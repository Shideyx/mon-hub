import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'life.dart';

/// Polices des émojis en couleur (Windows, Apple, Android/Linux).
const emojiFonts = ['Segoe UI Emoji', 'Apple Color Emoji', 'Noto Color Emoji'];

/// Le curseur de Nexo **qui vit** (il garde son look de curseur) :
/// * à côté de lui, l'émoji de ce qu'il ressent (😵‍💫, 🥰, 🤩…), qui
///   apparaît d'un petit rebond puis s'en va ;
/// * 💤 qui flotte doucement quand il dort (et lui, penché, un peu pâle) ;
/// * son « accessoire » (🧣 quand il fait froid, ☂️, 🎅, ☕ le matin…) ;
/// * il bouge en rythme quand ta musique joue, et tangue quand tu secoues
///   la souris.
///
/// Rien ne tourne en boucle sauf le 💤 pendant qu'il dort.
class ClickyLifeBody extends StatefulWidget {
  const ClickyLifeBody({super.key, required this.child, this.hud = false, this.life});

  final Widget child;

  /// Look « tête haute » (réacteur, plus grand) ou curseur classique.
  final bool hud;
  final ClickyLife? life;

  @override
  State<ClickyLifeBody> createState() => _ClickyLifeBodyState();
}

class _ClickyLifeBodyState extends State<ClickyLifeBody> with TickerProviderStateMixin {
  ClickyLife get life => widget.life ?? ClickyLife.instance;

  late final _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  late final _wob = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  late final _zzz = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  int _side = 1;

  @override
  void initState() {
    super.initState();
    life.beat.addListener(_onBeat);
    life.wobble.addListener(_onWobble);
    life.addListener(_onLife);
    _onLife();
  }

  @override
  void didUpdateWidget(ClickyLifeBody old) {
    super.didUpdateWidget(old);
    final was = old.life ?? ClickyLife.instance;
    if (was != life) {
      was.beat.removeListener(_onBeat);
      was.wobble.removeListener(_onWobble);
      was.removeListener(_onLife);
      life.beat.addListener(_onBeat);
      life.wobble.addListener(_onWobble);
      life.addListener(_onLife);
    }
  }

  void _onBeat() {
    _side = -_side;
    _bob.forward(from: 0);
  }

  void _onWobble() => _wob.forward(from: 0);

  void _onLife() {
    if (life.asleep && !_zzz.isAnimating) {
      _zzz.repeat();
    } else if (!life.asleep && _zzz.isAnimating) {
      _zzz.stop();
      _zzz.value = 0;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    life.beat.removeListener(_onBeat);
    life.wobble.removeListener(_onWobble);
    life.removeListener(_onLife);
    _bob.dispose();
    _wob.dispose();
    _zzz.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = life.shown;
    final acc = life.accessory;
    final asleep = life.asleep;
    final hud = widget.hud;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_bob, _wob]),
          child: AnimatedOpacity(
            opacity: asleep ? 0.75 : 1,
            duration: const Duration(milliseconds: 600),
            child: widget.child,
          ),
          builder: (context, child) {
            final (dy, tilt) = LifeMotion.at(bob: _bob.value, side: _side, wobble: _wob.value, asleep: asleep);
            return Transform.translate(
              offset: Offset(0, dy),
              child: Transform.rotate(angle: tilt, alignment: Alignment.topLeft, child: child),
            );
          },
        ),
        if (acc.isNotEmpty && !asleep)
          Positioned(
            left: hud ? 22 : 14,
            top: hud ? 22 : 17,
            child: Text(acc, style: const TextStyle(fontSize: 12, fontFamilyFallback: emojiFonts)),
          ),
        if (shown.isNotEmpty)
          Positioned(
            left: hud ? 28 : 21,
            top: hud ? -6 : -4,
            child: shown == '💤'
                ? AnimatedBuilder(
                    animation: _zzz,
                    builder: (context, _) {
                      final t = _zzz.value;
                      return Opacity(
                        opacity: (0.45 + 0.55 * math.sin(t * math.pi)).clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(2 * t, -5 * t),
                          child: const Text('💤', style: TextStyle(fontSize: 15, fontFamilyFallback: emojiFonts)),
                        ),
                      );
                    },
                  )
                : TweenAnimationBuilder<double>(
                    key: ValueKey(shown),
                    tween: Tween(begin: 0.2, end: 1),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.elasticOut,
                    builder: (context, s, child) =>
                        Transform.scale(scale: s, alignment: Alignment.bottomLeft, child: child),
                    child: Text(shown, style: const TextStyle(fontSize: 16, fontFamilyFallback: emojiFonts)),
                  ),
          ),
      ],
    );
  }
}

/// Le calcul des petits mouvements (testable).
class LifeMotion {
  LifeMotion._();

  /// (décalage vertical, inclinaison) : un petit saut sur chaque battement
  /// (penché d'un côté puis de l'autre), le tangage du tournis, et penché
  /// quand il dort.
  static (double, double) at({double bob = 0, int side = 1, double wobble = 0, bool asleep = false}) {
    final b = (bob <= 0 || bob >= 1) ? 0.0 : math.sin(math.pi * bob);
    final w = (wobble <= 0 || wobble >= 1) ? 0.0 : math.sin(wobble * math.pi * 6) * (1 - wobble) * 0.45;
    return (-4 * b, 0.14 * b * side + w + (asleep ? 0.45 : 0));
  }
}
