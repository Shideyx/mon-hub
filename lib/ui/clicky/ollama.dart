import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/claude_api.dart';

/// Cerveau local et gratuit pour Nexo : Ollama (ollama.com), qui fait
/// tourner un modèle d'IA directement sur le PC. Aucune clé, aucun compte,
/// rien n'est envoyé sur internet. Il faut un modèle qui comprend les images
/// (« qwen2.5vl », « gemma3 », « llama3.2-vision »…).
class Ollama {
  Ollama._();

  static String get url =>
      (ClaudeApi.store.getJson<String>('ollama.url') ?? 'http://127.0.0.1:11434').replaceAll(RegExp(r'/+$'), '');
  static String get model => ClaudeApi.store.getJson<String>('ollama.model') ?? 'qwen2.5vl';

  static const suggested = ['qwen2.5vl', 'gemma3', 'llama3.2-vision', 'minicpm-v'];

  /// Modèles installés (vide si Ollama n'est pas lancé).
  static Future<List<String>> installed() async {
    try {
      final r = await http.get(Uri.parse('$url/api/tags')).timeout(const Duration(seconds: 3));
      final j = jsonDecode(r.body) as Map;
      return [for (final m in (j['models'] as List? ?? const [])) '${(m as Map)['name']}'];
    } catch (_) {
      return const [];
    }
  }

  /// Une réponse en flux (le texte arrive au fur et à mesure via [onText]).
  static Future<String> chat({
    required String system,
    required List<(String, String)> memory,
    required String question,
    List<String> imagesB64 = const [],
    void Function(String text)? onText,
  }) async {
    final req = http.Request('POST', Uri.parse('$url/api/chat'))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'messages': [
          {'role': 'system', 'content': system},
          for (final (u, a) in memory) ...[
            {'role': 'user', 'content': u},
            {'role': 'assistant', 'content': a},
          ],
          {'role': 'user', 'content': question, if (imagesB64.isNotEmpty) 'images': imagesB64},
        ],
      });
    final client = http.Client();
    try {
      final http.StreamedResponse res;
      try {
        res = await client.send(req).timeout(const Duration(seconds: 20));
      } catch (_) {
        throw 'Ollama ne répond pas. Installe-le depuis ollama.com, lance-le, puis '
            'tape « ollama pull $model » dans un terminal.';
      }
      final out = StringBuffer();
      await for (final line
          in res.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(minutes: 4))) {
        if (line.trim().isEmpty) continue;
        final Map j;
        try {
          j = jsonDecode(line) as Map;
        } catch (_) {
          continue;
        }
        if (j['error'] != null) {
          final e = '${j['error']}';
          throw e.contains('not found')
              ? 'Le modèle « $model » n\'est pas installé : tape « ollama pull $model » dans un terminal.'
              : 'Ollama : $e';
        }
        final piece = (j['message'] as Map?)?['content'];
        if (piece is String && piece.isNotEmpty) {
          out.write(piece);
          onText?.call('$out');
        }
        if (j['done'] == true) break;
      }
      return '$out'.trim();
    } finally {
      client.close();
    }
  }
}
