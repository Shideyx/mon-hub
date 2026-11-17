import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/music/music_api.dart';
import 'package:hub/modules/schedule/schedule_module.dart';
import 'package:hub/ui/clicky/act.dart';
import 'package:hub/ui/clicky/buddies.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/neural_voice.dart';
import 'package:hub/ui/clicky/voice.dart';
import 'package:hub/ui/clicky/whisper.dart';

void main() {
  group('Clicky agit', () {
    test('lit une action, même entourée de texte', () {
      final s = ActStep.parse('Voilà : {"pense":"Je clique sur la barre","action":"clic","x":640,"y":52,"libelle":"Rechercher"} ok');
      expect(s, isNotNull);
      expect(s!.action, 'clic');
      expect(s.point!.$1, const Offset(640, 52));
      expect(s.thought, 'Je clique sur la barre');
      expect(s.describe, contains('Rechercher'));
      expect(ActStep.parse('{"action":"ecrire","texte":"un { dans le texte }"}')!.s('texte'), 'un { dans le texte }');
      expect(ActStep.parse('{"action":"fini","message":"C\'est fait."}')!.done, isTrue);
      expect(ActStep.parse('rien du tout'), isNull);
    });

    test('balise [AGIR] séparée de la réponse', () {
      final (text, goal) = ClickyController.extractAct('Je m\'en occupe. [AGIR]Ouvre YouTube et lance la vidéo de Karpathy[/AGIR]');
      expect(text, 'Je m\'en occupe.');
      expect(goal, 'Ouvre YouTube et lance la vidéo de Karpathy');
    });
  });

  test('secrétaire : créneaux libres entre les cours', () {
    final d = DateTime(2026, 11, 18);
    final slots = freeSlots(
      [
        (d.add(const Duration(hours: 8)), d.add(const Duration(hours: 12))),
        (d.add(const Duration(hours: 14)), d.add(const Duration(hours: 17))),
      ],
      from: d,
      days: 1,
    );
    expect(slots.single['libre'], ['12:00-14:00', '17:00-21:00']);
  });

  test('compagnons proposés par l\'IA', () {
    final list = Buddy.parseProposals('''Voici :
[{"nom":"Radar Devoirs","mission":"Je vais lister tes devoirs de la semaine","detail":"Pour ne rien oublier.","chaque_jour":true,"consignes":"Lis les devoirs…"},
 {"nom":"Coach Maths","mission":"Je vais te préparer 5 exercices"}]''');
    expect(list.map((b) => b.name), ['Radar Devoirs', 'Coach Maths']);
    expect(list.first.daily, isTrue);
    expect(list.last.prompt, 'Je vais te préparer 5 exercices');
    expect(list.first.color, isNot(list.last.color));
  });

  test('voix : durée d\'un WAV lue dans son en-tête', () {
    final pcm = Uint8List(24000 * 2); // 1 s à 24 kHz, 16 bits
    expect(ClickyVoice.wavDuration(GeminiVoice.wav(pcm)), const Duration(seconds: 1));
    expect(ClickyVoice.wavDuration(Uint8List.fromList([0xFF, 0xFB, 1, 2])), isNull);
  });

  test('Spotify : refus 403 expliqués', () {
    expect(SpotifyApi.explain403('Active premium subscription required for the owner of the app.'), contains('février 2026'));
    expect(SpotifyApi.isBlocked(SpotifyApi.explain403('Active premium subscription required for the owner of the app.')), isTrue);
    expect(SpotifyApi.explain403('Check settings on developer.spotify.com/dashboard, the user may not be registered.'), contains('User Management'));
  });

  test('micro par Gemini : transcription', () async {
    final dir = await Directory.systemTemp.createTemp('gem');
    addTearDown(() => dir.delete(recursive: true));
    final wav = File('${dir.path}/v.wav')..writeAsBytesSync(GeminiVoice.wav(Uint8List(3200)));
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map;
      final parts = ((body['contents'] as List).first as Map)['parts'] as List;
      expect((parts.last as Map)['inline_data']['mime_type'], 'audio/wav');
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Bonjour Clicky '},
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    expect(await GeminiTranscriber.transcribe(wav.path, 'cle', client: client), 'Bonjour Clicky');
  });

  test('espaces de travail École Directe', () {
    final w = EdWorkspace.fromJson({
      'id': 12,
      'titre': 'Club th&eacute;&acirc;tre',
      'description': '<p>R&eacute;p&eacute;titions le mardi</p>',
      'nbMembres': 18,
      'estMembre': false,
      'cloud': true,
    });
    expect(w.title, 'Club théâtre');
    expect(w.description, 'Répétitions le mardi');
    expect(w.member, isFalse);
    expect(w.members, 18);
  });
}
