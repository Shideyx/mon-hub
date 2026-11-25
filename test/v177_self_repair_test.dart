import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/self_repair.dart';

/// Un morceau de journal d'erreurs comme celui du PC.
String log(List<String> entries, {DateTime? at}) {
  final t = at ?? DateTime(2026, 11, 23, 20);
  return [for (final e in entries) '[${t.toIso8601String()}] Mon Hub\n$e\n'].join('\n');
}

void main() {
  final now = DateTime(2026, 11, 23, 21);

  group('Ce que l\'assistant sait réparer', () {
    test('un micro bloqué', () {
      final r = RepairRules.diagnose(
        log(['Bad state: Process is detached', 'micro : la reconnaissance vocale a échoué']),
        now: now,
      );
      expect(r.map((x) => x.id), contains('micro'));
      expect(r.firstWhere((x) => x.id == 'micro').tool, 'clicky_reparer_micro');
    });

    test('des certificats cassés', () {
      final r = RepairRules.diagnose(log(['HandshakeException: CERTIFICATE_VERIFY_FAILED']), now: now);
      expect(r.map((x) => x.id), contains('certificats'));
    });

    test('une appli qui fige trois fois : passage en mode léger', () {
      final r = RepairRules.diagnose(log(['figé', 'figé', 'figé']), now: now);
      expect(r.map((x) => x.id), contains('gels'));
    });

    test('déjà en mode léger : on ne le repropose pas', () {
      final r = RepairRules.diagnose(log(['figé', 'figé', 'figé']), now: now, light: true);
      expect(r.map((x) => x.id), isNot(contains('gels')));
    });

    test('Nexo partout qui n\'arrive pas à tenir', () {
      final r = RepairRules.diagnose(
        log([
          "Nexo partout s'est fermé : relancé",
          "Nexo partout s'est fermé : relancé",
          "Nexo partout s'est fermé : relancé",
        ]),
        now: now,
      );
      expect(r.map((x) => x.id), contains('clicky-partout'));
    });

    test('un disque presque plein', () {
      expect(RepairRules.diagnose('', now: now, diskFreeGb: 1.2).map((x) => x.id), contains('disque'));
      expect(RepairRules.diagnose('', now: now, diskFreeGb: 40).map((x) => x.id), isNot(contains('disque')));
    });

    test('un fichier de données abîmé', () {
      final r = RepairRules.diagnose(
        log([
          'FormatException: Unexpected end of input (carnet.json)',
          'FormatException: Unexpected character (notes.json)',
        ]),
        now: now,
      );
      expect(r.map((x) => x.id), contains('donnees'));
    });

    test('un journal vide : rien à réparer', () {
      expect(RepairRules.diagnose('', now: now), isEmpty);
    });

    test('une seule erreur de micro ne suffit pas (ça arrive)', () {
      expect(RepairRules.diagnose(log(['micro bizarre']), now: now), isEmpty);
    });
  });

  group('On ne répare que ce qui est récent', () {
    test('une panne d\'il y a une semaine est ignorée', () {
      final old = log(['figé', 'figé', 'figé'], at: now.subtract(const Duration(days: 7)));
      expect(RepairRules.diagnose(old, now: now), isEmpty);
    });

    test('une panne d\'hier compte encore', () {
      final hier = log(['figé', 'figé', 'figé'], at: now.subtract(const Duration(hours: 10)));
      expect(RepairRules.diagnose(hier, now: now).map((x) => x.id), contains('gels'));
    });

    test('un journal sans date est gardé (on ne rate rien)', () {
      expect(RepairRules.recentLines('figé\nfigé\nfigé', now: now).length, 3);
    });
  });

  group('Ce qu\'il dit à la personne', () {
    test('rien à réparer', () {
      expect(RepairRules.say(const []), contains('rien'));
    });

    test('une seule réparation', () {
      final say = RepairRules.say(const [
        Repair(id: 'micro', title: 'Ton micro restait bloqué', fixed: 'je l\'ai relancé'),
      ]);
      expect(say, 'Ton micro restait bloqué : je l\'ai relancé.');
    });

    test('plusieurs réparations', () {
      final say = RepairRules.say(const [
        Repair(id: 'micro', title: 'Ton micro restait bloqué', fixed: 'je l\'ai relancé'),
        Repair(id: 'gels', title: 'Mon Hub figeait', fixed: 'mode léger'),
      ]);
      expect(say, contains('réparé tout seul'));
      expect(say, contains('mode léger'));
    });
  });
}
