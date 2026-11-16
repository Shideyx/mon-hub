import 'dart:convert';

import 'package:http/http.dart' as http;

import 'claude_bridge.dart';
import 'hub_module.dart';
import 'module_store.dart';

/// Accès direct à Claude (API Anthropic) avec ta propre clé API.
///
/// Sert au compagnon « Clicky » (qui voit l'écran de Mon Hub, répond à voix
/// haute et montre les boutons) et à la discussion intégrée du module Claude.
/// La clé se crée sur console.anthropic.com (facturée à l'usage) et reste
/// chiffrée sur l'appareil.
class ClaudeApi {
  ClaudeApi._();

  static final ModuleStore store = ModuleStore()..bind('claude');

  static const models = {
    'claude-opus-5-5': 'Claude Opus 5.5 (le plus malin)',
    'claude-sonnet-5-5': 'Claude Sonnet 5.5 (plus rapide)',
    'claude-haiku-5-5': 'Claude Haiku 5.5 (le plus rapide, le moins cher)',
  };

  static String get model {
    final m = store.getJson<String>('model');
    return models.containsKey(m) ? m! : 'claude-opus-5-5';
  }

  static Future<void> setModel(String m) => store.setJson('model', m);

  static String? _key;
  static bool? _hasKey;

  static Future<String?> apiKey() async => _key ??= await store.readSecret('apiKey');
  static Future<bool> hasKey() async => _hasKey ??= (await apiKey())?.isNotEmpty == true;

  static Future<void> setApiKey(String? key) async {
    final k = key?.trim();
    await store.writeSecret('apiKey', k == null || k.isEmpty ? null : k);
    _key = k == null || k.isEmpty ? null : k;
    _hasKey = _key != null;
    store.changed();
  }

  /// Un appel à l'API Messages. [messages] suit le format de l'API.
  /// Renvoie le contenu (liste de blocs) et la raison d'arrêt.
  static Future<(List<dynamic>, String)> _call({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    int maxTokens = 4096,
    String effort = 'low',
  }) async {
    final key = await apiKey();
    if (key == null || key.isEmpty) throw const MissingKey();
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
              // Si un filtre de sécurité refuse la demande, l'API retente
              // toute seule avec un autre modèle adapté.
              'anthropic-beta': 'server-side-fallback-2026-07-01',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': maxTokens,
              'system': system,
              'messages': messages,
              'output_config': {'effort': effort},
              'fallbacks': 'default',
              if (tools.isNotEmpty) 'tools': tools,
            }),
          )
          .timeout(const Duration(minutes: 3));
    } catch (e) {
      throw 'Claude injoignable (vérifie ta connexion internet) : $e';
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      final msg = (j['error'] as Map?)?['message'] ?? 'erreur ${res.statusCode}';
      throw switch (res.statusCode) {
        401 => 'Clé API Claude refusée : vérifie-la dans le module Claude',
        402 || 403 => 'Claude : $msg (crédit épuisé ou accès refusé)',
        429 => 'Claude est très demandé, réessaie dans un instant',
        529 || 503 => 'Claude est surchargé, réessaie dans un instant',
        _ => 'Claude : $msg',
      };
    }
    return ((j['content'] as List?) ?? const [], '${j['stop_reason']}');
  }

  /// Conversation avec, en option, les actions des modules de Mon Hub
  /// (lire l'agenda, les notes, envoyer un message…). Les actions qui
  /// modifient quelque chose passent d'abord par [confirm].
  ///
  /// [history] est complétée avec les tours de cette réponse ; renvoie le
  /// texte final.
  static Future<String> chat({
    required String system,
    required List<Map<String, dynamic>> history,
    List<HubTool> tools = const [],
    Future<bool> Function(HubTool tool, Map<String, dynamic> args)? confirm,
    void Function(String status)? onStatus,
    String effort = 'low',
  }) async {
    final defs = [
      for (final t in tools)
        {
          'name': t.name,
          'description': t.description,
          'input_schema': t.toJson()['inputSchema'],
        },
    ];
    for (var round = 0; round < 8; round++) {
      final (content, stop) = await _call(
        system: system,
        messages: history,
        tools: defs,
        effort: effort,
      );
      if (stop == 'refusal') {
        return 'Désolé, je ne peux pas t\'aider pour cette demande.';
      }
      // On renvoie le contenu tel quel (blocs de réflexion compris).
      history.add({'role': 'assistant', 'content': content});
      final uses = [
        for (final b in content)
          if (b is Map && b['type'] == 'tool_use') b,
      ];
      if (stop != 'tool_use' || uses.isEmpty) {
        final text = [
          for (final b in content)
            if (b is Map && b['type'] == 'text') b['text'],
        ].join('\n').trim();
        if (stop == 'max_tokens' && text.isEmpty) return 'Ma réponse était trop longue, reformule ta question.';
        return text;
      }
      final results = <Map<String, dynamic>>[];
      for (final u in uses) {
        final tool = tools.where((t) => t.name == u['name']).firstOrNull;
        final args = (u['input'] as Map?)?.cast<String, dynamic>() ?? {};
        Object? out;
        var error = false;
        if (tool == null) {
          out = 'Action inconnue';
          error = true;
        } else if (isWriteAction(tool) && confirm != null && !await confirm(tool, args)) {
          out = 'La personne a refusé cette action.';
          error = true;
        } else {
          onStatus?.call('J\'utilise ${tool.name.replaceAll('_', ' ')}…');
          try {
            out = ClaudeBridge.plain(await tool.run(args));
          } catch (e) {
            out = '$e';
            error = true;
          }
        }
        results.add({
          'type': 'tool_result',
          'tool_use_id': u['id'],
          'content': out is String ? out : jsonEncode(out),
          if (error) 'is_error': true,
        });
      }
      history.add({'role': 'user', 'content': results});
    }
    return 'J\'ai fait plusieurs actions mais je n\'ai pas pu terminer, réessaie.';
  }

  /// Actions qui changent quelque chose : on demande la permission avant.
  static bool isWriteAction(HubTool t) =>
      RegExp(r'envoyer|ajouter|supprimer|modifier|repondre|noter').hasMatch(t.name);
}

class MissingKey implements Exception {
  const MissingKey();
  @override
  String toString() => 'Ajoute ta clé API Claude dans le module Claude';
}
