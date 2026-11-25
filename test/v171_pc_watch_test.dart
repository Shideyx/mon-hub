import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/claude_bridge.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/ui/clicky/life.dart';
import 'package:hub/ui/clicky/pc_watch.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  final now = DateTime(2026, 11, 22, 18);

  group('le presse-papier malin', () {
    test('jamais un mot de passe ni une clé', () {
      expect(ClipSmart.looksSecret('Tr0ub4dor&3'), isTrue);
      expect(ClipSmart.looksSecret('mon mot de passe : chat123'), isTrue);
      expect(ClipSmart.looksSecret('sk-ant-api03-abcdef'), isTrue);
      expect(ClipSmart.looksSecret('bonjour tout le monde'), isFalse);
      expect(ClipSmart.looksSecret('https://fr.wikipedia.org/wiki/Volcan'), isFalse);
      expect(ClipSmart.classify('Tr0ub4dor&3', now), isNull);
    });

    test('un lien d\'arnaque : il prévient tout de suite (même copié dans une messagerie)', () {
      final i = ClipSmart.classify('https://discord-nitro.gift/claim', now, private: true)!;
      expect(i.kind, 'scam');
      expect(i.warn, isTrue);
      expect(i.say, startsWith('🚨'));
      expect(ClipSmart.classify('https://fr.wikipedia.org/wiki/Volcan', now), isNull);
    });

    test('un calcul : le résultat (pas une date ni un numéro)', () {
      final i = ClipSmart.classify('12*7+3', now)!;
      expect(i.kind, 'calcul');
      expect(i.say, contains('87'));
      expect(ClipSmart.classify('2026-11-22', now), isNull);
      expect(ClipSmart.classify('06 12 34 56 78', now), isNull);
      expect(ClipSmart.classify('12*7', now, private: true), isNull);
    });

    test('un colis, une adresse, une date', () {
      final p = ClipSmart.classify('1Z999AA10123456784', now)!;
      expect(p.kind, 'colis');
      expect(p.args['cible'], contains('ups.com'));
      expect(ClipSmart.parcel('6A12345678901')!.$1, 'Colissimo');
      final a = ClipSmart.classify('12 rue de la Paix 75002 Paris', now)!;
      expect(a.kind, 'adresse');
      expect(a.tool, 'pc_ouvrir');
      expect(a.args['cible'], contains('google.com/maps'));
      final d = ClipSmart.classify('Réunion parents-profs jeudi 26 novembre à 18h', now)!;
      expect(d.kind, 'date');
      expect(d.tool, 'agenda_ajouter');
      expect(d.args['debut'], '2026-11-26T18:00');
    });

    test('de l\'anglais à traduire, un long texte à résumer', () {
      final en = ClipSmart.classify(
        'The mitochondria is the powerhouse of the cell and it is where the energy that we need is made, so this is '
        'what you have to remember for the test.',
        now,
      )!;
      expect(en.kind, 'anglais');
      expect(en.args['action'], 'traduire');
      final long = List.filled(140, 'la cellule est l\'unité de base du vivant').join(', ');
      final l = ClipSmart.classify(long, now)!;
      expect(l.kind, 'long');
      expect(l.args['action'], 'resumer');
      expect(ClipSmart.classify('Salut, ça va ?', now), isNull);
      expect(ClipSmart.prompt('traduire', 'hello', lang: 'espagnol'), contains('espagnol'));
      expect(ClipSmart.prompt('resumer', 'texte'), contains('Résume'));
    });
  });

  group('le PC qui réagit', () {
    test('un cours téléchargé', () {
      expect(PcRules.downloadSubject('DM_maths_ch3.pdf'), 'Maths');
      expect(PcRules.downloadSubject('Exposé SVT.pptx'), 'SVT');
      expect(PcRules.downloadSubject('vacances.jpg'), isNull);
      expect(PcRules.downloadSubject('installeur_maths.exe'), isNull);
      expect(PcRules.partial('cours.pdf.crdownload'), isTrue);
      expect(PcRules.partial('cours.pdf'), isFalse);
    });

    test('une appli qui ne répond plus', () {
      expect(PcRules.frozenApp('Document1 - Word (Ne répond pas)'), 'Word');
      expect(PcRules.frozenApp('Google Chrome (Not Responding)'), 'Google Chrome');
      expect(PcRules.frozenApp('Document1 - Word'), isNull);
    });

    test('une clé USB (et ce qu\'il y a de suspect dessus)', () {
      expect(PcRules.newDrives(0x4, 0x14), ['E']);
      expect(PcRules.newDrives(0x14, 0x14), isEmpty);
      expect(PcRules.suspicious(['photo.jpg', 'autorun.inf', 'jeu gratuit.exe', 'cours.pdf']), [
        'autorun.inf',
        'jeu gratuit.exe',
      ]);
    });

    test('ranger un fichier : seulement depuis les Téléchargements, et avec ton accord', () async {
      final tools = {for (final t in PcWatch.instance.tools()) t.name: t};
      expect(await tools['pc_ranger_fichier']!.run({'chemin': '/etc/hosts'}), contains('Téléchargements'));
      expect(
        ClaudeBridge.isWriteAction(HubTool(name: 'pc_ranger_fichier', description: '', run: (_) async => null)),
        isTrue,
      );
      expect(
        ClaudeBridge.isWriteAction(HubTool(name: 'clicky_presse_papier', description: '', run: (_) async => null)),
        isFalse,
      );
    });
  });

  group('sa ville', () {
    test('« j\'habite à Lyon »', () {
      expect(ClickyLife.cityFrom('Nexo, j\'habite à Lyon'), 'lyon');
      expect(ClickyLife.cityFrom('ma ville c\'est Nantes'), 'nantes');
      expect(ClickyLife.cityFrom('j\'habite en Bretagne'), 'bretagne');
      expect(QuickAnswers.original('j\'habite à Lyon', 'lyon'), 'Lyon');
      expect(ClickyLife.cityFrom('j\'habite à côté'), isNull);
      expect(ClickyLife.cityFrom('je suis en cours'), isNull);
      expect(ClickyLife.cityFrom('quelle heure est-il'), isNull);
    });
  });
}
