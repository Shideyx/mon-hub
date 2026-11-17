import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Prépare une photo pour l'envoyer (Instagram n'accepte que le JPEG) :
/// n'importe quel format courant (PNG, WebP, GIF, BMP, JPEG) devient un JPEG
/// de 1440 px au plus, bien orienté. Fait à côté, sans bloquer l'appli.
class Photo {
  Photo._();

  static Future<(Uint8List, int, int)> toJpeg(Uint8List bytes, {int maxSide = 1440, int quality = 88}) =>
      Isolate.run(() => convert(bytes, maxSide: maxSide, quality: quality));

  static (Uint8List, int, int) convert(Uint8List bytes, {int maxSide = 1440, int quality = 88}) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw 'Ce fichier n\'est pas une photo lisible (JPEG, PNG, WebP, GIF ou BMP).';
    var image = img.bakeOrientation(decoded);
    final side = image.width > image.height ? image.width : image.height;
    if (side > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
    }
    return (Uint8List.fromList(img.encodeJpg(image, quality: quality)), image.width, image.height);
  }

  static const extensions = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'];
}
