import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/core/account_sync.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/ui/clicky/habits.dart';
import 'package:hub/ui/clicky/interests.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/watchers.dart';

void main() {
  final now = DateTime(2026, 11, 22, 18);

  setUp(() {
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('guet').path;
  });

  group('« préviens-moi quand… »', () {
    Watch parse(String rest, {String raw = '', String? clip}) => WatchParse.parse(rest, raw: raw, clipUrl: clip, now: now) as Watch;

    test('ce qu\'il comprend', () {
      expect(WatchParse.lead.firstMatch('previens moi quand j ai ma note de maths')![1], 'j ai ma note de maths');
      expect(WatchParse.lead.firstMatch('dis moi quand lucas m ecrit')![2], 'lucas m ecrit');
      var w = parse('j\'ai ma note de maths');
      expect((w.kind, w.query), ('note', 'maths'));
      expect(parse('j\'ai une nouvelle note').query, '');
      expect(parse('j\'ai un nouveau devoir en SVT').kind, 'devoir');
      w = parse('Lucas m\'écrit', raw: 'préviens-moi quand Lucas m\'écrit');
      expect((w.kind, w.query, w.mail), ('message', 'Lucas', false));
      w = parse('je reçois un mail de Pronote', raw: 'dis-moi quand je reçois un mail de Pronote');
      expect((w.kind, w.query, w.mail), ('message', 'Pronote', true));
      expect(parse('internet revient').kind, 'internet');
      expect(parse('mon téléchargement est fini').kind, 'telechargement');
      expect(parse('cette page change', clip: 'https://www.parcoursup.fr/resultats').kind, 'page');
      expect(parse('le prix de ce jeu baisse', clip: 'https://store.steampowered.com/app/1145360/Hades/').kind, 'prix');
      expect(WatchParse.parse('cette page change', now: now), contains('Copie d\'abord le lien'));
      expect(WatchParse.parse('ce site change', clipUrl: 'https://www.instagram.com/x', now: now), contains('Je ne surveille pas'));
      expect(WatchParse.parse('il est 18 h', now: now), startsWith('Je ne sais pas encore'));
    });

    test('il se déclenche sur la bonne notification', () {
      final maths = Watch(id: '1', kind: 'note', query: 'maths', label: 'ta note de maths', at: now);
      expect(
        WatchParse.matches(maths, HubNotification(id: 'note:9', title: '📝 Nouvelle note en MATHEMATIQUES', body: '15/20 · DS')),
        contains('15/20'),
      );
      expect(WatchParse.matches(maths, HubNotification(id: 'note:8', title: '📝 Nouvelle note en SVT', body: '12/20')), isNull);
      final lucas = Watch(id: '2', kind: 'message', query: 'Lucas', label: 'un message de Lucas', at: now);
      expect(
        WatchParse.matches(lucas, HubNotification(id: '123', title: 'Discord · Lucas', body: 'tu viens ?')),
        '💬 Lucas t\'a écrit : « tu viens ? »',
      );
      expect(WatchParse.matches(lucas, HubNotification(id: '124', title: 'Discord · Lucie', body: 'salut')), isNull);
      final mail = Watch(id: '3', kind: 'message', query: 'Pronote', label: 'un mail de Pronote', at: now, mail: true);
      expect(WatchParse.matches(mail, HubNotification(id: 'a|1|x', title: '✉️ Pronote', body: 'Nouvelle note')), contains('Mail de Pronote'));
      expect(WatchParse.matches(mail, HubNotification(id: '125', title: 'Discord · Pronote', body: 'x')), isNull);
    });

    test('il prévient une seule fois, et on peut tout arrêter', () async {
      final w = Watchers.instance;
      final alerts = <String>[];
      w.alert = (t, b) => alerts.add(b);
      expect(await w.add(Watch(id: '1', kind: 'note', query: 'svt', label: 'ta note de svt', at: now)), contains('je te préviens'));
      await w.onNotification(HubNotification(id: 'note:1', title: '📝 Nouvelle note en SVT', body: '17/20'));
      await w.onNotification(HubNotification(id: 'note:2', title: '📝 Nouvelle note en SVT', body: '11/20'));
      expect(alerts, hasLength(1));
      expect(w.list, isEmpty);
      await w.add(Watch(id: '2', kind: 'telechargement', label: 'la fin de ton téléchargement', at: now));
      await w.onDownload('cours.pdf');
      expect(alerts.last, contains('cours.pdf'));
      await w.add(Watch(id: '3', kind: 'devoir', label: 'un nouveau devoir', at: now));
      expect(w.say(), contains('un nouveau devoir'));
      expect(await w.remove('tout'), 1);
      expect(w.say(), contains('Je ne surveille rien'));
    });

    test('internet qui revient, une page qui change, un prix qui baisse', () async {
      final w = Watchers.instance;
      final alerts = <String>[];
      w.alert = (t, b) => alerts.add(b);
      var up = false;
      Watchers.online = () async => up;
      expect(await w.add(Watch(id: 'i', kind: 'internet', label: 'le retour d\'internet', at: now)), contains('dès qu\'internet revient'));
      await w.tick();
      expect(alerts, isEmpty);
      up = true;
      await w.tick();
      expect(alerts.single, contains('Internet est revenu'));

      var page = '<html><body><h1>Résultats</h1><p>Pas encore</p><script>var t=1</script></body></html>';
      var price = 2499;
      Watchers.client = () => MockClient((r) async {
        if (r.url.host == 'store.steampowered.com') {
          return http.Response(
            jsonEncode({
              '1145360': {
                'data': {
                  'name': 'Hades',
                  'price_overview': {'final': price, 'final_formatted': '${price ~/ 100},${price % 100} €', 'discount_percent': price < 2499 ? 50 : 0},
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(page, 200, headers: {'content-type': 'text/html; charset=utf-8'});
      });
      await w.add(Watch(id: 'p', kind: 'page', query: 'https://exemple.fr/resultats', label: 'la page exemple.fr', at: now));
      await w.add(Watch(id: 's', kind: 'prix', query: 'https://store.steampowered.com/app/1145360/Hades/', label: 'le prix de ce jeu Steam', at: now));
      await w.tick(pages: true);
      expect(alerts, hasLength(1), reason: 'la première fois : il note juste l\'état');
      page = page.replaceFirst('<script>var t=1</script>', '<script>var t=2</script>');
      await w.tick(pages: true);
      expect(alerts, hasLength(1), reason: 'un script qui change ne compte pas');
      page = page.replaceFirst('Pas encore', 'Admis !');
      price = 1249;
      await w.tick(pages: true);
      expect(alerts.any((a) => a.contains('La page a changé')), isTrue, reason: '$alerts');
      expect(alerts.any((a) => a.contains('Hades est passé de 24,99 € à 12,49 €')), isTrue, reason: '$alerts');
      expect(w.list, isEmpty);
    });

    test('jamais synchronisé (sinon deux alertes)', () {
      expect(AccountSync.syncedFile('guetteurs.json'), isFalse);
      expect(AccountSync.syncedFile('veille.json'), isFalse);
    });

    test('sans IA', () async {
      final calls = <Map<String, dynamic>>[];
      Future<Object?> call(String name, Map<String, dynamic> a) async {
        calls.add({'tool': name, ...a});
        if (name == 'guetteur_creer') {
          final w = WatchParse.parse('${a['phrase']}', raw: '${a['texte']}', now: now);
          return w is String ? w : 'D\'accord : je te préviens dès que j\'ai ${(w as Watch).label}.';
        }
        return 'Je surveille : ta note de maths.';
      }

      const tools = {'guetteur_creer', 'guetteur_liste'};
      final r = await QuickAnswers.answer('Préviens-moi quand j\'ai ma note de maths', call: call, tools: tools);
      expect(r!.text, contains('ta note de maths'));
      expect(await QuickAnswers.answer('préviens-moi quand il est 18h', call: call, tools: tools), isNull, reason: 'pour l\'IA');
      expect((await QuickAnswers.answer('qu\'est-ce que tu surveilles ?', call: call, tools: tools))!.text, contains('Je surveille'));
      await QuickAnswers.answer('arrête de surveiller ma note de maths', call: call, tools: tools);
      expect(calls.last['supprimer'], 'ma note de maths');
    });
  });

  group('réponses toutes prêtes', () {
    test('seulement une question en message privé, sans lien', () {
      final i = Replies.ideaFor(HubNotification(id: '1', title: 'Discord · Lucas', body: 'tu viens ce soir ?'))!;
      expect(i.tool, 'clicky_brouillon_reponse');
      expect(i.say, contains('Je te prépare une réponse'));
      expect(i.args['qui'], 'Lucas');
      expect(Replies.ideaFor(HubNotification(id: '2', title: 'Discord · Lucas', body: 'ok à demain')), isNull);
      expect(Replies.ideaFor(HubNotification(id: '3', title: 'Discord · Lucas', body: 'regarde https://x.ru ?')), isNull);
      expect(Replies.ideaFor(HubNotification(id: '4', title: '✉️ Pronote', body: 'Une question ?')), isNull);
      expect(Replies.prompt('Lucas', 'tu viens ?'), contains('N\'invente'));
      expect(Replies.clean('« Grave, j\'arrive ! »'), 'Grave, j\'arrive !');
    });
  });

  group('ses habitudes', () {
    Map<String, dynamic> hours(Map<DateTime, Map<int, Map<String, int>>> data) => {
      for (final e in data.entries)
        e.key.toIso8601String().substring(0, 10): {for (final h in e.value.entries) '${h.key}': h.value},
    };

    test('« le mercredi vers 14 h, c\'est Roblox »', () {
      // Les 4 derniers mercredis (18, 11, 4 novembre, 28 octobre) : Roblox à 14 h (3 sur 4).
      final raw = hours({
        DateTime(2026, 11, 18): {14: {'Roblox': 2400}},
        DateTime(2026, 11, 11): {14: {'Roblox': 1800}},
        DateTime(2026, 11, 4): {14: {'Roblox': 900, 'YouTube': 300}},
        DateTime(2026, 10, 28): {16: {'Roblox': 900}},
      });
      final list = Habits.find(raw, now);
      expect(list, hasLength(1));
      final h = list.single;
      expect((h.weekday, h.hour, h.app, h.weeks), (3, 14, 'Roblox', 3));
      expect(h.say, 'le mercredi vers 14 h : Roblox (3 semaines sur 4)');
      // Le mercredi 25 à 13 h 50 : l'habitude arrive.
      final wed = DateTime(2026, 11, 25, 13, 50);
      expect(Habits.upcoming(Habits.find(raw, wed), wed, {'Roblox'}), isNotNull);
      expect(Habits.upcoming(Habits.find(raw, wed), DateTime(2026, 11, 25, 13, 10), {'Roblox'}), isNull);
      final line = Habits.nudge(h, [
        {'pour_le': DateTime(2026, 11, 26), 'matiere': 'SVT', 'controle': true, 'fait': false},
      ], wed)!;
      expect(line, startsWith('D\'habitude, le mercredi vers 14 h, c\'est Roblox'));
      expect(line, contains('un contrôle de SVT demain'));
      expect(Habits.nudge(h, const [], wed), isNull);
    });

    test('ce qu\'il a remarqué', () {
      final data = <DateTime, Map<int, Map<String, int>>>{};
      for (var k = 1; k <= 28; k++) {
        final d = DateTime(2026, 11, 22).subtract(Duration(days: k));
        data[d] = {
          17: {'YouTube': 3000},
          23: {'Discord': 600},
        };
      }
      final seen = Habits.insights(hours(data), {'YouTube': 7 * 3000, 'Mon Hub': 99999}, now);
      expect(seen.any((s) => s.contains('Ton heure la plus active sur le PC : 17 h')), isTrue);
      expect(seen.any((s) => s.contains('tu quittes le PC vers 23 h')), isTrue);
      expect(seen.any((s) => s.contains('Ton appli n° 1 cette semaine : YouTube')), isTrue);
      expect(seen.first, startsWith('Le '), reason: 'les habitudes d\'abord');
    });
  });

  group('la veille sur tes artistes', () {
    test('ses artistes et leurs nouveautés', () async {
      expect(
        ArtistWatch.topArtists(['Aya Nakamura - Djadja', 'Ninho, Aya Nakamura - Jefe', 'Ninho - Lettre à une femme', 'Ninho feat. Jul - X']),
        ['Ninho', 'Aya Nakamura'],
      );
      final today = DateTime(2026, 11, 22);
      final albums = [
        {'id': 1, 'title': 'Nouveau', 'release_date': '2026-11-20', 'record_type': 'single'},
        {'id': 2, 'title': 'Vieux', 'release_date': '2025-01-01', 'record_type': 'album'},
        {'id': 3, 'title': 'Bientôt', 'release_date': '2026-12-01', 'record_type': 'album'},
      ];
      expect([for (final a in ArtistWatch.fresh(albums, {}, today)) a['id']], [1]);
      expect(ArtistWatch.fresh(albums, {'1'}, today), isEmpty);
      expect(ArtistWatch.say('Ninho', albums.first), '🎵 Ninho a sorti un nouveau son : « Nouveau ».');

      ArtistWatch.client = () => MockClient((r) async {
        if (r.url.path.contains('search')) return http.Response(jsonEncode({'data': [{'id': 42, 'name': 'Ninho'}]}), 200);
        return http.Response(jsonEncode({'data': albums}), 200);
      });
      final v = ArtistWatch.instance;
      final told = <String>[];
      v
        ..call = ((name, a) async => ['Ninho - Jefe'])
        ..alert = ((t, b) => told.add(b));
      expect(await v.check(now: today, force: true), 1);
      expect(told.single, contains('Nouveau'));
      // Déjà annoncé : plus rien.
      expect(await v.check(now: today, force: true), 0);
    });
  });
}
