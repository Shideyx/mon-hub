import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';

import '../core/ar_server.dart';
import '../core/claude_bridge.dart';
import '../core/error_log.dart';
import '../core/hologram.dart';
import '../core/nav.dart';
import 'web_login.dart' show webLoginSupported;

/// Réalité augmentée : un hologramme 3D dans l'image de la caméra, qu'on
/// touche, attrape, tourne et agrandit avec les doigts. La page 3D
/// (`assets/ar/`) tourne dans le navigateur intégré, servie par [ArServer]
/// sur 127.0.0.1. Rien ne part sur internet : les images de la caméra
/// restent sur l'appareil.
class ArPage extends StatefulWidget {
  const ArPage({super.key, this.objet, this.mode, this.recipe});

  final String? objet;
  final String? mode;
  final Map<String, dynamic>? recipe;

  static bool get supported => webLoginSupported;

  static _ArPageState? _current;

  /// La page est-elle ouverte ?
  static bool get isOpen => _current?.mounted ?? false;

  /// Ouvre la page (ou change l'objet si elle est déjà ouverte).
  static Future<void> show({String? objet, String? mode, Map<String, dynamic>? recipe}) async {
    final open = _current;
    if (open != null && open.mounted) {
      await open.apply(objet: objet, mode: mode, recipe: recipe);
      return;
    }
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    unawaited(
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => ArPage(objet: objet, mode: mode, recipe: recipe),
        ),
      ),
    );
  }

  /// Le serveur local (un seul pour l'appli).
  static ArServer? _server;

  static Future<Directory> dataDir() async {
    final base = ClaudeBridge.folder ?? (await getApplicationSupportDirectory()).path;
    return Directory('$base${Platform.pathSeparator}realite-augmentee');
  }

  static Future<ArServer> server() async {
    final s = _server ??= ArServer(
      loadAsset: (p) async {
        try {
          final d = await rootBundle.load('assets/ar/$p');
          return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
        } catch (_) {
          return null;
        }
      },
      dataDir: await dataDir(),
    );
    await s.start();
    return s;
  }

  /// Où ranger les photos : Images › Mon Hub (Windows), sinon les documents.
  static Future<Directory> photoDir() async {
    final home = Platform.environment['USERPROFILE'];
    if (Platform.isWindows && home != null) return Directory('$home\\Pictures\\Mon Hub');
    return Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}Mon Hub');
  }

  @override
  State<ArPage> createState() => _ArPageState();
}

class _ArPageState extends State<ArPage> {
  InAppWebViewController? _c;
  Uri? _url;
  String? _error;
  bool _loaded = false;

  /// Ce que Clicky a demandé avant que la page ait fini de charger.
  ({String? objet, String? mode, Map<String, dynamic>? recipe})? _pending;

