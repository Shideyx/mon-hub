import 'dart:math' as math;
import 'dart:typed_data' show Float32List;
import 'dart:ui' show PointMode, lerpDouble;

import 'package:material_ui/material_ui.dart';

/// Les couleurs de l'interface « HUD » de Mon Hub (violet + rose sur fond
/// sombre, ou version claire).
@immutable
class HudColors {
  const HudColors({
    required this.bg,
    required this.side,
    required this.panel,
    required this.panelLow,
    required this.line,
    required this.bracket,
    required this.text,
    required this.muted,
    required this.dim,
    required this.accent,
    required this.accentText,
    required this.pink,
    required this.hotBg,
    required this.hotLine,
    required this.chip,
    required this.selected,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.dot,
  });

  final Color bg;
  final Color side;
  final Color panel;
  final Color panelLow;
  final Color line;
  final Color bracket;
  final Color text;
  final Color muted;
  final Color dim;
  final Color accent;

  /// Texte violet lisible sur le fond (liens, étiquettes).
  final Color accentText;
  final Color pink;
  final Color hotBg;
  final Color hotLine;
  final Color chip;
  final Color selected;
  final Color ok;
  final Color warn;
  final Color bad;

  /// Points de la grille du fond.
  final Color dot;

  static const dark = HudColors(
    bg: Color(0xFF0B0C12),
    side: Color(0xFF0F1017),
    panel: Color(0xFF13141C),
    panelLow: Color(0xFF101119),
    line: Color(0xFF2B2E42),
    bracket: Color(0xFF4A4E6A),
    text: Color(0xFFF2F2F7),
    muted: Color(0xFF9EA1B3),
    dim: Color(0xFF8A8DA0),
    accent: Color(0xFF7C5CFF),
    accentText: Color(0xFFB9A8FF),
    pink: Color(0xFFE0457B),
    hotBg: Color(0xFF161328),
    hotLine: Color(0xFF4B3A8F),
    chip: Color(0xFF1F2131),
    selected: Color(0xFF1C1834),
    ok: Color(0xFF86EFC9),
    warn: Color(0xFFFCD38D),
    bad: Color(0xFFFCA5B5),
    dot: Color(0x0FFFFFFF),
  );

  static const light = HudColors(
    bg: Color(0xFFF3F2F8),
    side: Color(0xFFFFFFFF),
    panel: Color(0xFFFFFFFF),
    panelLow: Color(0xFFF8F7FC),
    line: Color(0xFFD9D6E8),
    bracket: Color(0xFFB5AFD6),
    text: Color(0xFF17151F),
    muted: Color(0xFF5D5B6E),
    dim: Color(0xFF6E6B80),
    accent: Color(0xFF6D4AFF),
    accentText: Color(0xFF5B39E6),
    pink: Color(0xFFD13A70),
    hotBg: Color(0xFFF0ECFF),
    hotLine: Color(0xFFB9A8FF),
    chip: Color(0xFFECEAF5),
    selected: Color(0xFFEDE8FF),
    ok: Color(0xFF0F8A5F),
    warn: Color(0xFFA86500),
    bad: Color(0xFFC2264F),
    dot: Color(0x14000000),
  );

  static HudColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Polices de l'interface.
class HudFonts {
  HudFonts._();

  /// Titres et boutons.
  static const display = 'ChakraPetch';

