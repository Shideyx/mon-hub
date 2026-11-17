import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Voix neurales **gratuites** pour Clicky.
///
/// * **Microsoft (Edge)** : les voix « lecture à voix haute » du navigateur
///   Edge (Henri, Denise, Rémy…), très naturelles, sans clé ni compte. Même
///   service que l'outil libre edge-tts (et clicky-windows). Non officiel :
///   si le service refuse, Clicky repasse sur la voix de Windows.
/// * **Gemini** : la synthèse vocale de Google, avec une clé gratuite
///   d'AI Studio (quota gratuit limité par jour).
class EdgeVoice {
  EdgeVoice._();

  static const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _chromium = '130.0.2849.68';

  /// Voix conseillées.
  static const voices = {
    'fr-FR-HenriNeural': 'Henri (homme, posé)',
    'fr-FR-RemyMultilingualNeural': 'Rémy (homme, multilingue)',
    'fr-FR-DeniseNeural': 'Denise (femme)',
    'fr-FR-VivienneMultilingualNeural': 'Vivienne (femme, multilingue)',
    'fr-FR-EloiseNeural': 'Éloïse (jeune)',
    'fr-CA-ThierryNeural': 'Thierry (Québec)',
    'fr-BE-GerardNeural': 'Gérard (Belgique)',
    'fr-CH-FabriceNeural': 'Fabrice (Suisse)',
    'en-GB-RyanNeural': 'Ryan (anglais britannique)',
    'en-US-AndrewMultilingualNeural': 'Andrew (anglais, multilingue)',
  };

  /// Voix pour une langue (mode multilingue).
  static String forLanguage(String lang, String chosen) {
    if (lang.toLowerCase().startsWith('fr')) return chosen;
    return switch (lang.split('-').first) {
      'en' => 'en-US-AndrewMultilingualNeural',
      'es' => 'es-ES-AlvaroNeural',
      'de' => 'de-DE-ConradNeural',
      'it' => 'it-IT-DiegoNeural',
      'pt' => 'pt-PT-DuarteNeural',
      _ => 'fr-FR-RemyMultilingualNeural',
    };
  }

  /// Jeton anti-abus du service (comme edge-tts) : empreinte de l'heure
  /// Windows arrondie à 5 minutes.
  static String secMsGec([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    final rounded = t - t % 300;
    final ticks = BigInt.from(rounded) * BigInt.from(10000000);
    return sha256.convert(ascii.encode('$ticks$token')).toString().toUpperCase();
  }

  static String _hex(int bytes) {
    final r = Random.secure();
    return [for (var i = 0; i < bytes; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')]
        .join();
  }

  static String _date() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${months[d.month - 1]} ${two(d.day)} ${d.year} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// « +10% », « -5Hz »…
  static String _signed(num v, String unit) => '${v >= 0 ? '+' : ''}${v.round()}$unit';

  /// Le texte SSML envoyé au service.
  static String ssml(String text, String voice, {double rate = 1, double pitch = 1}) {
    final parts = voice.split('-');
    final locale = parts.length >= 2 ? '${parts[0]}-${parts[1]}' : 'fr-FR';
    final name = parts.length >= 3 ? parts.sublist(2).join('-') : voice;
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        "<voice name='Microsoft Server Speech Text to Speech Voice ($locale, $name)'>"
        "<prosody pitch='${_signed((pitch - 1) * 50, 'Hz')}' rate='${_signed((rate - 1) * 100, '%')}' volume='+0%'>"
        '${_escape(text)}</prosody></voice></speak>';
  }

  /// Lit un message binaire du service : (en-têtes, audio).
  static (String, Uint8List) splitBinary(Uint8List msg) {
    if (msg.length < 2) return ('', Uint8List(0));
    final n = (msg[0] << 8) | msg[1];
    final end = (2 + n).clamp(0, msg.length);
    return (utf8.decode(msg.sublist(2, end), allowMalformed: true), msg.sublist(end));
  }

  /// Synthétise un texte en MP3.
  static Future<Uint8List> synthesize(
    String text, {
    String voice = 'fr-FR-HenriNeural',
    double rate = 1,
    double pitch = 1,
  }) async {
    final url =
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$token&ConnectionId=${_hex(16)}'
        '&Sec-MS-GEC=${secMsGec()}&Sec-MS-GEC-Version=1-$_chromium';
    final ws = await WebSocket.connect(
      url,
      headers: {
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/${_chromium.split('.').first}.0.0.0 Safari/537.36 Edg/${_chromium.split('.').first}.0.0.0',
        'Cookie': 'muid=${_hex(16).toUpperCase()};',
      },
    ).timeout(const Duration(seconds: 10));
    final audio = BytesBuilder(copy: false);
    final done = Completer<void>();
    final sub = ws.listen(
      (m) {
        if (m is String) {
          if (m.contains('Path:turn.end') && !done.isCompleted) done.complete();
        } else if (m is List<int>) {
          final (head, data) = splitBinary(Uint8List.fromList(m));
          if (head.contains('Path:audio') && data.isNotEmpty) audio.add(data);
        }
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (Object e) => done.isCompleted ? null : done.completeError(e),
    );
    try {
      ws.add(
        'X-Timestamp:${_date()}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",'
        '"wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      ws.add(
        'X-RequestId:${_hex(16)}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${_date()}Z\r\nPath:ssml\r\n\r\n'
        '${ssml(text, voice, rate: rate, pitch: pitch)}',
      );
      await done.future.timeout(const Duration(seconds: 25));
    } finally {
      await sub.cancel();
      await ws.close();
    }
    final out = audio.takeBytes();
    if (out.isEmpty) throw 'La voix Microsoft n\'a rien renvoyé';
    return out;
  }
}

/// Voix Gemini (clé gratuite AI Studio).
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
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
          ),
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
    final parts =
        (((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final data = ((parts?.firstOrNull as Map?)?['inlineData'] as Map?)?['data'] as String?;
    if (data == null) throw 'Gemini n\'a pas renvoyé de son';
    return wav(base64Decode(data));
  }
}
