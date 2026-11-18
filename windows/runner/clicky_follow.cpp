#include "clicky_follow.h"

namespace clicky_follow {

namespace {

bool g_follow = false;
LONG g_dx = 16;
LONG g_dy = 14;
bool g_has_last = false;
POINT g_last = {0, 0};

// Place la fenêtre à côté du curseur (en restant dans l'écran du curseur).
void MoveToCursor(HWND window) {
  if (!g_follow || !IsWindowVisible(window)) {
    return;
  }
  POINT cursor;
  if (!GetCursorPos(&cursor)) {
    return;
  }
  if (g_has_last && cursor.x == g_last.x && cursor.y == g_last.y) {
    return;
  }
  g_has_last = true;
  g_last = cursor;

  RECT rect;
  if (!GetWindowRect(window, &rect)) {
    return;
  }
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  LONG x = cursor.x + g_dx;
  LONG y = cursor.y + g_dy;

  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST),
                     &info)) {
    const RECT& screen = info.rcMonitor;
    if (x + width > screen.right) {
      x = screen.right - width;
    }
    if (y + height > screen.bottom) {
      y = screen.bottom - height;
    }
    if (x < screen.left) {
      x = screen.left;
    }
    if (y < screen.top) {
      y = screen.top;
    }
  }
  if (x == rect.left && y == rect.top) {
    return;
  }
  SetWindowPos(window, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_NOOWNERZORDER | SWP_NOSENDCHANGING);
}

}  // namespace

void Attach(HWND window) {
  RAWINPUTDEVICE device = {};
  device.usUsagePage = 0x01;  // Generic Desktop
  device.usUsage = 0x02;      // Mouse
  device.dwFlags = RIDEV_INPUTSINK;
  device.hwndTarget = window;
  RegisterRawInputDevices(&device, 1, sizeof(device));
}

bool Handle(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kClickyFollowMessage) {
    g_follow = wparam != 0;
    const DWORD packed = static_cast<DWORD>(lparam);
    g_dx = static_cast<SHORT>(LOWORD(packed));
    g_dy = static_cast<SHORT>(HIWORD(packed));
    g_has_last = false;
    MoveToCursor(window);
    return true;
  }
  if (message == WM_INPUT) {
    MoveToCursor(window);
    // WM_INPUT doit aussi passer par Windows (nettoyage des données).
    return false;
  }
  return false;
}

}  // namespace clicky_follow
