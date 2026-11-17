import 'dart:math' as math;
import 'dart:ui';

/// Le vol de Clicky (comme le vrai Clicky) : un arc, plus rapide pour les
/// petits sauts, plus ample pour les grands ; il s'oriente dans le sens du
/// vol et grossit un peu au milieu.
class ClickyFlight {
  ClickyFlight(this.from, this.to, this.start, {double dpr = 1})
    : duration = durationFor((to - from).distance / dpr),
      _control = controlFor(from, to, dpr);

  final Offset from;
  final Offset to;
  final DateTime start;
  final Duration duration;
  final Offset _control;

  /// Durée selon la distance (en points) : 0,26 s à 0,75 s.
  static Duration durationFor(double distance) =>
      Duration(milliseconds: (220 + distance * 0.42).clamp(260, 750).round());

  /// Point de contrôle : au-dessus du milieu, d'autant plus haut que le vol est long.
  static Offset controlFor(Offset a, Offset b, double dpr) {
    final mid = (a + b) / 2;
    final h = math.min((b - a).distance * 0.22, 90 * dpr);
    return Offset(mid.dx, mid.dy - h);
  }

  /// Avancement 0 → 1.
  double progress(DateTime now) => (now.difference(start).inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

  bool done(DateTime now) => progress(now) >= 1;

  /// Douce au départ et à l'arrivée (« smoothstep »).
  static double ease(double t) => t * t * (3 - 2 * t);

  Offset positionAt(double linear) {
    final t = ease(linear);
    final u = 1 - t;
    return from * (u * u) + _control * (2 * u * t) + to * (t * t);
  }

  /// Orientation (radians) : la pointe du curseur (en haut à gauche) suit le
  /// sens du vol.
  double angleAt(double linear) {
    final t = ease(linear);
    final u = 1 - t;
    final d = (_control - from) * (2 * u) + (to - _control) * (2 * t);
    if (d.distance < 0.01) return 0;
    // Au repos, la pointe regarde en haut à gauche (-135°).
    return math.atan2(d.dy, d.dx) + 3 * math.pi / 4;
  }

  /// Taille : jusqu'à 1,3 au milieu du vol.
  double scaleAt(double linear) => 1 + math.sin(linear * math.pi) * 0.3;
}

/// Suivre la souris avec un petit ressort : vif, mais vivant.
Offset springTowards(Offset current, Offset want, {double k = 0.38}) {
  final d = want - current;
  if (d.distance < 0.6) return want;
  return current + d * k;
}
