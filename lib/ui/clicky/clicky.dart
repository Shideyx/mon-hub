import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/claude_api.dart';
import '../../core/hub_controller.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import 'ollama.dart';

/// « Clicky » : un petit compagnon IA qui vit à côté de ton curseur.
///
/// * Maintiens **Ctrl + Alt** et parle, relâche pour envoyer (appui court =
///   écrire). Sur téléphone : la bulle bleue.
/// * Il voit ton écran (capture envoyée avec ta question ; sur Windows, avec
///   « Clicky partout », tous tes écrans et toutes tes applis).
/// * Il répond à voix haute, le texte s'écrit à côté du curseur, et son
///   curseur bleu **vole jusqu'au bouton** dont il parle.
/// * « Agent, … » : il lance une tâche de fond avec tes modules (agenda,
///   notes, messages…) et te prévient quand c'est fini.
/// * Cerveau au choix : Claude (clé API) ou un modèle **local et gratuit**
///   avec Ollama (rien ne sort du PC).
enum ClickyState { idle, listening, thinking, speaking, pointing }

/// Une capture envoyée à l'IA, et comment ramener ses pixels à l'écran.
class ClickyShot {
  const ClickyShot({
    required this.png64,
    required this.label,
    required this.width,
    required this.height,
    this.origin = Offset.zero,
    required this.logicalPerPx,
  });

  final String png64;
  final String label;
  final int width;
  final int height;

  /// Coin haut-gauche de la capture, en coordonnées de la couche Clicky.
  final Offset origin;

  /// Taille d'un pixel de la capture, en coordonnées de la couche Clicky.
  final double logicalPerPx;

  Offset toLayer(Offset px) => origin + px * logicalPerPx;
}

class ClickyController extends ChangeNotifier {
  ClickyController._();
  static final instance = ClickyController._();

  /// Modules de Mon Hub (dans l'appli).
  HubController? hub;

  /// « Clicky partout » (Windows) : actions lues via le pont local, capture
  /// de tous les écrans, et bascule clics traversants / cliquable.
  List<HubTool> Function()? toolsOverride;
  Future<List<ClickyShot>> Function()? captureOverride;
  void Function(bool interactive)? onInteractive;
  bool desktopMode = false;

  /// Alerte système (agent terminé…).
  void Function(String title, String body)? notify;

  ClickyState state = ClickyState.idle;
  String status = '';
  String reply = '';
  String transcript = '';
  bool panelOpen = false;
  int agentsRunning = 0;

  /// Niveaux sonores récents (0..1) pour l'onde pendant l'écoute.
  final levels = List<double>.filled(7, 0);

  /// Position du curseur (coordonnées de la couche Clicky).
  Offset? cursor;

  /// Cible montrée par l'IA (coordonnées de la couche) et son libellé.
  Offset? target;
  String targetLabel = '';

  /// Mode discret : Clicky n'apparaît que pendant un échange.
  bool _recent = false;
  Timer? _fade;

  final shotKey = GlobalKey();
  final input = TextEditingController();

  // ---------- Réglages ----------

  T _opt<T>(String k, T d) => ClaudeApi.store.getJson<T>('clicky.$k') ?? d;
  bool get enabled => _opt('enabled', true);
  bool get voice => _opt('voice', true);
  bool get follow => _opt('follow', true);

  /// Toujours afficher le curseur bleu (sinon seulement pendant un échange).
  bool get alwaysShow => _opt('show', true);

  /// 'claude' (clé API) ou 'ollama' (local, gratuit).
  String get provider => _opt('provider', 'claude');

  /// Windows : Clicky au-dessus de tout l'écran et de toutes les applis.
  bool get everywhere => _opt('everywhere', true);

  static bool get everywhereSupported => !kIsWeb && Platform.isWindows;

  /// Clicky de l'appli désactivé car « Clicky partout » s'en charge.
  bool get handledElsewhere => !desktopMode && everywhereSupported && everywhere;

  Future<void> setOption(String k, Object v) async {
    await ClaudeApi.store.setJson('clicky.$k', v);
    await refreshReady();
    notifyListeners();
  }

  /// Clicky a un cerveau (clé Claude, ou Ollama choisi). Tant que ce n'est
  /// pas le cas, il reste complètement invisible et ne fait rien : le reste
  /// de Mon Hub marche exactement pareil sans lui.
  bool ready = false;

