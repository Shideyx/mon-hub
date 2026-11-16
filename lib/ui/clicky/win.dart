import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Petits appels Windows pour « Clicky partout » : clavier et souris de tout
/// le système, écrans, capture, et placement de la fenêtre de Clicky.
class Win {
  Win._();

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
}
