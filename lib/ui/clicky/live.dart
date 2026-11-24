import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/hub_module.dart';
import 'shot_encode.dart';
import '../../core/token_budget.dart';

/// Gemini Live : la conversation **en direct**, comme le JARVIS « Mark LII »
/// (Gemini Live API). Le micro part vers Gemini pendant que tu parles, et la
/// réponse revient directement en voix, morceau par morceau : Smily répond
/// au tac au tac, sans attendre une transcription, une IA, puis une voix.
///
/// Une connexion (WebSocket) reste ouverte entre deux questions : pas de
/// temps de démarrage. Ta clé Gemini gratuite (aistudio.google.com) suffit.
class GeminiLive {
  GeminiLive({
    required this.key,
    required this.system,
    required this.tools,
    this.voice = 'Charon',
    this.extraDeclarations = const [],
    this.language = 'fr-FR',
    this.autoVad = false,
  });

  /// Langue de la voix (null : Gemini choisit, ex. pour l'interprète).
  final String? language;

  /// true : Gemini repère tout seul quand on commence et finit de parler
  /// (conversation continue, interprète) ; false : Smily le lui dit.
  final bool autoVad;

  final String key;
  final String system;
  final String voice;

  /// Actions de Mon Hub que Gemini peut utiliser (agenda, notes…).
  final List<HubTool> tools;

  /// Fonctions en plus (regarder l'écran, agir sur le PC…), déjà au format
  /// de Gemini.
  final List<Map<String, dynamic>> extraDeclarations;

  /// Modèles « voix native », du plus récent au plus ancien.
  static const models = [
    'gemini-2.5-flash-native-audio-preview-12-2025',
    'gemini-2.5-flash-native-audio-preview-09-2025',
    'gemini-live-2.5-flash-preview',
    'gemini-2.0-flash-live-001',
  ];

  /// Dernier modèle qui a marché (essayé en premier la fois suivante).
  static String? workingModel;

  /// Adresse imposée (tests).
  @visibleForTesting
  static String? endpointOverride;

  static String url(String key) =>
      endpointOverride ??
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${Uri.encodeQueryComponent(key)}';

  WebSocket? _ws;
  String? _resume;
  Completer<void>? _ready;

  /// Évènements reçus.
  void Function(Uint8List pcm24k)? onAudio;
  void Function(String text)? onOutputText;
  void Function(String text)? onInputText;
  void Function()? onTurnComplete;
  void Function()? onInterrupted;
  Future<Object?> Function(String name, Map<String, dynamic> args)? onToolCall;
  void Function(String status)? onToolStatus;
  void Function(Object error)? onClosed;

  bool get connected => _ws != null && (_ready?.isCompleted ?? false);

  /// La connexion est en train de s'ouvrir.
  bool get connecting => _ready != null && !_ready!.isCompleted;

