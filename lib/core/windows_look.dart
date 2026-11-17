import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:win32/win32.dart';

/// Le look de Windows 11 : couleur d'accent choisie dans Windows, barre de
/// titre assortie à l'appli (claire ou sombre, coins arrondis).
class WindowsLook {
  WindowsLook._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Bleu de Windows 11 (si la couleur d'accent n'est pas lisible).
  static const defaultAccent = Color(0xFF0067C0);

  static Color? _accent;

  /// La couleur d'accent de Windows (Paramètres → Personnalisation →
  /// Couleurs).
  static Color get accent => _accent ??= _readAccent() ?? defaultAccent;

  static Color? _readAccent() {
    if (!supported) return null;
    try {
      return using((a) {
        final data = a<Uint32>();
        final size = a<Uint32>()..value = 4;
        final r = RegGetValue(
          HKEY_CURRENT_USER,
          r'Software\Microsoft\Windows\DWM'.toPcwstr(allocator: a),
          'AccentColor'.toPcwstr(allocator: a),
          RRF_RT_REG_DWORD,
          null,
          data,
          size,
        );
        if (r != ERROR_SUCCESS) return null;
        // Rangée ABGR.
        final v = data.value;
        return Color.fromARGB(255, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
      });
    } catch (_) {
      return null;
    }
  }

  /// Fond de l'appli (comme Paramètres de Windows 11).
  static Color background(Brightness b) => b == Brightness.dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3);

  /// La fenêtre principale de ce programme.
  static HWND? mainWindow() => _window();

  static HWND? _window() {
    HWND? found;
    int callback(Pointer h, int _) {
      final hwnd = HWND(h);
      if (!IsWindowVisible(hwnd)) return 1;
      final owner = using((a) {
        final p = a<Uint32>();
        GetWindowThreadProcessId(hwnd, p);
        return p.value;
      });
      if (owner == pid) {
        found = hwnd;
        return 0;
      }
      return 1;
    }

    final cb = NativeCallable<WNDENUMPROC>.isolateLocal(callback, exceptionalReturn: 0);
    try {
      EnumWindows(cb.nativeFunction, const LPARAM(0));
    } catch (_) {
    } finally {
      cb.close();
    }
    return found;
  }

  static int _colorRef(Color c) => ((c.b * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.r * 255).round();

  static void _set(HWND hwnd, DWMWINDOWATTRIBUTE attr, int value) {
    final p = calloc<Uint32>()..value = value;
    try {
      DwmSetWindowAttribute(hwnd, attr, p, 4);
    } catch (_) {
      // Windows 10 : certains réglages n'existent pas, ce n'est pas grave.
    } finally {
      calloc.free(p);
    }
  }

  /// Barre de titre de la couleur de l'appli (claire / sombre), comme une
  /// appli de Windows 11.
  static void applyTitleBar(Brightness b) {
    if (!supported) return;
    try {
      final hwnd = _window();
      if (hwnd == null) return;
      final dark = b == Brightness.dark;
      _set(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, dark ? 1 : 0);
      _set(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, 2); // coins arrondis
      _set(hwnd, DWMWA_CAPTION_COLOR, _colorRef(background(b)));
      _set(hwnd, DWMWA_TEXT_COLOR, _colorRef(dark ? Colors.white : Colors.black));
    } catch (_) {}
  }
}
