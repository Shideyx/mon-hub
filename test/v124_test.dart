import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/powershell.dart';
import 'package:hub/modules/carnet/carnet_store.dart';
import 'package:hub/modules/claude/claude_ai_sync.dart';
import 'package:hub/modules/music/media_session.dart';
import 'package:hub/ui/clicky/holo.dart';
import 'package:hub/ui/clicky/hud.dart';
import 'package:hub/ui/clicky/routines.dart';
import 'package:hub/ui/clicky/tutor.dart';

void main() {
  test('scripts PowerShell sans fichier : paramètres et encodage', () {
    final s = PowerShell.withParams("param([string]\$Path)\nWrite-Output \$Path\n", {'Path': "C:\\l'eau\\x.png"});
    expect(s, startsWith("\$Path = 'C:\\l''eau\\x.png'"));
    expect(s, isNot(contains('param(')));
    final bytes = base64Decode(PowerShell.encode('é'));
    expect(bytes, [0xE9, 0x00]);
    expect(PowerShell.firstError('+ CategoryInfo\nAccès refusé\n'), 'Accès refusé');
  });

  test('musique : titre de la fenêtre Spotify', () {
    final np = WindowsMediaSession.parseSpotifyTitle(['Spotify Premium', 'johnny5 - SETSUNA'])!;
    expect(np.artist, 'johnny5');
    expect(np.title, 'SETSUNA');
    expect(WindowsMediaSession.parseSpotifyTitle(['Spotify Free']), isNull);
  });

  test('hologramme : lecture et formes', () {
    final h = HoloScene.extract(
      'Regarde. [HOLO]{"titre":"Eau","objets":[{"forme":"sphère","pos":[0,0,0],"taille":0.5,"couleur":"rouge","label":"O"},'
      '{"forme":"boule","pos":[9,0,0]},{"forme":"inconnue"}],"liens":[[0,1],[0,7]]}[/HOLO]',
    );
    expect(h.$1, 'Regarde.');
    final s = h.$2!;
    expect(s.title, 'Eau');
    expect(s.objects.length, 2);
    expect(s.objects[1].pos.first, 4, reason: 'position bornée');
    expect(s.links, [(0, 1)]);
    for (final shape in [
      'cube',
      'sphere',
      'cylindre',
      'cone',
      'pyramide',
      'anneau',
      'tore',
      'helice',
      'axes',
      'fleche',
      'point',
    ]) {
      expect(holoSegments(HoloObject(shape: shape)), isNotEmpty, reason: shape);
    }
    expect(HoloScene.strip('a [HOLO]{"titre"'), 'a');
  });

  test('Smily vivant : petits mouvements bornés', () {
    for (var t = 0.0; t < 30; t += 0.37) {
      final o = aliveOffset(t);
      expect(o.dx.abs(), lessThan(20));
      expect(o.dy.abs(), lessThan(20));
    }
    expect(parseCommand('Smily, protocole travail'), (ClickyCommand.protocol, 'travail'));
    expect(Routine.templates().map((r) => r.name), contains('Bilan du soir'));
  });

  test('carnet : budget, sport, bilan, presse-papier, tenue', () async {
    final dir = await Directory.systemTemp.createTemp('carnet');
    HubFiles.overrideRoot = dir.path;
    try {
      final c = Carnet.instance;
      await c.load();
      await c.add('money', {'amount': -12.5, 'category': 'repas'});
      await c.add('money', {'amount': -7.5, 'category': 'jeux'});
      await c.add('money', {'amount': 20.0, 'category': 'revenu'});
      final (spent, earned, cats) = c.money(DateTime(2000));
      expect(spent, 20);
      expect(earned, 20);
      expect(cats['repas'], 12.5);
      await c.add('sport', {'exercise': 'squat', 'weight': 80.0, 'reps': 5});
      await c.add('sport', {'exercise': 'squat', 'weight': 85.0, 'reps': 3});
      final (best, last, n) = c.progress('Squat');
      expect(best, 85);
      expect(n, 2);
      expect(last!.data['reps'], 3);
      final t = await c.add('todos', {'text': 'Réviser maths'});
      await c.change('todos', t.id, {'done': true, 'doneAt': DateTime.now().millisecondsSinceEpoch});
      await c.add('memory', {'text': 'allergique aux noix'});
      expect(c.facts, ['allergique aux noix']);
      final recap = c.eveningRecap();
      expect(recap['taches_faites_aujourd_hui'], ['Réviser maths']);
      expect(recap['depenses_du_jour'], 20);
      expect(c.find('todos', 'maths')?.id, t.id);
      expect(c.protocols.keys, containsAll(['travail', 'nuit']));
    } finally {
      HubFiles.overrideRoot = null;
      await dir.delete(recursive: true);
    }
    expect(ClipboardVault.looksSecret('Xk9#mPq2!vL'), isTrue);
    expect(ClipboardVault.looksSecret('https://exemple.fr/page?id=3'), isFalse);
    expect(ClipboardVault.looksSecret('une phrase normale'), isFalse);
    final cold = Weather.outfit(min: 1, max: 4, rainChance: 80, wind: 10, code: 63);
    expect(cold, contains('manteau'));
    expect(cold, contains('parapluie'));
    expect(Weather.describe(95).$1, 'orage');
  });

  test('claude.ai : conversations importées', () {
    final threads = ClaudeAiSync.parse(
      jsonEncode([
        {
          'uuid': 'abc',
          'name': 'Exposé histoire',
          'created': '2026-11-10T10:00:00Z',
          'updated': '2026-11-10T10:05:00Z',
          'msgs': [
            {'s': 'human', 't': 'Aide-moi', 'at': '2026-11-10T10:00:00Z'},
            {'s': 'assistant', 't': 'Bien sûr', 'at': '2026-11-10T10:00:05Z'},
            {'s': 'assistant', 't': '', 'at': '2026-11-10T10:00:06Z'},
          ],
        },
        {'uuid': 'vide', 'name': '', 'msgs': []},
      ]),
    );
    expect(threads.length, 1);
    expect(threads.first.id, 'claudeai-abc');
    expect(threads.first.app, 'claude.ai');
    expect(threads.first.messages.map((m) => m.mine), [true, false]);
    expect(ClaudeAiSync.script(5), contains('chat_conversations?limit=5'));
  });
}
