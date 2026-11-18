import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/shot_encode.dart';
import 'package:hub/ui/clicky/win.dart';
import 'package:image/image.dart' as img;

void main() {
  test('capture d\'écran (BGRA de Windows) en JPEG léger, couleurs justes', () {
    const w = 64, h = 32;
    final bgra = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      // Moitié gauche bleue, moitié droite rouge (ordre B, G, R, A ; alpha à 0
      // comme le donne Windows).
      final left = (i % w) < w / 2;
      bgra[i * 4] = left ? 230 : 20;
      bgra[i * 4 + 1] = 40;
      bgra[i * 4 + 2] = left ? 20 : 230;
      bgra[i * 4 + 3] = 0;
    }
    final jpeg = encodeShot(bgra, w, h);
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    final back = img.decodeJpg(jpeg)!;
    expect(back.width, w);
    final blue = back.getPixel(5, 10), red = back.getPixel(58, 10);
    expect(blue.b, greaterThan(180));
    expect(blue.r, lessThan(70));
    expect(red.r, greaterThan(180));
    expect(red.b, lessThan(70));
    // Annoncé comme JPEG à l'IA.
    expect(imageMime(base64Encode(jpeg)), 'image/jpeg');
    expect(imageMime('iVBORw0KGgo'), 'image/png');
  });

  test('décalage envoyé au lanceur (avec les nombres négatifs)', () {
    for (final (dx, dy) in const [(16, 14), (-20, 5), (0, -300), (-1, -1)]) {
      expect(Win.unpackOffset(Win.packOffset(dx, dy)), (dx, dy));
    }
  });
}
