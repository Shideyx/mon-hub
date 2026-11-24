import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/books/book_finder.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/music/cd_case.dart';
import 'package:hub/ui/clicky/whisper.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('livres : retrouver le bon livre', () {
    test('ressemblance des titres', () {
      expect(BookFinder.titleSimilarity('Le Petit Prince', 'Le petit prince'), 1);
      expect(BookFinder.titleSimilarity('l\'étranger', 'L\'Étranger'), 1);
      expect(
        BookFinder.titleSimilarity('Harry Potter école des sorciers', "Harry Potter à l'école des sorciers"),
        greaterThan(0.9),
      );
      // Une faute de frappe.
      expect(BookFinder.titleSimilarity('Les Miserbles', 'Les Misérables'), greaterThan(0.7));
      // Sous-titre en plus.
      expect(BookFinder.titleSimilarity('Dune', 'Dune : roman'), greaterThan(0.9));
      expect(BookFinder.titleSimilarity('Dune', 'Le Seigneur des anneaux'), lessThan(0.2));
    });

    test('choisit le livre le plus probable, avec sa couverture', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'openlibrary.org') {
          return http.Response(
            jsonEncode({
              'docs': [
                {
                  'title': 'Le Petit Prince illustré pour adultes',
                  'author_name': ['X'],
                  'edition_count': 1,
                },
                {
                  'title': 'Le Petit Prince',
                  'author_name': ['Antoine de Saint-Exupéry'],
                  'cover_i': 123,
                  'number_of_pages_median': 96,
                  'edition_count': 900,
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'items': [
              {
                'volumeInfo': {
                  'title': 'Le petit prince',
                  'authors': ['Antoine de Saint-Exupéry'],
                  'imageLinks': {'thumbnail': 'http://books.google.com/x?zoom=1&edge=curl'},
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final best = await BookFinder(client).find('le petit prince');
      expect(best, isNotNull);
      expect(best!.author, contains('Saint-Exupéry'));
      expect(best.coverUrl, 'https://covers.openlibrary.org/b/id/123-L.jpg?default=false');
      expect(best.pages, 96);
      final all = await BookFinder(client).candidates('le petit prince');
      final google = all.where((m) => m.source == 'Google Livres').firstOrNull;
      // Google : https et sans le coin corné.
      if (google != null) expect(google.coverUrl, 'https://books.google.com/x?zoom=1');
    });

    test('rien de convaincant : pas de livre au hasard', () async {
      final client = MockClient(
        (req) async => http.Response(
          req.url.host == 'openlibrary.org'
              ? jsonEncode({
                  'docs': [
                    {
                      'title': 'Cuisine facile',
                      'author_name': ['Y'],
                    },
                  ],
                })
              : jsonEncode({'items': []}),
          200,
        ),
      );
      expect(await BookFinder(client).find('Les Fourmis'), isNull);
    });
  });

  test('Whisper : texte nettoyé', () {
    expect(
      Whisper.clean('[00:00:00.000 --> 00:00:02.000]  Bonjour Nexo,\n quelle heure est-il ?\n'),
      'Bonjour Nexo, quelle heure est-il ?',
    );
    expect(Whisper.clean(' [Musique]\n'), '');
  });

  test('cloud et documents École Directe', () {
    final root = EdCloudNode.parse([
      {
        'type': 'folder',
        'libelle': '/',
        'id': r'\E\1',
        'children': [
          {
            'type': 'folder',
            'libelle': 'Maths',
            'id': r'\E\1\Maths',
            'children': [
              {'type': 'file', 'libelle': 'a.pdf', 'id': r'\E\1\Maths\a.pdf'},
            ],
          },
          {'type': 'file', 'libelle': 'b.pdf', 'id': r'\E\1\b.pdf'},
        ],
      },
    ]);
    expect(root.allFiles.map((f) => f.name).toList(), ['a.pdf', 'b.pdf']);
    final docs = EdDocument.parse({
      'notes': [
        {'id': 5, 'libelle': 'Bulletin du 1er trimestre', 'date': '2026-12-20'},
      ],
      'administratifs': [
        {'id': 9, 'libelle': 'Certificat de scolarit&eacute;', 'date': '2026-09-02'},
      ],
      'factures': [],
    });
    expect(docs.map((d) => d.title), ['Bulletin du 1er trimestre', 'Certificat de scolarité']);
    expect(docs.first.category, 'Notes et bulletins');
  });

  testWidgets('le CD avec la pochette se dessine', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 500,
            child: CaseWithDisc(playing: true, caseWidget: ColoredBox(color: Colors.black)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CdDisc), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
