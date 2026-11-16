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

/// « Clicky » : un petit compagnon Claude qui vit à côté de ton curseur.
///
/// * Maintiens **Ctrl + Alt** et parle (ou appuie brièvement pour écrire),
///   ou touche la bulle en bas à droite sur téléphone.
/// * Il voit l'écran de Mon Hub (capture envoyée avec ta question).
/// * Il répond à voix haute, et son curseur bleu **vole jusqu'au bouton**
///   dont il parle pour te le montrer.
/// * Il peut aussi agir dans tes modules (agenda, notes, messages…) ; il te
///   demande la permission avant toute action qui change quelque chose.
enum ClickyState { idle, listening, thinking, speaking, pointing }

class ClickyController extends ChangeNotifier {
  ClickyController._();
  static final instance = ClickyController._();

  HubController? hub;

  ClickyState state = ClickyState.idle;
  String status = '';
  String reply = '';
  String transcript = '';
  bool panelOpen = false;

  /// Position du curseur (coordonnées de l'appli).
  Offset? cursor;

  /// Cible montrée par Claude (coordonnées de l'appli) et son libellé.
  Offset? target;
  String targetLabel = '';

  final shotKey = GlobalKey();

  void moveCursor(Offset p) {
    cursor = p;
    if (follow && enabled && state != ClickyState.pointing) notifyListeners();
  }
  final input = TextEditingController();

  bool get enabled => ClaudeApi.store.getJson<bool>('clicky.enabled') ?? true;
  bool get voice => ClaudeApi.store.getJson<bool>('clicky.voice') ?? true;
  bool get follow => ClaudeApi.store.getJson<bool>('clicky.follow') ?? true;

