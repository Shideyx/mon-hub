import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Nombre « à la française » : 1 234 567.
String fmtInt(num n) {
  final s = n.round().abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '$b';
}

/// Nombre court : 1,2 k · 3,4 M · 1,1 Md.
String fmtShort(num n) {
  final a = n.abs();
  String f(double v, String u) =>
      '${(v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)).replaceAll('.', ',')} $u';
  if (a >= 1e9) return f(n / 1e9, 'Md');
  if (a >= 1e6) return f(n / 1e6, 'M');
  if (a >= 1e4) return f(n / 1e3, 'k');
  return fmtInt(n);
}

String _two(int v) => v.toString().padLeft(2, '0');
String fmtWhen(DateTime d, {bool withDay = true}) =>
    withDay ? '${_two(d.day)}/${_two(d.month)} ${_two(d.hour)}:${_two(d.minute)}' : '${_two(d.hour)}:${_two(d.minute)}';

/// Courbe d'une seule série, avec ligne de repère + bulle au survol / toucher.
class LineChart extends StatefulWidget {
  const LineChart({
    super.key,
    required this.points,
    required this.color,
    this.height = 180,
    this.format = fmtShort,
    this.zeroBased = true,
  });

  final List<(DateTime, double)> points;
  final Color color;
  final double height;
  final String Function(num) format;
  final bool zeroBased;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int? hover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant);
    final pts = widget.points;
    if (pts.length < 2) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            'Pas encore assez de relevés.\nL\'historique se construit tant que Mon Hub est ouvert.',
            textAlign: TextAlign.center,
            style: text,
          ),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final geo = _Geo(pts, box.maxWidth, widget.height, widget.zeroBased);
          void pick(Offset p) {
            final i = geo.nearest(p.dx);
            if (i != hover) setState(() => hover = i);
          }

          return MouseRegion(
            onHover: (e) => pick(e.localPosition),
            onExit: (_) => setState(() => hover = null),
            child: GestureDetector(
              onPanDown: (d) => pick(d.localPosition),
              onPanUpdate: (d) => pick(d.localPosition),
              onPanEnd: (_) => setState(() => hover = null),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CustomPaint(
                    size: Size(box.maxWidth, widget.height),
                    painter: _LinePainter(
                      geo: geo,
                      color: widget.color,
                      grid: scheme.outlineVariant.withValues(alpha: 0.5),
                      surface: scheme.surface,
                      hover: hover,
                      label: text,
                      format: widget.format,
                    ),
                  ),
                  if (hover != null) _tooltip(context, geo, hover!, box.maxWidth),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tooltip(BuildContext context, _Geo geo, int i, double width) {
    final scheme = Theme.of(context).colorScheme;
    final (t, v) = widget.points[i];
    final p = geo.at(i);
    const w = 132.0;
    final left = (p.dx + 12 + w > width) ? p.dx - 12 - w : p.dx + 12;
    return Positioned(
      left: left.clamp(0, math.max(0, width - w)),
      top: 4,
      child: IgnorePointer(
        child: Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmtWhen(t), style: TextStyle(color: scheme.onInverseSurface, fontSize: 11)),
              Text(
                fmtInt(v),
                style: TextStyle(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Geo {
  _Geo(this.pts, this.w, this.h, bool zero) {
    t0 = pts.first.$1.millisecondsSinceEpoch.toDouble();
    t1 = math.max(t0 + 1, pts.last.$1.millisecondsSinceEpoch.toDouble());
    var lo = pts.map((p) => p.$2).reduce(math.min);
    var hi = pts.map((p) => p.$2).reduce(math.max);
    if (zero) lo = math.min(0, lo);
    if (hi == lo) hi = lo + 1;
    // Marge en haut pour que la courbe ne touche pas le bord.
    hi += (hi - lo) * 0.08;
    v0 = lo;
    v1 = hi;
  }

  final List<(DateTime, double)> pts;
  final double w, h;
  static const left = 44.0, bottom = 18.0, top = 6.0;
  late final double t0, t1, v0, v1;

  double x(DateTime t) => left + (t.millisecondsSinceEpoch - t0) / (t1 - t0) * (w - left - 4);
  double y(double v) => top + (1 - (v - v0) / (v1 - v0)) * (h - top - bottom);
  Offset at(int i) => Offset(x(pts[i].$1), y(pts[i].$2));

  int nearest(double px) {
    var best = 0;
    var d = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final dd = (x(pts[i].$1) - px).abs();
      if (dd < d) {
        d = dd;
        best = i;
      }
    }
    return best;
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.geo,
    required this.color,
    required this.grid,
    required this.surface,
    required this.hover,
    required this.label,
    required this.format,
  });

  final _Geo geo;
  final Color color, grid, surface;
  final int? hover;
  final TextStyle label;
  final String Function(num) format;

  void _text(Canvas c, String s, Offset o, {bool right = false}) {
    final tp = TextPainter(text: TextSpan(text: s, style: label), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, right ? o - Offset(tp.width, tp.height / 2) : o);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geo;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // 3 lignes de repère discrètes + valeurs à gauche.
    for (var k = 0; k <= 2; k++) {
      final v = g.v0 + (g.v1 - g.v0) * k / 2;
      final yy = g.y(v);
      canvas.drawLine(Offset(_Geo.left, yy), Offset(size.width - 4, yy), gridPaint);
      _text(canvas, format(v), Offset(_Geo.left - 6, yy), right: true);
    }
    final first = g.pts.first.$1, last = g.pts.last.$1;
    final sameDay = last.difference(first).inHours < 24;
    _text(canvas, fmtWhen(first, withDay: !sameDay), Offset(_Geo.left, size.height - 14));
    final endLabel = fmtWhen(last, withDay: !sameDay);
    final tp = TextPainter(text: TextSpan(text: endLabel, style: label), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(size.width - 4 - tp.width, size.height - 14));

    final path = Path();
    for (var i = 0; i < g.pts.length; i++) {
      final p = g.at(i);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final area = Path.from(path)
      ..lineTo(g.at(g.pts.length - 1).dx, g.y(g.v0))
      ..lineTo(g.at(0).dx, g.y(g.v0))
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (hover != null) {
      final p = g.at(hover!);
      canvas.drawLine(
        Offset(p.dx, _Geo.top),
        Offset(p.dx, size.height - _Geo.bottom),
        Paint()
          ..color = grid
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, 6, Paint()..color = surface);
      canvas.drawCircle(p, 4.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter o) => o.hover != hover || o.geo != geo || o.color != color;
}

/// Barres verticales (une série), bulle au survol.
class BarChart extends StatefulWidget {
  const BarChart({super.key, required this.bars, required this.color, this.height = 160});
  final List<(String, double)> bars;
  final Color color;
  final double height;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? hover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = Theme.of(context).textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant);
    final bars = widget.bars;
    if (bars.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(child: Text('Pas encore de données', style: label)),
      );
    }
    final hi = math.max(1.0, bars.map((b) => b.$2).reduce(math.max));
    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < bars.length; i++)
                  Expanded(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => hover = i),
                      onExit: (_) => setState(() => hover = null),
                      child: GestureDetector(
                        onTapDown: (_) => setState(() => hover = i),
                        child: Tooltip(
                          message: '${bars[i].$1} : ${fmtInt(bars[i].$2)}',
                          child: Container(
                            color: Colors.transparent,
                            alignment: Alignment.bottomCenter,
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: FractionallySizedBox(
                              heightFactor: (bars[i].$2 / hi).clamp(0.0, 1.0).toDouble(),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: hover == null || hover == i
                                      ? widget.color
                                      : widget.color.withValues(alpha: 0.45),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: scheme.outlineVariant),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(bars.first.$1, style: label),
              if (hover != null)
                Text('${bars[hover!].$1} · ${fmtInt(bars[hover!].$2)}',
                    style: label.copyWith(fontWeight: FontWeight.w700)),
              Text(bars.last.$1, style: label),
            ],
          ),
        ],
      ),
    );
  }
}
