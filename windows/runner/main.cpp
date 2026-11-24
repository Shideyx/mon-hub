#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Marque posée sur la fenêtre principale : une deuxième copie la retrouve
// pour la ramener devant au lieu de s'ouvrir à côté.
constexpr const wchar_t kMainWindowProp[] = L"MonHubFenetrePrincipale";

BOOL CALLBACK FindMainWindow(HWND hwnd, LPARAM out) {
  if (::GetPropW(hwnd, kMainWindowProp) == nullptr) return TRUE;
  *reinterpret_cast<HWND*>(out) = hwnd;
  return FALSE;
}

// Une seule copie à la fois (fenêtre principale, chaque widget) : avant, deux
// Mon Hub pouvaient tourner ensemble (deux zips décompressés, double-clic
// pendant qu'il démarrait…) et tout arrivait en double : notifications,
// assistant, Discord caché. [wait] : la copie d'avant est en train de se
// fermer (mise à jour, installation) ; on attend qu'elle parte (15 s au plus).
bool TakeSingleInstance(const std::wstring& name, bool wait) {
  const int tries = wait ? 75 : 1;
  for (int i = 0; i < tries; ++i) {
    HANDLE mutex = ::CreateMutexW(nullptr, TRUE, name.c_str());
    const DWORD error = ::GetLastError();
    if (mutex != nullptr && error != ERROR_ALREADY_EXISTS) {
      // Gardé ouvert jusqu'à la fin du programme (Windows le libère seul).
      return true;
    }
    if (mutex != nullptr) ::CloseHandle(mutex);
    if (wait) ::Sleep(200);
  }
  return false;
}

// Ramène devant la fenêtre de la copie déjà ouverte.
void ShowExistingMainWindow() {
  HWND found = nullptr;
  ::EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&found));
  if (found == nullptr) return;
  if (::IsIconic(found)) {
    ::ShowWindow(found, SW_RESTORE);
  } else {
    ::ShowWindow(found, SW_SHOW);
  }
  ::SetForegroundWindow(found);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(command_line_arguments);

  // « hub.exe --clicky » : la petite fenêtre transparente de Nexo qui
  // suit la souris au-dessus de toutes les applis (lancée par Mon Hub).
  bool clicky = false;
  // « hub.exe --widget=musique » : un widget de l'accueil détaché sur le
  // bureau, dans sa petite fenêtre.
  std::wstring widget;
  // Relancé par Mon Hub lui-même (mise à jour, installation) : l'ancienne
  // copie se ferme, on l'attend.
  bool relaunch = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--clicky") clicky = true;
    if (arg == "--updated" || arg == "--relance") relaunch = true;
    if (arg.rfind("--widget=", 0) == 0) {
      widget.clear();
      for (const char c : arg.substr(9)) {
        widget.push_back(static_cast<wchar_t>(static_cast<unsigned char>(c)));
      }
    }
  }
  // (L'assistant partout a déjà son propre verrou, côté Dart.)
  if (!clicky) {
    const std::wstring lock = widget.empty() ? std::wstring(L"Local\\MonHub.Principal")
                                             : L"Local\\MonHub.Widget." + widget;
    if (!TakeSingleInstance(lock, relaunch)) {
      if (widget.empty()) ShowExistingMainWindow();
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }
  // Chaque widget a sa propre icône dans la barre des tâches (au lieu d'être
  // regroupé avec Mon Hub).
  if (!widget.empty()) {
    const std::wstring app_id = L"fr.erik.hub.widget." + widget;
    ::SetCurrentProcessExplicitAppUserModelID(app_id.c_str());
  }

  FlutterWindow window(project);
  window.SetOverlay(clicky);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (clicky) {
    origin = Win32Window::Point(0, 0);
    size = Win32Window::Size(380, 230);
  } else if (!widget.empty()) {
    origin = Win32Window::Point(80, 80);
    size = Win32Window::Size(460, 380);
  }
  if (!window.Create(clicky ? L"Nexo" : L"Mon Hub", origin, size)) {
    return EXIT_FAILURE;
  }
  if (!clicky && widget.empty()) {
    ::SetPropW(window.GetHandle(), kMainWindowProp, reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1)));
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
