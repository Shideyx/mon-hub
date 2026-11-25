import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_controller.dart';
import 'package:hub/core/module_registry.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/notifications.dart';
import 'package:hub/ui/clicky/clicky_settings_page.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/skills.dart';
import 'package:hub/ui/clicky/tutorial.dart';
import 'package:hub/ui/settings_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
  });

  group('la visite guidée', () {
    test('elle montre tout, nouveautés comprises', () {
      final titles = [for (final p in ClickyTutorial.tour) p.title];
      expect(titles.first, 'Salut, moi c\'est Nexo');
      expect(titles.last, 'Prêt ?');
      for (final t in [
        'Parle-moi',
        'Je le fais à ta place',
        'Ton école',
        'Mes yeux et mes oreilles',
        'Je prends les devants',
        'Préviens-moi quand…',
        'Toute ta vie, pas que l\'école',
        'Et je suis vivant',
      ]) {
        expect(titles, contains(t));
      }
      expect(ClickyTutorial.tour.where((p) => p.badge == 'Nouveau'), hasLength(4));
      // Les phrases à essayer sont comprises par Nexo.
      expect(ClickyTutorial.tour.expand((p) => p.examples), contains('Préviens-moi quand j\'ai ma note de maths'));
    });

    test('montrée une fois (aussi à ceux qui avaient vu l\'ancienne)', () async {
      SharedPreferences.setMockInitialValues({'tutorial.v124': true});
      await ModuleStore.init();
      expect(ClickyTutorial.seen, isFalse);
    });

    testWidgets('on la parcourt et on essaie une phrase', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tried = <String>[];
      await tester.pumpWidget(MaterialApp(home: ClickyTutorial(onTry: tried.add)));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Salut, moi c\'est Nexo'), findsOneWidget);
      expect(find.text('1 / ${ClickyTutorial.tour.length}'), findsOneWidget);
      Future<void> next() async {
        await tester.tap(find.text('Suivant'));
        for (var k = 0; k < 6; k++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }

      await next();
      expect(find.text('Parle-moi'), findsOneWidget);
      await tester.tap(find.text('« Fais le point »'));
      expect(tried, ['Fais le point']);
      // Toutes les pages s'affichent sans erreur.
      for (var i = 2; i < ClickyTutorial.tour.length; i++) {
        await next();
        expect(find.text(ClickyTutorial.tour[i].title), findsOneWidget);
        final ex = tester.takeException();
        expect(ex, isNull, reason: 'page ${i + 1} : ${ex is FlutterError ? ex.toStringDeep() : ex}');
        if (ClickyTutorial.tour[i].title == 'Mes yeux et mes oreilles') {
          expect(find.text('Allumer mes yeux et mes oreilles'), findsOneWidget);
          expect(find.text('Nouveau'), findsOneWidget);
        }
      }
      expect(find.text('Voir tout ce que je sais faire'), findsOneWidget);
      expect(find.text('C\'est parti'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('la visite sur un petit écran (téléphone)', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ClickyTutorial(onTry: (_) {})));
    for (var i = 0; i < ClickyTutorial.tour.length; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      final ex = tester.takeException();
      expect(ex, isNull, reason: 'page ${i + 1} : ${ex is FlutterError ? ex.toStringDeep() : ex}');
      if (i < ClickyTutorial.tour.length - 1) {
        await tester.tap(find.text('Suivant'));
        for (var k = 0; k < 6; k++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  group('ce que Nexo sait faire', () {
    test('tout le catalogue, avec les nouveautés', () {
      expect(ClickySkills.count, greaterThan(80));
      final titles = [for (final g in ClickySkills.groups) g.title];
      for (final t in [
        'Lui parler',
        'Ses yeux et ses oreilles',
        'Préviens-moi quand…',
        'Il prend les devants',
        'Nexo vivant',
        'École',
      ]) {
        expect(titles, contains(t));
      }
      expect(ClickySkills.search('arnaque').map((g) => g.title), contains('Sécurité'));
      expect(ClickySkills.search('écharpe').single.title, 'Nexo vivant');
      expect(ClickySkills.search('zzzzzz'), isEmpty);
    });

    test('les phrases « essayer » partent bien quelque part', () async {
      // Celles qu'un algorithme sait faire passent par les réponses sans IA.
      const tools = {
        'clicky_situation',
        'agenda_lire',
        'guetteur_creer',
        'guetteur_liste',
        'clicky_habitudes',
        'memoire_ecran',
        'sens_regler',
        'temps_ecran',
        'ecole_devoirs',
        'clicky_concentration',
      };
      final asked = <String>[];
      Future<Object?> call(String name, Map<String, dynamic> a) async {
        asked.add(name);
        return name == 'guetteur_creer'
            ? 'D\'accord : je te préviens dès que j\'ai ta note de maths.'
            : {'resume': 'ok'};
      }

      expect(
        await QuickAnswers.answer('Préviens-moi quand j\'ai ma note de maths', call: call, tools: tools),
        isNotNull,
      );
      expect(await QuickAnswers.answer('Mes habitudes', call: call, tools: tools), isNotNull);
      expect(await QuickAnswers.answer('Mode concentration 45 minutes', call: call, tools: tools), isNotNull);
      expect(asked, containsAll(['guetteur_creer', 'clicky_habitudes', 'clicky_concentration']));
    });

    testWidgets('on cherche, on filtre, on essaie', (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tried = <String>[];
      await tester.pumpWidget(MaterialApp(home: ClickySkillsPage(onTry: tried.add)));
      expect(find.text('Lui parler'), findsOneWidget);
      await tester.tap(find.textContaining('Réfléchis bien'));
      expect(tried.single, startsWith('Réfléchis bien'));
      await tester.enterText(find.byType(TextField), 'colis');
      await tester.pump();
      expect(find.text('Ton argent'), findsOneWidget);
      expect(find.text('Lui parler'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  });

  group('les menus', () {
    test('les rubriques des réglages se trouvent en cherchant', () {
      expect(SettingsCategory.find('').length, SettingsCategory.all.length);
      expect(SettingsCategory.find('téléphone').single.id, 'appareils');
      expect(SettingsCategory.find('sombre').single.id, 'apparence');
      expect(SettingsCategory.find('déconnexion').single.id, 'compte');
      expect(SettingsCategory.find('xyz'), isEmpty);
      expect(SettingsCategory.clickyMatches('voix'), isTrue);
      expect(SettingsCategory.clickyMatches('téléphone'), isFalse);
    });

    testWidgets('Réglages : Nexo en tête, puis des rubriques claires', (tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final hub = HubController(buildModules());
      final n = NotificationCenter(hub);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(controller: hub, notifications: n),
        ),
      );
      await tester.pump();
      expect(find.text('Réglages de Nexo'), findsOneWidget);
      expect(find.text('Revoir la visite guidée'), findsOneWidget);
      for (final k in SettingsCategory.all.where((k) => k.id != 'demarrage')) {
        expect(find.text(k.title), findsOneWidget);
      }
      // Une rubrique s'ouvre sur sa page.
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Tester une alerte'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mon compte'));
      await tester.pumpAndSettle();
      expect(find.text('Se déconnecter'), findsOneWidget);
      expect(find.text('Version de Mon Hub'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // La recherche.
      await tester.enterText(find.byType(TextField).first, 'téléphone');
      await tester.pump();
      expect(find.text('Mes appareils'), findsOneWidget);
      expect(find.text('Apparence'), findsNothing);
      n.dispose();
    });

    testWidgets('Réglages de Nexo : rangés par thème', (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ClickySettingsPage()));
      await tester.pump();
      for (final t in [
        'BIEN DÉMARRER',
        'LUI PARLER',
        'CE QU\'IL FAIT POUR TOI',
        'SA PERSONNALITÉ',
        'VIE PRIVÉE ET AVANCÉ',
      ]) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('Ses yeux et ses oreilles'), findsOneWidget);
      expect(find.text('Revoir la visite guidée'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
