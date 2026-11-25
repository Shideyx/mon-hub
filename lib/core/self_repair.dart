import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'certificates.dart';
import 'error_log.dart';
import 'module_store.dart';
import 'perf.dart';

/// Une panne repérée dans le journal des erreurs, et ce qui la répare.
@immutable
class Repair {
  const Repair({required this.id, required this.title, required this.fixed, this.tool, this.args = const {}});

  /// Identifiant de la panne ('micro', 'certificats', 'gels'…).
  final String id;

  /// Ce que la personne lira : « Ton micro était bloqué ».
  final String title;

  /// Ce que Nexo a fait, dit simplement : « je l'ai relancé ».
  final String fixed;

  /// L'action de Mon Hub à lancer (null : réparé ici même).
  final String? tool;
  final Map<String, dynamic> args;

  @override
  bool operator ==(Object other) => other is Repair && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Les règles, **sans Windows ni fichiers** : testables.
class RepairRules {
  const RepairRules._();

  /// Ne regarde que les erreurs des dernières 48 h, pour ne pas réparer
  /// quelque chose qui n'arrive plus.
  static List<String> recentLines(String log, {DateTime? now, Duration within = const Duration(hours: 48)}) {
    final t = now ?? DateTime.now();
    final out = <String>[];
    // Avant la première date (ou sans date du tout), on garde : mieux vaut
    // regarder une ligne de trop que rater une panne.
    var keep = true;
    for (final line in log.split('\n')) {
      final m = RegExp(r'^\[([0-9T:\-.]+)\]').firstMatch(line);
      if (m != null) {
        final at = DateTime.tryParse(m[1]!);
        keep = at == null || t.difference(at) <= within;
      }
      if (keep) out.add(line);
    }
    return out;
  }

  static int _count(List<String> lines, RegExp re) => lines.where(re.hasMatch).length;

  /// Les pannes repérées, dans l'ordre où il faut les réparer.
  ///
  /// [log] = le journal des erreurs, [freezes] et [clickyRestarts] viennent
  /// du journal aussi, [diskFreeGb] du disque C:.
  static List<Repair> diagnose(String log, {DateTime? now, double diskFreeGb = 100, bool light = false}) {
    final lines = recentLines(log, now: now);
    final out = <Repair>[];

    // Le micro : écoute bloquée, processus détaché, reconnaissance vocale en
    // échec.
    if (_count(lines, RegExp(r'Process is detached|micro|SmartEars|reconnaissance vocale', caseSensitive: false)) >=
        2) {
      out.add(
        const Repair(
          id: 'micro',
          title: 'Ton micro restait bloqué',
          fixed: 'je l\'ai relancé',
          tool: 'clicky_reparer_micro',
        ),
      );
    }

    // Les certificats (antivirus, réseau du lycée) : plus rien ne se
    // télécharge.
    if (_count(lines, RegExp(r'CERTIFICATE_VERIFY_FAILED|HandshakeException', caseSensitive: false)) >= 1) {
      out.add(
        const Repair(
          id: 'certificats',
          title: 'Les connexions sécurisées échouaient',
          fixed: 'j\'ai réinstallé les certificats de ton PC',
        ),
      );
    }

    // L'appli fige (noté par le guetteur de gels) : le mode léger la calme.
    if (!light && _count(lines, RegExp(r'fig[ée]e?', caseSensitive: false)) >= 3) {
      out.add(
        const Repair(
          id: 'gels',
          title: 'Mon Hub figeait de temps en temps',
          fixed: 'je suis passé en mode léger pour que tout reste fluide',
        ),
      );
    }

    // Nexo partout se ferme en boucle : il reste dans la fenêtre.
    if (!light && _count(lines, RegExp(r"Nexo partout s'est ferm", caseSensitive: false)) >= 3) {
      out.add(
        const Repair(
          id: 'clicky-partout',
          title: 'Nexo partout n\'arrivait pas à tenir ouvert',
          fixed: 'je l\'ai ramené dans la fenêtre de Mon Hub (mode léger)',
        ),
      );
    }

    // Plus de place : rien ne s'enregistre plus.
    if (diskFreeGb > 0 && diskFreeGb < 2) {
      out.add(
        const Repair(
          id: 'disque',
          title: 'Ton disque C: est presque plein',
          fixed: 'j\'ai préparé un rangement de tes téléchargements (rien n\'est supprimé)',
          tool: 'pc_ranger_apercu',
        ),
      );
    }

    // Un fichier de données abîmé (coupure de courant pendant une écriture).
    if (_count(lines, RegExp(r'FormatException.*json|Unexpected (?:character|end of input)', caseSensitive: false)) >=
        2) {
      out.add(
        const Repair(
          id: 'donnees',
          title: 'Un de tes fichiers de données était abîmé',
          fixed: 'je l\'ai remis d\'aplomb avec la copie de ton compte',
        ),
      );
    }

    return out;
  }

