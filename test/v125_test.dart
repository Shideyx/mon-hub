import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/updater.dart';
import 'package:hub/core/news.dart';
import 'package:hub/ui/clicky/neural_voice.dart';
import 'package:hub/ui/clicky/routines.dart';

void main() {
  test('actualités : lecture d\'un flux RSS', () {
    const xml = '''<rss><channel>
<item><title><![CDATA[Grève : les trains perturbés]]></title><description><![CDATA[<p>La SNCF prévoit &amp; annonce…</p>]]></description>
<pubDate>Tue, 17 Nov 2026 06:12:00 +0100</pubDate><link>https://exemple.fr/a</link></item>
<item><title>Sommet du G20</title><pubDate>Tue, 17 Nov 2026 05:00:00 GMT</pubDate></item>
</channel></rss>''';
    final l = News.parse(xml, 'franceinfo');
    expect(l.length, 2);
    expect(l.first.title, 'Grève : les trains perturbés');
    expect(l.first.summary, 'La SNCF prévoit & annonce…');
    expect(l.first.at!.toUtc(), DateTime.utc(2026, 11, 17, 5, 12));
    expect(l.last.at!.toUtc(), DateTime.utc(2026, 11, 17, 5));
    expect(l.first.toJson()['source'], 'franceinfo');
  });

  test('voix Gemini : son WAV', () {
    final w = GeminiVoice.wav(Uint8List.fromList([0, 0, 1, 0]));
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(w.length, 48);
  });

  test('topos : créés une fois, désactivables, rattrapage du matin jusqu\'à midi', () async {
    final dir = await Directory.systemTemp.createTemp('topos');
    HubFiles.overrideRoot = dir.path;
    try {
      final r = Routines.instance;
      await r.ensureTopos();
      expect(r.list.map((x) => x.id), containsAll(['topo-matin', 'topo-soir']));
      expect(r.topoOn('topo-matin'), isTrue);
      await r.setTopo('topo-matin', false);
      expect(r.topoOn('topo-matin'), isFalse);
      await r.remove('topo-soir');
      await r.ensureTopos();
      expect(r.list.any((x) => x.id == 'topo-soir'), isFalse, reason: 'pas recréé après suppression');
      expect(r.list.any((x) => x.id.startsWith('_')), isFalse);
    } finally {
      HubFiles.overrideRoot = null;
      await dir.delete(recursive: true);
    }
    final m = Routine.topoMorning();
    expect(m.isTopo, isTrue);
    expect(m.due(DateTime(2026, 11, 17, 6, 59)), isFalse);
    expect(m.due(DateTime(2026, 11, 17, 11, 30)), isTrue, reason: 'PC allumé tard');
    expect(m.due(DateTime(2026, 11, 17, 12, 30)), isFalse);
    expect(Routine.topoMorningPrompt, contains('actualites'));
    expect(Routine.topoMorningPrompt, contains('mails_lister'));
    expect(Routine.topoMorningPrompt, contains('ecole_devoirs'));
  });

  test('mise à jour : remplacement en place, sans script, avec retour en arrière', () async {
    final root = await Directory.systemTemp.createTemp('maj');
    try {
      final src = Directory('${root.path}/new')..createSync();
      final dst = Directory('${root.path}/app')..createSync();
      File('${dst.path}/hub.exe').writeAsStringSync('v1.24');
      File('${dst.path}/garde.txt').writeAsStringSync('mes données');
      Directory('${src.path}/data').createSync();
      File('${src.path}/hub.exe').writeAsStringSync('v1.25');
      File('${src.path}/data/app.so').writeAsStringSync('nouveau');
      await Updater.replaceInPlace(src.path, dst.path);
      expect(File('${dst.path}/hub.exe').readAsStringSync(), 'v1.25');
      expect(File('${dst.path}/data/app.so').readAsStringSync(), 'nouveau');
      expect(File('${dst.path}/garde.txt').readAsStringSync(), 'mes données');
      final aside = dst.listSync().whereType<File>().where((f) => f.path.contains(Updater.oldSuffix)).toList();
      expect(aside.length, 1, reason: 'ancien hub.exe mis de côté');
      expect(aside.single.readAsStringSync(), 'v1.24');
      // Source vide : erreur, rien n'est touché.
      final empty = Directory('${root.path}/vide')..createSync();
      await expectLater(Updater.replaceInPlace(empty.path, dst.path), throwsA(isA<String>()));
      expect(File('${dst.path}/hub.exe').readAsStringSync(), 'v1.25');
    } finally {
      await root.delete(recursive: true);
    }
  });
}
