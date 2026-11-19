import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';
import 'package:win32/win32.dart';

import '../../core/certificates.dart';
import '../../core/claude_api.dart';
import '../../core/desktop_widgets.dart';
import '../../core/error_log.dart';
import '../../core/module_store.dart';
import '../../core/session.dart';
import '../../core/windows_look.dart';
import 'loopback.dart';
import 'oral_coach.dart';
import 'pcm_player.dart';
import 'whisper.dart';

/// **Sous-titres en direct** de tout ce qui passe sur le PC (vidéo, série,
/// jeu, appel) : le son du PC est capté par Windows, découpé en morceaux de
/// quelques secondes, et Gemini écrit la traduction en français dans une
/// petite fenêtre toujours au premier plan. Sans clé Gemini : Whisper (sur
/// le PC) écrit ce qui est dit, dans la langue d'origine.
class LiveCaptions {
  LiveCaptions._();

  static const id = 'soustitres';

  /// Durée d'un morceau (le quota gratuit de Gemini : ~10 demandes par minute).
  static const chunk = Duration(seconds: 8);
  static int bytesFor(Duration d) => d.inMilliseconds * 32; // 16 kHz × 2 octets

  static bool get supported => LoopbackCapture.supported;

  /// Ouvre la fenêtre (un programme à part, comme les widgets détachés).
  static Future<void> launch() async {
    if (!supported) return;
    if (await DesktopWidgets.running(id)) {
      await DesktopWidgets.send(id, 'front');
      return;
    }
    await Process.start(Platform.resolvedExecutable, ['--widget=$id'], mode: ProcessStartMode.detached);
  }

  static Future<void> close() => DesktopWidgets.send(id, 'quit');

  /// Un fichier WAV (16 kHz mono 16 bits) à partir de PCM brut.
  static Uint8List wav(Uint8List pcm) {
    final b = BytesBuilder();
    final h = ByteData(44);
    void str(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    h
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, 16000, Endian.little)
      ..setUint32(28, 32000, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    str(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    b
      ..add(h.buffer.asUint8List())
      ..add(pcm);
    return b.takeBytes();
  }

  static String prompt(String target) =>
      'Extrait audio de ce qui passe sur l\'ordinateur (vidéo, série, jeu, appel). Écris en $target ce qui est dit, '
      'comme des sous-titres : traduis si c\'est dans une autre langue, va à la ligne quand quelqu\'un d\'autre parle. '
      'Réponds seulement par le texte des sous-titres, sans commentaire. S\'il n\'y a pas de paroles (musique, bruit, '
      'silence), réponds exactement : (rien)';

  /// Le texte à afficher (null : pas de paroles).
  static String? clean(String answer) {
    var t = answer.trim().replaceAll(RegExp(r'^```\w*|```$'), '').trim();
    t = t.replaceAll(RegExp(r'^(?:sous-titres?|subtitles?)\s*:\s*', caseSensitive: false), '');
    final low = t.toLowerCase();
    if (t.isEmpty || low.contains('(rien)') || low == 'rien' || RegExp(r'^\[?(musique|music|silence|bruit)\]?\.?$').hasMatch(low)) {
      return null;
    }
    return t.length > 400 ? '${t.substring(0, 400)}…' : t;
  }
}

/// Point d'entrée de `hub.exe --widget=soustitres`.
Future<void> runCaptionsWindow() async {
  WidgetsFlutterBinding.ensureInitialized();
  DesktopWidgets.inWidgetWindow = true;
  ErrorLog.install('Sous-titres');
  final ServerSocket lock;
  try {
    lock = await ServerSocket.bind(InternetAddress.loopbackIPv4, DesktopWidgets.port(LiveCaptions.id));
  } catch (_) {
    exit(0); // déjà ouverte
  }
  await TrustedCertificates.install();
  await ModuleStore.init();
  AppSession.instance.restore();
  if (AppSession.instance.current == null) exit(0);
  lock.listen((sock) {
    utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) {
      final cmd = line.trim();
      if (cmd == 'quit') exit(0);
      if (cmd == 'front') _CaptionsViewState.front();
    }, onError: (_) {});
  });
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF7C5CFF)),
      home: const _CaptionsView(),
    ),
  );
}

class _CaptionsView extends StatefulWidget {
  const _CaptionsView();

  @override
  State<_CaptionsView> createState() => _CaptionsViewState();
}

class _CaptionsViewState extends State<_CaptionsView> {
  static HWND? _hwnd;
  StreamSubscription<Uint8List>? _sub;
  final _pending = BytesBuilder(copy: false);
  final _lines = <String>[];
  String _status = 'J\'écoute le son du PC…';
  String _target = 'français';
  Duration _chunk = LiveCaptions.chunk;
  bool _busy = false;
  bool _paused = false;
  double _level = 0;
  Directory? _dir;

