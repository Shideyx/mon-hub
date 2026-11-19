import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/ar_server.dart';
import 'package:hub/core/hologram.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  group('Hologrammes : objets reconnus', () {
    test('objets prêts', () {
      expect(Hologram.match('un T-rex'), 'dino');
      expect(Hologram.match('Affiche un dinosaure'), 'dino');
      expect(Hologram.match('le cœur'), 'coeur');
      expect(Hologram.match('Saturne'), 'planete');
      expect(Hologram.match('le système solaire'), 'systeme');
      expect(Hologram.match('des planètes'), 'systeme');
      expect(Hologram.match('une fusée'), 'fusee');
      expect(Hologram.match('un rubik'), 'cube');
    });

    test('le reste est à inventer', () {
      expect(Hologram.match('une voiture de course'), isNull);
      expect(Hologram.match('un bonhomme de neige'), isNull);
      expect(Hologram.match('une courgette'), isNull);
    });
  });

  group('Hologrammes : recette de l\'IA vérifiée', () {
    test('texte autour, valeurs nettoyées', () {
      final r = Hologram.parse(
        'Voici :\n```json\n{"nom":"Bonhomme de neige","pieces":['
        '{"forme":"sphere","couleur":"#ffffff","pos":[0,0.5,0],"taille":[1,1,1],"matiere":"mat"},'
        '{"forme":"Sphère","couleur":"rouge","pos":[0,99999,0],"taille":[-5,1,"x"],"rot":[0,720,0]},'
        '{"forme":"<script>alert(1)</script>","couleur":"#000000"},'
        '"pas une pièce"'
        ']}\n```',
      );
      expect(r, isNotNull);
      expect(r!['nom'], 'Bonhomme de neige');
      final pieces = r['pieces'] as List;
      expect(pieces, hasLength(2));
      expect(pieces[1]['forme'], 'sphere');
      expect(pieces[1]['couleur'], '#cccccc');
      expect(pieces[1]['pos'], [0, 10, 0]);
      expect(pieces[1]['taille'], [0.005, 1, 0.2]);
      expect(pieces[1]['rot'], [0, 360, 0]);
      expect(pieces[1]['matiere'], 'mat');
    });

    test('trop de pièces, pas de JSON', () {
      final many = jsonEncode({
        'nom': 'x' * 80,
        'pieces': [
          for (var i = 0; i < 200; i++) {'forme': 'boite'},
        ],
      });
      final r = Hologram.parse(many)!;
      expect((r['pieces'] as List).length, Hologram.maxPieces);
      expect((r['nom'] as String).length, 40);
      expect(Hologram.parse('Je ne sais pas faire ça.'), isNull);
      expect(Hologram.parse('{"pieces": []}'), isNull);
    });

    test('la consigne demande du JSON avec les formes connues', () {
      final p = Hologram.prompt('une voiture');
      expect(p, contains('« une voiture »'));
      for (final f in Hologram.shapes) {
        expect(p, contains(f));
      }
    });
  });

  group('Hologrammes : Clicky sans IA', () {
    final calls = <Map<String, dynamic>>[];
    Future<Object?> fake(String name, Map<String, dynamic> args) async {
      calls.add({'name': name, ...args});
      return 'ok';
    }

    Future<Map<String, dynamic>?> ask(String q) async {
      calls.clear();
      await QuickAnswers.answer(q, call: fake, tools: const {'ar_afficher'});
      return calls.where((c) => c['name'] == 'ar_afficher').firstOrNull;
    }

    test('phrases reconnues', () async {
      expect(await ask('Affiche-moi un T-rex en 3D'), {'name': 'ar_afficher', 'objet': 't rex', 'mode': 'air'});
      expect(await ask('Clicky, fais un hologramme de voiture sur ma main'), {
        'name': 'ar_afficher',
        'objet': 'voiture',
        'mode': 'main',
      });
      expect(await ask('fais apparaître une fusée en hologramme sur la table'), {
        'name': 'ar_afficher',
        'objet': 'fusee',
        'mode': 'table',
      });
      expect(await ask('ouvre la réalité augmentée'), {'name': 'ar_afficher', 'objet': '', 'mode': 'air'});
      expect(await ask('montre-moi un dinosaure en vrai'), {
        'name': 'ar_afficher',
        'objet': 'dinosaure',
        'mode': 'air',
      });
    });

    test('les vraies questions partent vers l\'IA', () async {
      expect(await ask('comment marche la 3D dans les jeux vidéo ?'), isNull);
      expect(await ask('c\'est quoi un hologramme ?'), isNull);
      expect(await ask('affiche mes devoirs'), isNull);
    });

    test('Claude reçoit l\'outil quand on parle de 3D', () {
      expect(ToolRouter.groupsFor('mets un dragon en 3D'), contains('hologrammes'));
      expect(ToolRouter.groupOf('ar_afficher'), 'hologrammes');
    });
  });

  group('Réalité augmentée : serveur local', () {
    late ArServer server;
    late Directory dir;
    final client = HttpClient();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ar_test');
      server = ArServer(
        loadAsset: (p) async => p == 'index.html'
            ? Uint8List.fromList(utf8.encode('<h1>AR</h1>'))
            : p == 'vendor/three.min.js'
            ? Uint8List.fromList(utf8.encode('export {}'))
            : null,
        dataDir: dir,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    Future<(int, String, String)> get(String path, {String? host, String method = 'GET'}) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (host != null) req.headers.host = host;
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return (res.statusCode, res.headers.contentType?.mimeType ?? '', body);
    }

    test('sert la page, rien d\'autre', () async {
      expect(await get('/'), (200, 'text/html', '<h1>AR</h1>'));
      expect((await get('/vendor/three.min.js')).$2, 'text/javascript');
      expect((await get('/inconnu.js')).$1, 404);
      expect((await get('/%2e%2e/pubspec.yaml')).$1, 404);
      expect((await get('/mp/../../secret.txt')).$1, 404);
      expect((await get('/mp/autre.wasm')).$1, 404);
      expect((await get('/mp/vision_bundle.mjs')).$1, 404); // pas encore téléchargé
    });

    test('refuse les autres noms d\'hôte (pages web malveillantes)', () async {
      expect((await get('/', host: 'evil.example')).$1, 403);
      expect((await get('/', host: 'localhost')).$1, 200);
    });

    test('état de la vision des mains', () async {
      final (code, type, body) = await get('/mp/status');
      expect(code, 200);
      expect(type, 'application/json');
      final s = jsonDecode(body) as Map;
      expect(s['ready'], false);
      expect(s['total'], ArServer.packageSize + ArServer.modelSize);
    });

    test('chemins acceptés', () {
      expect(ArServer.safeAsset('ar.js'), isTrue);
      expect(ArServer.safeAsset('vendor/three.min.js'), isTrue);
      expect(ArServer.safeAsset('../x.js'), isFalse);
      expect(ArServer.safeAsset('a/../b.js'), isFalse);
      expect(ArServer.safeAsset('index.exe'), isFalse);
      expect(ArServer.safeAsset('C:/x.js'), isFalse);
      expect(ArServer.typeOf('wasm/vision_wasm_internal.wasm'), 'application/wasm');
    });

    test('un paquet abîmé est refusé', () {
      expect(() => ArServer.extractPackage(Uint8List.fromList([1, 2, 3])), throwsA(anything));
    });

    test('la page est dans les ressources de l\'appli', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/ar/'));
      expect(pubspec, contains('- assets/ar/vendor/'));
      for (final f in [
        'index.html',
        'ar.js',
        'ar.css',
        'objects.js',
        'track.js',
        'holo.js',
        'vendor/three.min.js',
        'vendor/aruco.js',
      ]) {
        expect(File('assets/ar/$f').existsSync(), isTrue, reason: f);
        expect(ArServer.safeAsset(f), isTrue, reason: f);
      }
    });
  });
}
