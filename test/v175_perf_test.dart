import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/perf.dart';

void main() {
  group('Mode léger : quels PC sont jugés modestes', () {
    test('un petit PC (2 cœurs, 4 Go) est modeste', () {
      expect(PerfRules.modest(cores: 2, ramGb: 4), isTrue);
    });

    test('4 cœurs mais 4 Go de mémoire : modeste', () {
      expect(PerfRules.modest(cores: 4, ramGb: 4), isTrue);
    });

    test('4 cœurs et 8 Go : encore modeste (Mon Hub se calme)', () {
      expect(PerfRules.modest(cores: 4, ramGb: 8), isTrue);
    });

    test('6 cœurs et 16 Go : PC confortable', () {
      expect(PerfRules.modest(cores: 6, ramGb: 16), isFalse);
    });

    test('8 cœurs et 16 Go : PC confortable', () {
      expect(PerfRules.modest(cores: 8, ramGb: 16), isFalse);
    });

    test('mémoire inconnue (0) : on ne juge que sur les cœurs', () {
      expect(PerfRules.modest(cores: 8, ramGb: 0), isFalse);
      expect(PerfRules.modest(cores: 2, ramGb: 0), isTrue);
    });

    test('cœurs inconnus : on ne juge que sur la mémoire', () {
      expect(PerfRules.modest(cores: 0, ramGb: 3), isTrue);
      expect(PerfRules.modest(cores: 0, ramGb: 16), isFalse);
    });
  });

  group('Les tours de surveillance sont allongés en mode léger', () {
    test('en mode complet, rien ne change', () {
      expect(PerfRules.slow(const Duration(seconds: 2), light: false), const Duration(seconds: 2));
    });

    test('en mode léger, 2 s deviennent 5 s', () {
      expect(PerfRules.slow(const Duration(seconds: 2), light: true), const Duration(seconds: 5));
    });

    test('le facteur se règle (presse-papier : 1,5 s → 4,5 s)', () {
      expect(
        PerfRules.slow(const Duration(milliseconds: 1500), light: true, factor: 3),
        const Duration(milliseconds: 4500),
      );
    });
  });

  group('Perf : ce que le mode léger coupe', () {
    tearDown(() => Perf.level = null);

    test('mode léger : Smily reste dans la fenêtre, rien de lourd', () {
      Perf.level = PerfLevel.light;
      expect(Perf.light, isTrue);
      expect(Perf.everywhere, isFalse);
      expect(Perf.heavy, isFalse);
      expect(Perf.animations, isFalse);
      expect(Perf.slow(const Duration(seconds: 15)), const Duration(milliseconds: 37500));
    });

    test('mode complet : tout est allumé', () {
      Perf.level = PerfLevel.full;
      expect(Perf.light, isFalse);
      expect(Perf.everywhere, isTrue);
      expect(Perf.heavy, isTrue);
      expect(Perf.slow(const Duration(seconds: 15)), const Duration(seconds: 15));
    });

    test('le démarrage est étalé, et plus encore en mode léger', () {
      Perf.level = PerfLevel.full;
      expect(Perf.stagger(0), isA<Future<void>>());
      Perf.level = PerfLevel.light;
      // Rien ne doit lever : les retards sont de simples attentes.
      expect(() => Perf.later(1, () {}), returnsNormally);
    });

    test('la phrase d\'explication parle du bon mode', () {
      Perf.level = PerfLevel.light;
      expect(Perf.explain, contains('léger'));
      Perf.level = PerfLevel.full;
      expect(Perf.explain, contains('complet'));
    });
  });
}
