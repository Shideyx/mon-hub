import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';
import 'package:win32/win32.dart' show HWND;

import '../../core/certificates.dart';
import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/error_log.dart';
import '../../core/hub_module.dart';
import '../../core/module_store.dart';
import '../../core/perf.dart';
import '../../core/nav.dart';
import '../../core/session.dart';
import '../theme.dart';
import 'autonomy.dart';
import 'clicky.dart';
import 'flight.dart';
import 'shot_encode.dart';
import 'win.dart';

/// « Nexo partout » (Windows) : Nexo sort de la fenêtre de Mon Hub.
///
/// Mon Hub lance une seconde fois son propre programme avec `--clicky`.
/// Ce second programme n'affiche qu'une petite fenêtre transparente, toujours
/// au premier plan, qui suit la souris partout (toutes les applis, tous les
/// écrans). Il écoute Ctrl + Alt même quand Mon Hub est réduit, capture tous
/// les écrans pour l'IA, et passe par le pont local de Mon Hub pour lire
/// l'agenda, les notes, les messages…
class ClickyDesktop {
  ClickyDesktop._();

  /// Port local qui sert de verrou (un seul Nexo) et de télécommande.
  static const port = 47613;

  static bool get supported => !kIsWeb && Platform.isWindows;

  static Future<bool> running() async {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 400));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Démarre Nexo partout (s'il n'est pas déjà lancé).
  static Future<void> launch() async {
    _paused = false;
    final c = ClickyController.instance;
    // Mode léger (PC modeste) : Nexo reste dans la fenêtre de Mon Hub.
    // Ce second programme est ce qui ralentissait le plus les petits PC.
    if (!Perf.everywhere) return;
    // Pas de cerveau configuré : on ne lance rien du tout.
    if (!supported || !c.everywhere || !await c.refreshReady() || !c.enabled) return;
    if (await running()) return;
    try {
      await Process.start(Platform.resolvedExecutable, ['--clicky'], mode: ProcessStartMode.detached);
    } catch (e) {
      debugPrint('Nexo partout : $e');
    }
  }

  /// Pose une question à Nexo partout (il s'ouvre et répond).
  static Future<bool> ask(String question) => send('ask ${question.replaceAll(RegExp(r'[\r\n]+'), ' ')}');

  /// Envoie un ordre à Nexo partout ('open', 'quit', 'ask …').
  static Future<bool> send(String command) async {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 400));
      s.write('$command\n');
      await s.flush();
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Arrêt voulu (mise à jour…) : la surveillance ne le relance pas.
  static Future<void> stop() {
    _paused = true;
    return send('quit');
  }

  static Timer? _watch;
  static bool _paused = false;
  static final _restarts = <DateTime>[];

  /// Surveille Nexo partout : s'il a planté, il est relancé (au plus 5
  /// fois en 10 minutes, pour ne pas tourner en boucle).
  static void watch() {
    if (!supported) return;
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(seconds: 15), (_) async {
      final c = ClickyController.instance;
      if (_paused || !c.everywhere || !c.enabled || !Perf.everywhere) return;
      if (await running()) return;
      final now = DateTime.now();
      _restarts.removeWhere((t) => now.difference(t) > const Duration(minutes: 10));
      if (_restarts.length >= 5) return;
      _restarts.add(now);
      ErrorLog.record('Nexo partout s\'est fermé : relancé', null, where: 'surveillance');
      await launch();
    });
  }

  /// Relance Nexo partout (compte changé, cerveau ou modèle modifié…).
  static Future<void> restart() async {
    if (!supported) return;
    if (await send('quit')) {
      // Attend que l'ancien Nexo soit bien parti (3 s au plus).
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
  ErrorLog.install('Nexo partout');
  await TrustedCertificates.install();
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
    ..toolsOverride = _BridgeTools.list
    // Sa présence : là où il peut aller regarder, et plein écran = discret.
    ..lookSpots = _lookSpots
    ..fullscreenNow = Win.foregroundFullscreen;

  unawaited(c.loadMemory());
  lock.listen((sock) {
    utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) {
      final cmd = line.trim();
      if (cmd == 'quit') exit(0);
      if (cmd == 'open') c.openPanel();
      // Topo du matin / du soir préparé par Mon Hub.
      if (cmd.startsWith('show64 ')) {
        try {
          final j = jsonDecode(utf8.decode(base64Decode(cmd.substring(7)))) as Map;
          unawaited(c.presentTopo('${j['t']}', '${j['x']}', speakIt: j['v'] != false));
        } catch (_) {}
      }
      // « Nexo agit » demandé depuis Mon Hub : c'est Nexo partout (au-
      // dessus de tout l'écran) qui prend la souris.
      if (cmd.startsWith('act64 ')) {
        try {
          unawaited(c.act(utf8.decode(base64Decode(cmd.substring(6)))));
        } catch (_) {}
      }
      // Une idée décidée par Mon Hub : c'est Nexo partout qui la propose.
      if (cmd.startsWith('idea64 ')) {
        try {
          final i = ClickyIdea.fromJson(jsonDecode(utf8.decode(base64Decode(cmd.substring(7)))));
          if (i != null) unawaited(c.proposeIdea(i));
        } catch (_) {}
      }
      // « Regarde mon écran maintenant » (réglages de Mon Hub).
      if (cmd == 'notice') unawaited(c.noticeSomething(force: true));
      // Ce qu'il ressent (une note, un cours annulé…), envoyé par Mon Hub.
      if (cmd.startsWith('feel64 ')) {
        try {
          final j = jsonDecode(utf8.decode(base64Decode(cmd.substring(7)))) as Map;
          final t = j['t'];
          unawaited(c.feel('${j['e']}', text: t is String ? t : null));
        } catch (_) {}
      }
      // Une pensée de Nexo (rappel de l'assistant…) envoyée par Mon Hub.
      if (cmd.startsWith('think64 ')) {
        try {
          unawaited(c.think(utf8.decode(base64Decode(cmd.substring(8)))));
        } catch (_) {}
      }
      // Question envoyée par Mon Hub (révisions du journal…).
      if (cmd.startsWith('ask ')) {
        c.openPanel();
        unawaited(c.ask(cmd.substring(4)));
      }
    }, onError: (_) {});
  });

  runApp(const _ClickyDesktopApp());
}

