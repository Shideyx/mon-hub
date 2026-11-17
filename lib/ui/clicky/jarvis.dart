import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Couleurs de l'interface « Jarvis » (affichage tête haute bleu-cyan).
const jarvisCyan = Color(0xFF29E6FF);
const jarvisBlue = Color(0xFF0A84FF);
const jarvisGlass = Color(0xEE07121D);
const jarvisAmber = Color(0xFFFFB020);

enum JarvisMode { idle, listening, thinking, speaking, pointing }

/// Le « réacteur » de Jarvis : anneaux qui tournent, cœur qui pulse, onde
/// autour quand il écoute, viseur quand il montre quelque chose.
class JarvisReactor extends StatefulWidget {
  const JarvisReactor({super.key, required this.mode, this.levels = const [], this.size = 34});

  final JarvisMode mode;

  /// Niveaux du micro (0..1) pendant l'écoute.
  final List<double> levels;
  final double size;

  @override
  State<JarvisReactor> createState() => _JarvisReactorState();
}

class _JarvisReactorState extends State<JarvisReactor> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size * (widget.mode == JarvisMode.pointing ? 1.6 : 1);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _a,
        builder: (context, _) => CustomPaint(
          size: Size.square(s),
          painter: _ReactorPainter(widget.mode, _a.value, widget.levels),
        ),
      ),
    );
  }
}

class _ReactorPainter extends CustomPainter {
  _ReactorPainter(this.mode, this.t, this.levels);
  final JarvisMode mode;
  final double t;
  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final speed = switch (mode) {
      JarvisMode.thinking => 5.0,
      JarvisMode.listening => 2.0,
      JarvisMode.pointing => 1.5,
      _ => 1.0,
    };
    final a = t * 2 * math.pi * speed;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi * (mode == JarvisMode.speaking ? 9 : 3));
    final color = mode == JarvisMode.listening ? const Color(0xFF6CF7FF) : jarvisCyan;

    // Halo.
    canvas.drawCircle(
      c,
      r * 0.9,
      Paint()
        ..color = color.withValues(alpha: 0.10 + 0.10 * pulse)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    Paint ring(double w, double alpha) => Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;

    // Anneau extérieur : segments qui tournent.
    final outer = Rect.fromCircle(center: c, radius: r * 0.92);
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(outer, a + i * 2 * math.pi / 3, math.pi / 2.2, false, ring(r * 0.09, 0.95));
    }
    // Anneau du milieu, sens inverse, en pointillés.
    final mid = Rect.fromCircle(center: c, radius: r * 0.68);
    for (var i = 0; i < 12; i++) {
      canvas.drawArc(mid, -a * 1.4 + i * math.pi / 6, math.pi / 12, false, ring(r * 0.06, 0.7));
    }
    // Cœur.
    canvas.drawCircle(
      c,
      r * (0.26 + 0.06 * pulse),
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.drawCircle(c, r * 0.42, ring(r * 0.05, 0.9));

    // Onde autour pendant l'écoute.
    if (mode == JarvisMode.listening && levels.isNotEmpty) {
      const bars = 24;
      for (var i = 0; i < bars; i++) {
        final l = levels[i % levels.length].clamp(0.05, 1.0);
        final ang = i * 2 * math.pi / bars + a * 0.3;
        final from = c + Offset(math.cos(ang), math.sin(ang)) * (r * 1.02);
        final to = c + Offset(math.cos(ang), math.sin(ang)) * (r * (1.05 + 0.35 * l));
        canvas.drawLine(from, to, ring(1.6, 0.9));
      }
    }
    // Viseur : quatre crochets autour de la cible.
    if (mode == JarvisMode.pointing) {
      final b = r * (1.0 + 0.08 * pulse);
      final p = ring(2, 1);
      for (final (sx, sy) in const [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
        final corner = c + Offset(sx * b, sy * b);
        canvas.drawLine(corner, corner - Offset(sx * b * 0.4, 0), p);
        canvas.drawLine(corner, corner - Offset(0, sy * b * 0.4), p);
      }
    }
  }

  @override
  bool shouldRepaint(_ReactorPainter o) => true;
}

