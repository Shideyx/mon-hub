import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/ui/home_page.dart';
import 'package:hub/ui/hud/home_layout.dart';
import 'package:hub/ui/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Mod extends HubModule {
  _Mod(this.id, this.name);
  @override
  final String id;
  @override
  final String name;
  @override
  String get description => '';
  @override
  IconData get icon => Icons.star;
  @override
  Color get color => Colors.purple;
  @override
  ApiAccess get access => ApiAccess.local;
  @override
  Widget buildSummary(BuildContext context) => Text('résumé $name');
  @override
  Widget buildPage(BuildContext context) => const SizedBox();
}

void main() {
  // L'ancien accueil (cartes arrondies qu'on échangeait en les glissant) a
  // été remplacé en v1.60 par l'accueil HUD : mêmes gestes, en blocs.
  testWidgets('accueil HUD : un clic ouvre le module, « Personnaliser » permet de glisser un bloc avant un autre', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    HomeLayout.instance.setEditing(false);
    final a = _Mod('a', 'Agenda'), b = _Mod('b', 'Notes');
    final hub = HubController([a, b]);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: HomePage(controller: hub, notifications: NotificationCenter(hub), onOpen: (m) => opened.add(m.id)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Agenda'), findsOneWidget);
    expect(find.text('résumé Notes'), findsOneWidget);

    // Un clic sur le bloc ouvre le module.
    await tester.tap(find.text('Agenda'));
    await tester.pump();
    expect(opened, ['a']);

    // Mode personnalisation : glisser « Notes » sur « Agenda » le met avant.
    HomeLayout.instance.setEditing(true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MODE PERSONNALISATION'), findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(find.text('Notes')));
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    await g.moveTo(tester.getCenter(find.text('Agenda')));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    final order = HomeLayout.instance
        .blocks(modules: const ['a', 'b'], specialsHere: const {})
        .map((x) => x.id)
        .toList();
    expect(order.indexOf('mod:b') < order.indexOf('mod:a'), isTrue, reason: '$order');
    // En mode personnalisation, un clic n'ouvre rien.
    expect(opened, ['a']);
    HomeLayout.instance.setEditing(false);
    expect(tester.takeException(), isNull);
  });
}
