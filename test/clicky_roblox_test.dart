import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/shortcuts.dart';
import 'package:hub/modules/roblox/roblox_charts.dart';
import 'package:hub/modules/roblox/roblox_module.dart';
import 'package:hub/ui/clicky/clicky.dart';

void main() {
  test('Clicky lit la balise [POINT:x,y:libellé]', () {
    final (t, p, l, _) = ClickyController.parsePoint(
      'Clique sur Réglages en bas à gauche. [POINT:120,640:Réglages]',
    );
    expect(t, 'Clique sur Réglages en bas à gauche.');
    expect(p, const Offset(120, 640));
    expect(l, 'Réglages');

    final (_, p4, l4, s4) = ClickyController.parsePoint('Là ! [POINT:10,20:Bouton OK:screen2]');
    expect(p4, const Offset(10, 20));
    expect(l4, 'Bouton OK');
    expect(s4, 2);

    final (t2, p2, _, _) = ClickyController.parsePoint('Rien à montrer. [POINT:none]');
    expect(t2, 'Rien à montrer.');
    expect(p2, isNull);

    final (t3, p3, _, _) = ClickyController.parsePoint('Pas de balise');
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

  test('script des raccourcis Windows', () {
    final s = AppShortcuts.windowsScript(r"C:\Users\Erik\Mon Hub l'appli\hub.exe", false);
    expect(s, contains(r"TargetPath='C:\Users\Erik\Mon Hub l''appli\hub.exe'"));
    expect(s, contains(r"WorkingDirectory='C:\Users\Erik\Mon Hub l''appli'"));
    expect(s, contains("GetFolderPath('Desktop')"));
    expect(s, contains("GetFolderPath('Programs')"));
    expect(s, contains('Remove-Item'));
    expect(AppShortcuts.windowsScript(r'C:\a\hub.exe', true), contains("GetFolderPath('Startup')"));
  });
}
