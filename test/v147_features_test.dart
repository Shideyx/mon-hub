import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/custom_modules.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/hub_feed.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/modules/books/free_classics.dart';
import 'package:hub/modules/books/read_finder.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/ui/add_module.dart';
import 'package:hub/ui/hub_feed_view.dart';
import 'package:hub/ui/clicky/alive.dart';
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
  Widget buildSummary(BuildContext context) => const SizedBox();
  @override
  Widget buildPage(BuildContext context) => Scaffold(body: Text('page $name'));
}

void main() {
  testWidgets('le fil s\'affiche sans déborder et ouvre le bon module', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    final hub = HubController([
      _Mod('schedule', 'Agenda'),
      _Mod('revisions', 'Révisions'),
      _Mod('ecoledirecte', 'École'),
    ]);
    HubFeed.instance.items = HubFeed.build(
      now: DateTime(2026, 11, 18, 17),
      events: [
        {
          'titre': 'Mathématiques avancées en salle de travaux pratiques',
          'debut': DateTime(2026, 11, 18, 17, 20),
          'source': 'École Directe',
          'lieu': 'B12',
        },
      ],
      homework: [
        {'pour_le': DateTime(2026, 11, 19), 'matiere': 'Physique-Chimie', 'controle': true},
      ],
    );
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HubFeedStrip(controller: hub, onOpen: (m) => opened.add(m.id)),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ton fil'), findsOneWidget);
    await tester.tap(find.text('Contrôle de Physique-Chimie demain'));
    expect(opened, ['revisions']);
    HubFeed.instance.reset();
    await tester.pumpWidget(const SizedBox());
  });

  group('ton fil : les modules reliés entre eux', () {
    final now = DateTime(2026, 11, 18, 17, 0);

    test('contrôle demain → relié aux Révisions (fiche prête)', () {
      final items = HubFeed.build(
        now: now,
        homework: [
          {'pour_le': DateTime(2026, 11, 19), 'matiere': 'Physique', 'controle': true, 'fait': false},
        ],
        revisions: {
          'paquets': [
            {'nom': '📝 Physique', 'maitrise_pourcent': 40},
          ],
        },
      );
      final t = items.first;
      expect(t.moduleId, 'revisions');
      expect(t.title, 'Contrôle de Physique demain');
      expect(t.detail, contains('fiche est prête'));
      expect(t.from, ['ecoledirecte', 'revisions']);
      expect(HubFeed.say(t), isNotNull);
    });

    test('cours dans 20 minutes : en premier, et Nexo peut le dire', () {
      final items = HubFeed.build(
        now: now,
        events: [
          {'titre': 'Maths', 'debut': DateTime(2026, 11, 18, 17, 20), 'source': 'École Directe', 'lieu': 'B12'},
          {'titre': 'Sport', 'debut': DateTime(2026, 11, 19, 9), 'source': 'École Directe'},
        ],
        revisions: {'a_revoir_aujourdhui': 4, 'serie_jours': 3},
      );
      expect(items.first.title, 'Maths dans 20 min');
      expect(items.first.detail, contains('B12'));
      expect(items.first.priority, greaterThanOrEqualTo(80));
      expect(items.map((i) => i.moduleId), contains('revisions'));
    });

    test('devoirs pour demain, lecture en cours, messages non lus', () {
      final items = HubFeed.build(
        now: now,
        homework: [
          {'pour_le': DateTime(2026, 11, 19), 'matiere': 'Français', 'fait': false},
          {'pour_le': DateTime(2026, 11, 19), 'matiere': 'Anglais', 'fait': true},
        ],
        books: [
          {'titre': '1984', 'auteur': 'George Orwell', 'statut': 'En cours', 'progression': '32 % lu'},
        ],
        badges: {'discord': 3, 'mail': 1, 'music': 9},
        names: {'discord': 'Discord', 'mail': 'Mails'},
      );
      final hw = items.firstWhere((i) => i.moduleId == 'ecoledirecte');
      expect(hw.title, '1 devoir pour demain');
      expect(hw.detail, 'Français');
      final book = items.firstWhere((i) => i.moduleId == 'books');
      expect(book.title, 'Reprends « 1984 »');
      expect(book.detail, contains('32 %'));
      final unread = items.firstWhere((i) => i.icon == Icons.mark_chat_unread_rounded);
      expect(unread.title, '4 messages non lus');
      expect(unread.moduleId, 'discord');
    });

    test('rien à dire : fil vide', () {
      expect(HubFeed.build(now: now), isEmpty);
      expect(HubFeed.say(null), isNull);
    });
  });

  group('modules perso', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
    });

    test('seuls les vrais sites web sont acceptés (https)', () {
      expect(CustomModules.cleanUrl('www.exemple.fr'), 'https://www.exemple.fr');
      expect(CustomModules.cleanUrl('http://exemple.fr/page'), 'https://exemple.fr/page');
      expect(CustomModules.cleanUrl('file:///C:/Windows'), isNull);
      expect(CustomModules.cleanUrl('javascript:alert(1)'), isNull);
      expect(CustomModules.cleanUrl('pas une adresse'), isNull);
      expect(CustomModules.cleanUrl(''), isNull);
    });

    test('ajouté, gardé, puis retiré', () async {
      final spec = CustomModuleSpec(
        id: CustomModules.newId('WhatsApp'),
        name: 'WhatsApp',
        kind: 'web',
        url: 'https://web.whatsapp.com/',
        icon: 'chat',
        color: 0xFF25D366,
      );
      expect(spec.id, startsWith('perso_whatsapp_'));
      await CustomModules.add(spec);
      final hub = HubController([]);
      hub.add(spec.build());
      expect(hub.enabled.map((m) => m.name), ['WhatsApp']);
      expect(CustomModules.load().single.url, 'https://web.whatsapp.com/');
      // Au prochain démarrage, il est toujours là.
      expect(CustomModules.build().single.name, 'WhatsApp');
      // Nexo sait l'ouvrir.
      expect(hub.enabled.single.tools.single.name, startsWith('perso_ouvrir_'));
      await CustomModules.remove(spec.id);
      hub.remove(spec.id);
      expect(hub.enabled, isEmpty);
      expect(CustomModules.load(), isEmpty);
    });

    test('un fichier abîmé ou trafiqué ne casse rien', () async {
      await ModuleStore.prefs.setString(
        'hub.custom',
        '[{"id":"schedule","name":"x","url":"https://a.fr"},{"id":"perso_x","url":"file:///c:/"},"n\'importe quoi"]',
      );
      expect(CustomModules.load(), isEmpty);
      await ModuleStore.prefs.setString('hub.custom', 'pas du json');
      expect(CustomModules.load(), isEmpty);
    });

    testWidgets('« Ajouter un module » : un clic dans le catalogue', (tester) async {
      final hub = HubController([]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(width: 400, height: 260, child: AddModuleCard(controller: hub)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter un module'));
      await tester.pumpAndSettle();
      expect(find.text('Prêts à l\'emploi'), findsOneWidget);
      await tester.tap(find.text('WhatsApp'));
      await tester.pumpAndSettle();
      expect(hub.enabled.map((m) => m.name), contains('WhatsApp'));
      expect(CustomModules.load().map((s) => s.name), contains('WhatsApp'));
      // Fermer la feuille et laisser partir le message.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('livres gratuits et légaux', () {
    test('1984 et La Ferme des animaux : libres en France (Gutenberg Australie)', () {
      final a = FreeClassics.match('1984');
      expect(a.single.title, 'Nineteen Eighty-Four');
      expect(a.single.source, 'gutenberg-au');
      expect(a.single.textUrl, startsWith('https://gutenberg.net.au/'));
      expect(a.single.isText, isTrue);
      expect(FreeClassics.match('La ferme des animaux').single.title, 'Animal Farm');
      expect(FreeClassics.match('Harry Potter'), isEmpty);
      // Un autre auteur demandé : pas Orwell.
      expect(FreeClassics.match('1984', author: 'Haruki Murakami'), isEmpty);
    });

    test('le texte du Gutenberg Australie est nettoyé (en-tête, licence)', () {
      final raw =
          'Project Gutenberg Australia\nTitle: Nineteen eighty-four\nAuthor: George Orwell\n'
          '------------------------------------------------------------------\n\n'
          'PART ONE\n\nIt was a bright cold day in April.\n\n${'Texte du roman. ' * 200}\n\nTHE END\n\n'
          'This eBook is made available at no cost.';
      final t = FreeClassics.clean(raw);
      expect(t, startsWith('PART ONE'));
      expect(t, isNot(contains('Project Gutenberg Australia')));
      expect(t, isNot(contains('no cost')));
    });

    test('Wikisource : les œuvres, pas les sous-pages ni les auteurs', () {
      final r = Wikisource.fromSearch({
        'query': {
          'search': [
            {'title': 'Germinal'},
            {'title': 'Germinal/Partie 1'},
            {'title': 'Auteur:Émile Zola'},
            {'title': 'Les Misérables (Hugo)'},
          ],
        },
      });
      expect(r.map((m) => m.title), ['Germinal', 'Les Misérables']);
      expect(r[1].author, 'Hugo');
      expect(r.first.source, 'wikisource');
      expect(r.first.languages, ['fr']);
      expect(r.first.textUrl, contains('ws-export'));
      expect(ReadMatch.textSources, containsAll(['gutenberg', 'gutenberg-au', 'wikisource']));
    });
  });

  group('animations de Nexo', () {
    test('le rebond revient toujours à la taille normale', () {
      expect(ClickyBounceMath.squash(0), (1.0, 1.0));
      expect(ClickyBounceMath.squash(1), (1.0, 1.0));
      final (sx, sy) = ClickyBounceMath.squash(0.2);
      expect(sx, isNot(1.0));
      expect(sy, isNot(1.0));
      final (lx, ly) = ClickyBounceMath.squash(0.98);
      expect((lx - 1).abs(), lessThan(0.01));
      expect((ly - 1).abs(), lessThan(0.01));
    });

    testWidgets('halo quand il réfléchit, puis plus rien qui tourne au repos', (tester) async {
      Widget at(AliveMood m) => MaterialApp(
        home: Center(
          child: ClickyBounce(mood: m, child: const SizedBox(width: 22, height: 22)),
        ),
      );
      await tester.pumpWidget(at(AliveMood.idle));
      await tester.pumpWidget(at(AliveMood.thinking));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(at(AliveMood.speaking));
      // Le saut de joie se termine tout seul…
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(at(AliveMood.idle));
      await tester.pump(const Duration(seconds: 1));
      // … et au repos, aucune animation ne tourne en boucle.
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