  Future<bool> refreshReady() async {
    bool r;
    try {
      r = provider == 'ollama' || await ClaudeApi.hasKey();
    } catch (_) {
      r = false;
    }
    if (r != ready) {
      ready = r;
      notifyListeners();
    }
    return r;
  }

  /// Clicky doit s'afficher et écouter le clavier.
  bool get active => enabled && ready;

  bool get buddyVisible =>
      alwaysShow || _recent || panelOpen || state != ClickyState.idle || agentsRunning > 0;

  void moveCursor(Offset p) {
    if (cursor == p) return;
    cursor = p;
    if (follow && active && state != ClickyState.pointing && buddyVisible) notifyListeners();
  }

  // ---------- Voix ----------

  final _stt = SpeechToText();
  bool? _sttReady;
  FlutterTts? _tts;

  bool get _voicePlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  Future<bool> get canListen async {
    if (!_voicePlatform) return false;
    if (_sttReady != null) return _sttReady!;
    try {
      _sttReady = await _stt.initialize(onError: (_) {}, onStatus: (_) {});
    } catch (_) {
      _sttReady = false;
    }
    return _sttReady!;
  }

  Future<void> startListening() async {
    await stopSpeaking();
    if (state == ClickyState.thinking) return;
    if (!await canListen) {
      openPanel();
      _set(ClickyState.idle, status: 'Micro indisponible ici : écris ta question.');
      return;
    }
    transcript = '';
    target = null;
    levels.fillRange(0, levels.length, 0);
    _set(ClickyState.listening, status: '', reply: '');
    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          localeId: 'fr_FR',
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 5),
        ),
        onSoundLevelChange: (l) {
          // Selon l'appareil, le niveau va d'environ -2 à 10.
          levels.setRange(0, levels.length - 1, levels.skip(1));
          levels[levels.length - 1] = ((l + 2) / 12).clamp(0.05, 1.0);
          notifyListeners();
        },
        onResult: (r) {
          transcript = r.recognizedWords;
          notifyListeners();
          if (r.finalResult && state == ClickyState.listening && !_holding) {
            unawaited(_sendTranscript());
          }
        },
      );
    } catch (e) {
      _set(ClickyState.idle, status: 'Micro : $e');
    }
  }

  Future<void> stopListening({bool send = true}) async {
    if (state != ClickyState.listening) return;
    try {
      await _stt.stop();
    } catch (_) {}
    // Laisse le temps au dernier mot d'arriver.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (send) {
      await _sendTranscript();
    } else {
      _set(ClickyState.idle, status: '');
    }
  }

  Future<void> _sendTranscript() async {
    if (state != ClickyState.listening) return;
    final t = transcript.trim();
    if (t.isEmpty) {
      _set(ClickyState.idle, status: 'Je n\'ai rien entendu.');
      _fadeSoon();
      return;
    }
    await ask(t);
  }

  Future<void> speak(String text) async {
    if (!voice || !_voicePlatform || text.isEmpty) return;
    try {
      final tts = _tts ??= FlutterTts();
      await tts.setLanguage('fr-FR');
      await tts.setSpeechRate(Platform.isAndroid || Platform.isIOS ? 0.5 : 0.55);
      await tts.awaitSpeakCompletion(true);
      await tts.speak(text);
    } catch (_) {}
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  // ---------- Clavier : maintenir Ctrl + Alt ----------

  bool _holding = false;
  bool _cancelled = false;
  DateTime? _holdStart;
  Timer? _holdTimer;

  /// Appelé quand Ctrl + Alt (sans AltGr) est enfoncé ou relâché, ou quand
  /// une autre touche est tapée pendant l'appui ([other]).
  void hotkey({required bool down, bool other = false}) {
    if (!active) return;
    if (_holding && other) {
      // Ctrl + Alt + une touche = un raccourci clavier, pas Clicky.
      _cancelled = true;
      _holdTimer?.cancel();
      if (state == ClickyState.listening) unawaited(stopListening(send: false));
      return;
    }
    if (down && !_holding) {
      _holding = true;
      _cancelled = false;
      _holdStart = DateTime.now();
      _recent = true;
      // Appui long = on parle. Appui court = on écrit.
      _holdTimer = Timer(const Duration(milliseconds: 350), () {
        if (_holding && !_cancelled) unawaited(startListening());
      });
    } else if (!down && _holding) {
      _holding = false;
      _holdTimer?.cancel();
      if (_cancelled) return;
      final short =
          DateTime.now().difference(_holdStart ?? DateTime.now()) <
          const Duration(milliseconds: 350);
      if (short) {
        panelOpen ? closePanel() : openPanel();
      } else {
        unawaited(stopListening());
      }
    }
  }

  static final _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.altGraph,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  /// Clavier de l'appli (quand Clicky vit dans la fenêtre de Mon Hub).
  bool onKey(KeyEvent e) {
    try {
      return _onKey(e);
    } catch (_) {
      return false; // Clicky ne doit jamais gêner le clavier de l'appli
    }
  }

  bool _onKey(KeyEvent e) {
    if (!active || handledElsewhere) return false;
    final k = HardwareKeyboard.instance;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && panelOpen) {
      closePanel();
      return false;
    }
    // AltGr (claviers français : @, €, #…) envoie aussi Ctrl + Alt : on
    // l'ignore pour ne pas ouvrir Clicky en tapant une adresse mail.
    final altGr =
        k.physicalKeysPressed.contains(PhysicalKeyboardKey.altRight) ||
        k.logicalKeysPressed.contains(LogicalKeyboardKey.altGraph);
    final both = k.isControlPressed && k.isAltPressed && !altGr;
    if (_holding && e is KeyDownEvent && !_modifiers.contains(e.logicalKey)) {
      hotkey(down: true, other: true);
    } else if (both && !_holding && e is KeyDownEvent) {
      hotkey(down: true);
    } else if (_holding && !both) {
      hotkey(down: false);
    }
    return false;
  }

  // ---------- Panneau ----------

  void openPanel() {
    panelOpen = true;
    _recent = true;
    onInteractive?.call(true);
    notifyListeners();
  }

  void closePanel() {
    panelOpen = false;
    unawaited(stopSpeaking());
    if (state == ClickyState.listening) unawaited(stopListening(send: false));
    if (state == ClickyState.speaking || state == ClickyState.pointing) {
      state = ClickyState.idle;
    }
    target = null;
    onInteractive?.call(false);
    _fadeSoon();
    notifyListeners();
  }

  /// Mode discret : Clicky disparaît 1 s après la fin de l'échange.
  void _fadeSoon() {
    _fade?.cancel();
    _fade = Timer(const Duration(seconds: 1), () {
      if (state == ClickyState.idle && !panelOpen) {
        _recent = false;
        notifyListeners();
      }
    });
    // La bulle de réponse s'efface après quelques secondes.
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 8), () {
      if (state == ClickyState.idle && !panelOpen && (reply.isNotEmpty || status.isNotEmpty)) {
        reply = '';
        status = '';
        notifyListeners();
      }
    });
  }

  Timer? _clear;

  void _set(ClickyState s, {String? status, String? reply}) {
    state = s;
    if (status != null) this.status = status;
    if (reply != null) this.reply = reply;
    if (s != ClickyState.idle) {
      _recent = true;
      _clear?.cancel();
    }
    notifyListeners();
  }

  // ---------- Question → IA ----------

  /// Courte mémoire (texte seulement) des derniers échanges.
  final _memory = <(String, String)>[];

  /// Capture de la fenêtre de Mon Hub (Clicky dans l'appli).
  Future<List<ClickyShot>> _captureApp() async {
    try {
      final b = shotKey.currentContext?.findRenderObject();
      if (b is! RenderRepaintBoundary) return const [];
      final size = b.size;
      if (size.isEmpty) return const [];
      final ratio = math.min(1.0, 1280 / math.max(size.width, size.height));
      final img = await b.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null) return const [];
      return [
        ClickyShot(
          png64: base64Encode(data.buffer.asUint8List()),
          label: 'fenêtre de Mon Hub',
          width: w,
          height: h,
          logicalPerPx: 1 / ratio,
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  List<HubTool> get _tools =>
      toolsOverride?.call() ?? [for (final m in hub?.enabled ?? const <HubModule>[]) ...m.tools];

  String _system(List<ClickyShot> shots, {bool agent = false}) {
    final modules = hub?.enabled ?? const <HubModule>[];
    final now = DateTime.now();
    final where = desktopMode
        ? 'Tu vois une capture de chaque écran de l\'ordinateur (toutes les applis, pas seulement Mon Hub).'
        : 'Tu vois une capture de la fenêtre de l\'appli Mon Hub.';
    final screens = [
      for (var i = 0; i < shots.length; i++)
        'Image ${i + 1} = écran ${i + 1} (${shots[i].label}, ${shots[i].width} × ${shots[i].height} pixels)',
    ].join(' ; ');
    final base =
        '''
Tu es Clicky, un petit compagnon IA qui vit à côté du curseur de la personne, dans « Mon Hub », l'appli personnelle d'un·e élève (emploi du temps, École Directe, mails, Discord, Instagram, Roblox, livres, Google Drive…). $where
${modules.isEmpty ? '' : 'Modules de Mon Hub : ${modules.map((m) => '${m.name} (${m.description})').join(' ; ')}.'}
Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.''';
    if (agent) {
      return '''$base

Tu travailles en arrière-plan comme agent : fais la tâche demandée jusqu'au bout avec les actions disponibles (lire l'agenda, les notes, les devoirs, les messages, chercher dans Drive, envoyer un message…). Les actions qui envoient ou modifient quelque chose demandent la permission. Termine par un compte rendu en français de 1 à 3 phrases simples, lisible à voix haute, sans markdown.''';
    }
    return '''$base

Ta réponse est lue à voix haute :
- réponds en français, comme à l'oral, chaleureux et clair, en 1 à 4 phrases courtes ;
- pas de markdown, pas de listes à puces, pas d'émojis ;
- si on te demande d'expliquer quelque chose (un devoir, une notion, un logiciel), explique simplement, étape par étape, sans faire le travail à la place de l'élève.
${_tools.isEmpty ? '' : 'Tu peux utiliser les actions de Mon Hub pour lire les vraies données (agenda, notes, devoirs, messages…) ou agir ; celles qui envoient ou modifient quelque chose demandent la permission.'}

Montrer à l'écran : quand c'est utile de montrer où cliquer ou de quoi tu parles, termine ta réponse par une balise [POINT:x,y:libellé court${shots.length > 1 ? ':screenN' : ''}] où x,y sont en pixels sur l'image (origine en haut à gauche) et visent le centre de l'élément${shots.length > 1 ? ', et N le numéro de l\'écran' : ''}. ${screens.isEmpty ? '' : '$screens.'} Une seule balise, à la toute fin. Si rien n'est à montrer, termine par [POINT:none].''';
  }

  static final _agentRe = RegExp(
    r'^\s*(?:(?:hey|ok|dis|eh)\s+)?(?:clicky[\s,]+)?agent\b[\s,:]*',
    caseSensitive: false,
  );

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    await stopSpeaking();
    input.clear();
    transcript = q;
    target = null;
    final agent = _agentRe.firstMatch(q);
    if (agent != null) {
      unawaited(_runAgent(q.substring(agent.end).trim()));
      return;
    }
    _set(ClickyState.thinking, status: 'Je regarde…', reply: '');
    final useOllama = provider == 'ollama';
    if (!useOllama && !await ClaudeApi.hasKey()) {
      _needsSetup();
      return;
    }
    final shots = await (captureOverride ?? _captureApp)();
    try {
      final String raw;
      void streamed(String t) {
        final clean = _stripTag(t);
        if (clean != reply) _set(state, status: '', reply: clean);
      }

      if (useOllama) {
        raw = await Ollama.chat(
          system: _system(shots),
          memory: _memory,
          question: q,
          imagesB64: [for (final s in shots) s.png64],
          onText: streamed,
        );
      } else {
        final history = <Map<String, dynamic>>[
          for (final (u, a) in _memory) ...[
            {'role': 'user', 'content': u},
            {'role': 'assistant', 'content': a},
          ],
          {
            'role': 'user',
            'content': [
              for (final s in shots) ...[
                {'type': 'text', 'text': 'Écran ${shots.indexOf(s) + 1} (${s.label}) :'},
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': s.png64},
                },
              ],
              {'type': 'text', 'text': q},
            ],
          },
        ];
        raw = await ClaudeApi.chat(
          system: _system(shots),
          history: history,
          tools: _tools,
          confirm: _confirm,
          onStatus: (s) => _set(ClickyState.thinking, status: s),
          onText: streamed,
        );
      }
      final (text, point, label, screen) = parsePoint(raw);
      _memory.add((q, text.isEmpty ? '(je t\'ai montré à l\'écran)' : text));
      if (_memory.length > 6) _memory.removeAt(0);
      final shot = shots.isEmpty ? null : shots[(screen - 1).clamp(0, shots.length - 1)];
      if (point != null && shot != null) {
        target = shot.toLayer(point);
        targetLabel = label;
        _set(ClickyState.pointing, status: '', reply: text);
      } else {
        _set(ClickyState.speaking, status: '', reply: text);
      }
      await speak(text);
      if (state == ClickyState.speaking) {
        _set(ClickyState.idle);
        _fadeSoon();
      }
      if (state == ClickyState.pointing) {
        // On laisse la flèche le temps de voir, puis Clicky revient.
        Timer(const Duration(seconds: 4), () {
          if (state == ClickyState.pointing) {
            target = null;
            _set(ClickyState.idle);
            _fadeSoon();
          }
        });
      }
    } catch (e) {
      panelOpen = true;
      onInteractive?.call(true);
      _set(ClickyState.idle, status: '', reply: e is MissingKey ? '$e' : '$e');
    }
  }

  void _needsSetup() {
    panelOpen = true;
    onInteractive?.call(true);
    _set(
      ClickyState.idle,
      status: '',
      reply:
          'Pour que je puisse t\'aider, choisis mon cerveau dans le module Claude '
          '→ Réglages (icône clé) : une clé API Claude, ou Ollama, gratuit et sur ton PC.',
    );
  }

  /// Tâche de fond : Clicky reste disponible pendant que l'agent travaille.
  Future<void> _runAgent(String task) async {
    if (task.isEmpty) {
      _set(
        ClickyState.idle,
        reply:
            'Dis-moi ce que l\'agent doit faire, par exemple : '
            '« agent, résume mes devoirs de la semaine ».',
      );
      return;
    }
    if (provider != 'claude' || !await ClaudeApi.hasKey()) {
      _set(
        ClickyState.idle,
        reply: 'Le mode agent a besoin de Claude (clé API) pour utiliser tes modules.',
      );
      return;
    }
    agentsRunning++;
    _set(ClickyState.idle, status: '', reply: 'C\'est parti, je m\'en occupe en arrière-plan.');
    unawaited(speak('C\'est parti, je m\'en occupe.'));
    _fadeSoon();
    try {
      final r = await ClaudeApi.chat(
        system: _system(const [], agent: true),
        history: [
          {'role': 'user', 'content': task},
        ],
        tools: _tools,
        confirm: _confirm,
        effort: 'high',
      );
      final text = parsePoint(r).$1;
      agentsRunning--;
      _set(state, reply: 'Agent : $text');
      notify?.call('Clicky : tâche terminée', text);
      if (state == ClickyState.idle) await speak('Ton agent a fini. $text');
    } catch (e) {
      agentsRunning--;
      _set(state, reply: 'L\'agent n\'a pas pu finir : $e');
    }
    _fadeSoon();
  }

  Future<bool> _confirm(HubTool tool, Map<String, dynamic> args) async {
    onInteractive?.call(true);
    try {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
      if (ctx == null || !ctx.mounted) return false;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.auto_awesome_rounded),
          title: const Text('Clicky veut agir'),
          content: SingleChildScrollView(
            child: Text(
              '${tool.description}\n\n'
              '${args.entries.map((e) => '• ${e.key} : ${e.value}').join('\n')}',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Refuser')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Autoriser')),
          ],
        ),
      );
      return ok == true;
    } finally {
      if (!panelOpen) onInteractive?.call(false);
    }
  }

  static final _tagRe = RegExp(r'\[POINT:\s*([^\]]*)\]', caseSensitive: false);

  /// Retire la balise (même à moitié écrite) du texte affiché en direct.
  static String _stripTag(String t) =>
      t.replaceAll(_tagRe, '').replaceFirst(RegExp(r'\[[^\]]*$'), '').trim();

  /// Sépare le texte et la balise [POINT:x,y:libellé(:screenN)].
  /// Renvoie (texte, point, libellé, numéro d'écran à partir de 1).
  static (String, Offset?, String, int) parsePoint(String raw) {
    final m = _tagRe.allMatches(raw).lastOrNull;
    final text = raw.replaceAll(_tagRe, '').trim();
    if (m == null) return (text, null, '', 1);
    final inner = m.group(1)!.trim();
    final c = RegExp(r'^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::\s*(.*))?$')
        .firstMatch(inner);
    if (c == null) return (text, null, '', 1);
    var label = (c.group(3) ?? '').trim();
    var screen = 1;
    final s = RegExp(r':?\s*screen\s*(\d+)\s*$', caseSensitive: false).firstMatch(label);
    if (s != null) {
      screen = int.parse(s.group(1)!);
      label = label.substring(0, s.start).trim();
    }
    return (text, Offset(double.parse(c.group(1)!), double.parse(c.group(2)!)), label, screen);
  }
}

