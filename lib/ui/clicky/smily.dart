import 'package:material_ui/material_ui.dart';

import 'alive.dart' show AliveMood;
import 'life_view.dart' show emojiFonts;

/// Ce que Nexo ressent, à l'écran : un smiley par état.
///
/// Avant, c'était un curseur en forme de flèche (un look copié ailleurs, et
/// le plus coûteux à dessiner). Maintenant c'est un visage : un vrai smiley,
/// qui change d'expression selon ce qu'il fait et ce qui arrive.
enum SmilyMood {
  /// Au repos : il veille, tranquille.
  calm('🙂'),

  /// Il t'écoute.
  listening('😮'),

  /// Il réfléchit.
  thinking('🤔'),

  /// Il te parle.
  speaking('😄'),

  /// Il montre quelque chose à l'écran ou il agit.
  acting('😎'),

  /// Il travaille pour toi en arrière-plan.
  working('🧐'),

  /// Il dort (tu n'as rien touché depuis un moment).
  asleep('😴'),

  /// Mode concentration : il se taît.
  quiet('🤫'),

  /// Une bonne nouvelle (une bonne note, un cours annulé).
  happy('🤩'),

  /// Un souci (une erreur, une arnaque, un devoir oublié).
  worried('😟');

  const SmilyMood(this.emoji);

  /// Le smiley affiché.
  final String emoji;
}

/// Les règles, **sans affichage** : testables.
class SmilyRules {
  const SmilyRules._();

  /// Le smiley à montrer, selon ce qu'il fait et ce qui se passe.
  ///
  /// L'ordre compte : ce qu'il fait **maintenant** passe avant son humeur.
  static SmilyMood moodFor({
    required AliveMood doing,
    bool asleep = false,
    bool quiet = false,
    int agents = 0,
    String? feeling,
  }) {
    switch (doing) {
      case AliveMood.listening:
        return SmilyMood.listening;
      case AliveMood.thinking:
        return SmilyMood.thinking;
      case AliveMood.speaking:
        return SmilyMood.speaking;
      case AliveMood.pointing:
        return SmilyMood.acting;
      case AliveMood.idle:
        break;
    }
    if (asleep) return SmilyMood.asleep;
    if (agents > 0) return SmilyMood.working;
    if (quiet) return SmilyMood.quiet;
    return switch (feeling) {
      '🤩' || '🥳' || '😍' || '😄' => SmilyMood.happy,
      '😟' || '🚨' || '🫂' || '😬' => SmilyMood.worried,
      _ => SmilyMood.calm,
    };
  }

  /// Ce qu'il répond quand on lui demande comment il va (sans IA).
  static String say(SmilyMood m) => switch (m) {
    SmilyMood.calm => 'Tranquille, je veille.',
    SmilyMood.listening => 'Je t\'écoute.',
    SmilyMood.thinking => 'Je réfléchis.',
    SmilyMood.speaking => 'Je te parle, là !',
    SmilyMood.acting => 'Je suis en train de faire quelque chose à l\'écran.',
    SmilyMood.working => 'Je travaille sur une tâche pour toi.',
    SmilyMood.asleep => 'Je somnolais.',
    SmilyMood.quiet => 'Tu es en mode concentration, je me tais.',
    SmilyMood.happy => 'Plutôt content !',
    SmilyMood.worried => 'Il y a un truc qui m\'embête.',
  };
}

/// **Le visage de Nexo** : un smiley qui change d'expression.
class SmilyFace extends StatelessWidget {
  const SmilyFace({super.key, required this.mood, this.size = 24, this.agents = 0});

  final SmilyMood mood;
  final double size;

  /// Nombre de tâches en cours (petit chiffre dans le coin).
  final int agents;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 2,
      height: size + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Le smiley change d'un fondu : pas de clignotement.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              mood.emoji,
              key: ValueKey(mood),
              style: TextStyle(fontSize: size, fontFamilyFallback: emojiFonts, height: 1),
            ),
          ),
          if (agents > 0)
            Positioned(
              right: -4,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(8)),
                child: Text('$agents', style: const TextStyle(color: Colors.white, fontSize: 10)),
              ),
            ),
        ],
      ),
    );
  }
}