  /// Étiquettes, heures, codes.
  static const mono = 'JetBrainsMono';
}

/// Petite étiquette technique (« [01] MAINTENANT »).
TextStyle hudLabel(BuildContext context, {Color? color, double size = 11, FontWeight weight = FontWeight.w600}) =>
    TextStyle(
      fontFamily: HudFonts.mono,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: size * 0.14,
      color: color ?? HudColors.of(context).muted,
      height: 1.3,
    );

/// Titre en police « HUD ».
TextStyle hudTitle(BuildContext context, {double size = 28, Color? color, FontWeight weight = FontWeight.w700}) =>
    TextStyle(
      fontFamily: HudFonts.display,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: size * 0.02,
      height: 1.05,
      color: color ?? HudColors.of(context).text,
    );

/// Texte en police à chasse fixe (heures, chiffres).
TextStyle hudMono(BuildContext context, {double size = 13, Color? color, FontWeight weight = FontWeight.w400}) =>
    TextStyle(
      fontFamily: HudFonts.mono,
      fontSize: size,
      fontWeight: weight,
      color: color ?? HudColors.of(context).text,
    );

/// Forme à coins coupés (en haut à droite et en bas à gauche).
BeveledRectangleBorder hudCut(double cut, {BorderSide side = BorderSide.none}) => BeveledRectangleBorder(
  borderRadius: BorderRadius.only(topRight: Radius.circular(cut), bottomLeft: Radius.circular(cut)),
  side: side,
);

/// Parallélogramme (boutons, étiquettes) : les côtés gauche et droit penchent.
class SlantBorder extends OutlinedBorder {
  const SlantBorder({this.slant = 9, super.side});

  final double slant;

  Path _path(Rect r, double inset) {
    final s = math.min(slant, r.width / 4);
    final a = Rect.fromLTRB(r.left + inset, r.top + inset, r.right - inset, r.bottom - inset);
    return Path()
      ..moveTo(a.left + s, a.top)
      ..lineTo(a.right, a.top)
      ..lineTo(a.right - s, a.bottom)
      ..lineTo(a.left, a.bottom)
      ..close();
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _path(rect, side.strokeInset);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect, 0);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawPath(_path(rect, side.width / 2), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) => SlantBorder(slant: slant * t, side: side.scale(t));

  @override
  SlantBorder copyWith({BorderSide? side, double? slant}) =>
      SlantBorder(slant: slant ?? this.slant, side: side ?? this.side);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is SlantBorder) {
      return SlantBorder(slant: lerpDouble(a.slant, slant, t)!, side: BorderSide.lerp(a.side, side, t));
    }
    return super.lerpFrom(a, t);
  }

  @override
  bool operator ==(Object other) => other is SlantBorder && other.slant == slant && other.side == side;

  @override
  int get hashCode => Object.hash(slant, side);
}

/// Un bloc de l'interface : coins coupés, fin contour et petits crochets
/// lumineux aux coins.
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.hot = false,
    this.padding = const EdgeInsets.all(16),
    this.cut = 14,
    this.color,
    this.lineColor,
    this.bracketColor,
    this.onTap,
    this.onLongPress,
    this.brackets = true,
  });

  final Widget child;

  /// Bloc mis en avant (violet).
  final bool hot;
  final EdgeInsetsGeometry padding;
  final double cut;
  final Color? color;
  final Color? lineColor;
  final Color? bracketColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool brackets;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final shape = hudCut(cut, side: BorderSide(color: lineColor ?? (hot ? c.hotLine : c.line)));
    Widget body = Padding(padding: padding, child: child);
    if (onTap != null || onLongPress != null) {
      body = InkWell(customBorder: shape, onTap: onTap, onLongPress: onLongPress, child: body);
    }
    return Material(
      shape: shape,
      color: color ?? (hot ? c.hotBg : c.panel),
      clipBehavior: Clip.antiAlias,
      child: brackets
          ? CustomPaint(foregroundPainter: _Brackets(bracketColor ?? (hot ? c.accent : c.bracket)), child: body)
          : body,
    );
  }
}

class _Brackets extends CustomPainter {
  _Brackets(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const l = 12.0;
    canvas.drawPath(
      Path()
        ..moveTo(1, l)
        ..lineTo(1, 1)
        ..lineTo(l, 1),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width - 1, size.height - l)
        ..lineTo(size.width - 1, size.height - 1)
        ..lineTo(size.width - l, size.height - 1),
      p,
    );
  }

  @override
  bool shouldRepaint(_Brackets old) => old.color != color;
}

