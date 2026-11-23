import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' show GlobalMemoryStatusEx, MEMORYSTATUSEX;

import 'module_store.dart';

/// Comment Mon Hub tourne sur **ce PC** : à fond, ou en douceur.
enum PerfLevel {
  /// Mode léger : Clicky reste dans la fenêtre de Mon Hub, et tout ce qui
  /// surveille en continu tourne beaucoup moins souvent.
  light,

  /// Tout est allumé (PC confortable).
  full,
}

/// Les règles, sans Windows : testables.
class PerfRules {
  const PerfRules._();

  /// Un PC est « modeste » s'il a peu de cœurs ou peu de mémoire.
  ///
  /// [cores] = nombre de cœurs, [ramGb] = mémoire totale (0 = inconnue).
  static bool modest({required int cores, required double ramGb}) {
    if (cores > 0 && cores <= 2) return true;
    if (ramGb > 0 && ramGb < 4.5) return true;
    if (cores > 0 && cores <= 4 && ramGb > 0 && ramGb < 8.5) return true;
    return false;
  }

  /// Un tour de surveillance : allongé en mode léger.
  static Duration slow(Duration d, {required bool light, double factor = 2.5}) =>
      light ? Duration(milliseconds: (d.inMilliseconds * factor).round()) : d;
}

/// **Mode léger** : Mon Hub s'adapte à la puissance du PC.
///
/// Avant, dès la connexion, l'appli lançait tout en même temps (Clicky
/// partout en second programme, les yeux et les oreilles, le presse-papier,
/// la sauvegarde, le téléphone…). Sur un PC modeste, ça l'étouffait et
/// Clicky n'arrivait même pas à démarrer. Maintenant :
///
/// * la puissance du PC est regardée une fois, au premier démarrage ;
/// * en mode léger, Clicky vit dans la fenêtre de Mon Hub (pas de second
///   programme), les surveillances tournent bien moins souvent, et rien de
///   lourd (lecture de l'écran, écoute du son) ne démarre tout seul ;
/// * le démarrage est **étalé** au lieu d'être fait d'un coup.
///
/// Réglable dans Réglages → Vitesse de l'appli (`app.perf`).
class Perf {
  Perf._();

  /// Choix de la personne : 'auto' (par défaut), 'leger' ou 'complet'.
  static const key = 'app.perf';

  static PerfLevel? _level;
  static bool? _modest;

  /// Vrai si le mode léger est actif.
  static bool get light => level == PerfLevel.light;

  static PerfLevel get level {
    final l = _level;
    if (l != null) return l;
    final r = _read();
    // Tant que les réglages ne sont pas prêts (tout début du démarrage), on
    // ne garde pas la réponse : le choix de la personne doit pouvoir gagner.
    if (_prefsOk) _level = r;
    return r;
  }

  static bool _prefsOk = false;

  /// Pour les tests : impose un niveau (null = relire le réglage).
  @visibleForTesting
  static set level(PerfLevel? v) => _level = v;

  /// Ce que la personne a choisi ('auto', 'leger' ou 'complet').
  static String get choice {
    try {
      final v = ModuleStore.global.getString(key) ?? 'auto';
      _prefsOk = true;
      return v;
    } catch (_) {
      _prefsOk = false;
      return 'auto';
    }
  }

  static Future<void> setChoice(String v) async {
    try {
      await ModuleStore.global.setString(key, v);
    } catch (_) {}
    _level = null;
  }

  static PerfLevel _read() {
    switch (choice) {
      case 'leger':
        return PerfLevel.light;
      case 'complet':
        return PerfLevel.full;
      default:
        return _detect() ? PerfLevel.light : PerfLevel.full;
    }
  }

  /// Mémoire totale du PC en Go (0 si on ne sait pas).
  static double ramGb() {
    if (kIsWeb || !Platform.isWindows) return 0;
    var total = 0.0;
    try {
      using((a) {
        final m = a<MEMORYSTATUSEX>();
        m.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
        if (GlobalMemoryStatusEx(m).value) {
          total = m.ref.ullTotalPhys / (1 << 30);
        }
      });
    } catch (_) {}
    return total;
  }

  static bool _detect() {
    final known = _modest;
    if (known != null) return known;
    var cores = 0;
    try {
      cores = Platform.numberOfProcessors;
    } catch (_) {}
    return _modest = PerfRules.modest(cores: cores, ramGb: ramGb());
  }

  /// Vrai si le PC a été jugé modeste tout seul (pour l'expliquer une fois).
  static bool get autoLight => choice == 'auto' && light;

  /// Un tour de surveillance, allongé en mode léger.
  static Duration slow(Duration d, {double factor = 2.5}) => PerfRules.slow(d, light: light, factor: factor);

  /// Clicky peut-il sortir de la fenêtre (second programme) ?
  /// Non en mode léger : c'est lui qui coûtait le plus cher.
  static bool get everywhere => !light;

  /// Les choses lourdes qui tournent en continu (lire l'écran, écouter le
  /// son du PC, reconnaître les rythmes, sauvegarder le travail).
  static bool get heavy => !light;

  /// Animations longues et effets : calmés en mode léger.
  static bool get animations => !light;

  /// Démarrage **étalé** : la n-ième chose attend un peu plus longtemps,
  /// deux fois plus en mode léger.
  static Future<void> stagger(int rank) {
    if (rank <= 0) return Future<void>.value();
    final ms = rank * (light ? 2500 : 900);
    return Future<void>.delayed(Duration(milliseconds: ms));
  }

  /// Lance [job] plus tard, sans bloquer l'ouverture de l'appli.
  static void later(int rank, FutureOr<void> Function() job) {
    unawaited(
      stagger(rank).then((_) async {
        try {
          await job();
        } catch (_) {}
      }),
    );
  }

  /// Phrase expliquée à la personne (Réglages, et une fois au démarrage).
  static String get explain => light
      ? 'Mode léger : Clicky reste dans la fenêtre de Mon Hub et les surveillances se font plus '
            'rarement, pour que tout reste fluide.'
      : 'Mode complet : tout est allumé (Clicky partout, surveillances en continu).';
}
