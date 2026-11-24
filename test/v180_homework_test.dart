import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/homework_auto.dart';

void main() {
  group('La matière du devoir', () {
    test('lue dans le titre de la notification', () {
      expect(HomeworkRules.subjectOf('📚 Maths : exercices 4 et 5'), 'Maths');
      expect(HomeworkRules.subjectOf('Nouveau devoir - Histoire-Géo'), 'Nouveau devoir');
      expect(HomeworkRules.subjectOf('SVT – lire le chapitre 3'), 'SVT');
      expect(HomeworkRules.subjectOf('📝'), 'ce devoir');
    });
  });

  group('Quand il s\'y met', () {
    bool go({
      bool allowed = true,
      Duration away = const Duration(minutes: 15),
      int done = 0,
      bool busy = false,
      DateTime? now,
    }) => HomeworkRules.shouldStart(
      allowed: allowed,
      awayFor: away,
      doneToday: done,
      busy: busy,
      now: now ?? DateTime(2026, 11, 24, 15),
    );

    test('absent depuis dix minutes, et il a l\'autorisation', () {
      expect(go(), isTrue);
      expect(go(allowed: false), isFalse);
      expect(go(away: const Duration(minutes: 4)), isFalse);
    });

    test('deux par jour au plus', () {
      expect(go(done: 1), isTrue);
      expect(go(done: 2), isFalse);
    });

    test('jamais s\'il fait déjà autre chose', () {
      expect(go(busy: true), isFalse);
    });

    test('jamais la nuit (elle dort, elle ne verrait rien)', () {
      expect(go(now: DateTime(2026, 11, 24, 3)), isFalse);
      expect(go(now: DateTime(2026, 11, 24, 23, 30)), isFalse);
      expect(go(now: DateTime(2026, 11, 24, 7)), isTrue);
      expect(go(now: DateTime(2026, 11, 24, 22, 59)), isTrue);
    });
  });

  group('Ce qu\'il dit au retour', () {
    final at = DateTime(2026, 11, 24, 15);
    AutoHomework h(String s, {bool failed = false}) =>
        AutoHomework(id: s, subject: s, at: at, docUrl: failed ? null : 'https://docs', failed: failed);

    test('rien à dire s\'il n\'a rien fait', () {
      expect(HomeworkRules.welcome(const []), isEmpty);
    });

    test('un devoir fait', () {
      final say = HomeworkRules.welcome([h('Maths')]);
      expect(say, contains('j\'ai fait ton devoir de Maths'));
      expect(say, contains('Google Doc'));
      expect(say, contains('Comment j\'ai fait'));
    });

    test('deux devoirs faits', () {
      expect(HomeworkRules.welcome([h('Maths'), h('SVT')]), contains('tes devoirs de Maths et SVT'));
    });

    test('il dit aussi quand il n\'a pas réussi (jamais de faux succès)', () {
      final say = HomeworkRules.welcome([h('Maths'), h('Anglais', failed: true)]);
      expect(say, contains('j\'ai fait ton devoir de Maths'));
      expect(say, contains('Je n\'ai pas réussi celui de Anglais'));
      final only = HomeworkRules.welcome([h('Anglais', failed: true)]);
      expect(only, contains('Je n\'ai pas réussi'));
      expect(only, isNot(contains('Google Doc')));
    });
  });

  group('Ce qu\'il garde', () {
    test('un devoir fait se relit', () {
      final h = AutoHomework(id: '7', subject: 'Maths', at: DateTime(2026, 11, 24, 15), docUrl: 'https://d');
      final back = AutoHomework.fromJson(h.toJson())!;
      expect(back.id, '7');
      expect(back.subject, 'Maths');
      expect(back.docUrl, 'https://d');
      expect(back.failed, isFalse);
      final ko = AutoHomework.fromJson(
        AutoHomework(id: '8', subject: 'SVT', at: DateTime(2026, 11, 24), failed: true).toJson(),
      )!;
      expect(ko.failed, isTrue);
      expect(ko.docUrl, isNull);
      expect(AutoHomework.fromJson({'id': '9'}), isNull);
      expect(AutoHomework.fromJson('rien'), isNull);
    });
  });
}
