import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'music_models.dart';

/// Rouge « natsuko garage » quand la pochette ne donne pas de couleur.
const musicRed = Color(0xFFC8372D);
const musicCream = Color(0xFFE9E6DD);

/// Pochette : image réseau, octets (pochette lue par Windows), ou un
/// dégradé avec une note de musique.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, this.url, this.bytes, this.fit = BoxFit.cover, this.color = musicRed});
  final String? url;
  final Uint8List? bytes;
  final BoxFit fit;
  final Color color;

  static ImageProvider? provider(String? url, Uint8List? bytes) {
    if (url != null && url.isNotEmpty) return NetworkImage(url);
    if (bytes != null && bytes.isNotEmpty) return MemoryImage(bytes);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = provider(url, bytes);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.55)!],
        ),
      ),
      child: const Center(child: Icon(Icons.album_rounded, color: Colors.white54, size: 64)),
    );
    if (p == null) return fallback;
    return Image(image: p, fit: fit, gaplessPlayback: true, errorBuilder: (_, _, _) => fallback);
  }
}

/// Couleur dominante (vive) d'une pochette, pour teinter tout l'écran.
Future<Color?> coverAccent(ImageProvider p) async {
  try {
    final c = Completer<ui.Image>();
    final stream = ResizeImage(p, width: 48, height: 48).resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        if (!c.isCompleted) c.complete(info.image);
        stream.removeListener(l);
      },
      onError: (e, _) {
        if (!c.isCompleted) c.completeError(e);
        stream.removeListener(l);
      },
    );
    stream.addListener(l);
    final img = await c.future.timeout(const Duration(seconds: 10));
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return pickAccent(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// Choisit une couleur vive dans des pixels RGBA (la plus fréquente parmi
/// les couleurs saturées), assez foncée pour du texte blanc.
Color? pickAccent(Uint8List rgba) {
  final buckets = <int, (int, double, double, double)>{};
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
    if (hsv.saturation < 0.35 || hsv.value < 0.25) continue;
    final key = (hsv.hue / 20).floor();
    final (n, sr, sg, sb) = buckets[key] ?? (0, 0.0, 0.0, 0.0);
    buckets[key] = (n + 1, sr + r, sg + g, sb + b);
  }
  final best = buckets.isEmpty ? null : buckets.values.reduce((a, b) => a.$1 >= b.$1 ? a : b);
  if (best == null || best.$1 < 6) return _calmAccent(rgba);
  final c = Color.fromARGB(255, (best.$2 / best.$1).round(), (best.$3 / best.$1).round(), (best.$4 / best.$1).round());
  final hsv = HSVColor.fromColor(c);
  return hsv.withSaturation(math.max(0.55, hsv.saturation)).withValue(hsv.value.clamp(0.45, 0.8)).toColor();
}

/// Pochette sans couleur vive (noir et blanc, tons pastel) : sa couleur
/// moyenne, gardée assez foncée pour le texte blanc.
Color? _calmAccent(Uint8List rgba) {
  var n = 0, r = 0, g = 0, b = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    n++;
    r += rgba[i];
    g += rgba[i + 1];
    b += rgba[i + 2];
  }
  if (n == 0) return null;
  final hsv = HSVColor.fromColor(Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n));
  return hsv
      .withSaturation(hsv.saturation < 0.12 ? hsv.saturation : math.max(0.35, hsv.saturation))
      .withValue(hsv.value.clamp(0.3, 0.6))
      .toColor();
}

/// Un CD avec la pochette de l'album imprimée dessus : trou au centre,
/// anneau transparent, reflets irisés. Il tourne pendant la lecture.
class CdDisc extends StatefulWidget {
  const CdDisc({super.key, this.coverUrl, this.coverBytes, this.color = musicRed, this.spinning = true});
  final String? coverUrl;
  final Uint8List? coverBytes;
  final Color color;
  final bool spinning;

