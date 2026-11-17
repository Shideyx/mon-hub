import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/discord/discord_api.dart';
import 'package:hub/modules/discord/discord_phone.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  layerTests();
  test('salons rangés comme dans Discord (sans catégorie, puis catégories ; écrits avant vocaux)', () {
    final all = [
      DiscordChannel('v1', 'Général vocal', 2, parentId: 'c1', position: 0),
      DiscordChannel('t2', 'devoirs', 0, parentId: 'c1', position: 1),
      DiscordChannel('t1', 'général', 0, parentId: 'c1', position: 0),
      DiscordChannel('c2', 'JEUX', 4, position: 2),
      DiscordChannel('c1', 'CLASSE', 4, position: 1),
      DiscordChannel('r', 'règles', 0, position: 0),
      DiscordChannel('f', 'forum', 15, parentId: 'c2'),
      DiscordChannel('t3', 'minecraft', 0, parentId: 'c2'),
    ];
    final g = DiscordChannel.grouped(all);
    expect(g.map((e) => e.$1?.name), [null, 'CLASSE', 'JEUX']);
    expect(g[0].$2.map((c) => c.id), ['r']);
    expect(g[1].$2.map((c) => c.id), ['t1', 't2', 'v1']);
    expect(g[2].$2.map((c) => c.id), ['t3']); // le forum n'est pas affiché
  });

  test('serveur : icône animée en gif, sinon png', () {
    expect(DiscordGuild('1', 'A', 'a_abc').iconUrl, contains('.gif'));
    expect(DiscordGuild('1', 'A', 'abc').iconUrl, contains('.png'));
    expect(DiscordGuild('1', 'A', null).iconUrl, isNull);
  });

  test('téléphone : sonnerie, réponse, fin d\'appel', () {
    final p = DiscordPhone.instance;
    p.onStatus({'ringing': true, 'who': 'Léo', 'inCall': false});
    expect(p.state, PhoneState.ringing);
    expect(p.who, 'Léo');
    p.onStatus({'ringing': false, 'inCall': true});
    expect(p.state, PhoneState.inCall);
    expect(p.who, 'Léo');
    p.onStatus({'ringing': false, 'inCall': false});
    expect(p.state, PhoneState.ready);
    expect(p.who, '');
    p.onStatus({'loggedOut': true});
    expect(p.loggedOut, isTrue);
  });

  test('scripts du téléphone (écrits pour le test dans le navigateur)', () {
    final dir = Directory('${Directory.systemTemp.path}/discord_phone_scripts')..createSync(recursive: true);
    File('${dir.path}/status.js').writeAsStringSync(DiscordPhone.statusScript);
    for (final w in ['answer', 'answerVideo', 'decline', 'hangup', 'joinVoice']) {
      File('${dir.path}/$w.js').writeAsStringSync(DiscordPhone.buttonScript(w));
    }
    File('${dir.path}/nav.js').writeAsStringSync(DiscordPhone.navigateScript('/channels/@me/42'));
    expect(DiscordPhone.statusScript, contains('ringBox'));
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: () => setState(() => n++), child: Text('compteur $n'));
}

void layerTests() {
  testWidgets('Discord caché : Mon Hub garde son état, sonnerie et fenêtre d\'appel', (tester) async {
    final p = DiscordPhone.instance;
    DiscordPhone.testWebView = (_) => const ColoredBox(color: Colors.indigo, child: Text('DISCORD'));
    await tester.pumpWidget(const MaterialApp(home: DiscordPhoneLayer(child: Scaffold(body: Center(child: _Counter())))));
    await tester.tap(find.text('compteur 0'));
    await tester.pump();
    expect(find.text('compteur 1'), findsOneWidget);

    // Le Discord caché démarre : l'appli n'est pas reconstruite.
    p.forceActive();
    await tester.pump();
    expect(find.text('compteur 1'), findsOneWidget);

    // Ça sonne : la carte Répondre / Refuser apparaît.
    p.onStatus({'ringing': true, 'who': 'Léo'});
    await tester.pump();
    expect(find.text('Répondre'), findsOneWidget);
    expect(find.text('Léo'), findsOneWidget);

    // Fenêtre d'appel affichée, puis réduite : toujours le même compteur.
    p.show();
    await tester.pump();
    expect(find.text('Réduire'), findsOneWidget);
    expect(find.text('compteur 1'), findsNothing); // caché derrière l'appel
    p.hide();
    await tester.pump();
    expect(find.text('compteur 1'), findsOneWidget);
    p.stop();
    await tester.pump();
    expect(find.text('compteur 1'), findsOneWidget);
    DiscordPhone.testWebView = null;
  });
}
