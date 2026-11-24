import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'module_store.dart';

/// Un fichier que le PC met à disposition du téléphone.
class SharedFile {
  SharedFile(this.id, this.path, this.name, this.size);
  final String id;
  final String path;
  final String name;
  final int size;
  final added = DateTime.now();

  Map<String, Object> toJson() => {'id': id, 'nom': name, 'taille': size};
}

/// Un fichier reçu du téléphone.
class ReceivedFile {
  ReceivedFile(this.path, this.name, this.size);
  final String path;
  final String name;
  final int size;
  final at = DateTime.now();
}

/// **Mon téléphone** : le téléphone et le PC reliés par le Wi-Fi de la
/// maison, sans câble, sans cloud et sans serveur à nous.
///
/// Mon Hub ouvre un petit serveur sur le réseau local ; le téléphone y accède
/// par un **lien secret** (128 bits au hasard, dans le QR code) : envoyer des
/// photos et fichiers au PC, récupérer ceux du PC, partager le presse-papier,
/// et piloter le PC (son, musique, diapos, souris, verrouiller, veille,
/// éteindre). Seuls les appareils du réseau local sont acceptés.
class PhoneLink extends ChangeNotifier {
  PhoneLink._();
  static final instance = PhoneLink._();

  /// Port fixe : le lien enregistré sur le téléphone reste bon d'un
  /// lancement à l'autre.
  static const port = 47615;

  /// Plus gros fichier accepté (4 Go).
  static const maxUpload = 4 * 1024 * 1024 * 1024;
  static const maxJson = 64 * 1024;

  HttpServer? _server;
  String? _token;
  String? ip;
  String? error;

  /// PC → téléphone.
  final shared = <SharedFile>[];

  /// Téléphone → PC (depuis le lancement).
  final received = <ReceivedFile>[];

  /// Branché par l'appli : notification sur le PC.
  void Function(String title, String body)? notify;

  /// Branché par l'appli : la télécommande (Windows). Renvoie un message
  /// pour le téléphone, ou null si l'action est inconnue.
  Future<String?> Function(String action, Map<String, dynamic> args)? command;

  /// Branché par l'appli : presse-papier du PC.
  Future<String?> Function()? readClipboard;
  Future<void> Function(String text)? writeClipboard;

  /// Branché par l'appli : les fichiers de la page du téléphone
  /// (`assets/phone/…`).
  Future<Uint8List?> Function(String path)? loadAsset;

  /// Autres pages servies par ce serveur (la soirée) : renvoie true si la
  /// requête a été traitée. [segments] = le chemin découpé.
  final extraRoutes = <Future<bool> Function(HttpRequest req, List<String> segments)>[];

  /// Dossier imposé (tests).
  @visibleForTesting
  String? receiveDirOverride;
  @visibleForTesting
  static String? lanOverride;

  bool get enabled => ModuleStore.prefs.getBool('app.phone.on') ?? false;
  bool get running => _server != null;
  int get boundPort => _server?.port ?? 0;

  /// Le lien à ouvrir sur le téléphone (QR code).
  Uri? get link {
    final t = _token;
    final host = ip;
    if (t == null || host == null || _server == null) return null;
    return Uri(scheme: 'http', host: host, port: _server!.port, path: '/t/$t/');
  }

  /// L'adresse de base (pour les autres pages, ex. la soirée).
  Uri? get base {
    final host = ip;
    if (host == null || _server == null) return null;
    return Uri(scheme: 'http', host: host, port: _server!.port, path: '/');
  }

