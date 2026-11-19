import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/phone_link.dart';
import 'package:hub/core/tool_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Mon téléphone : règles', () {
    test('noms de fichiers sûrs', () {
      expect(PhoneLink.safeName('IMG_0001.HEIC'), 'IMG_0001.HEIC');
      expect(PhoneLink.safeName(r'..\..\Windows\evil.exe'), 'evil.exe');
      expect(PhoneLink.safeName('../../.bashrc'), 'bashrc');
      expect(PhoneLink.safeName('a<b>c:d"e|f?g*.txt'), 'a_b_c_d_e_f_g_.txt');
      expect(PhoneLink.safeName('CON.txt'), '_CON.txt');
      expect(PhoneLink.safeName('photo. '), 'photo');
      expect(PhoneLink.safeName(''), 'fichier');
      final long = PhoneLink.safeName('${'a' * 300}.jpg');
      expect(long.length, 120);
      expect(long.endsWith('.jpg'), isTrue);
    });

    test('seulement le réseau de la maison', () {
      expect(PhoneLink.localClient('192.168.1.20'), isTrue);
      expect(PhoneLink.localClient('10.0.0.3'), isTrue);
      expect(PhoneLink.localClient('172.16.4.1'), isTrue);
      expect(PhoneLink.localClient('127.0.0.1'), isTrue);
      expect(PhoneLink.localClient('8.8.8.8'), isFalse);
      expect(PhoneLink.localClient('172.40.0.1'), isFalse);
    });

    test('clés comparées entièrement', () {
      expect(PhoneLink.sameKey('abc', 'abc'), isTrue);
      expect(PhoneLink.sameKey('abc', 'abd'), isFalse);
      expect(PhoneLink.sameKey('abc', 'abcd'), isFalse);
      expect(PhoneLink.sameKey('abc', null), isFalse);
      expect(PhoneLink.newToken(), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('Claude reçoit l\'outil quand on parle du téléphone', () {
      expect(ToolRouter.groupsFor('envoie le pdf sur mon téléphone'), contains('telephone'));
      expect(ToolRouter.groupOf('telephone_envoyer'), 'telephone');
    });
  });

  group('Mon téléphone : serveur', () {
    final link = PhoneLink.instance;
    final client = HttpClient();
    late Directory dir;
    String? clipboard;
    final commands = <String>[];
    final notices = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app.phone.on': true});
      await ModuleStore.init();
      dir = await Directory.systemTemp.createTemp('phone_test');
      PhoneLink.lanOverride = '127.0.0.1';
      link
        ..receiveDirOverride = dir.path
        ..notify = ((t, b) => notices.add(t))
        ..readClipboard = (() async => clipboard)
        ..writeClipboard = ((t) async => clipboard = t)
        ..command = ((action, a) async {
          commands.add(action);
          return action == 'volup' ? 'Son +' : null;
        })
        ..loadAsset = ((p) async => p == 'phone/index.html' ? Uint8List.fromList(utf8.encode('<h1>Mon PC</h1>')) : null);
      await link.start();
    });

    tearDown(() async {
      await link.stop();
      await dir.delete(recursive: true);
      PhoneLink.lanOverride = null;
    });

    Future<(int, String)> call(String path, {String method = 'GET', List<int>? body, Map<String, String>? headers}) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${link.boundPort}$path'));
      req.followRedirects = false;
      headers?.forEach(req.headers.set);
      if (body != null) req.add(body);
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    String base() => link.link!.path;

    test('le lien secret', () async {
      expect(link.link!.path, matches(RegExp(r'^/t/[0-9a-f]{32}/$')));
      expect(await call(base()), (200, '<h1>Mon PC</h1>'));
      expect((await call(base().substring(0, base().length - 1))).$1, 302);
      expect((await call('/t/0123456789abcdef0123456789abcdef/')).$1, 404);
      expect((await call('/')).$1, 404);
      expect((await call('${base()}../../pubspec.yaml')).$1, 404);
    });

    test('photo du téléphone → Téléchargements', () async {
      final r = await call(
        '${base()}api/envoyer',
        method: 'POST',
        body: List.filled(5000, 7),
        headers: {'x-nom': Uri.encodeComponent('vacances été.jpg')},
      );
      expect(r.$1, 200);
      expect(jsonDecode(r.$2)['nom'], 'vacances été.jpg');
      final f = File('${dir.path}${Platform.pathSeparator}vacances été.jpg');
      expect(await f.length(), 5000);
      // Même nom : pas d'écrasement.
      final r2 = await call(
        '${base()}api/envoyer',
        method: 'POST',
        body: [1, 2, 3],
        headers: {'x-nom': Uri.encodeComponent('vacances été.jpg')},
      );
      expect(jsonDecode(r2.$2)['nom'], 'vacances été (2).jpg');
      expect(link.received.first.name, 'vacances été (2).jpg');
    });

    test('presse-papier dans les deux sens', () async {
      clipboard = 'copié sur le PC';
      final st = jsonDecode((await call('${base()}api/etat')).$2) as Map;
      expect(st['presse_papier'], 'copié sur le PC');
      expect(st['telecommande'], isTrue);
      await call('${base()}api/texte', method: 'POST', body: utf8.encode('https://exemple.fr'));
      expect(clipboard, 'https://exemple.fr');
      expect(notices, contains('📱 Texte reçu du téléphone'));
    });

    test('télécommande', () async {
      final ok = jsonDecode((await call('${base()}api/commande', method: 'POST', body: utf8.encode('{"action":"volup"}'))).$2);
      expect(ok, {'ok': true, 'message': 'Son +'});
      final ko = jsonDecode((await call('${base()}api/commande', method: 'POST', body: utf8.encode('pas du json'))).$2);
      expect(ko['ok'], isFalse);
      expect(commands, ['volup', '']);
    });

    test('fichier du PC → téléphone', () async {
      final f = File('${dir.path}${Platform.pathSeparator}exposé.pdf')..writeAsStringSync('PDF');
      final sf = (await link.share(f.path))!;
      final st = jsonDecode((await call('${base()}api/etat')).$2) as Map;
      expect((st['fichiers'] as List).single['nom'], 'exposé.pdf');
      expect(await call('${base()}api/fichier/${sf.id}'), (200, 'PDF'));
      expect((await call('${base()}api/fichier/inconnu')).$1, 404);
      link.unshare(sf.id);
      expect((await call('${base()}api/fichier/${sf.id}')).$1, 404);
    });

    test('nouveau lien : l\'ancien ne marche plus', () async {
      final old = base();
      await link.newLink();
      expect((await call(old)).$1, 404);
      expect((await call(base())).$1, 200);
    });
  });
}