  /// Ce que Nexo dit après s'être réparé.
  static String say(List<Repair> done) {
    if (done.isEmpty) return 'Tout va bien, je n\'ai rien eu à réparer.';
    if (done.length == 1) return '${done.first.title} : ${done.first.fixed}.';
    return 'Je me suis réparé tout seul : ${[for (final r in done) '${r.title.toLowerCase()} (${r.fixed})'].join(' ; ')}.';
  }
}

/// **Nexo se répare tout seul.**
///
/// Il relit son journal d'erreurs (qui ne quitte jamais le PC), repère les
/// pannes qu'il sait corriger, et les corrige : micro bloqué, certificats
/// cassés, appli qui fige, Nexo partout qui n'arrive pas à tenir, disque
/// plein, fichier de données abîmé.
///
/// Il ne supprime jamais rien, et il dit toujours ce qu'il a fait.
class SelfRepair {
  SelfRepair._();
  static final instance = SelfRepair._();

  static bool get supported => !kIsWeb;

  /// Lance une action de Mon Hub (branché par l'appli).
  Future<Object?> Function(String name, Map<String, dynamic> args)? call;

  /// Prévenir la personne de ce qui a été réparé.
  void Function(String title, String body)? tell;

  /// Récupère un fichier de données abîmé depuis la copie du compte.
  Future<bool> Function()? restoreData;

  /// La dernière réparation (pour le diagnostic et la page Sécurité).
  DateTime? lastRun;
  List<Repair> lastDone = const [];

  static const _kDone = 'app.repare.fait';

  /// Les pannes déjà réparées (pour ne pas le refaire tous les jours).
  Set<String> get _already {
    try {
      return (ModuleStore.global.getStringList(_kDone) ?? const []).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _remember(String id) async {
    try {
      final d = _already..add(id);
      await ModuleStore.global.setStringList(_kDone, d.toList());
    } catch (_) {}
  }

  /// Oublie ce qui a déjà été réparé (« répare-toi » demandé à la main).
  Future<void> forget() async {
    try {
      await ModuleStore.global.setStringList(_kDone, const []);
    } catch (_) {}
  }

  /// Regarde et répare. [manual] : demandé par la personne (on refait tout,
  /// et on répond même s'il n'y a rien).
  Future<List<Repair>> run({bool manual = false, double? diskFreeGb}) async {
    if (!supported) return const [];
    if (manual) await forget();
    final log = ErrorLog.read();
    final found = RepairRules.diagnose(log, diskFreeGb: diskFreeGb ?? 100, light: Perf.light);
    final skip = manual ? <String>{} : _already;
    final done = <Repair>[];
    for (final r in found) {
      if (skip.contains(r.id)) continue;
      if (await _apply(r)) {
        done.add(r);
        await _remember(r.id);
      }
    }
    lastRun = DateTime.now();
    lastDone = done;
    if (done.isNotEmpty) {
      tell?.call('🔧 Nexo s\'est réparé tout seul', RepairRules.say(done));
    }
    return done;
  }

  Future<bool> _apply(Repair r) async {
    try {
      switch (r.id) {
        case 'certificats':
          await TrustedCertificates.install();
          return true;
        case 'gels':
        case 'clicky-partout':
          await Perf.setChoice('leger');
          return true;
        case 'donnees':
          return await restoreData?.call() ?? false;
        default:
          final tool = r.tool;
          if (tool == null) return false;
          final run = call;
          if (run == null) return false;
          final out = await run(tool, r.args);
          return out != null;
      }
    } catch (e) {
      ErrorLog.record(e, null, where: 'auto-réparation (${r.id})');
      return false;
    }
  }

  /// Place libre sur le disque C: (0 si on ne sait pas).
  static double diskFreeGb() {
    if (kIsWeb || !Platform.isWindows) return 0;
    try {
      final r = Process.runSync('cmd', ['/c', 'dir', 'C:\\']);
      final m = RegExp(r'([\d\s\u00a0.,]+) (?:octets libres|bytes free)').firstMatch('${r.stdout}');
      final digits = (m?[1] ?? '').replaceAll(RegExp(r'[^\d]'), '');
      if (digits.isEmpty) return 0;
      return (int.tryParse(digits) ?? 0) / (1 << 30);
    } catch (_) {
      return 0;
    }
  }
}
