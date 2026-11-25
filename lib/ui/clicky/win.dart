import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Petits appels Windows pour « Nexo partout » : clavier et souris de tout
/// le système, écrans, capture, et placement de la fenêtre de Nexo.
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
      bool primary((int, int, int, int) m) => m.$1 <= 0 && m.$2 <= 0 && m.$1 + m.$3 > 0 && m.$2 + m.$4 > 0;
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

  /// La fenêtre de Nexo (créée par le lanceur avec le titre « Nexo »),
  /// en vérifiant qu'elle appartient bien à ce programme.
  static HWND? findClicky(int myPid) => using((a) {
    final r = FindWindow('FLUTTER_RUNNER_WIN32_WINDOW'.toPcwstr(allocator: a), 'Nexo'.toPcwstr(allocator: a));
    final h = r.value;
    if (h.address == 0) return null;
    final owner = a<Uint32>();
    GetWindowThreadProcessId(h, owner);
    return owner.value == myPid ? h : null;
  });

  /// Ramène la fenêtre principale de Mon Hub au premier plan (de ce
  /// programme : [myPid]).
  static bool raiseMain(int myPid) => using((a) {
    final h = FindWindow('FLUTTER_RUNNER_WIN32_WINDOW'.toPcwstr(allocator: a), 'Mon Hub'.toPcwstr(allocator: a)).value;
    if (h.address == 0) return false;
    final owner = a<Uint32>();
    GetWindowThreadProcessId(h, owner);
    if (owner.value != myPid) return false;
    if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
    _focus(h);
    return true;
  });

  /// Place la fenêtre (pixels physiques), au premier plan, sans voler le focus.
  static void place(HWND hwnd, int x, int y, int w, int h) {
    SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SET_WINDOW_POS_FLAGS(SWP_NOACTIVATE | SWP_SHOWWINDOW));
  }

  static void hide(HWND hwnd) => ShowWindow(hwnd, SW_HIDE);

  /// Change seulement la taille (le coin en haut à gauche ne bouge pas) :
  /// utile quand Windows fait suivre la souris à la fenêtre (voir [follow]).
  static void resize(HWND hwnd, int w, int h, {bool show = true}) {
    SetWindowPos(
      hwnd,
      HWND_TOPMOST,
      0,
      0,
      w,
      h,
      SET_WINDOW_POS_FLAGS(SWP_NOMOVE | SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : 0)),
    );
  }

  /// Message compris par le lanceur (windows/runner/clicky_follow.h).
  static const _followMessage = WM_APP + 0x51;

  /// **Nexo colle à la souris** : Windows déplace lui-même la fenêtre à
  /// chaque mouvement de la souris (jusqu'à 1000 fois par seconde), sans
  /// attendre le code Dart — c'est ce qui le rend fluide. [dx]/[dy] : où se
  /// tient la fenêtre par rapport au curseur (pixels physiques).
  static void follow(HWND hwnd, {required bool on, int dx = 16, int dy = 14}) {
    PostMessage(hwnd, _followMessage, WPARAM(on ? 1 : 0), LPARAM(packOffset(dx, dy)));
  }

  /// Le décalage dans un seul nombre, comme le lit le lanceur (x dans les 16
  /// bits du bas, y dans ceux du haut, avec signe).
  static int packOffset(int dx, int dy) => ((dy & 0xFFFF) << 16) | (dx & 0xFFFF);

  /// Ce que le lanceur relit (pour les tests).
  static (int, int) unpackOffset(int packed) {
    int signed(int v) => v >= 0x8000 ? v - 0x10000 : v;
    return (signed(packed & 0xFFFF), signed((packed >> 16) & 0xFFFF));
  }

  /// Position et taille réelles d'une fenêtre (pixels physiques).
  static (int, int, int, int)? windowRect(HWND hwnd) => using((a) {
    final r = a<RECT>();
    if (!GetWindowRect(hwnd, r).value) return null;
    return (r.ref.left, r.ref.top, r.ref.right - r.ref.left, r.ref.bottom - r.ref.top);
  });

  static int Function(int, int)? _affinity;
  static bool _affinityLooked = false;

  /// Retire (ou remet) une fenêtre des captures d'écran (Windows 10 2004 et
  /// plus) : Nexo reste visible pour toi pendant que la photo de l'écran
  /// se fait sans lui. Renvoie false si Windows ne sait pas faire.
  static bool excludeFromCapture(HWND hwnd, bool exclude) {
    if (!_affinityLooked) {
      _affinityLooked = true;
      try {
        _affinity = DynamicLibrary.open('user32.dll')
            .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('SetWindowDisplayAffinity');
      } catch (_) {}
    }
    final f = _affinity;
    if (f == null) return false;
    // WDA_EXCLUDEFROMCAPTURE = 0x11, WDA_NONE = 0.
    return f(hwnd.address, exclude ? 0x11 : 0) != 0;
  }

  /// Attend que Windows ait recomposé l'écran (une image).
  static void waitComposition() {
    try {
      DwmFlush();
    } catch (_) {}
  }

  /// Capture une zone de l'écran **déjà réduite** à [tw] × [th] par Windows
  /// (bien plus rapide que de tout copier puis réduire) : pixels BGRA (le
  /// canal alpha n'est pas rempli).
  static Uint8List captureScaled(int x, int y, int w, int h, int tw, int th) {
    final screen = GetDC(null);
    final mem = CreateCompatibleDC(screen);
    final bmp = CreateCompatibleBitmap(screen, tw, th);
    final old = SelectObject(mem, HGDIOBJ(bmp));
    final bi = calloc<BITMAPINFO>();
    final buf = calloc<Uint8>(tw * th * 4);
    try {
      if (tw == w && th == h) {
        BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY);
      } else {
        SetStretchBltMode(mem, HALFTONE);
        StretchBlt(mem, 0, 0, tw, th, screen, x, y, w, h, SRCCOPY);
      }
      bi.ref.bmiHeader
        ..biSize = sizeOf<BITMAPINFOHEADER>()
        ..biWidth = tw
        ..biHeight =
            -th // de haut en bas
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = BI_RGB;
      GetDIBits(mem, bmp, 0, th, buf, bi, DIB_RGB_COLORS);
      return Uint8List.fromList(buf.asTypedList(tw * th * 4));
    } finally {
      SelectObject(mem, old);
      DeleteObject(HGDIOBJ(bmp));
      DeleteDC(mem);
      ReleaseDC(null, screen);
      calloc.free(bi);
      calloc.free(buf);
    }
  }

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
  /// Nexo ne marche pas.
  static void voiceTyping() => using((a) {
    const keys = [(VK_LWIN, false), (VIRTUAL_KEY(0x48), false), (VIRTUAL_KEY(0x48), true), (VK_LWIN, true)];
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

  /// Depuis combien de secondes personne n'a touché ni la souris ni le
  /// clavier (sur tout le PC).
  static int idleSeconds() {
    final p = calloc<LASTINPUTINFO>();
    try {
      p.ref.cbSize = sizeOf<LASTINPUTINFO>();
      if (!GetLastInputInfo(p)) return 0;
      final ms = (GetTickCount() - p.ref.dwTime) & 0xFFFFFFFF;
      return ms ~/ 1000;
    } finally {
      calloc.free(p);
    }
  }

  /// Rectangle de la fenêtre au premier plan (x, y, largeur, hauteur).
  static (int, int, int, int)? foregroundRect() {
    final r = calloc<RECT>();
    try {
      final h = GetForegroundWindow();
      if (!GetWindowRect(h, r).value) return null;
      final w = r.ref.right - r.ref.left, hh = r.ref.bottom - r.ref.top;
      if (w <= 0 || hh <= 0) return null;
      return (r.ref.left, r.ref.top, w, hh);
    } finally {
      calloc.free(r);
    }
  }

  /// La fenêtre au premier plan couvre tout un écran (jeu, vidéo en grand) :
  /// Nexo se fait discret.
  static bool foregroundFullscreen() {
    final f = foregroundRect();
    if (f == null) return false;
    final t = foregroundTitle();
    if (t.isEmpty || t == 'Program Manager') return false;
    for (final m in monitors()) {
      if (f.$1 <= m.$1 && f.$2 <= m.$2 && f.$1 + f.$3 >= m.$1 + m.$3 && f.$2 + f.$4 >= m.$2 + m.$4) return true;
    }
    return false;
  }

  /// Titre de la fenêtre au premier plan (« Document1 - Word »).
  /// Le programme de la fenêtre au premier plan (« RobloxPlayerBeta.exe »).
  static String foregroundExe() {
    try {
      return _exeOf(GetForegroundWindow());
    } catch (_) {
      return '';
    }
  }

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

  // ---------- Clavier et souris (Nexo pilote, dictée) ----------

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
  static void releaseModifiers() => _keys([
    for (final vk in const [0x10, 0x11, 0x12, 0x5B, 0x5C])
      if (down(vk)) (vk, true),
  ]);

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
            ..dwFlags = j == 1 ? KEYBD_EVENT_FLAGS(KEYEVENTF_UNICODE | KEYEVENTF_KEYUP) : KEYEVENTF_UNICODE;
        }
      }
    }
    SendInput(units.length * 2, inputs, sizeOf<INPUT>());
  });

  static const _named = {
    'ctrl': 0x11,
    'control': 0x11,
    'alt': 0x12,
    'shift': 0x10,
    'maj': 0x10,
    'win': 0x5B,
    'windows': 0x5B,
    'enter': 0x0D,
    'entree': 0x0D,
    'entrée': 0x0D,
    'tab': 0x09,
    'esc': 0x1B,
    'echap': 0x1B,
    'échap': 0x1B,
    'escape': 0x1B,
    'space': 0x20,
    'espace': 0x20,
    'backspace': 0x08,
    'retour': 0x08,
    'delete': 0x2E,
    'suppr': 0x2E,
    'del': 0x2E,
    'home': 0x24,
    'end': 0x23,
    'fin': 0x23,
    'pageup': 0x21,
    'pagedown': 0x22,
    'up': 0x26,
    'haut': 0x26,
    'down': 0x28,
    'bas': 0x28,
    'left': 0x25,
    'gauche': 0x25,
    'right': 0x27,
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

  // ---------- Nexo agit : souris visible, glisser, fenêtres ----------

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

  /// Déplace la souris de ([dx], [dy]) depuis là où elle est (pavé tactile
  /// du téléphone).
  static void mouseBy(int dx, int dy) => using((a) {
    final input = a<INPUT>();
    input.ref.type = INPUT_MOUSE;
    input.ref.Anonymous.mi
      ..dwFlags = MOUSEEVENTF_MOVE
      ..dx = dx
      ..dy = dy;
    SendInput(1, input, sizeOf<INPUT>());
  });

  /// Un clic là où est la souris.
  static void clickHere({bool right = false}) {
    _mouse(right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN);
    _mouse(right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP);
  }

  /// Verrouille la session (comme Windows + L).
  static bool lock() => LockWorkStation().value;

  /// Met le PC en veille (pas en veille prolongée).
  static bool sleep() {
    try {
      final f = DynamicLibrary.open('powrprof.dll')
          .lookupFunction<Uint8 Function(Uint8, Uint8, Uint8), int Function(int, int, int)>('SetSuspendState');
      return f(0, 0, 0) != 0;
    } catch (_) {
      return false;
    }
  }

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
        if (t.trim().isNotEmpty && t != 'Nexo' && t != 'Program Manager') {
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

  /// Chemin complet du programme au premier plan (« C:\\…\\steamapps\\common\\… »).
  static String foregroundPath() {
    try {
      return _pathOf(GetForegroundWindow());
    } catch (_) {
      return '';
    }
  }

  static String _exeOf(HWND h) => _pathOf(h).split(RegExp(r'[\\/]')).last;

  static String _pathOf(HWND h) => using((a) {
    final pidPtr = a<Uint32>();
    GetWindowThreadProcessId(h, pidPtr);
    final proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pidPtr.value).value;
    if (proc.address == 0) return '';
    try {
      final buf = wsalloc(1024, a);
      final size = a<Uint32>()..value = 1024;
      if (!QueryFullProcessImageName(proc, PROCESS_NAME_WIN32, buf, size).value) return '';
      return buf.toDartString();
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
      'volup' => VK_VOLUME_UP,
      'voldown' => VK_VOLUME_DOWN,
      'mute' => VK_VOLUME_MUTE,
      _ => VK_MEDIA_PLAY_PAUSE,
    };
    // Le volume monte ou descend de 10 % (5 crans de 2 %).
    final times = key == 'volup' || key == 'voldown' ? 5 : 1;
    for (var i = 0; i < times; i++) {
      _keys([(vk, false), (vk, true)]);
    }
  }
}
