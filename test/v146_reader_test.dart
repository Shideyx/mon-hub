import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/books/books_module.dart';
import 'package:hub/modules/books/read_finder.dart';
import 'package:hub/modules/books/reader_page.dart';

Map<String, dynamic> manga(String id, Map<String, String> title,
        {List<Map<String, String>> alt = const [], List<String> langs = const ['fr', 'en'], String author = ''}) =>
    {
      'id': id,
      'type': 'manga',
      'attributes': {
        'title': title,
        'altTitles': alt,
        'availableTranslatedLanguages': langs,
        'year': 1997,
      },
      'relationships': [
        {'id': 'c-$id', 'type': 'cover_art', 'attributes': {'fileName': 'cover-$id.jpg'}},
        if (author.isNotEmpty) {'id': 'a-$id', 'type': 'author', 'attributes': {'name': author}},
      ],
    };

Map<String, dynamic> chap(String id, String? n, String lang, {int pages = 20, String? vol, String? ext}) => {
  'id': id,
  'type': 'chapter',
  'attributes': {'chapter': n, 'volume': vol, 'title': '', 'translatedLanguage': lang, 'pages': pages, 'externalUrl': ext},
};

http.Response ok(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  test('le titre est nettoyé : tome, chapitre, sous-titre', () {
    final a = ReadQuery.parse("One Piece - Tome 03 : À l'aube d'une grande aventure");
    expect(a.title, 'One Piece');
    expect(a.volume, 3);
    final b = ReadQuery.parse('Re:Zero chapitre 12');
    expect(b.title, 'Re:Zero');
    expect(b.chapter, 12);
    expect(ReadQuery.parse('Spider-Man').title, 'Spider-Man');
    final c = ReadQuery.parse('Harry Potter, tome 1');
    expect(c.title, 'Harry Potter');
    expect(c.volume, 1);
    expect(ReadQuery.parse('Naruto (Édition Hokage)').title, 'Naruto');
  });

  test('retrouve le manga (même par son titre français) et pas les livres à emprunter', () async {
    final asked = <String>[];
    final client = MockClient((r) async {
      asked.add(r.url.host);
      if (r.url.host == 'api.mangadex.org') {
        expect(r.url.queryParametersAll['contentRating[]'], ['safe', 'suggestive']); // jamais de contenu adulte
        expect(r.url.queryParameters['title'], "L'Attaque des Titans");
        return ok({
          'data': [
            manga('m2', {'en': 'Attack on Titan: Junior High'}),
            manga('m1', {'en': 'Attack on Titan'},
                alt: [
                  {'ja-ro': 'Shingeki no Kyojin'},
                  {'fr': "L'Attaque des Titans"},
                ],
                author: 'Isayama Hajime'),
          ],
        });
      }
      if (r.url.host == 'gutendex.com') return ok({'results': []});
      if (r.url.host == 'openlibrary.org') {
        return ok({
          'docs': [
            {'title': "L'Attaque des Titans", 'ebook_access': 'borrowable', 'ia': ['x']},
          ],
        });
      }
      return http.Response('?', 404);
    });
    final f = ReadFinder(client);
    final found = await f.find("L'Attaque des Titans - Tome 1");
    expect(asked.toSet(), {'api.mangadex.org', 'gutendex.com', 'openlibrary.org'});
    expect(found.first.id, 'm1');
    expect(found.first.isManga, true);
    expect(found.first.author, 'Isayama Hajime');
    expect(found.first.coverUrl, 'https://uploads.mangadex.org/covers/m1/cover-m1.jpg.512.jpg');
    expect(found.any((m) => m.source == 'archive'), false); // à emprunter = exclu
    expect(ReadFinder.confident(found), true);
  });

  test('pas sûr → on demande « c\'est celui-ci ? »', () {
    const q = ReadQuery(title: 'Monster', full: 'Monster');
    final a = const ReadMatch(source: 'mangadex', id: 'a', title: 'Monster').withScore(1.0, similarity: 1);
    final b = const ReadMatch(source: 'gutenberg', id: 'b', title: 'Monster').withScore(0.97, similarity: 1);
    expect(ReadFinder.confident([a, b]), false);
    // Seulement un titre qui ressemble : on ne l'ouvre pas tout seul.
    const musume = ReadMatch(source: 'mangadex', id: 'c', title: 'Monster Musume', coverUrl: 'x', languages: ['fr']);
    expect(ReadFinder.confident([musume.withScore(ReadFinder.score(q, '', musume), similarity: ReadFinder.titleMatch(q, musume))]), false);
  });

  test('un chapitre par numéro : lisible, en français d\'abord, dans l\'ordre', () async {
    final client = MockClient((r) async {
      if (r.url.path == '/manga/m1/feed') {
        expect(r.url.queryParameters['includeExternalUrl'], '1');
        return ok({
          'total': 6,
          'data': [
            chap('c2en', '2', 'en', vol: '1'),
            chap('c1en', '1', 'en', vol: '1'),
            chap('c1fr', '1', 'fr', vol: '1'),
            chap('c3off', '3', 'en', pages: 0, ext: 'https://mangaplus.shueisha.co.jp/viewer/1'),
            chap('c4vide', '4', 'fr', pages: 0),
            chap('c10fr', '10', 'fr', vol: '2'),
          ],
        });
      }
      if (r.url.path == '/at-home/server/c1fr') {
        return ok({
          'baseUrl': 'https://abc.mangadex.network',
          'chapter': {'hash': 'h1', 'data': ['1.png', '2.png'], 'dataSaver': ['1.jpg', '2.jpg']},
        });
      }
      return http.Response('?', 404);
    });
    final f = ReadFinder(client);
    final list = await f.chapters('m1');
    expect([for (final c in list) c.id], ['c1fr', 'c2en', 'c3off', 'c10fr']); // 10 après 3 (pas « 10 » < « 2 »)
    expect(list[2].readable, false);
    expect(list[2].externalUrl, startsWith('https://mangaplus'));
    expect(ReadFinder.startIndex(list, ReadQuery.parse('Truc tome 2')), 3);
    expect(ReadFinder.startIndex(list, ReadQuery.parse('Truc chapitre 2')), 1);
    expect(ReadFinder.startIndex(list, ReadQuery.parse('Truc')), 0);
    expect(await f.pages('c1fr'), ['https://abc.mangadex.network/data/h1/1.png', 'https://abc.mangadex.network/data/h1/2.png']);
    expect((await f.pages('c1fr', saver: true)).first, 'https://abc.mangadex.network/data-saver/h1/1.jpg');
  });

  test('livre libre : texte sans la licence, paragraphes recollés, pages', () async {
    final g = ReadFinder.gutenbergFromJson({
      'id': 17489,
      'title': 'Les misérables Tome I',
      'authors': [
        {'name': 'Hugo, Victor'},
      ],
      'languages': ['fr'],
      'formats': {
        'text/plain; charset=us-ascii': 'http://www.gutenberg.org/files/17489/17489.txt',
        'text/plain; charset=utf-8': 'https://www.gutenberg.org/ebooks/17489.txt.utf-8',
        'image/jpeg': 'https://www.gutenberg.org/cache/epub/17489/pg17489.cover.medium.jpg',
      },
    })!;
    expect(g.author, 'Victor Hugo');
    expect(g.textUrl, 'https://www.gutenberg.org/ebooks/17489.txt.utf-8');
    const raw = 'Licence…\r\n*** START OF THE PROJECT GUTENBERG EBOOK LES MISÉRABLES ***\r\n'
        'En 1815, M. Charles-François-Bienvenu Myriel\r\nétait évêque de Digne.\r\n\r\nC\'était un vieillard.\r\n'
        '*** END OF THE PROJECT GUTENBERG EBOOK ***\r\nFin de licence';
    final text = ReadFinder.cleanGutenberg(raw);
    expect(text.contains('Licence'), false);
    final paras = ReadFinder.paragraphs(text);
    expect(paras, ['En 1815, M. Charles-François-Bienvenu Myriel était évêque de Digne.', 'C\'était un vieillard.']);
    final pages = ReadFinder.paginate([for (var i = 0; i < 30; i++) 'x' * 300], chars: 1000);
    expect(pages.length, 10);
    expect(pages.every((p) => p.length == 3), true);
    final huge = ReadFinder.paginate(['Une phrase assez longue. ' * 200], chars: 1000);
    expect(huge.length > 3, true);
  });

  test('le livre garde où tu en es', () {
    final b = Book(id: '1', title: 'One Piece', status: BookStatus.reading)
      ..read = (ReadLink.fromMatch(const ReadMatch(source: 'mangadex', id: 'm1', title: 'One Piece'))
        ..chapterId = 'c12'
        ..chapterLabel = 'Chapitre 12'
        ..page = 4
        ..at = DateTime(2026, 11, 17));
    final back = Book.fromJson(jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>);
    expect(back.read!.chapterId, 'c12');
    expect(back.read!.progress, 'Chapitre 12 · page 5');
    final t = ReadLink(source: 'gutenberg', id: '1', title: 'x', page: 50, total: 200, at: DateTime(2026));
    expect(t.progress, '25 % lu');
    expect(Book.fromJson({'id': '2', 'title': 'Ancien'}).read, null); // anciens livres : rien ne casse
  });

  testWidgets('« Lire » trouve le livre tout seul, l\'ouvre et retient la page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final dir = Directory.systemTemp.createTempSync('lecture');
    HubFiles.overrideRoot = dir.path;
    final m = BooksModule()..attach();
    final paras = [for (var i = 0; i < 40; i++) 'Paragraphe numéro $i. ${'bla ' * 80}'];
    m.readFinder = ReadFinder(MockClient((r) async {
      if (r.url.host == 'gutendex.com') {
        return ok({
          'results': [
            {
              'id': 1,
              'title': 'Le Petit Prince',
              'authors': [{'name': 'Saint-Exupéry, Antoine de'}],
              'languages': ['fr'],
              'formats': {'text/plain; charset=utf-8': 'https://www.gutenberg.org/ebooks/1.txt.utf-8'},
            },
          ],
        });
      }
      if (r.url.host == 'www.gutenberg.org') {
        return http.Response.bytes(utf8.encode('*** START OF THE PROJECT GUTENBERG EBOOK X ***\n${paras.join('\n\n')}'), 200);
      }
      return ok({'data': [], 'docs': []});
    }));
    final b = Book(id: 'b1', title: 'Le Petit Prince', status: BookStatus.toRead);
    await m.upsert(b);
    await tester.pumpWidget(MaterialApp(home: BookDetailPage(module: m, book: b)));
    await tester.ensureVisible(find.text('Lire'));
    await tester.tap(find.text('Lire'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Paragraphe numéro 0.'), findsOneWidget);
    expect(find.textContaining('1 / '), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / '), findsOneWidget);
    expect(tester.getRect(find.byType(Slider)).height <= 52, true); // la barre ne cache pas l'écran
    await tester.pageBack();
    await tester.pumpAndSettle();
    final saved = m.books.single;
    expect(saved.read!.source, 'gutenberg');
    expect(saved.read!.page > 0, true); // reprend à la 2e page
    expect(saved.status, BookStatus.reading);
    expect(find.byType(TextReaderPage), findsNothing);
    expect(find.text('Reprendre la lecture'), findsOneWidget);
    // Le texte est gardé sur l'appareil.
    final files = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return dir.listSync(recursive: true).map((f) => f.path).toList();
    });
    expect(files!.any((f) => f.endsWith('gutenberg-1.txt')), true, reason: '$files');
  });

  testWidgets('scans : pages, fin du chapitre, chapitre suivant, reprise', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('scans').path;
    final m = BooksModule()..attach();
    m.readFinder = ReadFinder(MockClient((r) async {
      if (r.url.path == '/manga/m1/feed') {
        return ok({'total': 2, 'data': [chap('c1', '1', 'fr', pages: 2), chap('c2', '2', 'fr', pages: 2)]});
      }
      if (r.url.path.startsWith('/at-home/server/')) {
        return ok({
          'baseUrl': 'https://x.mangadex.network',
          'chapter': {'hash': 'h', 'data': ['1.png', '2.png'], 'dataSaver': ['1.jpg', '2.jpg']},
        });
      }
      return http.Response('?', 404);
    }));
    final b = Book(id: 'b2', title: 'Frieren', status: BookStatus.reading)
      ..read = ReadLink(source: 'mangadex', id: 'm1', title: 'Frieren');
    await m.upsert(b);
    await tester.pumpWidget(MaterialApp(home: BookDetailPage(module: m, book: b)));
    await tester.ensureVisible(find.text('Lire'));
    await tester.tap(find.text('Lire'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ScanReaderPage), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.getRect(find.byType(Slider)).height <= 52, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Fin du chapitre 1'), findsOneWidget);
    await tester.tap(find.text('Chapitre 2'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Chapitre 2'), findsWidgets);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(m.books.single.read!.chapterId, 'c2');
    expect(find.textContaining('Chapitre 2 · page 1'), findsOneWidget);
  });
}

