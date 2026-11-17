import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:material_ui/material_ui.dart' show Offset, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/core/hub_files.dart';
import 'package:hub/core/updater.dart';
import 'package:hub/modules/discord/discord_api.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/instagram/instagram_module.dart';
import 'package:hub/ui/chat_history.dart';
import 'package:hub/ui/clicky/documents.dart';
import 'package:hub/ui/clicky/drive.dart';
import 'package:hub/ui/clicky/ears.dart';
import 'package:hub/ui/clicky/extensions.dart';
import 'package:hub/ui/clicky/hud.dart';
import 'package:hub/ui/clicky/journal.dart';
import 'package:hub/ui/clicky/marks.dart';
import 'package:hub/ui/clicky/pointer.dart';
import 'package:hub/ui/clicky/routines.dart';
import 'package:hub/ui/clicky/tutor.dart';
import 'package:hub/ui/clicky/voice.dart';

void main() {
  group('Clicky : dessins et étapes', () {
    test('annotations lues et retirées du texte', () {
      final (text, marks) = ClickyMark.extract(
        'Regarde ici [ARROW:10,20->110,220:le menu] puis là [CIRCLE:50,60,30:Fichier] '
        '[UNDERLINE:5,90,200] [LABEL:300,40:Titre:screen2] fin.',
      );
      expect(text, 'Regarde ici puis là fin.');
      expect(marks.map((m) => m.kind), [
        MarkKind.arrow,
        MarkKind.circle,
        MarkKind.underline,
        MarkKind.label,
      ]);
      expect(marks[0].a, const Offset(10, 20));
      expect(marks[0].b, const Offset(110, 220));
      expect(marks[0].text, 'le menu');
      expect(marks[1].size, 30);
      expect(marks[1].text, 'Fichier');
      expect(marks[2].size, 200);
      expect(marks[3].text, 'Titre');
      expect(marks[3].screen, 2);
      final moved = marks[1].map((p) => p * 2, 2);
      expect(moved.a, const Offset(100, 120));
      expect(moved.size, 60);
    });

    test('leçon découpée en étapes, balises retirées pendant l\'écriture', () {
      final steps = splitSteps(
        'Ouvre Fichier. [POINT:1,2:Fichier][ETAPE] Clique sur Exporter.[ÉTAPE]Fini !',
      );
      expect(steps, ['Ouvre Fichier. [POINT:1,2:Fichier]', 'Clique sur Exporter.', 'Fini !']);
      expect(splitSteps('Une seule réponse.'), ['Une seule réponse.']);
      expect(
        stripClickyTags(
          'Voilà [POINT:1,2:x] [CIRCLE:1,2,3] [ACTIONS]{"etapes":[]}[/ACTIONS] et [POI',
        ),
        'Voilà et',
      );
    });
  });

  group('Clicky : commandes vocales', () {
    test('commandes reconnues', () {
      expect(parseCommand('Suivant')?.$1, ClickyCommand.next);
      expect(parseCommand('Clicky, continue')?.$1, ClickyCommand.next);
      expect(parseCommand('répète')?.$1, ClickyCommand.repeat);
      expect(parseCommand('Stop !')?.$1, ClickyCommand.stop);
      expect(parseCommand('Qu\'est-ce qu\'on a vu aujourd\'hui ?')?.$1, ClickyCommand.today);
      expect(parseCommand('qu\'est-ce qu\'on a appris cette semaine')?.$1, ClickyCommand.week);
      expect(parseCommand('Qu\'est-ce que je dois réviser ?')?.$1, ClickyCommand.review);
      expect(parseCommand('Interroge-moi sur les fractions')?.$2, 'sur les fractions');
      expect(parseCommand('Qu\'est-ce que je viens de faire ?')?.$1, ClickyCommand.whatDidIDo);
      expect(parseCommand('Fais-moi le point')?.$1, ClickyCommand.briefing);
      expect(parseCommand('change de voix pour Paul')?.$2, 'paul');
      expect(parseCommand('Explique-moi la photosynthèse'), isNull);
      expect(parseCommand('stop la musique'), isNull);
    });

    test('vie privée, mode code, appli, langue', () {
      expect(isSensitiveTitle('Bitwarden - Coffre'), isTrue);
      expect(isSensitiveTitle('Ma Banque - Mes comptes'), isTrue);
      expect(isSensitiveTitle('Exposé - Word'), isFalse);
      expect(isCodeEditorTitle('main.dart - mon-hub - Visual Studio Code'), isTrue);
      expect(isCodeEditorTitle('YouTube - Google Chrome'), isFalse);
      expect(appFromTitle('Exposé histoire - Word'), 'Word');
      expect(appFromTitle('Mon Hub'), 'Mon Hub');
      expect(detectLanguage('Comment est-ce que je fais une division ?'), 'fr-FR');
      expect(detectLanguage('How do I export this video to my phone?'), 'en-US');
      expect(wantsOcr('Lis-moi ce qui est écrit en petit'), isTrue);
      expect(wantsWeb('Quelle est la météo aujourd\'hui ?'), isTrue);
    });

    test('raccourcis vocaux', () {
      final list = [
        VoiceSkill('ouvre youtube', 'url', 'https://youtube.com'),
        VoiceSkill('mode revision', 'ask', 'Quiz'),
      ];
      expect(VoiceSkill.match('Clicky, ouvre YouTube', list)?.$1.value, 'https://youtube.com');
      expect(VoiceSkill.match('Mode révision maths', list)?.$2, 'maths');
      expect(VoiceSkill.match('ouvre la porte', list), isNull);
    });
  });

  test('journal : répétition espacée', () {
    final now = DateTime(2026, 11, 16, 10);
    expect(Journal.schedule(0, true, now), (1, now.add(const Duration(days: 3))));
    expect(Journal.schedule(5, true, now).$1, 6);
    expect(Journal.schedule(6, true, now), (6, now.add(const Duration(days: 120))));
    expect(Journal.schedule(4, false, now), (0, now.add(const Duration(days: 1))));
    expect(
      Journal.worthKeeping('merci', 'De rien, avec plaisir de t\'aider aujourd\'hui !'),
      isFalse,
    );
    expect(
      Journal.worthKeeping(
        'Comment marche la photosynthèse ?',
        'Les plantes captent la lumière et le CO2 pour fabriquer du sucre et rejeter de l\'oxygène.',
      ),
      isTrue,
    );
    expect(
      Journal.topicOf('Comment calculer une moyenne pondérée en maths ?', 'Moyenne pondérée'),
      'Moyenne pondérée',
    );
  });

  test('routines : l\'heure venue, une seule fois', () {
    final r = Routine(
      id: '1',
      name: 'Briefing',
      prompt: 'x',
      every: 'weekdays',
      hour: 7,
      minute: 10,
    );
    final monday = DateTime(2026, 11, 16, 7, 12);
    expect(r.due(DateTime(2026, 11, 16, 7, 0)), isFalse);
    expect(r.due(monday), isTrue);
    r.lastRun = monday;
    expect(r.due(DateTime(2026, 11, 16, 9)), isFalse);
    expect(r.due(DateTime(2026, 11, 17, 7, 11)), isTrue);
    expect(r.due(DateTime(2026, 11, 21, 7, 11)), isFalse, reason: 'pas le samedi');
    final hourly = Routine(id: '2', name: 'h', prompt: 'x', every: 'hourly', lastRun: monday);
    expect(hourly.due(monday.add(const Duration(minutes: 30))), isFalse);
    expect(hourly.due(monday.add(const Duration(minutes: 61))), isTrue);
    final back = Routine.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map);
    expect(back.lastRun, monday);
    expect(back.when, 'En semaine à 07:10');
  });

  test('pilotage : plan lu et décrit', () {
    final (text, plan) = DrivePlan.extract(
      'Je vais enregistrer. [ACTIONS]{"but":"Enregistrer","etapes":[{"type":"clic","x":10,"y":20,"libelle":"Fichier"},'
      '{"type":"touches","touches":"ctrl+s"},{"type":"ecrire","texte":"bonjour"},{"type":"inconnu"}]}[/ACTIONS]',
    );
    expect(text, 'Je vais enregistrer.');
    expect(plan!.steps.length, 3);
    expect(plan.steps.first.describe, 'Clic sur « Fichier »');
    expect(plan.steps[1].describe, 'Appuyer sur ctrl+s');
    expect(plan.expired, isFalse);
    expect(DrivePlan.extract('rien').$2, isNull);
  });

  test('pointage précis : zone et case de la grille', () {
    final z = PrecisePointer.zone(const Offset(10, 10), 1000, 800);
    expect(z, const Rect.fromLTWH(0, 0, 280, 280));
    final c = PrecisePointer.cellCenter('C’est la case B3.', const Rect.fromLTWH(100, 100, 60, 60));
    expect(c, const Offset(125, 115));
    expect(PrecisePointer.cellCenter('aucune', z), isNull);
  });

  test('documents : Word et Excel lus', () async {
    List<int> zip(Map<String, String> files) {
      final a = Archive();
      for (final e in files.entries) {
        final b = utf8.encode(e.value);
        a.addFile(ArchiveFile(e.key, b.length, b));
      }
      return ZipEncoder().encode(a);
    }

    final docx = zip({
      'word/document.xml':
          '<w:document><w:body><w:p><w:r><w:t>Le cycle de l&apos;eau</w:t></w:r></w:p>'
          '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Étape</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Pluie</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
          '</w:body></w:document>',
    });
    final d = await ClickyDoc.read('cours.docx', docx);
    expect(d.text, contains('Le cycle de l\'eau'));
    expect(d.text, contains('Étape | Pluie'));
    final xlsx = zip({
      'xl/sharedStrings.xml': '<sst><si><t>Maths</t></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><f>SUM(C1:C2)</f><v>15</v></c></row></sheetData></worksheet>',
    });
    final x = await ClickyDoc.read('notes.xlsx', xlsx);
    expect(x.text, contains('A1=Maths'));
    expect(x.text, contains('B1=15 (formule =SUM(C1:C2))'));
    final txt = await ClickyDoc.read('a.md', utf8.encode('# Titre'));
    expect(txt.blocks().last['text'], '# Titre');
    final img = await ClickyDoc.read('photo.jpg', [1, 2, 3]);
    expect(img.blocks().last['type'], 'image');
  });

  test('MCP : réponse JSON ou flux SSE', () {
    expect(McpClient.parseResponse('{"jsonrpc":"2.0","id":3,"result":{"ok":1}}', 3)?['result'], {
      'ok': 1,
    });
    expect(
      McpClient.parseResponse(
        'event: message\ndata: {"jsonrpc":"2.0","id":4,"result":{"tools":[]}}\n\n',
        4,
      )?['result'],
      {'tools': []},
    );
    expect(McpServer.validUrl('https://exemple.fr/mcp'), isTrue);
    expect(McpServer.validUrl('http://localhost:3000/mcp'), isTrue);
    expect(McpServer.validUrl('http://exemple.fr/mcp'), isFalse);
  });

  test('historique des conversations enregistré sur le disque', () async {
    final dir = await Directory.systemTemp.createTemp('hub-history');
    HubFiles.overrideRoot = dir.path;
    try {
      final h = ChatHistory('test-chats.json');
      await h.add('t1', ChatMsg(mine: true, text: 'Comment faire une fraction ?'));
      await h.add('t1', ChatMsg(mine: false, text: 'On coupe une pizza en parts égales…'));
      await h.add('t2', ChatMsg(mine: true, text: 'Autre sujet'), app: 'Word');
      final again = ChatHistory('test-chats.json');
      final list = await again.load();
      expect(list.map((t) => t.id).toSet(), {'t1', 't2'});
      expect(again.byId('t1')!.label, 'Comment faire une fraction ?');
      expect(again.byId('t2')!.app, 'Word');
      expect(again.byId('t1')!.matches('pizza'), isTrue);
      await again.rename('t1', 'Fractions');
      await again.togglePin('t1');
      expect(again.threads.first.title, 'Fractions');
      await again.remove('t2');
      expect((await ChatHistory('test-chats.json').load()).length, 1);
      expect(ChatHistory.export(again.byId('t1')!), contains('**Claude**'));
    } finally {
      HubFiles.overrideRoot = null;
      await dir.delete(recursive: true);
    }
    expect(historySection(DateTime(2026, 11, 16, 8), DateTime(2026, 11, 16, 20)), 'Aujourd\'hui');
    expect(historySection(DateTime(2026, 11, 15), DateTime(2026, 11, 16)), 'Hier');
    expect(historySection(DateTime(2026, 9, 1), DateTime(2026, 11, 16)), 'Plus ancien');
  });

  test('voix : bip de Clicky et salutation', () {
    final wav = ClickyChime.wav();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(clickyGreeting('Erik', DateTime(2026, 11, 16, 8)), startsWith('Bonjour Erik.'));
    expect(clickyGreeting('', DateTime(2026, 11, 16, 20)), startsWith('Bonsoir.'));
    expect(clickyPersona('Erik'), contains('« Erik »'));
    expect(clickyPersona('Erik'), contains('Clicky'));
  });

  group('messages vocaux et likes', () {
    test('Instagram : vocal, ❤️ et réactions', () {
      final m = IgMessage.fromJson({
        'item_id': '1',
        'user_id': '7',
        'item_type': 'voice_media',
        'timestamp': '1763290000000000',
        'voice_media': {
          'media': {
            'audio': {
              'audio_src': 'https://cdn/x.mp4',
              'duration': 4370,
              'waveform_data': [0.1, 0.5],
            },
          },
        },
        'reactions': {
          'likes': [
            {'sender_id': 9},
          ],
          'emojis': [
            {'sender_id': 7, 'emoji': '😂'},
          ],
        },
      });
      expect(m.isVoice, isTrue);
      expect(m.audioLength, const Duration(milliseconds: 4370));
      expect(m.waveform, [0.1, 0.5]);
      expect(m.reactions, [('❤️', '9'), ('😂', '7')]);
      final like = IgMessage.fromJson({
        'item_id': '2',
        'user_id': '7',
        'item_type': 'like',
        'timestamp': '0',
      });
      expect(like.isLike, isTrue);
      final a = IgActivity.fromJson({
        'story_type': 60,
        'args': {
          'rich_text': '{lea|000000|1|user?id=1} a aimé ta publication.',
          'timestamp': 1763290000.5,
        },
      });
      expect(a.text, 'lea a aimé ta publication.');
      expect(a.isLike, isTrue);
    });

    test('Discord : vocal et réactions', () {
      final m = DiscordMessage.fromJson({
        'id': '1',
        'author': {'id': '2', 'username': 'lea'},
        'content': '',
        'timestamp': '2026-11-16T10:00:00Z',
        'flags': 8192,
        'attachments': [
          {
            'url': 'https://cdn.discordapp.com/voice-message.ogg',
            'filename': 'voice-message.ogg',
            'content_type': 'audio/ogg',
            'duration_secs': 3.5,
            'waveform': base64.encode([0, 255, 128]),
          },
        ],
        'reactions': [
          {
            'emoji': {'name': '❤️'},
            'count': 2,
            'me': true,
          },
          {
            'emoji': {'name': 'pepe', 'id': '123'},
            'count': 1,
            'me': false,
          },
        ],
      });
      expect(m.isVoice, isTrue);
      expect(m.audioLength, const Duration(milliseconds: 3500));
      expect(m.waveform.length, 3);
      expect(m.preview, '🎤 Message vocal');
      expect(m.content, '');
      expect(m.reactions.first.count, 2);
      expect(m.reactions.last.apiKey, 'pepe:123');
      expect(m.reactions.last.label, ':pepe:');
    });
  });

  test('École Directe : messagerie d\'un compte parent (familles) et messages envoyés', () async {
    final paths = <String>[];
    final client = MockClient((req) async {
      paths.add('${req.method} ${req.url.path}');
      if (req.method == 'GET') return http.Response('', 200);
      if (req.url.path.endsWith('login.awp')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'token': 't',
            'data': {
              'accounts': [
                {
                  'id': 900,
                  'typeCompte': '1',
                  'anneeScolaireCourante': '2026-2027',
                  'profile': {
                    'eleves': [
                      {'id': 42, 'prenom': 'Erik', 'nom': 'M'},
                    ],
                  },
                },
              ],
            },
          }),
          200,
        );
      }
      final data = jsonDecode(Uri.splitQueryString(req.body)['data']!) as Map;
      expect(data['anneeMessages'], '2026-2027');
      if (req.url.path.endsWith('/messages.awp')) {
        expect(req.url.queryParameters['getAll'], '1');
        final folder = req.url.queryParameters['typeRecuperation']!;
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {
              'messages': {
                folder: [
                  {
                    'id': '7',
                    'subject': 'Sortie',
                    'date': '2026-11-10 10:00:00',
                    'read': false,
                    'from': {'name': 'Mme Dupont', 'id': 3, 'role': 'P'},
                    'to': [
                      {'prenom': 'Paul', 'nom': 'Prof'},
                    ],
                    'files': [
                      {'id': 1},
                    ],
                  },
                ],
              },
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': {
            'content': base64.encode(utf8.encode('<p>Bonjour<br>À demain</p>')),
            'files': [
              {'id': 5, 'libelle': 'autorisation.pdf', 'type': 'PIECE_JOINTE'},
            ],
          },
        }),
        200,
      );
    });
    final ed = EdClient(client, false);
    await ed.login('p', 'x', answerQuestion: (_, _) async => null);
    expect(ed.accountId, 42);
    expect(ed.familyId, 900);
    final inbox = await ed.messages();
    expect(inbox.single.id, 7);
    expect(inbox.single.from, 'Mme Dupont');
    expect(inbox.single.hasFiles, isTrue);
    final sent = await ed.messages(folder: 'sent');
    expect(sent.single.from, 'À Paul Prof');
    expect(sent.single.sent, isTrue);
    final c = await ed.message(7);
    expect(c.text, 'Bonjour\nÀ demain');
    expect(c.files.single.name, 'autorisation.pdf');
    expect(paths.where((p) => p.contains('/familles/900/messages')).length, 3);
    expect(paths.any((p) => p.contains('/eleves/42/messages')), isFalse);
  });

  test('micro Windows : lancement sans fichier et erreur lisible', () {
    final bytes = base64Decode(WindowsEars.encodedScript());
    final code = String.fromCharCodes([
      for (var i = 0; i + 1 < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
    ]);
    expect(code, startsWith("\$Lang = 'fr-FR'"));
    expect(code, isNot(contains('param([string]')));
    expect(code.length, lessThan(16000), reason: 'tient dans une ligne de commande Windows');
    expect(
      WindowsEars.errorDetail(
        'File C:\\x.ps1 cannot be loaded because running scripts is disabled on this system.\r\n'
        '+ CategoryInfo : SecurityError',
      ),
      startsWith('File C:'),
    );
  });

  test('mises à jour : version et release GitHub', () {
    expect(Updater.versionNumber('v1.22'), 22);
    expect(Updater.versionNumber('développement'), isNull);
    final u = UpdateInfo.fromRelease({
      'tag_name': 'v1.23',
      'body': 'Nouveautés',
      'assets': [
        {'name': 'MonHub-Claude.mcpb', 'browser_download_url': 'x'},
        {
          'name': 'MonHub-Windows.zip',
          'browser_download_url': 'https://github.com/a/b/releases/download/v1.23/MonHub-Windows.zip',
          'size': 1234,
          'digest': 'sha256:ABCDEF',
        },
      ],
    })!;
    expect(u.number, 23);
    expect(u.url, endsWith('MonHub-Windows.zip'));
    expect(u.sha256, 'abcdef');
    expect(u.size, 1234);
    expect(UpdateInfo.fromRelease({'tag_name': 'v1.24', 'assets': []}), isNull);
  });
}
