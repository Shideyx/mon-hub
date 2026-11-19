import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Réalité augmentée : petit serveur **local** (127.0.0.1, port au hasard)
/// qui sert la page 3D (`assets/ar/`) au navigateur intégré. Il faut une
/// adresse « sûre » pour que le navigateur accepte d'ouvrir la caméra, et la
/// vision des mains a besoin de vrais fichiers (WebAssembly).
///
/// La vision des mains (MediaPipe de Google, ~ 17 Mo) n'est pas dans Mon Hub :
/// elle est téléchargée la première fois, depuis npm et Google, puis
/// **vérifiée par empreinte SHA-256** avant d'être utilisée (un fichier
/// modifié est refusé). Les images de la caméra restent sur l'appareil.
class ArServer {
  ArServer({required this.loadAsset, required this.dataDir});

  /// Lit un fichier de `assets/ar/` (ex. « vendor/three.min.js »).
  final Future<Uint8List?> Function(String path) loadAsset;

  /// Où ranger la vision des mains (`%APPDATA%\MonHub\realite-augmentee`).
  final Directory dataDir;

  HttpServer? _server;

  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  /// L'adresse de la page.
  Uri page({String? objet, String? mode}) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/', queryParameters: {'objet': ?objet, 'mode': ?mode});

  // ------------------------------------------------------------ MediaPipe
  static const mediapipeVersion = '1.2.3';
  static const packageUrl = 'https://registry.npmjs.org/@mediapipe/tasks-vision/-/tasks-vision-$mediapipeVersion.tgz';
  static const packageSha256 = '469602650dab70256df387983ea44e85fa66020335bae85a54fa8fda062ca0a0';
  static const packageSize = 8798983;
  static const modelUrl =
      'https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task';
  static const modelSha256 = 'fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1';
  static const modelSize = 7819105;

  /// Fichiers servis sous `/mp/` → leur place dans le paquet npm.
  static const packageFiles = {
    'vision_bundle.mjs': 'package/vision_bundle.mjs',
    'wasm/vision_wasm_internal.js': 'package/wasm/vision_wasm_internal.js',
    'wasm/vision_wasm_internal.wasm': 'package/wasm/vision_wasm_internal.wasm',
  };
  static const modelFile = 'hand_landmarker.task';
  static const _versionFile = 'version.txt';

  Directory get _mp => Directory('${dataDir.path}${Platform.pathSeparator}mp');
  File _mpFile(String rel) =>
      File('${_mp.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');

  int _received = 0;
  String? _error;

  /// La vraie raison du dernier échec (journal).
  String? detail;
  Future<void>? _preparing;