/// Couche posée au-dessus de toute l'appli (voir `MaterialApp.builder`).
class ClickyLayer extends StatefulWidget {
  const ClickyLayer({super.key, required this.child, this.hub});
  final Widget child;
  final HubController? hub;

  @override
  State<ClickyLayer> createState() => _ClickyLayerState();
}

class _ClickyLayerState extends State<ClickyLayer> {
  final c = ClickyController.instance;
  late final OverlayEntry _entry = OverlayEntry(builder: _build);

  @override
  void initState() {
    super.initState();
    c.hub = widget.hub;
    HardwareKeyboard.instance.addHandler(c.onKey);
    ClaudeApi.store.addListener(_settingsChanged);
    _settingsChanged();
  }

  void _settingsChanged() => unawaited(c.refreshReady());

  @override
  void didUpdateWidget(ClickyLayer old) {
    super.didUpdateWidget(old);
    c.hub = widget.hub;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_entry.mounted) _entry.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(c.onKey);
    ClaudeApi.store.removeListener(_settingsChanged);
    super.dispose();
  }

  Widget _build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) => _move(e.position, e.kind),
      onPointerMove: (e) => _move(e.position, e.kind),
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(key: c.shotKey, child: widget.child),
          ),
          if (widget.hub != null)
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Listenable.merge([c, ClaudeApi.store]),
                // Sans cerveau configuré (ou désactivé) : aucun Clicky.
                builder: (context, _) =>
                    c.active && !c.handledElsewhere ? ClickyBuddy(c: c) : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }

  void _move(Offset p, PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.mouse) c.moveCursor(p);
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

