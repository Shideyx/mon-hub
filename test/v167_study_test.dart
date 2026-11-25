import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/core/ai_text.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/ui/clicky/copy_check.dart';
import 'package:hub/ui/clicky/mind_map.dart';
import 'package:hub/ui/clicky/oral_coach.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/video_notes.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

const mapJson =
    '{"titre":"La photosynthèse","enfants":[{"titre":"Où ?","detail":"Dans les chloroplastes.","enfants":[{"titre":"Feuilles"},{"titre":"Chlorophylle"}]},'
    '{"titre":"Équation","detail":"6 CO2 + 6 H2O → glucose + 6 O2"},{"titre":"Lumière","enfants":[{"titre":"Phase claire","enfants":[{"titre":"ATP","enfants":[{"titre":"trop profond"}]}]}]}]}';

void main() {
  tearDown(() => AiText.override = null);

  group('Correction de copie', () {
    test('positions remises dans l\'ordre et bornées', () {
      final r = CopyCheck.parse(
        '```json\n{"note_sur_20": 13.5, "resume": "Bien.", "fautes": ['
        '{"box_2d": [120, 300, 150, 420], "type": "accord", "faux": "les chat", "correction": "les chats", "explication": "pluriel"},'
        '{"box_2d": [500, 900, 450, 1200], "type": "orthographe", "faux": "sa", "correction": "ça", "explication": "cela"},'
        '{"box_2d": [10, 10, 10, 10], "type": "x"},'
        '{"box_2d": "pas une liste"}], "points_forts": ["Plan clair"], "conseils": ["Relis les accords"]}\n```',
      )!;
      expect(r.grade, 13.5);
      expect(r.mistakes, hasLength(2));
      expect(r.mistakes[0].box, [0.12, 0.3, 0.15, 0.42]);
      expect(r.mistakes[1].box, [0.45, 0.9, 0.5, 1.0]);
      expect(r.good, ['Plan clair']);
      expect(CopyCheck.parse('{"note_sur_20": 42, "fautes": []}')!.grade, isNull);
      expect(CopyCheck.parse('je ne peux pas'), isNull);
      expect(CopyCheck.prompt('Maths'), contains('calcul'));
    });

    testWidgets('la page entoure les fautes', (t) async {
      final dir = Directory.systemTemp.createTempSync('copie');
      final f = File('${dir.path}/copie.png')..writeAsBytesSync(img.encodePng(img.Image(width: 400, height: 300)));
      AiText.override = (p, s) async =>
          '{"note_sur_20": 12, "resume": "Quelques fautes.", "fautes": ['
          '{"box_2d": [100, 100, 200, 400], "type": "accord", "faux": "ils mange", "correction": "ils mangent", "explication": "3e pers. du pluriel"}]}';
      await t.binding.setSurfaceSize(const Size(1200, 800));
      await t.runAsync(() async {
        await t.pumpWidget(MaterialApp(home: CopyCheckPage(path: f.path)));
        for (var i = 0; i < 30 && find.textContaining('ils mangent').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await t.pump();
        }
      });
      expect(find.textContaining('ils mangent'), findsOneWidget);
      expect(find.textContaining('12 / 20'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
    });
  });

  group('Coach d\'oral', () {
    test('tics, débit, conseils', () {
      final f = OralCoach.fillers('Alors euh, du coup, euh le climat, en fait c\'est important quoi. Genre vraiment.');
      expect(f['euh'], 2);
      expect(f['du coup'], 1);
      expect(f['en fait'], 1);
      expect(f['quoi'], 1);
      expect(f['genre'], 1);
      expect(OralCoach.fillers('Le quoi de la question'), isNot(contains('quoi')));
      expect(OralCoach.wpm(List.filled(300, 'mot').join(' '), const Duration(minutes: 2)), 150);
      expect(OralCoach.paceAdvice(190), contains('Trop rapide'));
      expect(OralCoach.paceAdvice(140), contains('Bon rythme'));
    });

    test('Gemini écoute l\'audio et le rapport est lu', () async {
      final dir = Directory.systemTemp.createTempSync('oral');
      final wav = File('${dir.path}/a.wav')..writeAsBytesSync([1, 2, 3, 4]);
      late Map body;
      final c = MockClient((r) async {
        body = jsonDecode(r.body) as Map;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            '{"note_sur_20": 14, "resume": "Clair.", "transcription": "Bonjour euh je vais parler du climat. Euh voilà.", '
                            '"points_forts": ["Voix posée"], "a_ameliorer": ["Annonce ton plan"], "oublis_du_plan": ["Conclusion"], '
                            '"questions_du_jury": ["Pourquoi ce sujet ?", "Et ensuite ?"]}',
                      },
                    ],
                  },
                },
              ],
            }),
          ),
          200,
        );
      });
      final answer = await OralCoach.listen(wav.path, 'consigne', 'cle', client: c);
      final parts = ((body['contents'] as List).first as Map)['parts'] as List;
      expect((parts.first as Map)['inline_data']['mime_type'], 'audio/wav');
      final r = OralCoach.parse(answer, transcript: '', length: const Duration(seconds: 30), pauses: 2)!;
      expect(r.grade, 14);
      expect(r.fillerWords['euh'], 2);
      expect(r.missing, ['Conclusion']);
      expect(r.questions, hasLength(2));
      expect(r.pauses, 2);
      expect(r.wpm, 18);
    });
  });

  group('Vidéo → fiche', () {
    test('liens et minutes', () {
      expect(VideoNotes.videoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10'), 'dQw4w9WgXcQ');
      expect(VideoNotes.videoId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(VideoNotes.videoId('https://www.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(VideoNotes.videoId('pas un lien'), isNull);
      expect(VideoNotes.seconds('12:34'), 754);
      expect(VideoNotes.seconds('1:02:03'), 3723);
      expect(VideoNotes.seconds(90), 90);
      expect(VideoNotes.clock(3723), '1:02:03');
    });

    test('fiche lue et vérifiée', () {
      final s = VideoNotes.parse(
        '{"titre":"La Révolution","resume":"Résumé.","chapitres":['
        '{"debut":"5:00","titre":"Causes","points":["Crise"]},{"debut":"0:30","titre":"Intro"}],'
        '"a_retenir":["1789"],"quiz":[{"question":"Quand ?","choix":["1789","1815"],"bonne":0,"explication":"Prise de la Bastille"},'
        '{"question":"Faux","choix":["a","b"],"bonne":5}]}',
      )!;
      expect(s.chapters.map((c) => c.title), ['Intro', 'Causes']);
      expect(s.chapters.first.seconds, 30);
      expect(s.quiz, hasLength(1));
      expect(s.markdown('https://y'), contains('### 5:00 — Causes'));
    });

    test('sous-titres de la vidéo', () async {
      final c = MockClient((r) async {
        if (r.url.path == '/watch') {
          return http.Response(
            '<script>var x = {"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc\\u0026lang=fr","languageCode":"fr"}],"y":1};</script>',
            200,
          );
        }
        expect(r.url.queryParameters['fmt'], 'json3');
        return http.Response(
          jsonEncode({
            'events': [
              {
                'tStartMs': 0,
                'segs': [
                  {'utf8': 'Bonjour à tous'},
                ],
              },
              {
                'tStartMs': 65000,
                'segs': [
                  {'utf8': 'Deuxième partie'},
                ],
              },
            ],
          }),
          200,
        );
      });
      final t = await VideoNotes.captions('dQw4w9WgXcQ', client: c);
      expect(t, '[0:00] Bonjour à tous\n[1:05] Deuxième partie');
    });
  });

  group('Carte mentale', () {
    test('arbre lu, 3 niveaux au plus, branches', () {
      final r = MindMaps.parse(mapJson)!;
      expect(r.title, 'La photosynthèse');
      expect(r.children, hasLength(3));
      expect(r.children[0].children[1].parent, r.children[0]);
      expect(r.children[2].children[0].branch, 2);
      // « trop profond » (4e niveau) est coupé.
      expect(r.children[2].children[0].children[0].children, isEmpty);
      expect(r.markdown(), contains('- **Équation** : 6 CO2'));
      expect(MindMaps.parse('{"titre":"Seul"}'), isNull);
    });

    test('disposition en cercles', () {
      final r = MindMaps.parse(mapJson)!;
      expect(MindMaps.layout(r).length, 1);
      r.open = true;
      r.children[0].open = true;
      final pos = MindMaps.layout(r);
      expect(pos.length, 1 + 3 + 2);
      expect(pos[r.children[0]]!.distance, closeTo(240, 0.01));
      expect(pos[r.children[0].children[0]]!.distance, closeTo(440, 0.01));
    });

    testWidgets('la carte se déplie', (t) async {
      AiText.override = (p, s) async => mapJson;
      await t.binding.setSurfaceSize(const Size(1200, 900));
      await t.pumpWidget(const MaterialApp(home: MindMapPage(input: 'la photosynthèse')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pumpAndSettle();
      expect(find.text('Où ?'), findsOneWidget);
      expect(find.text('Feuilles'), findsNothing);
      await t.tap(find.text('Où ?').first);
      await t.pumpAndSettle();
      expect(find.text('Feuilles'), findsOneWidget);
      expect(find.text('Dans les chloroplastes.'), findsOneWidget);
      await t.tap(find.text('Où ?').first);
      await t.pumpAndSettle();
      expect(find.text('Feuilles'), findsNothing);
    });
  });

  group('Nexo', () {
    test('phrases sans IA', () async {
      final calls = <String>[];
      Future<Object?> fake(String name, Map<String, dynamic> a) async {
        calls.add('$name ${a['sujet'] ?? ''}'.trim());
        return 'ok';
      }

      const tools = {'copie_corriger', 'oral_coach', 'carte_mentale'};
      for (final (q, want) in [
        ('Corrige ma rédaction', 'copie_corriger'),
        ('corrige ma copie', 'copie_corriger'),
        ('entraîne-moi pour mon grand oral', 'oral_coach'),
        ('coach d\'oral', 'oral_coach'),
        ('Fais-moi une carte mentale sur la Révolution française', 'carte_mentale La Révolution française'),
      ]) {
        calls.clear();
        await QuickAnswers.answer(q, call: fake, tools: tools);
        expect(calls, [want], reason: q);
      }
      calls.clear();
      await QuickAnswers.answer('c\'est quoi une carte mentale ?', call: fake, tools: tools);
      expect(calls, isEmpty);
    });

    test('Claude reçoit les outils', () {
      expect(ToolRouter.groupsFor('aide moi à répéter mon exposé'), contains('etudes'));
      expect(ToolRouter.groupOf('video_fiche'), 'etudes');
    });
  });
}
