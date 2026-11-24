import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:material_ui/material_ui.dart';

import 'core/account_sync.dart';
import 'core/camera_guard.dart';
import 'core/self_repair.dart';
import 'core/perf.dart';
import 'core/online/clicky_chat.dart';
import 'core/online/online.dart';
import 'core/online/spaces.dart';
import 'core/phone_link.dart';
import 'core/browser_link.dart';
import 'core/work_backup.dart';
import 'core/screen_time.dart';
import 'ui/clicky/live_captions.dart';
import 'ui/clicky/senses.dart';
import 'ui/clicky/pc_watch.dart';
import 'ui/clicky/watchers.dart';
import 'ui/clicky/interests.dart';
import 'ui/clicky/jarvis.dart' show FocusMode;
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
  // « hub.exe --clicky » : Smily partout (Windows), voir clicky_desktop.dart.
  if (args.contains('--clicky')) return runClickyDesktop();
  // « hub.exe --widget=musique » : un widget détaché sur le bureau.
  final widget = args.where((a) => a.startsWith('--widget=')).firstOrNull;
  // « hub.exe --widget=soustitres » : les sous-titres en direct du son du PC.
  if (widget == '--widget=${LiveCaptions.id}') return runCaptionsWindow();
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
    // Smily partout se met en pause pendant la mise à jour.
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

/// Une fois : « Smily peut maintenant voir ton écran et entendre ton PC ».
Future<void> _announceSenses(NotificationCenter n) async {
  const key = 'app.sens.annonce';
  if (ModuleStore.global.getBool(key) == true) return;
  await Future<void>.delayed(const Duration(seconds: 40));
  await ModuleStore.global.setBool(key, true);
  if (ClickySenses.instance.screenOn) return;
  await n.post(
    HubNotification(
      id: 'sens:annonce',
      title: '👀 Nouveau : Smily peut voir ton écran et entendre ton PC',
      body:
          'En continu, mais tout reste sur ton PC (jamais tes messages, ta banque ni pendant un appel). '
          'À allumer dans Réglages de Smily → Ses yeux et ses oreilles.',
      moduleId: 'claude',
    ),
  );
}

