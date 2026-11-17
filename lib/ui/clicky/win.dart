import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Petits appels Windows pour « Clicky partout » : clavier et souris de tout
/// le système, écrans, capture, et placement de la fenêtre de Clicky.
class Win {
  Win._();

  /// Ces appels ne marchent que sur Windows.
  static bool get supportedHere => !kIsWeb && Platform.isWindows;

  static bool down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

  static const _modifierKeys = {
    0x10, 0x11, 0x12, // Maj, Ctrl, Alt
    0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, // gauche / droite
    0x5B, 0x5C, // Windows
    0x14, 0x90, 0x91, // verrouillages
  };

  /// Une touche autre que Ctrl / Alt / Maj / Windows est enfoncée.
  static bool otherKeyDown() {
    for (var vk = 0x08; vk <= 0xFE; vk++) {
      if (_modifierKeys.contains(vk)) continue;
      if (down(vk)) return true;
    }
    return false;
  }

  /// Position de la souris (pixels physiques de l'écran).
  static (int, int)? cursor() {
    final p = calloc<POINT>();
    try {
      if (!GetCursorPos(p).value) return null;
      return (p.ref.x, p.ref.y);
    } finally {
      calloc.free(p);
    }
  }

  /// Rectangle de tous les écrans réunis (x, y, largeur, hauteur).
  static (int, int, int, int) virtualScreen() => (
    GetSystemMetrics(SM_XVIRTUALSCREEN),
    GetSystemMetrics(SM_YVIRTUALSCREEN),
    GetSystemMetrics(SM_CXVIRTUALSCREEN),
    GetSystemMetrics(SM_CYVIRTUALSCREEN),
  );

  /// Chaque écran branché (x, y, largeur, hauteur), le principal en premier.
  static List<(int, int, int, int)> monitors() {
    final out = <(int, int, int, int)>[];
    int callback(Pointer hMonitor, Pointer hdc, Pointer<RECT> r, int data) {
      final rc = r.ref;
      out.add((rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top));
      return 1;
    }

    final cb = NativeCallable<MONITORENUMPROC>.isolateLocal(callback, exceptionalReturn: 0);
    try {
      EnumDisplayMonitors(null, null, cb.nativeFunction, const LPARAM(0));
    } finally {
      cb.close();
    }
    // L'écran principal contient le point (0, 0).
    out.sort((a, b) {
      bool primary((int, int, int, int) m) =>
          m.$1 <= 0 && m.$2 <= 0 && m.$1 + m.$3 > 0 && m.$2 + m.$4 > 0;
      return (primary(b) ? 1 : 0) - (primary(a) ? 1 : 0);
    });
    if (out.isEmpty) {
      final v = virtualScreen();
      out.add(v);
    }
    return out;
  }

