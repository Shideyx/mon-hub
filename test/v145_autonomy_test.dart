import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/ui/clicky/autonomy.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/mind.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final mind = ClickyMind.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('autonomie').path;
    await mind.load();
    await mind.forget();
  });

  test('il décide seul, mais jamais d\'envoyer un message ni de supprimer', () {
    const tools = {
      'revision_preparer_controle',
      'discord_envoyer',
      'agenda_supprimer',
      'pc_commande',
      'musique_commande',
    };
    expect(Autonomy.usable('revision_preparer_controle', tools), isTrue);
    expect(Autonomy.usable('musique_commande', tools), isTrue);
    expect(Autonomy.usable('discord_envoyer', tools), isFalse);
    expect(Autonomy.usable('agenda_supprimer', tools), isFalse);
    expect(Autonomy.usable('pc_commande', tools), isFalse);
    expect(Autonomy.usable('agent', tools), isTrue);
    // Une décision de l'IA bien formée…
    final i = Autonomy.parse({
      'dire': 'Ton contrôle de SVT est jeudi. Je te prépare une fiche et des cartes ?',
      'outil': 'revision_preparer_controle',
      'args': {'matiere': 'SVT'},
      'pourquoi': 'contrôle dans 2 jours',
    }, tools)!;
    expect((i.tool, i.args['matiere'], i.why), ('revision_preparer_controle', 'SVT', 'contrôle dans 2 jours'));
    // … et ce qui est refusé.
    expect(Autonomy.parse({'rien': true}, tools), isNull);
    expect(Autonomy.parse({'dire': 'J\'envoie un message à Léa ?', 'outil': 'discord_envoyer'}, tools), isNull);
    expect(
      Autonomy.parse({
        'dire': 'Je cherche ?',
        'outil': 'agent',
        'args': {'tache': 'x'},
      }, tools),
      isNull,
    );
    expect(ClickyIdea.fromJson(i.toJson())!.say, i.say);
    // La consigne ne propose pas les actions interdites.
    final prompt = Autonomy.prompt(
      situation: '📚 Pas de cours aujourd\'hui.',
      tools: [
        HubTool(name: 'discord_envoyer', description: 'Envoie un message', run: (_) async => null),
        HubTool(name: 'revision_lancer', description: 'Ouvre une séance de révision', run: (_) async => null),
      ],
      name: 'Sam',
      now: DateTime(2026, 11, 17, 18),
    );
    expect(prompt, contains('revision_lancer'));
    expect(prompt, isNot(contains('discord_envoyer')));
    expect(prompt, contains('{"rien":true}'));
  });

  test('sans IA : des décisions évidentes selon l\'heure et la situation', () {
    const all = {
      'revision_preparer_controle',
      'assistant_briefing',
      'assistant_ajouter_plan_journee',
      'revision_lancer',
    };
    expect(Autonomy.rules({'controle': 'Maths'}, DateTime(2026, 11, 17, 18), available: all)!.args['matiere'], 'Maths');
    expect(Autonomy.rules({}, DateTime(2026, 11, 17, 8), available: all)!.tool, 'assistant_briefing');
    expect(
      Autonomy.rules({'trop': true}, DateTime(2026, 11, 17, 18), available: all)!.tool,
      'assistant_ajouter_plan_journee',
    );
    expect(Autonomy.rules({'cartes': 15}, DateTime(2026, 11, 17, 19), available: all)!.tool, 'revision_lancer');
    expect(Autonomy.rules({'cartes': 15}, DateTime(2026, 11, 17, 13), available: all), isNull);
    // Ce qu'il a appris à ne plus proposer.
    expect(
      Autonomy.rules(
        {'controle': 'Maths'},
        DateTime(2026, 11, 17, 18),
        available: all,
        skip: {'revision_preparer_controle'},
      ),
      isNull,
    );
  });

  test('tu réponds « oui » ou « non » à voix haute', () {
    for (final y in ['oui', 'Ouais vas-y', 'OK', 'd\'accord', 'vas-y', 'Nexo fais-le', 'carrément']) {
      expect(Autonomy.answer(y), isTrue, reason: y);
    }
    for (final n in ['non', 'non merci', 'pas maintenant', 'laisse tomber', 'plus tard']) {
      expect(Autonomy.answer(n), isFalse, reason: n);
    }
    // Une vraie question n'est pas une réponse.
    expect(Autonomy.answer('oui mais comment on fait une dissertation ?'), isNull);
    expect(Autonomy.answer('non je voulais savoir l\'heure'), isNull);
  });

  test('il apprend de tes réponses, et respecte un rythme', () async {
    final now = DateTime(2026, 11, 17, 18);
    await mind.recordDecision('revision_lancer', true, now: now);
    await mind.recordDecision('revision_lancer', true, now: now);
    await mind.recordDecision('musique_commande', false, now: now);
    await mind.recordDecision('musique_commande', false, now: now);
    expect(mind.likes, 'revision_lancer');
    expect(mind.dislikes, 'musique_commande');
    expect(mind.skipTools(now), {'musique_commande'});
    expect(mind.skipTools(now.add(const Duration(days: 8))), isEmpty);
    // Rythme « normal » : 45 min entre deux idées, 5 par jour, jamais la nuit.
    expect(mind.ideaAllowed(now), isTrue);
    await mind.ideaProposed('a', now);
    expect(mind.ideaAllowed(now.add(const Duration(minutes: 30))), isFalse);
    expect(mind.ideaAllowed(now.add(const Duration(minutes: 46))), isTrue);
    expect(mind.ideaSeen('a'), isTrue);
    expect(mind.ideaAllowed(DateTime(2026, 11, 18, 2)), isFalse);
    await mind.setPace('souvent');
    expect(mind.ideaGap, const Duration(minutes: 25));
    expect(
      mind.welcomeBack(now: now, name: 'Sam', away: const Duration(hours: 2)),
      startsWith('Ça fait un moment Sam'),
    );
  });

  testWidgets('son idée s\'affiche avec Oui / Non / Plus tard', (tester) async {
    final c = ClickyController.instance;
    c.idea = ClickyIdea(say: 'Je t\'organise ta soirée ?', tool: 'outil_absent', why: 'soirée chargée');
    c.reply = 'Je t\'organise ta soirée ?';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ClickyBox(c: c)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Oui, vas-y'), findsOneWidget);
    expect(find.text('Pourquoi : soirée chargée'), findsOneWidget);
    await tester.ensureVisible(find.text('Non'));
    await tester.pump();
    await tester.tap(find.text('Non'));
    await tester.pump();
    expect(c.idea, isNull);
    expect(mind.dislikes, isEmpty); // un seul « non » ne suffit pas
    // La boîte s'efface toute seule après quelques secondes.
    await tester.pump(const Duration(seconds: 20));
    c.reply = '';
  });
}
