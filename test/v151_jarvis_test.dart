import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_feed.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/ui/clicky/clicky_settings_page.dart';
import 'package:hub/ui/clicky/jarvis.dart';
import 'package:hub/ui/clicky/skills.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/thrift.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('état du PC', () {
    test('les applis qui prennent le plus de mémoire (tasklist), regroupées', () {
      const csv = '"System Idle Process","0","Services","0","8 Ko"\r\n'
          '"chrome.exe","1200","Console","1","812 344 Ko"\r\n'
          '"chrome.exe","1201","Console","1","1 210 000 Ko"\r\n'
          '"Discord.exe","300","Console","1","402 100 Ko"\r\n'
          '"svchost.exe","4","Services","0","900 000 Ko"\r\n'
          '"hub.exe","88","Console","1","350 000 Ko"\r\n';
      final top = SystemStatus.topMemory(csv);
      expect(top.first.$1, 'Chrome');
      expect(top.first.$2, (812344 + 1210000) ~/ 1024);
      expect(top.map((a) => a.$1), ['Chrome', 'Discord', 'Mon Hub']);
    });

    test('tout va bien / soucis signalés', () {
      const ok = SystemStatus(battery: 80, charging: true, memLoad: 45, memTotalGb: 16, memFreeGb: 8, diskFreeGb: 120, diskTotalGb: 476, cpu: 12, online: true);
      expect(ok.say(), startsWith('Tous les systèmes sont opérationnels.'));
      expect(ok.say(), contains('Batterie à 80 %, en charge'));
      const bad = SystemStatus(
        battery: 12,
        memLoad: 93,
        memTotalGb: 8,
        memFreeGb: 0.5,
        diskFreeGb: 4,
        diskTotalGb: 238,
        online: false,
        topApps: [('Chrome', 2600), ('Discord', 400)],
      );
      final s = bad.say(why: true);
      expect(s, startsWith('Attention'));
      expect(s, contains('branche le chargeur'));
      expect(s, contains('mémoire est presque pleine'));
      expect(s, contains('pas d\'internet'));
      expect(s, contains('Chrome (2,5 Go)'));
      expect(bad.toJson()['batterie_pourcent'], 12);
    });

    test('alerte batterie : une fois à 20 %, une fois à 10 %', () {
      expect(SystemStatus.batteryAlert(50, false, null), isNull);
      expect(SystemStatus.batteryAlert(19, false, null), 20);
      expect(SystemStatus.batteryAlert(15, false, 20), isNull);
      expect(SystemStatus.batteryAlert(9, false, 20), 10);
      expect(SystemStatus.batteryAlert(8, false, 10), isNull);
      expect(SystemStatus.batteryAlert(8, true, 10), isNull);
    });
  });

  group('mode concentration', () {
    test('durées dites à l\'oral', () {
      expect(FocusDuration.parse('45 min'), const Duration(minutes: 45));
      expect(FocusDuration.parse('pendant 1 h'), const Duration(hours: 1));
      expect(FocusDuration.parse('1 h 30'), const Duration(minutes: 90));
      expect(FocusDuration.parse('une heure et demie'), const Duration(minutes: 90));
      expect(FocusDuration.parse('une demi heure'), const Duration(minutes: 30));
      expect(FocusDuration.parse('pour 2 heures'), const Duration(hours: 2));
      expect(FocusDuration.parse('mon expose'), isNull);
      expect(FocusDuration.parse('2 min'), isNull);
      expect(FocusDuration.say(const Duration(minutes: 90)), '1 heure 30');
    });

    test('séance : active, finie, bilan avec les notifications gardées', () async {
      final f = FocusMode.instance;
      var now = DateTime(2026, 11, 18, 16);
      f.now = () => now;
      await f.start(const Duration(minutes: 45));
      expect(f.active, isTrue);
      await f.holdOne();
      await f.holdOne();
      now = now.add(const Duration(minutes: 50));
      expect(f.active, isFalse);
      expect(f.endedUnannounced, isTrue);
      final text = await f.stop();
      expect(text, contains('45 minutes de concentration'));
      expect(text, contains('2 notifications sont arrivées'));
      expect(text, contains('pause de 10 minutes'));
      expect(f.endedUnannounced, isFalse);
      expect(await f.stop(), isNull);
      f.now = DateTime.now;
    });
  });

  group('rappels liés à une appli', () {
    test('le nom de l\'appli et la fenêtre', () {
      expect(AppReminders.appKey('mon Discord'), 'discord');
      expect(AppReminders.appKey('VS Code'), 'visual studio code');
      final list = [
        AppReminder(id: '1', app: 'discord', text: 'répondre à Léo', created: DateTime(2026)),
        AppReminder(id: '2', app: 'word', text: 'finir l\'exposé', created: DateTime(2026)),
      ];
      expect(AppReminders.match(list, '#général | Mon serveur - Discord')?.id, '1');
      expect(AppReminders.match(list, 'Exposé.docx - Word')?.id, '2');
      // « word » n'est pas dans « password ».
      expect(AppReminders.match(list, 'Change your password - Google Chrome'), isNull);
    });
  });

  test('le point de la situation donné à l\'IA', () {
    final text = ClickySituation.describe(
      feed: const [
        FeedItem(id: 'a', moduleId: 'agenda', icon: Icons.event, title: 'Maths à 8 h', detail: 'demain, salle B12'),
        FeedItem(id: 'b', moduleId: 'ecole', icon: Icons.school, title: 'Contrôle de SVT jeudi'),
      ],
      music: const {'en_lecture': true, 'titre': 'Blinding Lights', 'artiste': 'The Weeknd'},
      focus: true,
      focusLeft: const Duration(minutes: 20),
    );
    expect(text, contains('- Maths à 8 h — demain, salle B12'));
    expect(text, contains('- Contrôle de SVT jeudi'));
    expect(text, contains('Blinding Lights de The Weeknd'));
    expect(text, contains('encore 20 min'));
  });

  test('« réfléchis bien » : Claude réfléchit à fond', () {
    expect(ClaudeThrift.deep('Réfléchis bien : combien de façons de ranger 5 livres ?'), isTrue);
    expect(ClaudeThrift.effort('réfléchis bien à mon problème'), 'high');
    expect(ClaudeThrift.effort('quelle heure est-il'), 'low');
    expect(ClaudeThrift.light('réfléchis bien : c\'est quoi la photosynthèse'), isFalse);
  });

  group('phrases sans IA', () {
    final calls = <String>[];
    Future<Object?> fake(String name, Map<String, dynamic> args) async {
      calls.add('$name${args.isEmpty ? '' : ' $args'}');
      switch (name) {
        case 'pc_etat':
          return {
            'resume': 'Tous les systèmes sont opérationnels. Batterie à 64 %.',
            if (args['applis'] == true) 'applis_gourmandes': ['Chrome (2,1 Go)', 'Discord (400 Mo)'],
          };
        case 'clicky_concentration':
          return args['arreter'] == true ? {'ok': true, 'bilan': 'Séance terminée : 30 minutes.'} : {'ok': true, 'fin': '17 h 15'};
        case 'clicky_situation':
          return '- Maths demain à 8 h\n- 2 devoirs pour demain';
        case 'pc_fenetres':
          return '${args['appli']}' == 'question' ? {'ok': false} : {'ok': true};
      }
      return {'ok': true};
    }

    const tools = {'pc_etat', 'pc_fenetres', 'clicky_concentration', 'clicky_rappel_appli', 'clicky_situation'};
    final now = DateTime(2026, 11, 18, 16, 30);
    Future<String?> ask(String q) async => (await QuickAnswers.answer(q, call: fake, tools: tools, now: now))?.text;

    test('mode concentration', () async {
      calls.clear();
      expect(await ask('Clicky, mode concentration'), contains('45 minutes'));
      expect(await ask('mode focus 30 minutes'), contains('30 minutes, jusqu\'à 17 h 15'));
      expect(await ask('je dois travailler pendant une heure'), contains('1 heure'));
      expect(await ask('arrête le mode concentration'), 'Séance terminée : 30 minutes.');
      expect(calls, [
        'clicky_concentration {minutes: 45}',
        'clicky_concentration {minutes: 30}',
        'clicky_concentration {minutes: 60}',
        'clicky_concentration {arreter: true}',
      ]);
    });

    test('état du PC, et pourquoi il rame', () async {
      calls.clear();
      expect(await ask('comment va mon PC ?'), contains('opérationnels'));
      expect(await ask('il me reste combien de batterie'), contains('64 %'));
      expect(await ask('pourquoi mon ordi rame'), contains('Chrome (2,1 Go)'));
      expect(calls.last, 'pc_etat {applis: true}');
    });

    test('fais le point', () async {
      final r = await ask('fais le point');
      expect(r, startsWith('Voici le point. Il est 16 h 30.'));
      expect(r, contains('Maths demain à 8 h. 2 devoirs pour demain.'));
      expect(r, contains('Batterie à 64 %'));
    });

    test('fenêtres', () async {
      calls.clear();
      expect(await ask('montre le bureau'), 'C\'est fait.');
      expect(await ask('mets Chrome à gauche'), 'C\'est fait.');
      expect(await ask('mets ça à droite'), 'C\'est fait.');
      expect(await ask('reviens sur Discord'), 'C\'est fait.');
      expect(calls, [
        'pc_fenetres {action: bureau, appli: }',
        'pc_fenetres {action: gauche, appli: chrome}',
        'pc_fenetres {action: droite, appli: }',
        'pc_fenetres {action: activer, appli: discord}',
      ]);
    });

    test('rappel quand j\'ouvre une appli (texte avec ses accents)', () async {
      calls.clear();
      expect(
        await ask('Rappelle-moi de répondre à Léo quand j\'ouvre Discord'),
        'D\'accord : la prochaine fois que tu ouvres Discord, je te rappelle de répondre à Léo.',
      );
      expect(calls.single, 'clicky_rappel_appli {appli: Discord, texte: répondre à Léo}');
    });

    test('les vraies questions vont à l\'IA', () async {
      calls.clear();
      expect(await ask('je dois travailler mon exposé sur la guerre froide'), isNull);
      expect(await ask('c\'est quoi un cours d\'eau'), isNull);
      expect(await ask('explique-moi comment marche la mémoire de mon ordi'), isNull);
      expect(calls, isEmpty);
      // « Reviens sur la question » : pas une fenêtre.
      expect(await ask('reviens sur la question'), isNull);
    });
  });

  group('écrans', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
    });

    testWidgets('ce que Clicky sait faire', (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ClickySkillsPage()));
      expect(find.text('Lui parler'), findsOneWidget);
      // Le thème « Concentration » se trouve en cherchant.
      await tester.enterText(find.byType(TextField), 'concentration');
      await tester.pump();
      expect(find.text('Concentration'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('réglages : « conversation continue » se trouve en cherchant', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ClickySettingsPage()));
      await tester.pump();
      expect(find.text('Ce que Clicky sait faire'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'conversation');
      await tester.pump();
      expect(find.text('Conversation continue'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
