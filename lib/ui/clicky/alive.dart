import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Ce que fait Smily (pour choisir son animation).
enum AliveMood { idle, listening, thinking, speaking, pointing }

/// Donne de la vie au curseur de Smily, **sans animation qui tourne en
/// boucle pour rien** (fluidité, et Smily partout reste sur l'écran toute
/// la journée) :
/// * à chaque changement d'état : un petit rebond (écrasé puis étiré) ;
/// * quand il commence à parler : un saut de joie ;
/// * pendant qu'il réfléchit : un halo de couleur qui tourne (seulement à
///   ce moment-là) ;
/// * pendant qu'il écoute : une onde qui s'élargit ;
/// * au repos : de temps en temps, un petit coucou (penché), puis plus rien.
class ClickyBounce extends StatefulWidget {
  const ClickyBounce({
    super.key,
    required this.mood,
    required this.child,
    this.color = const Color(0xFF3B82F6),
    this.size = 26,
  });

  final AliveMood mood;
  final Widget child;
  final Color color;
  final double size;

  @override
  State<ClickyBounce> createState() => _ClickyBounceState();
}

class _ClickyBounceState extends State<ClickyBounce> with TickerProviderStateMixin {
  /// Rebond d'un changement d'état (une fois).
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  /// Halo / onde (seulement en réflexion ou écoute).
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  /// Petit coucou au repos (une fois de temps en temps).
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  Timer? _idle;
  bool _hop = false;
  final _rnd = math.Random();

  @override
  void initState() {
    super.initState();
    _apply(null);
  }

  @override
  void didUpdateWidget(ClickyBounce old) {
    super.didUpdateWidget(old);
    if (old.mood != widget.mood) _apply(old.mood);
  }

  void _apply(AliveMood? from) {
    final m = widget.mood;
    // Saut de joie quand la réponse arrive (réflexion → parole).
    _hop = from == AliveMood.thinking && (m == AliveMood.speaking || m == AliveMood.pointing);
    if (from != null) _pop.forward(from: 0);
    if (m == AliveMood.thinking || m == AliveMood.listening) {
      if (!_loop.isAnimating) _loop.repeat();
    } else {
      _loop.stop();
      _loop.value = 0;
    }
    _idle?.cancel();
    if (m == AliveMood.idle) _scheduleWave();
  }

  void _scheduleWave() {
    // Entre 25 et 55 secondes, puis il ne bouge plus.
    _idle = Timer(Duration(seconds: 25 + _rnd.nextInt(30)), () {
      if (!mounted || widget.mood != AliveMood.idle) return;
      _wave.forward(from: 0).whenComplete(() {
        if (mounted && widget.mood == AliveMood.idle) _scheduleWave();
      });
    });
  }

  @override
  void dispose() {
    _idle?.cancel();
    _pop.dispose();
    _loop.dispose();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pop, _loop, _wave]),
        child: widget.child,
        builder: (context, child) {
          final (sx, sy) = ClickyBounceMath.squash(_pop.value, hop: _hop);
          // Saut : monte puis redescend pendant le rebond.
          final lift = _hop ? -10 * math.sin(math.pi * _pop.value.clamp(0.0, 1.0)) : 0.0;
          // Coucou : il se penche à gauche et à droite.
          final tilt = math.sin(_wave.value * math.pi * 4) * (1 - _wave.value) * 0.35;
          final mood = widget.mood;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (mood == AliveMood.thinking)
                Positioned(
                  left: -9,
                  top: -9,
                  child: IgnorePointer(
                    child: CustomPaint(size: Size(s + 18, s + 18), painter: _HaloPainter(_loop.value, widget.color)),
                  ),
                ),
              if (mood == AliveMood.listening)
                for (final phase in const [0.0, 0.5])
                  Positioned(
                    left: -12,
                    top: -12,
                    child: IgnorePointer(
                      child: Builder(
                        builder: (_) {
                          final t = (_loop.value + phase) % 1;
                          return Opacity(
                            opacity: (1 - t) * 0.6,
                            child: Transform.scale(
                              scale: 0.6 + t * 0.9,
                              child: Container(
                                width: s + 24,
                                height: s + 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.redAccent, width: 2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              Transform.translate(
                offset: Offset(0, lift),
                child: Transform.rotate(
                  angle: tilt,
                  alignment: Alignment.topLeft,
                  child: Transform(
                    alignment: Alignment.bottomCenter,
                    transform: Matrix4.diagonal3Values(sx, sy, 1),
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Le halo qui tourne pendant que Smily réfléchit (un arc dégradé).
class _HaloPainter extends CustomPainter {
  _HaloPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = rect.deflate(2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0), color, const Color(0xFFE0457B)],
        stops: const [0, 0.6, 1],
        transform: GradientRotation(t * 2 * math.pi),
      ).createShader(rect);
    canvas.drawArc(ring, t * 2 * math.pi, math.pi * 1.4, false, paint);
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t || old.color != color;
}

/// Le calcul du rebond (testable).
class ClickyBounceMath {
  ClickyBounceMath._();

  /// Écrasé puis étiré (« squash & stretch »), qui revient à 1.
  static (double, double) squash(double t, {bool hop = false}) {
    if (t <= 0 || t >= 1) return (1, 1);
    final k = math.sin(t * math.pi * 2) * math.pow(1 - t, 1.6);
    final amp = hop ? 0.32 : 0.22;
    return (1 + amp * k, 1 - amp * k * 0.8);
  }
}
