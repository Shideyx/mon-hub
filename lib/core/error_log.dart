import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'claude_bridge.dart';
import 'freeze_watch.dart';

/// Journal des erreurs, **sur ton PC seulement** (rien n'est envoyé) :
/// %APPDATA%\MonHub\journal-erreurs.log. Quand Clicky ou Mon Hub plante,
/// on y voit exactement quoi et où, pour le corriger.
///
/// Les garde-fous installés ici évitent aussi qu'une erreur ne casse tout :
/// une erreur dans un écran affiche un petit encadré discret (au lieu d'un
/// grand rectangle gris par-dessus l'écran), et une erreur en arrière-plan
/// est notée puis ignorée.
class ErrorLog {
  ErrorLog._();

  static String? get path {
    final d = ClaudeBridge.folder;
    return d == null || kIsWeb ? null : '$d${Platform.pathSeparator}journal-erreurs.log';
  }

  static String _who = 'Mon Hub';
  static final _recent = <String, DateTime>{};

  /// Note une erreur (les mêmes erreurs à la suite ne sont notées qu'une
  /// fois par minute).
  static void record(Object error, StackTrace? stack, {String where = ''}) {
    try {
      // Jamais de clé ni de jeton dans le journal (les erreurs réseau
      // contiennent souvent l'adresse complète, « ?key=… » compris).
      final text = redact('$error');
      final first = text.split('\n').first;
      final key = '$where|$first';
      final now = DateTime.now();
      final last = _recent[key];
      if (last != null && now.difference(last) < const Duration(minutes: 1)) return;
      _recent[key] = now;
      if (_recent.length > 200) _recent.clear();
      final p = path;
      if (p == null) return;
      final f = File(p);
      if (f.existsSync() && f.lengthSync() > 512 * 1024) {
        // On garde la fin du journal.
        final keep = f.readAsStringSync();
        f.writeAsStringSync(keep.substring(keep.length - 128 * 1024));
      }
      final trace = (stack?.toString() ?? '').split('\n').take(14).join('\n');
      f.writeAsStringSync(
        '[${now.toIso8601String()}] $_who${where.isEmpty ? '' : ' / $where'}\n$text\n$trace\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Masque les secrets d'un texte : clés d'API (Gemini, Claude, GitHub…),
  /// jetons (`Bearer …`, Discord), paramètres `key=`, `token=`, mots de passe.
  static String redact(String s) => s
      .replaceAllMapped(
        RegExp(
          r'([?&;\s](?:key|api_?key|token|access_token|refresh_token|id_token|code|password|passwd|mdp|secret|client_secret|sig|signature)=)[^&\s"<>]+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}•••',
      )
      .replaceAllMapped(
        RegExp(r'((?:bearer|bot|basic)\s+)[A-Za-z0-9._~+/=-]{12,}', caseSensitive: false),
        (m) => '${m[1]}•••',
      )
      .replaceAll(RegExp(r'AIza[0-9A-Za-z_-]{30,}'), 'AIza•••')
      .replaceAll(RegExp(r'sk-ant-[A-Za-z0-9_-]{10,}'), 'sk-ant-•••')
      .replaceAll(RegExp(r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'), 'gh•••')
      .replaceAll(RegExp(r'GOCSPX-[A-Za-z0-9_-]{10,}'), 'GOCSPX-•••')
      .replaceAll(RegExp(r'ya29\.[A-Za-z0-9._-]{20,}'), 'ya29.•••')
      .replaceAll(RegExp(r'\b[MNO][A-Za-z\d_-]{23,27}\.[\w-]{6}\.[\w-]{27,40}\b'), '(jeton Discord masqué)')
      .replaceAll(RegExp(r'"(password|motdepasse|mdp|token|apiKey|key)"\s*:\s*"[^"]*"', caseSensitive: false), '"•••":"•••"');

  /// Installe les garde-fous (au démarrage de chaque programme).
  static void install(String who) {
    _who = who;
    // Le guetteur note quand l'appli fige (« Ne répond pas ») et pourquoi.
    unawaited(FreezeWatch.start(who, path));
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, where: details.library ?? 'affichage');
      if (kDebugMode) previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, where: 'arrière-plan');
      return true; // erreur gérée : le programme continue
    };
    if (!kDebugMode) {
      ErrorWidget.builder = (details) => const SizedBox.shrink();
    }
  }

  /// Le contenu du journal (pour les réglages).
  static String read() {
    try {
      final p = path;
      if (p == null || !File(p).existsSync()) return '';
      // Les anciennes lignes (avant le masquage) sont masquées à la lecture.
      return redact(File(p).readAsStringSync());
    } catch (_) {
      return '';
    }
  }

  static void clear() {
    try {
      final p = path;
      if (p != null && File(p).existsSync()) File(p).deleteSync();
    } catch (_) {}
  }
}
