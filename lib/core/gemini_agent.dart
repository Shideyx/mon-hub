import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'claude_api.dart';
import 'hub_module.dart';
import 'prompt_shield.dart';
import 'token_budget.dart';
import 'tool_router.dart';

/// **Le cerveau économe** : Gemini (gratuit, ta clé Google) qui sait utiliser
/// les outils de Mon Hub — agenda, notes, devoirs, messages, musique… — pour
/// les questions **écrites** comme pour la voix.
///
/// Avant, à l'écrit, tout ce qui touchait à tes données partait chez Claude
/// (payant, gourmand en jetons). Maintenant Gemini répond d'abord ; Claude ne
/// sert plus qu'aux gros travaux (rédiger, devoirs, agir sur l'écran,
/// réfléchir en profondeur) ou quand Gemini dit lui-même « CLAUDE ».
///
/// Les actions à autoriser restent demandées comme avant ([run] passe par
/// la même permission que Claude), et les résultats venant de l'extérieur
/// sont étiquetés « données » (`PromptShield`).
class GeminiAgent {
  GeminiAgent._();

  static const models = ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash'];

  /// Le dernier modèle qui a marché (essayé en premier).
  static String? workingModel;

  /// Remplace l'appel à Google (tests).
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(Map<String, dynamic> body)? postOverride;

  static Future<String> _key() async => (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();

  /// Gemini peut répondre (clé présente).
  static Future<bool> ready() async => postOverride != null || (await _key()).isNotEmpty;

  /// Ce que Gemini doit répondre quand il lui faut Claude.
  static const handOff = 'CLAUDE';

  /// Répond à [question] en se servant de [tools] (au plus [rounds] tours
  /// d'outils). null : pas de réponse (Claude prendra le relais).
  static Future<String?> ask({
    required String question,
    required String system,
    required List<HubTool> tools,
    required Future<Object?> Function(HubTool tool, Map<String, dynamic> args) run,
    String context = '',
    int rounds = 5,
  }) async {
    final key = postOverride != null ? '' : await _key();
    if (key.isEmpty && postOverride == null) return null;
    final contents = <Map<String, dynamic>>[
      {
        'role': 'user',
        'parts': [
          {'text': context.isEmpty ? question : '$context\n\nQuestion : $question'},
        ],
      },
    ];
    final decl = [for (final t in tools) declaration(t)];
    for (var round = 0; round <= rounds; round++) {
      final body = <String, dynamic>{
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': contents,
        // Dernier tour : plus d'outils, il doit répondre.
        if (decl.isNotEmpty && round < rounds)
          'tools': [
            {'functionDeclarations': decl},
          ],
      };
      final j = await _post(key, body);
      if (j == null) return null;
      final parts = partsOf(j);
      final calls = [
        for (final p in parts)
          if (p is Map && p['functionCall'] is Map) (p['functionCall'] as Map).cast<String, dynamic>(),
      ];
      if (calls.isEmpty) {
        final text = textOf(parts);
        return text.isEmpty ? null : text;
      }
      contents.add({'role': 'model', 'parts': parts});
      final answers = <Map<String, dynamic>>[];
      for (final c in calls.take(4)) {
        final name = '${c['name']}';
        final tool = tools.where((t) => t.name == name).firstOrNull;
        Object? result;
        if (tool == null) {
          result = {'erreur': 'Outil inconnu : $name'};
        } else {
          try {
            final r = await run(tool, ((c['args'] as Map?) ?? const {}).cast<String, dynamic>());
            final text = r is String ? r : jsonEncode(plain(r));
            result = ToolRouter.cap(PromptShield.wrap(name, text));
          } catch (e) {
            result = {'erreur': '$e'};
          }
        }
        answers.add({
          'functionResponse': {
            'name': name,
            'response': {'result': plain(result)},
          },
        });
      }
      contents.add({'role': 'user', 'parts': answers});
    }
    return null;
  }

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

  /// Les morceaux de la réponse de Gemini.
  static List<Object?> partsOf(Map<String, dynamic> j) {
    final cand = (j['candidates'] as List?)?.firstOrNull;
    final parts = ((cand is Map ? cand['content'] : null) as Map?)?['parts'];
    return parts is List ? parts : const [];
  }

  /// Le texte de la réponse (sans les pensées de Gemini).
  static String textOf(List<Object?> parts) => [
    for (final p in parts)
      if (p is Map && p['text'] is String && p['thought'] != true) p['text'] as String,
  ].join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Gemini passe la main à Claude.
  static bool handsOff(String? text) => text == null || text.trim().toUpperCase().startsWith(handOff);

  static Object? plain(Object? v) => switch (v) {
    null || String() || num() || bool() => v,
    DateTime() => v.toIso8601String(),
    Map() => {for (final e in v.entries) '${e.key}': plain(e.value)},
    Iterable() => [for (final x in v) plain(x)],
    _ => '$v',
  };

  static Future<Map<String, dynamic>?> _post(String key, Map<String, dynamic> body) async {
    final o = postOverride;
    if (o != null) return o(body);
    final client = HttpClient();
    try {
      final order = [?workingModel, ...models.where((m) => m != workingModel)];
      for (final model in order) {
        final req = await client
            .postUrl(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'))
            .timeout(const Duration(seconds: 15));
        req.headers
          ..contentType = ContentType.json
          ..set('x-goog-api-key', key);
        req.add(utf8.encode(jsonEncode(body)));
        final res = await req.close().timeout(const Duration(seconds: 45));
        final text = await utf8.decodeStream(res);
        // Modèle inconnu ou saturé : le suivant.
        if (res.statusCode == 404 || res.statusCode == 503 || res.statusCode == 429) continue;
        if (res.statusCode != 200) return null;
        final j = jsonDecode(text);
        if (j is! Map) return null;
        workingModel = model;
        final um = j['usageMetadata'];
        if (um is Map) {
          final total = (um['totalTokenCount'] as num? ?? 0).toInt();
          final prompt = (um['promptTokenCount'] as num? ?? 0).toInt();
          unawaited(TokenBudget.instance.recordGemini(prompt, total - prompt).catchError((Object _) {}));
        }
        return j.cast<String, dynamic>();
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Qui répond : les règles du cerveau économe, **sans IA** (testables).
class BrainRules {
  BrainRules._();

  /// Les trois réglages.
  static const modes = ['econome', 'equilibre', 'claude'];

  static String label(String m) => switch (m) {
    'equilibre' => 'Équilibré',
    'claude' => 'Toujours Claude',
    _ => 'Économe (conseillé)',
  };

  static String explain(String m) => switch (m) {
    'equilibre' => 'Gemini pour les questions simples, Claude pour tout ce qui touche à tes données.',
    'claude' => 'Tout passe par Claude : le plus fort, mais le plus gourmand en jetons.',
    _ =>
      'Gemini (gratuit) répond à presque tout, avec tes données (agenda, notes, messages…). Claude ne sert que pour '
          'les gros travaux : rédiger, faire un devoir, agir sur l\'écran, réfléchir en profondeur.',
  };

  /// Gemini répond d'abord ? [heavy] : gros travail (rédiger, analyser,
  /// coder…), [deep] : « réfléchis bien », [screen] : il faut voir ou agir
  /// sur l'écran, [docs] : des documents joints.
  static bool geminiFirst(
    String mode, {
    required bool light,
    required bool heavy,
    required bool deep,
    required bool screen,
    required bool docs,
  }) {
    if (mode == 'claude') return false;
    if (screen || docs || deep) return false;
    if (mode == 'econome') return !heavy;
    return light;
  }
}
