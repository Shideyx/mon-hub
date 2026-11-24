import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/ui/clicky/patience.dart';

void main() {
  group('Ce que la personne a répondu', () {
    test('oui', () {
      for (final s in ['oui', 'Ouais', 'ok', 'vas-y', 'd\'accord', 'carrément']) {
        expect(PatienceRules.read(s), Answer.yes, reason: s);
      }
    });

    test('non', () {
      for (final s in ['non', 'nan', 'j\'ai pas envie', 'laisse tomber', 'flemme', 'ça m\'intéresse pas']) {
        expect(PatienceRules.read(s), Answer.no, reason: s);
      }
    });

    test('plus tard', () {
      for (final s in ['plus tard', 'pas maintenant', 'tout à l\'heure', 'ce soir']) {
        expect(PatienceRules.read(s), Answer.later, reason: s);
      }
    });

    test('arrête de me le répéter', () {
      for (final s in [
        'arrête',
        'ça suffit',
        'lâche-moi',
        'ne me le répète plus',
        'arrête de me le répéter',
        'plus jamais',
      ]) {
        expect(PatienceRules.read(s), Answer.never, reason: s);
      }
    });

    test('une vraie question n\'est pas une réponse', () {
      expect(PatienceRules.read('c\'est quoi mes devoirs ?'), Answer.none);
      expect(PatienceRules.read('non mais explique-moi les fractions'), Answer.no);
      expect(PatienceRules.read(''), Answer.none);
    });
  });

  group('Plus il refuse, plus Smily se taît', () {
    test('premier refus : six heures', () {
      expect(PatienceRules.silence(1), const Duration(hours: 6));
    });

    test('deuxième refus : deux jours', () {
      expect(PatienceRules.silence(2), const Duration(days: 2));
    });

    test('troisième refus : il laisse tomber le sujet', () {
      expect(PatienceRules.silence(3), isNull);
    });

    test('« arrête » : il laisse tomber tout de suite', () {
      expect(PatienceRules.silence(1, last: Answer.never), isNull);
    });

    test('« plus tard » n\'est pas un refus : deux heures', () {
      expect(PatienceRules.silence(0, last: Answer.later), const Duration(hours: 2));
    });

    test('il se taît jusqu\'à l\'heure dite, puis il peut reparler', () {
      final now = DateTime(2026, 11, 24, 12);
      expect(PatienceRules.mayTalk(now: now, mutedUntil: now.add(const Duration(hours: 1))), isFalse);
      expect(PatienceRules.mayTalk(now: now, mutedUntil: now.subtract(const Duration(minutes: 1))), isTrue);
      expect(PatienceRules.mayTalk(now: now), isTrue);
      expect(PatienceRules.mayTalk(now: now, dropped: true), isFalse);
    });

    test('il répond sans vexer', () {
      expect(PatienceRules.ack(Answer.never), contains('demande-moi'));
      expect(PatienceRules.ack(Answer.no), contains('insister'));
      expect(PatienceRules.ack(Answer.later), contains('plus tard'));
    });
  });

  group('La mémoire des refus, sujet par sujet', () {
    final p = Patience.instance;
    final now = DateTime(2026, 11, 24, 12);

    setUp(() => p.setForTest({}));

    test('un refus fait taire ce sujet, pas les autres', () async {
      await p.answered('revisions', Answer.no, now: now);
      expect(p.mayTalk('revisions', now: now), isFalse);
      expect(p.mayTalk('devoirs', now: now), isTrue);
      expect(p.mayTalk('revisions', now: now.add(const Duration(hours: 7))), isTrue);
    });

    test('trois refus : le sujet est abandonné', () async {
      for (var i = 0; i < 3; i++) {
        await p.answered('coucher', Answer.no, now: now.add(Duration(days: i * 3)));
      }
      expect(p.dropped('coucher'), isTrue);
      expect(p.mayTalk('coucher', now: now.add(const Duration(days: 30))), isFalse);
      expect(p.droppedSubjects, contains('coucher'));
    });

    test('un oui remet le compteur à zéro', () async {
      await p.answered('sac', Answer.no, now: now);
      await p.answered('sac', Answer.yes, now: now);
      expect(p.refusals('sac'), 0);
      expect(p.mayTalk('sac', now: now), isTrue);
    });

    test('« plus tard » ne compte pas comme un refus', () async {
      await p.answered('sac', Answer.later, now: now);
      expect(p.refusals('sac'), 0);
      expect(p.mayTalk('sac', now: now), isFalse);
      expect(p.mayTalk('sac', now: now.add(const Duration(hours: 3))), isTrue);
    });

    test('quand la personne redemande le sujet, il repart', () async {
      await p.answered('revisions', Answer.never, now: now);
      expect(p.mayTalk('revisions', now: now), isFalse);
      await p.wanted('revisions');
      expect(p.mayTalk('revisions', now: now), isTrue);
    });
  });

  group('Notifications : ce qui part tout de suite', () {
    HubNotification n(String id, {String module = 'ecoledirecte'}) =>
        HubNotification(id: id, title: 't', body: 'b', moduleId: module);

    test('une note, un devoir, un message : tout de suite', () {
      expect(NotificationCenter.urgent(n('note:123')), isTrue);
      expect(NotificationCenter.urgent(n('devoir:7')), isTrue);
      expect(NotificationCenter.urgent(n('msg:9')), isTrue);
      // Discord : l'identifiant est celui du message, sans préfixe.
      expect(NotificationCenter.urgent(n('1309876543210', module: 'discord')), isTrue);
    });

    test('un appel, un cours annulé, une arnaque : tout de suite', () {
      expect(NotificationCenter.urgent(n('discord-appel-1')), isTrue);
      expect(NotificationCenter.urgent(n('annule:maths')), isTrue);
      expect(NotificationCenter.urgent(n('arnaque:lien')), isTrue);
    });

    test('les nouvelles qui peuvent attendre sont regroupées', () {
      for (final id in [
        'abo:spotify',
        'colis:ups',
        'epic-gratuit',
        'veille:artiste',
        'bilan-notes:2026-11-23',
        'temps:1',
      ]) {
        expect(NotificationCenter.urgent(n(id, module: 'money')), isFalse, reason: id);
      }
    });

    test('une notification de Mon Hub lui-même passe toujours', () {
      expect(NotificationCenter.urgent(n('abo:spotify', module: '')), isTrue);
    });
  });
}