const clickyBlue = Color(0xFF3B82F6);

/// Le curseur bleu, sa bulle de texte, le panneau et le bouton.
class ClickyBuddy extends StatelessWidget {
  const ClickyBuddy({super.key, required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final desktop = c.desktopMode;
    final mobile = !desktop && size.width < 600;
    final cursor = c.follow ? c.cursor : null;
    final home = cursor == null
        ? Offset(size.width - 44, size.height - (mobile ? 150 : 60))
        : cursor + const Offset(18, 16);
    final at = c.target ?? home;
    final showBubble = c.state != ClickyState.idle || (c.reply.isNotEmpty && c.buddyVisible);

    // Bulle de texte à côté du curseur (comme Clicky), gardée dans l'écran.
    const bubbleW = 300.0;
    final bubbleLeft = (at.dx + 30 + bubbleW > size.width) ? at.dx - 14 - bubbleW : at.dx + 30;
    final bubbleTop = (at.dy + 4).clamp(8.0, math.max(8.0, size.height - 180)).toDouble();

    return Stack(
      children: [
        // Dans « Clicky partout », un clic à côté du panneau le ferme.
        if (desktop && c.panelOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: c.closePanel,
              child: const SizedBox.expand(),
            ),
          ),
        // Le petit curseur bleu de Clicky (suit la souris, vole vers la cible).
        AnimatedOpacity(
          opacity: c.buddyVisible ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Stack(
            children: [
              _Flight(
                to: at,
                flying: c.target != null,
                child: IgnorePointer(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Pointer(c: c),
                      if (c.state == ClickyState.pointing && c.targetLabel.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(left: 4, top: 14),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: clickyBlue,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [BoxShadow(blurRadius: 8, color: Color(0x33000000))],
                          ),
                          child: Text(
                            c.targetLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (showBubble && !c.panelOpen && !mobile && cursor != null)
                AnimatedPositioned(
                  duration: Duration(milliseconds: c.target != null ? 650 : 90),
                  curve: Curves.easeInOutCubic,
                  left: bubbleLeft.clamp(8.0, math.max(8.0, size.width - bubbleW - 8)),
                  top: bubbleTop,
                  width: bubbleW,
                  child: IgnorePointer(child: _Bubble(c: c)),
                ),
            ],
          ),
        ),
        // Panneau (question écrite, réponse complète).
        if (c.panelOpen || (showBubble && (mobile || cursor == null)))
          Positioned(
            right: desktop ? null : 16,
            left: desktop
                ? (at.dx + 30).clamp(8.0, math.max(8.0, size.width - 396))
                : (mobile ? 16 : null),
            top: desktop ? (at.dy + 24).clamp(8.0, math.max(8.0, size.height - 380)) : null,
            bottom: desktop ? null : (mobile ? 150 : 76),
            child: _Panel(c: c),
          ),
        // Bouton toujours accessible dans l'appli (indispensable sur téléphone).
        if (!desktop)
          Positioned(
            right: 16,
            bottom: mobile ? 88 : 16,
            child: _Fab(c: c),
          ),
      ],
    );
  }
}

/// Contenu de la petite fenêtre de « Clicky partout » : la fenêtre elle-même
/// suit la souris, le bout du curseur bleu est dans son coin haut-gauche.
class ClickyFollower extends StatelessWidget {
  const ClickyFollower({super.key, required this.c, required this.interactive});
  final ClickyController c;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final showBubble =
        !interactive && (c.state != ClickyState.idle || (c.reply.isNotEmpty && c.buddyVisible));
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: IgnorePointer(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Pointer(c: c),
                if (c.state == ClickyState.pointing && c.targetLabel.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(left: 4, top: 14),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: clickyBlue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      c.targetLabel,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (showBubble && c.state != ClickyState.pointing)
          Positioned(
            left: 30,
            top: 6,
            right: 8,
            child: IgnorePointer(child: _Bubble(c: c)),
          ),
        if (interactive) Positioned(left: 22, top: 26, right: 4, child: _Panel(c: c)),
      ],
    );
  }
}

/// Vol du curseur : suit la souris de près, et fait un arc (courbe de
/// Bézier) quand il part montrer quelque chose.
class _Flight extends StatefulWidget {
  const _Flight({required this.to, required this.flying, required this.child});
  final Offset to;
  final bool flying;
  final Widget child;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late Offset _from = widget.to;
  late Offset _pos = widget.to;

  @override
  void initState() {
    super.initState();
    _a.addListener(() {
      final t = Curves.easeInOutCubic.transform(_a.value);
      final a = _from, b = widget.to;
      // Point de contrôle au-dessus du milieu : joli arc.
      final mid = Offset((a.dx + b.dx) / 2, math.min(a.dy, b.dy) - (b - a).distance * 0.3 - 30);
      final u = 1 - t;
      setState(() => _pos = a * (u * u) + mid * (2 * u * t) + b * (t * t));
    });
  }

  @override
  void didUpdateWidget(_Flight old) {
    super.didUpdateWidget(old);
    if (old.to == widget.to) return;
    final arc = widget.flying != old.flying || (widget.to - _pos).distance > 300;
    if (arc) {
      _from = _pos;
      _a.forward(from: 0);
    } else if (!_a.isAnimating) {
      _pos = widget.to;
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Positioned(left: _pos.dx - 2, top: _pos.dy - 2, child: widget.child);
}

class _Pointer extends StatelessWidget {
  const _Pointer({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final thinking = c.state == ClickyState.thinking;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 26,
          height: 26,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (thinking)
                const Positioned(
                  left: -6,
                  top: -6,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(strokeWidth: 2, color: clickyBlue),
                  ),
                ),
              CustomPaint(size: const Size(22, 22), painter: _TrianglePainter()),
              if (c.agentsRunning > 0)
                Positioned(
                  right: -4,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${c.agentsRunning}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (c.state == ClickyState.listening) _Wave(levels: c.levels),
      ],
    );
  }
}

/// Petite onde qui bouge avec ta voix.
class _Wave extends StatelessWidget {
  const _Wave({required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 2, top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: clickyBlue, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final l in levels)
            AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              width: 3,
              height: 4.0 + 14 * l,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, s.height * 0.42)
      ..lineTo(s.width * 0.45, s.height * 0.55)
      ..lineTo(s.width * 0.32, s.height)
      ..close();
    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(path, Paint()..color = clickyBlue);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Bulle compacte à côté du curseur : ce que tu as dit, puis la réponse
/// qui s'écrit en direct.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final text = switch (c.state) {
      ClickyState.listening => c.transcript.isEmpty ? 'Je t\'écoute…' : c.transcript,
      ClickyState.thinking =>
        c.reply.isNotEmpty ? c.reply : (c.status.isEmpty ? 'Je regarde…' : c.status),
      _ => c.reply.isNotEmpty ? c.reply : c.status,
    };
    if (text.isEmpty) return const SizedBox.shrink();
    final listening = c.state == ClickyState.listening;
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 170),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: listening ? Colors.white : const Color(0xF21E293B),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(blurRadius: 10, color: Color(0x40000000))],
        ),
        child: SingleChildScrollView(
          reverse: true,
          child: Text(
            text,
            style: TextStyle(
              color: listening ? const Color(0xFF1E293B) : Colors.white,
              fontStyle: listening ? FontStyle.italic : FontStyle.normal,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _Fab extends StatelessWidget {
  const _Fab({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final listening = c.state == ClickyState.listening;
    return Tooltip(
      message: 'Clicky (maintiens Ctrl + Alt pour parler)',
      child: GestureDetector(
        onLongPressStart: (_) => c.startListening(),
        onLongPressEnd: (_) => c.stopListening(),
        child: Material(
          color: listening ? Colors.redAccent : clickyBlue,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => c.panelOpen ? c.closePanel() : c.openPanel(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = c.state == ClickyState.thinking;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: scheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: clickyBlue, size: 18),
                  const SizedBox(width: 6),
                  const Text('Clicky', style: TextStyle(fontWeight: FontWeight.w700)),
                  if (c.agentsRunning > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '· ${c.agentsRunning} agent${c.agentsRunning > 1 ? 's' : ''} au travail',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                  const Spacer(),
                  if (c.state == ClickyState.speaking || c.state == ClickyState.pointing)
                    IconButton(
                      tooltip: 'Arrêter la voix',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.volume_off_rounded, size: 18),
                      onPressed: c.stopSpeaking,
                    ),
                  IconButton(
                    tooltip: 'Fermer (Échap)',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: c.closePanel,
                  ),
                ],
              ),
              if (c.transcript.isNotEmpty && c.state != ClickyState.idle)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, right: 8),
                  child: Text(
                    '« ${c.transcript} »',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic),
                  ),
                ),
              if (c.state == ClickyState.listening)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _Wave(levels: c.levels),
                  ),
                ),
              if (c.status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, right: 8),
                  child: Row(
                    children: [
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Expanded(child: Text(c.status)),
                    ],
                  ),
                ),
              if (c.reply.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 8, bottom: 6),
                    child: SelectableText(c.reply),
                  ),
                ),
              if (c.panelOpen)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: c.input,
                        autofocus: true,
                        enabled: !busy,
                        textInputAction: TextInputAction.send,
                        onSubmitted: c.ask,
                        decoration: const InputDecoration(
                          hintText: 'Demande-moi quelque chose…',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Parler',
                      icon: Icon(
                        c.state == ClickyState.listening ? Icons.stop_rounded : Icons.mic_rounded,
                      ),
                      onPressed: busy
                          ? null
                          : () => c.state == ClickyState.listening
                                ? c.stopListening()
                                : c.startListening(),
                    ),
                    IconButton(
                      tooltip: 'Envoyer',
                      icon: const Icon(Icons.send_rounded),
                      onPressed: busy ? null : () => c.ask(c.input.text),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
