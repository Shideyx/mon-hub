import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/ui/clicky/robots.dart';
import 'package:hub/ui/clicky/robots_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('Créer un robot en une phrase, sans IA', () {
    test('une heure', () {
      final r = RobotRules.parse('Crée un robot : tous les jours à 19h, j\'ai quoi à faire pour demain')!;
      expect(r.trigger, 'heure');
      expect(r.value, '19:00');
      expect(r.actions, ['phrase:j ai quoi a faire pour demain']);
      expect(r.when, 'Tous les jours à 19 h');
      final s = RobotRules.parse('le samedi à 10h30 mets de la musique')!;
      expect(s.value, '10:30');
      expect(s.days, [6]);
    });

    test('une appli qui s\'ouvre, avec plusieurs actions', () {
      final r = RobotRules.parse('quand j\'ouvre Discord, coupe mon micro puis dis-moi de rester poli')!;
      expect(r.trigger, 'appli');
      expect(r.value, 'discord');
      expect(r.actions, ['phrase:coupe mon micro', 'dire:Rester poli']);
    });

    test('un jeu, un retour, un message, le temps d\'écran', () {
      expect(RobotRules.parse('quand je lance un jeu, coach-moi')!.trigger, 'jeu');
      expect(RobotRules.parse('quand je reviens, qu\'est-ce que j\'ai raté')!.trigger, 'retour');
      final m = RobotRules.parse('quand je reçois un message de Léa, préviens-moi')!;
      expect(m.trigger, 'message');
      expect(m.value, 'lea');
      expect(m.actions, ['notifier:']);
      final u = RobotRules.parse('toutes les 45 minutes, dis-moi de m\'étirer')!;
      expect(u.trigger, 'usage');
      expect(u.value, '45');
    });

    test('une vraie question ne crée pas de robot', () {
      expect(RobotRules.parse('quand j\'ouvre Discord il plante, pourquoi ?'), isNull);
      expect(RobotRules.looksLikeRobot('c est quoi un robot aspirateur'), isFalse);
      expect(RobotRules.looksLikeRobot('cree un robot quand j ouvre discord coupe mon micro'), isTrue);
    });
  });

  group('Quand un robot part', () {
    final now = DateTime(2026, 11, 25, 19, 1);

    test('à l\'heure, une seule fois', () {
      final r = RobotRules.parse('tous les jours à 19h, j\'ai quoi demain')!;
      expect(RobotRules.firesOnTick(r, RobotTick(now: now), null), isTrue);
      expect(RobotRules.firesOnTick(r, RobotTick(now: now), null, lastRun: now), isFalse);
      expect(RobotRules.firesOnTick(r, RobotTick(now: DateTime(2026, 11, 25, 18, 59)), null), isFalse);
    });

    test('quand l\'appli arrive au premier plan (pas à chaque tour)', () {
      final r = RobotRules.parse('quand j\'ouvre Discord, coupe mon micro')!;
      final before = RobotTick(now: now, app: 'chrome.exe google');
      final on = RobotTick(now: now, app: 'discord.exe #général - discord');
      expect(RobotRules.firesOnTick(r, on, before), isTrue);
      expect(RobotRules.firesOnTick(r, on, on), isFalse);
    });

    test('un jeu qui commence, un retour après une absence', () {
      final g = RobotRules.parse('quand je lance un jeu, coach-moi')!;
      expect(RobotRules.firesOnTick(g, RobotTick(now: now, game: 'Fortnite'), RobotTick(now: now)), isTrue);
      final b = RobotRules.parse('quand je reviens, qu\'est-ce que j\'ai raté')!;
      expect(RobotRules.firesOnTick(b, RobotTick(now: now), RobotTick(now: now, idleSeconds: 3600)), isTrue);
      expect(RobotRules.firesOnTick(b, RobotTick(now: now), RobotTick(now: now, idleSeconds: 30)), isFalse);
    });

    test('pas plus de N fois par jour', () {
      final r = RobotRules.parse('quand je lance un jeu, coach-moi')!
        ..runsDay = RobotRules.dayKey(now)
        ..runs = 3;
      expect(RobotRules.firesOnTick(r, RobotTick(now: now, game: 'Roblox'), RobotTick(now: now)), isFalse);
    });

    test('un message de la bonne personne', () {
      final r = RobotRules.parse('quand je reçois un message de Léa, préviens-moi')!;
      expect(
        RobotRules.firesOnNote(r, HubNotification(id: '1', title: 'Discord · Léa', body: 'salut', moduleId: 'discord'), now),
        isTrue,
      );
      expect(
        RobotRules.firesOnNote(r, HubNotification(id: '2', title: 'Discord · Tom', body: 'yo', moduleId: 'discord'), now),
        isFalse,
      );
      expect(RobotRules.firesOnNote(r, HubNotification(id: 'note:1', title: 'Note', body: '15'), now), isFalse);
    });

    test('les robots tout prêts sont valables', () {
      for (final t in RobotRules.templates) {
        final r = t.build();
        expect(Robot.fromJson(r.toJson())?.actions, t.actions, reason: t.id);
        expect(r.when, isNotEmpty);
      }
      expect(RobotRules.templates.where((t) => t.byDefault).length, greaterThanOrEqualTo(3));
    });
  });

  testWidgets('la page « Ses robots » s\'ouvre', (tester) async {
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('robots').path;
    await tester.runAsync(() => Robots.instance.load());
    await tester.pumpWidget(const MaterialApp(home: RobotsPage()));
    await tester.pump();
    expect(find.text('Ses robots'), findsOneWidget);
    expect(find.textContaining('aucun jeton'), findsWidgets);
  });
}
