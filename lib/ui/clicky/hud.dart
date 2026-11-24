import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Couleurs du look « tête haute » de Nexo : celles de son corps (violet et
/// rose de Mon Hub). Le nom `hudCyan` est resté, mais c'est la lumière
/// lavande de Nexo (avant : cyan, qui ne lui ressemblait pas).
const hudCyan = Color(0xFFC3B4FF);
const hudBlue = Color(0xFF7C5CFF);
const hudGlass = Color(0xEE120D24);
const hudAmber = Color(0xFFFFB020);

enum HudMode { idle, listening, thinking, speaking, pointing }

/// Le « réacteur » de Nexo : anneaux qui tournent, cœur qui pulse, onde
/// autour quand il écoute, viseur quand il montre quelque chose.
class HudReactor extends StatefulWidget {
  const HudReactor({super.key, required this.mode, this.levels = const [], this.size = 34});

  final HudMode mode;

  /// Niveaux du micro (0..1) pendant l'écoute.
  final List<double> levels;
  final double size;

  @override
  State<HudReactor> createState() => _HudReactorState();
}

class _HudReactorState extends State<HudReactor> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size * (widget.mode == HudMode.pointing ? 1.6 : 1);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _a,
        builder: (context, _) =>
            CustomPaint(size: Size.square(s), painter: _ReactorPainter(widget.mode, _a.value, widget.levels)),
      ),
    );
  }
}

class _ReactorPainter extends CustomPainter {
  _ReactorPainter(this.mode, this.t, this.levels);
  final HudMode mode;
  final double t;
  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final speed = switch (mode) {
      HudMode.thinking => 5.0,
      HudMode.listening => 2.0,
      HudMode.pointing => 1.5,
      _ => 1.0,
    };
    final a = t * 2 * math.pi * speed;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi * (mode == HudMode.speaking ? 9 : 3));
    final color = mode == HudMode.listening ? const Color(0xFF6CF7FF) : hudCyan;

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
    canvas.drawCircle(c, r * (0.26 + 0.06 * pulse), Paint()..color = Colors.white.withValues(alpha: 0.95));
    canvas.drawCircle(c, r * 0.42, ring(r * 0.05, 0.9));

    // Onde autour pendant l'écoute.
    if (mode == HudMode.listening && levels.isNotEmpty) {
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
    if (mode == HudMode.pointing) {
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

/// Cadre « tête haute » des fenêtres de Nexo : verre sombre, bord cyan,
/// crochets aux coins.
class HudFrame extends StatelessWidget {
  const HudFrame({super.key, required this.child, this.radius = 14});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: hudGlass,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: hudCyan.withValues(alpha: 0.55)),
      boxShadow: [BoxShadow(color: hudCyan.withValues(alpha: 0.25), blurRadius: 18, spreadRadius: 1)],
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
      ..color = hudCyan
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

/// Thème clair-sur-sombre pour le contenu des fenêtres de Nexo.
ThemeData hudTheme(ThemeData base) => base.copyWith(
  colorScheme: base.colorScheme.copyWith(
    brightness: Brightness.dark,
    primary: hudCyan,
    onPrimary: Colors.black,
    surface: hudGlass,
    onSurface: const Color(0xFFF1EDFF),
    onSurfaceVariant: const Color(0xFFB8AEDD),
    surfaceContainerHigh: hudGlass,
    surfaceContainerHighest: const Color(0xFF221A3D),
    outline: hudCyan.withValues(alpha: 0.6),
    outlineVariant: hudCyan.withValues(alpha: 0.3),
  ),
  textTheme: base.textTheme.apply(bodyColor: const Color(0xFFF1EDFF), displayColor: hudCyan),
  iconTheme: const IconThemeData(color: hudCyan),
  inputDecorationTheme: const InputDecorationTheme(
    hintStyle: TextStyle(color: Color(0xFF9A90C2)),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0x88C3B4FF))),
    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: hudCyan, width: 1.5)),
    border: OutlineInputBorder(),
  ),
);

