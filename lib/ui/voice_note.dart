import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';

import 'widgets.dart';

/// Lecteur d'un message vocal (Instagram, Discord…) : lecture / pause,
/// onde sonore, avancement, vitesse ×1 / ×1,5 / ×2.
///
/// Un seul vocal joue à la fois : en lancer un autre arrête le précédent.
class VoiceNotePlayer extends StatefulWidget {
  const VoiceNotePlayer({
    super.key,
    required this.url,
    this.duration,
    this.waveform = const [],
    required this.color,
    this.onColor = Colors.white,
  });

  final String url;

  /// Durée annoncée par le service (avant le chargement du son).
  final Duration? duration;

  /// Hauteurs de l'onde (0..1), si le service les donne.
  final List<double> waveform;
  final Color color;
  final Color onColor;

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  static _VoiceNotePlayerState? _playing;

  AudioPlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  Duration _pos = Duration.zero;
  Duration? _len;
  bool _on = false;
  bool _loading = false;
  bool _failed = false;
  double _rate = 1;

  @override
  void dispose() {
    if (_playing == this) _playing = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }

  AudioPlayer _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = _player = AudioPlayer();
    _subs.addAll([
      p.onPositionChanged.listen((d) => mounted ? setState(() => _pos = d) : null),
      p.onDurationChanged.listen((d) => mounted ? setState(() => _len = d) : null),
      p.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _on = s == PlayerState.playing);
      }),
      p.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _pos = Duration.zero);
      }),
    ]);
    return p;
  }

  Future<void> _toggle() async {
    final p = _ensure();
    try {
      if (_on) {
        await p.pause();
        return;
      }
      final other = _playing;
      if (other != null && other != this) await other._player?.pause();
      _playing = this;
      if (p.source == null) {
        setState(() => _loading = true);
        // Le son est d'abord téléchargé (plus fiable que la lecture en
        // direct sur Windows), sinon lu depuis internet.
        final file = await _download(widget.url);
        if (file != null) {
          await p.setSource(DeviceFileSource(file));
        } else {
          await p.setSource(UrlSource(widget.url));
        }
        await p.setPlaybackRate(_rate);
      }
      await p.resume();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Copie locale d'un vocal (gardée le temps de la session).
  static final _cache = <String, String>{};

  static Future<String?> _download(String url) async {
    final known = _cache[url];
    if (known != null && File(known).existsSync()) return known;
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final type = r.headers['content-type'] ?? '';
      final ext = type.contains('ogg') || url.contains('.ogg')
          ? 'ogg'
          : type.contains('mpeg') || url.contains('.mp3')
          ? 'mp3'
          : 'm4a';
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}monhub-vocal-${url.hashCode.abs()}.$ext');
      await f.writeAsBytes(r.bodyBytes);
      return _cache[url] = f.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _speed() async {
    final next = _rate == 1 ? 1.5 : (_rate == 1.5 ? 2.0 : 1.0);
    setState(() => _rate = next);
    try {
      await _player?.setPlaybackRate(next);
    } catch (_) {}
  }

  static String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final fg = widget.onColor;
    final len = _len ?? widget.duration;
    final progress = len == null || len.inMilliseconds == 0
        ? 0.0
        : (_pos.inMilliseconds / len.inMilliseconds).clamp(0.0, 1.0);
    if (_failed) {
      // Dernier recours : le navigateur intégré de Mon Hub lit le son.
      return SizedBox(width: 280, height: 54, child: WebAudio(url: widget.url));
    }
    return SizedBox(
      width: 260,
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: _loading
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: _on ? 'Pause' : 'Écouter le vocal',
                    icon: Icon(
                      _on ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                      color: fg,
                      size: 36,
                    ),
                    onPressed: _toggle,
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) async {
                final box = context.findRenderObject() as RenderBox?;
                if (len == null || box == null || _player?.source == null) return;
                final w = math.max(1.0, box.size.width - 100);
                final f = ((d.localPosition.dx) / w).clamp(0.0, 1.0);
                await _player?.seek(len * f);
              },
              child: SizedBox(
                height: 30,
                child: CustomPaint(
                  painter: _WavePainter(
                    widget.waveform.isEmpty ? _fakeWave(widget.url) : widget.waveform,
                    progress,
                    fg,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _on || _pos > Duration.zero ? _fmt(_pos) : (len == null ? '' : _fmt(len)),
            style: TextStyle(color: fg, fontSize: 11),
          ),
          InkWell(
            onTap: _speed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                '×${_rate == 1 ? '1' : (_rate == 1.5 ? '1,5' : '2')}',
                style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Onde décorative stable quand le service n'en donne pas.
  static List<double> _fakeWave(String seed) {
    final r = math.Random(seed.hashCode);
    return [for (var i = 0; i < 36; i++) 0.25 + r.nextDouble() * 0.75];
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.wave, this.progress, this.color);
  final List<double> wave;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    if (wave.isEmpty) return;
    const bars = 36;
    final step = s.width / bars;
    for (var i = 0; i < bars; i++) {
      final v = wave[(i * wave.length / bars).floor().clamp(0, wave.length - 1)].clamp(0.08, 1.0);
      final h = s.height * v;
      final played = (i + 0.5) / bars <= progress;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * step + step * 0.2, (s.height - h) / 2, step * 0.6, h),
          const Radius.circular(2),
        ),
        Paint()..color = played ? color : color.withValues(alpha: 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress || old.wave != wave;
}

/// Une réaction affichée sous un message (❤️ 2, 😂…).
class Reaction {
  const Reaction(this.emoji, this.who, {this.count, this.mine = false});
  final String emoji;

  /// Noms des personnes qui ont réagi (si connus).
  final List<String> who;

  /// Nombre (si les noms ne sont pas tous connus).
  final int? count;
  final bool mine;

  int get total => count ?? who.length;
}

/// Pastilles de réactions sous une bulle ; toucher une pastille montre qui
/// a réagi.
class ReactionChips extends StatelessWidget {
  const ReactionChips({super.key, required this.reactions, this.onWho, this.alignEnd = false});

  final List<Reaction> reactions;

  /// Demande les noms quand ils ne sont pas déjà connus (Discord).
  final Future<List<String>> Function(Reaction r)? onWho;
  final bool alignEnd;

  Future<void> _show(BuildContext context, Reaction r) async {
    final names = r.who.isNotEmpty || onWho == null ? r.who : await onWho!(r);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: Text(r.emoji, style: const TextStyle(fontSize: 26)),
              title: Text('${r.total} réaction${r.total > 1 ? 's' : ''}'),
            ),
            for (final n in names)
              ListTile(
                leading: HubAvatar(label: n, color: Theme.of(c).colorScheme.primary, size: 32),
                title: Text(n),
              ),
            if (names.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Les noms ne sont pas disponibles.')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4, left: 8, right: 8),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final r in reactions)
              Tooltip(
                message: r.who.isEmpty ? 'Voir qui a réagi' : r.who.join(', '),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _show(context, r),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: r.mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(r.total > 1 ? '${r.emoji} ${r.total}' : r.emoji, style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Un son lu par le navigateur intégré (si le lecteur de Windows refuse le
/// format).
class WebAudio extends StatelessWidget {
  const WebAudio({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final a = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data:
            '<!doctype html><html><body style="margin:0;background:transparent">'
            '<audio src="$a" controls style="width:100%"></audio></body></html>',
      ),
      initialSettings: InAppWebViewSettings(transparentBackground: true, mediaPlaybackRequiresUserGesture: false),
    );
  }
}
