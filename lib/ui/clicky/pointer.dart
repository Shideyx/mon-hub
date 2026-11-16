import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Pointage précis en deux passes : après une première réponse, Clicky
/// zoome autour du point proposé, pose une grille 6 × 6 numérotée, et
/// redemande à l'IA dans quelle case est exactement l'élément. Le curseur
/// tombe ainsi pile sur le bouton, même petit.
class PrecisePointer {
  PrecisePointer._();

  static const cells = 6;
  static const rows = 'ABCDEF';

  /// Zone zoomée (pixels de la capture) autour de [p].
  static Rect zone(Offset p, int width, int height, {double side = 280}) {
    final s = math.min(side, math.min(width, height).toDouble());
    final left = (p.dx - s / 2).clamp(0.0, math.max(0.0, width - s)).toDouble();
    final top = (p.dy - s / 2).clamp(0.0, math.max(0.0, height - s)).toDouble();
    return Rect.fromLTWH(left, top, s, s);
  }

  /// Centre de la case (« C4 ») dans la zone, en pixels de la capture.
  static Offset? cellCenter(String answer, Rect zone) {
    final m = RegExp(r'\b([A-F])\s*([1-6])\b', caseSensitive: false).firstMatch(answer);
    if (m == null) return null;
    final row = rows.indexOf(m.group(1)!.toUpperCase());
    final col = int.parse(m.group(2)!) - 1;
    final w = zone.width / cells, h = zone.height / cells;
    return Offset(zone.left + (col + 0.5) * w, zone.top + (row + 0.5) * h);
  }

  /// Image zoomée (×2) avec la grille, en PNG base64.
  static Future<String?> gridImage(String png64, Rect zone) async {
    try {
      final codec = await ui.instantiateImageCodec(base64Decode(png64));
      final src = (await codec.getNextFrame()).image;
      const scale = 2.0;
      final out = Size(zone.width * scale, zone.height * scale);
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImageRect(src, zone, Offset.zero & out, Paint()..filterQuality = FilterQuality.high);
      final line = Paint()
        ..color = const Color(0xCCFF1744)
        ..strokeWidth = 2;
      final cw = out.width / cells, ch = out.height / cells;
      for (var i = 1; i < cells; i++) {
        c.drawLine(Offset(i * cw, 0), Offset(i * cw, out.height), line);
        c.drawLine(Offset(0, i * ch), Offset(out.width, i * ch), line);
      }
      for (var r = 0; r < cells; r++) {
        for (var k = 0; k < cells; k++) {
          final tp = TextPainter(
            text: TextSpan(
              text: '${rows[r]}${k + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                backgroundColor: Color(0xAAFF1744),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(c, Offset(k * cw + 3, r * ch + 3));
        }
      }
      final img = await rec.endRecording().toImage(out.width.round(), out.height.round());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      src.dispose();
      img.dispose();
      return data == null ? null : base64Encode(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  static String question(String label) =>
      'Voici un zoom de l\'écran avec une grille rouge (lignes A à F, colonnes 1 à 6). '
      'Dans quelle case se trouve le centre de « ${label.isEmpty ? 'l\'élément dont tu parlais' : label} » ? '
      'Réponds seulement par la case (par exemple C4), ou « aucune ».';
}
