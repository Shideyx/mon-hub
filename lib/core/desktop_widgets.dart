import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'module_store.dart';

/// Les widgets de l'accueil **détachés sur le bureau** : chacun devient une
/// petite fenêtre à part (le même programme lancé avec `--widget=<module>`),
/// avec sa propre icône dans la barre des tâches. Mon Hub se souvient de
/// leur place et les rouvre au démarrage.
class DesktopWidgets extends ChangeNotifier {
  DesktopWidgets._();
  static final instance = DesktopWidgets._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Ce programme est une fenêtre de widget (pas Mon Hub en entier).
  static bool inWidgetWindow = false;

  static const _key = 'hub.detached';

  List<String> get ids {
    try {
      return ModuleStore.prefs.getStringList(_key) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  bool isDetached(String id) => supported && ids.contains(id);

  /// Port local de la fenêtre d'un widget (verrou + télécommande).
  static int port(String id) => 47700 + id.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) % 250);

  /// Place enregistrée (pixels de l'écran) : x, y, largeur, hauteur.
  static (int, int, int, int)? savedRect(String id) {
    try {
      final v = ModuleStore.prefs.getString('$_key.rect.$id');
      final p = v?.split(',').map(int.tryParse).toList();
      if (p == null || p.length != 4 || p.contains(null)) return null;
      return (p[0]!, p[1]!, p[2]!, p[3]!);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveRect(String id, (int, int, int, int) r) =>
      ModuleStore.prefs.setString('$_key.rect.$id', '${r.$1},${r.$2},${r.$3},${r.$4}');

  /// Sort un widget de Mon Hub ([at] : où le poser, en pixels de l'écran).
  Future<void> detach(String id, {(int, int)? at}) async {
    if (!supported) return;
    if (!ids.contains(id)) await ModuleStore.prefs.setStringList(_key, [...ids, id]);
    if (at != null) {
      final old = savedRect(id);
      await saveRect(id, (at.$1 - 60, at.$2 - 20, old?.$3 ?? 0, old?.$4 ?? 0));
    }
    notifyListeners();
    await launch(id);
  }

  /// Remet le widget dans Mon Hub (sa fenêtre se ferme).
  Future<void> attach(String id) async {
    await ModuleStore.prefs.setStringList(_key, [
      for (final x in ids)
        if (x != id) x,
    ]);
    notifyListeners();
    await send(id, 'quit');
  }

  static Future<bool> running(String id) async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port(id),
        timeout: const Duration(milliseconds: 300),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> send(String id, String cmd) async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port(id),
        timeout: const Duration(milliseconds: 300),
      );
      s.write('$cmd\n');
      await s.flush();
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ouvre la fenêtre du widget (ou la ramène devant si elle est ouverte).
  Future<void> launch(String id) async {
    if (!supported) return;
    if (await running(id)) {
      await send(id, 'front');
      return;
    }
    try {
      await Process.start(Platform.resolvedExecutable, ['--widget=$id'], mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('Widget $id : $e');
    }
  }

  /// Au démarrage de Mon Hub : rouvre les widgets laissés sur le bureau.
  Future<void> launchAll() async {
    for (final id in ids) {
      await launch(id);
    }
  }
}