/// iPhone : « une nouvelle version est prête » (une fois par version).
Future<void> _phoneUpdateNotice(NotificationCenter n) async {
  await Future<void>.delayed(const Duration(seconds: 20));
  final tag = await Updater.phoneUpdate();
  if (tag == null) return;
  final key = 'iphone.maj.$tag';
  if (ModuleStore.global.getBool(key) == true) return;
  await ModuleStore.global.setBool(key, true);
  if (Platform.isAndroid) {
    await n.post(
      HubNotification(
        id: 'maj-android:$tag',
        title: '📲 Mon Hub $tag est prête',
        body:
            'Télécharge MonHub-Android.apk sur la page des versions de Mon Hub (GitHub → Releases), puis ouvre-le pour '
            'mettre à jour. Tes données restent là.',
      ),
    );
    return;
  }
  await n.post(
    HubNotification(
      id: 'maj-iphone:$tag',
      title: '📲 Mon Hub $tag est prête pour ton iPhone',
      body:
          'Sur ton PC : Réglages → Mes appareils → Ajouter mon iPhone → Télécharger, puis Sideloadly. '
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
    NotificationCenter.onAny = null;
    // Mon Hub en ligne : la session reste gardée pour ce compte.
    Online.instance.removeListener(_onlineChanged);
    Spaces.instance
      ..onMessage = null
      ..stop();
    _spacesOn = false;
    unawaited(Online.instance.close());
    unawaited(ClickySenses.instance.stop());
    PcWatch.instance.stop();
    Watchers.instance.stop();
    ArtistWatch.instance.stop();
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

  /// Espaces partagés démarrés (compte en ligne connecté).
  bool _spacesOn = false;

  void _onlineChanged() {
    final on = Online.instance.signedIn;
    if (on && !_spacesOn) {
      _spacesOn = true;
      unawaited(Spaces.instance.start());
    } else if (!on && _spacesOn) {
      _spacesOn = false;
      Spaces.instance.stop();
    }
  }

  /// Mon Hub en ligne : reprend la session du compte, puis les espaces, les
  /// discussions (notification quand on t'écrit) et Smily dans les
  /// discussions (« @clicky », Smily entre eux).
  Future<void> _startOnline(NotificationCenter n) async {
    Online.instance.addListener(_onlineChanged);
    Spaces.instance.onMessage = (space, m) {
      final sp = Spaces.instance;
      final myName = ModuleStore.prefs.getString('hub.name') ?? AppSession.instance.current?.name ?? '';
      unawaited(ClickyChat.instance.handle(space, m, myName: myName));
      if (m.author == sp.me || sp.viewing == space.id) return;
      final who = sp.person(m.author)?.label ?? 'Quelqu\'un';
      final from = m.fromClicky ? 'Smily de $who' : who;
      unawaited(
        n.post(
          HubNotification(
            id: 'espace:${space.id}:${m.id}',
            title: space.isDm ? '💬 $from' : '💬 $from · ${sp.titleOf(space)}',
            body: m.body.length > 300 ? '${m.body.substring(0, 297)}…' : m.body,
          ),
        ),
      );
    };
    try {
      await Online.instance.open();
    } catch (_) {}
    _onlineChanged();
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
          };
        // Le compte sur tous tes appareils : un peu après l'ouverture.
        Perf.later(2, AccountSync.instance.start);
        // Mon Hub en ligne (espaces partagés, discussions, même compte partout).
        Perf.later(1, () => _startOnline(n));
        // Démarrage **étalé** (Perf.later) : avant, tout partait d'un coup à
        // la connexion et les petits PC s'étouffaient. Maintenant chaque
        // service attend son tour (et attend plus longtemps en mode léger).
        // Tes travaux (Documents, Bureau) copiés dans ton Drive : lourd, donc
        // jamais en mode léger.
        if (Perf.heavy) Perf.later(4, WorkBackup.instance.start);
        // L'extension Chrome de Mon Hub (Smily dans le navigateur).
        Perf.later(3, BrowserLink.instance.start);
        // Les hologrammes ont été retirés (v1.60) : on efface la « vision des
        // mains » qu'ils avaient téléchargée (~ 30 Mo), une fois.
        unawaited(_removeHologramFiles());
        // Le téléphone relié au PC : fichiers, presse-papier, télécommande.
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          PhoneLinkPage.wire((title, body) {
            final id = 'tel:${DateTime.now().millisecondsSinceEpoch}';
            unawaited(n.post(HubNotification(id: id, title: title, body: body)));
          });
          Perf.later(5, PhoneLink.instance.start);
        }
        // Temps d'écran et mode jeu : un coup d'œil à la fenêtre au premier
        // plan toutes les 15 s (sur ce PC seulement).
        if (Win.supportedHere) {
          final st = ScreenTime.instance;
          st.alert = (title, body) {
            unawaited(
              n.post(HubNotification(id: 'temps:${DateTime.now().millisecondsSinceEpoch}', title: title, body: body)),
            );
          };
          // Ce qu'il remarque à l'écran ou dans le son devient une idée (avec
          // ton accord) ou une petite pensée.
          final clicky = ClickyController.instance;
          ClickySenses.instance
            ..propose = clicky.proposeIdea
            ..think = ((t) => unawaited(clicky.think(t, aloud: false)))
            ..call = ((name, args) async {
              final tools = clicky.hubTools;
              return tools.where((t) => t.name == name).firstOrNull?.run(args);
            })
            ..busy = (() => FocusMode.instance.active || GameMode.instance.active || clicky.idea != null)
            ..inCall = (() => const {
              PhoneState.ringing,
              PhoneState.calling,
              PhoneState.inCall,
            }.contains(DiscordPhone.instance.state));
          unawaited(_announceSenses(n));
          // Le presse-papier malin et les réactions du PC (téléchargements,
          // captures, clés USB…).
          PcWatch.instance
            ..think = ((t) => unawaited(clicky.think(t, aloud: false)))
            ..warn = ((title, body) {
              unawaited(
                n.post(
                  HubNotification(id: 'arnaque:pc:${DateTime.now().millisecondsSinceEpoch}', title: title, body: body),
                ),
              );
            });
          Perf.later(3, PcWatch.instance.start);
          // Une appli allume la caméra : Smily le dit tout de suite.
          CameraGuard.instance.warn = (title, body) {
            unawaited(
              n.post(HubNotification(id: 'camera:${DateTime.now().millisecondsSinceEpoch}', title: title, body: body)),
            );
            unawaited(clicky.think(body, aloud: false));
          };
          st.onTick = () async {
            try {
              final exe = Win.foregroundExe(), title = Win.foregroundTitle();
              await ScreenTime.instance.tick(exe: exe, title: title, idleSeconds: Win.idleSeconds());
              final full = Win.foregroundFullscreen();
              final end = GameMode.instance.tick(exe: exe, fullscreen: full);
              await PcWatch.instance.tick(
                title: title,
                idle: Win.idleSeconds(),
                diskFreeGb: PcWatch.instance.diskFree(),
              );
              // La garde de la caméra : qui filme, et depuis quand.
              await CameraGuard.instance.tick();
              // Ses yeux et ses oreilles (s'ils sont allumés), sur le PC.
              await ClickySenses.instance.tick(
                exe: exe,
                title: title,
                idle: Win.idleSeconds(),
                fullscreen: full,
                game: GameMode.instance.active,
              );
              if (end != null) {
                unawaited(
                  n.post(
                    HubNotification(
                      id: 'jeu:${DateTime.now().millisecondsSinceEpoch}',
                      title: '🎮 Partie terminée',
                      body: end,
                    ),
                  ),
                );
              }
            } catch (_) {}
          };
          Perf.later(1, st.start);
        }
        // iPhone : pas de mise à jour automatique (Apple l'interdit hors App
        // Store) : on prévient quand une nouvelle version est prête.
        if (Platform.isIOS || Platform.isAndroid) unawaited(_phoneUpdateNotice(n));
        // Ctrl + Espace (ici) ou Ctrl + Alt + Espace (partout) : la recherche.
        HubHome.instance.onSearchText = (text) => unawaited(SearchPage.show(text));
        // Première ouverture du compte : la visite guidée de Smily.
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
        // Quand Claude Code (Smily) veut agir, Mon Hub demande la permission.
        ClaudeBridge.confirm = ClickyController.instance.confirmAction;
        // Les outils de Smily (contrôle du PC, réparation du micro) aussi
        // pour Claude Code.
        ClaudeBridge.appTools = () => ClickyController.instance.localTools;
        // Smily réagit aux nouvelles (une bonne note, un cours annulé…).
        NotificationCenter.onAny = (note) {
          ClickyController.instance.reactTo(note);
          // Un nouveau devoir : il peut le faire pendant ton absence.
          if (note.id.startsWith('devoir:')) {
            unawaited(ClickyController.instance.onNewHomework(note.id, note.title).catchError((Object _) {}));
          }
          // « Préviens-moi quand… » (note, devoir, message de quelqu'un).
          unawaited(Watchers.instance.onNotification(note).catchError((Object _) {}));
          // Une question sur Discord : « je te prépare une réponse ? ».
          final idea = Replies.on && Win.supportedHere && Win.idleSeconds() < 120 ? Replies.ideaFor(note) : null;
          if (idea != null) {
            unawaited(ClickySenses.instance.offer(idea, 'reponse|${note.id}', gap: const Duration(minutes: 20)));
          }
        };
        // La veille : un artiste que tu écoutes sort un nouveau son.
        ArtistWatch.instance
          ..call = ((name, args) async =>
              ClickyController.instance.hubTools.where((t) => t.name == name).firstOrNull?.run(args))
          ..alert = (title, body) {
            unawaited(
              n.post(
                HubNotification(
                  id: 'veille:${DateTime.now().millisecondsSinceEpoch}',
                  title: title,
                  body: body,
                  moduleId: 'music',
                ),
              ),
            );
            unawaited(ClickyController.instance.think(body, aloud: false));
          };
        Perf.later(6, ArtistWatch.instance.start);
        // Les guetteurs : notification + Smily le dit.
        Watchers.instance.alert = (title, body) {
          unawaited(
            n.post(HubNotification(id: 'guetteur:${DateTime.now().millisecondsSinceEpoch}', title: title, body: body)),
          );
          unawaited(ClickyController.instance.think(body));
        };
        Perf.later(2, Watchers.instance.start);
        // Smily se répare tout seul : il relit son journal d'erreurs et
        // corrige ce qu'il sait corriger (micro bloqué, certificats cassés,
        // appli qui fige, disque plein), puis il le dit.
        SelfRepair.instance
          ..call = ((name, args) async =>
              ClickyController.instance.hubTools.where((t) => t.name == name).firstOrNull?.run(args))
          ..restoreData = (() async {
            final sync = AccountSync.instance;
            if (!sync.enabled) return false;
            await sync.syncNow();
            return sync.error == null;
          })
          ..tell = ((title, body) {
            unawaited(
              n.post(
                HubNotification(
                  id: 'repare:${DateTime.now().millisecondsSinceEpoch}',
                  title: title,
                  body: body,
                  moduleId: 'claude',
                ),
              ),
            );
            unawaited(ClickyController.instance.think(body, aloud: false));
          });
        Perf.later(7, () => SelfRepair.instance.run(diskFreeGb: SelfRepair.diskFreeGb()));
        // Alertes de Smily (agent terminé…).
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
      await ClickyTutorial.show(
        ctx,
        onBrain: () {
          brain = true;
          final c = hubNavigatorKey.currentContext;
          if (c != null) ClaudeModule.showSettings(c);
        },
      );
    } else {
      // Compte déjà là : on laisse l'appli s'ouvrir tranquillement.
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    // Puis Smily demande le compte Google (Drive, Docs, agenda), une fois.
    // S'il vient d'ouvrir les réglages du cerveau, ce sera au prochain
    // démarrage.
    if (brain) return;
    final ctx = await hubDialogContext(timeout: const Duration(seconds: 20));
    if (ctx != null && ctx.mounted) await GoogleWelcome.maybeShow(ctx);
  }

  /// Windows : Smily au-dessus de tout l'écran (petit programme à part).
  Future<void> _startClicky() async {
    // Smily est un bonus : s'il échoue, le reste de l'appli continue.
    try {
      // Réglages de ce compte partagés avec Smily partout, qu'on relance
      // pour qu'il reprenne le bon compte.
      await ClickyController.instance.shareOptions();
      await ClickyDesktop.restart();
      // S'il se ferme tout seul (plantage), il est relancé.
      ClickyDesktop.watch();
      // Les widgets laissés sur le bureau se rouvrent.
      unawaited(DesktopWidgets.instance.launchAll());
    } catch (e) {
      debugPrint('Smily : $e');
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
      // Smily, le compagnon Claude, au-dessus de toutes les pages.
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
                  // La pastille « Smily écoute le cours » (en haut, au milieu).
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