  @override
  State<CdDisc> createState() => _CdDiscState();
}

class _CdDiscState extends State<CdDisc> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(seconds: 4));

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _a.repeat();
  }

  @override
  void didUpdateWidget(CdDisc old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_a.isAnimating) _a.repeat();
    if (!widget.spinning && _a.isAnimating) _a.stop();
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RotationTransition(
            turns: _a,
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage(url: widget.coverUrl, bytes: widget.coverBytes, color: widget.color),
                  // Sillons très fins.
                  CustomPaint(painter: _GroovesPainter()),
                ],
              ),
            ),
          ),
          // Reflets (fixes : la lumière ne tourne pas avec le disque).
          ClipOval(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: SweepGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.0),
                    Colors.white.withValues(alpha: 0.28),
                    const Color(0x2266CCFF),
                    Colors.white.withValues(alpha: 0.0),
                    const Color(0x22FF66CC),
                    Colors.white.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                  stops: const [0, 0.1, 0.18, 0.35, 0.6, 0.68, 0.8],
                ),
              ),
            ),
          ),
          CustomPaint(painter: _HubPainter()),
        ],
      ),
    ),
  );
}

class _GroovesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = s.shortestSide / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.black.withValues(alpha: 0.06);
    for (var k = r * 0.36; k < r; k += 3) {
      canvas.drawCircle(c, k, p);
    }
  }

  @override
  bool shouldRepaint(_GroovesPainter old) => false;
}

/// Le centre du CD : anneau transparent, rebord, trou.
class _HubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = s.shortestSide / 2;
    canvas.drawCircle(c, r * 0.33, Paint()..color = Colors.white.withValues(alpha: 0.28));
    canvas.drawCircle(
      c,
      r * 0.33,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.6),
    );
    canvas.drawCircle(c, r * 0.2, Paint()..color = const Color(0xFFDADADA).withValues(alpha: 0.85));
    canvas.drawCircle(c, r * 0.085, Paint()..color = const Color(0xFF2A2626));
    canvas.drawCircle(
      c,
      r - 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_HubPainter old) => false;
}

/// La boîte de CD, avec le disque (pochette dessus) qui sort et tourne
/// pendant la lecture.
class CaseWithDisc extends StatelessWidget {
  const CaseWithDisc({
    super.key,
    required this.caseWidget,
    this.coverUrl,
    this.coverBytes,
    this.color = musicRed,
    this.playing = false,
  });
  final Widget caseWidget;
  final String? coverUrl;
  final Uint8List? coverBytes;
  final Color color;
  final bool playing;

  /// Largeur totale / largeur de la boîte.
  static const extra = 1.38;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1.13 * extra,
    child: LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final caseW = w / extra;
        final d = h * 0.9;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              left: playing ? w - d : caseW - d * 1.02,
              top: (h - d) / 2,
              width: d,
              height: d,
              child: CdDisc(coverUrl: coverUrl, coverBytes: coverBytes, color: color, spinning: playing),
            ),
            Positioned(left: 0, top: 0, width: caseW, height: h, child: caseWidget),
          ],
        );
      },
    ),
  );
}