  /// La vision des mains est-elle déjà là ?
  Future<bool> handsReady() async {
    try {
      final v = _mpFile(_versionFile);
      if (!await v.exists() || (await v.readAsString()).trim() != mediapipeVersion) return false;
      for (final f in [...packageFiles.keys, modelFile]) {
        if (!await _mpFile(f).exists()) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, Object?>> status() async => {
    'ready': await handsReady(),
    'received': _received,
    'total': packageSize + modelSize,
    'error': _error,
  };

  /// Télécharge et vérifie la vision des mains (une seule fois).
  Future<void> prepare() => _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    if (await handsReady()) return;
    _error = null;
    _received = 0;
    try {
      final pkg = await download(packageUrl, packageSha256, (n) => _received += n);
      final model = await download(modelUrl, modelSha256, (n) => _received += n);
      final files = await _extractApart(pkg);
      for (final e in files.entries) {
        final f = _mpFile(e.key);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(e.value, flush: true);
      }
      await _mpFile(modelFile).writeAsBytes(model, flush: true);
      // En dernier : la vision des mains n'est « prête » que si tout est écrit.
      await _mpFile(_versionFile).writeAsString(mediapipeVersion, flush: true);
    } catch (e) {
      detail = '$e';
      _error = e is ArDownloadError ? e.message : 'Je n\'ai pas pu télécharger la vision des mains (vérifie internet).';
    }
  }

  /// Télécharge [url] et refuse le fichier si son empreinte n'est pas
  /// [sha256] (fichier abîmé ou modifié).
  static Future<Uint8List> download(String url, String sha256Hex, void Function(int) onBytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw ArDownloadError('Téléchargement refusé (${res.statusCode}).');
      final b = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        b.add(chunk);
        onBytes(chunk.length);
      }
      final bytes = b.takeBytes();
      if (sha256.convert(bytes).toString() != sha256Hex) {
        throw ArDownloadError('Le fichier téléchargé n\'est pas le bon (empreinte différente) : refusé par sécurité.');
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// Hors du fil de l'interface (et sans rien emporter de ce serveur).
  static Future<Map<String, Uint8List>> _extractApart(Uint8List tgz) => Isolate.run(() => extractPackage(tgz));

  /// Sort du paquet npm (.tgz) les fichiers utiles.
  static Map<String, Uint8List> extractPackage(Uint8List tgz) {
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(tgz));
    return {
      for (final e in packageFiles.entries)
        e.key: tar.findFile(e.value)?.content ?? (throw ArDownloadError('Paquet incomplet : ${e.value}')),
    };
  }

  // ------------------------------------------------------------ Le serveur
  Future<void> start() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((r) => unawaited(_handle(r)));
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  /// Chemins de la page acceptés : lettres, chiffres, -, _ et points (jamais
  /// « .. »), avec une extension connue.
  static bool safeAsset(String rel) =>
      !rel.contains('..') &&
      RegExp(r'^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*(/[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*)*$').hasMatch(rel) &&
      types.containsKey(rel.split('.').last);

  static const types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'wasm': 'application/wasm',
    'task': 'application/octet-stream',
  };

  static String typeOf(String rel) => types[rel.split('.').last] ?? 'application/octet-stream';

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      // Seulement ce PC, et seulement par 127.0.0.1 / localhost (une page
      // web qui se ferait passer pour « nous » par son nom est refusée).
      final host = req.headers.host ?? '';
      if (host != '127.0.0.1' && host != 'localhost') return await _send(res, 403, 'text/plain', utf8.encode('Refusé'));
      res.headers
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Cache-Control', 'no-store');
      final path = req.uri.path;
      if (path == '/mp/prepare' && req.method == 'POST') {
        unawaited(prepare());
        return await _sendJson(res, await status());
      }
      if (path == '/mp/status') return await _sendJson(res, await status());
      if (req.method != 'GET' && req.method != 'HEAD') return await _send(res, 405, 'text/plain', const []);
      if (path.startsWith('/mp/')) {
        final rel = path.substring(4);
        if (!packageFiles.containsKey(rel) && rel != modelFile) return await _send(res, 404, 'text/plain', const []);
        final f = _mpFile(rel);
        if (!await f.exists()) return await _send(res, 404, 'text/plain', const []);
        return await _send(res, 200, typeOf(rel), await f.readAsBytes());
      }
      final rel = path == '/' ? 'index.html' : path.substring(1);
      if (!safeAsset(rel)) return await _send(res, 404, 'text/plain', const []);
      final bytes = await loadAsset(rel);
      if (bytes == null) return await _send(res, 404, 'text/plain', const []);
      return await _send(res, 200, typeOf(rel), bytes);
    } catch (_) {
      try {
        await _send(res, 500, 'text/plain', const []);
      } catch (_) {}
    }
  }

  Future<void> _sendJson(HttpResponse res, Object body) =>
      _send(res, 200, 'application/json', utf8.encode(jsonEncode(body)));

  Future<void> _send(HttpResponse res, int code, String type, List<int> body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.parse(type);
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }
}

class ArDownloadError implements Exception {
  ArDownloadError(this.message);
  final String message;
  @override
  String toString() => message;
}