  /// Ouvre la connexion (essaie les modèles l'un après l'autre).
  Future<void> connect() async {
    if (connected) return;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) return ready.future;
    Object? last;
    final order = [?workingModel, ...models.where((m) => m != workingModel)];
    for (final model in order) {
      try {
        await _connect(model).timeout(const Duration(seconds: 10));
        workingModel = model;
        return;
      } catch (e) {
        last = e;
        await close();
        // Clé refusée : inutile d'essayer les autres modèles.
        if ('$e'.contains('API key') || '$e'.contains('PERMISSION_DENIED')) break;
      }
    }
    throw 'Gemini Live indisponible : $last';
  }

  Future<void> _connect(String model) async {
    final ready = _ready = Completer<void>();
    final ws = await WebSocket.connect(url(key));
    _ws = ws;
    ws.listen(
      (msg) => _onMessage(msg, ready),
      onDone: () {
        final why =
            'connexion fermée${ws.closeReason == null || ws.closeReason!.isEmpty ? '' : ' (${ws.closeReason})'}';
        if (!ready.isCompleted) ready.completeError(why);
        if (identical(_ws, ws)) {
          _ws = null;
          onClosed?.call(why);
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
      },
      cancelOnError: true,
    );
    ws.add(jsonEncode(setupMessage(model)));
    await ready.future;
  }

  /// Le message de départ : modèle, voix, consignes, fonctions.
  @visibleForTesting
  Map<String, dynamic> setupMessage(String model) => {
    'setup': {
      'model': 'models/$model',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voice},
          },
          'languageCode': ?language,
        },
      },
      'systemInstruction': {
        'parts': [
          {'text': system},
        ],
      },
      if (tools.isNotEmpty || extraDeclarations.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [for (final t in tools) declaration(t), ...extraDeclarations],
          },
        ],
      // Smily dit lui-même quand tu commences et finis de parler
      // (Ctrl + Alt, ou silence) : la réponse part dès que tu lâches.
      if (!autoVad)
        'realtimeInputConfig': {
          'automaticActivityDetection': {'disabled': true},
        },
      'inputAudioTranscription': <String, dynamic>{},
      'outputAudioTranscription': <String, dynamic>{},
      'contextWindowCompression': {'slidingWindow': <String, dynamic>{}},
      'sessionResumption': {'handle': ?_resume},
    },
  };

  /// Une action de Mon Hub au format des fonctions de Gemini.
  static Map<String, dynamic> declaration(HubTool t) {
    const types = {'string': 'STRING', 'integer': 'INTEGER', 'number': 'NUMBER', 'boolean': 'BOOLEAN'};
    return {
      'name': t.name,
      'description': t.description,
      if (t.params.isNotEmpty)
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            for (final e in t.params.entries) e.key: {'type': types[e.value.$1] ?? 'STRING', 'description': e.value.$2},
          },
          if (t.required.isNotEmpty) 'required': t.required,
        },
    };
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Tu commences à parler.
  void activityStart() => _send({
    'realtimeInput': {'activityStart': <String, dynamic>{}},
  });

  /// Tu as fini : Gemini répond tout de suite.
  void activityEnd() => _send({
    'realtimeInput': {'activityEnd': <String, dynamic>{}},
  });

  /// Un morceau du micro (PCM 16 bits, 16 kHz, mono).
  void sendAudio(Uint8List pcm) => _send({
    'realtimeInput': {
      'audio': {'data': base64Encode(pcm), 'mimeType': 'audio/pcm;rate=16000'},
    },
  });

  /// Une question écrite.
  void sendText(String text) => _send({
    'clientContent': {
      'turns': [
        {
          'role': 'user',
          'parts': [
            {'text': text},
          ],
        },
      ],
      'turnComplete': true,
    },
  });

  Future<void> _onMessage(Object msg, Completer<void> ready) async {
    final Map<String, dynamic> m;
    try {
      final text = msg is String ? msg : utf8.decode(msg as List<int>);
      m = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (m.containsKey('setupComplete')) {
      if (!ready.isCompleted) ready.complete();
      return;
    }
    // Les jetons de Gemini Live (gratuit, comptés pour information).
    final um = m['usageMetadata'];
    if (um is Map) {
      final total = (um['totalTokenCount'] as num? ?? 0).toInt();
      final prompt = (um['promptTokenCount'] as num? ?? 0).toInt();
      unawaited(TokenBudget.instance.recordGemini(prompt, total - prompt).catchError((Object _) {}));
    }
    final sru = m['sessionResumptionUpdate'];
    if (sru is Map && sru['resumable'] == true && sru['newHandle'] is String) _resume = sru['newHandle'] as String;
    final sc = m['serverContent'];
    if (sc is Map) {
      if (sc['interrupted'] == true) onInterrupted?.call();
      final parts = (sc['modelTurn'] as Map?)?['parts'];
      if (parts is List) {
        for (final p in parts) {
          final d = p is Map ? p['inlineData'] : null;
          if (d is Map && '${d['mimeType']}'.startsWith('audio/') && d['data'] is String) {
            onAudio?.call(base64Decode(d['data'] as String));
          }
        }
      }
      final out = (sc['outputTranscription'] as Map?)?['text'];
      if (out is String && out.isNotEmpty) onOutputText?.call(out);
      final inp = (sc['inputTranscription'] as Map?)?['text'];
      if (inp is String && inp.isNotEmpty) onInputText?.call(inp);
      if (sc['turnComplete'] == true) onTurnComplete?.call();
    }
    final tc = m['toolCall'];
    if (tc is Map) {
      final calls = (tc['functionCalls'] as List?) ?? const [];
      final responses = <Map<String, dynamic>>[];
      for (final c in calls) {
        if (c is! Map) continue;
        final name = '${c['name']}';
        onToolStatus?.call(name);
        Object? result;
        try {
          result = await onToolCall?.call(name, ((c['args'] as Map?) ?? const {}).cast<String, dynamic>());
        } catch (e) {
          result = {'erreur': '$e'};
        }
        responses.add({
          'id': c['id'],
          'name': name,
          'response': {'result': _plain(result)},
        });
      }
      _send({
        'toolResponse': {'functionResponses': responses},
      });
    }
    if (m.containsKey('goAway')) {
      // Le serveur va couper : la prochaine question rouvrira la connexion
      // (en reprenant la conversation).
      unawaited(close());
    }
  }

  static Object? _plain(Object? v) => switch (v) {
    null || String() || num() || bool() => v,
    DateTime() => v.toIso8601String(),
    Map() => {for (final e in v.entries) '${e.key}': _plain(e.value)},
    Iterable() => [for (final x in v) _plain(x)],
    _ => '$v',
  };

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    _ready = null;
    try {
      await ws?.close();
    } catch (_) {}
  }
}

/// « Regarde l'écran » pour Gemini Live : les captures sont décrites par
/// Gemini Flash (rapide), et la réponse revient dans la conversation.
class GeminiVision {
  GeminiVision._();

  static Future<String> look(String key, List<String> png64, String question) async {
    final c = HttpClient();
    try {
      for (final model in const ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash']) {
        final req = await c.postUrl(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
        );
        req.headers
          ..contentType = ContentType.json
          ..set('x-goog-api-key', key.trim());
        req.add(
          utf8.encode(
            jsonEncode({
              'contents': [
                {
                  'parts': [
                    for (final p in png64)
                      {
                        'inline_data': {'mime_type': imageMime(p), 'data': p},
                      },
                    {
                      'text':
                          'Voici l\'écran de la personne. $question\nRéponds en français, précisément et brièvement '
                          '(ce qui est visible, les textes importants, où se trouvent les éléments).',
                    },
                  ],
                },
              ],
            }),
          ),
        );
        final res = await req.close().timeout(const Duration(seconds: 30));
        final body = await utf8.decodeStream(res);
        if (res.statusCode == 404) continue;
        final j = jsonDecode(body);
        if (res.statusCode != 200) return 'Je n\'ai pas pu regarder l\'écran (code ${res.statusCode}).';
        final parts =
            ((((j as Map)['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
        return [
          for (final p in parts ?? const [])
            if (p is Map && p['text'] != null) '${p['text']}',
        ].join(' ').trim();
      }
      return 'Je n\'ai pas pu regarder l\'écran.';
    } finally {
      c.close(force: true);
    }
  }
}