/// Bouton penché (parallélogramme), en majuscules.
class HudButton extends StatelessWidget {
  const HudButton({
    super.key,
    this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.danger = false,
    this.tooltip,
    this.compact = false,
    this.color,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final String? tooltip;
  final bool compact;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final bg = color ?? (danger ? c.pink : (primary ? c.accent : c.chip));
    final fg = primary || danger || color != null ? Colors.white : c.text;
    final enabled = onPressed != null;
    const shape = SlantBorder(slant: 10);
    Widget b = Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 36 : 44, minWidth: compact ? 36 : 44),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: label == null ? 14 : (compact ? 14 : 20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) Icon(icon, size: compact ? 16 : 18, color: fg),
                  if (icon != null && label != null) const SizedBox(width: 8),
                  if (label != null)
                    Text(
                      label!.toUpperCase(),
                      style: TextStyle(
                        fontFamily: HudFonts.display,
                        fontWeight: FontWeight.w600,
                        fontSize: compact ? 12 : 13,
                        letterSpacing: 1,
                        color: fg,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return Semantics(button: true, label: label ?? tooltip, child: b);
  }
}

/// Petite étiquette penchée (matière, statut…).
class HudTag extends StatelessWidget {
  const HudTag(this.text, {super.key, this.color, this.textColor});
  final String text;
  final Color? color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
      decoration: ShapeDecoration(color: color ?? c.chip, shape: const SlantBorder(slant: 6)),
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: hudLabel(context, size: 10, color: textColor ?? c.text).copyWith(letterSpacing: 0.8),
      ),
    );
  }
}

/// Avatar en hexagone (initiale + couleur).
class HexAvatar extends StatelessWidget {
  const HexAvatar(this.text, {super.key, this.color, this.size = 32, this.child});
  final String text;
  final Color? color;
  final double size;
  final Widget? child;

  /// Une couleur stable pour un nom.
  static Color colorFor(String seed) {
    const colors = [
      Color(0xFF3B6FD9),
      Color(0xFFC2410C),
      Color(0xFF0E7490),
      Color(0xFF6D4AFF),
      Color(0xFFB4236A),
      Color(0xFF15803D),
      Color(0xFF7E22CE),
      Color(0xFFB45309),
    ];
    var h = 0;
    for (final u in seed.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return colors[h % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: const HexClipper(),
      child: Container(
        width: size,
        height: size,
        color: color ?? colorFor(text),
        alignment: Alignment.center,
        child:
            child ??
            Text(
              text,
              maxLines: 1,
              style: TextStyle(
                fontFamily: HudFonts.display,
                fontWeight: FontWeight.w700,
                fontSize: size * (text.length > 2 ? 0.28 : 0.36),
                color: Colors.white,
              ),
            ),
      ),
    );
  }
}

class HexClipper extends CustomClipper<Path> {
  const HexClipper();

  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width * .25, 0)
    ..lineTo(s.width * .75, 0)
    ..lineTo(s.width, s.height / 2)
    ..lineTo(s.width * .75, s.height)
    ..lineTo(s.width * .25, s.height)
    ..lineTo(0, s.height / 2)
    ..close();

  @override
  bool shouldReclip(HexClipper oldClipper) => false;
}

/// Losange de couleur (espaces).
class HudDiamond extends StatelessWidget {
  const HudDiamond(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: math.pi / 4,
    child: SizedBox(
      width: size,
      height: size,
      child: ColoredBox(color: color),
    ),
  );
}

/// Rayures en biais.
class Hatch extends StatelessWidget {
  const Hatch({super.key, this.width, this.height = 8, this.color, this.opacity = 1});
  final double? width;
  final double height;
  final Color? color;
  final double opacity;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: CustomPaint(painter: _HatchPainter((color ?? HudColors.of(context).accent).withValues(alpha: opacity))),
  );
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final p = Paint()
      ..color = color
      ..strokeWidth = 3.5;
    for (var x = -size.height; x < size.width + size.height; x += 10) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

/// Barre de progression en segments.
class SegBar extends StatelessWidget {
  const SegBar(this.value, {super.key, this.height = 8, this.color});
  final double value;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SegPainter(value.clamp(0, 1).toDouble(), color ?? c.accent, c.line)),
    );
  }
}

class _SegPainter extends CustomPainter {
  _SegPainter(this.value, this.on, this.off);
  final double value;
  final Color on;
  final Color off;

