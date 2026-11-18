import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/safe_open.dart';
import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/hub_module.dart';
import 'tutor.dart';
import '../../core/browser.dart';

// ---------------------------------------------------------------------------
// Outils MCP personnalisés
// ---------------------------------------------------------------------------

/// Un serveur MCP ajouté par toi (adresse HTTPS, ou locale), dont Claude peut
/// utiliser les outils. Chaque appel te demande la permission.
class McpServer {
  McpServer(this.id, this.name, this.url);
  final String id;
  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};
  factory McpServer.fromJson(Map j) => McpServer('${j['id']}', '${j['name']}', '${j['url']}');

  String get slug {
    final s = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return s.isEmpty ? 'srv' : (s.length > 16 ? s.substring(0, 16) : s);
  }

  /// Adresse acceptée : HTTPS, ou HTTP seulement sur ce PC.
  static bool validUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasAuthority) return false;
    if (u.scheme == 'https') return true;
    return u.scheme == 'http' &&
        (u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '::1');
  }
}

/// Client MCP minimal (transport « Streamable HTTP », protocole 2025-06-18).
class McpClient {
  McpClient(this.url, [this.token, http.Client? client]) : _http = client ?? http.Client();
  final String url;
  final String? token;
  final http.Client _http;
  String? _session;
  int _id = 0;
  bool _ready = false;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'accept': 'application/json, text/event-stream',
    'mcp-protocol-version': '2025-06-18',
    if (token != null && token!.isNotEmpty) 'authorization': 'Bearer $token',
    'mcp-session-id': ?_session,
  };

  /// Lit une réponse JSON-RPC (JSON direct ou flux SSE).
  static Map<String, dynamic>? parseResponse(String body, int id) {
    final t = body.trim();
    if (t.startsWith('{')) {
      final j = jsonDecode(t);
      return j is Map<String, dynamic> ? j : null;
    }
    for (final line in const LineSplitter().convert(t)) {
      if (!line.startsWith('data:')) continue;
      try {
        final j = jsonDecode(line.substring(5).trim());
        if (j is Map<String, dynamic> &&
            (j['id'] == id || j.containsKey('result') || j.containsKey('error'))) {
          if (j['id'] == null || j['id'] == id) return j;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Object?> _rpc(String method, [Map<String, dynamic>? params, bool notify = false]) async {
    final id = ++_id;
    final r = await _http
        .post(
          Uri.parse(url),
          headers: _headers,
          body: jsonEncode({
            'jsonrpc': '2.0',
            if (!notify) 'id': id,
            'method': method,
            'params': ?params,
          }),
        )
        .timeout(const Duration(seconds: 40));
    final s = r.headers['mcp-session-id'];
    if (s != null && s.isNotEmpty) _session = s;
    if (r.statusCode == 401 || r.statusCode == 403) throw 'Accès refusé par le serveur (jeton ?)';
    if (r.statusCode >= 400) throw 'Serveur MCP : erreur ${r.statusCode}';
    if (notify) return null;
    final j = parseResponse(utf8.decode(r.bodyBytes), id);
    if (j == null) throw 'Réponse du serveur MCP illisible';
    if (j['error'] is Map) throw 'Serveur MCP : ${(j['error'] as Map)['message']}';
    return j['result'];
  }

  Future<void> _init() async {
    if (_ready) return;
    await _rpc('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': {},
      'clientInfo': {'name': 'Mon Hub', 'version': '1.0'},
    });
    await _rpc('notifications/initialized', null, true);
    _ready = true;
  }

  Future<List<Map<String, dynamic>>> tools() async {
    await _init();
    final r = await _rpc('tools/list', {});
    return [
      for (final t in ((r as Map?)?['tools'] as List?) ?? const [])
        if (t is Map) t.cast<String, dynamic>(),
    ];
  }

  Future<String> call(String name, Map<String, dynamic> args) async {
    await _init();
    final r = await _rpc('tools/call', {'name': name, 'arguments': args}) as Map?;
    final parts = [
      for (final c in (r?['content'] as List?) ?? const [])
        if (c is Map) c['type'] == 'text' ? '${c['text']}' : jsonEncode(c),
    ];
    final text = parts.join('\n');
    if (r?['isError'] == true) throw text.isEmpty ? 'L\'outil a échoué' : text;
    return text;
  }
}

/// Les serveurs MCP enregistrés et leurs outils (vus par Claude comme des
/// actions de Mon Hub, toujours avec permission).
class McpTools {
  McpTools._();

  static List<McpServer> get servers => [
    for (final s in (ClaudeApi.store.getJson<List<dynamic>>('mcp.servers') ?? const []))
      if (s is Map) McpServer.fromJson(s),
  ];

  static Future<void> saveServers(List<McpServer> l) =>
      ClaudeApi.store.setJson('mcp.servers', [for (final s in l) s.toJson()]);

  static Future<String?> token(String id) async {
    try {
      return await ClaudeApi.store.readSecret('mcp.token.$id');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setToken(String id, String? t) =>
      ClaudeApi.store.writeSecret('mcp.token.$id', t == null || t.isEmpty ? null : t);

  static List<HubTool> _cache = const [];
  static DateTime? _at;

  /// Change quand la liste d'outils change (le pont la republie).
  static final changed = ValueNotifier<int>(0);

  static List<HubTool> get cached => _cache;

  /// Relit les outils de tous les serveurs (au plus toutes les 5 minutes).
  static Future<List<HubTool>> refresh({bool force = false}) async {
    final at = _at;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _cache;
    }
    _at = DateTime.now();
    final out = <HubTool>[];
    for (final s in servers) {
      try {
        final client = McpClient(s.url, await token(s.id));
        for (final t in await client.tools()) {
          final schema = (t['inputSchema'] as Map?) ?? const {};
          final props = (schema['properties'] as Map?) ?? const {};
          var name = 'mcp_${s.slug}_${'${t['name']}'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
          if (name.length > 60) name = name.substring(0, 60);
          out.add(
            HubTool(
              name: name,
              description: '[${s.name}] ${t['description'] ?? t['name']}',
              params: {
                for (final e in props.entries)
                  '${e.key}': (
                    '${(e.value is Map ? (e.value as Map)['type'] : null) ?? 'string'}',
                    '${(e.value is Map ? (e.value as Map)['description'] : null) ?? ''}',
                  ),
              },
              required: [for (final r in (schema['required'] as List?) ?? const []) '$r'],
              run: (args) => client.call('${t['name']}', args),
            ),
          );
        }
      } catch (e) {
        debugPrint('MCP ${s.name} : $e');
      }
    }
    final before = _cache.map((t) => t.name).join(',');
    _cache = out;
    ClaudeBridge.extras.value = out;
    if (before != out.map((t) => t.name).join(',')) changed.value++;
    return out;
  }
}

// ---------------------------------------------------------------------------
// Raccourcis vocaux
// ---------------------------------------------------------------------------

/// Un raccourci vocal à toi : une phrase → une action, sans passer par l'IA
/// (« ouvre la calculatrice », « mode révision »…).
class VoiceSkill {
  VoiceSkill(this.phrase, this.kind, this.value);

  /// Phrase qui déclenche (début de ce que tu dis).
  final String phrase;

  /// 'url' (ouvrir un site), 'app' (lancer un programme Windows), 'say'
  /// (Clicky dit une phrase), 'ask' (une question toute faite à Clicky).
  final String kind;
  final String value;

  static const kinds = {
    'url': 'Ouvrir un site',
    'app': 'Lancer un programme',
    'say': 'Dire une phrase',
    'ask': 'Poser une question à Clicky',
  };

  Map<String, dynamic> toJson() => {'p': phrase, 'k': kind, 'v': value};
  factory VoiceSkill.fromJson(Map j) => VoiceSkill('${j['p']}', '${j['k']}', '${j['v']}');

  static List<VoiceSkill> get all => [
    for (final s in (ClaudeApi.store.getJson<List<dynamic>>('clicky.skills') ?? const []))
      if (s is Map) VoiceSkill.fromJson(s),
  ];

  static Future<void> save(List<VoiceSkill> l) =>
      ClaudeApi.store.setJson('clicky.skills', [for (final s in l) s.toJson()]);

  static List<VoiceSkill> examples() => [
    VoiceSkill('ouvre la calculatrice', 'app', 'calc.exe'),
    VoiceSkill('ouvre youtube', 'url', 'https://www.youtube.com'),
    VoiceSkill('mode revision', 'ask', 'Fais-moi réviser mes notions à revoir avec un quiz.'),
  ];

  /// Le raccourci qui correspond à ce que tu as dit (et le reste de la
  /// phrase), s'il y en a un.
  static (VoiceSkill, String)? match(String said, [List<VoiceSkill>? list]) {
    var n = normalize(said);
    n = n.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|he) )?clicky ?'), '').trim();
    for (final s in list ?? all) {
      final p = normalize(s.phrase);
      if (p.isEmpty) continue;
      if (n == p || n.startsWith('$p ')) return (s, n.substring(p.length).trim());
    }
    return null;
  }

  /// Fait l'action. Renvoie la phrase à dire / la question à poser.
  Future<(String? say, String? ask)> run(String rest) async {
    switch (kind) {
      case 'url':
        final u = Uri.tryParse(value);
        if (u != null) await Browser.open(u.toString());
        return ('C\'est ouvert.', null);
      case 'app':
        if (!kIsWeb && Platform.isWindows) {
          // « start » de Windows : pas de commande arbitraire, juste le nom
          // du programme choisi par toi.
          await SafeOpen.launch(value);
          return ('Je lance ${value.replaceAll('.exe', '')}.', null);
        }
        return ('Je ne peux lancer de programme que sur Windows.', null);
      case 'say':
        return (value, null);
      default:
        return (null, rest.isEmpty ? value : '$value $rest');
    }
  }
}
