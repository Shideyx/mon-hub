import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/account_sync.dart';
import 'package:hub/core/claude_bridge.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/prompt_shield.dart';
import 'package:hub/core/screen_memory.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/senses.dart';

Uint8List _tone(int ms, {double amp = 0}) {
  final r = math.Random(1);
  final data = ByteData(ms * 32);
  for (var i = 0; i < ms * 16; i++) {
    data.setInt16(i * 2, ((r.nextDouble() - 0.5) * amp * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  final mem = ScreenMemory.instance;

  setUp(() async {
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('sens').path;
    await mem.load();
    await mem.forget();
  });

  group('la mémoire de l\'écran', () {
    test('il retrouve ce qu\'il a vu, au bon moment', () async {
      final now = DateTime(2026, 11, 22, 18);
      final yesterday = DateTime(2026, 11, 21, 16, 10);
      await mem.add(
        ScreenMoment(
          at: yesterday,
          app: 'Chrome',
          title: 'Volcan — Wikipédia - Google Chrome',
          text: 'Un volcan est un ensemble géologique… le magma remonte par la cheminée.',
        ),
        now: now,
      );
      await mem.add(
        ScreenMoment(
          at: DateTime(2026, 11, 22, 10),
          app: 'YouTube',
          title: 'Minecraft speedrun',
          text: 'record du monde',
        ),
        now: now,
      );
      await mem.add(
        ScreenMoment(
          at: DateTime(2026, 11, 22, 11),
          app: 'YouTube',
          title: 'Cours SVT',
          text: 'retenez bien la mitose',
          heard: true,
        ),
        now: now,
      );
      final hits = mem.search('le site sur les volcans');
      expect(hits, isNotEmpty);
      expect(hits.first.moment.title, contains('Volcan'));
      expect(ScreenMemory.say('volcans', hits, now), startsWith('Oui ! Hier vers 16 h 10'));
      // Avec le moment : seulement hier.
      final w = TimeWindow.parse('hier', now)!;
      expect(mem.search('minecraft', from: w.from, to: w.to), isEmpty);
      expect(mem.search('mitose').single.moment.heard, isTrue);
      expect(ScreenMemory.say('mitose', mem.search('mitose'), now), contains('entendu dans'));
      expect(ScreenMemory.say('girafes', const [], now), contains('Je ne retrouve rien'));
      // « Qu'est-ce que je faisais ce matin ? »
      final morning = TimeWindow.parse('ce matin', now)!;
      final list = mem.between(morning.from, morning.to);
      expect(list, hasLength(2));
      expect(ScreenMemory.sayBetween(list, morning.from, morning.to, now), contains('YouTube'));
    });

    test('la même fenêtre avec le même texte ne crée pas 100 souvenirs', () async {
      final t = DateTime(2026, 11, 22, 14);
      for (var i = 0; i < 10; i++) {
        await mem.add(
          ScreenMoment(
            at: t.add(Duration(seconds: 15 * i)),
            app: 'Word',
            title: 'Exposé',
            text: 'Introduction',
          ),
          now: t,
        );
      }
      expect(mem.moments, hasLength(1));
      expect(mem.moments.single.until, t.add(const Duration(seconds: 135)));
      await mem.add(
        ScreenMoment(
          at: t.add(const Duration(minutes: 3)),
          app: 'Word',
          title: 'Exposé',
          text: 'Introduction et partie 1',
        ),
        now: t,
      );
      expect(mem.moments, hasLength(2));
    });

    test('il oublie (les dernières minutes, ou tout) et ne garde que 7 jours', () async {
      final now = DateTime(2026, 11, 22, 14);
      await mem.add(
        ScreenMoment(at: now.subtract(const Duration(days: 9)), app: 'A', title: 'vieux'),
        now: now.subtract(const Duration(days: 9)),
      );
      await mem.add(
        ScreenMoment(at: now.subtract(const Duration(hours: 2)), app: 'A', title: 'avant'),
        now: now,
      );
      expect(mem.moments.map((m) => m.title), ['avant'], reason: 'plus de 7 jours : oublié');
      await mem.add(
        ScreenMoment(at: now.subtract(const Duration(minutes: 5)), app: 'A', title: 'récent'),
        now: now,
      );
      expect(await mem.forget(last: const Duration(minutes: 15), now: now), 1);
      expect(mem.moments.map((m) => m.title), ['avant']);
      await mem.forget(now: now);
      expect(mem.moments, isEmpty);
    });

    test('les moments dont on parle', () {
      final now = DateTime(2026, 11, 22, 18, 30); // un dimanche
      final hier = TimeWindow.parse('hier soir', now)!;
      expect(hier.from, DateTime(2026, 11, 21, 18));
      final mardi = TimeWindow.parse('mardi vers 16 h', now)!;
      expect(mardi.from, DateTime(2026, 11, 17, 15, 15));
      expect(mardi.to, DateTime(2026, 11, 17, 16, 45));
      final ago = TimeWindow.parse('il y a 20 minutes', now)!;
      expect(ago.from, DateTime(2026, 11, 22, 18));
      expect(TimeWindow.parse('tout à l\'heure', now)!.from, DateTime(2026, 11, 22, 15, 30));
      // « Vers 20 h » alors qu'il n'est que 18 h 30 : c'était hier.
      expect(TimeWindow.parse('vers 20h', now)!.from, DateTime(2026, 11, 21, 19, 15));
      expect(TimeWindow.parse('le site sur les volcans', now), isNull);
      expect(ScreenMemory.words('le site sur les volcans que j\'ai vu hier'), ['volcans']);
    });

    test('jamais synchronisée ni lue comme une consigne', () {
      expect(AccountSync.syncedFile('memoire-ecran.json'), isFalse);
      expect(AccountSync.syncedFile('sens-recent.json'), isFalse);
      expect(PromptShield.readsOutside('memoire_ecran'), isTrue);
      expect(PromptShield.readsOutside('sens_etat'), isTrue);
      expect(ToolRouter.groupOf('memoire_ecran'), 'memoire');
      expect(ToolRouter.groupsFor('tu te souviens du site d\'hier ?'), contains('memoire'));
      // Allumer ses yeux : avec ton accord (pas en douce par l'IA).
      expect(ClaudeBridge.isWriteAction(HubTool(name: 'sens_regler', description: '', run: (_) async => null)), isTrue);
    });
  });

  group('ce qu\'il ne regarde jamais', () {
    test('messageries, mails, banque, mots de passe, navigation privée, Mon Hub', () {
      expect(SenseRules.privateWindow('Discord.exe', 'Discord'), isTrue);
      expect(
        SenseRules.privateWindow('chrome.exe', 'Boîte de réception (3) - moi@gmail.com - Gmail - Google Chrome'),
        isTrue,
      );
      expect(SenseRules.privateWindow('chrome.exe', 'WhatsApp - Google Chrome'), isTrue);
      expect(SenseRules.privateWindow('msedge.exe', 'Nouvel onglet - [InPrivate] - Microsoft Edge'), isTrue);
      expect(SenseRules.privateWindow('chrome.exe', 'Mon compte - Banque Populaire'), isTrue);
      expect(SenseRules.privateWindow('KeePassXC.exe', 'Passwords.kdbx'), isTrue);
      expect(SenseRules.privateWindow('hub.exe', 'Mon Hub'), isTrue);
      expect(SenseRules.privateWindow('chrome.exe', 'École Directe - Google Chrome'), isTrue);
      expect(SenseRules.privateWindow('chrome.exe', 'Volcan — Wikipédia - Google Chrome'), isFalse);
      expect(SenseRules.privateWindow('WINWORD.EXE', 'Exposé SVT - Word'), isFalse);
    });

    test('jamais pendant un appel', () {
      expect(SenseRules.callLikely(['Discord.exe'], const []), isTrue);
      expect(SenseRules.callLikely(['Teams.exe', 'chrome.exe'], const []), isTrue);
      expect(
        SenseRules.callLikely(['chrome.exe'], const [('Meet - abc-defg-hij - Google Chrome', 'chrome.exe')]),
        isTrue,
      );
      expect(
        SenseRules.callLikely(['chrome.exe'], const [('Cours de SVT - YouTube - Google Chrome', 'chrome.exe')]),
        isFalse,
      );
      // Discord ouvert à côté (sans son) : la vidéo du navigateur peut s'écouter.
      expect(
        SenseRules.callLikely(['chrome.exe'], const [('Discord', 'Discord.exe'), ('Vidéo - YouTube', 'chrome.exe')]),
        isFalse,
      );
      expect(SenseRules.callLikely(const [], const []), isFalse);
    });
  });

  group('ce qu\'il remarque', () {
    test('une erreur dans le code, pas dans un article', () {
      expect(
        SenseRules.errorShown(
          'Code.exe',
          'main.py - Visual Studio Code',
          'Traceback (most recent call last):\nNameError: name x is not defined',
        ),
        isTrue,
      );
      expect(SenseRules.errorShown('Thonny.exe', 'Thonny', 'SyntaxError: invalid syntax\nerror line 3'), isTrue);
      expect(
        SenseRules.errorShown(
          'chrome.exe',
          'Les erreurs courantes en français - Google Chrome',
          'Les erreurs les plus fréquentes',
        ),
        isFalse,
      );
      expect(SenseRules.errorShown('setup.exe', 'Erreur', 'Impossible de trouver le fichier.'), isTrue);
    });

    test('une date limite vue à l\'écran', () {
      final now = DateTime(2026, 11, 22, 18);
      final d = SenseRules.deadline('Devoir maison n°3\nÀ rendre le 28 novembre au plus tard.', now);
      expect(d, isNotNull);
      expect(d!.at.day, 28);
      expect(SenseRules.deadline('La réunion du G20 aura lieu jeudi à Rio.', now), isNull);
    });

    test('une vidéo en anglais, une phrase à retenir', () {
      expect(
        SenseRules.english(
          'So what we are going to do today is look at the cell and what it is made of, and you will see that this is easy',
        ),
        isTrue,
      );
      expect(
        SenseRules.english(
          'Alors aujourd\'hui on va voir la cellule et ce qui la compose, et vous allez voir que c\'est simple',
        ),
        isFalse,
      );
      expect(
        SenseRules.importantLine(
          'On commence. Retenez bien que la mitose donne deux cellules identiques. Ensuite on verra la méiose.',
        ),
        'Retenez bien que la mitose donne deux cellules identiques.',
      );
      expect(SenseRules.importantLine('Salut tout le monde, bienvenue sur la chaîne.'), isNull);
      expect(SenseRules.cleanHeard('[Musique] Bonjour à tous (applaudissements) ♪'), 'Bonjour à tous');
    });

    test('le silence et la musique ne se transcrivent pas', () {
      expect(SenseRules.quiet(_tone(500)), isTrue);
      expect(SenseRules.quiet(_tone(500, amp: 0.5)), isFalse);
    });

    test('la fenêtre a changé (sans tout relire)', () {
      final a = Uint8List(64 * 36 * 4);
      final b = Uint8List.fromList(a);
      for (var i = 0; i < b.length ~/ 2; i++) {
        b[i] = 255;
      }
      final ta = SenseRules.thumb(a, 64, 36), tb = SenseRules.thumb(b, 64, 36);
      expect(SenseRules.changed(ta, ta), isFalse);
      expect(SenseRules.changed(ta, tb), isTrue);
      expect(SenseRules.cleanOcr('  Bonjour   le monde \n\n ### \n ab \nLigne 2'), 'Bonjour le monde\nLigne 2');
    });

    test('le coup de pouce quand tu procrastines', () {
      final now = DateTime(2026, 11, 22, 19);
      final ticks = [
        for (var i = 0; i < 180; i++) (now.subtract(Duration(seconds: 15 * i)), i.isEven ? 'YouTube' : 'Roblox'),
      ];
      final (mins, app) = SenseRules.distraction(ticks, now);
      expect(mins, inInclusiveRange(45, 50));
      expect(app, anyOf('YouTube', 'Roblox'));
      final hw = [
        {'pour_le': DateTime(2026, 11, 23), 'matiere': 'MATHEMATIQUES', 'fait': false},
        {'pour_le': DateTime(2026, 11, 23), 'matiere': 'SVT', 'fait': false, 'controle': true},
        {'pour_le': DateTime(2026, 11, 25), 'matiere': 'ANGLAIS', 'fait': false},
      ];
      final line = SenseRules.procrastinationLine(minutes: mins, app: 'YouTube', homework: hw, now: now)!;
      expect(line, contains('un contrôle de SVT'));
      expect(line, contains('25 minutes'));
      // Fait, trop tôt, ou pas assez de distraction : rien.
      expect(SenseRules.procrastinationLine(minutes: 20, app: 'YouTube', homework: hw, now: now), isNull);
      expect(
        SenseRules.procrastinationLine(minutes: 50, app: 'YouTube', homework: hw, now: DateTime(2026, 11, 22, 10)),
        isNull,
      );
      expect(
        SenseRules.procrastinationLine(
          minutes: 50,
          app: 'YouTube',
          homework: [
            for (final h in hw) {...h, 'fait': true},
          ],
          now: now,
        ),
        isNull,
      );
    });
  });

  group('sans IA', () {
    final calls = <(String, Map<String, dynamic>)>[];
    Future<Object?> call(String name, Map<String, dynamic> a) async {
      calls.add((name, a));
      return switch (name) {
        'memoire_ecran' => {
          'resume': 'Oui ! Hier vers 16 h 10, dans Chrome : « Volcan ».',
          'resultats': [
            {'appli': 'Chrome'},
          ],
          'moments': [
            {'appli': 'YouTube'},
          ],
        },
        'sens_etat' => {'vient_d_etre_dit': 'la mitose donne deux cellules'},
        'memoire_oublier' => 'C\'est fait : j\'ai oublié les 10 dernières minutes (3 moments).',
        _ => {'ok': true},
      };
    }

    const tools = {'memoire_ecran', 'memoire_oublier', 'sens_etat', 'sens_regler'};

    test('« tu te souviens… ? », « qu\'est-ce que je faisais… ? »', () async {
      calls.clear();
      var r = await QuickAnswers.answer(
        'Tu te souviens du site sur les volcans que j\'ai vu hier ?',
        call: call,
        tools: tools,
      );
      expect(r!.text, contains('Volcan'));
      expect(calls.single.$2['texte'], 'site sur les volcans');
      expect(calls.single.$2['quand'], contains('hier'));
      r = await QuickAnswers.answer(
        'c\'était quoi la vidéo sur la mitose que j\'ai regardée mardi',
        call: call,
        tools: tools,
      );
      expect(r, isNotNull);
      r = await QuickAnswers.answer('qu\'est-ce que je faisais mardi vers 16h ?', call: call, tools: tools);
      expect(r, isNotNull);
      expect(calls.last.$2['quand'], contains('mardi'));
      // Ses souvenirs de vous deux : c'est pour l'IA, pas pour l'écran.
      expect(await QuickAnswers.answer('tu te souviens de moi ?', call: call, tools: tools), isNull);
    });

    test('« qu\'est-ce qu\'il a dit ? », oublier, fermer les yeux', () async {
      calls.clear();
      expect(
        (await QuickAnswers.answer('qu\'est-ce qu\'il a dit ?', call: call, tools: tools))!.text,
        contains('mitose'),
      );
      expect(
        (await QuickAnswers.answer('oublie les 10 dernières minutes', call: call, tools: tools))!.text,
        contains('oublié'),
      );
      expect(calls.last.$2['minutes'], 10);
      await QuickAnswers.answer('oublie la dernière heure', call: call, tools: tools);
      expect(calls.last.$2['minutes'], 60);
      expect(
        (await QuickAnswers.answer('ferme les yeux pendant 30 minutes', call: call, tools: tools))!.text,
        contains('30 min'),
      );
      expect(calls.last.$2['pause_minutes'], 30);
      await QuickAnswers.answer('regarde mon écran en continu', call: call, tools: tools);
      expect(calls.last.$2['ecran'], isTrue);
      await QuickAnswers.answer('arrête d\'écouter le son du PC', call: call, tools: tools);
      expect(calls.last.$2['son'], isFalse);
    });
  });

  group('les outils', () {
    test('chercher dans la mémoire et oublier', () async {
      final now = DateTime.now();
      await mem.add(
        ScreenMoment(
          at: now.subtract(const Duration(minutes: 30)),
          app: 'Chrome',
          title: 'Recette des crêpes',
          text: 'farine œufs lait',
        ),
        now: now,
      );
      final tools = {for (final t in ClickySenses.instance.tools(explain: (_) {})) t.name: t};
      final r = await tools['memoire_ecran']!.run({'texte': 'crêpes'}) as Map;
      expect(r['resume'], contains('Recette des crêpes'));
      expect((r['resultats'] as List).single['appli'], 'Chrome');
      final f = await tools['memoire_oublier']!.run({'minutes': 60});
      expect('$f', contains('oublié'));
      expect(mem.moments, isEmpty);
      String? asked;
      final t2 = {for (final t in ClickySenses.instance.tools(explain: (q) => asked = q)) t.name: t};
      await t2['clicky_expliquer_ecran']!.run({'question': 'Explique cette erreur'});
      expect(asked, 'Explique cette erreur');
    });
  });
}
