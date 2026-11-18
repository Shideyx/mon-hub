import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/catch_up.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  group('qu\'est-ce que j\'ai raté', () {
    final now = DateTime(2026, 11, 18, 18);
    test('messages, mentions, mails importants (pas les pubs), École Directe, qui attend', () {
      final t = CatchUp.build(
        now: now,
        dms: [
          {'nom': 'Léo', 'dernier': 'Léo : tu viens au match samedi ?', 'non_lu': true, 'de_moi': false, 'date': DateTime(2026, 11, 18, 14)},
          {'nom': 'Inès', 'dernier': 'Moi : ok', 'non_lu': false, 'de_moi': true, 'date': DateTime(2026, 11, 18, 17)},
        ],
        mentions: [
          {'de': 'Hugo', 'serveur': 'Les Potes', 'texte': '@Erik t\'es là ce soir ?', 'date': DateTime(2026, 11, 18, 16)},
        ],
        mails: [
          {'de': 'M. Durand <durand@lycee.fr>', 'objet': 'Sortie au musée', 'lu': false, 'date': DateTime(2026, 11, 18, 12)},
          {'de': 'Zalando <newsletter@zalando.fr>', 'objet': '-50 % sur tout', 'lu': false, 'date': DateTime(2026, 11, 18, 11)},
          {'de': 'Vieux <x@y.fr>', 'objet': 'Ancien', 'lu': false, 'date': DateTime(2026, 11, 10)},
        ],
        school: [
          {'de': 'Mme Martin', 'objet': 'Réunion', 'lu': false},
        ],
      );
      expect(t, startsWith('Pendant ton absence : 1 message privé sur Discord : Léo (« tu viens au match samedi ? »)'));
      expect(t, contains('1 mention sur Les Potes (Hugo : « @Erik t\'es là ce soir ? »)'));
      expect(t, contains('1 mail important : M. Durand (« Sortie au musée »)'));
      expect(t, contains('1 pub ou newsletter sans importance'));
      expect(t, contains('1 message École Directe (Mme Martin)'));
      expect(t, endsWith('Léo attend ta réponse depuis 4 h.'));
      expect(CatchUp.short(t), 'Tu as 1 message privé sur Discord et 1 mention sur Les Potes.');
    });

    test('rien de nouveau', () {
      expect(CatchUp.build(now: now), '');
      expect(CatchUp.short(''), '');
    });

    test('« qu\'est-ce que j\'ai raté ? »', () async {
      final calls = <String>[];
      final r = await QuickAnswers.answer(
        'Qu\'est-ce que j\'ai raté depuis hier ?',
        call: (n, a) async {
          calls.add('$n $a');
          return 'Pendant ton absence : rien.';
        },
        tools: const {'clicky_rate'},
      );
      expect(r?.text, 'Pendant ton absence : rien.');
      expect(calls.single, 'clicky_rate {heures: 24}');
    });
  });
}
