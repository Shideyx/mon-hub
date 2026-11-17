#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

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

  // « hub.exe --clicky » : la petite fenêtre transparente de Clicky qui
  // suit la souris au-dessus de toutes les applis (lancée par Mon Hub).
  bool clicky = false;
  // « hub.exe --widget=musique » : un widget de l'accueil détaché sur le
  // bureau, dans sa petite fenêtre.
  std::wstring widget;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--clicky") clicky = true;
    if (arg.rfind("--widget=", 0) == 0) {
      widget.clear();
      for (const char c : arg.substr(9)) {
        widget.push_back(static_cast<wchar_t>(static_cast<unsigned char>(c)));
      }
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
  if (!window.Create(clicky ? L"Clicky" : L"Mon Hub", origin, size)) {
    return EXIT_FAILURE;
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
