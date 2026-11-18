import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/screen_time.dart';
import 'package:hub/ui/clicky/assistant.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  // Le fichier des tests précédents (le temps compté s'ajoute sinon).
  setUpAll(() async {
    final f = await HubFiles.file('temps-ecran.json');
    if (f != null && await f.exists()) await f.delete();
  });

  group('temps d\'écran', () {
    test('les applis et les sites sont reconnus', () {
      expect(ScreenTime.appName('RobloxPlayerBeta.exe', 'Roblox'), 'Roblox');
      expect(ScreenTime.appName('chrome.exe', 'Minecraft speedrun - YouTube - Google Chrome'), 'YouTube');
      expect(ScreenTime.appName('msedge.exe', 'Instagram'), 'Instagram');
      expect(ScreenTime.appName('chrome.exe', 'Le Monde'), 'Navigateur (autres sites)');
      expect(ScreenTime.appName('javaw.exe', 'Minecraft 1.21'), 'Minecraft');
      expect(ScreenTime.appName('Paint.exe', 'Sans titre'), 'Paint');
    });

    test('retrouver l\'appli dont on parle', () {
      final names = ['Roblox', 'Roblox Studio', 'YouTube', 'Minecraft', 'École Directe'];
      expect(ScreenTime.matchApp('roblox', names), 'Roblox');
      expect(ScreenTime.matchApp('Roblox Studio', names), 'Roblox Studio');
      expect(ScreenTime.matchApp('yt', names), 'YouTube');
      expect(ScreenTime.matchApp('youtube', names), 'YouTube');
      expect(ScreenTime.matchApp('ecole directe', names), 'École Directe');
      expect(ScreenTime.matchApp('fortnite', names), isNull);
    });

    test('compter, limite douce et absence', () async {
      final st = ScreenTime.instance;
      final alerts = <String>[];
      st.alert = (t, b) => alerts.add(t);
      await st.setLimit('Roblox', 1);
      final day = DateTime(2026, 11, 18, 15);
      // Absent (souris immobile depuis 3 min) : rien n'est compté.
      expect(await st.tick(exe: 'RobloxPlayerBeta.exe', title: 'Roblox', idleSeconds: 200, now: day), isNull);
      for (var i = 0; i < 5; i++) {
        await st.tick(exe: 'RobloxPlayerBeta.exe', title: 'Roblox', idleSeconds: 3, now: day);
      }
      expect(st.day(day)['Roblox'], 75);
      expect(alerts, hasLength(1));
      expect(alerts.single, contains('Roblox'));
      await st.tick(exe: 'chrome.exe', title: 'YouTube', idleSeconds: 0, now: day);
      expect(ScreenTime.summary(st.day(day)), contains('Roblox'));
      await st.setLimit('Roblox', null);
      expect(st.limits.containsKey('Roblox'), isFalse);
    });

    test('dire une durée', () {
      expect(ScreenTime.say(40 * 60), '40 min');
      expect(ScreenTime.say(65 * 60), '1 h 05');
      expect(ScreenTime.say(120 * 60), '2 h');
      expect(ScreenTime.summary(const {}), contains('presque rien'));
    });
  });

  group('sommeil', () {
    test('heure du coucher', () {
      final first = DateTime(2026, 11, 19, 8);
      expect(Sleep.bedtime(first), DateTime(2026, 11, 18, 22));
      expect(Sleep.bedtime(first, hours: 8.5, prep: 45), DateTime(2026, 11, 18, 22, 45));
      expect(Sleep.say(first), 'Demain, cours à 8 h : au lit vers 22 h pour dormir 9 h.');
      expect(Sleep.say(first, hours: 8.5), contains('8,5 h'));
    });

    test('le premier cours du lendemain (École Directe seulement)', () {
      final day = DateTime(2026, 11, 19);
      final events = <Map>[
        {'titre': 'Foot', 'debut': '2026-11-19T07:30:00', 'source': 'Google Agenda'},
        {'titre': 'MATHS', 'debut': '2026-11-19T10:00:00', 'source': 'École Directe'},
        {'titre': 'ANGLAIS', 'debut': '2026-11-19T09:00:00', 'source': 'École Directe', 'annule': true},
        {'titre': 'FRANÇAIS', 'debut': '2026-11-19T09:00:00', 'source': 'École Directe'},
        {'titre': 'SVT', 'debut': '2026-11-20T08:00:00', 'source': 'École Directe'},
      ];
      expect(Assistant.firstLesson(events, day), DateTime(2026, 11, 19, 9));
      expect(Assistant.firstLesson(events, DateTime(2026, 11, 21)), isNull);
    });
  });

  group('mode jeu', () {
    test('entre après 30 s de jeu en plein écran, bilan à la fin', () {
      final g = GameMode.instance;
      final t0 = DateTime(2026, 11, 18, 16);
      expect(g.tick(exe: 'RobloxPlayerBeta.exe', fullscreen: true, now: t0), isNull);
      expect(g.active, isFalse);
      g.tick(exe: 'RobloxPlayerBeta.exe', fullscreen: true, now: t0.add(const Duration(seconds: 15)));
      expect(g.active, isTrue);
      expect(g.game, 'Roblox');
      g.held = 3;
      expect(g.tick(exe: 'explorer.exe', fullscreen: false, now: t0.add(const Duration(minutes: 40))), isNull);
      final end = g.tick(exe: 'explorer.exe', fullscreen: false, now: t0.add(const Duration(minutes: 41)));
      expect(end, contains('Roblox'));
      expect(end, contains('3 notifications'));
      expect(g.active, isFalse);
    });

    test('une vidéo ou un document en plein écran n\'est pas un jeu', () {
      expect(GameMode.isGame('chrome.exe', true), isFalse);
      expect(GameMode.isGame('vlc.exe', true), isFalse);
      expect(GameMode.isGame('POWERPNT.EXE', true), isFalse);
      expect(GameMode.isGame('RobloxPlayerBeta.exe', false), isFalse);
      expect(GameMode.isGame('javaw.exe', true), isTrue);
    });
  });

  group('phrases sans IA', () {
    Future<(String?, String, Map)> ask(String q, Set<String> tools) async {
      String? tool;
      Map args = const {};
      final r = await QuickAnswers.answer(
        q,
        call: (n, a) async {
          tool = n;
          args = a;
          return {'resume': 'ok'};
        },
        tools: tools,
      );
      return (r?.text, tool ?? '', args);
    }

    test('temps d\'écran', () async {
      const tools = {'temps_ecran', 'temps_ecran_limite', 'assistant_coucher'};
      var (text, tool, args) = await ask('mon temps d\'écran', tools);
      expect((tool, args['periode']), ('temps_ecran', 'jour'));
      (text, tool, args) = await ask('combien de temps j\'ai passé sur Roblox cette semaine', tools);
      expect((tool, args['appli'], args['periode']), ('temps_ecran', 'roblox', 'semaine'));
      (text, tool, args) = await ask('combien de temps sur YouTube hier ?', tools);
      expect((args['appli'], args['periode']), ('youtube', 'hier'));
      (text, tool, args) = await ask('combien de temps j\'ai passé sur l\'écran aujourd\'hui', tools);
      expect((tool, args.containsKey('appli')), ('temps_ecran', false));
      (text, tool, args) = await ask('limite Roblox à 1 h par jour', tools);
      expect((tool, args['appli'], args['minutes']), ('temps_ecran_limite', 'roblox', 60));
      (text, tool, args) = await ask('mets une limite de 30 min sur TikTok', tools);
      expect((tool, args['appli'], args['minutes']), ('temps_ecran_limite', 'tiktok', 30));
      (text, tool, args) = await ask('enlève la limite sur Roblox', tools);
      expect((tool, args['minutes']), ('temps_ecran_limite', 0));
      (text, tool, args) = await ask('à quelle heure je dois me coucher ce soir', tools);
      expect(tool, 'assistant_coucher');
      expect(text, isNotNull);
    });

    test('les vraies questions partent vers l\'IA', () async {
      const tools = {'temps_ecran', 'temps_ecran_limite', 'assistant_coucher'};
      for (final q in [
        'combien de temps faut-il pour cuire des pâtes',
        'combien de temps a duré la guerre de cent ans',
        'pourquoi faut-il dormir 9 heures',
      ]) {
        final (text, tool, _) = await ask(q, tools);
        expect(tool, '', reason: q);
        expect(text, isNull, reason: q);
      }
    });
  });
}
