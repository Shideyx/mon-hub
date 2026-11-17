import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Joue du son brut (PCM 16 bits mono) **au fur et à mesure qu'il arrive**,
/// sans fichier ni attente : c'est ce qui permet à Clicky de répondre « au
/// tac au tac » avec la voix de Gemini Live. Windows (waveOut), sans
/// module à installer.
class PcmPlayer {
  PcmPlayer({this.rate = 24000});

  final int rate;

  static bool get supported => !kIsWeb && Platform.isWindows;

  HWAVEOUT? _hwo;
  final _pending = <Pointer<WAVEHDR>>[];
  Timer? _reaper;

  /// Volume du dernier morceau joué (0..1), pour l'animation.
  double level = 0;

  /// Des morceaux sont encore en train d'être joués.
  bool get playing {
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

  /// Ajoute un morceau de son à jouer (il démarre tout de suite si rien ne
  /// joue).
  void write(Uint8List pcm) {
    if (!supported || pcm.isEmpty) return;
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
