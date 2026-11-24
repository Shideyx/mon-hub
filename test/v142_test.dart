import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_home.dart';
import 'package:hub/core/nav.dart';
import 'package:hub/modules/youtube/youtube_module.dart';
import 'package:hub/ui/clicky/voice.dart';
import 'package:hub/ui/motion.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('voix Gemini : gros morceaux (un premier court pour parler vite)', () {
    final text = List.generate(30, (i) => 'Voici la phrase numéro $i de mon briefing du matin.').join(' ');
    final parts = ClickyVoice.chunks(text);
    expect(parts.first.length, lessThanOrEqualTo(260));
    for (final p in parts.skip(1)) {
      expect(p.length, lessThanOrEqualTo(1125));
    }
    // Rien n'est perdu, et on coupe en fin de phrase.
    expect(parts.join(' '), text);
    expect(parts.every((p) => p.endsWith('.')), isTrue);
    // ~1 600 lettres : 3 lectures seulement (le quota gratuit est petit).
    expect(parts.length, 3);
    expect(ClickyVoice.chunks('Bonjour !'), ['Bonjour !']);
    // Pendant l'écriture : on attend une vraie fin de phrase.
    expect(ClickyVoice.cutAt('Bonjour, je regarde', min: 40, max: 260), isNull);
    expect(ClickyVoice.cutAt('Bonjour ! Je regarde ton emploi du temps de demain. Et', min: 40, max: 260), 51);
  });

  test('petit écran YouTube : la vidéo reprend à la bonne seconde', () {
    expect(YouTubeMiniPlayer.watchUrl('abc123', 95), 'https://www.youtube.com/watch?v=abc123&t=95s');
    expect(YouTubeMiniPlayer.watchUrl('abc123', 0), 'https://www.youtube.com/watch?v=abc123');
    final p = YouTubeMiniPlayer.instance;
    p.show(YouTubeModule(), 'abc123', 95.7, title: 'Ma vidéo');
    expect((p.active, p.start, p.title), (true, 95, 'Ma vidéo'));
    // Sur l'accueil avec la carte YouTube : la vidéo se joue dans la carte.
    expect(p.inCard, isFalse);
    p.cardAttached();
    expect(p.inCard, isTrue);
    p.tick(130.4);
    expect(p.start, 130);
    p.cardDetached();
    expect(p.inCard, isFalse);
    p.close();
    expect(p.active, isFalse);
    expect(YouTubeMiniPlayer.script, contains('#movie_player'));
  });

  test('barres de musique : toujours visibles, jamais trop hautes', () {
    for (var i = 0; i < 4; i++) {
      for (var t = 0.0; t <= 1; t += 0.05) {
        expect(EqualizerBars.height(i, t), inInclusiveRange(0.3, 1.0));
      }
    }
  });

  testWidgets('bouton Menu : visible hors de l\'accueil, il ferme tout et revient au menu', (tester) async {
    var home = 0;
    HubHome.instance.onHome = () => home++;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: hubNavigatorKey,
        navigatorObservers: [HubHome.instance.observer],
        builder: (context, child) => HubHomeLayer(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Center(child: Text('Page coincée'))),
                  ),
                ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(HubHome.instance.away, isFalse);
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    expect(find.text('Page coincée'), findsOneWidget);
    expect(HubHome.instance.away, isTrue);
    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Page coincée'), findsNothing);
    expect(home, 1);
    expect(HubHome.instance.away, isFalse);
    HubHome.instance.onHome = null;
  });

  testWidgets('animations : les cartes arrivent en douceur', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EnterAnimation(index: 2, child: Text('Carte'))),
      ),
    );
    final start = tester.widget<Opacity>(find.ancestor(of: find.text('Carte'), matching: find.byType(Opacity))).opacity;
    expect(start, 0);
    await tester.pumpAndSettle();
    final end = tester.widget<Opacity>(find.ancestor(of: find.text('Carte'), matching: find.byType(Opacity))).opacity;
    expect(end, 1);
  });
}
