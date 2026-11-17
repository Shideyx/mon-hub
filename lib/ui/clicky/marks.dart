import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'holo.dart';

/// Annotations que Clicky dessine sur l'écran pendant qu'il explique, comme
/// un prof au tableau :
///
/// * `[ARROW:x1,y1->x2,y2]` : flèche animée d'un point à un autre ;
/// * `[CIRCLE:x,y,r:légende]` : cercle qui pulse, avec une légende ;
/// * `[UNDERLINE:x,y,largeur]` : trait sous un texte ;
/// * `[LABEL:x,y:texte]` : petite étiquette.
///
/// Coordonnées en pixels de la capture (`:screenN` à la fin pour un autre
/// écran). Elles s'effacent toutes seules après quelques secondes.
enum MarkKind { arrow, circle, underline, label }

class ClickyMark {
  const ClickyMark(this.kind, this.a, {this.b, this.size = 0, this.text = '', this.screen = 1});

  final MarkKind kind;

  /// Point de départ (flèche), centre (cercle), début (trait), position
  /// (étiquette).
  final Offset a;

  /// Arrivée de la flèche.
  final Offset? b;

  /// Rayon du cercle, largeur du trait.
  final double size;
  final String text;
  final int screen;

  /// Même annotation, ramenée dans un autre repère.
  ClickyMark map(Offset Function(Offset p) f, double scale) => ClickyMark(
    kind,
    f(a),
    b: b == null ? null : f(b!),
    size: size * scale,
    text: text,
    screen: screen,
  );

  Rect get bounds {
    switch (kind) {
      case MarkKind.arrow:
        return Rect.fromPoints(a, b ?? a).inflate(20);
      case MarkKind.circle:
        return Rect.fromCircle(
          center: a,
          radius: size + 14,
        ).expandToInclude(Rect.fromLTWH(a.dx - size, a.dy + size, math.max(140, size * 2), 36));
      case MarkKind.underline:
        return Rect.fromLTWH(a.dx, a.dy - 6, size, 14);
      case MarkKind.label:
        return Rect.fromLTWH(a.dx - 10, a.dy - 10, 40 + text.length * 9.0, 44);
    }
  }

  static final tagRe = RegExp(
    r'\[(ARROW|FLECHE|FLÈCHE|CIRCLE|CERCLE|UNDERLINE|SOULIGNE|SOULIGNER|LABEL|ETIQUETTE|ÉTIQUETTE)\s*:([^\]]*)\]',
    caseSensitive: false,
  );

  static final _num = r'(-?\d+(?:\.\d+)?)';

  /// Lit les annotations d'une réponse. Renvoie (texte sans balises,
  /// annotations en pixels de capture).
  static (String, List<ClickyMark>) extract(String raw) {
    final out = <ClickyMark>[];
    for (final m in tagRe.allMatches(raw)) {
      final kind = m.group(1)!.toUpperCase();
      var body = m.group(2)!.trim();
      var screen = 1;
      final s = RegExp(r':?\s*screen\s*(\d+)\s*$', caseSensitive: false).firstMatch(body);
      if (s != null) {
        screen = int.parse(s.group(1)!);
        body = body.substring(0, s.start).trim();
      }
      Offset? pt(String a, String b) {
        final x = double.tryParse(a), y = double.tryParse(b);
        return x == null || y == null ? null : Offset(x, y);
      }

      if (kind.startsWith('ARROW') || kind.startsWith('FL')) {
        final r = RegExp('^$_num\\s*,\\s*$_num\\s*(?:->|→|=>|;)\\s*$_num\\s*,\\s*$_num')
            .firstMatch(body);
        if (r == null) continue;
        final rest = body.substring(r.end).replaceFirst(RegExp(r'^\s*:'), '').trim();
        out.add(
          ClickyMark(
            MarkKind.arrow,
            pt(r[1]!, r[2]!)!,
            b: pt(r[3]!, r[4]!),
            text: rest,
            screen: screen,
          ),
        );
      } else if (kind.startsWith('CIRCLE') || kind.startsWith('CERCLE')) {
        final r = RegExp('^$_num\\s*,\\s*$_num\\s*,\\s*$_num').firstMatch(body);
        if (r == null) continue;
        final rest = body.substring(r.end).replaceFirst(RegExp(r'^\s*:'), '').trim();
        out.add(
          ClickyMark(
            MarkKind.circle,
            pt(r[1]!, r[2]!)!,
            size: double.parse(r[3]!).clamp(6, 600).toDouble(),
            text: rest,
            screen: screen,
          ),
        );
      } else if (kind.startsWith('UNDER') || kind.startsWith('SOUL')) {
        final r = RegExp('^$_num\\s*,\\s*$_num\\s*,\\s*$_num').firstMatch(body);
        if (r == null) continue;
        out.add(
          ClickyMark(
            MarkKind.underline,
            pt(r[1]!, r[2]!)!,
            size: double.parse(r[3]!).clamp(4, 3000).toDouble(),
            screen: screen,
          ),
        );
      } else {
        final r = RegExp('^$_num\\s*,\\s*$_num\\s*:\\s*(.+)\$').firstMatch(body);
        if (r == null) continue;
        out.add(ClickyMark(MarkKind.label, pt(r[1]!, r[2]!)!, text: r[3]!.trim(), screen: screen));
      }
    }
    return (raw.replaceAll(tagRe, '').replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim(), out);
  }
}

