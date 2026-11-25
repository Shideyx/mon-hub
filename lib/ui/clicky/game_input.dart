import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Les touches comme un jeu les comprend, **sans Windows** (testable) : les
/// jeux lisent les touches *physiques* (codes « scan »), pas les lettres.
/// Avancer / reculer / gauche / droite = la place de W A S D (Z Q S D sur
/// un clavier français), quelle que soit la langue du clavier.
class GameKeys {
  GameKeys._();

  /// (code scan, touche étendue).
  static const named = <String, (int, bool)>{
    'echap': (0x01, false),
    'esc': (0x01, false),
    'escape': (0x01, false),
    'entree': (0x1C, false),
    'enter': (0x1C, false),
    'espace': (0x39, false),
    'space': (0x39, false),
    'saut': (0x39, false),
    'sauter': (0x39, false),
    'tab': (0x0F, false),
    'retour': (0x0E, false),
    'backspace': (0x0E, false),
    'maj': (0x2A, false),
    'shift': (0x2A, false),
    'courir': (0x1D, false),
    'ctrl': (0x1D, false),
    'alt': (0x38, false),
    'avancer': (0x11, false),
    'reculer': (0x1F, false),
    'gauche': (0x1E, false),
    'droite': (0x20, false),
    'haut': (0x48, true),
    'bas': (0x50, true),
    'fleche_gauche': (0x4B, true),
    'fleche_droite': (0x4D, true),
    'suppr': (0x53, true),
    'delete': (0x53, true),
    'f1': (0x3B, false),
    'f2': (0x3C, false),
    'f3': (0x3D, false),
    'f4': (0x3E, false),
    'f5': (0x3F, false),
    'f6': (0x40, false),
    'f7': (0x41, false),
    'f8': (0x42, false),
    'f9': (0x43, false),
    'f10': (0x44, false),
    'f11': (0x57, false),
    'f12': (0x58, false),
  };

  /// Les chiffres de la rangée du haut (barre d'objets : 1 à 9) : touches
  /// physiques, même sur un clavier français (« & é " » = 1 2 3).
  static (int, bool)? digit(String d) {
    final n = int.tryParse(d);
    if (n == null || n < 0 || n > 9 || d.length != 1) return null;
    return (n == 0 ? 0x0B : 0x01 + n, false);
  }

  /// La touche d'un nom : un nom connu, un chiffre, ou null (une lettre : voir
  /// [GameInput.scanOf], qui suit la langue du clavier).
  static (int, bool)? of(String name) {
    final n = name.trim().toLowerCase().replaceAll(' ', '_').replaceAll('é', 'e').replaceAll('è', 'e');
    return named[n] ?? digit(n);
  }
}

/// **Le clavier et la souris pour les jeux** (Windows) : codes scan (lus par
/// les jeux DirectInput / GLFW comme Minecraft), touches maintenues, souris
/// *relative* pour tourner la caméra, clics maintenus pour miner, glisser
/// dans un inventaire.
class GameInput {
  GameInput._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Le code scan d'une touche : nom connu, chiffre, sinon la lettre telle
  /// qu'elle est sur le clavier de la personne (AZERTY ou QWERTY).
  static (int, bool)? scanOf(String name) {
    final k = GameKeys.of(name);
    if (k != null) return k;
    final t = name.trim();
    if (t.length != 1 || !supported) return null;
    final vk = VkKeyScan(t.toLowerCase().codeUnitAt(0)) & 0xFF;
    if (vk == 0xFF) return null;
    final sc = MapVirtualKey(vk, MAPVK_VK_TO_VSC);
    return sc == 0 ? null : (sc, false);
  }

  /// Le clavier est en français (AZERTY) ?
  static bool get azerty {
    if (!supported) return false;
    try {
      return (GetKeyboardLayout(0).address & 0x3FF) == 0x0C; // LANG_FRENCH
    } catch (_) {
      return false;
    }
  }

  static void _key((int, bool) k, {required bool up}) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_KEYBOARD;
    var flags = KEYEVENTF_SCANCODE;
    if (k.$2) flags |= KEYEVENTF_EXTENDEDKEY;
    if (up) flags |= KEYEVENTF_KEYUP;
    input.ref.Anonymous.ki
      ..wVk = const VIRTUAL_KEY(0)
      ..wScan = k.$1
      ..dwFlags = flags;
    SendInput(1, input, sizeOf<INPUT>());
  });

  /// Appuie sur des touches ensemble pendant [ms] (avancer + courir…), puis
  /// les relâche. Faux si une touche est inconnue.
  static Future<bool> hold(List<String> names, int ms) async {
    final keys = [for (final n in names) scanOf(n)];
    if (keys.isEmpty || keys.contains(null)) return false;
    final ks = keys.cast<(int, bool)>();
    for (final k in ks) {
      _key(k, up: false);
    }
    await Future<void>.delayed(Duration(milliseconds: ms.clamp(30, 8000)));
    for (final k in ks.reversed) {
      _key(k, up: true);
    }
    return true;
  }

  /// Relâche tout ce qu'on aurait pu laisser appuyé (sécurité).
  static void releaseAll() {
    for (final n in const ['avancer', 'reculer', 'gauche', 'droite', 'maj', 'ctrl', 'espace', 'alt']) {
      final k = GameKeys.of(n);
      if (k != null) _key(k, up: true);
    }
    _button(left: true, down: false);
    _button(left: false, down: false);
  }

  static void _move(int dx, int dy) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi
      ..dwFlags = MOUSEEVENTF_MOVE
      ..dx = dx
      ..dy = dy;
    SendInput(1, input, sizeOf<INPUT>());
  });

  static void _button({required bool left, required bool down}) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi.dwFlags = left
        ? (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP)
        : (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
    SendInput(1, input, sizeOf<INPUT>());
  });

  /// Tourne la caméra (souris relative), en douceur.
  static Future<void> look(int dx, int dy) async {
    const steps = 12;
    var sx = 0, sy = 0;
    for (var i = 1; i <= steps; i++) {
      final tx = (dx * i / steps).round(), ty = (dy * i / steps).round();
      _move(tx - sx, ty - sy);
      sx = tx;
      sy = ty;
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
  }

  /// Clic à un point de l'écran (menus, inventaire). [shift] : Maj + clic
  /// (dans Minecraft : envoie tout le tas d'un coup).
  static Future<void> clickAt(int x, int y, {bool right = false, bool shift = false, bool double = false}) async {
    SetCursorPos(x, y);
    // Certains jeux ne voient la souris qu'après un vrai petit mouvement.
    _move(1, 0);
    _move(-1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final sh = GameKeys.of('maj')!;
    if (shift) _key(sh, up: false);
    for (var i = 0; i < (double ? 2 : 1); i++) {
      _button(left: !right, down: true);
      await Future<void>.delayed(const Duration(milliseconds: 45));
      _button(left: !right, down: false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (shift) _key(sh, up: true);
  }

  /// Maintient un bouton (miner, viser…) pendant [ms].
  static Future<void> holdButton({bool right = false, int ms = 600}) async {
    _button(left: !right, down: true);
    await Future<void>.delayed(Duration(milliseconds: ms.clamp(30, 8000)));
    _button(left: !right, down: false);
  }

  /// Glisse d'un point à un autre (déplacer un objet).
  static Future<void> drag(int x1, int y1, int x2, int y2, {bool right = false}) async {
    SetCursorPos(x1, y1);
    _move(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _button(left: !right, down: true);
    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      SetCursorPos((x1 + (x2 - x1) * i / steps).round(), (y1 + (y2 - y1) * i / steps).round());
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _button(left: !right, down: false);
  }
}
