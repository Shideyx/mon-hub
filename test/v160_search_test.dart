import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/everywhere_search.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  group('recherche partout', () {
    test('les mots cherchés', () {
      expect(EverywhereSearch.words('L\'exposé sur la Révolution'), ['expose', 'revolution']);
      expect(EverywhereSearch.words('le'), ['le']);
    });

    test('la note : tous les mots, mieux dans le titre', () {
      final w = EverywhereSearch.words('exposé révolution');
      expect(EverywhereSearch.score(w, 'Exposé Révolution française.docx', ''), greaterThan(2));
      expect(EverywhereSearch.score(w, 'Histoire', 'un exposé sur la révolution'), 1);
      expect(EverywhereSearch.score(w, 'Exposé de SVT', ''), 0);
    });

    test('les mots passés à Windows ne peuvent rien casser', () {
      expect(EverywhereSearch.pcQuery("maths'; DROP TABLE x --"), 'maths DROP TABLE');
      expect(EverywhereSearch.pcQuery('"révolution" (1789)'), 'révolution 1789');
      expect(EverywhereSearch.pcQuery('a'), '');
    });

    test('un extrait autour du mot', () {
      final long = '${'blabla ' * 40}la photosynthèse se fait dans les feuilles ${'blabla ' * 40}';
      final ex = EverywhereSearch.around(long, ['photosynthese']);
      expect(ex, contains('photosynthèse'));
      expect(ex.length, lessThan(150));
    });

    test('cherche dans les modules (sans IA)', () async {
      final calls = <String>[];
      final hits = await EverywhereSearch.run(
        'exposé',
        (tool, args) async {
          calls.add(tool);
          return switch (tool) {
            'drive_chercher' => [
              {'nom': 'Exposé histoire.pptx', 'type': 'application/vnd.ms-powerpoint', 'lien': 'https://drive.google.com/x'},
            ],
            'mails_lister' => [
              {'de': 'Prof <prof@lycee.fr>', 'objet': 'Consignes de l\'exposé', 'date': '2026-11-10T10:00:00', 'lu': true},
              {'de': 'Promo <promo@shop.fr>', 'objet': 'Soldes', 'date': '2026-11-10T10:00:00', 'lu': false},
            ],
            'discord_conversations' => [
              {'nom': 'Léa', 'dernier': 'Léa : on finit l\'exposé demain ?', 'date': '2026-11-17T18:00:00'},
            ],
            'carnet_taches_notes' => {
              'a_faire': ['Finir l\'exposé'],
              'notes': ['Idée de gâteau'],
              'fait': [],
            },
            'revision_paquets' => {
              'paquets': [{'nom': 'Histoire', 'cartes': 12}],
              'controles': [{'matiere': 'HISTOIRE', 'date': '2026-11-20', 'contenu': 'Exposé oral'}],
            },
            _ => null,
          };
        },
        {'drive_chercher', 'mails_lister', 'discord_conversations', 'carnet_taches_notes', 'revision_paquets'},
        pc: false,
      );
      expect(calls, containsAll(['drive_chercher', 'mails_lister', 'discord_conversations']));
      expect(calls, isNot(contains('ecole_messages')));
      final sources = {for (final h in hits) h.source};
      expect(sources, containsAll(['Drive', 'Mails', 'Discord', 'Carnet', 'Révisions']));
      expect(hits.where((h) => h.title == 'Soldes'), isEmpty);
      expect(hits.firstWhere((h) => h.source == 'Drive').link, 'https://drive.google.com/x');
      expect(hits.firstWhere((h) => h.source == 'Discord').moduleId, 'discord');
      expect(EverywhereSearch.say('exposé', hits), startsWith('${hits.length} résultats pour « exposé »'));
      expect(EverywhereSearch.say('zzz', const []), contains('rien trouvé'));
    });

    test('« cherche … partout »', () async {
      final asked = <String, Object?>{};
      final r = await QuickAnswers.answer(
        'cherche mon exposé sur la révolution partout',
        call: (n, a) async {
          asked[n] = a['texte'];
          return n == 'recherche_partout' ? {'resume': '3 résultats'} : 'ok';
        },
        tools: const {'recherche_partout', 'recherche_ouvrir'},
      );
      expect(r?.text, '3 résultats');
      expect(asked['recherche_partout'], 'mon expose sur la revolution');
      final r2 = await QuickAnswers.answer(
        'retrouve le fichier de maths',
        call: (n, a) async => n == 'recherche_partout' ? {'resume': 'ok ${a['texte']}'} : null,
        tools: const {'recherche_partout'},
      );
      expect(r2?.text, 'ok maths');
      final r3 = await QuickAnswers.answer(
        'cherche une recette de crêpes',
        call: (n, a) async => n == 'recherche_partout' ? {'resume': 'non'} : null,
        tools: const {'recherche_partout'},
      );
      expect(r3?.text, isNot('non'));
    });
  });
}
