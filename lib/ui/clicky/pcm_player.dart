import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Joue du son brut (PCM 16 bits mono) **au fur et à mesure qu'il arrive**,
/// sans fichier ni attente : c'est ce qui permet à Nexo de répondre « au
/// tac au tac » avec la voix de Gemini Live. Windows (waveOut), sans
/// module à installer.
class PcmPlayer {
  PcmPlayer({this.rate = 24000});

  final int rate;

  static bool get supported => !kIsWeb && Platform.isWindows;

  HWAVEOUT? _hwo;
  final _pending = <Pointer<WAVEHDR>>[];
  Timer? _reaper;

  /// Petit tampon anti-coupures : le son de Gemini arrive par morceaux
  /// irréguliers ; on en garde un peu avant de commencer à jouer.
  late final _jitter = PcmJitter(rate: rate);
  Timer? _hold;

  /// Volume du dernier morceau joué (0..1), pour l'animation.
  double level = 0;

  /// Des morceaux sont encore en train d'être joués (ou attendent).
  bool get playing => _jitter.pending || _devicePlaying;

  bool get _devicePlaying {
    _reap();
    return _pending.isNotEmpty;
  }

  void _open() {
    if (_hwo != null) return;
    final fmt = calloc<WAVEFORMATEX>();
    final out = calloc<Pointer>();
    try {
      fmt.ref
        ..wFormatTag = WAVE_FORMAT_PCM
        ..nChannels = 1
        ..nSamplesPerSec = rate
        ..wBitsPerSample = 16
        ..nBlockAlign = 2
        ..nAvgBytesPerSec = rate * 2
        ..cbSize = 0;
      final r = waveOutOpen(out, 0xFFFFFFFF /* WAVE_MAPPER */, fmt, 0, 0, CALLBACK_NULL);
      if (r != 0) throw 'Haut-parleur indisponible (code $r)';
      _hwo = HWAVEOUT(out.value);
    } finally {
      calloc.free(fmt);
      calloc.free(out);
    }
    _reaper ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _reap());
  }

  /// Ajoute un morceau de son à jouer. Après un silence, il attend d'en avoir
  /// un peu d'avance (≈ 0,2 s) pour ne pas hacher la voix.
  void write(Uint8List pcm) {
    if (!supported || pcm.isEmpty) return;
    final idle = !_devicePlaying;
    for (final (i, b) in _jitter.add(pcm, playing: !idle).indexed) {
      _out(b, fadeIn: idle && i == 0);
    }
    _hold?.cancel();
    if (_jitter.pending) _hold = Timer(PcmJitter.maxWait, flush);
  }

  /// Joue tout de suite ce qui attend (fin d'une réponse).
  void flush() {
    _hold?.cancel();
    final idle = !_devicePlaying;
    for (final (i, b) in _jitter.drain().indexed) {
      _out(b, fadeIn: idle && i == 0);
    }
  }

  void _out(Uint8List pcm, {bool fadeIn = false}) {
    if (pcm.isEmpty) return;
    if (fadeIn) PcmJitter.fadeIn(pcm);
    _open();
    final hwo = _hwo!;
    final data = calloc<Uint8>(pcm.length);
    data.asTypedList(pcm.length).setAll(0, pcm);
    final hdr = calloc<WAVEHDR>();
    hdr.ref
      ..lpData = PSTR(data.cast<Utf8>())
      ..dwBufferLength = pcm.length
      ..dwFlags = 0;
    if (waveOutPrepareHeader(hwo, hdr, sizeOf<WAVEHDR>()) != 0) {
      calloc.free(data);
      calloc.free(hdr);
      return;
    }
    waveOutWrite(hwo, hdr, sizeOf<WAVEHDR>());
    _pending.add(hdr);
    level = rms(pcm);
  }

  /// Libère les morceaux déjà joués.
  void _reap() {
    final hwo = _hwo;
    if (hwo == null) return;
    _pending.removeWhere((h) {
      if (h.ref.dwFlags & 0x00000001 /* WHDR_DONE */ == 0) return false;
      waveOutUnprepareHeader(hwo, h, sizeOf<WAVEHDR>());
      calloc.free(h.ref.lpData);
      calloc.free(h);
      return true;
    });
    if (_pending.isEmpty) level = 0;
  }

  /// Coupe tout de suite (interruption, Échap).
  void stop() {
    _hold?.cancel();
    _jitter.clear();
    final hwo = _hwo;
    if (hwo == null) return;
    waveOutReset(hwo);
    _reap();
  }

  void close() {
    stop();
    _reaper?.cancel();
    _reaper = null;
    final hwo = _hwo;
    _hwo = null;
    if (hwo != null) waveOutClose(hwo);
  }

  /// Du silence (PCM 16 bits) de la même taille qu'un morceau du micro.
  static Uint8List silence(int bytes) => Uint8List(bytes);

  /// Volume (0..1) d'un morceau de PCM 16 bits.
  static double rms(Uint8List pcm) {
    final s = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    if (n == 0) return 0;
    var sum = 0.0;
    final step = math.max(1, n ~/ 400);
    var count = 0;
    for (var i = 0; i < n; i += step) {
      final v = s.getInt16(i * 2, Endian.little) / 32768;
      sum += v * v;
      count++;
    }
    return math.min(1, math.sqrt(sum / count) * 4);
  }
}


/// Le tampon anti-coupures, **sans Windows** (testable) : après un silence,
/// on attend [prebuffer] de son avant de jouer (le morceau suivant a le temps
/// d'arriver, la voix ne hache plus) ; pendant la lecture, tout part tout de
/// suite. Les morceaux gardent un nombre pair d'octets (PCM 16 bits).
class PcmJitter {
  PcmJitter({this.rate = 24000, this.prebuffer = const Duration(milliseconds: 200)});

  final int rate;
  final Duration prebuffer;

  /// Au plus ce temps d'attente : un petit bout de son (fin de phrase) part
  /// quand même.
  static const maxWait = Duration(milliseconds: 160);

  final _buf = BytesBuilder(copy: true);

  bool get pending => _buf.isNotEmpty;

  int get _need => (rate * 2 * prebuffer.inMilliseconds / 1000).round() & ~1;

  /// Ajoute du son ; renvoie ce qu'il faut jouer maintenant. [playing] : le
  /// haut-parleur a encore du son en cours.
  List<Uint8List> add(Uint8List pcm, {required bool playing}) {
    _buf.add(pcm);
    if (!playing && _buf.length < _need) return const [];
    return drain();
  }

  /// Tout ce qui attend (nombre pair d'octets ; l'octet en trop reste).
  List<Uint8List> drain() {
    if (_buf.isEmpty) return const [];
    final all = _buf.takeBytes();
    final even = all.length & ~1;
    if (even < all.length) _buf.add(all.sublist(even));
    return even == 0 ? const [] : [Uint8List.sublistView(all, 0, even)];
  }

  void clear() => _buf.clear();

  /// Montée douce (≈ 5 ms) au début d'un son : pas de « clic ».
  static void fadeIn(Uint8List pcm, {int samples = 120}) {
    final d = ByteData.sublistView(pcm);
    final n = math.min(samples, pcm.length ~/ 2);
    for (var i = 0; i < n; i++) {
      final v = d.getInt16(i * 2, Endian.little);
      d.setInt16(i * 2, (v * i / n).round(), Endian.little);
    }
  }
}
