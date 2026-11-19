import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:material_ui/material_ui.dart';

import 'core/account_sync.dart';
import 'core/phone_link.dart';
import 'core/browser_link.dart';
import 'core/work_backup.dart';
import 'core/screen_time.dart';
import 'ui/phone_link_page.dart';
import 'ui/clicky/win.dart';
import 'core/certificates.dart';
import 'core/claude_bridge.dart';
import 'core/desktop_widgets.dart';
import 'core/error_log.dart';
import 'modules/claude/claude_module.dart';
import 'modules/discord/discord_module.dart';
import 'modules/discord/discord_phone.dart';
import 'modules/youtube/youtube_module.dart';
import 'core/hub_controller.dart';
import 'core/module_registry.dart';
import 'core/module_store.dart';
import 'core/nav.dart';
import 'core/notifications.dart';
import 'core/session.dart';
import 'core/shortcuts.dart';
import 'core/updater.dart';
import 'ui/app_shell.dart';
import 'core/hub_home.dart';
import 'ui/clicky/assistant_view.dart';
import 'ui/clicky/clicky.dart';
import 'ui/clicky/clicky_desktop.dart';
import 'ui/clicky/course_page.dart';
import 'ui/clicky/tutorial.dart';
import 'ui/google_welcome.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';
import 'ui/update_screen.dart';
import 'ui/widget_window.dart';
import 'ui/search_page.dart';

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

/// iPhone : « une nouvelle version est prête » (une fois par version).
Future<void> _phoneUpdateNotice(NotificationCenter n) async {
  await Future<void>.delayed(const Duration(seconds: 20));
  final tag = await Updater.phoneUpdate();
  if (tag == null) return;
  final key = 'iphone.maj.$tag';
  if (ModuleStore.global.getBool(key) == true) return;
  await ModuleStore.global.setBool(key, true);
  await n.post(
    HubNotification(
      id: 'maj-iphone:$tag',
      title: '📲 Mon Hub $tag est prête pour ton iPhone',
      body: 'Sur ton PC : Réglages → Mes appareils → Ajouter mon iPhone → Télécharger, puis Sideloadly. '
          'Tes données restent sur l\'iPhone.',
    ),
  );
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
    WorkBackup.instance.stop();
    ScreenTime.instance.stop();
    unawaited(BrowserLink.instance.stop());
    AccountSync.instance
      ..onApplied = null
      ..onNotice = null
      ..stop();
    DiscordPhone.instance.stop();
    _notifications?.dispose();
    unawaited(_bridge?.stop());
    unawaited(PhoneLink.instance.stop());
    _hub = null;
    _notifications = null;
    _bridge = null;
    _openFor = null;
  }

  static Future<void> _removeHologramFiles() async {
    final base = ClaudeBridge.folder;
    if (base == null) return;
    try {
      final d = Directory('$base${Platform.pathSeparator}realite-augmentee');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
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
        // Le compte sur tous tes appareils (copie chiffrée dans ton Google
        // Drive) : ce qui change ailleurs arrive ici tout seul.
        AccountSync.instance
          ..onApplied = (keys) {
            if (keys.any((k) => k.startsWith('p:hub.'))) hub.reload();
            if (keys.any((k) => k.startsWith('f:') || k.startsWith('p:mod.claude.'))) {
              unawaited(ClickyController.instance.loadMemory());
              unawaited(ClickyController.instance.shareOptions());
            }
          }
          ..onNotice = (title, body) {
            unawaited(
              n.post(
                HubNotification(
                  id: 'sync:${DateTime.now().millisecondsSinceEpoch}',
                  title: title,
                  body: body,
                  moduleId: 'drive',
                ),
              ),
            );
          }
          ..start();
        // Tes travaux (Documents, Bureau) copiés dans ton Drive.
        WorkBackup.instance.start();
        // L'extension Chrome de Mon Hub (Clicky dans le navigateur).
        unawaited(BrowserLink.instance.start());
        // Les hologrammes ont été retirés (v1.60) : on efface la « vision des
        // mains » qu'ils avaient téléchargée (~ 30 Mo), une fois.
        unawaited(_removeHologramFiles());
        // Le téléphone relié au PC : fichiers, presse-papier, télécommande.
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          PhoneLinkPage.wire((title, body) {
            final id = 'tel:${DateTime.now().millisecondsSinceEpoch}';
            unawaited(n.post(HubNotification(id: id, title: title, body: body)));
          });
          unawaited(PhoneLink.instance.start());
        }
        // Temps d'écran et mode jeu : un coup d'œil à la fenêtre au premier
        // plan toutes les 15 s (sur ce PC seulement).
        if (Win.supportedHere) {
          final st = ScreenTime.instance;
          st.alert = (title, body) {
            unawaited(n.post(HubNotification(id: 'temps:${DateTime.now().millisecondsSinceEpoch}', title: title, body: body)));
          };
          st
            ..onTick = () async {
              try {
                final exe = Win.foregroundExe(), title = Win.foregroundTitle();
                await ScreenTime.instance.tick(exe: exe, title: title, idleSeconds: Win.idleSeconds());
                final end = GameMode.instance.tick(exe: exe, fullscreen: Win.foregroundFullscreen());
                if (end != null) {
                  unawaited(n.post(HubNotification(id: 'jeu:${DateTime.now().millisecondsSinceEpoch}', title: '🎮 Partie terminée', body: end)));
                }
              } catch (_) {}
            }
            ..start();
        }
        // iPhone : pas de mise à jour automatique (Apple l'interdit hors App
        // Store) : on prévient quand une nouvelle version est prête.
        if (Platform.isIOS) unawaited(_phoneUpdateNotice(n));
        // Ctrl + Espace (ici) ou Ctrl + Alt + Espace (partout) : la recherche.
        HubHome.instance.onSearchText = (text) => unawaited(SearchPage.show(text));
        // Première ouverture du compte : la visite guidée de Clicky.
        unawaited(_tutorial());
        unawaited(n.start());
        // Appels Discord reçus dans Mon Hub (Discord officiel caché).
        DiscordPhone.allowed = true;
        DiscordPhone.instance.notifications = n;
        // « Menu » ferme aussi la fenêtre d'appel Discord (l'appel continue).
        final phone = DiscordPhone.instance;
        HubHome.instance
          ..closers.add(() {
            if (phone.shown) phone.hide();
          })
          ..awayChecks.add(() => phone.active && phone.shown);
        phone.addListener(HubHome.instance.refresh);
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
      navigatorObservers: [HubHome.instance.observer],
      // Clicky, le compagnon Claude, au-dessus de toutes les pages.
      builder: (context, child) => UpdateGate(
        child: ClickyLayer(
          hub: hub,
          // Discord gardé ouvert en fond pour recevoir les appels.
          // Le bouton « Menu » (toujours visible hors de l'accueil) et le
          // petit écran YouTube, au-dessus de tout.
          child: HubHomeLayer(
            enabled: hub != null,
            child: YouTubeMiniLayer(
              child: DiscordPhoneLayer(
                // Les propositions de l'assistant personnel (en bas à gauche).
                child: AssistantLayer(
                  enabled: hub != null,
                  // La pastille « Clicky écoute le cours » (en haut, au milieu).
                  child: CourseRecLayer(child: child ?? const SizedBox.shrink()),
                ),
              ),
            ),
          ),
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
