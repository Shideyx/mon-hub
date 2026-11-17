import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ui/clicky/claude_code.dart';
import '../ui/clicky/clicky.dart';
import '../ui/clicky/ollama.dart';
import 'claude_api.dart';

/// Une demande simple à l'IA, sans outils : corriger un texte, résumer,
/// créer des cartes de révision… Utilise ce que tu as déjà : ta clé Gemini
/// gratuite (rapide, lit aussi les photos et les PDF), sinon le cerveau de
/// Clicky (abonnement Claude, clé API ou Ollama sur le PC).
class AiText {
  AiText._();

  /// Réponse imposée (tests).
  @visibleForTesting
  static Future<String> Function(String prompt, String system)? override;

  static Future<String> _geminiKey() async => (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();

  /// La clé Gemini (gratuite) est là.
  static Future<bool> hasGemini() async => override != null || (await _geminiKey()).isNotEmpty;

  /// Une IA est-elle disponible ?
  static Future<bool> available() async {
    if (override != null) return true;
    if ((await _geminiKey()).isNotEmpty) return true;
    final p = ClickyController.instance.provider;
    if (p == 'ollama') return true;
    if (p == 'claudecode') return await ClaudeCode.find() != null;
    return ClaudeApi.hasKey();
  }

  /// Pose la question. [images] : photos en base64 (PNG ou JPEG), [pdf] :
  /// un PDF en base64 (Gemini seulement).
  static Future<String> ask(
    String prompt, {
    String system = 'Tu es Clicky, un assistant qui aide un lycéen. Réponds en français.',
    List<String> images = const [],
    String? pdf,
    bool geminiOnly = false,
  }) async {
    final o = override;
    if (o != null) return o(prompt, system);
    final key = await _geminiKey();
    // Pour les petites tâches (rédiger le briefing…), on n'utilise pas Claude.
    if (geminiOnly) {
      if (key.isEmpty) throw 'Pas de clé Gemini';
      return _gemini(key, prompt, system, images, pdf);
    }
    if (key.isNotEmpty) {
      try {
        return await _gemini(key, prompt, system, images, pdf);
      } catch (e) {
        // Quota épuisé ou panne : on essaie le cerveau de Clicky.
        if (pdf != null) rethrow;
      }
    }
    final c = ClickyController.instance;
    switch (c.provider) {
      case 'ollama':
        return Ollama.chat(system: system, memory: const [], question: prompt, imagesB64: images);
      case 'claudecode':
        return ClaudeCode.ask(system: system, question: prompt, imagesB64: images, withTools: false);
      default:
        return ClaudeApi.chat(
          system: system,
          history: [
            {
              'role': 'user',
              'content': [
                for (final i in images)
                  {
                    'type': 'image',
                    'source': {'type': 'base64', 'media_type': mime(i), 'data': i},
                  },
                {'type': 'text', 'text': prompt},
              ],
            },
          ],
        );
    }
  }

  /// Type d'une image en base64 (d'après ses premiers octets).
  static String mime(String b64) => b64.startsWith('/9j/') ? 'image/jpeg' : 'image/png';

  static Future<String> _gemini(String key, String prompt, String system, List<String> images, String? pdf) async {
    final c = HttpClient();
    try {
      Object? last;
      for (final model in const ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash']) {
        final req = await c.postUrl(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
        );
        req.headers
          ..contentType = ContentType.json
          ..set('x-goog-api-key', key);
        req.add(
          utf8.encode(
            jsonEncode({
              'systemInstruction': {
                'parts': [
                  {'text': system},
                ],
              },
              'contents': [
                {
                  'parts': [
                    for (final i in images)
                      {
                        'inline_data': {'mime_type': mime(i), 'data': i},
                      },
                    if (pdf != null)
                      {
                        'inline_data': {'mime_type': 'application/pdf', 'data': pdf},
                      },
                    {'text': prompt},
                  ],
                },
              ],
            }),
          ),
        );
        final res = await req.close().timeout(const Duration(seconds: 90));
        final body = await utf8.decodeStream(res);
        if (res.statusCode == 404) {
          last = 'modèle $model introuvable';
          continue;
        }
        if (res.statusCode != 200) throw 'Gemini : erreur ${res.statusCode}';
        final j = jsonDecode(body) as Map;
        final parts =
            ((((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?) ?? const [];
        final text = [
          for (final p in parts)
            if (p is Map && p['text'] != null && p['thought'] != true) '${p['text']}',
        ].join().trim();
        if (text.isEmpty) throw 'Gemini n\'a rien répondu';
        return text;
      }
      throw 'Gemini indisponible ($last)';
    } finally {
      c.close(force: true);
    }
  }

  /// Le premier bloc JSON (tableau ou objet) d'une réponse, même entouré de
  /// texte ou de ```json.
  static Object? json(String text) {
    final t = text.replaceAll(RegExp(r'```(?:json)?'), '');
    for (final (open, close) in const [('[', ']'), ('{', '}')]) {
      final a = t.indexOf(open);
      final b = t.lastIndexOf(close);
      if (a >= 0 && b > a) {
        try {
          return jsonDecode(t.substring(a, b + 1));
        } catch (_) {}
      }
    }
    return null;
  }
}
