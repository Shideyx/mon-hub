import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/roblox/roblox_charts.dart';
import 'package:hub/modules/roblox/roblox_module.dart';
import 'package:hub/ui/clicky/clicky.dart';

void main() {
  test('Clicky lit la balise [POINT:x,y:libellé]', () {
    final (t, p, l) = ClickyController.parsePoint(
      'Clique sur Réglages en bas à gauche. [POINT:120,640:Réglages]',
    );
    expect(t, 'Clique sur Réglages en bas à gauche.');
    expect(p, const Offset(120, 640));
    expect(l, 'Réglages');

    final (t2, p2, _) = ClickyController.parsePoint('Rien à montrer. [POINT:none]');
    expect(t2, 'Rien à montrer.');
    expect(p2, isNull);

    final (t3, p3, _) = ClickyController.parsePoint('Pas de balise');
    expect(t3, 'Pas de balise');
    expect(p3, isNull);
  });

  test('paliers Roblox et format des nombres', () {
    expect(RobloxModule.milestone(9), 0);
    expect(RobloxModule.milestone(10), 10);
    expect(RobloxModule.milestone(30), 25);
    expect(RobloxModule.milestone(1200), 1000);
    expect(RobloxModule.milestone(2600), 2500);
    expect(fmtInt(1234567), '1 234 567');
    expect(fmtShort(15300), '15,3 k');
    expect(fmtShort(2500000), '2,5 M');
  });
}
