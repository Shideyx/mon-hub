import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/call_shield.dart';
import 'package:hub/core/cam_blur.dart';
import 'package:hub/core/camera_guard.dart';
import 'package:hub/core/gemini_agent.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/ui/clicky/game_coach.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/install.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/core/web_notify.dart';
import 'package:hub/modules/discord/discord_phone.dart';
import 'package:hub/modules/instagram/instagram_watch.dart';
import 'package:hub/ui/clicky/announce.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/hud.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/identity.dart';
import 'package:hub/ui/clicky/mind.dart';
import 'package:hub/ui/clicky/smily.dart';
import 'package:hub/ui/clicky/wake.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Mon Hub installé pour de bon', () {
    test('l\'intérieur d\'un zip (dossier temporaire) et les Téléchargements ne sont pas des endroits où rester', () {
      expect(AppInstall.isTemporary(r'C:\Users\Erik\AppData\Local\Temp\Rar$EXa9116.40467.rartemp\hub.exe'), isTrue);
      expect(AppInstall.isTemporary(r'C:\Users\Erik\AppData\Local\Temp\7zO1234\hub.exe'), isTrue);
      expect(AppInstall.isTemporary(r'C:\Users\Erik\Downloads\MonHub-Windows (8)\hub.exe'), isTrue);
      expect(AppInstall.isTemporary(r'C:\Users\Erik\AppData\Local\Programs\Mon Hub\hub.exe'), isFalse);
      // Un dossier choisi par la personne : on n'y touche pas.
      expect(AppInstall.isTemporary(r'D:\Jeux\Mon Hub\hub.exe'), isFalse);
    });

    const dir = r'C:\Users\Erik\AppData\Local\Programs\Mon Hub';
    const temp = r'C:\Users\Erik\AppData\Local\Temp\Rar$EXa1.rartemp\hub.exe';

    test('lancé depuis un zip, sans rien d\'installé : il s\'installe', () {
      expect(
        AppInstall.decide(exePath: temp, installDir: dir, here: 84, installed: null, installedExists: false),
        InstallStep.install,
      );
    });

    test('une copie plus récente est déjà installée : c\'est elle qui s\'ouvre (plus de vieilles copies en double)', () {
      expect(
        AppInstall.decide(exePath: temp, installDir: dir, here: 70, installed: 84, installedExists: true),
        InstallStep.openInstalled,
      );
    });

    test('un zip plus récent remplace la version installée', () {
      expect(
        AppInstall.decide(exePath: temp, installDir: dir, here: 90, installed: 84, installedExists: true),
        InstallStep.install,
      );
    });

    test('déjà au bon endroit, ou version de développement : il reste là', () {
      expect(
        AppInstall.decide(exePath: '$dir\\hub.exe', installDir: dir, here: 84, installed: 84, installedExists: true),
        InstallStep.stay,
      );
      expect(
        AppInstall.decide(exePath: temp, installDir: dir, here: null, installed: null, installedExists: false),
        InstallStep.stay,
      );
      expect(
        AppInstall.decide(exePath: r'D:\Jeux\Mon Hub\hub.exe', installDir: dir, here: 84, installed: null, installedExists: false),
        InstallStep.stay,
      );
    });

    test('les connexions sont recopiées, pas les caches ni les verrous du navigateur', () {
      expect(AppInstall.worthCopying(r'EBWebView\Default\Network\Cookies'), isTrue);
      expect(AppInstall.worthCopying(r'EBWebView\Default\Local Storage\leveldb\000003.log'), isTrue);
      expect(AppInstall.worthCopying(r'EBWebView\Default\IndexedDB\https_discord.com_0.indexeddb.leveldb\CURRENT'), isTrue);
      expect(AppInstall.worthCopying(r'EBWebView\Default\Cache\Cache_Data\data_1'), isFalse);
      expect(AppInstall.worthCopying(r'EBWebView\Default\Code Cache\js\index'), isFalse);
      expect(AppInstall.worthCopying(r'EBWebView\GrShaderCache\data_0'), isFalse);
      expect(AppInstall.worthCopying(r'EBWebView\lockfile'), isFalse);
    });
  });

  group('Les notifications des vrais sites', () {
    test('le nombre de non-lus se lit dans le titre de la page', () {
      expect(WebNotify.countInTitle('(3) Instagram'), 3);
      expect(WebNotify.countInTitle('(12) Discord | Amis'), 12);
      expect(WebNotify.countInTitle('Instagram'), isNull);
      expect(WebNotify.countInTitle('• Discord | #général'), isNull);
    });

    test('du nouveau seulement quand il y a plus de non-lus, ou une notification de la page', () {
      expect(WebNotify.news(before: 2, now: 2, notifsBefore: 0, notifsNow: 0), isNull);
      expect(WebNotify.news(before: 3, now: 1, notifsBefore: 0, notifsNow: 0), isNull, reason: 'lu ailleurs');
      expect(WebNotify.news(before: 1, now: 2, notifsBefore: 0, notifsNow: 0)?.count, 2);
      expect(WebNotify.news(before: null, now: 1, notifsBefore: 0, notifsNow: 0)?.count, 1);
      final n = WebNotify.news(
        before: 0,
        now: 0,
        notifsBefore: 4,
        notifsNow: 5,
        last: {'t': 'Léa', 'b': 't\'es là ?'},
      );
      expect(n?.title, 'Léa');
      expect(n?.body, 't\'es là ?');
    });

    test('le relais de notifications accorde la permission et garde ce que le site voulait montrer', () {
      expect(WebNotify.shimScript, contains("Relay.permission = 'granted'"));
      expect(WebNotify.shimScript, contains('__mhNotifLast'));
      expect(WebNotify.statusScript(loginPattern: '^/login'), contains('document.title'));
    });

    test('Instagram : premier regard sans alerte, puis un nouveau message = une notification', () {
      final w = InstagramWatch.instance;
      final got = <WebNews>[];
      final badges = <int>[];
      w
        ..onNews = got.add
        ..onUnread = badges.add;
      w.onStatus({'title': '(1) Instagram', 'n': 0});
      expect(got, isEmpty, reason: 'les anciens non-lus ne sonnent pas');
      w.onStatus({'title': '(1) Instagram', 'n': 0});
      expect(got, isEmpty);
      w.onStatus({'title': '(2) Instagram', 'n': 0});
      expect(got.single.count, 2);
      expect(badges.last, 2);
      w.onStatus({'title': 'Instagram', 'n': 0});
      expect(badges.last, 0, reason: 'tout lu : la pastille disparaît');
      final (title, body) = InstagramWatch.describe(got.single);
      expect(title, contains('Instagram'));
      expect(body, contains('2'));
      w
        ..onNews = null
        ..onUnread = null;
    });

    test('Instagram : la notification reprend l\'expéditeur quand la page l\'a donné', () {
      final (title, body) = InstagramWatch.describe(const WebNews(count: 1, title: 'tom.dlr', body: 'ce soir ?'));
      expect(title, contains('tom.dlr'));
      expect(body, 'ce soir ?');
    });

    test('Discord : un non-lu de plus dans le vrai Discord = relève tout de suite', () {
      final p = DiscordPhone.instance;
      var calls = 0;
      p.onActivity = () => calls++;
      p.onStatus({'title': 'Discord | Amis', 'n': 0});
      expect(calls, 0, reason: 'premier regard');
      p.onStatus({'title': '(1) Discord | Amis', 'n': 0});
      expect(calls, 1);
      p.onStatus({'title': '(1) Discord | Amis', 'n': 0});
      expect(calls, 1, reason: 'rien de neuf');
      p
        ..onActivity = null
        ..stop();
    });
  });

  group('La relève des modules', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
    });

    test('les modules sont relevés en même temps (un module lent ne fait plus attendre les autres)', () async {
      final a = _Slow('a', const Duration(milliseconds: 400));
      final b = _Slow('b', const Duration(milliseconds: 400));
      final center = NotificationCenter(HubController([a, b]));
      final watch = Stopwatch()..start();
      await center.pollNow();
      expect(watch.elapsedMilliseconds, lessThan(750));
      expect(a.calls, 1);
      expect(b.calls, 1);
    });

    test('relever un seul module tout de suite', () async {
      final a = _Slow('a', Duration.zero);
      final b = _Slow('b', Duration.zero);
      final center = NotificationCenter(HubController([a, b]));
      await center.pollNow();
      a.items = [HubNotification(id: 'm1', title: 'Discord · Léa', body: 'salut')];
      await center.pollModules({'a'});
      expect(a.calls, 2);
      expect(b.calls, 1, reason: 'les autres ne sont pas relevés pour rien');
      expect(center.history.map((n) => n.id), ['m1']);
    });

    test('une relève demandée pendant qu\'une autre tourne est faite juste après', () async {
      final a = _Slow('a', const Duration(milliseconds: 150));
      final center = NotificationCenter(HubController([a]));
      final first = center.pollNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      unawaited(center.pollModules({'a'}));
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.calls, 2);
    });
  });

  group('Le coach de jeu, le cerveau économe, le micro', () {
    test('« coach-moi » et « arrête le coach »', () {
      expect(CoachRules.command('coach moi'), 'lancer');
      expect(CoachRules.command('mode coach'), 'lancer');
      expect(CoachRules.command('aide moi dans ce jeu'), 'lancer');
      expect(CoachRules.command('arrete le coach'), 'arreter');
      expect(CoachRules.command('c est quoi un coach'), isNull);
    });

    test('quand il n\'a rien à dire, on n\'entend rien', () {
      expect(CoachRules.silent('RIEN'), isTrue);
      expect(CoachRules.silent(' Rien.'), isTrue);
      expect(CoachRules.silent('Attention, un ennemi à gauche !'), isFalse);
      expect(CoachRules.silent('Rien de grave, mais recharge ton arme.'), isTrue,
          reason: 'commence par « rien » : on préfère se taire');
    });

    test('les images envoyées sont petites (flux léger, pas des captures en grand)', () {
      expect(CoachRules.frameSize(2560, 1440, 768), (768, 432));
      expect(CoachRules.frameSize(640, 480, 768), (640, 480));
      expect(CoachRules.system('Fortnite', ''), contains('Fortnite'));
      expect(CoachRules.system('', ''), contains('RIEN'));
    });

    test('économe : Gemini répond à presque tout, Claude pour les gros travaux', () {
      bool first(String mode, {bool heavy = false, bool screen = false, bool deep = false, bool light = false}) =>
          BrainRules.geminiFirst(mode, light: light, heavy: heavy, deep: deep, screen: screen, docs: false);
      expect(first('econome'), isTrue, reason: 'mes devoirs de demain, mon agenda… : Gemini avec les outils');
      expect(first('econome', heavy: true), isFalse, reason: 'rédiger, analyser, coder : Claude');
      expect(first('econome', screen: true), isFalse, reason: 'voir ou agir sur l\'écran : Claude');
      expect(first('econome', deep: true), isFalse);
      expect(first('equilibre'), isFalse);
      expect(first('equilibre', light: true), isTrue);
      expect(first('claude', light: true), isFalse);
    });

    test('Gemini utilise les outils de Mon Hub, puis répond', () async {
      final calls = <String>[];
      var step = 0;
      GeminiAgent.postOverride = (body) async {
        step++;
        if (step == 1) {
          expect((body['tools'] as List).isNotEmpty, isTrue);
          return {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'agenda_lire',
                        'args': {'jour': 'demain'},
                      },
                    },
                  ],
                },
              },
            ],
          };
        }
        return {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Demain tu as maths à 9 h.'},
                ],
              },
            },
          ],
        };
      };
      final tool = HubTool(
        name: 'agenda_lire',
        description: 'Lit l\'agenda',
        params: {'jour': ('string', 'le jour')},
        run: (a) async => {'cours': 'Maths 9 h'},
      );
      final r = await GeminiAgent.ask(
        question: 'J\'ai quoi demain ?',
        system: 'Tu es Nexo.',
        tools: [tool],
        run: (t, a) async {
          calls.add(t.name);
          return t.run(a);
        },
      );
      GeminiAgent.postOverride = null;
      expect(calls, ['agenda_lire']);
      expect(r, 'Demain tu as maths à 9 h.');
      expect(GeminiAgent.handsOff(r), isFalse);
      expect(GeminiAgent.handsOff('CLAUDE'), isTrue);
    });

    test('le bouclier ne prend plus ton jeu, ton appli d\'appel ou Nexo pour des espions', () {
      SensorUse use(String key) => SensorUse(key: key, app: CameraRules.appName(key), active: true);
      final mic = SensorState(
        uses: [
          use(r'C:#Users#Erik#AppData#Local#Discord#app-1.0#Discord.exe'),
          use(r'C:#Program Files#Epic Games#Fortnite#FortniteGame#Binaries#Win64#FortniteClient-Win64-Shipping.exe'),
          use(r'C:#Windows#System32#WindowsPowerShell#v1.0#powershell.exe'),
          use(r'C:#Program Files (x86)#Microsoft#EdgeWebView#Application#msedgewebview2.exe'),
          use(r'C:#Users#Erik#Downloads#truc_louche.exe'),
        ],
      );
      final call = CallRules.callApp(mic);
      expect(call, 'Discord');
      final bad = CallRules.intruders(const SensorState(), mic, call!);
      expect([for (final (u, _) in bad) u.app], ['Truc_louche']);
    });

    test('rendre le micro : seulement aux applis qui doivent l\'avoir', () {
      expect(
        CallShield.shouldHaveMic(
          SensorUse(key: r'C:#Users#Erik#Discord.exe', app: 'Discord', active: false, denied: true),
        ),
        isTrue,
      );
      expect(
        CallShield.shouldHaveMic(SensorUse(key: 'x#truc.exe', app: 'Truc', active: false, denied: true)),
        isFalse,
      );
      expect(
        CallShield.shouldHaveMic(SensorUse(key: r'C:#Users#Erik#Discord.exe', app: 'Discord', active: false)),
        isFalse,
        reason: 'pas bloqué : rien à rendre',
      );
      expect(CallShield.sayGiven(const ['Discord']), contains('Discord'));
    });

    test('« floute mon arrière-plan » : le fond flou, le visage net', () {
      expect(CamBlur.modeFrom('floute mon arrière-plan'), 'fond');
      expect(CamBlur.modes, contains('fond'));
      expect(CamBlur.script('fond'), contains("mode === 'fond'"));
      expect(CamBlur.label('fond'), 'Arrière-plan flou');
    });
  });

  group('Nexo t\'annonce tes messages', () {
    HubNotification note(String id, String title, String body, {String module = ''}) =>
        HubNotification(id: id, title: title, body: body, moduleId: module);

    test('les messages de quelqu\'un, d\'où ils viennent', () {
      expect(
        MessageAnnounce.line(note('1234', 'Discord · Léa', 't\'es là ?', module: 'discord')),
        'Léa sur Discord : t\'es là ?',
      );
      expect(
        MessageAnnounce.line(note('insta:1', '📸 tom.dlr', 'ce soir ?', module: 'instagram')),
        'tom.dlr sur Instagram : ce soir ?',
      );
      expect(
        MessageAnnounce.line(note('insta:2', '📸 Instagram', 'Tu as un nouveau message.', module: 'instagram')),
        'Tu as un nouveau message.',
      );
      expect(
        MessageAnnounce.line(note('msg:9', '📨 École Directe · M. Dupont', 'Sortie scolaire', module: 'ecoledirecte')),
        'M. Dupont sur École Directe : Sortie scolaire',
      );
      expect(
        MessageAnnounce.line(note('a|1|Promo', '✉️ Amazon', 'Votre colis', module: 'mail')),
        'Un mail d\'Amazon : Votre colis',
      );
      expect(
        MessageAnnounce.line(note('a|2|Sortie', '✉️ Lucas', 'Sortie samedi', module: 'mail')),
        'Un mail de Lucas : Sortie samedi',
      );
    });

    test('pas les notes, devoirs, arnaques ni le reste (ils ont leurs propres réactions)', () {
      expect(MessageAnnounce.line(note('note:1', '📝 Nouvelle note en Maths', '16/20', module: 'ecoledirecte')), isNull);
      expect(MessageAnnounce.line(note('devoir:1', '📚 Devoir en SVT', 'Pour demain', module: 'ecoledirecte')), isNull);
      expect(MessageAnnounce.line(note('arnaque:9', '⚠️ Arnaque probable', 'lien', module: 'discord')), isNull);
      expect(MessageAnnounce.line(note('maj:v1.90', '✨ Mon Hub v1.90 est installé', '')), isNull);
    });

    test('jamais un code ou un mot de passe lu tout haut', () {
      final l = MessageAnnounce.line(note('1', 'Discord · Bot', 'Ton code de vérification : 482913', module: 'discord'));
      expect(l, 'Bot sur Discord.');
      expect(MessageAnnounce.line(note('2', 'Discord · Léa', 'mon mot de passe c\'est chat', module: 'discord')),
          'Léa sur Discord.');
    });

    test('un appel est annoncé, avec quoi répondre', () {
      final n = note('discord-appel-1', 'Appel Discord', 'Léa t\'appelle', module: 'discord');
      expect(MessageAnnounce.isCall(n), isTrue);
      expect(MessageAnnounce.line(n), contains('Léa t\'appelle sur Discord'));
      expect(MessageAnnounce.line(n), contains('décroche'));
    });

    test('une rafale de messages = une seule bulle', () {
      final p = AnnouncePacer();
      final t = DateTime(2026, 11, 25, 16);
      expect(p.onMessage('Léa sur Discord : salut', t), 'Léa sur Discord : salut');
      expect(p.onMessage('Léa sur Discord : t\'es là ?', t.add(const Duration(seconds: 3))), isNull);
      expect(p.onMessage('Tom sur Instagram : yo', t.add(const Duration(seconds: 5))), isNull);
      expect(
        p.onMessage('Léa sur Discord : réponds', t.add(const Duration(seconds: 30))),
        'Léa sur Discord : réponds (et 2 autres messages avant).',
      );
    });

    test('répondre à un appel à la voix', () {
      expect(QuickAnswers.callAction('decroche'), 'repondre');
      expect(QuickAnswers.callAction('reponds a l appel'), 'repondre');
      expect(QuickAnswers.callAction('decroche en video'), 'repondre_video');
      expect(QuickAnswers.callAction('refuse l appel'), 'refuser');
      expect(QuickAnswers.callAction('raccroche'), 'raccrocher');
      // Une vraie question ne déclenche rien.
      expect(QuickAnswers.callAction('refuse'), isNull);
      expect(QuickAnswers.callAction('comment je decroche un telephone'), isNull);
    });
  });

  group('Nexo', () {
    test('il s\'appelle Nexo, et on le réveille par son nom (les anciens noms marchent encore)', () {
      expect(Nexo.name, 'Nexo');
      expect(WakeWord.phrases, contains('nexo'));
      expect(WakeWord.phrases, contains('hey nexo'));
      expect(WakeWord.phrases, contains('smily'));
      expect(WakeWord.phrases, contains('clicky'));
    });

    test('sa personnalité : un curseur, pas un smiley', () {
      final p = clickyPersona('Erik');
      expect(p, contains('Nexo'));
      expect(p, contains('curseur'));
      expect(p, isNot(contains('smiley')));
      expect(clickyGreeting('Erik', DateTime(2026, 11, 24, 9)), contains('Nexo en ligne'));
    });

    test('il sait dire d\'où vient son nom, sans IA', () async {
      HubFiles.overrideRoot = Directory.systemTemp.createTempSync('nexo').path;
      final mind = ClickyMind.instance;
      await mind.load();
      final now = DateTime(2026, 11, 24, 15);
      expect(mind.selfAnswer('Pourquoi tu t\'appelles Nexo ?', now: now), contains('nexus'));
      expect(mind.selfAnswer('d\'où vient ton nom', now: now), contains('nexus'));
      expect(mind.selfAnswer('t\'es qui ?', now: now), startsWith('Moi c\'est Nexo'));
    });

    test('chaque humeur a son mode, et seuls les modes actifs bougent (fluidité)', () {
      final modes = {for (final m in SmilyMood.values) Nexo.modeFor(m)};
      expect(modes.length, SmilyMood.values.length);
      expect(Nexo.animated(NexoMode.idle), isFalse);
      expect(Nexo.animated(NexoMode.asleep), isFalse);
      expect(Nexo.animated(NexoMode.thinking), isTrue);
      expect(Nexo.animated(NexoMode.listening), isTrue);
    });

    testWidgets('la Pointe se dessine dans chaque mode', (tester) async {
      for (final m in NexoMode.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: NexoPointer(mode: m, level: 0.5, agents: m == NexoMode.working ? 2 : 0)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: m.name);
      }
      await tester.pumpWidget(const SizedBox());
    });

    test('la bulle ne coupe jamais un émoji en deux (plantage de l\'affichage)', () {
      const t = 'Bravo 🤩 !';
      // « 🤩 » = deux morceaux UTF-16 : on saute toujours les deux d'un coup.
      final cuts = <int>[];
      var n = 0;
      while (n < t.length) {
        n = TypedText.nextCut(t, n);
        cuts.add(n);
      }
      for (final c in cuts) {
        final s = TypedText.safePrefix(t, c);
        expect(() => s.runes.toList(), returnsNormally);
        expect(s.codeUnits.isEmpty || s.codeUnits.last < 0xD800 || s.codeUnits.last > 0xDBFF, isTrue);
      }
      expect(TypedText.safePrefix(t, 7), 'Bravo ', reason: 'au milieu de l\'émoji : on s\'arrête avant');
    });
  });
}

class _Slow extends HubModule {
  _Slow(this._id, this.delay);
  final String _id;
  final Duration delay;
  int calls = 0;
  List<HubNotification> items = [];

  @override
  String get id => _id;
  @override
  String get name => _id;
  @override
  String get description => '';
  @override
  IconData get icon => Icons.star;
  @override
  Color get color => Colors.red;
  @override
  ApiAccess get access => ApiAccess.local;
  @override
  Future<List<HubNotification>> poll() async {
    calls++;
    await Future<void>.delayed(delay);
    return items;
  }

  @override
  Widget buildSummary(BuildContext context) => const SizedBox();
  @override
  Widget buildPage(BuildContext context) => const SizedBox();
}
