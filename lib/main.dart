import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core/claude_bridge.dart';
import 'core/hub_controller.dart';
import 'core/module_registry.dart';
import 'core/module_store.dart';
import 'core/nav.dart';
import 'core/notifications.dart';
import 'core/session.dart';
import 'core/shortcuts.dart';
import 'ui/app_shell.dart';
import 'ui/clicky/clicky.dart';
import 'ui/clicky/clicky_desktop.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

Future<void> main(List<String> args) async {
  // « hub.exe --clicky » : Clicky partout (Windows), voir clicky_desktop.dart.
  if (args.contains('--clicky')) return runClickyDesktop();
  WidgetsFlutterBinding.ensureInitialized();
  await ModuleStore.init();
  AppSession.instance.restore();
  // Raccourcis Bureau / menu Démarrer, créés ou réparés tout seuls.
  unawaited(AppShortcuts.ensure().catchError((Object _) {}));
  runApp(const HubApp());
}

/// Racine de l'appli : page de connexion, puis le hub du compte connecté.
class HubApp extends StatefulWidget {
  /// [controller] et [notifications] servent aux tests (pas de connexion).
  const HubApp({super.key, this.controller, this.notifications});

  final HubController? controller;
  final NotificationCenter? notifications;

  @override
  State<HubApp> createState() => _HubAppState();
}

class _HubAppState extends State<HubApp> {
  final session = AppSession.instance;
  HubController? _hub;
  NotificationCenter? _notifications;
  ClaudeBridge? _bridge;
  String? _openFor;

  @override
  void initState() {
    super.initState();
    session.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    session.removeListener(_sync);
    _close();
    super.dispose();
  }

  void _close() {
    _notifications?.dispose();
    unawaited(_bridge?.stop());
    _hub = null;
    _notifications = null;
    _bridge = null;
    _openFor = null;
  }

  /// Ouvre (ou ferme) le hub quand on se connecte / se déconnecte.
  void _sync() {
    if (widget.controller != null) return;
    final login = session.current?.login;
    if (login != _openFor) {
      _close();
      if (login != null) {
        final hub = HubController(buildModules());
        final n = NotificationCenter(hub);
        final b = ClaudeBridge(hub);
        _hub = hub;
        _notifications = n;
        _bridge = b;
        _openFor = login;
        // Laisse l'appli Claude (PC) lire et agir dans Mon Hub.
        unawaited(b.start().then((_) => _startClicky()));
        unawaited(n.start());
        // Quand Claude Code (Clicky) veut agir, Mon Hub demande la permission.
        ClaudeBridge.confirm = ClickyController.instance.confirmAction;
        // Alertes de Clicky (agent terminé…).
        ClickyController.instance.notify = (title, body) => n.show(
          HubNotification(
            id: 'clicky:${DateTime.now().millisecondsSinceEpoch}',
            title: title,
            body: body,
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  /// Windows : Clicky au-dessus de tout l'écran (petit programme à part).
  Future<void> _startClicky() async {
    // Clicky est un bonus : s'il échoue, le reste de l'appli continue.
    try {
      // Réglages de ce compte partagés avec Clicky partout, qu'on relance
      // pour qu'il reprenne le bon compte.
      await ClickyController.instance.shareOptions();
      await ClickyDesktop.restart();
    } catch (e) {
      debugPrint('Clicky : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.controller ?? _hub;
    final n = widget.notifications ?? _notifications;
    return MaterialApp(
      title: 'Mon Hub',
      navigatorKey: hubNavigatorKey,
      // Clicky, le compagnon Claude, au-dessus de toutes les pages.
      builder: (context, child) => ClickyLayer(hub: hub, child: child ?? const SizedBox.shrink()),
      debugShowCheckedModeBanner: false,
      themeMode: session.themeMode,
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: hub == null || n == null
          ? const LoginPage()
          : AppShell(key: ValueKey(_openFor), controller: hub, notifications: n),
    );
  }
}
