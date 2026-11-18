import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/google_auth.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/module_registry.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/main.dart';
import 'package:hub/ui/screen_time_page.dart';
import 'package:hub/ui/birthdays_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('l\'accueil tient sur un iPhone 12 (390 × 844)', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final hub = HubController(buildModules());
    await tester.pumpWidget(HubApp(controller: hub, notifications: NotificationCenter(hub)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Agenda'), findsWidgets);
    expect(find.byTooltip('Chercher partout (Ctrl + Espace)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('les nouvelles pages tiennent sur un iPhone', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    for (final page in const [ScreenTimePage(), BirthdaysPage()]) {
      await tester.pumpWidget(MaterialApp(home: page));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '$page');
    }
  });

  group('code de liaison (PC → iPhone)', () {
    test('aller-retour', () async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
      if (GoogleAuth.builtInId.isNotEmpty) return;
      await GoogleAuth.setClient('123-abc.apps.googleusercontent.com', 'GOCSPX-secret_1');
      final code = GoogleAuth.shareCode()!;
      expect(code, startsWith('MONHUB-GOOGLE:'));
      await GoogleAuth.setClient('', '');
      expect(GoogleAuth.available, isFalse);
      // Collé depuis un mail, avec du texte autour.
      expect(await GoogleAuth.importCode('Sur ton iPhone : …\n\n$code\n'), isTrue);
      expect(GoogleAuth.clientId, '123-abc.apps.googleusercontent.com');
      expect(GoogleAuth.clientSecret, 'GOCSPX-secret_1');
      expect(await GoogleAuth.importCode('rien ici'), isFalse);
      expect(() => GoogleAuth.importCode('MONHUB-GOOGLE:AAAAAAAAAAAAAAAAAAAAAAAA'), throwsA(isA<String>()));
    });
  });
}
