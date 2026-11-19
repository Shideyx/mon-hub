import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/party.dart';
import 'package:hub/core/phone_link.dart';
import 'package:hub/modules/youtube/youtube_module.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final party = Party.instance;
  final client = HttpClient();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
    PhoneLink.lanOverride = '127.0.0.1';
    PhoneLink.instance.loadAsset = (p) async =>
        p == 'party/index.html' ? Uint8List.fromList(utf8.encode('<h1>Soirée</h1>')) : null;
    party.search = (q) async => [
      YtVideo('aaaaaaaaaaa', 'Son A', channel: 'Artiste A', length: '3:10'),
      YtVideo('bbbbbbbbbbb', 'Son B', channel: 'Artiste B', length: '2:50'),
    ];
    await party.start();
  });

  tearDown(() async {
    await party.stop();
    PhoneLink.lanOverride = null;
  });

  Future<(int, String)> call(String path, {String method = 'GET', String? body}) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${PhoneLink.instance.boundPort}$path'));
    req.followRedirects = false;
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  test('ordre : les plus votés d\'abord, puis l\'arrivée', () {
    party.add(PartySong(id: 'aaaaaaaaaaa', title: 'A', guest: 'g1'), 'g1');
    party.add(PartySong(id: 'bbbbbbbbbbb', title: 'B', guest: 'g2'), 'g2');
    party.add(PartySong(id: 'ccccccccccc', title: 'C', guest: 'g3'), 'g3');
    party.vote('ccccccccccc', 'g1');
    expect(party.upcoming.map((s) => s.title), ['C', 'A', 'B']);
    // Voter deux fois = retirer son vote.
    party.vote('ccccccccccc', 'g1');
    expect(party.upcoming.map((s) => s.title), ['A', 'B', 'C']);
    // Ajouter un son déjà là = un vote.
    party.add(PartySong(id: 'bbbbbbbbbbb', title: 'B', guest: 'g4'), 'g4');
    expect(party.upcoming.first.title, 'B');
    expect(party.next()!.title, 'B');
    expect(party.playing!.title, 'B');
    expect(party.queue.length, 2);
  });

  test('limites', () {
    expect(party.add(PartySong(id: 'pas-un-id', title: 'x'), 'g'), 'Son inconnu.');
    for (var i = 0; i < Party.maxPerGuest; i++) {
      expect(party.add(PartySong(id: 'abcdefghij$i', title: '$i', guest: 'g'), 'g'), isNull);
    }
    expect(party.add(PartySong(id: 'zzzzzzzzzzz', title: 'trop', guest: 'g'), 'g'), contains('déjà'));
    expect(Party.clean('<script>alert(1)</script>', 100), 'script alert(1) /script');
    expect(Party.clean('a' * 50, 20).length, 20);
  });

  test('le lien des invités', () async {
    final path = party.link!.path;
    expect(path, matches(RegExp(r'^/soiree/[0-9a-f]{24}/$')));
    expect(await call(path), (200, '<h1>Soirée</h1>'));
    expect((await call('/soiree/000000000000000000000000/')).$1, 404);
    // Le lien des invités ne donne pas accès au reste (fichiers, télécommande).
    expect((await call('${path}api/commande', method: 'POST', body: '{"action":"eteindre"}')).$1, 404);
    expect((await call('$path../t/x/api/etat')).$1, 404);

    final r = jsonDecode((await call('${path}api/chercher?invite=g1&q=son')).$2) as Map;
    expect((r['resultats'] as List).length, 2);
    final add = jsonDecode(
      (await call(
        '${path}api/ajouter?invite=g1',
        method: 'POST',
        body: jsonEncode({'id': 'aaaaaaaaaaa', 'titre': 'Son A', 'chaine': 'Artiste A', 'duree': '3:10', 'nom': 'Léa'}),
      )).$2,
    );
    expect(add['ok'], isTrue);
    await call('${path}api/voter?invite=g2', method: 'POST', body: '{"id":"aaaaaaaaaaa"}');
    final st = jsonDecode((await call('${path}api/etat?invite=g2')).$2) as Map;
    final song = (st['file'] as List).single as Map;
    expect(song['par'], 'Léa');
    expect(song['votes'], 2);
    expect(song['moi'], isTrue);

    // Fin de la soirée : le lien ne marche plus (et le serveur s'arrête
    // si « Mon téléphone » n'est pas activé).
    await party.stop();
    expect(PhoneLink.instance.running, isFalse);
    expect(party.link, isNull);
  });

  test('Clicky sans IA', () async {
    final calls = <String>[];
    Future<Object?> fake(String name, Map<String, dynamic> a) async {
      calls.add(name);
      return 'ok';
    }

    for (final q in ['Lance une soirée', 'mode soirée', 'lance la playlist de soirée']) {
      calls.clear();
      await QuickAnswers.answer(q, call: fake, tools: const {'soiree_ouvrir'});
      expect(calls, ['soiree_ouvrir'], reason: q);
    }
    calls.clear();
    await QuickAnswers.answer('c\'était bien la soirée ?', call: fake, tools: const {'soiree_ouvrir'});
    expect(calls, isEmpty);
  });
}