  Future<void> setOption(String k, bool v) async {
    await ClaudeApi.store.setJson('clicky.$k', v);
    notifyListeners();
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
    if (!await canListen) {
      openPanel();
      _set(ClickyState.idle, status: 'Micro indisponible ici : écris ta question.');
      return;
    }
    transcript = '';
    _set(ClickyState.listening, status: 'Je t\'écoute…');
    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          localeId: 'fr_FR',
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 4),
        ),
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
    await Future<void>.delayed(const Duration(milliseconds: 350));
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
  DateTime? _holdStart;
  Timer? _holdTimer;

  bool _cancelled = false;

  static final _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.altGraph,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  bool onKey(KeyEvent e) {
    if (!enabled) return false;
    final k = HardwareKeyboard.instance;
    // AltGr (claviers français : @, €, #…) envoie aussi Ctrl + Alt : on
    // l'ignore pour ne pas ouvrir Clicky en tapant une adresse mail.
    final altGr = k.physicalKeysPressed.contains(PhysicalKeyboardKey.altRight) ||
        k.logicalKeysPressed.contains(LogicalKeyboardKey.altGraph);
    final both = k.isControlPressed && k.isAltPressed && !altGr;
    if (_holding && e is KeyDownEvent && !_modifiers.contains(e.logicalKey)) {
      // Ctrl + Alt + une touche = un raccourci clavier, pas Clicky.
      _cancelled = true;
      _holdTimer?.cancel();
      if (state == ClickyState.listening) unawaited(stopListening(send: false));
      return false;
    }
    if (both && !_holding && e is KeyDownEvent) {
      _holding = true;
      _cancelled = false;
      _holdStart = DateTime.now();
      // Appui long = on parle. Appui court = on écrit.
      _holdTimer = Timer(const Duration(milliseconds: 350), () {
        if (_holding && !_cancelled) unawaited(startListening());
      });
    } else if (_holding && !both) {
      _holding = false;
      _holdTimer?.cancel();
      if (_cancelled) return false;
      final short = DateTime.now().difference(_holdStart ?? DateTime.now()) <
          const Duration(milliseconds: 350);
      if (short) {
        panelOpen ? closePanel() : openPanel();
      } else {
        unawaited(stopListening());
      }
    }
    return false;
  }

  // ---------- Panneau ----------

  void openPanel() {
    panelOpen = true;
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
    notifyListeners();
  }

  void _set(ClickyState s, {String? status, String? reply}) {
    state = s;
    if (status != null) this.status = status;
    if (reply != null) this.reply = reply;
    notifyListeners();
  }

  // ---------- Question → Claude ----------

  /// Courte mémoire (texte seulement) des derniers échanges.
  final _memory = <(String, String)>[];

  Future<(String, double, Size)?> _capture() async {
    try {
      final b = shotKey.currentContext?.findRenderObject();
      if (b is! RenderRepaintBoundary) return null;
      final size = b.size;
      if (size.isEmpty) return null;
      final ratio = math.min(1.0, 1280 / math.max(size.width, size.height));
      final img = await b.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (data == null) return null;
      return (base64Encode(data.buffer.asUint8List()), ratio, size);
    } catch (_) {
      return null;
    }
  }

  String _system(Size? shot) {
    final modules = hub?.enabled ?? const <HubModule>[];
    final now = DateTime.now();
    return '''
Tu es Clicky, un petit compagnon IA qui vit à côté du curseur dans « Mon Hub », l'appli personnelle d'un·e élève (emploi du temps, École Directe, mails, Discord, Instagram, Roblox, livres, Google Drive…). Tu vois une capture d'écran de l'appli à chaque question.

Modules affichés : ${modules.map((m) => '${m.name} (${m.description})').join(' ; ')}.
Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.

Ta réponse est lue à voix haute :
- réponds en français, comme à l'oral, chaleureux et clair, en 1 à 4 phrases courtes ;
- pas de markdown, pas de listes à puces, pas d'émojis ;
- si on te demande d'expliquer quelque chose (un devoir, une notion), explique simplement, étape par étape, sans faire le travail à la place de l'élève.

Tu peux utiliser les actions des modules pour lire les vraies données (agenda, notes, devoirs, messages…) ou agir. Les actions qui envoient ou modifient quelque chose demandent la permission à la personne.

Montrer à l'écran : quand c'est utile de montrer où cliquer ou de quoi tu parles, termine ta réponse par une balise [POINT:x,y:libellé court] où x,y sont en pixels sur la capture${shot == null ? '' : ' (${shot.width.round()} × ${shot.height.round()} pixels, origine en haut à gauche)'} et vise le centre de l'élément. Une seule balise, à la toute fin. Si rien n'est à montrer, termine par [POINT:none].''';
  }

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    await stopSpeaking();
    input.clear();
    transcript = q;
    target = null;
    _set(ClickyState.thinking, status: 'Je regarde…', reply: '');
    if (!await ClaudeApi.hasKey()) {
      panelOpen = true;
      _set(
        ClickyState.idle,
        status: '',
        reply: 'Pour que je puisse t\'aider, ajoute ta clé API Claude : '
            'module Claude → Réglages (icône clé).',
      );
      return;
    }
    final shot = await _capture();
    final shotPx = shot == null ? null : Size(shot.$3.width * shot.$2, shot.$3.height * shot.$2);
    final history = <Map<String, dynamic>>[
      for (final (u, a) in _memory) ...[
        {'role': 'user', 'content': u},
        {'role': 'assistant', 'content': a},
      ],
      {
        'role': 'user',
        'content': [
          if (shot != null)
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': 'image/png', 'data': shot.$1},
            },
          {'type': 'text', 'text': q},
        ],
      },
    ];
    try {
      final raw = await ClaudeApi.chat(
        system: _system(shotPx),
        history: history,
        tools: [for (final m in hub?.enabled ?? const <HubModule>[]) ...m.tools],
        confirm: _confirm,
        onStatus: (s) => _set(ClickyState.thinking, status: s),
      );
      final (text, point, label) = parsePoint(raw);
      _memory.add((q, text.isEmpty ? '(je t\'ai montré à l\'écran)' : text));
      if (_memory.length > 6) _memory.removeAt(0);
      if (point != null && shot != null) {
        target = Offset(point.dx / shot.$2, point.dy / shot.$2);
        targetLabel = label;
        _set(ClickyState.pointing, status: '', reply: text);
      } else {
        _set(ClickyState.speaking, status: '', reply: text);
      }
      await speak(text);
      if (state == ClickyState.speaking) _set(ClickyState.idle);
      if (state == ClickyState.pointing) {
        // On laisse la flèche le temps de voir, puis Clicky revient.
        Timer(const Duration(seconds: 4), () {
          if (state == ClickyState.pointing) {
            target = null;
            _set(ClickyState.idle);
          }
        });
      }
    } catch (e) {
      panelOpen = true;
      _set(ClickyState.idle, status: '', reply: '$e');
    }
  }

  Future<bool> _confirm(HubTool tool, Map<String, dynamic> args) async {
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
  }

  /// Sépare le texte et la balise [POINT:x,y:libellé].
  static (String, Offset?, String) parsePoint(String raw) {
    final re = RegExp(r'\[POINT:\s*(none|(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?:\s*:\s*([^\]]*))?)\s*\]',
        caseSensitive: false);
    final m = re.allMatches(raw).lastOrNull;
    final text = raw.replaceAll(re, '').trim();
    if (m == null || m.group(1)!.toLowerCase() == 'none') return (text, null, '');
    final x = double.tryParse(m.group(2) ?? '');
    final y = double.tryParse(m.group(3) ?? '');
    if (x == null || y == null) return (text, null, '');
    return (text, Offset(x, y), (m.group(4) ?? '').trim());
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
  }

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
    super.dispose();
  }

  Widget _build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) => _move(e.position, e.kind),
      onPointerMove: (e) => _move(e.position, e.kind),
      child: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(key: c.shotKey, child: widget.child)),
          if (widget.hub != null)
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Listenable.merge([c, ClaudeApi.store]),
                builder: (context, _) => c.enabled ? _Buddy(c: c) : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }

  void _move(Offset p, PointerDeviceKind kind) {
    if (kind != PointerDeviceKind.mouse) return;
    c.moveCursor(p);
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

const _blue = Color(0xFF3B82F6);

class _Buddy extends StatelessWidget {
  const _Buddy({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final mobile = size.width < 600;
    final cursor = c.follow ? c.cursor : null;
    final home = cursor == null
        ? Offset(size.width - 44, size.height - (mobile ? 150 : 60))
        : cursor + const Offset(18, 16);
    final at = c.target ?? home;
    final busy = c.state != ClickyState.idle;
    final showBubble = busy || c.reply.isNotEmpty && c.panelOpen;

    return Stack(
      children: [
        // Le petit curseur bleu de Clicky (suit la souris, vole vers la cible).
        TweenAnimationBuilder<Offset>(
          tween: Tween(end: at),
          duration: c.target != null
              ? const Duration(milliseconds: 650)
              : const Duration(milliseconds: 90),
          curve: c.target != null ? Curves.easeInOutCubic : Curves.linear,
          builder: (context, p, _) => Positioned(
            left: p.dx - 2,
            top: p.dy - 2,
            child: IgnorePointer(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Pointer(state: c.state),
                  if (c.state == ClickyState.pointing && c.targetLabel.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(left: 4, top: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _blue,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [BoxShadow(blurRadius: 8, color: Color(0x33000000))],
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
        ),
        // Bulle de réponse / panneau de saisie.
        if (c.panelOpen || showBubble)
          Positioned(
            right: 16,
            bottom: mobile ? 150 : 76,
            left: mobile ? 16 : null,
            child: _Panel(c: c),
          ),
        // Bouton toujours accessible (indispensable sur téléphone).
        Positioned(
          right: 16,
          bottom: mobile ? 88 : 16,
          child: _Fab(c: c),
        ),
      ],
    );
  }
}

class _Pointer extends StatelessWidget {
  const _Pointer({required this.state});
  final ClickyState state;

  @override
  Widget build(BuildContext context) {
    final pulse = state == ClickyState.listening || state == ClickyState.thinking;
    return SizedBox(
      width: 26,
      height: 26,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (pulse)
            const Positioned(
              left: -6,
              top: -6,
              child: SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(strokeWidth: 2, color: _blue),
              ),
            ),
          CustomPaint(size: const Size(22, 22), painter: _TrianglePainter()),
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
    canvas.drawPath(path, Paint()..color = _blue);
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
          color: listening ? Colors.redAccent : _blue,
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
                  const Icon(Icons.auto_awesome_rounded, color: _blue, size: 18),
                  const SizedBox(width: 6),
                  const Text('Clicky', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (c.state == ClickyState.speaking || c.state == ClickyState.pointing)
                    IconButton(
                      tooltip: 'Arrêter la voix',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.volume_off_rounded, size: 18),
                      onPressed: c.stopSpeaking,
                    ),
                  IconButton(
                    tooltip: 'Fermer',
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
              if (c.status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, right: 8),
                  child: Row(
                    children: [
                      if (busy || c.state == ClickyState.listening)
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
