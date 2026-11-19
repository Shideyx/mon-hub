import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/modules/mail/mail_module.dart';
import 'package:hub/modules/money/games_deals.dart';
import 'package:hub/modules/money/money_module.dart';
import 'package:hub/modules/money/money_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('page Mon argent', (t) async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    HubFiles.overrideRoot = Directory.systemTemp.createTempSync('argent').path;
    final m = MoneyModule(mail: MailModule())..attach();
    m.data.subs = [
      Subscription(service: 'Spotify', price: 11.12, next: DateTime.now().add(const Duration(days: 1)), cancelUrl: 'https://x'),
      Subscription(service: 'Netflix', price: 7.99, trial: true, next: DateTime.now().add(const Duration(days: 3))),
    ];
    m.data.parcels = [Parcel(carrier: 'Colissimo', number: '6A12345678901', status: 'a_retirer', link: 'https://l', shop: 'Zalando')];
    m.data.free = [const FreeGame(id: 'a', title: 'Jeu Gratuit', url: 'https://e')];
    m.data.deals = [const SteamDeal(appId: 1, name: 'Hades', discount: 50, price: '9,99€', before: '19,99€')];
    m.data.steam = '76561198000000000';
    await t.binding.setSurfaceSize(const Size(1000, 800));
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: m.buildSummary))));
    await t.pump();
    expect(find.text('par mois'), findsOneWidget);
    await t.pumpWidget(MaterialApp(home: Builder(builder: m.buildPage)));
    await t.pump();
    expect(find.textContaining('Spotify'), findsWidgets);
    await t.tap(find.text('Colis'));
    await t.pumpAndSettle();
    expect(find.textContaining('À retirer'), findsOneWidget);
    await t.tap(find.text('Jeux'));
    await t.pumpAndSettle();
    expect(find.text('Hades'), findsOneWidget);
    final n = m.reminders(DateTime.now().copyWith(hour: 12));
    expect(n.map((x) => x.title).join(' | '), contains('Spotify : prélèvement demain'));
    expect(n.map((x) => x.title).join(' | '), contains('Colis Zalando à retirer'));
  });
}
