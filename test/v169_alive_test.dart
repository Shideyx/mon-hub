import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/ui/clicky/life.dart';
import 'package:hub/ui/clicky/life_view.dart';
import 'package:hub/ui/clicky/mind.dart';
import 'package:material_ui/material_ui.dart';

/// Du son à 16 kHz (PCM 16 bits) : un léger bruit, et des coups forts aux
/// instants [hits] (en millisecondes).
Uint8List _sound(int ms, List<int> hits, {int seed = 1}) {
  final r = math.Random(seed);
  final n = ms * 16;
  final data = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final t = i ~/ 16;
    final loud = hits.any((h) => t >= h && t < h + 60);
    final v = loud ? (math.sin(i * 0.3) * 20000) : (r.nextDouble() - 0.5) * 600;
    data.setInt16(i * 2, v.round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('sa journée', () {
    test('fatigué le soir, en forme l\'après-midi', () {
      expect(ClickyLife.energyAt(DateTime(2026, 11, 22, 16)), greaterThan(0.8));
      expect(ClickyLife.sleepyAt(DateTime(2026, 11, 22, 23, 30)), isTrue);
      expect(ClickyLife.sleepyAt(DateTime(2026, 11, 23, 2)), isTrue);
      expect(ClickyLife.sleepyAt(DateTime(2026, 11, 22, 15)), isFalse);
    });

    test('les accessoires des fêtes', () {
      expect(ClickyLife.seasonAccessory(DateTime(2026, 12, 5))!.$1, '🎅');
      expect(ClickyLife.seasonAccessory(DateTime(2026, 10, 31))!.$1, '🎃');
      expect(ClickyLife.seasonAccessory(DateTime(2027, 1, 1))!.$1, '🥳');
      expect(ClickyLife.seasonAccessory(DateTime(2027, 4, 1))!.$1, '🐟');
      expect(ClickyLife.seasonAccessory(DateTime(2027, 3, 10)), isNull);
    });

    test('les accessoires de la vraie météo', () {
      expect(ClickyLife.weatherAccessory({'temperature': 2.0, 'maintenant': '2 °C, ciel couvert', 'icone': '☁️'})!.$1, '🧣');
      expect(ClickyLife.weatherAccessory({'temperature': 2.0, 'maintenant': '2 °C, ciel couvert'})!.$2, contains('2 °C'));
      expect(ClickyLife.weatherAccessory({'temperature': 12.0, 'maintenant': '12 °C, pluie modérée'})!.$1, '☂️');
      expect(ClickyLife.weatherAccessory({'temperature': -1.0, 'maintenant': '-1 °C, chute de neige', 'icone': '❄️'})!.$1, '⛄');
      expect(ClickyLife.weatherAccessory({'temperature': 31.0, 'maintenant': '31 °C, ciel dégagé'})!.$1, '😎');
      expect(ClickyLife.weatherAccessory({'temperature': 15.0, 'maintenant': '15 °C, ciel dégagé'}), isNull);
    });

    test('il change d\'accessoire et le dit une seule fois', () {
      final life = ClickyLife();
      final day = DateTime(2026, 11, 22, 9);
      final cold = {'temperature': 1.0, 'maintenant': '1 °C, brouillard'};
      expect(life.refreshAccessory(day, weather: cold), contains('écharpe'));
      expect(life.accessory, '🧣');
      // Le même accessoire : rien de plus à dire.
      expect(life.refreshAccessory(day, weather: cold), isNull);
      // Le café du matin passe avant, sans commentaire.
      expect(life.refreshAccessory(day, weather: cold, coffee: true), isNull);
      expect(life.accessory, '☕');
      // De retour à l'écharpe : déjà dit aujourd'hui.
      expect(life.refreshAccessory(day, weather: cold), isNull);
      expect(life.accessory, '🧣');
      // Noël passe avant la météo.
      life.refreshAccessory(DateTime(2026, 12, 3, 9), weather: cold);
      expect(life.accessory, '🎅');
      // Sa vie coupée : plus rien sur lui.
      life.refreshAccessory(DateTime(2026, 12, 3, 9), weather: cold, off: true);
      expect(life.accessory, '');
    });
  });

  group('ce qu\'il ressent', () {
    test('une note, un cours annulé, une arnaque', () {
      final good = ClickyLife.feelingFor('note:1', '📝 Nouvelle note en MATHEMATIQUES', '17/20 · Contrôle')!;
      expect(good.$1, '🤩');
      expect(good.$2, contains('17/20'));
      expect(good.$2, contains('MATHEMATIQUES'));
      final bad = ClickyLife.feelingFor('note:2', '📝 Nouvelle note en SVT', '7,5/20')!;
      expect(bad.$1, '🫂');
      expect(bad.$2, contains('ensemble'));
      final ok = ClickyLife.feelingFor('note:3', '📝 Nouvelle note en ANGLAIS', '12/20')!;
      expect(ok.$1, '🙂');
      expect(ok.$2, isNull);
      expect(ClickyLife.feelingFor('annule:SVT@x', '🎉 Cours annulé : SVT', 'demain')!.$1, '🥳');
      expect(ClickyLife.feelingFor('arnaque:42', 'Lien dangereux', '')!.$1, '🚨');
      expect(ClickyLife.feelingFor('devoir:9', '⚠️ Contrôle en SVT', 'Pour demain')!.$1, '😬');
      expect(ClickyLife.feelingFor('maj', 'Mise à jour', ''), isNull);
    });

    test('jamais saoulant : 2 bulles par heure, 10 min d\'écart, 8 par jour', () {
      final life = ClickyLife();
      final t = DateTime(2026, 11, 22, 14);
      expect(life.mayTalk(t), isTrue);
      life.talked(t);
      expect(life.mayTalk(t.add(const Duration(minutes: 5))), isFalse);
      expect(life.mayTalk(t.add(const Duration(minutes: 11))), isTrue);
      life.talked(t.add(const Duration(minutes: 11)));
      expect(life.mayTalk(t.add(const Duration(minutes: 30))), isFalse, reason: 'déjà 2 dans l\'heure');
      expect(life.mayTalk(t.add(const Duration(minutes: 72))), isTrue);
      for (var i = 0; i < 6; i++) {
        life.talked(t.add(Duration(hours: 2 + i)));
      }
      expect(life.mayTalk(t.add(const Duration(hours: 10))), isFalse, reason: '8 dans la journée');
      // « Discret » : une par heure, 30 min d'écart.
      final calm = ClickyLife()..pace = 'discret';
      calm.talked(t);
      expect(calm.mayTalk(t.add(const Duration(minutes: 20))), isFalse);
      expect(calm.mayTalk(t.add(const Duration(minutes: 50))), isFalse);
      expect(calm.mayTalk(t.add(const Duration(minutes: 61))), isTrue);
    });

    test('les émojis ne reviennent pas en boucle', () {
      final life = ClickyLife();
      final t = DateTime(2026, 11, 22, 23);
      expect(life.mayEmoji('baille', t, const Duration(minutes: 20)), isTrue);
      expect(life.mayEmoji('baille', t.add(const Duration(minutes: 10)), const Duration(minutes: 20)), isFalse);
      expect(life.mayEmoji('baille', t.add(const Duration(minutes: 21)), const Duration(minutes: 20)), isTrue);
      expect(life.once('nuit:2026-11-22'), isTrue);
      expect(life.once('nuit:2026-11-22'), isFalse);
    });
  });

  group('ses réactions', () {
    test('souris secouée : la tête lui tourne (pas en bougeant normalement)', () {
      final shake = WiggleDetector.shake();
      var hit = false;
      for (var i = 0; i < 20 && !hit; i++) {
        hit = shake.add(i * 60, i.isEven ? 100 : 300);
      }
      expect(hit, isTrue);
      final calm = WiggleDetector.shake();
      var moved = false;
      for (var i = 0; i < 60; i++) {
        moved = moved || calm.add(i * 16, i * 8.0);
      }
      expect(moved, isFalse);
    });

    test('petits allers-retours : une caresse (pas une secousse)', () {
      final pet = WiggleDetector.pet();
      var hit = false;
      for (var i = 0; i < 30 && !hit; i++) {
        hit = pet.add(i * 50, 500 + (i.isEven ? 0 : 18));
      }
      expect(hit, isTrue);
      final big = WiggleDetector.pet();
      var wrong = false;
      for (var i = 0; i < 30; i++) {
        wrong = wrong || big.add(i * 50, i.isEven ? 0 : 400);
      }
      expect(wrong, isFalse);
    });

    test('clics énervés au même endroit', () {
      final rage = RageClickDetector();
      var hit = false;
      for (var i = 0; i < 6; i++) {
        hit = rage.add(i * 200, 300 + i * 2.0, 400);
      }
      expect(hit, isTrue);
      // Juste après : pas deux fois de suite.
      var again = false;
      for (var i = 0; i < 6; i++) {
        again = again || rage.add(2000 + i * 200, 300, 400);
      }
      expect(again, isFalse);
      // Des clics normaux, ailleurs à chaque fois.
      final calm = RageClickDetector();
      var spread = false;
      for (var i = 0; i < 6; i++) {
        spread = spread || calm.add(i * 300, i * 200.0, 100);
      }
      expect(spread, isFalse);
    });

    test('il trouve le rythme d\'une musique (pas d\'une voix)', () {
      final beat = BeatDetector();
      final hits = [for (var t = 500; t < 6000; t += 500) t];
      final pcm = _sound(6200, hits);
      var found = 0;
      // Par petits morceaux, comme le son du PC.
      for (var i = 0; i < pcm.length; i += 3200) {
        found += beat.push(Uint8List.sublistView(pcm, i, math.min(pcm.length, i + 3200)));
      }
      expect(found, greaterThanOrEqualTo(8));
      expect(beat.steady, isTrue);
      expect(beat.bpm, inInclusiveRange(110, 130));
      // Des coups au hasard : pas de rythme.
      final talk = BeatDetector();
      final r = math.Random(3);
      var t = 400;
      final random = <int>[];
      while (t < 6000) {
        random.add(t);
        t += 300 + r.nextInt(900);
      }
      talk.push(_sound(6200, random, seed: 2));
      expect(talk.steady, isFalse);
    });

    test('les jeux, où l\'on clique vite exprès', () {
      expect(ClickyLife.gameLike('RobloxPlayerBeta.exe', 'Roblox'), isTrue);
      expect(ClickyLife.gameLike('chrome.exe', 'Cookie Clicker - Google Chrome'), isTrue);
      expect(ClickyLife.gameLike('WINWORD.EXE', 'Document1 - Word'), isFalse);
    });

    test('les petits mouvements', () {
      expect(LifeMotion.at(bob: 0.5).$1, closeTo(-4, 0.001));
      expect(LifeMotion.at().$1, 0);
      expect(LifeMotion.at(asleep: true).$2, closeTo(0.45, 0.001));
      expect(LifeMotion.at(wobble: 0.1).$2, isNot(0));
    });
  });

  group('ses rêves et ce qu\'il dit de lui', () {
    test('des rêves avec ce qu\'il a vécu', () {
      for (var i = 0; i < 12; i++) {
        final d = ClickyLife.dreamFrom(app: 'Roblox', artist: 'Aya Nakamura', random: math.Random(i));
        expect(d, anyOf(startsWith('J\'ai rêvé'), startsWith('Cette nuit')));
      }
      final prompt = ClickyLife.dreamPrompt(name: 'Sam', app: 'Roblox');
      expect(prompt, contains('Roblox'));
      expect(prompt, contains('J\'ai rêvé'));
      expect(ClickyLife.cleanDream('« J\'ai rêvé que ton clavier jouait du piano tout seul. »'),
          'J\'ai rêvé que ton clavier jouait du piano tout seul.');
      expect(ClickyLife.cleanDream('Bonjour !'), isNull);
      expect(ClickyLife.cleanDream('Voici un rêve : j\'ai rêvé de toi, longtemps, très longtemps.'), isNull);
    });

    test('un rêve par jour, après une vraie sieste', () {
      final life = ClickyLife();
      final t = DateTime(2026, 11, 22, 8);
      expect(life.dreamDue(const Duration(minutes: 20), t), isFalse);
      expect(life.dreamDue(const Duration(hours: 2), t), isTrue);
      life.dreamt('J\'ai rêvé que je volais.', t);
      expect(life.dreamDue(const Duration(hours: 2), t), isFalse);
      expect(life.dreamDue(const Duration(hours: 2), t.add(const Duration(days: 1))), isTrue);
      // Gardé d'un démarrage à l'autre.
      final again = ClickyLife()..restore(life.toJson());
      expect(again.lastDream, 'J\'ai rêvé que je volais.');
      expect(again.dreamDue(const Duration(hours: 2), t), isFalse);
    });

    test('il dort, se réveille, et sait combien de temps', () {
      var now = DateTime(2026, 11, 22, 14);
      final life = ClickyLife(clock: () => now);
      life.fallAsleep();
      expect(life.shown, '💤');
      now = now.add(const Duration(minutes: 50));
      expect(life.wake(), const Duration(minutes: 50));
      expect(life.asleep, isFalse);
      expect(life.answer('t\'as bien dormi ?', now: now), contains('50 minutes'));
    });

    test('ses réponses sur lui, sans IA', () async {
      final life = ClickyLife();
      final now = DateTime(2026, 11, 22, 23, 40);
      expect(life.answer('Clicky, tu dors ?', now: now), contains('sieste'));
      life.fallAsleep();
      expect(life.answer('tu dors ?', now: now), contains('pixels'));
      life.wake();
      expect(life.answer('t\'as rêvé de quoi ?', now: now), contains('souviens'));
      life.dreamt('J\'ai rêvé que ta souris me courait après.', now);
      expect(life.answer('t\'as rêvé de quoi ?', now: now), contains('souris'));
      life.refreshAccessory(DateTime(2026, 11, 22, 9), weather: {'temperature': 1.0, 'maintenant': '1 °C'});
      expect(life.answer('pourquoi t\'as une écharpe ?', now: now), startsWith('🧣'));
      expect(life.answer('pourquoi tu as un problème avec moi', now: now), isNull);
      expect(life.answer('t\'es fatigué ?', now: now), contains('bâille'));
      String? pace;
      bool? dance;
      expect(
        life.answer('sois plus discret', now: now, setPace: (p) async => pace = p),
        contains('tout petit'),
      );
      expect(pace, 'discret');
      expect(life.discreet, isTrue);
      expect(life.answer('arrête de danser', now: now, setDance: (v) async => dance = v), contains('sage'));
      expect(dance, isFalse);
      expect(life.answer('quelle heure est-il ?', now: now), isNull);
    });

    test('un petit mot pour l\'IA, seulement s\'il y a quelque chose', () {
      final life = ClickyLife();
      expect(life.promptBlock(DateTime(2026, 11, 22, 15)), contains('pleine forme'));
      life.refreshAccessory(DateTime(2026, 11, 22, 15), weather: {'temperature': 30.0, 'maintenant': '30 °C'});
      final block = life.promptBlock(DateTime(2026, 11, 22, 15));
      expect(block, contains('😎'));
      expect(block, contains('jamais plus d\'une phrase'));
      expect(ClickyLife().promptBlock(DateTime(2026, 11, 22, 7)), isEmpty);
    });
  });

  group('ses réglages', () {
    final mind = ClickyMind.instance;
    setUp(() async {
      HubFiles.overrideRoot = Directory.systemTemp.createTempSync('vie').path;
      await mind.load();
    });

    test('tout est là par défaut, et se coupe à part', () async {
      expect(mind.life, isTrue);
      expect(mind.lifeDance, isTrue);
      expect(mind.lifePerch, isTrue);
      expect(mind.lifeReact, isTrue);
      expect(mind.lifePace, 'normal');
      await mind.set('life.dance', false);
      await mind.setLifePace('discret');
      expect(mind.lifeDance, isFalse);
      expect(mind.lifePace, 'discret');
      await mind.saveLife({'reve': 'J\'ai rêvé.'});
      expect(mind.lifeState['reve'], 'J\'ai rêvé.');
      final before = mind.moodAt(DateTime.now());
      await mind.petted();
      expect(mind.moodAt(DateTime.now()), greaterThan(before));
    });
  });

  group('à l\'écran', () {
    testWidgets('l\'émoji, le 💤 et l\'accessoire à côté du curseur', (tester) async {
      final life = ClickyLife();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ClickyLifeBody(life: life, child: const SizedBox(width: 26, height: 26)),
            ),
          ),
        ),
      );
      expect(find.text('🤩'), findsNothing);
      life.show('🤩', seconds: 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('🤩'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('🤩'), findsNothing);
      life.refreshAccessory(DateTime(2026, 12, 5));
      await tester.pump();
      expect(find.text('🎅'), findsOneWidget);
      life.fallAsleep();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('💤'), findsOneWidget);
      // En dormant, il ne porte rien (le 💤 suffit).
      expect(find.text('🎅'), findsNothing);
      life.wake();
      // Un battement de musique : il bouge en rythme.
      life.onBeat(steady: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('🎵'), findsNothing, reason: 'il ne danse que quand la musique joue');
      life.setDancing(true);
      life.onBeat(steady: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('🎵'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
