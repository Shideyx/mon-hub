import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// La voix de Smily : la synthèse vocale de Google Gemini, avec une clé
/// gratuite d'AI Studio (quota gratuit limité par jour). C'est la seule voix
/// (la voix Microsoft / Edge a été retirée à la demande de la personne).
class GeminiVoice {
  GeminiVoice._();

  static const voices = ['Charon', 'Kore', 'Puck', 'Fenrir', 'Aoede', 'Orus', 'Leda', 'Zephyr'];
  static const defaultModel = 'gemini-2.5-flash-preview-tts';

  /// En-tête WAV pour du PCM 16 bits mono.
  static Uint8List wav(Uint8List pcm, {int rate = 24000}) {
    final b = ByteData(44);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + pcm.length, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...pcm]);
  }

  static Future<Uint8List> synthesize(
    String text, {
    required String key,
    String voice = 'Charon',
    String model = defaultModel,
    http.Client? client,
  }) async {
    if (key.trim().isEmpty) throw 'Ajoute ta clé Gemini gratuite (aistudio.google.com)';
    final r = await (client ?? http.Client())
        .post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
          headers: {'content-type': 'application/json', 'x-goog-api-key': key.trim()},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Lis ce texte en français, d\'une voix posée et naturelle : $text'},
                ],
              },
            ],
            'generationConfig': {
              'responseModalities': ['AUDIO'],
              'speechConfig': {
                'voiceConfig': {
                  'prebuiltVoiceConfig': {'voiceName': voice},
                },
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 429) throw 'Quota gratuit de Gemini atteint pour aujourd\'hui';
    if (r.statusCode >= 400) throw 'Gemini : erreur ${r.statusCode}';
    final j = jsonDecode(r.body) as Map;
    final parts = (((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final data = ((parts?.firstOrNull as Map?)?['inlineData'] as Map?)?['data'] as String?;
    if (data == null) throw 'Gemini n\'a pas renvoyé de son';
    return wav(base64Decode(data));
  }
}
