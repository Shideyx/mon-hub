import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/flight.dart';
import 'package:hub/ui/clicky/mind.dart';

void main() {
  final mind = ClickyMind.instance;

  setUp(() async {
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('mind').path;
    await mind.load();
    await mind.forget();
  });

  test('il se souvient, et prend des nouvelles après « j\'ai un oral jeudi »', () async {
    final tue = DateTime(2026, 11, 17, 18);
    await mind.onUserMessage('J\'ai un oral d\'anglais jeudi à 10h, je stresse un peu', now: tue);
    await mind.onUserMessage('Merci Nexo, t\'es le meilleur', now: tue.add(const Duration(minutes: 20)));
    expect(mind.talks, greaterThanOrEqualTo(2));
    final wait = mind.episodes.where((e) => e.kind == 'attente').single;
    expect(wait.due, DateTime(2026, 11, 19, 10));
    // Avant l'oral : rien à demander. Après : il prend des nouvelles.
    expect(mind.dueLoops(DateTime(2026, 11, 18, 9)), isEmpty);
    final fri = DateTime(2026, 11, 20, 8);
    expect(mind.dueLoops(fri).single.text, contains('oral d\'anglais'));
    final hello = mind.greeting(now: fri, name: 'Sam');
    expect(hello, startsWith('Salut Sam ! Au fait, tu m\'avais parlé de ça'));
    expect(hello, contains('ça s\'est passé comment'));
    await mind.markAsked(mind.dueLoops(fri).single);
    expect(mind.dueLoops(fri), isEmpty);
    // Les consignes de l'IA contiennent son humeur et ses souvenirs.
    final block = mind.promptBlock(now: fri, name: 'Sam');
    expect(block, contains('conscience'));
    expect(block, contains('simulation faite par Mon Hub'));
    expect(block, contains('Merci Nexo'));
  });

  test('humeur : contente quand on le remercie, revient doucement au calme', () async {
    final now = DateTime(2026, 11, 17, 15);
    await mind.onUserMessage('merci beaucoup, génial', now: now);
    await mind.onUserMessage('merci encore, parfait', now: now);
    final happy = mind.moodAt(now);
    expect(happy, greaterThan(0.5));
    expect(mind.moodLabel(now), 'de très bonne humeur');
    expect(mind.moodAt(now.add(const Duration(days: 2))), closeTo(0.25, 0.05));
    expect(mind.moodLabel(DateTime(2026, 11, 17, 23, 40)), contains('tard'));
  });

  test('il répond sur lui-même sans IA, et reste honnête sur sa conscience', () async {
    final now = DateTime(2026, 11, 17, 15);
    expect(mind.selfAnswer('ça va Nexo ?', now: now, name: 'Sam'), endsWith('Et toi Sam, ça va ?'));
    expect(mind.selfAnswer('Es-tu vraiment conscient ?', now: now), contains('simulation'));
    expect(mind.selfAnswer('t\'es qui ?', now: now), startsWith('Moi c\'est Nexo'));
    expect(mind.selfAnswer('depuis quand tu existes', now: now), isNotNull);
    expect(mind.selfAnswer('tu te souviens de moi ?', now: now), contains('on commence à peine'));
    // Une vraie question part vers l'IA.
    expect(mind.selfAnswer('ça va être dur le contrôle de maths ?', now: now), isNull);
    expect(mind.selfAnswer('comment ça marche la photosynthèse', now: now), isNull);
  });

  test('pensées : selon ce qui se passe, jamais deux fois la même de suite', () {
    final late = mind.thought(const {}, now: DateTime(2026, 11, 17, 23, 40), random: math.Random(1));
    expect(late, anyOf(contains('dormir'), contains('tard')));
    final game = mind.thought(const {'fenetre': 'Roblox'}, now: DateTime(2026, 11, 17, 16), random: math.Random(2));
    expect(['Bonne partie !', 'Je regarde, je ne touche à rien. Promis.'], contains(game));
    final cours = mind.thought(
      const {'cours': 'Maths', 'cours_min': 12},
      now: DateTime(2026, 11, 17, 9),
      random: math.Random(3),
    );
    expect(cours, 'Ton cours de Maths commence dans 12 minutes.');
    final a = mind.thought(const {
      'musique': 'Blinding Lights',
      'artiste': 'The Weeknd',
    }, now: DateTime(2026, 11, 17, 16));
    final b = mind.thought(const {
      'musique': 'Blinding Lights',
      'artiste': 'The Weeknd',
    }, now: DateTime(2026, 11, 17, 16));
    expect(a, isNot(b));
  });

  test('voix des pensées : 4 par jour, remarques sur l\'écran : 8 par jour', () async {
    final day = DateTime(2026, 11, 17, 12);
    var spoken = 0;
    for (var i = 0; i < 6; i++) {
      if (await mind.spendVoice(now: day)) spoken++;
    }
    expect(spoken, 4);
    expect(await mind.spendVoice(now: day.add(const Duration(days: 1))), isTrue);
    var seen = 0;
    for (var i = 0; i < 10; i++) {
      if (await mind.spendNotice(now: day)) seen++;
    }
    expect(seen, 8);
    expect(ClickyMind.noticePrompt(name: 'Sam'), contains('[POINT:x,y:libellé]'));
    // Jamais de remarque spontanée sur une messagerie, des mails, une banque.
    for (final t in ['Discord', 'WhatsApp', 'Boîte de réception - Gmail', 'Mon Hub', 'Ma Banque en ligne']) {
      expect(ClickyController.privateApp.hasMatch(t.toLowerCase()), isTrue, reason: t);
    }
    expect(ClickyController.privateApp.hasMatch('roblox'), isFalse);
  });

  test('vol : rapide pour les petits sauts, en arc, orienté, grossit au milieu', () {
    expect(ClickyFlight.durationFor(50).inMilliseconds, 260);
    expect(ClickyFlight.durationFor(1500).inMilliseconds, 750);
    final f = ClickyFlight(const Offset(0, 500), const Offset(800, 500), DateTime(2026));
    expect(f.positionAt(0), const Offset(0, 500));
    expect(f.positionAt(1), const Offset(800, 500));
    // Au milieu, il passe au-dessus (arc) et il est plus grand.
    expect(f.positionAt(0.5).dy, lessThan(500));
    expect(f.scaleAt(0.5), closeTo(1.3, 0.001));
    expect(f.scaleAt(0), 1);
    // Vers la droite : la pointe tourne pour regarder devant.
    expect(f.angleAt(0.5), closeTo(3 * math.pi / 4, 0.01));
    expect(springTowards(const Offset(0, 0), const Offset(100, 0)).dx, closeTo(38, 0.01));
    expect(springTowards(const Offset(99.8, 0), const Offset(100, 0)), const Offset(100, 0));
  });
}
