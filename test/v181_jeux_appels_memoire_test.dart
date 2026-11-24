import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/call_shield.dart';
import 'package:hub/core/camera_guard.dart';
import 'package:hub/core/game_pal.dart';
import 'package:hub/core/screen_time.dart';
import 'package:hub/ui/clicky/long_memory.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('un jeu, c\'est un vrai jeu', () {
    test('« tu joues à Claude » : plus jamais', () {
      for (final exe in ['claude.exe', 'Claude.exe', 'ChatGPT.exe', 'Notion.exe', 'WhatsApp.exe', 'Obsidian.exe']) {
        expect(GameRules.gameOf(exe: exe, path: r'C:\Users\Erik\AppData\Local\AnthropicClaude\app\claude.exe'), isNull,
            reason: exe);
        expect(GameMode.isGame(exe, true), isFalse, reason: exe);
      }
      // Une appli inconnue agrandie n'est pas un jeu non plus.
      expect(GameMode.isGame('MonLogicielDeCours.exe', true), isFalse);
    });

    test('les jeux connus', () {
      expect(GameRules.gameOf(exe: 'RobloxPlayerBeta.exe'), 'Roblox');
      expect(GameRules.gameOf(exe: 'FortniteClient-Win64-Shipping.exe'), 'Fortnite');
      expect(GameRules.gameOf(exe: 'VALORANT-Win64-Shipping.exe'), 'Valorant');
      expect(GameRules.gameOf(exe: 'javaw.exe', title: 'Minecraft 1.21.4'), 'Minecraft');
      // Java sans « Minecraft » dans le titre : peut-être un logiciel de cours.
      expect(GameRules.gameOf(exe: 'javaw.exe', title: 'GeoGebra Classic'), isNull);
    });

    test('rangé dans un dossier de jeux', () {
      expect(
        GameRules.gameOf(exe: 'eldenring.exe', path: r'D:\SteamLibrary\steamapps\common\ELDEN RING\Game\eldenring.exe'),
        'Elden Ring',
      );
      expect(
        GameRules.gameOf(exe: 'Hades2.exe', path: r'C:\Program Files (x86)\Steam\steamapps\common\Hades II\Hades2.exe'),
        'Hades II',
      );
      expect(GameRules.gameOf(exe: 'x.exe', path: r'C:\Program Files\Epic Games\RocketLeague\x.exe'), 'Rocket League');
      expect(GameRules.gameOf(exe: 'Blasphemous-Win64-Shipping.exe'), 'Blasphemous');
      // Le lanceur Steam lui-même n'est pas un jeu.
      expect(GameRules.gameOf(exe: 'steam.exe', path: r'C:\Program Files (x86)\Steam\steam.exe'), isNull);
    });

    test('un moteur de jeu à côté du programme (Unity / Unreal)', () {
      expect(GameRules.gameOf(exe: 'MonJeu.exe', title: 'Super Jeu', engine: true), 'Super Jeu');
      expect(GameRules.gameOf(exe: 'MonJeu.exe', title: 'Super Jeu'), isNull);
    });

    test('un site de jeux dans le navigateur', () {
      expect(GameRules.gameOf(exe: 'chrome.exe', title: 'Subway Surfers - Poki - Google Chrome'), 'Subway Surfers');
      expect(GameRules.gameOf(exe: 'chrome.exe', title: 'Claude - Google Chrome'), isNull);
    });

    test('mode jeu : il faut aussi le plein écran', () {
      expect(GameMode.isGame('RobloxPlayerBeta.exe', true), isTrue);
      expect(GameMode.isGame('RobloxPlayerBeta.exe', false), isFalse);
    });

    test('ce qu\'il dit à l\'IA : aider vraiment, sans triche', () {
      final p = GameRules.promptLine('Elden Ring', genres: 'Action, RPG', played: const Duration(minutes: 42));
      expect(p, contains('Elden Ring'));
      expect(p, contains('42 min'));
      expect(p, contains('astuces concrètes'));
      expect(p, contains('Pas de triche'));
    });

    test('la fiche du jeu (Steam en français)', () async {
      final pal = GamePal.instance
        ..client = MockClient((r) async {
          if (r.url.path.contains('storesearch')) {
            return http.Response(jsonEncode({'items': [{'id': 1245620, 'name': 'ELDEN RING'}]}), 200);
          }
          return http.Response(
            jsonEncode({
              '1245620': {
                'data': {
                  'name': 'ELDEN RING',
                  'short_description': 'Levez-vous, Sans-éclat, et puissiez-vous être guidé par la grâce.',
                  'genres': [{'description': 'Action'}, {'description': 'RPG'}],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
      final i = await pal.info('Elden Ring', now: DateTime(2026, 11, 24));
      expect(i, isNotNull);
      expect(i!.genres, 'Action, RPG');
      expect(i.summary, contains('Sans-éclat'));
      pal.client = null;
    });

    test('fiche nettoyée et coupée', () {
      expect(GameInfo.clean('<b>Super</b> jeu &amp; fun'), 'Super jeu & fun');
      expect(GameInfo.clean('${'a' * 400}. Fin.').length, lessThanOrEqualTo(321));
    });
  });

  group('bouclier d\'appel', () {
    SensorUse u(String app, {bool on = true}) => SensorUse(key: app, app: app, active: on);

    test('l\'appel en cours = une appli d\'appel qui a le micro', () {
      expect(CallRules.callApp(SensorState(uses: [u('Discord')])), 'Discord');
      expect(CallRules.callApp(SensorState(uses: [u('Mon Hub')])), isNull);
      expect(CallRules.callApp(SensorState(uses: [u('Discord', on: false)])), isNull);
    });

    test('pendant l\'appel : les autres applis qui filment ou écoutent', () {
      final cam = SensorState(uses: [u('Discord'), u('Spyware')]);
      final mic = SensorState(uses: [u('Discord'), u('Mon Hub'), u('Inconnu')]);
      final bad = CallRules.intruders(cam, mic, 'Discord');
      expect([for (final (s, m) in bad) '${s.app}:$m'], ['Spyware:false', 'Inconnu:true']);
      expect(CallRules.alert('Inconnu', 'Discord', mic: true), contains('écoute ton micro'));
      expect(CallRules.alert('Inconnu', 'Discord', mic: true), contains('ton appel continue'));
    });

    test('flouter dans chaque appli', () {
      expect(CallRules.blurHow('Discord'), contains('Arrière-plan vidéo'));
      expect(CallRules.blurHow('Chrome'), contains('Meet'));
      expect(CallRules.blurHow('Teams'), contains('Flou'));
      expect(CallRules.blurHow(''), contains('arrière-plan'));
    });

    test('« coupe mon micro » = sourdine tout de suite (pas un refus de Windows)', () async {
      final calls = <String>[];
      Future<Object?> call(String n, Map<String, dynamic> a) async {
        calls.add('$n ${a['mode'] ?? a['couper']}');
        return {'resume': 'ok'};
      }

      const tools = {'micro_sourdine', 'camera_couper', 'appel_flou'};
      await QuickAnswers.answer('Coupe mon micro', call: call, tools: tools);
      await QuickAnswers.answer('remets mon micro', call: call, tools: tools);
      await QuickAnswers.answer('je suis mute ?', call: call, tools: tools);
      await QuickAnswers.answer('coupe ma caméra', call: call, tools: tools);
      await QuickAnswers.answer('floute mon arrière-plan', call: call, tools: tools);
      expect(calls, ['micro_sourdine on', 'micro_sourdine off', 'micro_sourdine etat', 'camera_couper oui', 'appel_flou null']);
    });

    test('le script de sourdine vise le bon micro', () {
      expect(CallShield.muteScript, contains('GetDefaultAudioEndpoint(1'));
      expect(CallShield.muteScript, contains('SetMute'));
    });
  });

  group('sa mémoire', () {
    final now = DateTime(2026, 11, 24, 12);

    test('ranger, renforcer, sans doublon', () {
      var (l, added) = MemoryRules.merge(const [], [('', 'Il écrit des poèmes sur la mer')], now);
      expect(added, 1);
      expect(l.single.topic, 'projets');
      (l, added) = MemoryRules.merge(l, [('projets', 'il écrit des poèmes sur la mer')], now);
      expect(added, 0);
      expect(l.single.weight, 2);
      (l, added) = MemoryRules.merge(l, [('gouts', 'Il adore les mangas de sport')], now);
      expect(l.length, 2);
      expect(l.last.topic, 'gouts');
    });

    test('le sujet, deviné sans IA', () {
      expect(MemoryRules.topicOf('Il ne veut pas qu\'on lui parle de ses devoirs le soir'), 'a_eviter');
      expect(MemoryRules.topicOf('Son meilleur ami s\'appelle Léo'), 'proches');
      expect(MemoryRules.topicOf('Il est en seconde au lycée'), 'ecole');
      expect(MemoryRules.topicOf('Il adore Roblox'), 'gouts');
    });

    test('il oublie les détails, pas l\'important', () {
      final old = now.subtract(const Duration(days: 90));
      final l = [
        Memory(id: '1', topic: 'divers', text: 'Il a regardé une vidéo de chats', at: old, seen: old),
        Memory(id: '2', topic: 'gouts', text: 'Il adore Roblox', at: old, seen: old, weight: 4),
        Memory(id: '3', topic: 'a_eviter', text: 'Ne pas lui parler du coucher', at: old, seen: old),
        Memory(id: '4', topic: 'divers', text: 'Retenu exprès', at: old, seen: old, pinned: true),
      ];
      expect([for (final m in MemoryRules.prune(l, now)) m.id], ['2', '3', '4']);
    });

    test('les souvenirs utiles à la question, « à éviter » toujours en premier', () {
      final l = [
        Memory(id: '1', topic: 'gouts', text: 'Il adore les mangas de sport', at: now, seen: now),
        Memory(id: '2', topic: 'ecole', text: 'Il a du mal en physique', at: now, seen: now),
        Memory(id: '3', topic: 'a_eviter', text: 'Il ne veut pas qu\'on lui rappelle le coucher', at: now, seen: now),
      ];
      final r = MemoryRules.relevant(l, 'conseille-moi un manga', now, k: 2);
      expect(r.first.id, '3');
      expect(r.last.id, '1');
      expect(MemoryRules.promptBlock(r), contains('a_eviter'));
    });

    test('« retiens que… »', () {
      expect(MemoryRules.rememberRequest('Retiens que je préfère les mangas aux romans'), 'Il/elle préfère les mangas aux romans');
      expect(MemoryRules.rememberRequest('Smily, souviens-toi que mon frère s\'appelle Tom'), 'son frère s\'appelle Tom');
      expect(MemoryRules.rememberRequest('retiens bien ça'), isNull);
      expect(MemoryRules.rememberRequest('quelle heure est-il ?'), isNull);
    });

    test('le rêve de l\'IA locale lu, sans secrets', () {
      final r = MemoryRules.parseDream('''Voilà :
```json
{"souvenirs": [{"sujet": "projets", "texte": "Il écrit un recueil de poèmes"},
 {"sujet": "moi", "texte": "Son mot de passe est chat123"}],
 "capacites": [{"phrase": "mode poème", "consigne": "propose 3 thèmes puis corrige les rimes"}],
 "reve": "J'ai rêvé que tes poèmes s'envolaient comme des oiseaux."}
```''')!;
      expect(r.memories, [('projets', 'Il écrit un recueil de poèmes')]);
      expect(r.skills.single.$1, 'mode poème');
      expect(r.dream, contains('oiseaux'));
      expect(r.local, isTrue);
      expect(MemoryRules.parseDream('pas de json'), isNull);
    });

    test('sans IA locale : des règles', () {
      final r = MemoryRules.byRules([
        'j\'adore les mangas de foot',
        'mon frère s\'appelle Tom',
        'quelle heure est-il',
        'je ne veux plus que tu me parles du coucher',
      ]);
      expect(r.memories.length, 3);
      expect(r.memories.last.$1, 'a_eviter');
      expect(r.local, isFalse);
    });

    test('il rêve quand tu es absent, pas trop souvent, et s\'il y a du nouveau', () {
      expect(MemoryRules.dreamDue(away: const Duration(minutes: 30), last: null, fresh: 5, now: now), isTrue);
      expect(MemoryRules.dreamDue(away: const Duration(minutes: 5), last: null, fresh: 5, now: now), isFalse);
      expect(MemoryRules.dreamDue(away: const Duration(minutes: 30), last: null, fresh: 1, now: now), isFalse);
      expect(
        MemoryRules.dreamDue(away: const Duration(hours: 1), last: now.subtract(const Duration(hours: 2)), fresh: 9, now: now),
        isFalse,
      );
    });

    test('ce qu\'il raconte au réveil', () {
      const r = DreamResult(dream: 'J\'ai rêvé de poèmes.', skills: [('mode poème', 'x')], local: true);
      final s = MemoryRules.morning(r, 3);
      expect(s, contains('🌙'));
      expect(s, contains('3 nouveaux souvenirs'));
      expect(s, contains('rien n\'est sorti du PC'));
      expect(s, contains('« mode poème »'));
    });

    test('« qu\'est-ce que tu sais sur moi ? » sans IA', () async {
      final r = await QuickAnswers.answer(
        'Qu\'est-ce que tu sais sur moi ?',
        call: (n, a) async => {
          'souvenirs': [{'texte': 'Il écrit des poèmes'}],
        },
        tools: const {'memoire_souvenirs'},
      );
      expect(r?.text, contains('Il écrit des poèmes'));
    });
  });
}
