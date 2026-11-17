import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/desktop_widgets.dart';
import 'package:hub/core/photo.dart';
import 'package:hub/ui/call_page.dart';
import 'package:image/image.dart' as img;

void main() {
  test('photo : un PNG devient un JPEG (Instagram), réduit à 1440 px', () {
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 3000, height: 1500)));
    final (jpeg, w, h) = Photo.convert(png);
    expect(jpeg[0], 0xFF);
    expect(jpeg[1], 0xD8); // en-tête JPEG
    expect((w, h), (1440, 720));
    expect(() => Photo.convert(Uint8List.fromList([1, 2, 3])), throwsA(isA<String>()));
  });

  test('widgets détachés : un port local stable par widget', () {
    final a = DesktopWidgets.port('music');
    expect(a, DesktopWidgets.port('music'));
    expect(a, inInclusiveRange(47700, 47949));
    expect(DesktopWidgets.port('books'), isNot(a));
  });

  test('appels : le bouton est cherché en français et en anglais', () {
    expect(CallPage.clickScript(video: false), contains('appel vocal'));
    expect(CallPage.clickScript(video: false), contains('voice call'));
    expect(CallPage.clickScript(video: true), contains('video call'));
  });
}
