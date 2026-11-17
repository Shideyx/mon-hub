import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/ui/home_page.dart';
import 'package:hub/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

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
  Widget buildSummary(BuildContext context) => const SizedBox();
  @override
  Widget buildPage(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('ancien accueil : un clic ouvre la carte, la glisser sur une autre les échange', (tester) async {
    final a = _Mod('a', 'Agenda'), b = _Mod('b', 'Notes');
    final opened = <String>[];
    final dropped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Row(
            children: [
              for (final m in [a, b])
                SizedBox(
                  width: 360,
                  height: 268,
                  child: ModuleCard(
                    module: m,
                    onOpen: (x) => opened.add(x.id),
                    onDropped: (x) => dropped.add('${x.id}→${m.id}'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    // L'ancien look (carte arrondie, pas de bouton « Ouvrir » en plus).
    expect(find.byType(Card), findsNWidgets(2));
    expect(find.byTooltip('Ouvrir'), findsNothing);

    // Un simple clic sur le titre ouvre toujours le module.
    await tester.tap(find.text('Agenda'));
    await tester.pumpAndSettle();
    expect(opened, ['a']);

    // Glisser le titre « Agenda » sur la carte « Notes ».
    final g = await tester.startGesture(tester.getCenter(find.text('Agenda')));
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    await g.moveTo(tester.getCenter(find.text('Notes')) + const Offset(0, 80));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(dropped, ['a→b']);
    expect(opened, ['a']);
  });
}
