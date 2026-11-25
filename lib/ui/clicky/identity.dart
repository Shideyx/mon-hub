import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/perf.dart';
import 'smily.dart' show SmilyMood;

/// **Nexo** : l'identité de l'assistant de Mon Hub (ex-Clicky, ex-Smily).
///
/// Un nom court, sans accent, facile à dire et à reconnaître à la voix
/// (« Nexo, fais le point »). Il vient de *nexus* : le lien. Nexo relie tout
/// ce que tu utilises — cours, messages, musique, ton PC — et agit pour toi,
/// avec un coup d'avance.
///
/// Son corps : **la Pointe**, un curseur taillé comme une flèche à deux faces
/// (violet et rose de Mon Hub), avec un **noyau** lumineux qui montre ce
/// qu'il fait (il écoute, il réfléchit, il parle, il agit…).
///
/// Les noms de code restent `Clicky*` / `clicky_*` (classes, outils, clés de
/// réglages) : seuls les textes vus par la personne portent son nom.
class Nexo {
  Nexo._();

  /// Son nom.
  static const name = 'Nexo';

  /// Son nom en capitales (titres, console).
  static const upper = 'NEXO';

  /// Sa devise.
  static const tagline = 'Toujours un coup d\'avance.';

  /// D'où vient son nom (dit quand on le lui demande).
  static const lore =
      'Nexo, ça vient de nexus : le lien. Je relie tout ce que tu utilises — tes cours, tes messages, ta '
      'musique, ton PC — et je m\'occupe du reste. Toujours un coup d\'avance.';

  /// Couleurs de son corps (celles de Mon Hub).
  static const violet = Color(0xFF7C5CFF);
  static const rose = Color(0xFFE0457B);
  static const night = Color(0xFF120D24);

  /// Couleur de son noyau selon ce qu'il fait.
  static Color coreColor(NexoMode m) => switch (m) {
    NexoMode.idle => const Color(0xFFE9E2FF),
    NexoMode.listening => rose,
    NexoMode.thinking => const Color(0xFFB9A6FF),
    NexoMode.speaking => Colors.white,
    NexoMode.acting => Colors.white,
    NexoMode.working => const Color(0xFFFFC24B),
    NexoMode.asleep => const Color(0xFF8E86A8),
    NexoMode.quiet => const Color(0xFF9C8FD6),
    NexoMode.happy => const Color(0xFFFFD35C),
    NexoMode.worried => const Color(0xFFFF8A3D),
  };

  /// Ce qu'il montre, d'après son humeur (même ordre que `SmilyRules.moodFor` :
  /// ce qu'il fait passe avant ce qu'il ressent).
  static NexoMode modeFor(SmilyMood m) => switch (m) {
    SmilyMood.calm => NexoMode.idle,
    SmilyMood.listening => NexoMode.listening,
    SmilyMood.thinking => NexoMode.thinking,
    SmilyMood.speaking => NexoMode.speaking,
    SmilyMood.acting => NexoMode.acting,
    SmilyMood.working => NexoMode.working,
    SmilyMood.asleep => NexoMode.asleep,
    SmilyMood.quiet => NexoMode.quiet,
    SmilyMood.happy => NexoMode.happy,
    SmilyMood.worried => NexoMode.worried,
  };

  /// Les modes qui bougent (une animation tourne) : jamais au repos.
  static bool animated(NexoMode m) =>
      m == NexoMode.listening || m == NexoMode.thinking || m == NexoMode.speaking || m == NexoMode.acting;

  /// Sa salutation au démarrage.
  static String greeting(String person, DateTime now) {
    final part = now.hour >= 5 && now.hour < 18 ? 'Bonjour' : 'Bonsoir';
    final who = person.trim().isEmpty ? '' : ' ${person.trim()}';
    return '$part$who. Nexo en ligne, tous les systèmes sont prêts. '
        'Maintiens Contrôle et Alt, ou dis « Nexo », pour me parler.';
  }
}

/// Ce que montre son noyau.
enum NexoMode { idle, listening, thinking, speaking, acting, working, asleep, quiet, happy, worried }

/// **La Pointe** : le corps de Nexo. La pointe du curseur est en haut à
/// gauche (au même endroit que celle de la souris).
class NexoPointer extends StatefulWidget {
  const NexoPointer({super.key, required this.mode, this.size = 26, this.level = 0, this.agents = 0});

  final NexoMode mode;
  final double size;

  /// Niveau de la voix (0..1) pendant qu'il écoute.
  final double level;

  /// Tâches en cours (petit chiffre dans le coin).
  final int agents;

  @override
  State<NexoPointer> createState() => _NexoPointerState();
}