  /// Capture une zone de l'écran : pixels BGRA (opaques).
  static Uint8List capture(int x, int y, int w, int h) {
    final screen = GetDC(null);
    final mem = CreateCompatibleDC(screen);
    final bmp = CreateCompatibleBitmap(screen, w, h);
    final old = SelectObject(mem, HGDIOBJ(bmp));
    final bi = calloc<BITMAPINFO>();
    final buf = calloc<Uint8>(w * h * 4);
    try {
      BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY);
      bi.ref.bmiHeader
        ..biSize = sizeOf<BITMAPINFOHEADER>()
        ..biWidth = w
        ..biHeight =
            -h // de haut en bas
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = BI_RGB;
      GetDIBits(mem, bmp, 0, h, buf, bi, DIB_RGB_COLORS);
      final out = Uint8List.fromList(buf.asTypedList(w * h * 4));
      // GDI laisse l'opacité à 0 : on la remet à fond.
      for (var i = 3; i < out.length; i += 4) {
        out[i] = 255;
      }
      return out;
    } finally {
      SelectObject(mem, old);
      DeleteObject(HGDIOBJ(bmp));
      DeleteDC(mem);
      ReleaseDC(null, screen);
      calloc.free(bi);
      calloc.free(buf);
    }
  }

  /// La fenêtre de Clicky (créée par le lanceur avec le titre « Clicky »),
  /// en vérifiant qu'elle appartient bien à ce programme.
  static HWND? findClicky(int myPid) => using((a) {
    final r = FindWindow(
      'FLUTTER_RUNNER_WIN32_WINDOW'.toPcwstr(allocator: a),
      'Clicky'.toPcwstr(allocator: a),
    );
    final h = r.value;
    if (h.address == 0) return null;
    final owner = a<Uint32>();
    GetWindowThreadProcessId(h, owner);
    return owner.value == myPid ? h : null;
  });

  /// Place la fenêtre (pixels physiques), au premier plan, sans voler le focus.
  static void place(HWND hwnd, int x, int y, int w, int h) {
    SetWindowPos(
      hwnd,
      HWND_TOPMOST,
      x,
      y,
      w,
      h,
      SET_WINDOW_POS_FLAGS(SWP_NOACTIVATE | SWP_SHOWWINDOW),
    );
  }

  static void hide(HWND hwnd) => ShowWindow(hwnd, SW_HIDE);

  /// Autorise (ou non) la fenêtre à recevoir le clavier, et lui donne le
  /// focus : nécessaire pour écrire une question dans le panneau.
  static void setInteractive(HWND hwnd, bool interactive) {
    final ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
    final next = interactive ? ex & ~WS_EX_NOACTIVATE : ex | WS_EX_NOACTIVATE;
    if (next != ex) SetWindowLongPtr(hwnd, GWL_EXSTYLE, next);
    if (!interactive) return;
    // Windows n'autorise une appli en arrière-plan à prendre le focus que
    // si elle se « branche » un instant sur la fenêtre active.
    final fg = GetForegroundWindow();
    final fgThread = GetWindowThreadProcessId(fg, null);
    final me = GetCurrentThreadId();
    final attach = fgThread != 0 && fgThread != me;
    if (attach) AttachThreadInput(me, fgThread, true);
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
    if (attach) AttachThreadInput(me, fgThread, false);
  }

  /// Ouvre la dictée de Windows (Win + H) : elle écrit ce que tu dis dans la
  /// zone de texte qui a le focus. Solution de secours si le micro de
  /// Clicky ne marche pas.
  static void voiceTyping() => using((a) {
    const keys = [
      (VK_LWIN, false),
      (VIRTUAL_KEY(0x48), false),
      (VIRTUAL_KEY(0x48), true),
      (VK_LWIN, true),
    ];
    final inputs = a<INPUT>(keys.length);
    for (var i = 0; i < keys.length; i++) {
      final (vk, up) = keys[i];
      inputs[i].type = INPUT_KEYBOARD;
      inputs[i].Anonymous.ki
        ..wVk = vk
        ..dwFlags = up ? KEYEVENTF_KEYUP : const KEYBD_EVENT_FLAGS(0);
    }
    SendInput(keys.length, inputs, sizeOf<INPUT>());
  });

  // ---------- Fenêtres ----------

  static String _title(HWND h) => using((a) {
    final n = GetWindowTextLength(h).value;
    if (n <= 0) return '';
    final buf = wsalloc(n + 1, a);
    GetWindowText(h, buf, n + 1);
    return buf.toDartString();
  });

  /// La fenêtre au premier plan (celle où tu travailles).
  static HWND foreground() => GetForegroundWindow();

  /// Titre de la fenêtre au premier plan (« Document1 - Word »).
  static String foregroundTitle() {
    try {
      return _title(GetForegroundWindow());
    } catch (_) {
      return '';
    }
  }

  /// Titres de toutes les fenêtres visibles (pour la protection de la vie
  /// privée : on ne capture pas l'écran si une fenêtre sensible est ouverte).
  static List<String> visibleTitles() {
    final out = <String>[];
    int callback(Pointer h, int _) {
      final hwnd = HWND(h);
      if (IsWindowVisible(hwnd)) {
        final t = _title(hwnd);
        if (t.trim().isNotEmpty) out.add(t);
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
    return out;
  }

  // ---------- Clavier et souris (Clicky pilote, dictée) ----------

  static void _keys(List<(int vk, bool up)> keys) => using((a) {
    final inputs = a<INPUT>(keys.length);
    for (var i = 0; i < keys.length; i++) {
      final (vk, up) = keys[i];
      inputs[i].type = INPUT_KEYBOARD;
      inputs[i].Anonymous.ki
        ..wVk = VIRTUAL_KEY(vk)
        ..dwFlags = up ? KEYEVENTF_KEYUP : const KEYBD_EVENT_FLAGS(0);
    }
    SendInput(keys.length, inputs, sizeOf<INPUT>());
  });

  /// Relâche Ctrl, Alt, Maj et Windows (pour taper sans raccourci parasite).
  static void releaseModifiers() =>
      _keys([for (final vk in const [0x10, 0x11, 0x12, 0x5B, 0x5C]) if (down(vk)) (vk, true)]);

  /// Tape un texte (caractères Unicode, sans dépendre du clavier).
  static void typeText(String text) => using((a) {
    final units = text.replaceAll('\r\n', '\n').codeUnits;
    if (units.isEmpty) return;
    final inputs = a<INPUT>(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      for (var j = 0; j < 2; j++) {
        final k = inputs[i * 2 + j];
        k.type = INPUT_KEYBOARD;
        final ki = k.Anonymous.ki;
        if (units[i] == 10) {
          ki
            ..wVk = VK_RETURN
            ..dwFlags = j == 1 ? KEYEVENTF_KEYUP : const KEYBD_EVENT_FLAGS(0);
        } else {
          ki
            ..wVk = const VIRTUAL_KEY(0)
            ..wScan = units[i]
            ..dwFlags = j == 1
                ? KEYBD_EVENT_FLAGS(KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)
                : KEYEVENTF_UNICODE;
        }
      }
    }
    SendInput(units.length * 2, inputs, sizeOf<INPUT>());
  });

  static const _named = {
    'ctrl': 0x11, 'control': 0x11, 'alt': 0x12, 'shift': 0x10, 'maj': 0x10,
    'win': 0x5B, 'windows': 0x5B, 'enter': 0x0D, 'entree': 0x0D, 'entrée': 0x0D,
    'tab': 0x09, 'esc': 0x1B, 'echap': 0x1B, 'échap': 0x1B, 'escape': 0x1B,
    'space': 0x20, 'espace': 0x20, 'backspace': 0x08, 'retour': 0x08,
    'delete': 0x2E, 'suppr': 0x2E, 'del': 0x2E, 'home': 0x24, 'end': 0x23,
    'fin': 0x23, 'pageup': 0x21, 'pagedown': 0x22, 'up': 0x26, 'haut': 0x26,
    'down': 0x28, 'bas': 0x28, 'left': 0x25, 'gauche': 0x25, 'right': 0x27,
    'droite': 0x27,
  };

  /// Code de touche d'un nom (« ctrl », « s », « f5 »…), ou null.
  static int? keyCode(String name) {
    final n = name.trim().toLowerCase();
    if (_named[n] case final v?) return v;
    if (RegExp(r'^f([1-9]|1[0-2])$').hasMatch(n)) return 0x70 + int.parse(n.substring(1)) - 1;
    if (n.length == 1) {
      final c = n.toUpperCase().codeUnitAt(0);
      if ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)) return c;
    }
    return null;
  }

  /// Un raccourci : « ctrl+s », « alt+tab », « enter ». Renvoie false si une
  /// touche est inconnue.
  static bool pressCombo(String combo) {
    final codes = [for (final p in combo.split('+')) keyCode(p)];
    if (codes.isEmpty || codes.contains(null)) return false;
    final vks = codes.cast<int>();
    _keys([for (final k in vks) (k, false), for (final k in vks.reversed) (k, true)]);
    return true;
  }

  /// Clic (pixels physiques de l'écran).
  static void click(int x, int y, {bool right = false, bool double = false}) {
    SetCursorPos(x, y);
    using((a) {
      final n = double ? 4 : 2;
      final inputs = a<INPUT>(n);
      for (var i = 0; i < n; i++) {
        inputs[i].type = INPUT_MOUSE;
        final downFlag = right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
        final upFlag = right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP;
        inputs[i].Anonymous.mi.dwFlags = i.isEven ? downFlag : upFlag;
      }
      SendInput(n, inputs, sizeOf<INPUT>());
    });
  }

  /// Molette : [notches] positif = vers le haut.
  static void scroll(int notches) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi
      ..dwFlags = MOUSEEVENTF_WHEEL
      ..mouseData = (notches * 120) & 0xFFFFFFFF;
    SendInput(1, input, sizeOf<INPUT>());
  });

  // ---------- Clicky agit : souris visible, glisser, fenêtres ----------

  /// Déplace la souris en douceur jusqu'au point (on la voit bouger).
  static Future<void> glide(int x, int y, {Duration duration = const Duration(milliseconds: 380)}) async {
    final from = cursor() ?? (x, y);
    const steps = 22;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final e = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2) / 2;
      SetCursorPos((from.$1 + (x - from.$1) * e).round(), (from.$2 + (y - from.$2) * e).round());
      await Future<void>.delayed(Duration(microseconds: duration.inMicroseconds ~/ steps));
    }
    SetCursorPos(x, y);
  }

  static void _mouse(MOUSE_EVENT_FLAGS flags) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi.dwFlags = flags;
    SendInput(1, input, sizeOf<INPUT>());
  });

  /// Glisser-déposer d'un point à un autre.
  static Future<void> drag(int x1, int y1, int x2, int y2) async {
    await glide(x1, y1);
    _mouse(MOUSEEVENTF_LEFTDOWN);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await glide(x2, y2, duration: const Duration(milliseconds: 600));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _mouse(MOUSEEVENTF_LEFTUP);
  }

  /// Molette horizontale : [notches] positif = vers la droite.
  static void hscroll(int notches) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi
      ..dwFlags = MOUSEEVENTF_HWHEEL
      ..mouseData = (notches * 120) & 0xFFFFFFFF;
    SendInput(1, input, sizeOf<INPUT>());
  });

  /// Les fenêtres ouvertes (visibles, avec un titre) : (numéro, titre,
  /// programme).
  static List<(int, String, String)> windowList() {
    final out = <(int, String, String)>[];
    int callback(Pointer h, int _) {
      final hwnd = HWND(h);
      if (IsWindowVisible(hwnd)) {
        final t = _title(hwnd);
        if (t.trim().isNotEmpty && t != 'Clicky' && t != 'Program Manager') {
          var exe = '';
          try {
            exe = _exeOf(hwnd);
          } catch (_) {}
          out.add((h.address, t, exe));
        }
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
    return out;
  }

  /// Agit sur une fenêtre : 'activer', 'reduire', 'agrandir', 'restaurer'
  /// ou 'fermer'. Renvoie false si la fenêtre n'existe plus.
  static bool windowAction(int id, String what) {
    final hwnd = HWND(Pointer.fromAddress(id));
    if (!IsWindow(hwnd)) return false;
    switch (what) {
      case 'reduire':
        ShowWindow(hwnd, SW_MINIMIZE);
      case 'agrandir':
        ShowWindow(hwnd, SW_MAXIMIZE);
        _focus(hwnd);
      case 'restaurer':
        ShowWindow(hwnd, SW_RESTORE);
        _focus(hwnd);
      case 'fermer':
        PostMessage(hwnd, WM_CLOSE, const WPARAM(0), const LPARAM(0));
      default:
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        _focus(hwnd);
    }
    return true;
  }

  /// Met une fenêtre au premier plan (Windows ne le permet que si on
  /// « appuie » sur Alt juste avant).
  static void _focus(HWND hwnd) {
    _keys([(0x12, false), (0x12, true)]);
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
  }

  // ---------- Applis ouvertes (repli musique) ----------

  static String _exeOf(HWND h) => using((a) {
    final pidPtr = a<Uint32>();
    GetWindowThreadProcessId(h, pidPtr);
    final proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pidPtr.value).value;
    if (proc.address == 0) return '';
    try {
      final buf = wsalloc(1024, a);
      final size = a<Uint32>()..value = 1024;
      if (!QueryFullProcessImageName(proc, PROCESS_NAME_WIN32, buf, size).value) return '';
      return buf.toDartString().split(RegExp(r'[\\/]')).last;
    } finally {
      CloseHandle(proc);
    }
  });

  /// Titres des fenêtres visibles d'un programme (ex. « Spotify.exe »).
  static List<String> titlesOf(String exeName) {
    final out = <String>[];
    final want = exeName.toLowerCase();
    int callback(Pointer h, int _) {
      final hwnd = HWND(h);
      if (IsWindowVisible(hwnd)) {
        final t = _title(hwnd);
        if (t.trim().isNotEmpty && _exeOf(hwnd).toLowerCase() == want) out.add(t);
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
    return out;
  }

  /// Touches multimédia du clavier : marchent avec n'importe quel lecteur.
  static void mediaKey(String key) {
    final vk = switch (key) {
      'next' => VK_MEDIA_NEXT_TRACK,
      'prev' => VK_MEDIA_PREV_TRACK,
      'stop' => VK_MEDIA_STOP,
      _ => VK_MEDIA_PLAY_PAUSE,
    };
    _keys([(vk, false), (vk, true)]);
  }
}
