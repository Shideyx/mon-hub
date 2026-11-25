import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/jarvis_talk.dart';
import 'package:hub/ui/clicky/live.dart';
import 'package:hub/ui/clicky/pcm_player.dart';
import 'package:hub/ui/clicky/voice.dart';

Uint8List tone(int samples, {int value = 8000}) {
  final b = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    b.setInt16(i * 2, value, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  group('Un son qui ne hache plus', () {
    test('après un silence, il attend un peu d\'avance avant de jouer', () {
      final j = PcmJitter(rate: 24000);
      // 50 ms : pas encore assez (il faut 200 ms).
      expect(j.add(tone(1200), playing: false), isEmpty);
      expect(j.pending, isTrue);
      // 200 ms en tout : ça part, d'un seul bloc.
      final out = j.add(tone(3600), playing: false);
      expect(out, hasLength(1));
      expect(out.single.length, 4800 * 2);
      expect(j.pending, isFalse);
    });

    test('pendant la lecture, tout part tout de suite', () {
      final j = PcmJitter(rate: 24000);
      expect(j.add(tone(240), playing: true).single.length, 480);
    });

    test('toujours un nombre pair d\'octets (PCM 16 bits)', () {
      final j = PcmJitter(rate: 24000);
      final odd = Uint8List(4801);
      final out = j.add(odd, playing: true);
      expect(out.single.length, 4800);
      expect(j.pending, isTrue);
      expect(j.drain(), isEmpty);
      j.clear();
      expect(j.pending, isFalse);
    });

    test('une montée douce au début (pas de « clic »)', () {
      final pcm = tone(400, value: 10000);
      PcmJitter.fadeIn(pcm);
      final d = ByteData.sublistView(pcm);
      expect(d.getInt16(0, Endian.little), 0);
      expect(d.getInt16(60 * 2, Endian.little), closeTo(5000, 100));
      expect(d.getInt16(300 * 2, Endian.little), 10000);
    });
  });

  group('La conversation mains libres (mode JARVIS)', () {
    test('les phrases pour commencer et finir', () {
      for (final s in ['Nexo, on discute', 'mode conversation', 'Mode JARVIS', 'parlons', 'Discute avec moi']) {
        expect(TalkRules.isStart(s), isTrue, reason: s);
      }
      for (final s in ['On discute de quoi en SVT ?', 'mets de la musique', 'parle-moi de la révolution']) {
        expect(TalkRules.isStart(s), isFalse, reason: s);
      }
      for (final s in ['Merci Nexo, c\'est tout.', 'Au revoir !', 'c\'est bon merci', 'Arrête la conversation']) {
        expect(TalkRules.isGoodbye(s), isTrue, reason: s);
      }
      for (final s in ['merci de m\'expliquer les fractions', 'arrête de parler de ça et explique-moi la suite']) {
        expect(TalkRules.isGoodbye(s), isFalse, reason: s);
      }
      expect(TalkRules.isStop('arrête la conversation'), isTrue);
      expect(TalkRules.isStop('arrête la musique'), isFalse);
    });

    test('le micro se tait pendant qu\'il parle, sauf si tu lui coupes la parole', () {
      const long = Duration(seconds: 5);
      expect(TalkRules.gate(level: 0.3, nexoSpeaking: false, loudChunks: 0, sinceSpoke: long), MicGate.send);
      // Son propre écho : jamais envoyé.
      expect(TalkRules.gate(level: 0.3, nexoSpeaking: true, loudChunks: 0, sinceSpoke: Duration.zero), MicGate.silence);
      expect(
        TalkRules.gate(level: 0.5, nexoSpeaking: false, loudChunks: 0, sinceSpoke: const Duration(milliseconds: 100)),
        MicGate.silence,
      );
      // Une voix forte, plusieurs morceaux de suite : il se tait.
      expect(
        TalkRules.gate(level: 0.7, nexoSpeaking: true, loudChunks: 2, sinceSpoke: Duration.zero, nexoLevel: 0.3),
        MicGate.bargeIn,
      );
      expect(
        TalkRules.gate(level: 0.7, nexoSpeaking: true, loudChunks: 0, sinceSpoke: Duration.zero, nexoLevel: 0.3),
        MicGate.silence,
      );
      // Aussi fort que sa propre voix : c'est l'écho, pas toi.
      expect(
        TalkRules.gate(level: 0.6, nexoSpeaking: true, loudChunks: 5, sinceSpoke: Duration.zero, nexoLevel: 0.6),
        MicGate.silence,
      );
    });

    test('ses consignes : à l\'oral, la même voix, il s\'arrête quand on lui dit au revoir', () {
      final s = TalkRules.system('Tu es Nexo.');
      expect(s, startsWith('Tu es Nexo.'));
      expect(s, contains(GeminiLive.voiceStyle));
      expect(s, contains('CONVERSATION EN DIRECT'));
      expect(TalkRules.endNote('silence'), contains('on discute'));
      expect(TalkRules.endNote('quota'), contains('quota gratuit'));
    });

    test('sans Windows ou sans clé : une phrase claire, pas de plantage', () async {
      final t = JarvisTalk(key: '', system: 'x');
      await expectLater(t.start(), throwsA(isA<String>()));
      expect(t.active, isFalse);
    });
  });

  group('Toujours la même voix', () {
    test('la conversation et la lecture ont le même style et une connexion réglée', () {
      expect(LiveReader.system, contains(GeminiLive.voiceStyle));
      final live = GeminiLive(key: 'k', system: 's', tools: const [], temperature: 0.3, autoVad: true);
      final setup = live.setupMessage('gemini-x')['setup'] as Map;
      final gen = setup['generationConfig'] as Map;
      expect(gen['temperature'], 0.3);
      expect((gen['speechConfig'] as Map)['voiceConfig'], {
        'prebuiltVoiceConfig': {'voiceName': 'Charon'},
      });
      // Gemini repère seul les tours de parole (pas de « activityStart » à envoyer).
      expect(setup.containsKey('realtimeInputConfig'), isFalse);
      final classic = GeminiLive(key: 'k', system: 's', tools: const []).setupMessage('gemini-x')['setup'] as Map;
      expect((classic['generationConfig'] as Map).containsKey('temperature'), isFalse);
    });

    test('la voix stable est le choix par défaut', () {
      expect(ClickyVoice().steady, isTrue);
    });
  });
}
