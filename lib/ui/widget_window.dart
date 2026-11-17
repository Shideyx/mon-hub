import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';
import 'package:win32/win32.dart';

import '../core/certificates.dart';
import '../core/desktop_widgets.dart';
import '../core/error_log.dart';
import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/module_registry.dart';
import '../core/module_store.dart';
import '../core/nav.dart';
import '../core/session.dart';
import '../core/windows_look.dart';
import 'theme.dart';

/// Point d'entrée de `hub.exe --widget=<module>` : un widget de l'accueil
/// tout seul dans sa petite fenêtre, sur le bureau.
Future<void> runWidgetWindow(String id) async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorLog.install('Widget $id');
  final ServerSocket lock;
  try {
    lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, DesktopWidgets.port(id));
  } catch (_) {
    exit(0); // déjà ouvert
  }
  await TrustedCertificates.install();
  await ModuleStore.init();
  AppSession.instance.restore();
  if (AppSession.instance.current == null) exit(0);
  final hub = HubController(buildModules());
  final module = hub.available.where((m) => m.id == id).firstOrNull;
  if (module == null || !DesktopWidgets.instance.ids.contains(id)) exit(0);
  lock.listen((sock) {
    utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) {
      final cmd = line.trim();
      if (cmd == 'quit') exit(0);
      if (cmd == 'front') _WidgetWindowState.bringToFront();
    }, onError: (_) {});
  });
  runApp(_WidgetWindow(module: module));
}

class _WidgetWindow extends StatefulWidget {
  const _WidgetWindow({required this.module});
  final HubModule module;

  @override
  State<_WidgetWindow> createState() => _WidgetWindowState();
}

class _WidgetWindowState extends State<_WidgetWindow> {
  HubModule get m => widget.module;
  int _refresh = 0;
  bool _onTop = false;
  Timer? _timer;
  Timer? _saver;
  (int, int, int, int)? _lastRect;

  static HWND? _hwnd;

  static void bringToFront() {
    final h = _hwnd;
    if (h == null) return;
    ShowWindow(h, SW_RESTORE);
    SetForegroundWindow(h);
  }

  @override
  void initState() {
    super.initState();
    // Les données se rafraîchissent toutes les 3 minutes.
    _timer = Timer.periodic(const Duration(minutes: 3), (_) => setState(() => _refresh++));
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _saver?.cancel();
    super.dispose();
  }

  /// Titre, place gardée, barre de titre assortie ; la place est notée
  /// quand tu déplaces la fenêtre.
  void _place() {
    final h = _hwnd = WindowsLook.mainWindow();
    if (h == null) return;
    using((a) => SetWindowText(h, '${m.name} — Mon Hub'.toPcwstr(allocator: a)));
    final r = DesktopWidgets.savedRect(m.id);
    if (r != null) {
      final sized = r.$3 > 120 && r.$4 > 100;
      SetWindowPos(
        h,
        null,
        r.$1,
        r.$2,
        sized ? r.$3 : 0,
        sized ? r.$4 : 0,
        SET_WINDOW_POS_FLAGS(SWP_NOZORDER | SWP_NOACTIVATE | (sized ? 0 : SWP_NOSIZE)),
      );
    }
    WindowsLook.applyTitleBar(Theme.of(context).brightness);
    _saver = Timer.periodic(const Duration(seconds: 2), (_) {
      final rect = calloc<RECT>();
      try {
        if (!GetWindowRect(h, rect).value || IsIconic(h)) return;
        final now = (rect.ref.left, rect.ref.top, rect.ref.right - rect.ref.left, rect.ref.bottom - rect.ref.top);
        if (now != _lastRect) {
          _lastRect = now;
          unawaited(DesktopWidgets.saveRect(m.id, now));
        }
      } finally {
        calloc.free(rect);
      }
    });
  }

  void _toggleTop() {
    final h = _hwnd;
    if (h == null) return;
    setState(() => _onTop = !_onTop);
    SetWindowPos(
      h,
      _onTop ? HWND_TOPMOST : HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SET_WINDOW_POS_FLAGS(SWP_NOMOVE | SWP_NOSIZE),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSession.instance,
    builder: (context, _) => MaterialApp(
      title: '${m.name} — Mon Hub',
      navigatorKey: hubNavigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: AppSession.instance.themeMode,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) {
          final text = Theme.of(context).textTheme;
          return Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(6)),
                        child: Icon(m.icon, color: Colors.white, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(m.name, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      IconButton(
                        tooltip: _onTop ? 'Ne plus garder devant' : 'Garder devant les autres fenêtres',
                        icon: Icon(_onTop ? Icons.push_pin_rounded : Icons.push_pin_outlined, size: 18),
                        onPressed: _toggleTop,
                      ),
                      IconButton(
                        tooltip: 'Rafraîchir',
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        onPressed: () => setState(() => _refresh++),
                      ),
                      IconButton(
                        tooltip: 'Ouvrir en grand',
                        icon: const Icon(Icons.open_in_full_rounded, size: 18),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: m.buildPage)),
                      ),
                      IconButton(
                        tooltip: 'Remettre dans Mon Hub',
                        icon: const Icon(Icons.close_fullscreen_rounded, size: 18),
                        onPressed: () async {
                          await DesktopWidgets.instance.attach(m.id);
                          exit(0);
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: KeyedSubtree(key: ValueKey(_refresh), child: Builder(builder: m.buildSummary)),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
