import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'hub_controller.dart';
import 'hub_module.dart';

/// Pont local entre l'appli Claude (sur PC) et Mon Hub.
///
/// Mon Hub ouvre un petit serveur sur 127.0.0.1 (jamais accessible depuis
/// internet) et écrit son adresse + une clé secrète dans un fichier que lit
/// l'extension « Mon Hub » installée dans Claude. Claude peut alors lire
/// l'agenda, les messages… et agir dans l'appli, en demandant ta permission.
class ClaudeBridge {
  ClaudeBridge(this.hub);
  final HubController hub;
  HttpServer? _server;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Dossier partagé avec l'extension Claude.
  static String? get folder {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      return appData == null ? null : '$appData\\MonHub';
    }
    final home = env['HOME'];
    if (home == null) return null;
    return Platform.isMacOS ? '$home/Library/Application Support/MonHub' : '$home/.config/MonHub';
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  List<HubTool> get tools => [
    for (final m in hub.enabled) ...m.tools,
    ...extras.value,
    ...?appTools?.call(),
  ];

  /// Outils de l'appli elle-même (Clicky : contrôle du PC, réparation du
  /// micro), pour que Claude Code puisse aussi s'en servir.
  static List<HubTool> Function()? appTools;

  /// Outils en plus des modules (serveurs MCP ajoutés dans les réglages de
  /// Clicky).
  static final extras = ValueNotifier<List<HubTool>>(const []);

  /// Demande la permission avant une action qui envoie ou modifie quelque
  /// chose, quand c'est Claude Code (Clicky) qui l'appelle via /mcp.
  static Future<bool> Function(HubTool tool, Map<String, dynamic> args)? confirm;

  Future<void> start() async {
    if (!supported || _server != null) return;
    final dir = folder;
    if (dir == null) return;
    try {
      final key = List.generate(32, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      await Directory(dir).create(recursive: true);
      Future<void> writeInfo() => File('$dir${Platform.pathSeparator}bridge.json').writeAsString(
        jsonEncode({
          'port': server.port,
          'key': key,
          'pid': pid,
          'tools': [for (final t in tools) t.toJson()],
        }),
      );
      await writeInfo();
      void refresh() {
        if (_server == server) writeInfo(); // modules activés / désactivés
      }

      hub.addListener(refresh);
      extras.addListener(refresh);
      server.listen((req) => _handle(req, key));
    } catch (e) {
      debugPrint('Pont Claude indisponible : $e');
    }
  }

  Future<void> _handle(HttpRequest req, String key) async {
    final res = req.response..headers.contentType = ContentType.json;
    Future<void> reply(int code, Object body) async {
      res.statusCode = code;
      res.write(jsonEncode(body));
      await res.close();
    }

    if (req.headers.value('authorization') != 'Bearer $key') {
      return reply(401, {'error': 'Clé invalide'});
    }
    if (req.uri.path == '/mcp') return _mcp(req, res);
    if (req.method == 'GET' && req.uri.path == '/tools') {
      return reply(200, {
        'tools': [for (final t in tools) t.toJson()],
      });
    }
    if (req.method == 'POST' && req.uri.path == '/call') {
      try {
        final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        final name = body['name'] as String;
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) return await reply(404, {'error': 'Action inconnue : $name'});
        final args = (body['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
        final result = await tool.run(args);
        return await reply(200, {'result': plain(result)});
      } catch (e) {
        return reply(200, {'error': '$e'});
      }
    }
    return reply(404, {'error': 'Introuvable'});
  }

  /// Serveur MCP minimal (HTTP « streamable », réponses JSON) : c'est par là
  /// que Claude Code, lancé par Clicky avec ton abonnement Claude, utilise
  /// les actions de Mon Hub (agenda, notes, messages…).
  Future<void> _mcp(HttpRequest req, HttpResponse res) async {
    if (req.method == 'DELETE') {
      res.statusCode = 200;
      return res.close();
    }
    if (req.method != 'POST') {
      res.statusCode = 405;
      res.headers.set('allow', 'POST');
      return res.close();
    }
    Object? body;
    try {
      body = jsonDecode(await utf8.decodeStream(req));
    } catch (_) {
      res.statusCode = 400;
      res.write(jsonEncode(_rpcError(null, -32700, 'JSON invalide')));
      return res.close();
    }
    final batch = body is List;
    final messages = batch ? body : [body];
    final replies = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m is! Map) continue;
      final reply = await _rpc(m.cast<String, dynamic>());
      if (reply != null) replies.add(reply);
    }
    if (replies.isEmpty) {
      res.statusCode = 202; // que des notifications
      return res.close();
    }
    res.statusCode = 200;
    res.write(jsonEncode(batch ? replies : replies.first));
    return res.close();
  }

  static Map<String, dynamic> _rpcError(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  Future<Map<String, dynamic>?> _rpc(Map<String, dynamic> m) async {
    final id = m['id'];
    final method = m['method'];
    if (id == null) return null; // notification (ex. « initialized »)
    final params = (m['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic> ok(Object result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    switch (method) {
      case 'initialize':
        return ok({
          'protocolVersion': params['protocolVersion'] ?? '2025-06-18',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'monhub', 'version': '1.0.0'},
          'instructions':
              'Actions de l\'appli Mon Hub de la personne : agenda, École Directe, mails, '
              'Discord, Instagram, livres, Roblox, Google Drive.',
        });
      case 'ping':
        return ok({});
      case 'tools/list':
        return ok({
          'tools': [
            for (final t in tools)
              {
                'name': t.name,
                'description': t.description,
                'inputSchema': t.toJson()['inputSchema'],
              },
          ],
        });
      case 'tools/call':
        final name = '${params['name']}';
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) return _rpcError(id, -32602, 'Action inconnue : $name');
        final args = (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
        Map<String, dynamic> result(String text, {bool error = false}) => ok({
          'content': [
            {'type': 'text', 'text': text},
          ],
          'isError': error,
        });
        try {
          final ask = confirm;
          if (ask != null && isWriteAction(tool) && !await ask(tool, args)) {
            return result('La personne a refusé cette action.', error: true);
          }
          final out = plain(await tool.run(args));
          return result(out is String ? out : jsonEncode(out));
        } catch (e) {
          return result('$e', error: true);
        }
      default:
        return _rpcError(id, -32601, 'Méthode inconnue : $method');
    }
  }

  /// Actions qui changent quelque chose : on demande la permission avant.
  static bool isWriteAction(HubTool t) =>
      RegExp(r'envoyer|ajouter|supprimer|modifier|repondre|noter|ranger$|ranger_annuler$|^mcp_|^pc_commande$|^pc_ecrire').hasMatch(t.name);

  /// Convertit le résultat en JSON simple (dates en texte).
  static Object? plain(Object? v) => switch (v) {
    null || String() || num() || bool() => v,
    DateTime() => v.toIso8601String(),
    Map() => {for (final e in v.entries) '${e.key}': plain(e.value)},
    Iterable() => [for (final x in v) plain(x)],
    _ => '$v',
  };
}