/// Séparateur des étapes d'une leçon (« dis suivant quand tu es prêt »).
final stepRe = RegExp(r'\[(?:ETAPE|ÉTAPE|STEP)\]', caseSensitive: false);

/// Découpe une réponse en étapes (une seule si pas de séparateur).
List<String> splitSteps(String raw) {
  final parts = [
    for (final p in raw.split(stepRe))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  return parts.isEmpty ? [raw.trim()] : parts;
}

/// Retire toutes les balises de Clicky (même à moitié écrites) du texte
/// affiché ou lu à voix haute pendant qu'il s'écrit.
String stripClickyTags(String t) => HoloScene.strip(t)
    .replaceAll(RegExp(r'\[POINT:\s*[^\]]*\]', caseSensitive: false), '')
    .replaceAll(ClickyMark.tagRe, '')
    .replaceAll(RegExp(r'\[ACTIONS\][\s\S]*?(\[/ACTIONS\]|$)', caseSensitive: false), '')
    .replaceAll(RegExp(r'\[AGIR\][\s\S]*?(\[/AGIR\]|$)', caseSensitive: false), '')
    .replaceAll(stepRe, '\n')
    .replaceFirst(RegExp(r'\[[^\]]*$'), '')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .trim();

/// Dessine les annotations (elles se tracent, puis s'effacent).
class ClickyMarksView extends StatefulWidget {
  const ClickyMarksView({
    super.key,
    required this.marks,
    required this.color,
    this.offset = Offset.zero,
    this.hold = const Duration(seconds: 4),
    this.onDone,
  });

  /// Annotations dans le repère de ce widget (avant [offset]).
  final List<ClickyMark> marks;
  final Color color;

  /// Décalage à soustraire (fenêtre de Clicky partout).
  final Offset offset;

  /// Temps d'affichage avant l'effacement.
  final Duration hold;
  final VoidCallback? onDone;

  @override
  State<ClickyMarksView> createState() => _ClickyMarksViewState();
}

class _ClickyMarksViewState extends State<ClickyMarksView> with TickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.hold, () async {
      if (!mounted) return;
      await _fade.forward();
      widget.onDone?.call();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _draw.dispose();
    _pulse.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: Listenable.merge([_draw, _pulse, _fade]),
      builder: (context, _) => Opacity(
        opacity: 1 - _fade.value,
        child: CustomPaint(
          size: Size.infinite,
          painter: _MarksPainter(
            widget.marks,
            widget.offset,
            widget.color,
            Curves.easeOutCubic.transform(_draw.value),
            _pulse.value,
          ),
        ),
      ),
    ),
  );
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.marks, this.offset, this.color, this.t, this.pulse);
  final List<ClickyMark> marks;
  final Offset offset;
  final Color color;
  final double t;
  final double pulse;

  void _label(Canvas canvas, Offset at, String text) {
    if (text.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
    )..layout(maxWidth: 260);
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(at.dx, at.dy, tp.width + 16, tp.height + 8),
      const Radius.circular(10),
    );
    canvas.drawShadow(Path()..addRRect(r), Colors.black, 3, false);
    canvas.drawRRect(r, Paint()..color = color);
    tp.paint(canvas, at + const Offset(8, 4));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final glow = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    for (final m in marks) {
      final a = m.a - offset;
      switch (m.kind) {
        case MarkKind.arrow:
          final b = (m.b ?? m.a) - offset;
          final end = Offset.lerp(a, b, t)!;
          canvas.drawLine(a, end, glow);
          canvas.drawLine(a, end, stroke);
          if (t > 0.6) {
            final dir = (b - a).direction;
            const head = 16.0;
            final p = Path()
              ..moveTo(end.dx, end.dy)
              ..lineTo(end.dx - head * math.cos(dir - 0.45), end.dy - head * math.sin(dir - 0.45))
              ..moveTo(end.dx, end.dy)
              ..lineTo(end.dx - head * math.cos(dir + 0.45), end.dy - head * math.sin(dir + 0.45));
            canvas.drawPath(p, stroke);
          }
          if (t >= 1) _label(canvas, a + const Offset(8, 8), m.text);
        case MarkKind.circle:
          final r = m.size * (0.92 + 0.12 * pulse);
          final rect = Rect.fromCircle(center: a, radius: r);
          canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * t, false, glow);
          canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * t, false, stroke);
          if (t >= 1) _label(canvas, a + Offset(-m.size, m.size + 8), m.text);
        case MarkKind.underline:
          final end = a + Offset(m.size * t, 0);
          canvas.drawLine(a, end, glow);
          canvas.drawLine(a, end, stroke);
        case MarkKind.label:
          if (t > 0.3) _label(canvas, a, m.text);
      }
    }
  }

  @override
  bool shouldRepaint(_MarksPainter o) => true;
}
