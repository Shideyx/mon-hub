import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/ai_text.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/modules/carnet/carnet_store.dart';
import 'package:hub/modules/revisions/revisions_store.dart';
import 'package:hub/ui/clicky/assistant_view.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hub/ui/clicky/assistant.dart';
import 'package:hub/ui/clicky/initiatives.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Mardi 17 novembre 2026, 17 h.
  final now = DateTime(2026, 11, 17, 17);
  String day(int plus) => DateTime(2026, 11, 17 + plus).toIso8601String();

  test('anticipation : la veille, et 3 jours avant un contrôle', () {
    final hw = <Map>[
      {'matiere': 'Maths', 'contenu': 'Exercices 3 et 4 page 52', 'pour_le': day(1), 'fait': false},
      {'matiere': 'SVT', 'contenu': 'Contrôle chapitre 3', 'pour_le': day(3), 'fait': false, 'controle': true},
      {'matiere': 'Anglais', 'contenu': 'Lire le texte', 'pour_le': day(3), 'fait': false},
      {'matiere': 'Histoire', 'contenu': 'Fiche', 'pour_le': day(1), 'fait': true},
    ];
    final a = Assistant.homeworkAlerts(hw, now);
    expect(a.map((x) => x.$2), ['⏰ Pour demain : Maths', '📝 Contrôle de SVT dans 3 jours']);
    // Le matin, pas encore d'alerte « pour demain ».
    expect(Assistant.homeworkAlerts(hw, DateTime(2026, 11, 17, 9)).length, 1);
  });

  test('organisation : deux évènements qui se chevauchent (pas deux cours)', () {
    final ev = <Map>[
      {'titre': 'Maths', 'debut': '2026-11-18T14:00', 'fin': '2026-11-18T15:00', 'source': 'École Directe'},
      {'titre': 'Physique', 'debut': '2026-11-18T14:30', 'fin': '2026-11-18T15:30', 'source': 'École Directe'},
      {'titre': 'Dentiste', 'debut': '2026-11-18T14:30', 'fin': '2026-11-18T15:00', 'source': 'Google Agenda'},
      {'titre': 'Foot', 'debut': '2026-11-18T18:00', 'fin': '2026-11-18T19:00', 'source': 'Mes évènements'},
    ];
    final c = Assistant.conflicts(ev);
    expect(c.map((x) => '${x.$1['titre']}/${x.$2['titre']}'), ['Maths/Dentiste', 'Physique/Dentiste']);
  });

  test('conseils : un contrôle demain passe avant un exercice dans 5 jours ; un retard tout en haut', () {
    final hw = <Map>[
      {'matiere': 'Anglais', 'contenu': 'Exercice', 'pour_le': day(5), 'fait': false},
      {'matiere': 'SVT', 'contenu': 'Contrôle', 'pour_le': day(1), 'fait': false, 'controle': true},
    ];
    final todos = [
      CarnetItem({
        'id': '1',
        'text': 'Rendre le livre au CDI',
        'due': DateTime(2026, 11, 14).millisecondsSinceEpoch,
        'at': 0,
      }),
      CarnetItem({'id': '2', 'text': 'Ranger ma chambre', 'at': DateTime(2026, 11, 16).millisecondsSinceEpoch}),
    ];
    final r = Assistant.rank(hw, todos, now);
    expect(r.first.text, 'Rendre le livre au CDI');
    expect(r.first.reason, 'en retard de 3 jours');
    expect(r[1].text, 'Réviser SVT');
    expect(r.indexWhere((t) => t.text.startsWith('Anglais')), greaterThan(1));
    expect(Assistant.overloaded(r), isFalse);
  });

  test('assistance : les tâches sont placées dans les créneaux libres, avec une pause', () {
    final tasks = [
      RankedTask('Réviser SVT', 90, 'contrôle demain', minutes: 45),
      RankedTask('Maths', 60, 'pour demain', minutes: 30),
      RankedTask('Anglais', 30, 'pour dans 5 jours', minutes: 45),
    ];
    final plan = Assistant.planSlots(['17:00-18:00', '18:30-20:00'], tasks, DateTime(2026, 11, 17));
    expect(
      [for (final p in plan) '${p['debut']!.substring(11)} ${p['titre']}'],
      ['17:00 Réviser SVT', '18:30 Maths', '19:10 Anglais'],
    );
  });

  test('mémoire : projets, décisions et objectifs repérés dans ce qu\'on dit', () {
    expect(Assistant.detectMemory('J\'ai décidé de faire du sport le mardi soir.'), (
      'décision',
      'Faire du sport le mardi soir',
    ));
    expect(Assistant.detectMemory('Mon objectif est d\'avoir 15 en maths'), ('objectif', 'Avoir 15 en maths'));
    expect(Assistant.detectMemory('Mon projet c\'est de créer une appli de musique'), (
      'projet',
      'Créer une appli de musique',
    ));
    expect(Assistant.detectMemory('Quelle heure est-il ?'), isNull);
  });

  test('initiatives : un rendez-vous ou une date limite repérés dans un message', () {
    final r = DateSpotter.find('Bonjour, la réunion parents-professeurs aura lieu le 20 novembre à 18h30. Merci.', now);
    expect(r.length, 1);
    expect(r.first.kind, 'rdv');
    expect(r.first.at, DateTime(2026, 11, 20, 18, 30));
    final dm = DateSpotter.find('Le DM est à rendre pour le 3 décembre', now).single;
    expect((dm.kind, dm.hasTime, dm.at), ('limite', false, DateTime(2026, 12, 3)));
    final friend = DateSpotter.find('on se voit demain à 14h ?', now).single;
    expect((friend.kind, friend.at), ('rdv', DateTime(2026, 11, 18, 14)));
    expect(DateSpotter.find('rdv jeudi 9h', now).single.at, DateTime(2026, 11, 19, 9));
    expect(DateSpotter.find('Salut, ça va ?', now), isEmpty);
    expect(DateSpotter.find('La réunion était hier', now), isEmpty);
    expect(Assistant.spotTitle(friend, who: 'Léa'), 'On se voit avec Léa');
  });

  test('initiatives : les notes', () {
    expect(DateSpotter.grade20('12,5/20'), 12.5);
    expect(DateSpotter.grade20('8/10'), 16);
    expect(DateSpotter.grade20('Abs'), isNull);
  });

  test('idées de Gemini : un évènement sans date valide devient une tâche', () {
    final ideas = Assistant.parseIdeas(
      jsonDecode(
        '[{"titre":"Préparer ton sac","texte":"Sortie demain","action":"tache"},'
        '{"titre":"Courir 20 min","texte":"Créneau libre","action":"evenement","quand":"2026-11-17T18:00","duree_min":20},'
        '{"titre":"Vieux","action":"evenement","quand":"2026-11-10T10:00"},{"texte":"sans titre"}]',
      ),
      now,
    );
    expect(
      [for (final i in ideas) '${i.title}:${i.action}'],
      ['Préparer ton sac:tache', 'Courir 20 min:evenement', 'Vieux:tache'],
    );
    expect(ideas[1].minutes, 20);
  });

  test('voix : pas d\'emojis lus à voix haute', () {
    expect(withoutEmoji('☀️ Bonjour !\n📚 Emploi du temps'), 'Bonjour !\nEmploi du temps');
  });

  test('briefing du matin : tout y est, sans IA', () {
    final d = <String, Object?>{
      'date': DateTime(2026, 11, 17, 7, 30),
      'meteo': {
        'icone': '🌧️',
        'maintenant': '8 °C, pluie',
        'min': 6,
        'max': 11,
        'tenue': 'Prends un manteau.',
        'pluie_pourcent': 80,
      },
      'cours': <Map>[
        {'titre': 'Maths', 'debut': '2026-11-17T08:00', 'fin': '2026-11-17T09:00', 'source': 'École Directe'},
        {
          'titre': 'SVT',
          'debut': '2026-11-17T10:00',
          'fin': '2026-11-17T11:00',
          'source': 'École Directe',
          'annule': true,
        },
        {'titre': 'Anglais', 'debut': '2026-11-17T15:00', 'fin': '2026-11-17T16:00', 'source': 'École Directe'},
      ],
      'rdv': <Map>[
        {'titre': 'Dentiste', 'debut': '2026-11-17T17:30', 'source': 'Google Agenda'},
      ],
      'devoirs': <Map>[
        {'matiere': 'Français', 'contenu': 'Lire le chapitre 2', 'pour_le': '2026-11-18'},
      ],
      'controles': <Map>[
        {'matiere': 'Physique', 'pour_le': '2026-11-19', 'controle': true},
      ],
      'messages_ecole': <Map>[
        {'de': 'M. Martin', 'objet': 'Sortie au musée'},
      ],
      'mails': <Map>[],
      'discord_non_lus': 2,
      'en_retard': [RankedTask('Rendre le livre', 93, 'en retard de 3 jours')],
      'taches': [
        RankedTask('Rendre le livre', 93, 'en retard de 3 jours'),
        RankedTask('Réviser Physique', 71, 'contrôle dans 2 jours'),
      ],
      'objectifs': ['Avoir 15 en maths'],
      'cartes': 12,
      'creneaux': ['17:00-18:30'],
    };
    final t = Assistant.briefingText(d, name: 'Sam');
    expect(t, startsWith('☀️ Bonjour Sam ! Nous sommes mardi 17 novembre.'));
    expect(t, contains('📚 Emploi du temps : 8 h Maths, 15 h Anglais. Tu finis à 16 h.'));
    expect(t, contains('🎉 Annulé : SVT à 10 h.'));
    expect(t, contains('📝 Contrôle de Physique jeudi 19 novembre.'));
    expect(t, contains('✏️ Français pour demain : Lire le chapitre 2'));
    expect(t, contains('📅 Dentiste aujourd\'hui à 17 h 30.'));
    expect(t, contains('✉️ École Directe — M. Martin : « Sortie au musée »'));
    expect(t, contains('💬 Non lus : 2 sur Discord.'));
    expect(t, contains('⏰ En retard : « Rendre le livre »'));
    expect(t, contains('🎯 Tes objectifs : Avoir 15 en maths.'));
    expect(t, contains('💡 Mes conseils pour aujourd\'hui :'));
    expect(t, contains('Révise Physique un peu chaque jour'));
  });

  group('avec Mon Hub', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
      HubFiles.overrideRoot = Directory.systemTemp.createTempSync('assistant').path;
      Assistant.instance.reset();
    });

    test('un tour : alertes, nouveaux devoirs proposés, puis ajoutés à la liste après accord', () async {
      final a = Assistant.instance;
      final said = <String>[];
      final added = <Object?>[];
      Future<Object?> call(String name, Map<String, dynamic> args) async => switch (name) {
        'ecole_devoirs' => [
          {'matiere': 'Maths', 'contenu': 'Exercice 3', 'pour_le': day(1), 'fait': false},
        ],
        'agenda_lire' => [
          {'titre': 'Foot', 'debut': '2026-11-18T18:00', 'fin': '2026-11-18T19:00', 'source': 'Google Agenda'},
          {'titre': 'Anniversaire', 'debut': '2026-11-18T18:30', 'fin': '2026-11-18T20:00', 'source': 'Google Agenda'},
        ],
        'agenda_creneaux_libres' => [
          {
            'jour': '2026-11-17',
            'libre': ['18:00-21:00'],
          },
        ],
        'agenda_ajouter_plan' => added..add(args['plan']),
        'ecole_messages' => [
          {'id': 7, 'de': 'Mme Durand', 'objet': 'Sortie scolaire', 'lu': false},
        ],
        'ecole_message_lire' => 'La sortie au musée aura lieu le 26 novembre à 9h. Prévoir un pique-nique.',
        _ => null,
      };
      a.notify = (t, b) => said.add(t);
      a.useTools(
        call: call,
        tools: () => {
          'ecole_devoirs',
          'agenda_lire',
          'agenda_creneaux_libres',
          'agenda_ajouter_plan',
          'ecole_messages',
          'ecole_message_lire',
        },
      );
      await a.store.setJson('consent', true);
      await a.tick(now: now);
      expect(said, contains('⏰ Pour demain : Maths'));
      expect(said, contains('⚠️ Conflit demain à 18 h 30'));
      final tasks = a.proposals.firstWhere((p) => p.id == 'tasks');
      expect(tasks.details.single, contains('Maths : Exercice 3'));
      final spot = a.proposals.firstWhere((p) => p.id.startsWith('spot|'));
      expect(spot.body, contains('« Sortie scolaire » jeudi 26 novembre à 9 h'));
      expect(await a.answer(tasks, true), '1 tâche ajoutée à ta liste.');
      expect(Carnet.instance.list('todos').single.text, 'Maths : Exercice 3');
      // Le tour suivant ne répète rien.
      said.clear();
      await a.tick(now: now.add(const Duration(minutes: 5)));
      expect(said, isEmpty);
      expect(a.proposals.where((p) => p.id == 'tasks'), isEmpty);
    });

    test('réponses instantanées : « par quoi je commence ? »', () async {
      final a = Assistant.instance;
      // Liste vide : le devoir daté du test précédent finirait « en retard »
      // avec le temps et passerait devant.
      await Carnet.instance.clear('todos');
      a.useTools(
        call: (name, args) async => name == 'ecole_devoirs'
            ? [
                {
                  'matiere': 'SVT',
                  'contenu': 'Contrôle',
                  'pour_le': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
                  'controle': true,
                },
              ]
            : null,
        tools: () => {'ecole_devoirs'},
      );
      final tools = {for (final t in a.tools) t.name: t};
      final r = await QuickAnswers.answer(
        'Smily, par quoi je commence ?',
        tools: tools.keys.toSet(),
        call: (name, args) async => tools[name]?.run(args),
      );
      expect(r?.text, contains('1. Réviser SVT (contrôle demain)'));
      expect(
        await QuickAnswers.answer('Pourquoi le ciel est bleu ?', tools: tools.keys.toSet(), call: (_, _) async => null),
        isNull,
      );
    });

    test('appli qui ne fige plus : relire un fichier inchangé ne redessine rien', () async {
      final r = RevisionsStore.instance;
      var n = 0;
      void count() => n++;
      r.addListener(count);
      try {
        await r.createDeck('Test anti-boucle');
        n = 0;
        for (var i = 0; i < 5; i++) {
          await r.load();
        }
        expect(n, 0);
      } finally {
        r.removeListener(count);
      }
    });

    testWidgets('les propositions s\'affichent et « Oui » fait l\'action', (tester) async {
      final a = Assistant.instance;
      var done = false;
      a.propose(
        Proposal(
          id: 'test',
          icon: Icons.event_rounded,
          color: Colors.teal,
          title: 'Un rendez-vous dans un mail',
          body: '« Dentiste » demain à 17 h. Je l\'ajoute à ton agenda ?',
          accept: 'Ajouter à l\'agenda',
          onAccept: () async {
            done = true;
            return null;
          },
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: AssistantLayer(child: Scaffold(body: Text('Mon Hub'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mon Hub'), findsOneWidget);
      expect(find.text('Un rendez-vous dans un mail'), findsOneWidget);
      await tester.tap(find.text('Ajouter à l\'agenda'));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(find.text('Un rendez-vous dans un mail'), findsNothing);
    });

    test('briefing rédigé par Gemini seulement si la clé est là', () async {
      final a = Assistant.instance;
      a.useTools(call: (_, _) async => null, tools: () => {});
      AiText.override = (prompt, system) async => 'Bonjour ! Version jolie.';
      try {
        expect(await a.morningBriefing(now: now), 'Bonjour ! Version jolie.');
        await a.store.setJson('briefingAi', false);
        expect(await a.morningBriefing(now: now), startsWith('☀️ Bonjour !'));
      } finally {
        AiText.override = null;
      }
    });
  });
}