class _NexoPointerState extends State<NexoPointer> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(NexoPointer old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) _sync();
  }

  /// L'animation ne tourne que quand il fait quelque chose (fluidité).
  void _sync() {
    final move = Nexo.animated(widget.mode) && Perf.animations;
    if (move && !_a.isAnimating) {
      _a.repeat();
    } else if (!move && _a.isAnimating) {
      _a.stop();
      _a.value = 0;
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final dim = widget.mode == NexoMode.asleep || widget.mode == NexoMode.quiet;
    return SizedBox(
      width: s + 6,
      height: s + 6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          RepaintBoundary(
            child: Opacity(
              opacity: dim ? 0.6 : 1,
              child: AnimatedBuilder(
                animation: _a,
                builder: (context, _) => CustomPaint(
                  size: Size.square(s),
                  painter: NexoPainter(mode: widget.mode, t: _a.value, level: widget.level),
                ),
              ),
            ),
          ),
          if (widget.agents > 0)
            Positioned(
              right: -2,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: const Color(0xFFFFC24B), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  '${widget.agents}',
                  style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Le dessin de la Pointe : deux faces (violet / rose), un liseré clair qui
/// se voit sur tous les fonds, et le noyau.
class NexoPainter extends CustomPainter {
  NexoPainter({required this.mode, this.t = 0, this.level = 0});

  final NexoMode mode;

  /// Avancement de l'animation (0..1).
  final double t;
  final double level;

  /// Les points de la Pointe (pour la taille [s]) : pointe, aile, creux,
  /// queue.
  static (Offset, Offset, Offset, Offset) points(Size s) => (
    Offset.zero,
    Offset(s.width * 0.94, s.height * 0.58),
    Offset(s.width * 0.50, s.height * 0.62),
    Offset(s.width * 0.30, s.height * 0.98),
  );

  /// Où est le noyau.
  static Offset core(Size s) => Offset(s.width * 0.40, s.height * 0.45);

  @override
  void paint(Canvas canvas, Size size) {
    final (tip, wing, notch, tail) = points(size);
    final outline = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(wing.dx, wing.dy)
      ..lineTo(notch.dx, notch.dy)
      ..lineTo(tail.dx, tail.dy)
      ..close();
    // Ombre douce : il flotte au-dessus de l'écran.
    canvas.drawShadow(outline, Colors.black, 3, false);

    // Face gauche (lumière) et face droite (ombre) : l'effet « taillé ».
    final left = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(notch.dx, notch.dy)
      ..lineTo(tail.dx, tail.dy)
      ..close();
    final right = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(wing.dx, wing.dy)
      ..lineTo(notch.dx, notch.dy)
      ..close();
    final rect = Offset.zero & size;
    canvas.drawPath(
      left,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF9B82FF), Nexo.violet],
        ).createShader(rect),
    );
    canvas.drawPath(
      right,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Nexo.violet, Nexo.rose],
        ).createShader(rect),
    );
    // Le liseré.
    canvas.drawPath(
      outline,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.06
        ..strokeJoin = StrokeJoin.round,
    );

    // Le noyau.
    final c = core(size);
    final r = size.width * 0.10;
    final color = Nexo.coreColor(mode);
    final wave = math.sin(t * 2 * math.pi);
    final glow = switch (mode) {
      NexoMode.listening => 1.0 + 1.4 * level.clamp(0.0, 1.0),
      NexoMode.speaking => 1.3 + 0.5 * wave.abs(),
      NexoMode.acting => 1.6,
      NexoMode.asleep || NexoMode.quiet => 0.5,
      _ => 1.0,
    };
    canvas.drawCircle(
      c,
      r * (1.6 + glow),
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 1.4),
    );
    canvas.drawCircle(c, r * (mode == NexoMode.speaking ? 1 + 0.25 * wave.abs() : 1), Paint()..color = color);

    // Il réfléchit : un arc tourne autour du noyau.
    if (mode == NexoMode.thinking) {
      final ring = Rect.fromCircle(center: c, radius: r * 2.3);
      canvas.drawArc(
        ring,
        t * 2 * math.pi,
        math.pi * 0.9,
        false,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.width * 0.05
          ..strokeCap = StrokeCap.round,
      );
    }
    // Il agit : la pointe s'allume.
    if (mode == NexoMode.acting) {
      canvas.drawCircle(
        tip + Offset(size.width * 0.06, size.height * 0.06),
        size.width * (0.08 + 0.05 * wave.abs()),
        Paint()
          ..color = Colors.white
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.06),
      );
    }
  }

  @override
  bool shouldRepaint(NexoPainter o) => o.mode != mode || o.t != t || o.level != level;
}
