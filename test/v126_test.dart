import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/session.dart';
import 'package:hub/core/vault.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';

String b64(String s, {bool lines = false}) {
  final e = base64.encode(utf8.encode(s));
  if (!lines) return e;
  // Comme certains serveurs : coupé toutes les 76 lettres.
  final out = StringBuffer();
  for (var i = 0; i < e.length; i += 76) {
    out.writeln(e.substring(i, i + 76 > e.length ? e.length : i + 76));
  }
  return '$out';
}

void main() {
  group('messages École Directe lisibles', () {
    test('accents en entités HTML', () {
      final t = EdClient.htmlToText(
        '<p>Bonjour,</p><p>Le contr&ocirc;le de fran&ccedil;ais est d&eacute;plac&eacute; &agrave; '
        'jeudi&nbsp;&#8217;10h&#x27;. &laquo;&nbsp;Merci&nbsp;&raquo; &hellip;</p>',
      );
      expect(t, 'Bonjour,\nLe contrôle de français est déplacé à jeudi ’10h\'. « Merci » …');
    });

    test('base64 coupé en lignes (avant : affiché en charabia)', () {
      const html = '<p>Réunion parents-professeurs à 18 h, salle 204.</p><p>Cordialement</p>';
      final c = EdMessageContent.fromJson({'content': b64(html, lines: true), 'files': []});
      expect(c.text, 'Réunion parents-professeurs à 18 h, salle 204.\nCordialement');
    });

    test('copié-collé depuis Word', () {
      const html =
          '<!--[if gte mso 9]><xml><o:OfficeDocumentSettings></o:OfficeDocumentSettings></xml><![endif]-->'
          '<style>p.MsoNormal{margin:0cm;font-family:Calibri}</style>'
          '<p class="MsoNormal"><span style="font-size:11pt">Sortie\n au mus&eacute;e</span></p>'
          '<ul><li>Pr&eacute;voir un pique-nique</li><li>10 &euro;</li></ul>';
      final t = EdMessageContent.fromJson({'content': b64(html)}).text;
      expect(t, 'Sortie au musée\n• Prévoir un pique-nique\n• 10 €');
      expect(t, isNot(contains('mso')));
      expect(t, isNot(contains('font-family')));
    });

    test('HTML échappé deux fois et ancien encodage', () {
      expect(EdClient.decodeContent('&lt;p&gt;Bonne journ&amp;eacute;e&lt;/p&gt;'), 'Bonne journée');
      final latin = base64.encode(latin1.encode('<p>Élève absent à 9h</p>'));
      expect(EdClient.decodeContent(latin), 'Élève absent à 9h');
    });

    test('lignes vides voulues gardées', () {
      expect(
        EdClient.htmlToText('<p>Bonjour</p><p>&nbsp;</p><p>Au revoir<br>Mme X</p>'),
        'Bonjour\n\nAu revoir\nMme X',
      );
    });

    test('texte simple laissé tel quel', () {
      expect(EdClient.decodeContent('Rappeler'), 'Rappeler');
      expect(EdClient.decodeContent('Merci beaucoup !'), 'Merci beaucoup !');
    });

    test('objet et expéditeur décodés', () {
      final m = EdMessage.fromJson({
        'id': 3,
        'subject': 'R&eacute;union du 12',
        'from': {'name': 'Mme Lef&egrave;vre'},
        'read': false,
      });
      expect(m.subject, 'Réunion du 12');
      expect(m.from, 'Mme Lefèvre');
    });
  });

  test('cloud École Directe : arborescence', () {
    final root = EdCloudNode.parse([
      {
        'type': 'folder',
        'libelle': '/',
        'id': r'\E\1234',
        'isLoaded': true,
        'children': [
          {'type': 'file', 'libelle': 'cours.pdf', 'id': r'\E\1234\cours.pdf', 'taille': 2048, 'date': '2026-11-10 08:00:00'},
          {'type': 'folder', 'libelle': 'Maths', 'id': r'\E\1234\Maths', 'isLoaded': false, 'children': []},
        ],
      },
    ]);
    expect(root.folder, isTrue);
    expect(root.name, '1234');
    expect(root.children.map((c) => c.name), ['Maths', 'cours.pdf']);
    expect(root.children.first.loaded, isFalse);
    expect(root.children.last.size, 2048);
    expect(root.find(r'\E\1234\Maths')?.name, 'Maths');
  });

  group('sécurité', () {
    setUp(() => Vault.overrideKey = List.generate(32, (i) => i));
    tearDown(() => Vault.overrideKey = null);

    test('coffre : chiffré, et illisible sans la bonne clé', () async {
      final sealed = await Vault.seal('{"secret":"mes notes"}');
      expect(Vault.isSealed(sealed), isTrue);
      expect(sealed, isNot(contains('mes notes')));
      expect(await Vault.open(sealed), '{"secret":"mes notes"}');
      // Ancien fichier en clair : relu tel quel.
      expect(await Vault.open('{"a":1}'), '{"a":1}');
      Vault.overrideKey = List.filled(32, 7);
      expect(() => Vault.open(sealed), throwsA(anything));
    });

    test('fichiers de données chiffrés sur le disque', () async {
      final dir = await Directory.systemTemp.createTemp('vault');
      HubFiles.overrideRoot = dir.path;
      addTearDown(() async {
        HubFiles.overrideRoot = null;
        await dir.delete(recursive: true);
      });
      final f = JsonFile<Map<String, dynamic>>(
        'test.json',
        empty: () => {},
        decode: (j) => (j as Map).cast<String, dynamic>(),
        encode: (v) => v,
      );
      await f.save({'conversation': 'bonjour Clicky'});
      final onDisk = await (await HubFiles.file('test.json'))!.readAsString();
      expect(onDisk, startsWith(Vault.prefix));
      expect(onDisk, isNot(contains('bonjour')));
      final g = JsonFile<Map<String, dynamic>>(
        'test.json',
        empty: () => {},
        decode: (j) => (j as Map).cast<String, dynamic>(),
        encode: (v) => v,
      );
      expect((await g.load())['conversation'], 'bonjour Clicky');
    });

    test('export protégé par mot de passe', () async {
      final p = await Vault.protect('{"secrets":{"mod.ed.password":"abc"}}', 'mot-de-passe-1');
      expect(jsonEncode(p), isNot(contains('abc')));
      expect(await Vault.unprotect(p, 'mot-de-passe-1'), contains('abc'));
      expect(() => Vault.unprotect(p, 'faux'), throwsA('Mot de passe incorrect'));
    });

    test('connexion : attente après 5 essais ratés', () {
      expect(AppSession.lockFor(4), Duration.zero);
      expect(AppSession.lockFor(5), const Duration(seconds: 30));
      expect(AppSession.lockFor(6), const Duration(minutes: 1));
      expect(AppSession.lockFor(50), const Duration(minutes: 15));
    });
  });
}