  Future<void> setEnabled(bool on) async {
    await ModuleStore.prefs.setBool('app.phone.on', on);
    if (on) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  static String newToken() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  /// Démarre si c'est activé (au lancement de Mon Hub). [force] : même si
  /// ce n'est pas activé (la soirée en a besoin).
  Future<void> start({bool force = false}) async {
    if ((!enabled && !force) || _server != null) return;
    var t = ModuleStore.prefs.getString('app.phone.token');
    if (t == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(t)) {
      t = newToken();
      await ModuleStore.prefs.setString('app.phone.token', t);
    }
    _token = t;
    try {
      HttpServer s;
      try {
        s = await HttpServer.bind(InternetAddress.anyIPv4, port);
      } on SocketException {
        s = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }
      _server = s;
      s.listen((r) => unawaited(_handle(r)));
      ip = await lanAddress();
      error = ip == null ? 'Pas de Wi-Fi trouvé : branche le PC au Wi-Fi de la maison.' : null;
    } catch (e) {
      error = 'Le lien n\'a pas pu démarrer ($e).';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
    notifyListeners();
  }

  /// Nouveau lien : les téléphones reliés avant ne marchent plus.
  Future<void> newLink() async {
    final t = newToken();
    await ModuleStore.prefs.setString('app.phone.token', t);
    _token = t;
    notifyListeners();
  }

  /// Met un fichier du PC à disposition du téléphone.
  Future<SharedFile?> share(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final name = path.split(RegExp(r'[\\/]')).last;
    final r = Random.secure();
    final id = [for (var i = 0; i < 6; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    final sf = SharedFile(id, path, name, await f.length());
    shared.insert(0, sf);
    if (shared.length > 30) shared.removeRange(30, shared.length);
    notifyListeners();
    return sf;
  }

  void unshare(String id) {
    shared.removeWhere((f) => f.id == id);
    notifyListeners();
  }

  // ---------------------------------------------------------- Réseau
  /// Adresse privée (192.168.x.x, 10.x.x.x, 172.16-31.x.x) du PC sur le Wi-Fi.
  static Future<String?> lanAddress() async {
    if (lanOverride != null) return lanOverride;
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String? best;
      var bestScore = -1;
      for (final i in all) {
        final name = i.name.toLowerCase();
        final virtual = RegExp(r'vethernet|virtual|vmware|vbox|hyper-v|wsl|docker|loopback|tailscale|zerotier|vpn')
            .hasMatch(name);
        for (final a in i.addresses) {
          if (!isPrivate(a.address)) continue;
          var score = virtual ? 0 : 1;
          if (RegExp(r'wi-?fi|wlan|wireless|sans fil').hasMatch(name)) score += 2;
          if (a.address.startsWith('192.168.')) score += 1;
          if (score > bestScore) {
            best = a.address;
            bestScore = score;
          }
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  static bool isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((x) => x == null)) return false;
    final a = p[0]!;
    final b = p[1]!;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254);
  }

  /// Appareils acceptés : le réseau local (et ce PC).
  static bool localClient(String ip) => isPrivate(ip) || ip == '127.0.0.1';

  /// Compare deux clés en temps constant.
  static bool sameKey(String a, String? b) {
    if (b == null || a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  /// Nom de fichier sûr (pas de dossier, pas de caractères interdits).
  static String safeName(String raw) {
    var n = raw.split(RegExp(r'[\\/]')).last;
    n = n.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').trim();
    n = n.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'[. ]+$'), '');
    if (RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)(\.|$)', caseSensitive: false).hasMatch(n)) n = '_$n';
    if (n.isEmpty) n = 'fichier';
    if (n.length > 120) {
      final dot = n.lastIndexOf('.');
      final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
      n = n.substring(0, 120 - ext.length) + ext;
    }
    return n;
  }

  /// Le dossier des fichiers reçus : Téléchargements\Depuis mon téléphone.
  Future<Directory> receiveDir() async {
    final o = receiveDirOverride;
    if (o != null) return Directory(o);
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return Directory('$home${sep}Downloads${sep}Depuis mon téléphone');
  }

  static Future<File> uniqueFile(Directory dir, String name) async {
    final sep = Platform.pathSeparator;
    var f = File('${dir.path}$sep$name');
    if (!await f.exists()) return f;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 2; i < 10000; i++) {
      f = File('${dir.path}$sep$stem ($i)$ext');
      if (!await f.exists()) return f;
    }
    return File('${dir.path}$sep$stem ${DateTime.now().millisecondsSinceEpoch}$ext');
  }

  // ---------------------------------------------------------- Requêtes
  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'png': 'image/png',
    'json': 'application/json',
  };

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final remote = req.connectionInfo?.remoteAddress.address ?? '';
      if (!localClient(remote)) return await send(res, 403, 'text/plain', utf8.encode('Refusé'));
      res.headers
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Cache-Control', 'no-store')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Frame-Options', 'DENY');
      final segs = req.uri.pathSegments;
      for (final r in extraRoutes) {
        if (await r(req, segs)) return;
      }
      if (segs.length < 2 || segs[0] != 't' || !sameKey(segs[1], _token)) {
        return await send(res, 404, 'text/plain', const []);
      }
      // Lien sans « / » final : on le rajoute (sinon la page ne trouve pas ses fichiers).
      if (segs.length == 2) {
        res.statusCode = 302;
        res.headers.set('Location', '/t/${segs[1]}/');
        return await res.close();
      }
      final rest = segs.sublist(2).join('/');
      switch (rest) {
        case '' || 'index.html':
          return await asset(res, 'phone/index.html');
        case 'phone.js' || 'phone.css':
          return await asset(res, 'phone/$rest');
        case 'icone.png':
          return await asset(res, 'logo.png');
        case 'api/etat':
          return await sendJson(res, await state());
        case 'api/texte' when req.method == 'POST':
          final text = await readText(req, maxJson);
          if (text == null) return await send(res, 413, 'text/plain', const []);
          await writeClipboard?.call(text);
          notify?.call('📱 Texte reçu du téléphone', 'Il est dans ton presse-papier : Ctrl + V pour le coller.');
          return await sendJson(res, {'ok': true});
        case 'api/envoyer' when req.method == 'POST':
          return await _receive(req);
        case 'api/commande' when req.method == 'POST':
          final body = await readText(req, maxJson);
          Map<String, dynamic> m = {};
          try {
            final d = jsonDecode(body ?? '');
            if (d is Map<String, dynamic>) m = d;
          } catch (_) {}
          final action = '${m['action'] ?? ''}';
          final msg = await command?.call(action, m);
          return await sendJson(res, {'ok': msg != null, 'message': msg ?? 'Pas possible sur cet appareil.'});
      }
      if (rest.startsWith('api/fichier/') && req.method == 'GET') {
        final id = rest.substring('api/fichier/'.length);
        final f = shared.where((s) => s.id == id).firstOrNull;
        if (f == null || !await File(f.path).exists()) return await send(res, 404, 'text/plain', const []);
        res.headers.contentType = ContentType.binary;
        res.headers.set(
          'Content-Disposition',
          'attachment; filename="${f.name.replaceAll(RegExp(r'[^\x20-\x7E]|"'), '_')}"; '
              "filename*=UTF-8''${Uri.encodeComponent(f.name)}",
        );
        res.contentLength = await File(f.path).length();
        await res.addStream(File(f.path).openRead());
        return await res.close();
      }
      return await send(res, 404, 'text/plain', const []);
    } catch (_) {
      try {
        await send(res, 500, 'text/plain', const []);
      } catch (_) {}
    }
  }

  /// Ce que la page du téléphone affiche.
  Future<Map<String, Object?>> state() async {
    String? clip;
    try {
      clip = await readClipboard?.call();
    } catch (_) {}
    if (clip != null && clip.length > 20000) clip = '${clip.substring(0, 20000)}…';
    return {
      'pc': Platform.localHostname,
      'presse_papier': clip ?? '',
      'fichiers': [for (final f in shared) f.toJson()],
      'telecommande': command != null,
    };
  }

  Timer? _noticeTimer;
  final _pendingNames = <String>[];

  Future<void> _receive(HttpRequest req) async {
    final res = req.response;
    final raw = Uri.decodeComponent(req.headers.value('x-nom') ?? 'fichier');
    final declared = req.contentLength;
    if (declared > maxUpload) return await send(res, 413, 'text/plain', const []);
    final dir = await receiveDir();
    await dir.create(recursive: true);
    final file = await uniqueFile(dir, safeName(raw));
    final sink = file.openWrite();
    var n = 0;
    var tooBig = false;
    try {
      await for (final chunk in req) {
        n += chunk.length;
        if (n > maxUpload) {
          tooBig = true;
          break;
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (tooBig || n == 0) {
      try {
        await file.delete();
      } catch (_) {}
      return await send(res, tooBig ? 413 : 400, 'text/plain', const []);
    }
    final name = file.path.split(RegExp(r'[\\/]')).last;
    received.insert(0, ReceivedFile(file.path, name, n));
    if (received.length > 100) received.removeRange(100, received.length);
    notifyListeners();
    // Une seule notification pour une série de photos.
    _pendingNames.add(name);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      final k = _pendingNames.length;
      notify?.call(
        k == 1 ? '📱 Reçu du téléphone' : '📱 $k fichiers reçus du téléphone',
        k == 1
            ? '${_pendingNames.first} → Téléchargements › Depuis mon téléphone'
            : 'Dans Téléchargements › Depuis mon téléphone',
      );
      _pendingNames.clear();
    });
    return await sendJson(res, {'ok': true, 'nom': name});
  }

  Future<void> asset(HttpResponse res, String path) async {
    final bytes = await loadAsset?.call(path);
    if (bytes == null) return send(res, 404, 'text/plain', const []);
    return send(res, 200, _types[path.split('.').last] ?? 'application/octet-stream', bytes);
  }

  /// Le corps d'une requête en texte (null s'il dépasse [max]).
  static Future<String?> readText(HttpRequest req, int max) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
      if (b.length > max) return null;
    }
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  static Future<void> sendJson(HttpResponse res, Object body) =>
      send(res, 200, 'application/json', utf8.encode(jsonEncode(body)));

  static Future<void> send(HttpResponse res, int code, String type, List<int> body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.parse(type);
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }
}