  @override
  void paint(Canvas canvas, Size size) {
    const seg = 8.0, gap = 3.0;
    final filled = size.width * value;
    for (var x = 0.0; x < size.width; x += seg + gap) {
      final w = math.min(seg, size.width - x);
      canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), Paint()..color = x + w / 2 <= filled ? on : off);
    }
  }

  @override
  bool shouldRepaint(_SegPainter old) => old.value != value || old.on != on || old.off != off;
}

/// Code-barres décoratif.
class Barcode extends StatelessWidget {
  const Barcode({super.key, this.width = 96, this.height = 16, this.color});
  final double width;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _BarPainter(color ?? HudColors.of(context).dim)),
    ),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.color);
  final Color color;
  static const _bars = [2, 1, 1, 3, 2, 1, 3, 1, 1, 2, 1, 3, 2, 2, 1, 1, 3, 1, 2, 1];

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    var x = 0.0;
    var i = 0;
    while (x < size.width) {
      final w = _bars[i % _bars.length].toDouble();
      if (i.isEven) canvas.drawRect(Rect.fromLTWH(x, 0, math.min(w, size.width - x), size.height), p);
      x += w + 1.5;
      i++;
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.color != color;
}

/// Trois chevrons »»».
class Chevrons extends StatelessWidget {
  const Chevrons({super.key, this.color, this.size = 12, this.down = false});
  final Color? color;
  final double size;
  final bool down;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RotatedBox(
      quarterTurns: down ? 1 : 0,
      child: SizedBox(
        width: size * 2.8,
        height: size,
        child: CustomPaint(painter: _ChevPainter(color ?? HudColors.of(context).pink)),
      ),
    ),
  );
}

class _ChevPainter extends CustomPainter {
  _ChevPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final p = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final x = i * h * 0.92;
      canvas.drawPath(
        Path()
          ..moveTo(x, 0)
          ..lineTo(x + h * .42, 0)
          ..lineTo(x + h * .92, h / 2)
          ..lineTo(x + h * .42, h)
          ..lineTo(x, h)
          ..lineTo(x + h * .5, h / 2)
          ..close(),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_ChevPainter old) => old.color != color;
}

/// Touche de clavier (« CTRL K »).
class HudKey extends StatelessWidget {
  const HudKey(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(border: Border.all(color: c.line)),
      child: Text(text.toUpperCase(), style: hudLabel(context, size: 10, color: c.muted).copyWith(letterSpacing: 0.5)),
    );
  }
}

/// Fond de l'appli : grille de points discrète.
class HudBackground extends StatelessWidget {
  const HudBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    // Le fond est dessiné une fois (calque à part) : ce qui bouge dessus ne
    // le fait pas redessiner.
    return ColoredBox(
      color: c.bg,
      child: CustomPaint(
        isComplex: true,
        painter: _DotsPainter(c.dot),
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Tous les points en un seul appel (bien plus rapide qu'un carré par point).
    final pts = <double>[];
    for (var y = 14.0; y < size.height; y += 28) {
      for (var x = 14.0; x < size.width; x += 28) {
        pts
          ..add(x)
          ..add(y);
      }
    }
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square;
    canvas.drawRawPoints(PointMode.points, Float32List.fromList(pts), p);
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color;
}

/// Titre d'une section du menu (« ESPACES ———— + »).
class HudSectionLabel extends StatelessWidget {
  const HudSectionLabel(this.text, {super.key, this.trailing, this.onTap, this.open});
  final String text;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Section repliable : ouverte ou fermée (null : pas repliable).
  final bool? open;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 4, 6),
      child: Row(
        children: [
          if (open != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AnimatedRotation(
                turns: open! ? 0.25 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(Icons.chevron_right_rounded, size: 14, color: c.dim),
              ),
            ),
          Text(text.toUpperCase(), style: hudLabel(context, size: 10, color: c.dim).copyWith(letterSpacing: 1.6)),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: c.line.withValues(alpha: 0.7))),
          ?trailing,
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Un message « pas encore là » dans le style HUD.
class HudEmpty extends StatelessWidget {
  const HudEmpty(this.text, {super.key, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chevrons(color: c.accent, size: 14, down: true),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, height: 1.45),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
