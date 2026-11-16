import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:win32/win32.dart' show HWND;

import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/hub_module.dart';
import '../../core/module_store.dart';
import '../../core/nav.dart';
import '../../core/session.dart';
import '../theme.dart';
import 'clicky.dart';
import 'win.dart';

/// « Clicky partout » (Windows) : Clicky sort de la fenêtre de Mon Hub.
///
/// Mon Hub lance une seconde fois son propre programme avec `--clicky`.
/// Ce second programme n'affiche qu'une petite fenêtre transparente, toujours
/// au premier plan, qui suit la souris partout (toutes les applis, tous les
/// écrans). Il écoute Ctrl + Alt même quand Mon Hub est réduit, capture tous
/// les écrans pour l'IA, et passe par le pont local de Mon Hub pour lire
/// l'agenda, les notes, les messages…
class ClickyDesktop {
  ClickyDesktop._();

  /// Port local qui sert de verrou (un seul Clicky) et de télécommande.
  static const port = 47613;

  static bool get supported => !kIsWeb && Platform.isWindows;

  static Future<bool> running() async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 400),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Démarre Clicky partout (s'il n'est pas déjà lancé).
  static Future<void> launch() async {
    final c = ClickyController.instance;
    // Pas de cerveau configuré : on ne lance rien du tout.
    if (!supported || !c.everywhere || !await c.refreshReady() || !c.enabled) return;
    if (await running()) return;
    try {
      await Process.start(Platform.resolvedExecutable, [
        '--clicky',
      ], mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('Clicky partout : $e');
    }
  }

  /// Envoie un ordre à Clicky partout ('open', 'quit').
  static Future<bool> send(String command) async {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 400),
      );
      s.write('$command\n');
      await s.flush();
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stop() => send('quit');

  /// Relance Clicky partout (compte changé, cerveau ou modèle modifié…).
  static Future<void> restart() async {
    if (!supported) return;
    if (await send('quit')) {
      // Attend que l'ancien Clicky soit bien parti (3 s au plus).
      for (var i = 0; i < 15 && await running(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    await launch();
  }
}

/// Point d'entrée de `hub.exe --clicky`.
Future<void> runClickyDesktop() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ServerSocket lock;
  try {
    lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, ClickyDesktop.port);
  } catch (_) {
    exit(0); // déjà lancé
  }
  await ModuleStore.init();
  AppSession.instance.restore();
  // Avant tout : ce programme ne doit jamais écrire dans les préférences.
  ClickyController.instance.desktopMode = true;
  await ClickyController.instance.followSharedOptions();
  if (!await ClickyController.instance.refreshReady()) exit(0);

  final c = ClickyController.instance
    ..desktopMode = true
    ..captureOverride = _captureScreens
    ..toolsOverride = _BridgeTools.list;

  lock.listen((sock) {
    utf8.decoder.bind(sock).listen((data) {
      if (data.contains('quit')) exit(0);
      if (data.contains('open')) c.openPanel();
    }, onError: (_) {});
  });

  runApp(const _ClickyDesktopApp());
}

/// Captures de chaque écran (Clicky est caché pendant la photo).
Future<List<ClickyShot>> _captureScreens() async {
  final hwnd = _DesktopState.hwnd;
  if (hwnd != null) Win.hide(hwnd);
  await Future<void>.delayed(const Duration(milliseconds: 80));
  final shots = <ClickyShot>[];
  try {
    final mons = Win.monitors();
    for (var i = 0; i < mons.length; i++) {
      final (x, y, w, h) = mons[i];
      final bytes = Win.capture(x, y, w, h);
      // Taille conseillée pour l'IA : 1568 px sur le grand côté au maximum.
      final s = math.min(1.0, 1568 / math.max(w, h));
      final tw = math.max(1, (w * s).round()), th = math.max(1, (h * s).round());
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        w,
        h,
        ui.PixelFormat.bgra8888,
        c.complete,
        targetWidth: tw,
        targetHeight: th,
      );
      final img = await c.future;
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) continue;
      shots.add(
        ClickyShot(
          png64: base64Encode(png.buffer.asUint8List()),
          label: i == 0 ? 'écran principal' : 'écran ${i + 1}',
          width: tw,
          height: th,
          // Les coordonnées de la couche sont les pixels physiques.
          origin: Offset(x.toDouble(), y.toDouble()),
          logicalPerPx: w / tw,
        ),
      );
    }
  } finally {
    _DesktopState.instance?._show();
  }
  return shots;
}

