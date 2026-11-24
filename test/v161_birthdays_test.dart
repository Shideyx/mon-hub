import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/birthdays.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  group('anniversaires', () {
    test('dates comprises', () {
      expect(Birthdays.parseDate('le 12 mars'), (3, 12, null));
      expect(Birthdays.parseDate('1er avril 2011'), (4, 1, 2011));
      expect(Birthdays.parseDate('12/03/2011'), (3, 12, 2011));
      expect(Birthdays.parseDate('3 févr.'), (2, 3, null));
      expect(Birthdays.parseDate('29 février'), (2, 29, null));
      expect(Birthdays.parseDate('31/02'), isNull);
      expect(Birthdays.parseDate('demain'), isNull);
    });

    test('dans l\'agenda', () {
      expect(Birthdays.nameInTitle('Anniversaire de Léa'), 'Léa');
      expect(Birthdays.nameInTitle('Anniversaire d\'Inès 🎂'), 'Inès');
      expect(Birthdays.nameInTitle("Tom's birthday"), 'Tom');
      expect(Birthdays.nameInTitle('🎂 Mamie'), 'Mamie');
      expect(Birthdays.nameInTitle('Hugo Martin', calendar: 'Anniversaires'), 'Hugo Martin');
      expect(Birthdays.nameInTitle('Contrôle de maths'), isNull);
      final l = Birthdays.fromEvents([
        {'titre': 'Anniversaire de Léa', 'debut': '2026-11-19T00:00:00'},
        {'titre': 'MATHS', 'debut': '2026-11-19T08:00:00', 'source': 'École Directe'},
      ]);
      expect(l.single.name, 'Léa');
      expect((l.single.month, l.single.day), (11, 19));
    });

    test('les prochains, l\'âge, sans doublon', () {
      final now = DateTime(2026, 11, 18, 20);
      final up = Birthdays.upcoming([
        const Birthday('Léa', 11, 19, year: 2011),
        const Birthday('Léa', 11, 19, fromAgenda: true),
        const Birthday('Tom', 11, 18),
        const Birthday('Mamie', 1, 5),
        const Birthday('Hugo', 11, 10),
      ], now);
      expect([for (final (b, _) in up) b.name], ['Tom', 'Léa']);
      expect(up[1].$1.year, 2011);
      expect(Birthdays.age(up[1].$1, up[1].$2), 15);
      final say = Birthdays.say(up, now);
      expect(say, startsWith('Aujourd\'hui : Tom 🎂 ; demain : Léa (15 ans)'));
      // Le 29 février, les années sans 29.
      expect(Birthdays.next(const Birthday('Zoé', 2, 29), DateTime(2027, 1, 1)), DateTime(2027, 2, 28));
      // L'an prochain si c'est passé.
      expect(Birthdays.next(const Birthday('Hugo', 11, 10), now), DateTime(2027, 11, 10));
      expect(
        Birthdays.wish(const Birthday('Léa Martin', 11, 19, year: 2011), DateTime(2026, 11, 19)),
        contains('Léa ! 🎉 15 ans'),
      );
    });

    test('phrases sans IA', () async {
      final asked = <String, Map>{};
      Future<String?> ask(String q) async => (await QuickAnswers.answer(
        q,
        call: (n, a) async {
          asked[n] = a;
          return n == 'anniversaires' && a['nom'] == null ? {'resume': 'liste'} : 'ok';
        },
        tools: const {'anniversaires', 'anniversaire_ajouter'},
      ))?.text;
      expect(await ask('L\'anniversaire de Léa c\'est le 12 mars'), 'ok');
      expect(asked['anniversaire_ajouter'], {'nom': 'Léa', 'date': '12/3'});
      expect(await ask('retiens que l\'anniversaire de Mamie est le 05/01/1950'), 'ok');
      expect(asked['anniversaire_ajouter'], {'nom': 'Mamie', 'date': '5/1/1950'});
      expect(await ask('c\'est quand l\'anniversaire de Inès ?'), 'ok');
      expect(asked['anniversaires'], {'nom': 'Inès'});
      expect(await ask('les prochains anniversaires'), 'liste');
      expect(asked['anniversaires'], {'jours': 30});
      expect(await ask('qui a son anniversaire cette semaine'), 'liste');
      expect(asked['anniversaires'], {'jours': 7});
      asked.clear();
      expect(await ask('écris un poème pour l\'anniversaire de ma sœur'), isNull);
      expect(asked, isEmpty);
    });

    test('retrouver les accents de la phrase', () {
      expect(QuickAnswers.original('l\'anniversaire de Léa Dupré', 'lea dupre'), 'Léa Dupré');
      expect(QuickAnswers.original('anniversaire de ma mère', 'ma mere'), 'Ma mère');
    });
  });
}