/// Face avant de la boîte de CD : la charnière à gauche, la pochette.
class CdCaseFront extends StatelessWidget {
  const CdCaseFront({super.key, this.coverUrl, this.coverBytes, this.color = musicRed});
  final String? coverUrl;
  final Uint8List? coverBytes;
  final Color color;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final h = box.maxHeight;
      final hinge = h * 0.085;
      return _Plastic(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Charnière : plastique strié.
            SizedBox(
              width: hinge,
              child: CustomPaint(painter: _HingePainter()),
            ),
            Container(width: math.max(2, h * 0.012), color: const Color(0xFF4A4646)),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(h * 0.012),
                child: ClipRect(
                  child: CoverImage(url: coverUrl, bytes: coverBytes, color: color),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Face arrière : bandes de couleur sur les côtés, carton crème, titre,
/// artiste, liste des titres (celui en cours en gras), code-barres.
class CdCaseBack extends StatelessWidget {
  const CdCaseBack({
    super.key,
    required this.title,
    required this.artist,
    required this.tracks,
    this.current = 0,
    this.color = musicRed,
  });

  final String title;
  final String artist;
  final List<MusicTrack> tracks;

  /// Numéro du titre en cours (1 = premier, 0 = aucun).
  final int current;
  final Color color;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final side = w * 0.03;
      final ink = Color.lerp(color, Colors.black, 0.25)!;
      final rows = tracks.take(14).toList();
      return _Plastic(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: side, color: color),
            Expanded(
              child: Container(
                color: musicCream,
                padding: EdgeInsets.fromLTRB(w * 0.08, h * 0.08, w * 0.07, h * 0.06),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: h * 0.14,
                      child: FittedBox(
                        child: Text(
                          title.toLowerCase(),
                          style: TextStyle(color: color, fontWeight: FontWeight.w800, height: 1),
                        ),
                      ),
                    ),
                    SizedBox(height: h * 0.015),
                    Text(
                      artist.toUpperCase(),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.brown.shade700, fontSize: h * 0.03, letterSpacing: h * 0.012),
                    ),
                    SizedBox(height: h * 0.045),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, area) {
                          final rowH = math.min(h * 0.05, area.maxHeight / math.max(1, rows.length));
                          return Column(
                            children: [
                              for (final (i, t) in rows.indexed)
                                SizedBox(
                                  height: rowH,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: rowH * 1.7,
                                        child: Text(
                                          '${(i + 1).toString().padLeft(2, '0')}.',
                                          style: _rowStyle(i + 1, ink, rowH),
                                        ),
                                      ),
                                      Container(
                                        width: w * 0.07,
                                        height: 1,
                                        color: ink.withValues(alpha: 0.7),
                                        margin: EdgeInsets.only(right: rowH * 0.6),
                                      ),
                                      Expanded(
                                        child: Text(
                                          '${t.artist.isEmpty ? artist : t.artist} - ${t.title.toUpperCase()}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: _rowStyle(i + 1, ink, rowH),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'MADE IN WORLDWIDE  STEREO',
                          style: TextStyle(color: ink.withValues(alpha: 0.8), fontSize: h * 0.022),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: w * 0.2,
                          height: h * 0.06,
                          child: CustomPaint(painter: _BarcodePainter('$artist$title', ink)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Container(width: side, color: color),
          ],
        ),
      );
    },
  );

  TextStyle _rowStyle(int n, Color ink, double rowH) => TextStyle(
    fontSize: rowH * 0.55,
    height: 1,
    color: n == current ? Color.lerp(ink, Colors.black, 0.3) : ink.withValues(alpha: 0.75),
    fontWeight: n == current ? FontWeight.w800 : FontWeight.w400,
  );
}

/// Le plastique transparent de la boîte (bords clairs, reflet).
class _Plastic extends StatelessWidget {
  const _Plastic({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 3),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(8, 14))],
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        child,
        // Reflet du plastique.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0, 0.35, 0.36, 1],
                colors: [
                  Colors.white.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0.04),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.06),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
          ),
        ),
      ],
    ),
  );
}

class _HingePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFD8D8D8));
    final line = Paint()
      ..color = const Color(0xFF8A8A8A)
      ..strokeWidth = 1;
    for (var y = 6.0; y < s.height - 6; y += math.max(4, s.height / 70)) {
      canvas.drawLine(Offset(s.width * 0.18, y), Offset(s.width * 0.82, y), line);
    }
    final edge = Paint()..color = const Color(0xFF6E6E6E);
    canvas.drawRect(Rect.fromLTWH(0, 0, 2, s.height), edge);
    canvas.drawRect(Rect.fromLTWH(s.width - 2, 0, 2, s.height), edge);
  }

  @override
  bool shouldRepaint(_HingePainter old) => false;
}