/// Là où Nexo peut aller regarder tout seul (pixels de l'écran) : la barre
/// de titre et le milieu de ta fenêtre, l'horloge, l'autre écran.
List<Offset> _lookSpots() {
  final out = <Offset>[];
  final f = Win.foregroundRect();
  if (f != null && f.$3 > 200 && f.$4 > 150) {
    final (x, y, w, h) = f;
    out.addAll([
      Offset(x + w * 0.5, y + 16.0),
      Offset(x + w * 0.5, y + h * 0.45),
      Offset(x + w * 0.25, y + h * 0.3),
      Offset(x + w * 0.75, y + h * 0.6),
    ]);
  }
  final mons = Win.monitors();
  if (mons.isNotEmpty) {
    final (mx, my, mw, mh) = mons.first;
    out.add(Offset(mx + mw - 70.0, my + mh - 24.0)); // l'horloge
  }
  for (final (mx, my, mw, mh) in mons.skip(1)) {
    out.add(Offset(mx + mw / 2, my + mh / 2));
  }
  return out;
}

/// Captures de chaque écran, **rapides** :
/// - Nexo reste à l'écran : Windows le retire seulement de la photo (avant,
///   il disparaissait 80 ms à chaque capture) ;
/// - Windows réduit l'image pendant la copie (1280 px au plus) ;
/// - l'image devient un JPEG à côté (Isolate), bien plus léger qu'un PNG à
///   envoyer à l'IA, pendant que Nexo continue de bouger.
Future<List<ClickyShot>> _captureScreens() async {
  final hwnd = _DesktopState.hwnd;
  final excluded = hwnd != null && Win.excludeFromCapture(hwnd, true);
  if (excluded) {
    // Le temps que Windows recompose l'écran sans lui (une ou deux images).
    Win.waitComposition();
    Win.waitComposition();
  } else if (hwnd != null) {
    // Ancien Windows : on le cache le temps de la photo.
    Win.hide(hwnd);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  final raw = <(int, Uint8List, int, int, int, int, int)>[];
  try {
    final mons = Win.monitors();
    for (var i = 0; i < mons.length; i++) {
      final (x, y, w, h) = mons[i];
      // 1280 px sur le grand côté au maximum : assez net pour lire l'écran,
      // et plus léger à envoyer (réponse plus rapide).
      final s = math.min(1.0, 1280 / math.max(w, h));
      final tw = math.max(1, (w * s).round()), th = math.max(1, (h * s).round());
      raw.add((i, Win.captureScaled(x, y, w, h, tw, th), x, y, w, tw, th));
    }
  } finally {
    if (excluded) {
      Win.excludeFromCapture(hwnd, false);
    } else {
      _DesktopState.instance?._show();
    }
  }
  final jpegs = await Future.wait([
    for (final r in raw) Isolate.run(() => encodeShot(r.$2, r.$6, r.$7)).catchError((Object _) => Uint8List(0)),
  ]);
  return [
    for (var k = 0; k < raw.length; k++)
      if (jpegs[k].isNotEmpty)
        ClickyShot(
          png64: base64Encode(jpegs[k]),
          label: raw[k].$1 == 0 ? 'écran principal' : 'écran ${raw[k].$1 + 1}',
          width: raw[k].$6,
          height: raw[k].$7,
          // Les coordonnées de la couche sont les pixels physiques.
          origin: Offset(raw[k].$3.toDouble(), raw[k].$4.toDouble()),
          logicalPerPx: raw[k].$5 / raw[k].$6,
        ),
  ];
}

/// Actions de Mon Hub, via le pont local (Mon Hub doit être ouvert).
class _BridgeTools {
  static List<HubTool> _cache = const [];
  static DateTime? _at;

  static Map<String, dynamic>? _info() {
    final dir = ClaudeBridge.folder;
    if (dir == null) return null;
    try {
      return jsonDecode(File('$dir${Platform.pathSeparator}bridge.json').readAsStringSync()) as Map<String, dynamic>;
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
      // Nexo partout a déjà demandé ton accord dans sa propre bulle : Mon
      // Hub ne redemande pas une deuxième fois.
      req.headers.set('x-monhub-client', 'clicky');
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
                  '${e.key}': ('${(e.value as Map)['type'] ?? 'string'}', '${e.value['description'] ?? ''}'),
              },
              required: [for (final r in (schema['required'] as List?) ?? const []) '$r'],
              run: (args) async {
                final r = await _request('POST', '/call', {'name': m['name'], 'arguments': args, 'confirme': true});
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
    title: 'Nexo',
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
const _cursorOnly = Size(170, 80);
const _pointing = Size(330, 96);
const _compact = Size(390, 330);
const _withPanel = Size(420, 400);
const _withBoard = Size(560, 760);

class _DesktopState extends State<_Desktop> with SingleTickerProviderStateMixin {
  static _DesktopState? instance;
  static HWND? hwnd;

  final c = ClickyController.instance;
  Timer? _tick, _slow;
  bool _wasBoth = false;
  bool _wasEsc = false;
  bool _wasFix = false, _wasFind = false, _wasClick = false;
  bool _fullscreen = false;
  int _n = 0;
  bool _interactive = false;
  bool _hidden = true;
  int _deadChecks = 0;

  // Position actuelle de la fenêtre et vol vers une cible (pixels physiques).
  Offset? _pos;

  /// Posée par toi (glisser la barre du haut) : ne suit plus la souris.
  bool _pinned = false;
  Offset? _dragFrom;
  Offset? _dragPos;

  /// Le vol en cours (vers une cible, un regard, ou retour à la souris).
  ClickyFlight? _flight;
  Offset? _flightTo;

  /// Pendant qu'il réfléchit après une capture : il parcourt l'écran.
  Offset? _scan;
  DateTime _nextScan = DateTime.now();

  /// Position qui suit la souris (avec un petit ressort).
  Offset? _follow;

  /// Windows fait suivre la souris à la fenêtre (voir `Win.follow`) : c'est
  /// le mode normal, le plus fluide. Dart ne reprend la main que pour les
  /// vols (vers une cible, un regard…), la boîte ouverte et les dessins.
  bool _native = false;

  /// Les vols sont calculés à chaque image de l'écran (et pas avec un
  /// minuteur qui tombe entre deux images) : arcs bien lisses.
  late final Ticker _frames = createTicker((_) => _place());

  void _setNative(HWND h, bool on) {
    if (on == _native) return;
    _native = on;
    Win.follow(h, on: on);
    if (!on) {
      // Dart reprend la main là où Windows a laissé la fenêtre.
      final r = Win.windowRect(h);
      if (r != null) _pos = Offset(r.$1.toDouble(), r.$2.toDouble());
      _follow = null;
    }
  }

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
    // Sa vie à lui : son coin pour dormir (en bas à droite de l'écran où est
    // la souris, au-dessus de la barre des tâches) et le haut de ta fenêtre,
    // où il vient s'asseoir.
    c
      ..restSpot = _restSpot
      ..perchSpot = _perchSpot;
    // La boîte s'attrape par sa barre du haut : la fenêtre suit la souris
    // (en pixels de l'écran) et reste où on la pose.
    c.onDragBox = (d, start) {
      final cur = Win.cursor();
      if (cur == null) return;
      final p = Offset(cur.$1.toDouble(), cur.$2.toDouble());
      if (start || _dragFrom == null) {
        _dragFrom = p;
        _dragPos = _pos;
        return;
      }
      final from = _dragPos;
      if (from == null) return;
      _pos = from + (p - _dragFrom!);
      _pinned = true;
      _place(force: true);
    };
    _tick = Timer.periodic(Perf.slow(const Duration(milliseconds: 16), factor: 2), (_) => _loop());
    _slow = Timer.periodic(const Duration(seconds: 3), (_) => _housekeeping());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _slow?.cancel();
    _frames.dispose();
    c.removeListener(_onChange);
    super.dispose();
  }

  Offset? _lastGoal;

  /// Là où il doit être : la cible montrée, un regard, un coin de l'écran
  /// qu'il parcourt en réfléchissant (sinon : à côté de la souris).
  Offset? get _goal => c.target ?? c.gaze ?? _scan;

  void _fly(Offset? to) {
    // La fenêtre était menée par Windows : on part de là où elle est vraiment.
    final h = hwnd;
    if (h != null && _native) _setNative(h, false);
    final from = _pos;
    _flightTo = to;
    final dest = to ?? (c.cursor ?? from);
    if (from == null || dest == null) {
      _flight = null;
      return;
    }
    _flight = ClickyFlight(
      from,
      to == null ? dest + const Offset(16, 14) : dest + const Offset(1, 1),
      DateTime.now(),
      dpr: _dpr,
    );
    if (!_frames.isActive) unawaited(_frames.start());
  }

  void _onChange() {
    if (c.marks.isEmpty) _frame = Offset.zero;
    final goal = _goal;
    if (goal != _lastGoal) {
      // Départ (ou retour) en vol, en arc.
      _fly(goal);
      _lastGoal = goal;
    }
    if (mounted) setState(() {});
  }

  /// En réfléchissant après une capture, il « lit » ta fenêtre : petits
  /// sauts rapides d'un endroit à l'autre.
  void _scanStep() {
    final thinking = c.state == ClickyState.thinking && c.target == null && c.gaze == null && !_interactive;
    if (!thinking) {
      if (_scan != null) {
        _scan = null;
        _onChange();
      }
      return;
    }
    final now = DateTime.now();
    if (now.isBefore(_nextScan)) return;
    _nextScan = now.add(Duration(milliseconds: 520 + math.Random().nextInt(420)));
    final f = Win.foregroundRect();
    final cur = c.cursor;
    final r = math.Random();
    if (f != null && f.$3 > 200 && f.$4 > 150) {
      final (x, y, w, h) = f;
      _scan = Offset(x + w * (0.15 + r.nextDouble() * 0.7), y + h * (0.12 + r.nextDouble() * 0.7));
    } else if (cur != null) {
      _scan = cur + Offset(r.nextDouble() * 300 - 150, r.nextDouble() * 200 - 100);
    }
    _onChange();
  }

  /// Réglages changés dans Mon Hub, Mon Hub fermé…
  Future<void> _housekeeping() async {
    // Toujours au-dessus des autres fenêtres (sans le déplacer : c'est
    // Windows qui le fait suivre la souris).
    final h = hwnd, sz = _size;
    if (h != null && _native && !_hidden && sz != null) Win.resize(h, sz.width.round(), sz.height.round());
    ClaudeApi.forget(); // clé ajoutée / retirée dans Mon Hub
    await c.refreshReady();
    if (!c.active || !c.everywhere) exit(0);
    // Mon Hub fermé depuis un moment : Nexo s'en va aussi.
    if (await _BridgeTools.alive()) {
      _deadChecks = 0;
    } else if (++_deadChecks >= 5) {
      exit(0);
    }
  }

  Offset? _restSpot() {
    final cur = Win.cursor();
    final mons = Win.monitors();
    if (mons.isEmpty) return null;
    final d = _dpr;
    final m = mons.firstWhere(
      (m) => cur != null && cur.$1 >= m.$1 && cur.$1 < m.$1 + m.$3 && cur.$2 >= m.$2 && cur.$2 < m.$2 + m.$4,
      orElse: () => mons.first,
    );
    return Offset(m.$1 + m.$3 - 190 * d, m.$2 + m.$4 - 140 * d);
  }

  (Offset, Rect)? _perchSpot() {
    final t = Win.foregroundTitle();
    if (t.trim().isEmpty || t == 'Nexo' || t == 'Program Manager' || _fullscreen) return null;
    final f = Win.foregroundRect();
    if (f == null) return null;
    final (x, y, w, h) = f;
    final d = _dpr;
    if (w < 360 * d || h < 240 * d) return null;
    return (Offset(x + w * 0.62, y - 6 * d), Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()));
  }

  void _show() {
    _hidden = true; // force un nouveau placement visible
    _place(force: true);
  }

  void _loop() {
    hwnd ??= Win.findClicky(pid);
    // Ctrl + Alt n'importe où (mais pas AltGr, qui sert à taper @, €, #).
    final both = Win.down(0x11) && Win.down(0x12) && !Win.down(0xA5);
    // Ctrl + Alt + Maj : dictée (le texte est tapé dans l'appli ouverte).
    final shift = Win.down(0x10);
    // Ctrl + Alt + C : corrige le texte surligné dans l'appli ouverte.
    final fix = both && Win.down(0x43);
    if (fix && !_wasFix) unawaited(c.fixSelection());
    _wasFix = fix;
    // Ctrl + Alt + Espace : la recherche partout (dans Mon Hub).
    final find = both && Win.down(0x20);
    if (find && !_wasFind) unawaited(c.openSearch());
    _wasFind = find;
    if (both && Win.otherKeyDown()) {
      c.hotkey(down: true, other: true);
    } else if (both && !_wasBoth) {
      c.hotkey(down: true, dictate: shift);
    } else if (both && shift) {
      c.hotkey(down: true, dictate: true);
    } else if (!both && _wasBoth) {
      c.hotkey(down: false);
    }
    _wasBoth = both;
    // Échap : arrête la réponse, puis ferme la boîte, puis le tableau.
    final esc = Win.down(0x1B);
    if (esc && !_wasEsc) c.escape();
    _wasEsc = esc;
    // Les clics (il se réveille, ou s'inquiète des clics énervés).
    final click = Win.down(0x01);
    if (click && !_wasClick) c.userClicked();
    _wasClick = click;

    final p = Win.cursor();
    if (p != null) c.moveCursor(Offset(p.$1.toDouble(), p.$2.toDouble()));
    _scanStep();
    // Plein écran ? (vérifié deux fois par seconde, pas à chaque image)
    if (++_n % 30 == 0) _fullscreen = Win.foregroundFullscreen();
    // Pendant un vol, c'est l'horloge des images qui place la fenêtre.
    if (!_frames.isActive) _place();
  }

  void _place({bool force = false}) {
    final h = hwnd;
    if (h == null || !mounted) return;
    // Un jeu ou une vidéo en plein écran : Nexo disparaît tant qu'on ne
    // l'appelle pas (rien par-dessus le jeu, aucun ralentissement).
    final quiet =
        _fullscreen &&
        c.state == ClickyState.idle &&
        !c.boxOpen &&
        c.board == null &&
        c.holo == null &&
        c.target == null;
    final visible = c.active && !quiet && (c.buddyVisible || c.boxOpen || c.board != null);
    if (_pinned && !c.boxOpen && c.board == null && c.holo == null) {
      _pinned = false;
      _dragFrom = null;
    }
    if (!visible) {
      if (!_hidden) {
        Win.hide(h);
        _hidden = true;
      }
      if (_frames.isActive) _frames.stop();
      return;
    }
    final dpr = _dpr;
    final cur = c.cursor;
    if (cur == null) return;
    // Il suit simplement la souris : c'est Windows qui déplace la fenêtre,
    // à chaque mouvement (fluide, même quand Nexo réfléchit ou capture).
    final follow = _flightTo == null && _flight == null && !_interactive && !_pinned && c.marks.isEmpty;
    if (follow) {
      if (_frames.isActive) _frames.stop();
      final size = c.board != null || c.holo != null
          ? _withBoard
          : c.lifeNote.length > 60 && c.state == ClickyState.idle
          ? _compact
          : c.state == ClickyState.pointing || c.gazeNote.isNotEmpty || c.lifeNote.isNotEmpty
          ? _pointing
          : c.boxOpen
          ? _compact
          : _cursorOnly;
      final w = (size.width * dpr).round(), hh = (size.height * dpr).round();
      final sz = Size(w.toDouble(), hh.toDouble());
      if (_inside != Offset.zero) {
        _inside = Offset.zero;
        if (mounted) setState(() {});
      }
      if (!_native || _hidden || force) {
        // Premier placement (ou réapparition) : juste à côté du curseur,
        // puis Windows prend le relais.
        final (vx, vy, vw, vh) = Win.virtualScreen();
        final x = (cur.dx + 16).round().clamp(vx, math.max(vx, vx + vw - w)).toInt();
        final y = (cur.dy + 14).round().clamp(vy, math.max(vy, vy + vh - hh)).toInt();
        Win.place(h, x, y, w, hh);
        _hidden = false;
        _size = sz;
        _native = false;
        _setNative(h, true);
      } else if (_size != sz) {
        Win.resize(h, w, hh);
        _size = sz;
      }
      _pos = null;
      _follow = null;
      return;
    }
    if (_native) _setNative(h, false);
    // Le bout du curseur bleu est en haut à gauche de la fenêtre.
    Offset want;
    final to = _flightTo;
    if (to != null) {
      want = to + const Offset(1, 1);
    } else if (_interactive || _pinned) {
      want = _pos ?? cur + const Offset(16, 14);
    } else {
      // Il suit la souris avec un petit ressort (vif, mais vivant).
      final home = cur + const Offset(16, 14);
      want = _follow = springTowards(_follow ?? home, home);
    }
    // Vol en arc (vers la cible, un regard, ou retour vers la souris) :
    // il s'oriente dans le sens du vol et grossit un peu au milieu.
    final fl = _flight;
    if (fl != null) {
      final now = DateTime.now();
      final t = fl.progress(now);
      if (t < 1) {
        // Retour vers la souris : la destination suit la souris qui bouge.
        final live = to == null ? ClickyFlight(fl.from, want, fl.start, dpr: dpr) : fl;
        want = live.positionAt(t);
        c.setFlight(live.angleAt(t), live.scaleAt(t));
      } else {
        _flight = null;
        _follow = want;
        c.setFlight(0, 1);
        // Vol fini : plus besoin de recalculer à chaque image.
        if (_frames.isActive) _frames.stop();
      }
    }
    // Fenêtre juste assez grande : minuscule autour du curseur, plus grande
    // quand la boîte de texte est ouverte (elle ne bloque ainsi aucun clic).
    final size = c.board != null || c.holo != null
        ? _withBoard
        : _interactive
        ? _withPanel
        : c.lifeNote.length > 60 && c.state == ClickyState.idle && !c.boxOpen
        ? _compact
        : c.state == ClickyState.pointing || c.gazeNote.isNotEmpty || c.lifeNote.isNotEmpty
        ? _pointing
        : c.boxOpen
        ? _compact
        : _cursorOnly;
    var w = (size.width * dpr).round(), hh = (size.height * dpr).round();
    // On reste dans les écrans.
    final (vx, vy, vw, vh) = Win.virtualScreen();
    var x = want.dx.round().clamp(vx, math.max(vx, vx + vw - w)).toInt();
    var y = want.dy.round().clamp(vy, math.max(vy, vy + vh - hh)).toInt();
    var inside = Offset.zero;
    // Des dessins (flèches, cercles…) : la fenêtre couvre aussi leur zone le
    // temps qu'ils s'affichent.
    if (c.marks.isNotEmpty && !_interactive) {
      var r = Rect.fromLTWH(want.dx, want.dy, w.toDouble(), hh.toDouble());
      for (final m in c.marks) {
        r = r.expandToInclude(m.bounds);
      }
      r = r.inflate(30 * dpr).intersect(Rect.fromLTWH(vx.toDouble(), vy.toDouble(), vw.toDouble(), vh.toDouble()));
      x = r.left.floor();
      y = r.top.floor();
      w = r.width.ceil();
      hh = r.height.ceil();
      inside = (want - Offset(x.toDouble(), y.toDouble())) / dpr;
    }
    final origin = Offset(x.toDouble(), y.toDouble());
    if (inside != _inside || (c.marks.isNotEmpty && origin != _frame)) {
      _inside = inside;
      _frame = origin;
      if (mounted) setState(() {});
    }
    final moved =
        _pos == null ||
        (_pos!.dx - x).abs() >= 1 ||
        (_pos!.dy - y).abs() >= 1 ||
        _size != Size(w.toDouble(), hh.toDouble());
    if (force || moved || _hidden) {
      Win.place(h, x, y, w, hh);
      _pos = origin;
      _size = Size(w.toDouble(), hh.toDouble());
      _hidden = false;
    }
  }

  /// Taille actuelle de la fenêtre, coin de la fenêtre pendant un dessin, et
  /// position du curseur dans la fenêtre.
  Size? _size;
  Offset _frame = Offset.zero;
  Offset _inside = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final dpr = _dpr;
          return ClickyFollower(
            c: c,
            interactive: _interactive,
            pointerAt: c.marks.isEmpty ? Offset.zero : _inside,
            marks: c.marks.isEmpty ? const [] : [for (final m in c.marks) m.map((p) => (p - _frame) / dpr, 1 / dpr)],
          );
        },
      ),
    );
  }
}