/// Actions de Mon Hub, via le pont local (Mon Hub doit être ouvert).
class _BridgeTools {
  static List<HubTool> _cache = const [];
  static DateTime? _at;

  static Map<String, dynamic>? _info() {
    final dir = ClaudeBridge.folder;
    if (dir == null) return null;
    try {
      return jsonDecode(File('$dir${Platform.pathSeparator}bridge.json').readAsStringSync())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<Object?> _request(String method, String path, [Object? body]) async {
    final info = _info();
    if (info == null) throw 'Mon Hub n\'est pas ouvert';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${info['port']}$path'));
      req.headers.set('authorization', 'Bearer ${info['key']}');
      req.headers.contentType = ContentType.json;
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(minutes: 2));
      return jsonDecode(await utf8.decodeStream(res));
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> alive() async {
    try {
      await _request('GET', '/tools');
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<HubTool> list() {
    final at = _at;
    if (at == null || DateTime.now().difference(at).inSeconds > 30) {
      _at = DateTime.now();
      final info = _info();
      final tools = (info?['tools'] as List?) ?? const [];
      _cache = [
        for (final t in tools)
          () {
            final m = t as Map;
            final schema = (m['inputSchema'] as Map?) ?? const {};
            final props = (schema['properties'] as Map?) ?? const {};
            return HubTool(
              name: '${m['name']}',
              description: '${m['description'] ?? ''}',
              params: {
                for (final e in props.entries)
                  '${e.key}': (
                    '${(e.value as Map)['type'] ?? 'string'}',
                    '${e.value['description'] ?? ''}',
                  ),
              },
              required: [for (final r in (schema['required'] as List?) ?? const []) '$r'],
              run: (args) async {
                final r = await _request('POST', '/call', {'name': m['name'], 'arguments': args});
                if (r is Map && r['error'] != null) throw '${r['error']}';
                return r is Map ? r['result'] : r;
              },
            );
          }(),
      ];
    }
    return _cache;
  }
}

class _ClickyDesktopApp extends StatelessWidget {
  const _ClickyDesktopApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Clicky',
    debugShowCheckedModeBanner: false,
    navigatorKey: hubNavigatorKey,
    themeMode: AppSession.instance.themeMode,
    locale: const Locale('fr', 'FR'),
    supportedLocales: const [Locale('fr', 'FR'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: buildTheme(Brightness.light).copyWith(scaffoldBackgroundColor: Colors.transparent),
    darkTheme: buildTheme(Brightness.dark).copyWith(scaffoldBackgroundColor: Colors.transparent),
    color: Colors.transparent,
    home: const _Desktop(),
  );
}

class _Desktop extends StatefulWidget {
  const _Desktop();

  @override
  State<_Desktop> createState() => _DesktopState();
}

/// Taille de la fenêtre (en points) : compacte, ou avec le panneau ouvert.
const _cursorOnly = Size(110, 50);
const _pointing = Size(300, 60);
const _compact = Size(390, 330);
const _withPanel = Size(420, 400);

class _DesktopState extends State<_Desktop> {
  static _DesktopState? instance;
  static HWND? hwnd;

  final c = ClickyController.instance;
  Timer? _tick, _slow;
  bool _wasBoth = false;
  bool _interactive = false;
  bool _hidden = true;
  int _deadChecks = 0;

  // Position actuelle de la fenêtre et vol vers une cible (pixels physiques).
  Offset? _pos;
  Offset? _flightFrom;
  Offset? _flightTo;
  DateTime? _flightStart;

  double get _dpr => View.of(context).devicePixelRatio;

  @override
  void initState() {
    super.initState();
    instance = this;
    c.onInteractive = (v) {
      _interactive = v;
      final h = hwnd;
      if (h != null) Win.setInteractive(h, v);
      _place(force: true);
      if (mounted) setState(() {});
    };
    c.addListener(_onChange);
    _tick = Timer.periodic(const Duration(milliseconds: 16), (_) => _loop());
    _slow = Timer.periodic(const Duration(seconds: 3), (_) => _housekeeping());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _slow?.cancel();
    c.removeListener(_onChange);
    super.dispose();
  }

  Offset? _lastTarget;

  void _onChange() {
    if (c.target != _lastTarget) {
      // Départ (ou retour) en vol, en arc.
      _flightFrom = _pos;
      _flightTo = c.target;
      _flightStart = DateTime.now();
      _lastTarget = c.target;
    }
    if (mounted) setState(() {});
  }

  /// Réglages changés dans Mon Hub, Mon Hub fermé…
  Future<void> _housekeeping() async {
    ClaudeApi.forget(); // clé ajoutée / retirée dans Mon Hub
    await c.refreshReady();
    if (!c.active || !c.everywhere) exit(0);
    // Mon Hub fermé depuis un moment : Clicky s'en va aussi.
    if (await _BridgeTools.alive()) {
      _deadChecks = 0;
    } else if (++_deadChecks >= 5) {
      exit(0);
    }
  }

  void _show() {
    _hidden = true; // force un nouveau placement visible
    _place(force: true);
  }

  void _loop() {
    hwnd ??= Win.findClicky(pid);
    // Ctrl + Alt n'importe où (mais pas AltGr, qui sert à taper @, €, #).
    final both = Win.down(0x11) && Win.down(0x12) && !Win.down(0xA5);
    if (both && Win.otherKeyDown()) {
      c.hotkey(down: true, other: true);
    } else if (both && !_wasBoth) {
      c.hotkey(down: true);
    } else if (!both && _wasBoth) {
      c.hotkey(down: false);
    }
    _wasBoth = both;
    if (c.boxOpen && Win.down(0x1B)) c.closeBox(); // Échap

    final p = Win.cursor();
    if (p != null) c.moveCursor(Offset(p.$1.toDouble(), p.$2.toDouble()));
    _place();
  }

  void _place({bool force = false}) {
    final h = hwnd;
    if (h == null || !mounted) return;
    final visible = c.active && (c.buddyVisible || c.boxOpen);
    if (!visible) {
      if (!_hidden) {
        Win.hide(h);
        _hidden = true;
      }
      return;
    }
    final dpr = _dpr;
    final cur = c.cursor;
    if (cur == null) return;
    // Le bout du curseur bleu est en haut à gauche de la fenêtre.
    Offset want;
    final to = _flightTo;
    if (to != null) {
      want = to + const Offset(1, 1);
    } else if (_interactive) {
      want = _pos ?? cur + const Offset(16, 14);
    } else {
      want = cur + const Offset(16, 14);
    }
    // Vol en arc vers la cible (ou retour vers la souris).
    final start = _flightStart;
    if (start != null && _flightFrom != null) {
      final t = (DateTime.now().difference(start).inMilliseconds / 650).clamp(0.0, 1.0);
      if (t < 1) {
        final e = Curves.easeInOutCubic.transform(t);
        final a = _flightFrom!, b = want;
        final mid = Offset(
          (a.dx + b.dx) / 2,
          math.min(a.dy, b.dy) - (b - a).distance * 0.3 - 30 * dpr,
        );
        final u = 1 - e;
        want = a * (u * u) + mid * (2 * u * e) + b * (e * e);
      } else {
        _flightStart = null;
      }
    }
    // Fenêtre juste assez grande : minuscule autour du curseur, plus grande
    // quand la boîte de texte est ouverte (elle ne bloque ainsi aucun clic).
    final size = _interactive
        ? _withPanel
        : c.state == ClickyState.pointing
        ? _pointing
        : c.boxOpen
        ? _compact
        : _cursorOnly;
    final w = (size.width * dpr).round(), hh = (size.height * dpr).round();
    // On reste dans les écrans.
    final (vx, vy, vw, vh) = Win.virtualScreen();
    final x = want.dx.round().clamp(vx, math.max(vx, vx + vw - w)).toInt();
    final y = want.dy.round().clamp(vy, math.max(vy, vy + vh - hh)).toInt();
    final moved = _pos == null || (_pos!.dx - x).abs() >= 1 || (_pos!.dy - y).abs() >= 1;
    if (force || moved || _hidden) {
      Win.place(h, x, y, w, hh);
      _pos = Offset(x.toDouble(), y.toDouble());
      _hidden = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ClickyFollower(c: c, interactive: _interactive),
      ),
    );
  }
}
