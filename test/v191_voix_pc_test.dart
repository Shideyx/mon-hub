import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/piper_voice.dart';
import 'package:hub/ui/clicky/voice.dart';

void main() {
  group('La voix du PC (Piper), sans Gemini', () {
    test('le texte part en JSON ASCII (accents, guillemets, émojis sans souci)', () {
      final line = PiperVoice.jsonLine('Ça « marche » \\o/ "oui" 😀\nfin', speaker: 1);
      expect(line, isNot(contains('\n')));
      expect(line.codeUnits.every((c) => c < 0x80), isTrue);
      final j = jsonDecode(line) as Map;
      expect(j['text'], 'Ça « marche » \\o/ "oui" 😀 fin');
      expect(j['speaker_id'], 1);
      expect((jsonDecode(PiperVoice.jsonLine('Bonjour')) as Map).containsKey('speaker_id'), isFalse);
    });

    test('ce qui est lu : sans émojis ni Markdown', () {
      expect(PiperVoice.speakable('**Super** ! 🎉 Ton cours de #maths'), 'Super ! Ton cours de maths');
      expect(PiperVoice.speakable('🎵'), '');
    });

    test('la vitesse et les voix', () {
      expect(PiperVoice.lengthScale(1), 1);
      expect(PiperVoice.lengthScale(1.25), closeTo(0.8, 0.001));
      expect(PiperVoice.lengthScale(10), closeTo(0.556, 0.001)); // vitesse bornée
      expect(PiperVoice.voiceOf('inconnue').id, 'tom');
      expect(PiperVoice.voiceOf('siwis').githubTar, contains('github.com/rhasspy/piper'));
      expect(PiperVoice.modelUrl(PiperVoice.voiceOf('tom')), contains('fr_FR-tom-medium.onnx'));
      expect(PiperVoice.modelUrl(PiperVoice.voiceOf('tom'), json: true), contains('.onnx.json'));
      expect(PiperVoice.zipSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('un fichier modifié est refusé (empreinte SHA-256)', () async {
      final dir = await Directory.systemTemp.createTemp('piper_test');
      final f = File('${dir.path}/x.bin')..writeAsBytesSync(utf8.encode('Nexo'));
      final good = sha256.convert(utf8.encode('Nexo')).toString();
      expect(await PiperVoice.sha256Matches(f, good), isTrue);
      expect(await PiperVoice.sha256Matches(f, PiperVoice.zipSha256), isFalse);
      await dir.delete(recursive: true);
    });

    test('hors de Windows : pas de voix du PC, et une phrase claire', () async {
      expect(PiperVoice.supported, isFalse);
      expect(PiperVoice.ready, isFalse);
      await expectLater(PiperVoice.install(), throwsA(isA<String>()));
    });

    test('qui parle : Gemini, puis la voix du PC', () {
      final v = ClickyVoice()..geminiKey = 'cle';
      expect(v.engine, 'auto');
      expect(v.hasVoice, isTrue);
      // « Toujours le PC » sans la voix du PC installée : pas de voix (réponse écrite).
      v.engine = 'pc';
      expect(v.hasVoice, isFalse);
      final none = ClickyVoice();
      expect(none.hasVoice, isFalse);
    });
  });
}
