import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/ecoledirecte/grade_math.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/school_bag.dart';
import 'package:hub/ui/clicky/text_fix.dart';

EdGrade g(String subject, String v, {String outOf = '20', double coef = 1, String period = 'A002', DateTime? date, bool counts = true}) =>
    EdGrade('$subject$v${date?.day}', subject, v, outOf, 'devoir', date ?? DateTime(2026, 11, 2), coef: coef, period: period, counts: counts);

void main() {
  group('notes', () {
    test('coefficients, notes sur 10, notes qui ne comptent pas', () {
      final j = EdGrade.fromJson({'id': 1, 'libelleMatiere': 'MATHEMATIQUES', 'valeur': '12,5', 'noteSur': '20', 'coef': '2.00', 'codePeriode': 'A002', 'nonSignificatif': false});
      expect(j.coef, 2);
      expect(GradeMath.on20(j), 12.5);
      expect(GradeMath.on20(g('M', '7', outOf: '10')), 14);
      expect(GradeMath.on20(g('M', 'Abs')), isNull);
      expect(GradeMath.on20(g('M', '15', counts: false)), isNull);
      final list = [g('M', '10'), g('M', '16', coef: 2), g('M', 'Abs'), g('M', '2', period: 'A001')];
      final cur = GradeMath.currentPeriod(list);
      expect(cur.length, 3);
      expect(GradeMath.average(cur), 14); // (10 + 16×2) / 3
    });

    test('la note qu\'il faut au prochain devoir', () {
      final list = [g('MATHEMATIQUES', '10'), g('MATHEMATIQUES', '12')]; // moyenne 11
      expect(GradeMath.needed(list, 12), 14); // (12×3 − 22) / 1
      expect(GradeMath.needed(list, 12, coef: 2), 13); // (12×4 − 22) / 2
      expect(GradeMath.sayNeeded('Maths', list, 12), contains('au moins 14/20'));
      expect(GradeMath.sayNeeded('Maths', list, 19), contains('pas possible en une seule note'));
      expect(GradeMath.sayNeeded('Maths', list, 5), contains('même avec 0'));
    });

    test('retrouver la matière dite à l\'oral', () {
      const subjects = ['MATHEMATIQUES', 'SCIENCES VIE & TERRE', 'PHYSIQUE-CHIMIE', 'ANGLAIS LV1', 'ED.PHYSIQUE & SPORT.', 'HISTOIRE-GEOGRAPHIE'];
      expect(GradeMath.matchSubject('maths', subjects), 'MATHEMATIQUES');
      expect(GradeMath.matchSubject('SVT', subjects), 'SCIENCES VIE & TERRE');
      expect(GradeMath.matchSubject('physique', subjects), 'PHYSIQUE-CHIMIE');
      expect(GradeMath.matchSubject('en anglais', subjects), 'ANGLAIS LV1');
      expect(GradeMath.matchSubject('sport', subjects), 'ED.PHYSIQUE & SPORT.');
      expect(GradeMath.matchSubject('géo', subjects), 'HISTOIRE-GEOGRAPHIE');
      expect(GradeMath.matchSubject('latin', subjects), isNull);
    });

    test('bilan de la semaine', () {
      final now = DateTime(2026, 11, 20, 18);
      final list = [
        g('MATHEMATIQUES', '10', date: DateTime(2026, 11, 3)),
        g('MATHEMATIQUES', '16', date: DateTime(2026, 11, 18)),
        g('ANGLAIS LV1', '12', date: DateTime(2026, 11, 4)),
      ];
      final r = GradeMath.weekReport(list, now)!;
      expect(r, startsWith('1 nouvelle note cette semaine.'));
      expect(r, contains('MATHEMATIQUES : 16/20 (moyenne 10 → 13 ↑)'));
      expect(r, contains('Moyenne générale : 11 → 12,5 ↑'));
      expect(GradeMath.weekReport(list, DateTime(2026, 12, 20)), isNull);
    });
  });

  group('phrases', () {
    final calls = <String>[];
    Future<Object?> fake(String name, Map<String, dynamic> args) async {
      calls.add('$name $args');
      if (name == 'ecole_moyenne') {
        if (args['objectif'] != null) return {'resume': 'Il te faut 14/20.'};
        if ('${args['matiere']}'.isEmpty) return {'generale': '13,2'};
        return {'matiere': 'MATHEMATIQUES', 'moyenne': '11', 'nombre_de_notes': 2};
      }
      if (name == 'ecole_bilan_notes') return '2 nouvelles notes cette semaine.';
      return null;
    }

    Future<String?> ask(String q) async => (await QuickAnswers.answer(
      q,
      call: fake,
      tools: const {'ecole_moyenne', 'ecole_bilan_notes', 'ecole_notes'},
    ))?.text;

    test('note nécessaire, moyenne, bilan', () async {
      calls.clear();
      expect(await ask('Il me faut combien en maths pour avoir 14 ?'), 'Il te faut 14/20.');
      expect(calls.last, 'ecole_moyenne {matiere: maths, objectif: 14.0}');
      expect(await ask('quelle note il me faut au prochain contrôle de physique pour avoir 12,5 de moyenne'), 'Il te faut 14/20.');
      expect(calls.last, 'ecole_moyenne {matiere: physique, objectif: 12.5}');
      expect(await ask('c\'est quoi ma moyenne en maths'), contains('est de 11'));
      expect(await ask('ma moyenne générale'), contains('13,2'));
      expect(await ask('bilan de mes notes'), '2 nouvelles notes cette semaine.');
    });

    test('les vraies questions vont à l\'IA', () async {
      expect(await ask('comment on calcule une moyenne pondérée'), isNull);
    });
  });

  group('prépare ton sac', () {
    final day = DateTime(2026, 11, 19);
    Map lesson(String t, int h) => {'titre': t, 'debut': DateTime(2026, 11, 19, h), 'fin': DateTime(2026, 11, 19, h + 1), 'source': 'École Directe'};
    final events = [
      lesson('MATHEMATIQUES', 8),
      lesson('ED.PHYSIQUE & SPORT.', 10),
      lesson('ANGLAIS LV1', 14),
      lesson('MATHEMATIQUES', 15),
      {'titre': 'Dentiste', 'debut': DateTime(2026, 11, 19, 17), 'fin': DateTime(2026, 11, 19, 18), 'source': 'Mes évènements'},
      {'titre': 'HISTOIRE-GEOGRAPHIE', 'debut': DateTime(2026, 11, 20, 8), 'fin': DateTime(2026, 11, 20, 9), 'source': 'École Directe'},
    ];
    final homework = [
      {'pour_le': DateTime(2026, 11, 19), 'matiere': 'MATHEMATIQUES', 'contenu': 'DM', 'fait': false},
      {'pour_le': DateTime(2026, 11, 19), 'matiere': 'SVT', 'contenu': 'Contrôle', 'fait': false, 'controle': true},
      {'pour_le': DateTime(2026, 11, 20), 'matiere': 'FRANCAIS', 'contenu': 'Lire', 'fait': false},
    ];

    test('les affaires d\'après les cours, les devoirs et les contrôles', () {
      final p = SchoolBag.plan(events: events, homework: homework, day: day)!;
      expect(p.subjects, ['MATHEMATIQUES', 'ED.PHYSIQUE & SPORT.', 'ANGLAIS LV1']);
      expect(p.items, contains('ta calculatrice'));
      expect(p.items, contains('ta tenue de sport'));
      expect(p.items, contains('ton livre d\'anglais'));
      expect(p.homework, ['MATHEMATIQUES']);
      expect(p.tests, ['SVT']);
      final text = SchoolBag.say(p, 'demain');
      expect(text, startsWith('Demain, tu as MATHEMATIQUES, ED.PHYSIQUE & SPORT. et ANGLAIS LV1.'));
      expect(text, contains('contrôle de SVT demain'));
      expect(SchoolBag.plan(events: events, homework: homework, day: DateTime(2026, 11, 22)), isNull);
    });

    test('tes affaires à toi remplacent les habituelles', () {
      final custom = SchoolBag.parseCustom('EPS : kimono, gourde\nMaths: compas ; calculatrice\nligne sans deux points');
      expect(custom, {'EPS': ['kimono', 'gourde'], 'Maths': ['compas', 'calculatrice']});
      expect(SchoolBag.itemsFor('ED.PHYSIQUE & SPORT.', custom), ['kimono', 'gourde']);
      expect(SchoolBag.itemsFor('ED.PHYSIQUE & SPORT.'), ['ta tenue de sport', 'tes baskets', 'une gourde']);
      expect(SchoolBag.itemsFor('EPS', custom), ['kimono', 'gourde']);
      expect(SchoolBag.itemsFor('MATHEMATIQUES', custom), ['compas', 'calculatrice']);
    });

    test('« qu\'est-ce que je dois prendre demain »', () async {
      final r = await QuickAnswers.answer(
        'Qu\'est-ce que je dois prendre demain ?',
        call: (n, a) async => n == 'assistant_sac' ? 'Demain, tu as Maths.' : null,
        tools: const {'assistant_sac'},
      );
      expect(r?.text, 'Demain, tu as Maths.');
      final r2 = await QuickAnswers.answer('prépare mon sac', call: (n, a) async => 'ok', tools: const {'assistant_sac'});
      expect(r2?.text, 'ok');
    });
  });

  group('corriger le texte surligné', () {
    test('consignes selon le mode', () {
      expect(TextFix.prompt('salu sa va', mode: 'corriger'), contains('Corrige uniquement'));
      expect(TextFix.prompt('x', mode: 'traduire:espagnol'), contains('en espagnol'));
      expect(TextFix.prompt('x', mode: 'reformuler'), contains('Reformule'));
      expect(TextFix.prompt('salu sa va'), contains('<<<\nsalu sa va\n>>>'));
    });

    test('la réponse de l\'IA nettoyée, espaces d\'origine gardés', () {
      expect(TextFix.clean('```\nSalut, ça va ?\n```', '  salu sa va ?\n'), '  Salut, ça va ?\n');
      expect(TextFix.clean('« Bonjour »', 'bonjou'), 'Bonjour');
      expect(TextFix.clean('« Bonjour »', '« bonjou »'), '« Bonjour »');
      expect(TextFix.clean('<<<\nJe suis allé\n>>>', 'je suis allez'), 'Je suis allé');
    });

    test('nombre de mots changés', () {
      expect(TextFix.changes('je suis allez au parc', 'Je suis allé au parc'), 2);
      expect(TextFix.changes('pareil', 'pareil'), 0);
    });

    test('« corrige ce que j\'ai surligné » sans IA', () async {
      final calls = <String>[];
      Future<String?> ask(String q) async => (await QuickAnswers.answer(
        q,
        call: (n, a) async {
          calls.add('$n ${a['mode']}');
          return 'Corrigé ✓';
        },
        tools: const {'clicky_corriger_selection'},
      ))?.text;
      expect(await ask('Clicky, corrige ce que j\'ai surligné'), 'Corrigé ✓');
      expect(await ask('traduis la sélection en anglais'), 'Corrigé ✓');
      expect(await ask('reformule mon texte'), 'Corrigé ✓');
      expect(calls, ['clicky_corriger_selection corriger', 'clicky_corriger_selection traduire:anglais', 'clicky_corriger_selection reformuler']);
      expect(await ask('corrige mon exercice de maths'), isNull);
    });
  });
}
