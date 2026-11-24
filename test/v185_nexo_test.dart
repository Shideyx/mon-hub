import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/install.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/core/web_notify.dart';
import 'package:hub/modules/discord/discord_phone.dart';
import 'package:hub/modules/instagram/instagram_watch.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/hud.dart';
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
