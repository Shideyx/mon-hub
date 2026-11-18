import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/mail/mail_module.dart';
import 'package:hub/ui/clicky/course_listener.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/file_viewer.dart';
import 'package:hub/ui/web_login.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/ui/clicky/clicky_settings_page.dart';
import 'package:hub/ui/clicky/course_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('pièces jointes des devoirs (École Directe)', () {
    test('documents du devoir, des ressources et de la séance, sans doublon', () {
      final todo = {
        'contenu': 'RXhlcmNpY2Vz',
        'documents': [
          {'id': 101, 'libelle': 'Sujet de l&#39;exercice.pdf', 'type': 'FICHIER_CDT'},
          {'id': '102', 'libelle': 'fiche.docx'},
        ],
        'ressourceDocuments': [
          {'id': 101, 'libelle': 'Sujet (doublon).pdf'},
          {'id': 0, 'libelle': 'sans id'},
        ],
      };
      final seance = {
        'contenu': '',
        'documents': [
          {'id': 205, 'libelle': 'Diapo du cours.pptx', 'type': 'FICHIER_CDT'},
        ],
      };
      final files = EdClient.homeworkFiles(todo, seance);
      expect(files.map((f) => f.id), [101, 102, 205]);
      expect(files.first.name, 'Sujet de l\'exercice.pdf');
      expect(files[1].type, 'FICHIER_CDT');
    });

    test('rien de joint : liste vide', () {
      expect(EdClient.homeworkFiles({'contenu': 'x'}, null), isEmpty);
      expect(EdClient.homeworkFiles(null, null), isEmpty);
    });
  });

  group('visionneuse de fichiers', () {
    test('type d\'après le nom', () {
      expect(FileViewer.kindOf('Sujet.PDF'), FileKind.pdf);
      expect(FileViewer.kindOf('photo.jpeg'), FileKind.image);
      expect(FileViewer.kindOf('cours.docx'), FileKind.word);
      expect(FileViewer.kindOf('notes.txt'), FileKind.text);
      expect(FileViewer.kindOf('oral.m4a'), FileKind.media);
      expect(FileViewer.kindOf('tableur.xlsx'), FileKind.other);
    });

    test('sans extension : reconnu à ses premiers octets', () {
      expect(FileViewer.kindOf('piece', utf8.encode('%PDF-1.7')), FileKind.pdf);
      expect(FileViewer.guessExt([0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(FileViewer.guessExt([0x89, 0x50, 0x4E, 0x47]), 'png');
      expect(FileViewer.guessExt([1, 2, 3, 4]), '');
    });

    test('nom de fichier sans caractères interdits', () {
      expect(FileViewer.safeName('a/b:c*?.pdf'), 'a_b_c__.pdf');
      expect(FileViewer.safeName('  '), 'fichier');
    });
  });

  test('pièces jointes d\'un mail', () {
    final b = MessageBuilder.prepareMultipartMixedMessage()
      ..from = [const MailAddress('Prof', 'prof@lycee.fr')]
      ..to = [const MailAddress('Moi', 'moi@exemple.fr')]
      ..subject = 'Le sujet'
      ..addTextPlain('Bonjour, voici le sujet.');
    b.addBinary(utf8.encode('%PDF-1.4 faux pdf'), MediaType.fromSubtype(MediaSubtype.applicationPdf), filename: 'sujet.pdf');
    final m = MimeMessage.parseFromText(b.buildMimeMessage().renderMessage());
    final files = MailModule.attachmentsOf(m);
    expect(files.map((f) => f.name), ['sujet.pdf']);
  });

  test('identité du navigateur intégré : la vraie version du moteur', () {
    expect(desktopUserAgent('147.0.3210.5'), contains('Chrome/147.0.0.0'));
    expect(desktopUserAgent(null), contains('Chrome/'));
    expect(desktopUserAgent('n\'importe quoi'), isNot(contains('Chrome/n')));
  });

  group('écouter un cours', () {
    test('compte rendu gardé et relu', () {
      final n = CourseNote(
        id: '1',
        subject: 'Histoire',
        start: DateTime(2026, 11, 18, 10),
        end: DateTime(2026, 11, 18, 11),
        parts: ['La guerre froide commence en 1947.', '', 'Le mur de Berlin tombe en 1989.'],
        summary: '# La guerre froide',
      );
      final back = CourseNote.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map);
      expect(back.subject, 'Histoire');
      expect(back.length.inMinutes, 60);
      expect(back.transcript, 'La guerre froide commence en 1947.\n\nLe mur de Berlin tombe en 1989.');
      expect(back.done, isTrue);
      final p = CourseListener.prompt(back);
      expect(p, contains('de Histoire'));
      expect(p, contains('1989'));
      expect(p, contains('N\'invente rien'));
    });

    final calls = <String>[];
    Future<Object?> fake(String name, Map<String, dynamic> args) async {
      calls.add(name);
      if (name == 'cours_ecouter') return {'ok': true, 'matiere': 'SVT', 'fin': '11 h 00'};
      return {'ok': true};
    }

    Future<String?> ask(String q) async =>
        (await QuickAnswers.answer(q, call: fake, tools: const {'cours_ecouter', 'cours_arreter'}))?.text;

    test('« écoute le cours » et « arrête le cours » sans IA', () async {
      calls.clear();
      expect(await ask('Clicky, écoute le cours'), contains('SVT'));
      expect(await ask('prends le cours en notes'), contains('jusqu\'à 11 h 00'));
      expect(await ask('fais-moi un compte rendu du cours'), isNotNull);
      expect(await ask('arrête le cours'), contains('compte rendu'));
      expect(await ask('le cours est fini'), isNotNull);
      expect(calls, ['cours_ecouter', 'cours_ecouter', 'cours_ecouter', 'cours_arreter', 'cours_arreter']);
    });

    test('les vraies questions vont à l\'IA', () async {
      calls.clear();
      expect(await ask('c\'est quoi un cours d\'eau'), isNull);
      expect(await ask('écoute le cours de maths et explique-moi les fractions'), isNull);
      expect(calls, isEmpty);
    });
  });

  group('écrans', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
    });

    testWidgets('réglages de Clicky : l\'essentiel, les rubriques, la recherche', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ClickySettingsPage()));
      await tester.pump();
      expect(find.text('L\'essentiel'), findsOneWidget);
      expect(find.text('Écouter un cours'), findsOneWidget);
      expect(find.text('Aide aux devoirs'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'quiz');
      await tester.pump();
      expect(find.text('Mode quiz'), findsOneWidget);
      expect(find.text('L\'essentiel'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('écouter un cours : la page s\'affiche', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: CoursePage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Écouter un cours'), findsOneWidget);
      expect(find.text('Mes comptes rendus'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