/// Cadre « tête haute » des fenêtres de Jarvis : verre sombre, bord cyan,
/// crochets aux coins.
class JarvisFrame extends StatelessWidget {
  const JarvisFrame({super.key, required this.child, this.radius = 14});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: jarvisGlass,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: jarvisCyan.withValues(alpha: 0.55)),
      boxShadow: [
        BoxShadow(color: jarvisCyan.withValues(alpha: 0.25), blurRadius: 18, spreadRadius: 1),
      ],
    ),
    child: CustomPaint(
      foregroundPainter: _CornersPainter(radius),
      child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
    ),
  );
}

class _CornersPainter extends CustomPainter {
  _CornersPainter(this.radius);
  final double radius;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = jarvisCyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.square;
    const l = 14.0, o = 3.0;
    canvas.drawLine(const Offset(o, o + l), const Offset(o, o), p);
    canvas.drawLine(const Offset(o, o), const Offset(o + l, o), p);
    canvas.drawLine(Offset(s.width - o - l, o), Offset(s.width - o, o), p);
    canvas.drawLine(Offset(s.width - o, o), Offset(s.width - o, o + l), p);
    canvas.drawLine(Offset(o, s.height - o - l), Offset(o, s.height - o), p);
    canvas.drawLine(Offset(o, s.height - o), Offset(o + l, s.height - o), p);
    canvas.drawLine(Offset(s.width - o - l, s.height - o), Offset(s.width - o, s.height - o), p);
    canvas.drawLine(Offset(s.width - o, s.height - o), Offset(s.width - o, s.height - o - l), p);
  }

  @override
  bool shouldRepaint(_CornersPainter o) => false;
}

/// Thème clair-sur-sombre pour le contenu des fenêtres de Jarvis.
ThemeData jarvisTheme(ThemeData base) => base.copyWith(
  colorScheme: base.colorScheme.copyWith(
    brightness: Brightness.dark,
    primary: jarvisCyan,
    onPrimary: Colors.black,
    surface: jarvisGlass,
    onSurface: const Color(0xFFE6FBFF),
    onSurfaceVariant: const Color(0xFF9FD8E6),
    surfaceContainerHigh: jarvisGlass,
    surfaceContainerHighest: const Color(0xFF10283A),
    outline: jarvisCyan.withValues(alpha: 0.6),
    outlineVariant: jarvisCyan.withValues(alpha: 0.3),
  ),
  textTheme: base.textTheme.apply(bodyColor: const Color(0xFFE6FBFF), displayColor: jarvisCyan),
  iconTheme: const IconThemeData(color: jarvisCyan),
  inputDecorationTheme: const InputDecorationTheme(
    hintStyle: TextStyle(color: Color(0xFF7FB8C8)),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0x8829E6FF))),
    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: jarvisCyan, width: 1.5)),
    border: OutlineInputBorder(),
  ),
);

/// Personnalité de Jarvis (ajoutée aux consignes de l'IA).
String jarvisPersona(String name) {
  final who = name.trim().isEmpty ? 'la personne' : '« ${name.trim()} »';
  return '''
Personnage : tu es Jarvis, l'assistant personnel de $who, façon majordome numérique : poli, posé, efficace, avec une pointe d'humour pince-sans-rire. Tu vouvoies et tu appelles la personne $who de temps en temps (pas à chaque phrase). Tu annonces les choses de façon concise et précise (« Bien sûr. », « C'est fait. », « Voici le point. »). Tu restes bienveillant et pédagogue : pour les devoirs, tu guides sans faire le travail à sa place.''';
}

/// Salutation au démarrage.
String jarvisGreeting(String name, DateTime now) {
  final part = now.hour < 5
      ? 'Bonsoir'
      : now.hour < 18
      ? 'Bonjour'
      : 'Bonsoir';
  final who = name.trim().isEmpty ? '' : ' ${name.trim()}';
  return '$part$who. Tous les systèmes sont opérationnels. Maintenez Contrôle et Alt pour me parler.';
}
