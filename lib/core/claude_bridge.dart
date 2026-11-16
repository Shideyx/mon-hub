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

  List<HubTool> get tools => [for (final m in hub.enabled) ...m.tools];

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
      hub.addListener(() {
        if (_server == server) writeInfo(); // modules activés / désactivés
      });
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

  /// Convertit le résultat en JSON simple (dates en texte).
  static Object? plain(Object? v) => switch (v) {
    null || String() || num() || bool() => v,
    DateTime() => v.toIso8601String(),
    Map() => {for (final e in v.entries) '${e.key}': plain(e.value)},
    Iterable() => [for (final x in v) plain(x)],
    _ => '$v',
  };
}
