import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/alive.dart' show AliveMood;
import 'package:hub/ui/clicky/smily.dart';
import 'package:hub/ui/clicky/wake.dart';

void main() {
  group('Le smiley de Nexo', () {
    test('au repos, il est tranquille', () {
      expect(SmilyRules.moodFor(doing: AliveMood.idle), SmilyMood.calm);
      expect(SmilyMood.calm.emoji, '🙂');
    });

    test('ce qu\'il fait passe avant son humeur', () {
      expect(SmilyRules.moodFor(doing: AliveMood.listening, feeling: '🤩'), SmilyMood.listening);
      expect(SmilyRules.moodFor(doing: AliveMood.thinking, asleep: true), SmilyMood.thinking);
      expect(SmilyRules.moodFor(doing: AliveMood.speaking), SmilyMood.speaking);
      expect(SmilyRules.moodFor(doing: AliveMood.pointing), SmilyMood.acting);
    });

    test('il dort quand tu n\'es plus là', () {
      expect(SmilyRules.moodFor(doing: AliveMood.idle, asleep: true), SmilyMood.asleep);
    });

    test('il travaille quand une tâche tourne pour toi', () {
      expect(SmilyRules.moodFor(doing: AliveMood.idle, agents: 2), SmilyMood.working);
    });

    test('mode concentration : il se taît', () {
      expect(SmilyRules.moodFor(doing: AliveMood.idle, quiet: true), SmilyMood.quiet);
    });

    test('une bonne nouvelle le rend content, une mauvaise l\'inquiète', () {
      expect(SmilyRules.moodFor(doing: AliveMood.idle, feeling: '🤩'), SmilyMood.happy);
      expect(SmilyRules.moodFor(doing: AliveMood.idle, feeling: '🚨'), SmilyMood.worried);
      expect(SmilyRules.moodFor(doing: AliveMood.idle, feeling: '🎵'), SmilyMood.calm);
    });

    test('chaque état a son smiley, et ils sont tous différents', () {
      final emojis = {for (final m in SmilyMood.values) m.emoji};
      expect(emojis.length, SmilyMood.values.length);
      expect(emojis.any((e) => e.isEmpty), isFalse);
    });

    test('il sait dire ce qu\'il ressent, sans IA', () {
      for (final m in SmilyMood.values) {
        expect(SmilyRules.say(m), isNotEmpty);
      }
      expect(SmilyRules.say(SmilyMood.working), contains('tâche'));
    });
  });

  group('On l\'appelle par son nouveau nom', () {
    test('« Nexo » le réveille, avec les fautes d\'écoute courantes', () {
      expect(WakeWord.phrases, contains('smily'));
      expect(WakeWord.phrases, contains('smiley'));
      expect(WakeWord.phrases.any((p) => p.contains('hey smily')), isTrue);
    });

    test('l\'ancien nom marche encore, le temps de l\'habitude', () {
      expect(WakeWord.phrases, contains('clicky'));
    });
  });
}
