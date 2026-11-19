import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/ui/clicky/interpreter.dart';
import 'package:hub/ui/clicky/live.dart';
import 'package:hub/ui/clicky/live_captions.dart';
import 'package:hub/ui/clicky/loopback.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('Son du PC → 16 kHz', () {
    test('48 kHz : un tiers des échantillons, sans coupure entre les morceaux', () {
      final rs = Resampler(48000, 16000);
      final all = <int>[];
      // Une sinusoïde de 440 Hz, envoyée en 3 morceaux de tailles différentes.
      final wave = Float32List.fromList([for (var i = 0; i < 4800; i++) 0.5 * math.sin(2 * math.pi * 440 * i / 48000)]);
      for (final (a, b) in [(0, 1000), (1000, 3333), (3333, 4800)]) {
        final bytes = rs.push(Float32List.sublistView(wave, a, b));
        all.addAll(Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2));
      }
      expect(all.length, closeTo(1600, 2));
      // Chaque échantillon produit = la sinusoïde au bon moment.
      for (var k = 0; k < all.length; k += 37) {
        final want = 0.5 * math.sin(2 * math.pi * 440 * k / 16000) * 32767;
        expect(all[k], closeTo(want, 400), reason: 'échantillon $k');
      }
      expect(rs.push(Float32List(0)), isEmpty);
    });

    test('44,1 kHz', () {
      final rs = Resampler(44100, 16000);
      final out = rs.push(Float32List(44100));
      expect(out.length ~/ 2, closeTo(16000, 2));
    });
  });

  group('Sous-titres en direct', () {
    test('fichier WAV', () {
      final pcm = Uint8List(32000);
      final w = LiveCaptions.wav(pcm);
      final h = ByteData.sublistView(w);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
      expect(h.getUint32(4, Endian.little), 36 + 32000);
      expect(h.getUint32(24, Endian.little), 16000);
      expect(h.getUint16(34, Endian.little), 16);
      expect(h.getUint32(40, Endian.little), 32000);
      expect(w.length, 44 + 32000);
      expect(LiveCaptions.bytesFor(LiveCaptions.chunk), 8 * 32000);
    });

    test('ce qui s\'affiche', () {
      expect(LiveCaptions.clean('(rien)'), isNull);
      expect(LiveCaptions.clean('[Musique]'), isNull);
      expect(LiveCaptions.clean('  '), isNull);
      expect(LiveCaptions.clean('Sous-titres : On y va !'), 'On y va !');
      expect(LiveCaptions.clean('```\nBonjour à tous\n```'), 'Bonjour à tous');
      expect(LiveCaptions.prompt('français'), contains('(rien)'));
    });
  });

  group('Interprète', () {
    test('consignes et réglages de Gemini Live', () {
      expect(Interpreter.system('espagnol'), contains('français et le espagnol'));
      final setup = GeminiLive(key: 'k', system: 's', tools: const [], language: null, autoVad: true).setupMessage('m')['setup'] as Map;
      expect(setup.containsKey('realtimeInputConfig'), isFalse);
      expect(setup.containsKey('tools'), isFalse);
      expect(((setup['generationConfig'] as Map)['speechConfig'] as Map).containsKey('languageCode'), isFalse);
      // Clicky garde ses réglages habituels.
      final clicky = GeminiLive(key: 'k', system: 's', tools: const []).setupMessage('m')['setup'] as Map;
      expect(clicky['realtimeInputConfig'], isNotNull);
      expect(((clicky['generationConfig'] as Map)['speechConfig'] as Map)['languageCode'], 'fr-FR');
    });

    testWidgets('la page s\'ouvre', (t) async {
      await t.pumpWidget(const MaterialApp(home: InterpreterPage(language: 'Espagnol')));
      expect(find.text('Français ⇄ Espagnol'), findsOneWidget);
      await t.tap(find.text('Commencer'));
      await t.pump();
      expect(find.textContaining('PC (Windows)'), findsOneWidget);
    });
  });

  group('Clicky', () {
    test('phrases sans IA', () async {
      final calls = <String>[];
      Future<Object?> fake(String name, Map<String, dynamic> a) async {
        calls.add('$name ${a['langue'] ?? ''}'.trim());
        return 'ok';
      }

      const tools = {'interprete_ouvrir', 'soustitres_lancer'};
      for (final (q, want) in [
        ('Interprète anglais', 'interprete_ouvrir anglais'),
        ('mode interprète', 'interprete_ouvrir anglais'),
        ('traduis notre conversation en espagnol', 'interprete_ouvrir espagnol'),
        ('Mets les sous-titres', 'soustitres_lancer'),
        ('sous-titres en direct', 'soustitres_lancer'),
        ('traduis ce que j\'écoute', 'soustitres_lancer'),
      ]) {
        calls.clear();
        await QuickAnswers.answer(q, call: fake, tools: tools);
        expect(calls, [want], reason: q);
      }
      calls.clear();
      await QuickAnswers.answer('comment on dit bonjour en anglais ?', call: fake, tools: tools);
      expect(calls, isEmpty);
    });

    test('Claude reçoit les outils', () {
      expect(ToolRouter.groupOf('soustitres_lancer'), 'langues');
      expect(ToolRouter.groupsFor('je veux une traduction de ma conversation'), contains('langues'));
    });
  });
}
