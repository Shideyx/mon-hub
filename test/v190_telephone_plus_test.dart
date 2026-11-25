import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/phone_link.dart';
import 'package:hub/ui/phone_link_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Le téléphone pilote le PC, en mieux', () {
    final link = PhoneLink.instance;
    final client = HttpClient();
    final asked = <String>[];
    final widths = <int>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app.phone.on': true});
      await ModuleStore.init();
      PhoneLink.lanOverride = '127.0.0.1';
      asked.clear();
      widths.clear();
      link
        ..command = ((action, a) async => 'OK')
        ..screen = ((w) async {
          widths.add(w);
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        })
        ..ask = ((q) async {
          asked.add(q);
          return 'Musique lancée 🎵';
        })
        ..apps = ((q) async => [
          {'id': 'mc', 'nom': 'Minecraft Launcher', 'ini': 'ML'},
        ])
        ..windows = (() => [
          {'id': 42, 'titre': 'Minecraft', 'appli': 'javaw.exe'},
        ])
        ..loadAsset = ((p) async => null);
      await link.start();
    });

    tearDown(() async {
      await link.stop();
      link
        ..screen = null
        ..ask = null
        ..apps = null
        ..windows = null;
      PhoneLink.lanOverride = null;
    });

    Future<(int, List<int>, String?)> call(String path, {String method = 'GET', List<int>? body}) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${link.boundPort}$path'));
      if (body != null) req.add(body);
      final res = await req.close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, bytes, res.headers.contentType?.mimeType);
    }

    String base() => link.link!.path;

    test('l\'état annonce l\'écran, Nexo et les applis', () async {
      final st = jsonDecode(utf8.decode((await call('${base()}api/etat')).$2)) as Map;
      expect(st['ecran'], isTrue);
      expect(st['nexo'], isTrue);
      expect(st['applis'], isTrue);
    });

    test('l\'écran du PC en direct (taille bornée)', () async {
      final r = await call('${base()}api/ecran?l=99999');
      expect(r.$1, 200);
      expect(r.$3, 'image/jpeg');
      expect(r.$2, [0xFF, 0xD8, 0xFF, 0xD9]);
      expect(widths.single, 1600);
      // Sans le lien secret : rien.
      expect((await call('/t/0123456789abcdef0123456789abcdef/api/ecran')).$1, 404);
    });

    test('demander à Nexo depuis le téléphone', () async {
      final r = await call(
        '${base()}api/nexo',
        method: 'POST',
        body: utf8.encode(jsonEncode({'texte': 'mets de la musique'})),
      );
      expect(jsonDecode(utf8.decode(r.$2))['reponse'], 'Musique lancée 🎵');
      expect(asked, ['mets de la musique']);
      final empty = await call('${base()}api/nexo', method: 'POST', body: utf8.encode('{}'));
      expect(jsonDecode(utf8.decode(empty.$2))['ok'], isFalse);
      expect(asked, hasLength(1));
    });

    test('les applis et les fenêtres', () async {
      final apps = jsonDecode(utf8.decode((await call('${base()}api/applis?q=mine')).$2)) as List;
      expect((apps.single as Map)['nom'], 'Minecraft Launcher');
      final wins = jsonDecode(utf8.decode((await call('${base()}api/fenetres')).$2)) as List;
      expect((wins.single as Map)['id'], 42);
    });
  });

  group('Le toucher sur l\'image → l\'écran du PC', () {
    test('les coins et le milieu', () {
      expect(PhoneRemote.toScreen(0, 0, (0, 0, 1920, 1080)), (0, 0));
      expect(PhoneRemote.toScreen(1, 1, (0, 0, 1920, 1080)), (1919, 1079));
      expect(PhoneRemote.toScreen(0.5, 0.5, (-1920, 0, 1920, 1080)), (-961, 540)); // l'écran de gauche
      expect(PhoneRemote.shotSize(2560, 1440, 960), (960, 540));
      expect(PhoneRemote.shotSize(800, 600, 960), (800, 600));
    });
  });
}
