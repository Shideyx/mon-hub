import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/ai_text.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/modules/ecoledirecte/ecoledirecte_module.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/revisions/fiche_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hub/modules/revisions/fsrs.dart';
import 'package:hub/modules/revisions/revisions_module.dart';
import 'package:hub/modules/revisions/revisions_store.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  prepTests();
  final t0 = DateTime(2026, 11, 17, 18);

  test('FSRS : « Bien » espace de plus en plus, « À revoir » fait revenir vite', () {
    var c = StudyCard(id: '1', front: 'Capitale de l\'Italie', back: 'Rome');
    // Nouvelle carte : « Bien » = encore une fois dans 10 min.
    c = Fsrs.review(c, 3, t0);
    expect(c.state, 1);
    expect(c.due.difference(t0).inMinutes, 10);
    // Deuxième « Bien » : apprise, revient dans quelques jours.
    var now = t0.add(const Duration(minutes: 10));
    c = Fsrs.review(c, 3, now);
    expect(c.state, 2);
    final first = c.due.difference(now).inDays;
    expect(first, inInclusiveRange(1, 6));
    // Chaque « Bien » le jour prévu allonge l'intervalle.
    var last = first;
    for (var i = 0; i < 4; i++) {
      now = c.due;
      c = Fsrs.review(c, 3, now);
      final gap = c.due.difference(now).inDays;
      expect(gap, greaterThan(last));
      last = gap;
    }
    // Oubli : à réapprendre dans 10 min, stabilité plus faible.
    final before = c.stability;
    now = c.due;
    c = Fsrs.review(c, 1, now);
    expect(c.state, 3);
    expect(c.lapses, 1);
    expect(c.stability, lessThan(before));
    expect(c.due.difference(now).inMinutes, 10);
  });

  test('FSRS : Facile > Bien > Difficile, et les étiquettes des boutons', () {
    final c = Fsrs.review(Fsrs.review(StudyCard(id: '1', front: 'a', back: 'b'), 3, t0), 3, t0.add(const Duration(minutes: 10)));
    final now = c.due;
    final days = [for (final g in [2, 3, 4]) Fsrs.review(c, g, now).due.difference(now).inDays];
    expect(days[0], lessThanOrEqualTo(days[1]));
    expect(days[1], lessThan(days[2]));
    expect(Fsrs.label(StudyCard(id: 'n', front: 'a', back: 'b'), 1, t0), '1 min');
    expect(Fsrs.label(StudyCard(id: 'n', front: 'a', back: 'b'), 4, t0), '2 sem');
    // Probabilité de se souvenir : 90 % au bout d'un intervalle.
    expect(Fsrs.recall(Fsrs.interval(10), 10), closeTo(0.9, 0.001));
  });

  test('réponse écrite : accents, majuscules, petites fautes, plusieurs réponses', () {
    expect(Answer.correct('revolution francaise', 'Révolution française'), isTrue);
    expect(Answer.correct('Révolutoin française', 'Révolution française'), isTrue);
    expect(Answer.correct('rome', 'Rome / la capitale'), isTrue);
    expect(Answer.correct('Milan', 'Rome'), isFalse);
    expect(Answer.correct('', 'Rome'), isFalse);
  });

  test('import « question - réponse » et cartes de Clicky', () {
    final l = RevisionsStore.parseLines('Capitale de l\'Italie - Rome\n1789 : Révolution française\nH2O = eau\nligne sans réponse\n- Mitochondrie\tcentrale énergétique');
    expect(l, [
      ('Capitale de l\'Italie', 'Rome'),
      ('1789', 'Révolution française'),
      ('H2O', 'eau'),
      ('Mitochondrie', 'centrale énergétique'),
    ]);
    final cards = RevisionsModule.parseCards('Voici :\n```json\n[{"q":"Date de la chute du mur","r":"1989"},{"question":"Doctrine de 1947","reponse":"Truman"},{"q":"","r":"x"}]\n```');
    expect(cards, [('Date de la chute du mur', '1989'), ('Doctrine de 1947', 'Truman')]);
  });

  test('quiz : 4 réponses dont la bonne, sans doublon', () {
    final all = [for (var i = 0; i < 8; i++) StudyCard(id: '$i', front: 'q$i', back: 'r$i')];
    final o = QuizPage.options(all[2], all, math.Random(1));
    expect(o, hasLength(4));
    expect(o, contains('r2'));
    expect(o.toSet(), hasLength(4));
  });

  test('séances, série de jours, cartes générées par Clicky', () async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final dir = Directory.systemTemp.createTempSync('rev');
    HubFiles.overrideRoot = dir.path;
    try {
      final s = RevisionsStore.instance;
      await s.load();
      final d = await s.createDeck('Histoire');
      expect(await s.addCards(d.id, [('Chute du mur', '1989'), ('Doctrine Truman', '1947'), ('', 'vide')]), 2);
      await s.setNewPerDay(1);
      // Une seule nouvelle carte permise par jour.
      expect(s.session(now: t0), hasLength(1));
      final (deck, card) = s.session(now: t0).first;
      await s.grade(deck.id, card, 3, now: t0);
      expect(s.today(t0).fresh, 1);
      expect(s.freshLeft(t0), 0);
      expect(s.streak(t0), 1);
      await s.addMinutes(20, now: t0.subtract(const Duration(days: 1)));
      expect(s.streak(t0), 2);
      // Le lendemain sans rien faire : la série tient encore.
      expect(s.streak(t0.add(const Duration(days: 1))), 2);
      expect(s.streak(t0.add(const Duration(days: 3))), 0);

      // Clicky fabrique des cartes (IA simulée).
      AiText.override = (prompt, system) async {
        expect(prompt, contains('guerre froide'));
        return '[{"q":"Qui a construit le mur de Berlin ?","r":"La RDA"},{"q":"Année de la crise de Cuba","r":"1962"}]';
      };
      final m = RevisionsModule()..attach();
      final made = await m.generate(text: 'Cours sur la guerre froide : le mur de Berlin, la crise de Cuba…', count: 2);
      expect(made, hasLength(2));
      final tool = m.tools.firstWhere((t) => t.name == 'revision_paquets');
      final r = await tool.run({}) as Map;
      expect([for (final p in r['paquets'] as List) p['nom']], contains('Histoire'));
    } finally {
      AiText.override = null;
      HubFiles.overrideRoot = null;
      ClickyController.instance.toString();
    }
  });

  test('plan avant un contrôle : J-4, J-2, J-1 dans les créneaux libres', () async {
    final m = RevisionsModule();
    final now = DateTime(2026, 11, 16, 8); // lundi
    // Contrôle le lundi 23 : jeudi 19 (J-4), samedi 21 (J-2), dimanche 22 (J-1).
    final test = EdHomework('1', DateTime(2026, 11, 23), 'Mathématiques', 'Chapitre 4 : suites', false, true);
    final plan = await m.planFor([test], now: now);
    expect(plan.map((e) => e.start.day), [19, 21, 22]);
    // En semaine après les cours, le week-end le matin.
    expect(plan.first.start.hour, 17);
    expect(plan.last.start.hour, 10);
    expect(plan.first.title, 'Révision Mathématiques');
    expect(plan.first.note, contains('suites'));
  });
}