  @override
  void initState() {
    super.initState();
    ArPage._current = this;
    if (widget.recipe != null) _pending = (objet: null, mode: null, recipe: widget.recipe);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final s = await ArPage.server();
      final mode = Hologram.modes.contains(widget.mode) ? widget.mode : null;
      if (mounted) setState(() => _url = s.page(objet: widget.objet, mode: mode));
    } catch (e, st) {
      ErrorLog.record(e, st, where: 'réalité augmentée');
      if (mounted) setState(() => _error = 'La réalité augmentée n\'a pas pu démarrer.');
    }
  }

  @override
  void dispose() {
    if (ArPage._current == this) ArPage._current = null;
    _c = null;
    // La caméra s'éteint avec la page ; le serveur aussi.
    final s = ArPage._server;
    ArPage._server = null;
    unawaited(s?.stop());
    super.dispose();
  }

  Future<void> _js(String code) async {
    try {
      await _c?.evaluateJavascript(source: 'window.monHub && $code');
    } catch (_) {}
  }

  /// Change ce qui est affiché (appelé par Clicky).
  Future<void> apply({String? objet, String? mode, Map<String, dynamic>? recipe}) async {
    if (!_loaded) {
      _pending = (objet: objet ?? _pending?.objet, mode: mode ?? _pending?.mode, recipe: recipe ?? _pending?.recipe);
      return;
    }
    if (Hologram.modes.contains(mode)) await _js('window.monHub.setMode(${jsonEncode(mode)})');
    if (recipe != null) {
      await _js('window.monHub.setCustom(${jsonEncode(recipe)})');
    } else if (objet != null) {
      await _js('window.monHub.setObject(${jsonEncode(objet)})');
    }
  }

  Future<String> _savePhoto(String dataUrl) async {
    final i = dataUrl.indexOf('base64,');
    if (!dataUrl.startsWith('data:image/jpeg') || i < 0) return 'Photo illisible.';
    final bytes = base64Decode(dataUrl.substring(i + 7));
    final dir = await ArPage.photoDir();
    await dir.create(recursive: true);
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name =
        'hologramme-${t.year}-${two(t.month)}-${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.jpg';
    await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(bytes, flush: true);
    return Platform.isWindows ? 'Photo enregistrée dans Images › Mon Hub 📸' : 'Photo enregistrée 📸';
  }

  Future<Object?> _invent(String text) async {
    try {
      final r = await Hologram.invent(text);
      return r ?? {'erreur': 'Je n\'ai pas réussi à fabriquer « $text ». Essaie avec d\'autres mots.'};
    } catch (_) {
      return {'erreur': 'Pour inventer un objet, il faut le cerveau de Clicky (clé Gemini ou Claude) et internet.'};
    }
  }

  /// Le lien vers le téléphone : seulement depuis un ordinateur.
  bool get _canShare => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Pyramide sur le téléphone : la page est ouverte au même Wi-Fi derrière
  /// un lien secret, montré en QR code.
  Future<void> _share() async {
    final s = ArPage._server;
    if (s == null) return;
    Uri? link;
    try {
      link = await s.startShare();
    } catch (e, st) {
      ErrorLog.record(e, st, where: 'hologrammes sur le téléphone');
    }
    if (!mounted) return;
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Je ne trouve pas de Wi-Fi : le PC et le téléphone doivent être sur le même réseau.'),
        ),
      );
      return;
    }
    await _js('window.monHub.setLinked(true)');
    await _js("window.monHub.setMode('pyramide')");
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('L\'hologramme sur ton téléphone'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 220, child: CustomPaint(painter: QrPainter('$link'))),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '1. Scanne ce code avec l\'appareil photo de ton téléphone (même Wi-Fi que le PC).\n'
                  '2. Si Windows demande d\'autoriser Mon Hub sur le réseau, clique sur « Autoriser ».\n'
                  '3. Pose le téléphone à plat, la pyramide à l\'envers au centre, et éteins la lumière.\n'
                  '4. Devant la webcam du PC, glisse ton index pour faire tourner l\'hologramme, pince avec '
                  'tes deux mains pour l\'agrandir. Change d\'objet ici : le téléphone suit.\n'
                  '5. Pour que l\'écran du téléphone ne s\'éteigne pas : Réglages → Luminosité → Verrouillage auto → Jamais.',
                ),
                const SizedBox(height: 8),
                SelectableText('$link', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                const Text(
                  'Le lien est secret et ne montre que l\'hologramme (jamais la caméra). Il se coupe quand tu fermes '
                  'cette page.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('C\'est bon'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return Scaffold(
      backgroundColor: const Color(0xFF07060D),
      appBar: AppBar(
        title: const Text('Hologrammes'),
        backgroundColor: const Color(0xFF07060D),
        foregroundColor: Colors.white,
        actions: [
          if (_canShare)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _url == null ? null : _share,
                icon: const Icon(Icons.phone_iphone_rounded),
                label: const Text('Sur mon téléphone'),
              ),
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.white)),
            )
          : url == null
          ? const Center(child: CircularProgressIndicator())
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(url.toString())),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                isInspectable: kDebugMode,
                supportZoom: false,
                useShouldOverrideUrlLoading: true,
              ),
              onWebViewCreated: (c) {
                _c = c;
                c.addJavaScriptHandler(
                  handlerName: 'photo',
                  callback: (args) => args.isEmpty ? 'Photo vide.' : _savePhoto('${args.first}'),
                );
                c.addJavaScriptHandler(
                  handlerName: 'etat',
                  callback: (args) {
                    if (args.isNotEmpty) ArPage._server?.publish(args.first);
                    return null;
                  },
                );
                c.addJavaScriptHandler(
                  handlerName: 'invent',
                  callback: (args) => args.isEmpty ? null : _invent('${args.first}'),
                );
              },
              onLoadStop: (_, _) async {
                _loaded = true;
                final p = _pending;
                _pending = null;
                if (p != null) await apply(objet: p.objet, mode: p.mode, recipe: p.recipe);
              },
              // La caméra, seulement pour notre page locale.
              onPermissionRequest: (_, req) async {
                final ours = req.origin.host == '127.0.0.1';
                final camera = req.resources.where((r) => r == PermissionResourceType.CAMERA).toList();
                return PermissionResponse(
                  resources: ours ? camera : req.resources,
                  action: ours && camera.isNotEmpty ? PermissionResponseAction.GRANT : PermissionResponseAction.DENY,
                );
              },
              // Aucun lien ne quitte la page.
              shouldOverrideUrlLoading: (_, action) async {
                final u = action.request.url;
                return u != null && u.host == '127.0.0.1'
                    ? NavigationActionPolicy.ALLOW
                    : NavigationActionPolicy.CANCEL;
              },
            ),
    );
  }
}

/// Un QR code dessiné (paquet qr, sans Internet).
class QrPainter extends CustomPainter {
  QrPainter(this.data)
    : _image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (_image.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}
