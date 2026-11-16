import 'dart:async';
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

  static Future<String?> apiKey() async {
    try {
      return _key ??= await store.readSecret('apiKey');
    } catch (_) {
      return null; // coffre sécurisé indisponible : pas de clé, rien ne casse
    }
  }

  static Future<bool> hasKey() async => _hasKey ??= (await apiKey())?.isNotEmpty == true;

  static Future<void> setApiKey(String? key) async {
    final k = key?.trim();
    await store.writeSecret('apiKey', k == null || k.isEmpty ? null : k);
    _key = k == null || k.isEmpty ? null : k;
    _hasKey = _key != null;
    store.changed();
  }

  /// Oublie la clé gardée en mémoire (relue au prochain appel).
  static void forget() {
    _key = null;
    _hasKey = null;
  }

  /// Un appel à l'API Messages, en flux (le texte arrive au fur et à mesure
  /// via [onText]). Renvoie le contenu complet (liste de blocs, réflexion
  /// comprise, à renvoyer tel quel) et la raison d'arrêt.
  static Future<(List<dynamic>, String)> _call({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    int maxTokens = 8192,
    String effort = 'low',
    void Function(String text)? onText,
  }) async {
    final key = await apiKey();
    if (key == null || key.isEmpty) throw const MissingKey();
    final req = http.Request('POST', Uri.parse('https://api.anthropic.com/v1/messages'))
      ..headers.addAll({
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        // Si un filtre de sécurité refuse la demande, l'API retente toute
        // seule avec un autre modèle adapté.
        'anthropic-beta': 'server-side-fallback-2026-07-01',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'system': system,
        'messages': messages,
        'output_config': {'effort': effort},
        'fallbacks': 'default',
        'stream': true,
        if (tools.isNotEmpty) 'tools': tools,
      });
    final client = http.Client();
    try {
      final http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(seconds: 60));
      } catch (e) {
        throw 'Claude injoignable (vérifie ta connexion internet) : $e';
      }
      if (res.statusCode >= 400) {
        final body = await res.stream.bytesToString();
        Object? msg;
        try {
          msg = ((jsonDecode(body) as Map)['error'] as Map?)?['message'];
        } catch (_) {}
        msg ??= 'erreur ${res.statusCode}';
        throw switch (res.statusCode) {
          401 => 'Clé API Claude refusée : vérifie-la dans le module Claude',
          402 || 403 => 'Claude : $msg (crédit épuisé ou accès refusé)',
          429 => 'Claude est très demandé, réessaie dans un instant',
          529 || 503 => 'Claude est surchargé, réessaie dans un instant',
          _ => 'Claude : $msg',
        };
      }
      final blocks = <int, Map<String, dynamic>>{};
      final json = <int, StringBuffer>{};
      var stop = '';
      final shown = StringBuffer();
      await for (final line
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(minutes: 3))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        final Map<String, dynamic> e;
        try {
          e = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        switch (e['type']) {
          case 'content_block_start':
            final i = (e['index'] as num).toInt();
            blocks[i] = Map<String, dynamic>.from(e['content_block'] as Map);
            if (blocks[i]!['type'] == 'tool_use') json[i] = StringBuffer();
          case 'content_block_delta':
            final i = (e['index'] as num).toInt();
            final b = blocks[i];
            final d = e['delta'] as Map;
            if (b == null) continue;
            switch (d['type']) {
              case 'text_delta':
                b['text'] = '${b['text'] ?? ''}${d['text']}';
                shown.write(d['text']);
                onText?.call('$shown');
              case 'thinking_delta':
                b['thinking'] = '${b['thinking'] ?? ''}${d['thinking']}';
              case 'signature_delta':
                b['signature'] = '${b['signature'] ?? ''}${d['signature']}';
              case 'input_json_delta':
                json[i]?.write(d['partial_json']);
            }
          case 'content_block_stop':
            final i = (e['index'] as num).toInt();
            final buf = json.remove(i);
            if (buf != null) {
              final raw = '$buf'.trim();
              try {
                blocks[i]!['input'] = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
              } catch (_) {
                blocks[i]!['input'] = <String, dynamic>{};
              }
            }
          case 'message_delta':
            final r = (e['delta'] as Map?)?['stop_reason'];
            if (r != null) stop = '$r';
          case 'error':
            throw 'Claude : ${(e['error'] as Map?)?['message'] ?? 'erreur'}';
        }
      }
      final keys = blocks.keys.toList()..sort();
      return ([for (final k in keys) blocks[k]], stop);
    } finally {
      client.close();
    }
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
    void Function(String text)? onText,
    String effort = 'low',
  }) async {
    final defs = [
      for (final t in tools)
        {'name': t.name, 'description': t.description, 'input_schema': t.toJson()['inputSchema']},
    ];
    for (var round = 0; round < 8; round++) {
      final (content, stop) = await _call(
        system: system,
        messages: history,
        tools: defs,
        effort: effort,
        onText: onText,
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
        if (stop == 'max_tokens' && text.isEmpty) {
          return 'Ma réponse était trop longue, reformule ta question.';
        }
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
  static bool isWriteAction(HubTool t) => ClaudeBridge.isWriteAction(t);
}

class MissingKey implements Exception {
  const MissingKey();
  @override
  String toString() => 'Ajoute ta clé API Claude dans le module Claude';
}
