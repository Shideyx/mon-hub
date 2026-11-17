import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core/certificates.dart';
import 'core/claude_bridge.dart';
import 'core/desktop_widgets.dart';
import 'core/error_log.dart';
import 'modules/claude/claude_module.dart';
import 'modules/discord/discord_module.dart';
import 'modules/discord/discord_phone.dart';
import 'core/hub_controller.dart';
import 'core/module_registry.dart';
import 'core/module_store.dart';
import 'core/nav.dart';
import 'core/notifications.dart';
import 'core/session.dart';
import 'core/shortcuts.dart';
import 'core/updater.dart';
import 'ui/app_shell.dart';
import 'ui/clicky/clicky.dart';
import 'ui/clicky/clicky_desktop.dart';
import 'ui/clicky/tutorial.dart';
import 'ui/google_welcome.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';
import 'ui/update_screen.dart';
import 'ui/widget_window.dart';

Future<void> main(List<String> args) async {
  // « hub.exe --clicky » : Clicky partout (Windows), voir clicky_desktop.dart.
  if (args.contains('--clicky')) return runClickyDesktop();
  // « hub.exe --widget=musique » : un widget détaché sur le bureau.
  final widget = args.where((a) => a.startsWith('--widget=')).firstOrNull;
  if (widget != null) return runWidgetWindow(widget.substring(9));
  WidgetsFlutterBinding.ensureInitialized();
  // Journal des erreurs (sur le PC) et garde-fous : une erreur ne casse
  // plus tout l'écran.
  ErrorLog.install('Mon Hub');
  // Certificats de Windows (antivirus, réseau…) et de Mozilla : plus
  // d'erreur « CERTIFICATE_VERIFY_FAILED ».
  await TrustedCertificates.install();
  await ModuleStore.init();
  AppSession.instance.restore();
  // Raccourcis Bureau / menu Démarrer, créés ou réparés tout seuls.
  unawaited(AppShortcuts.ensure().catchError((Object _) {}));
  // Mises à jour automatiques : pause + écran de téléchargement, puis
  // redémarrage sur la nouvelle version.
  final updater = Updater.instance..beforeInstall = ClickyDesktop.stop;
  var paused = false;
  updater.addListener(() {
    // Clicky partout se met en pause pendant la mise à jour.
    if (updater.showing && !paused) {
      paused = true;
      unawaited(ClickyDesktop.stop());
    } else if (!updater.showing && paused) {
      paused = false;
      unawaited(ClickyDesktop.launch());
    }
  });
  updater.start();
  // Fichiers de l'ancienne version mis de côté pendant la mise à jour.
  unawaited(Updater.cleanup());
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
    DiscordPhone.instance.stop();
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
        // Première ouverture du compte : la visite guidée de Clicky.
        unawaited(_tutorial());
        unawaited(n.start());
        // Appels Discord reçus dans Mon Hub (Discord officiel caché).
        DiscordPhone.allowed = true;
        DiscordPhone.instance.notifications = n;
        hub.available.whereType<DiscordModule>().firstOrNull?.syncPhone();
        // Quand Claude Code (Clicky) veut agir, Mon Hub demande la permission.
        ClaudeBridge.confirm = ClickyController.instance.confirmAction;
        // Les outils de Clicky (contrôle du PC, réparation du micro) aussi
        // pour Claude Code.
        ClaudeBridge.appTools = () => ClickyController.instance.localTools;
        // Alertes de Clicky (agent terminé…).
        ClickyController.instance.notify = (title, body) => n.post(
          HubNotification(
            id: 'clicky:${DateTime.now().millisecondsSinceEpoch}',
            title: title,
            body: body,
            moduleId: 'claude',
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _tutorial() async {
    if (widget.controller != null) return;
    var brain = false;
    if (!ClickyTutorial.seen) {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 20));
      if (ctx == null || !ctx.mounted || ClickyTutorial.seen) return;
      await ClickyTutorial.show(ctx, onBrain: () {
        brain = true;
        final c = hubNavigatorKey.currentContext;
        if (c != null) ClaudeModule.showSettings(c);
      });
    } else {
      // Compte déjà là : on laisse l'appli s'ouvrir tranquillement.
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    // Puis Clicky demande le compte Google (Drive, Docs, agenda), une fois.
    // S'il vient d'ouvrir les réglages du cerveau, ce sera au prochain
    // démarrage.
    if (brain) return;
    final ctx = await hubDialogContext(timeout: const Duration(seconds: 20));
    if (ctx != null && ctx.mounted) await GoogleWelcome.maybeShow(ctx);
  }

  /// Windows : Clicky au-dessus de tout l'écran (petit programme à part).
  Future<void> _startClicky() async {
    // Clicky est un bonus : s'il échoue, le reste de l'appli continue.
    try {
      // Réglages de ce compte partagés avec Clicky partout, qu'on relance
      // pour qu'il reprenne le bon compte.
      await ClickyController.instance.shareOptions();
      await ClickyDesktop.restart();
      // S'il se ferme tout seul (plantage), il est relancé.
      ClickyDesktop.watch();
      // Les widgets laissés sur le bureau se rouvrent.
      unawaited(DesktopWidgets.instance.launchAll());
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
      builder: (context, child) => UpdateGate(
        child: ClickyLayer(
          hub: hub,
          // Discord gardé ouvert en fond pour recevoir les appels.
          child: DiscordPhoneLayer(child: child ?? const SizedBox.shrink()),
        ),
      ),
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
