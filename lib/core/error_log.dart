import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'claude_bridge.dart';

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
      final first = '$error'.split('\n').first;
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
        '[${now.toIso8601String()}] $_who${where.isEmpty ? '' : ' / $where'}\n$error\n$trace\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Installe les garde-fous (au démarrage de chaque programme).
  static void install(String who) {
    _who = who;
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
      return File(p).readAsStringSync();
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
