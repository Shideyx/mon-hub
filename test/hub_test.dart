import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_module.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/module_registry.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/main.dart';
import 'package:hub/modules/mail/mail_module.dart';
import 'package:hub/modules/schedule/ics_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

const ics = '''BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART;TZID=Europe/Paris:20261116T080000
DTEND;TZID=Europe/Paris:20261116T090000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE
EXDATE;TZID=Europe/Paris:20261118T080000
SUMMARY:Maths
LOCATION:Salle 12
END:VEVENT
BEGIN:VEVENT
DTSTART;VALUE=DATE:20261120
DTEND;VALUE=DATE:20261121
SUMMARY:Sortie\\, musée
END:VEVENT
END:VCALENDAR''';

void main() {
  test('parseIcs gère récurrences, exceptions et journées entières', () {
    final ev = parseIcs(ics, DateTime(2026, 11, 16), DateTime(2026, 11, 26));
    final maths = ev.where((e) => e.title == 'Maths').map((e) => e.start.day);
    expect(maths, [16, 23, 25]); // le 18 est exclu (EXDATE)
    final sortie = ev.firstWhere((e) => e.title == 'Sortie, musée');
    expect(sortie.allDay, isTrue);
  });

  test('imapHostFor devine le serveur', () {
    expect(imapHostFor('a@gmail.com'), 'imap.gmail.com');
    expect(imapHostFor('a@orange.fr'), 'imap.orange.fr');
  });

  test('HubController mémorise ordre et modules désactivés', () async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final c = HubController(buildModules());
    final first = c.ordered.first;
    c.reorder(0, 2);
    c.setEnabled(first, false);
    final c2 = HubController(buildModules());
    expect(c2.ordered[2].id, first.id);
    expect(c2.enabled.any((m) => m.id == first.id), isFalse);
  });

  test('NotificationCenter n\'alerte pas au premier passage puis alerte les nouveautés', () async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final fake = _FakeModule();
    final hub = HubController([fake]);
    final center = NotificationCenter(hub);
    fake.items = [HubNotification(id: 'a', title: 'A', body: '')];
    await center.pollNow();
    expect(center.history, isEmpty);
    fake.items = [...fake.items, HubNotification(id: 'b', title: 'B', body: '')];
    await center.pollNow();
    expect(center.history.map((n) => n.id), ['b']);
    await center.pollNow();
    expect(center.history.length, 1);
  });

  testWidgets('le tableau de bord affiche les modules', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final hub = HubController(buildModules());
    await tester.pumpWidget(HubApp(controller: hub, notifications: NotificationCenter(hub)));
    expect(find.textContaining('👋'), findsOneWidget);
    expect(find.text('Agenda'), findsWidgets);
    expect(find.text('Accueil'), findsOneWidget);
  });
}

class _FakeModule extends HubModule {
  List<HubNotification> items = [];
  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get description => '';
  @override
  IconData get icon => Icons.star;
  @override
  Color get color => Colors.red;
  @override
  ApiAccess get access => ApiAccess.local;
  @override
  Future<List<HubNotification>> poll() async => items;
  @override
  Widget buildSummary(BuildContext context) => const SizedBox();
  @override
  Widget buildPage(BuildContext context) => const SizedBox();
}
