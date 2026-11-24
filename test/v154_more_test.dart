import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/core/work_backup.dart';
import 'package:hub/modules/revisions/mock_exam.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/course_listener.dart';

void main() {
  test('notifications regroupées : le résumé', () {
    final items = [
      HubNotification(id: '1', title: 'Léo', body: 'salut ça va ?', moduleId: 'discord'),
      HubNotification(id: '2', title: 'Inès', body: 'tu viens ?', moduleId: 'discord'),
      HubNotification(id: '3', title: '📝 Nouvelle note en Maths', body: '15/20', moduleId: 'ecoledirecte'),
    ];
    final d = NotificationCenter.digestOf(items, {'discord': 'Discord', 'ecoledirecte': 'École Directe'});
    expect(d.title, '🔔 3 notifications : 2 Discord · 1 École Directe');
    expect(d.body.split('\n').first, '• 📝 Nouvelle note en Maths — 15/20');
    expect(d.moduleId, isEmpty); // le résumé lui-même passe tout de suite
    expect(
      NotificationCenter.urgent(HubNotification(id: 'discord-appel-1', title: 'Appel', body: '', moduleId: 'discord')),
      isTrue,
    );
    // v1.61 : un message, une note, un devoir ne sont plus retenus par le
    // résumé (ils arrivaient jusqu'à une demi-heure trop tard).
    expect(NotificationCenter.urgent(items.first), isTrue);
    expect(NotificationCenter.urgent(items.last), isTrue);
    expect(
      NotificationCenter.urgent(HubNotification(id: 'abo:spotify', title: 'Spotify', body: '', moduleId: 'argent')),
      isFalse,
    );
    expect(NotificationCenter.urgent(HubNotification(id: 'x', title: 'Rappel', body: '')), isTrue);
  });

  test('sauvegarde des travaux : quels fichiers, où, et seulement s\'ils ont changé', () {
    expect(WorkBackup.wanted(r'C:\Users\Moi\Documents\Exposé SVT.pptx', 2000000), isTrue);
    expect(WorkBackup.wanted(r'C:\Users\Moi\Documents\DM.docx', 30000), isTrue);
    expect(WorkBackup.wanted(r'C:\Users\Moi\Documents\~$DM.docx', 300), isFalse); // fichier de Word ouvert
    expect(WorkBackup.wanted(r'C:\Users\Moi\Documents\vacances.jpg', 3000000), isFalse);
    expect(WorkBackup.wanted(r'C:\Users\Moi\Documents\film.pdf', 80 * 1024 * 1024), isFalse);
    expect(
      WorkBackup.relative(r'C:\Users\Moi\Documents', r'C:\Users\Moi\Documents\Maths\DM 3.docx'),
      'Documents/Maths/DM 3.docx',
    );
    final at = DateTime(2026, 11, 18, 10);
    final saved = <String, dynamic>{
      'Documents/DM.docx': {'id': 'x', 'taille': 100, 'modif': at.millisecondsSinceEpoch},
    };
    expect(WorkBackup.changed(saved, 'Documents/DM.docx', 100, at), isFalse);
    expect(WorkBackup.changed(saved, 'Documents/DM.docx', 120, at), isTrue);
    expect(WorkBackup.changed(saved, 'Documents/Nouveau.docx', 100, at), isTrue);
  });

  group('contrôle blanc', () {
    const ai = '''```json
{"titre": "La photosynthèse", "minutes": 20, "questions": [
 {"type": "qcm", "question": "Où a lieu la photosynthèse ?", "choix": ["Mitochondrie", "Chloroplaste", "Noyau"], "bonne": 1, "points": 2},
 {"type": "redigee", "question": "Définis la photosynthèse.", "attendu": "Production de matière organique à partir de CO2, eau et lumière", "points": 4}
]}
```''';

    test('le sujet de l\'IA lu, la copie corrigée, la note sur 20', () {
      final e = MockExam.parse(ai)!;
      expect(e.title, 'La photosynthèse');
      expect(e.minutes, 20);
      expect(e.questions.first.isChoice, isTrue);
      expect(e.questions.last.isChoice, isFalse);
      expect(e.total, 6);
      final answers = ['1', 'La plante fabrique du sucre avec la lumière'];
      final p = e.gradePrompt(answers);
      expect(p, contains('Question 2 (4.0 points)'));
      expect(p, isNot(contains('Question 1 ')));
      final (marks, advice) = e.mark(
        answers,
        '{"questions": [{"numero": 2, "points": 2.5, "commentaire": "Il manque le CO2."}], "conseil": "Revois les réactifs."}',
      );
      expect(marks.map((m) => m.got), [2, 2.5]);
      expect(marks.last.comment, 'Il manque le CO2.');
      expect(advice, 'Revois les réactifs.');
      expect(MockExam.on20(marks), 15); // 4,5/6 → 15/20
      // Sans correction de l'IA : les QCM comptent quand même.
      final (m2, _) = e.mark(['0', ''], null);
      expect(m2.first.got, 0);
      expect(m2.first.comment, contains('Chloroplaste'));
    });

    test('« fais-moi un contrôle blanc de SVT »', () async {
      final calls = <String>[];
      final r = await QuickAnswers.answer(
        'Fais-moi un contrôle blanc de SVT',
        call: (n, a) async {
          calls.add('$n ${a['matiere']}');
          return {'ok': true};
        },
        tools: const {'revision_controle_blanc'},
      );
      expect(r?.text, contains('contrôle blanc de svt'));
      expect(calls, ['revision_controle_blanc svt']);
    });
  });

  test('notes en direct : le Google Doc gardé avec le cours, consignes de prise de notes', () {
    final n = CourseNote(id: '1', subject: 'Histoire', start: DateTime(2026, 11, 18, 10), docId: 'doc123');
    final back = CourseNote.fromJson(n.toJson());
    expect(back.docId, 'doc123');
    expect(CourseNote.fromJson(CourseNote(id: '2', subject: '', start: DateTime(2026)).toJson()).docId, isNull);
    final p = CourseListener.livePrompt('Histoire', 'Alors la guerre froide commence en 1947…');
    expect(p, contains('de Histoire'));
    expect(p, contains('« • »'));
    expect(p, contains('1947'));
  });
}
