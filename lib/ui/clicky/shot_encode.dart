import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Une capture d'écran (pixels BGRA de Windows) en **JPEG** : 5 à 10 fois
/// plus léger qu'un PNG, donc envoyée bien plus vite à l'IA. Fait dans un
/// Isolate (voir `_captureScreens`) : Nexo continue de bouger pendant ce
/// temps.
///
/// Windows laisse l'opacité à 0 : on la remet à fond (sinon l'encodeur
/// JPEG voit une image transparente… donc blanche). [bgra] est modifié.
/// [rgba] : pixels dans l'ordre R, V, B, A (capture de Flutter).
Uint8List encodeShot(Uint8List bgra, int width, int height, {int quality = 85, bool rgba = false}) {
  for (var i = 3; i < bgra.length; i += 4) {
    bgra[i] = 255;
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bgra.buffer,
    bytesOffset: bgra.offsetInBytes,
    numChannels: 4,
    order: rgba ? img.ChannelOrder.rgba : img.ChannelOrder.bgra,
  );
  return img.encodeJpg(image, quality: quality);
}

/// Le type d'une image en base64 (JPEG ou PNG), pour l'annoncer à l'IA.
String imageMime(String b64) => b64.startsWith('/9j/') ? 'image/jpeg' : 'image/png';