class _BarcodePainter extends CustomPainter {
  _BarcodePainter(this.seed, this.color);
  final String seed;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final r = math.Random(seed.hashCode);
    final p = Paint()..color = color;
    var x = 0.0;
    while (x < s.width) {
      final w = (r.nextInt(3) + 1) * s.width / 120;
      if (r.nextBool()) canvas.drawRect(Rect.fromLTWH(x, 0, w, s.height), p);
      x += w + s.width / 120;
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) => old.seed != seed;
}

/// La boîte de CD qui tourne sur elle-même : la pochette, un demi-tour,
/// la liste des titres au dos, un demi-tour… Elle se pose sur la pochette
/// quand la musique est en pause.
class SpinningCdCase extends StatefulWidget {
  const SpinningCdCase({
    super.key,
    required this.front,
    required this.back,
    this.spinning = true,
    this.period = const Duration(seconds: 16),
  });

  final Widget front;
  final Widget back;
  final bool spinning;
  final Duration period;

  /// Angle (radians) à l'instant t ∈ [0, 1[ : pause sur la pochette, demi-
  /// tour, pause au dos, demi-tour (avec un léger balancement pendant les
  /// pauses).
  static double angleAt(double t) {
    double ease(double x) => Curves.easeInOutCubic.transform(x.clamp(0.0, 1.0));
    final wobble = math.sin(t * 4 * math.pi) * 0.12;
    if (t < 0.35) return wobble;
    if (t < 0.5) return ease((t - 0.35) / 0.15) * math.pi;
    if (t < 0.85) return math.pi + wobble;
    return math.pi + ease((t - 0.85) / 0.15) * math.pi;
  }

  @override
  State<SpinningCdCase> createState() => _SpinningCdCaseState();
}

class _SpinningCdCaseState extends State<SpinningCdCase> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _a.repeat();
  }

  @override
  void didUpdateWidget(SpinningCdCase old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_a.isAnimating) {
      _a.repeat();
    } else if (!widget.spinning && _a.isAnimating) {
      // Retour en douceur sur la pochette.
      _a.stop();
      final v = _a.value;
      final target = v < 0.5 ? 0.0 : 1.0;
      unawaited(
        _a
            .animateTo(target, duration: const Duration(milliseconds: 900), curve: Curves.easeOut)
            .then((_) => _a.value = 0),
      );
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1.13,
    child: AnimatedBuilder(
      animation: _a,
      builder: (context, _) {
        final angle = SpinningCdCase.angleAt(_a.value);
        final showFront = math.cos(angle) >= 0;
        final bob = math.sin(_a.value * 2 * math.pi) * 6;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0011)
            ..translateByDouble(0, bob, 0, 1)
            ..rotateY(angle)
            ..rotateX(-0.06),
          child: showFront
              ? widget.front
              : Transform(alignment: Alignment.center, transform: Matrix4.rotationY(math.pi), child: widget.back),
        );
      },
    ),
  );
}

/// Fond en deux couleurs coupé en diagonale (crème à gauche, couleur de la
/// pochette à droite).
class SplitBackground extends StatelessWidget {
  const SplitBackground({super.key, required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _SplitPainter(color), child: child);
}

class _SplitPainter extends CustomPainter {
  _SplitPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = musicCream);
    final p = Path()
      ..moveTo(s.width * 0.44, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width, s.height)
      ..lineTo(s.width * 0.74, s.height)
      ..lineTo(s.width * 0.5, s.height * 0.22)
      ..close();
    canvas.drawPath(
      p,
      Paint()
        ..shader = LinearGradient(colors: [color, Color.lerp(color, Colors.black, 0.12)!])
            .createShader(Offset.zero & s),
    );
  }

  @override
  bool shouldRepaint(_SplitPainter old) => old.color != color;
}
