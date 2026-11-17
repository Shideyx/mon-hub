import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/ui/clicky/live.dart';
import 'package:hub/ui/clicky/pcm_player.dart';
import 'package:hub/ui/clicky/tutor.dart';
import 'package:hub/ui/clicky/voice.dart';

void main() {
  test('réponse rapide : pas de capture pour une question générale', () {
    expect(needsScreen('Quelle heure est-il ?'), isFalse);
    expect(needsScreen('C\'est quoi une mitochondrie ?'), isFalse);
    expect(needsScreen('Raconte-moi une blague'), isFalse);
    expect(needsScreen('J\'ai quoi demain ?'), isFalse);
    expect(needsScreen('C\'est quoi ça ?'), isTrue);
    expect(needsScreen('Aide-moi avec cet exercice'), isTrue);
    expect(needsScreen('Où est le bouton pour exporter ?'), isTrue);
    expect(needsScreen('Pourquoi le ciel est bleu'), isTrue); // dans le doute : on regarde
  });

  test('voix : durée d\'un MP3 de la voix Microsoft', () {
    // 48 kbit/s → 6 000 octets par seconde.
    expect(ClickyVoice.mp3Duration(Uint8List(12000)), const Duration(seconds: 2));
  });

  test('volume d\'un son PCM', () {
    expect(PcmPlayer.rms(Uint8List(3200)), 0);
    final loud = ByteData(3200);
    for (var i = 0; i < 1600; i++) {
      loud.setInt16(i * 2, i.isEven ? 20000 : -20000, Endian.little);
    }
    expect(PcmPlayer.rms(loud.buffer.asUint8List()), 1);
  });

  test('Gemini Live : actions de Mon Hub au format de Gemini', () {
    final t = HubTool(
      name: 'agenda_lire',
      description: 'Lit l\'agenda',
      params: {'jours': ('integer', 'Nombre de jours'), 'debut': ('string', 'Date')},
      required: ['jours'],
      run: (_) async => null,
    );
    final d = GeminiLive.declaration(t);
    expect(d['parameters']['type'], 'OBJECT');
    expect(d['parameters']['properties']['jours']['type'], 'INTEGER');
    expect(d['parameters']['required'], ['jours']);
    final none = GeminiLive.declaration(HubTool(name: 'x', description: 'y', run: (_) async => null));
    expect(none.containsKey('parameters'), isFalse);
    final setup = GeminiLive(key: 'k', system: 'consignes', tools: [t]).setupMessage('gemini-x')['setup'] as Map;
    expect(setup['model'], 'models/gemini-x');
    expect(setup['generationConfig']['responseModalities'], ['AUDIO']);
    expect(setup['realtimeInputConfig']['automaticActivityDetection']['disabled'], isTrue);
  });

  test('Gemini Live : conversation en direct avec un faux serveur', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final got = <Map<String, dynamic>>[];
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final m = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
        got.add(m);
        if (m.containsKey('setup')) {
          // Le serveur répond en binaire, comme le vrai.
          ws.add(utf8.encode(jsonEncode({'setupComplete': <String, dynamic>{}})));
        }
        if ((m['realtimeInput'] as Map?)?.containsKey('activityEnd') == true) {
          ws.add(jsonEncode({
            'toolCall': {
              'functionCalls': [
                {'id': '1', 'name': 'agenda_lire', 'args': {'jours': 1}},
              ],
            },
          }));
        }
        if (m.containsKey('toolResponse')) {
          ws.add(jsonEncode({
            'serverContent': {
              'modelTurn': {
                'parts': [
                  {'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': base64Encode([1, 2, 3, 4])}},
                ],
              },
              'outputTranscription': {'text': 'Tu as maths à 8 h.'},
            },
          }));
          ws.add(jsonEncode({'serverContent': {'turnComplete': true}}));
        }
      });
    });
    GeminiLive.endpointOverride = 'ws://127.0.0.1:${server.port}';
    addTearDown(() => GeminiLive.endpointOverride = null);
    final tool = HubTool(
      name: 'agenda_lire',
      description: 'Lit l\'agenda',
      params: {'jours': ('integer', 'Nombre de jours')},
      run: (a) async => {'cours': 'maths à 8 h', 'jours': a['jours']},
    );
    final live = GeminiLive(key: 'k', system: 's', tools: [tool]);
    final audio = <int>[];
    final text = StringBuffer();
    final done = Completer<void>();
    live
      ..onAudio = audio.addAll
      ..onOutputText = text.write
      ..onTurnComplete = done.complete
      ..onToolCall = (name, args) => tool.run(args);
    await live.connect();
    expect(live.connected, isTrue);
    live
      ..activityStart()
      ..sendAudio(Uint8List(320))
      ..activityEnd();
    await done.future.timeout(const Duration(seconds: 5));
    expect(audio, [1, 2, 3, 4]);
    expect('$text', 'Tu as maths à 8 h.');
    final resp = got.firstWhere((m) => m.containsKey('toolResponse'))['toolResponse'] as Map;
    expect(((resp['functionResponses'] as List).single as Map)['response']['result']['cours'], 'maths à 8 h');
    expect(got.any((m) => (m['realtimeInput'] as Map?)?['audio']?['mimeType'] == 'audio/pcm;rate=16000'), isTrue);
    await live.close();
  });
}