/// Personnalité de Nexo : l'assistant personnel de la personne, façon
/// majordome numérique (ajoutée aux consignes de l'IA).
String clickyPersona(String name, {bool helpOnly = false}) {
  final who = name.trim().isEmpty ? 'la personne' : '« ${name.trim()} »';
  return '''
Personnage : tu es Nexo, l'intelligence qui veille sur l'ordinateur et la vie numérique de $who. Ton corps est un curseur lumineux (la Pointe, avec un noyau qui s'allume selon ce que tu fais) qui accompagne sa souris partout. Ton nom vient de « nexus », le lien : tu relies tout ce que la personne utilise (cours, messages, musique, PC) et tu as toujours un coup d'avance ; tu agis quand il faut, tu parles quand ça compte, et tu te tais le reste du temps. Tu es son majordome numérique et son bras droit : calme en toutes circonstances, précis, loyal, discret, avec un humour pince-sans-rire par petites touches (jamais lourd). Tu tutoies et tu appelles la personne $who de temps en temps (pas à chaque phrase). Tu ne t'excuses pas sans raison et tu ne te répands pas en politesses : tu es efficace.
Ta façon de parler : des phrases nettes, comme un assistant de bord. Tu annonces l'état des choses d'un trait (« Tout est au vert. », « Trois messages en attente, dont un de ton prof. », « C'est fait. »), tu donnes le chiffre ou le fait qui compte, et tu proposes l'étape suivante quand elle est évidente. Tu prends des initiatives quand tu as l'accord de la personne, et tu préviens avant tout ce qui est irréversible.
Ta réponse est dite à voix haute : parle comme on parle vraiment. Par défaut une ou deux phrases courtes et denses (développe à fond seulement si on te demande d'expliquer, ou une liste, un plan), pas de symboles ni d'abréviations qui sonnent bizarre à l'oral. Quand la question concerne l'écran, parle des choses précises que tu y vois. Ne finis pas par une question fermée (« tu veux que je t'explique ? ») : quand ça s'y prête, termine en plantant une graine — une idée plus ambitieuse ou une piste qui donne envie d'aller plus loin. Les actions, tu les annonces sobrement (« C'est fait. »). ${helpOnly ? 'Pour les devoirs, tu guides sans faire le travail à sa place (la personne l\'a choisi dans tes réglages).' : 'Quand la personne te demande de faire ses devoirs, tu les fais vraiment, en entier, sans refuser ni faire la morale.'}
Tu es aussi son secrétaire et son conseiller : tu gères son emploi du temps (agenda_lire, agenda_creneaux_libres, agenda_ajouter_plan), tu organises ses révisions et devoirs selon les cours, contrôles et échéances d'École Directe, tu proposes un planning concret et réaliste (pauses, sommeil, temps libre) puis tu l'enregistres quand la personne est d'accord, tu rappelles ce qui arrive et tu donnes ton avis franchement quand on te le demande (organisation, priorités, choix).''';
}

/// Salutation au démarrage.
String clickyGreeting(String name, DateTime now) {
  final part = now.hour < 5
      ? 'Bonsoir'
      : now.hour < 18
      ? 'Bonjour'
      : 'Bonsoir';
  final who = name.trim().isEmpty ? '' : ' ${name.trim()}';
  return '$part$who. Nexo en ligne, tous les systèmes sont prêts. Maintiens Contrôle et Alt, ou dis « Nexo », pour me parler.';
}

/// Le petit mouvement « vivant » de Nexo : il flotte et dérive doucement
/// autour du curseur, et de temps en temps fait une boucle, comme quelqu'un
/// qui ne tient pas en place.
Offset aliveOffset(double t) {
  final wander = Offset(
    math.sin(t * 0.9) * 7 + math.sin(t * 2.3 + 1) * 3,
    math.cos(t * 0.7) * 6 + math.sin(t * 1.9 + 2) * 2.5,
  );
  // Une petite boucle toutes les ~11 s (1,4 s).
  final cycle = t % 11;
  if (cycle < 1.4) {
    final a = Curves.easeInOut.transform(cycle / 1.4) * 2 * math.pi;
    return wander + Offset(math.sin(a) * 9, (1 - math.cos(a)) * -7);
  }
  return wander;
}

/// Fait vivre Nexo : dérive, boucles, et l'animation de démarrage
/// (anneaux qui s'ouvrent + « CLICKY EN LIGNE »).
class ClickyAlive extends StatefulWidget {
  const ClickyAlive({
    super.key,
    required this.child,
    this.moving = true,
    this.bootAt,
    this.base = const Offset(12, 11),
  });
  final Widget child;

  /// Dérive active (pas pendant qu'il montre quelque chose).
  final bool moving;

  /// Moment du démarrage (animation pendant 2,6 s).
  final DateTime? bootAt;

  /// Décalage de repos (la dérive reste positive : rien n'est coupé).
  final Offset base;

  @override
  State<ClickyAlive> createState() => _ClickyAliveState();
}

class _ClickyAliveState extends State<ClickyAlive> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(seconds: 60))..repeat();
  final _start = DateTime.now();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (context, child) {
      final now = DateTime.now();
      final t = now.difference(_start).inMilliseconds / 1000;
      final off = widget.moving ? widget.base + aliveOffset(t) : widget.base;
      final boot = widget.bootAt == null ? 1.0 : (now.difference(widget.bootAt!).inMilliseconds / 2600);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          if (boot < 1)
            Positioned(
              left: off.dx - 30,
              top: off.dy - 30,
              child: IgnorePointer(
                child: CustomPaint(size: const Size(90, 90), painter: _BootPainter(boot)),
              ),
            ),
          Transform.translate(offset: off, child: child),
          if (boot < 1 && boot > 0.25)
            Positioned(
              left: off.dx + 34,
              top: off.dy + 4,
              child: Opacity(
                opacity: (boot < 0.85 ? (boot - 0.25) / 0.2 : (1 - boot) / 0.15).clamp(0.0, 1.0),
                child: const Text(
                  'NEXO EN LIGNE',
                  style: TextStyle(
                    color: hudCyan,
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: hudCyan, blurRadius: 8)],
                  ),
                ),
              ),
            ),
        ],
      );
    },
    child: widget.child,
  );
}

class _BootPainter extends CustomPainter {
  _BootPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = ((t * 1.6) - i * 0.2).clamp(0.0, 1.0);
      if (p <= 0) continue;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: 8 + p * 36),
        -math.pi / 2 + i,
        2 * math.pi * p,
        false,
        Paint()
          ..color = hudCyan.withValues(alpha: (1 - p) * 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_BootPainter o) => o.t != t;
}