  static void front() {
    final h = _hwnd;
    if (h == null) return;
    ShowWindow(h, SW_RESTORE);
    SetForegroundWindow(h);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _place());
    _start();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  /// En bas de l'écran, au milieu, toujours au premier plan.
  void _place() {
    final h = _hwnd = WindowsLook.mainWindow();
    if (h == null) return;
    using((a) => SetWindowText(h, 'Sous-titres — Mon Hub'.toPcwstr(allocator: a)));
    final w = GetSystemMetrics(SM_CXSCREEN);
    final sh = GetSystemMetrics(SM_CYSCREEN);
    const ww = 960;
    const wh = 210;
    SetWindowPos(h, HWND_TOPMOST, (w - ww) ~/ 2, sh - wh - 70, ww, wh, const SET_WINDOW_POS_FLAGS(0));
  }

  void _start() {
    _sub = LoopbackCapture.start().listen(
      (pcm) {
        if (_paused) return;
        _pending.add(pcm);
        final lv = PcmPlayer.rms(pcm);
        if ((lv - _level).abs() > 0.05 && mounted) setState(() => _level = lv);
        if (_pending.length >= LiveCaptions.bytesFor(_chunk)) {
          final piece = _pending.takeBytes();
          // En retard (réponse lente) : on garde seulement le plus récent.
          if (_busy) return;
          unawaited(_caption(piece));
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _status = '$e');
      },
    );
  }

  Future<void> _caption(Uint8List pcm) async {
    if (PcmPlayer.rms(pcm) < 0.02) {
      if (mounted) setState(() => _status = 'Pas de paroles pour l\'instant…');
      return;
    }
    _busy = true;
    try {
      _dir ??= await Directory.systemTemp.createTemp('mh-soustitres');
      final f = File('${_dir!.path}${Platform.pathSeparator}morceau.wav');
      await f.writeAsBytes(LiveCaptions.wav(pcm), flush: true);
      final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
      String? text;
      if (key.isNotEmpty) {
        try {
          text = LiveCaptions.clean(await OralCoach.listen(f.path, LiveCaptions.prompt(_target), key));
          _status = 'Traduction en $_target';
        } catch (e) {
          if ('$e'.contains('429')) {
            // Quota gratuit : des morceaux plus longs (moins de demandes).
            _chunk = const Duration(seconds: 14);
            _status = 'Quota Gemini presque atteint : sous-titres un peu plus lents.';
          } else {
            _status = 'Gemini ne répond pas ($e)';
          }
        }
      } else if (await Whisper.ready) {
        text = LiveCaptions.clean(await Whisper.transcribe(f.path, lang: 'auto', timeout: const Duration(seconds: 30)));
        _status = 'Sans clé Gemini : texte dans la langue d\'origine';
      } else {
        _status = 'Il me faut ta clé Gemini gratuite (Réglages de Clicky → Voix) ou Whisper.';
      }
      if (text != null && mounted) {
        setState(() {
          _lines.add(text!);
          if (_lines.length > 3) _lines.removeAt(0);
        });
      } else if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xF20B0A12),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq_rounded, size: 18, color: Color.lerp(Colors.white38, const Color(0xFF8B5CF6), _level.clamp(0.0, 1.0))),
                const SizedBox(width: 8),
                Expanded(child: Text(_status, style: const TextStyle(fontSize: 12, color: Colors.white60), overflow: TextOverflow.ellipsis)),
                DropdownButton<String>(
                  value: _target,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  items: const [
                    DropdownMenuItem(value: 'français', child: Text('→ Français')),
                    DropdownMenuItem(value: 'anglais', child: Text('→ English')),
                    DropdownMenuItem(value: 'espagnol', child: Text('→ Español')),
                  ],
                  onChanged: (v) => setState(() => _target = v ?? _target),
                ),
                IconButton(
                  tooltip: _paused ? 'Reprendre' : 'Pause',
                  iconSize: 18,
                  onPressed: () => setState(() => _paused = !_paused),
                  icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                ),
                IconButton(tooltip: 'Fermer', iconSize: 18, onPressed: () => exit(0), icon: const Icon(Icons.close_rounded)),
              ],
            ),
            Expanded(
              child: Center(
                child: _lines.isEmpty
                    ? const Text('Lance une vidéo, une série ou un jeu : les sous-titres s\'écrivent ici.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: Colors.white54))
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < _lines.length; i++)
                            Text(
                              _lines[i],
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: i == _lines.length - 1 ? 24 : 16,
                                height: 1.25,
                                fontWeight: i == _lines.length - 1 ? FontWeight.w700 : FontWeight.w400,
                                color: i == _lines.length - 1 ? Colors.white : Colors.white54,
                                shadows: const [Shadow(blurRadius: 6, color: Colors.black)],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
