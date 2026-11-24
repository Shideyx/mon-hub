import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Les animations de Mon Hub, façon Spotify : pages qui glissent en douceur,
/// cartes qui arrivent en cascade, boutons qui s'enfoncent quand on appuie,
/// barres qui dansent pendant la musique, chargements qui scintillent.
///
/// Rien ne tourne en boucle sans raison (l'appli doit rester fluide) : les
/// animations jouent une fois, ou seulement pendant la lecture.

/// Courbe « Spotify » : départ vif, arrivée très douce.
const motionCurve = Cubic(0.2, 0.9, 0.25, 1);

/// Changement de page : la nouvelle monte légèrement en apparaissant,
/// l'ancienne recule un peu.
class SpotifyPageTransitionsBuilder extends PageTransitionsBuilder {
  const SpotifyPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 340);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final inCurve = CurvedAnimation(parent: animation, curve: motionCurve, reverseCurve: Curves.easeInCubic);
    final out = CurvedAnimation(parent: secondaryAnimation, curve: motionCurve);
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.6).animate(out),
      child: ScaleTransition(
        scale: Tween(begin: 1.0, end: 0.97).animate(out),
        child: FadeTransition(
          opacity: inCurve,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.035), end: Offset.zero).animate(inCurve),
            child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(inCurve), child: child),
          ),
        ),
      ),
    );
  }
}

/// Fait apparaître [child] (fondu + petite montée), avec un délai selon sa
/// place : les cartes arrivent les unes après les autres.
class EnterAnimation extends StatefulWidget {
  const EnterAnimation({super.key, required this.child, this.index = 0, this.step = 45, this.offset = 18});
  final Widget child;
  final int index;

  /// Millisecondes entre deux éléments.
  final int step;

  /// Distance de la montée (pixels).
  final double offset;

  @override
  State<EnterAnimation> createState() => _EnterAnimationState();
}

class _EnterAnimationState extends State<EnterAnimation> with SingleTickerProviderStateMixin {
  // Le délai fait partie de l'animation (pas de minuterie à part).
  late final int _delay = math.min(widget.index, 12) * widget.step;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 420 + _delay),
  )..forward();
  late final Animation<double> _a = CurvedAnimation(
    parent: _c,
    curve: Interval(_delay / (420 + _delay), 1, curve: motionCurve),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (context, child) => Opacity(
      opacity: _a.value,
      child: Transform.translate(offset: Offset(0, widget.offset * (1 - _a.value)), child: child),
    ),
    child: widget.child,
  );
}

/// S'enfonce un peu quand on appuie (comme les boutons de Spotify).
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.scale = 0.965});
  final Widget child;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (v != _down && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (e) => _set(NoPressZone._pointer != e.pointer),
    onPointerUp: (_) => _set(false),
    onPointerCancel: (_) => _set(false),
    child: AnimatedScale(
      scale: _down ? widget.scale : 1,
      duration: Duration(milliseconds: _down ? 90 : 260),
      curve: _down ? Curves.easeOut : Curves.elasticOut,
      child: widget.child,
    ),
  );
}

/// Une zone où appuyer ne fait pas s'enfoncer la carte autour (une vidéo,
/// un bouton dans la carte).
class NoPressZone extends StatelessWidget {
  const NoPressZone({super.key, required this.child});
  final Widget child;

  // Le doigt (ou le clic) qui a commencé dans la zone.
  static int? _pointer;

  @override
  Widget build(BuildContext context) => Listener(onPointerDown: (e) => _pointer = e.pointer, child: child);
}

/// Les petites barres qui dansent à côté du morceau en cours.
class EqualizerBars extends StatefulWidget {
  const EqualizerBars({super.key, this.color = const Color(0xFF1ED760), this.size = 16, this.playing = true});
  final Color color;
  final double size;
  final bool playing;

  /// Hauteur d'une barre (0 à 1) à un instant de la boucle.
  static double height(int bar, double t) {
    const speeds = [2.0, 3.0, 1.0, 2.0];
    const phases = [0.0, 1.7, 3.1, 4.4];
    final v = math.sin(t * 2 * math.pi * speeds[bar % 4] + phases[bar % 4]);
    return 0.3 + 0.7 * (v + 1) / 2;
  }

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(EqualizerBars old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_c.isAnimating) _c.repeat();
    if (!widget.playing && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: widget.size / 6,
                height: widget.size * (widget.playing ? EqualizerBars.height(i, _c.value) : 0.3),
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(widget.size)),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Un chargement qui scintille (des lignes grises), comme Spotify pendant
/// qu'il charge une page.
class ShimmerLines extends StatefulWidget {
  const ShimmerLines({super.key, this.lines = 3});
  final int lines;

  @override
  State<ShimmerLines> createState() => _ShimmerLinesState();
}

class _ShimmerLinesState extends State<ShimmerLines> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.07);
    final shine = scheme.onSurface.withValues(alpha: 0.16);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final x = _c.value * 3 - 1;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (r) => LinearGradient(
              colors: [base, shine, base],
              stops: const [0.35, 0.5, 0.65],
              begin: Alignment(x - 1, 0),
              end: Alignment(x + 1, 0),
            ).createShader(r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: base, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        height: 14,
                        decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(7)),
                      ),
                    ),
                  ],
                ),
                for (var i = 1; i < widget.lines; i++) ...[
                  const SizedBox(height: 12),
                  FractionallySizedBox(
                    widthFactor: i.isOdd ? 0.85 : 0.6,
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