void prepTests() {
  test('contrôle détecté : fiche, cartes et quiz préparés tout seuls, une seule fois', () async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('prep').path;
    final ecole = EcoleDirecteModule()..attach();
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day + 3);
    ecole.homework = [
      EdHomework('42', due, 'SVT', 'Contrôle sur la génétique (chapitre 3)', false, true),
      EdHomework('43', due, 'Anglais', 'Exercice 2', false, false),
    ];
    final m = RevisionsModule(ecole: ecole)..attach();
    var asked = '';
    AiText.override = (prompt, system) async {
      asked = prompt;
      return '```json\n{"titre": "La génétique", "fiche": "# La génétique\\n## L\'essentiel\\n- Un **gène** est une portion d\'ADN.", '
          '"cartes": [{"q": "Qu\'est-ce qu\'un gène ?", "r": "Une portion d\'ADN"}, {"q": "ADN ?", "r": "Acide désoxyribonucléique"}], '
          '"quiz": [{"q": "Où est l\'ADN ?", "bonne": "Dans le noyau", "fausses": ["Dans la membrane", "Dans le sang", "Nulle part"]}]}\n```';
    };
    try {
      final note = await m.autoPrepare();
      expect(note, isNotNull);
      expect(note!.title, contains('SVT'));
      expect(asked, contains('génétique'));
      final deck = RevisionsStore.instance.forTest(RevisionsModule.testKey(ecole.homework.first))!;
      expect(deck.name, '📝 SVT — La génétique');
      expect(deck.sheet, startsWith('# La génétique'));
      expect(deck.cards, hasLength(2));
      expect(deck.quiz.single.wrong, hasLength(3));
      // Déjà prêt : rien de plus.
      expect(await m.autoPrepare(), isNull);
      // La fiche se met en page sans erreur.
      expect(FicheView(markdown: deck.sheet!, color: Colors.orange), isNotNull);
    } finally {
      AiText.override = null;
      HubFiles.overrideRoot = null;
    }
  });
}
