import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:win32/win32.dart';

/// Change la cadence d'un son (ex. 48 000 → 16 000 échantillons par
/// seconde), morceau par morceau, sans couture entre les morceaux
/// (interpolation linéaire).
class Resampler {
  Resampler(this.from, this.to);
  final int from;
  final int to;

  /// Position du prochain échantillon à produire, dans le morceau en cours
  /// (entre -1 et 0 : entre le dernier du morceau d'avant et le premier).
  double _pos = 0;
  double _last = 0;

  /// [mono] : échantillons entre -1 et 1. Renvoie du PCM 16 bits (little endian).
  Uint8List push(Float32List mono) {
    final n = mono.length;
    if (n == 0) return Uint8List(0);
    final step = from / to;
    double at(int i) => i < 0 ? _last : mono[i];
    final out = Int16List(((n + 1) / step).ceil() + 2);
    var k = 0;
    while (_pos < n - 1) {
      final i = _pos.floor();
      final frac = _pos - i;
      final v = (at(i) + (at(i + 1) - at(i)) * frac).clamp(-1.0, 1.0);
      out[k++] = (v * 32767).round();
      _pos += step;
    }
    _pos -= n;
    _last = mono[n - 1];
    return out.buffer.asUint8List(0, k * 2);
  }
}

/// **Le son qui sort du PC** (vidéos, séries, jeux, appels…), capté par
/// Windows (WASAPI « en boucle ») : rien n'est enregistré sur le disque,
/// on reçoit du PCM 16 kHz mono au fur et à mesure.
class LoopbackCapture {
  LoopbackCapture._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Démarre la capture. Le flux s'arrête quand on annule l'abonnement.
  static Stream<Uint8List> start() {
    late StreamController<Uint8List> ctrl;
    Isolate? iso;
    SendPort? toIso;
    final fromIso = ReceivePort();
    ctrl = StreamController<Uint8List>(
      onListen: () async {
        fromIso.listen((m) {
          if (m is SendPort) {
            toIso = m;
          } else if (m is TransferableTypedData) {
            ctrl.add(m.materialize().asUint8List());
          } else if (m is String) {
            ctrl.addError(m);
          }
        });
        iso = await Isolate.spawn(_run, fromIso.sendPort);
      },
      onCancel: () async {
        toIso?.send('stop');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        iso?.kill(priority: Isolate.beforeNextEvent);
        fromIso.close();
      },
    );
    return ctrl.stream;
  }

  static const _loopback = 0x00020000; // AUDCLNT_STREAMFLAGS_LOOPBACK
  static const _silent = 0x2; // AUDCLNT_BUFFERFLAGS_SILENT

  static Future<void> _run(SendPort out) async {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    var stop = false;
    inbox.listen((m) {
      if (m == 'stop') stop = true;
    });
    CoInitializeEx(COINIT_MULTITHREADED);
    IAudioClient? client;
    Pointer<WAVEFORMATEX>? fmt;
    final ppData = calloc<Pointer<Uint8>>();
    final pFrames = calloc<Uint32>();
    final pFlags = calloc<Uint32>();
    try {
      final en = createInstance<IMMDeviceEnumerator>(MMDeviceEnumerator);
      final dev = en.getDefaultAudioEndpoint(eRender, eConsole);
      if (dev == null) throw 'Aucune sortie son trouvée';
      client = dev.activate<IAudioClient>(CLSCTX_ALL, null);
      fmt = client.getMixFormat();
      final ch = fmt.ref.nChannels;
      final rate = fmt.ref.nSamplesPerSec;
      final bits = fmt.ref.wBitsPerSample;
      final tag = fmt.ref.wFormatTag;
      final isFloat = tag == 3 || (tag == 0xFFFE && bits == 32);
      client.initialize(AUDCLNT_SHAREMODE_SHARED, _loopback, 10000000, 0, fmt, null);
      final cap = client.getService<IAudioCaptureClient>();
      client.start();
      final rs = Resampler(rate, 16000);
      while (!stop) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final pcm = BytesBuilder(copy: false);
        var packet = cap.getNextPacketSize();
        while (packet > 0) {
          cap.getBuffer(ppData, pFrames, pFlags, null, null);
          final frames = pFrames.value;
          final mono = Float32List(frames);
          if ((pFlags.value & _silent) == 0 && frames > 0) {
            if (isFloat) {
              final f = ppData.value.cast<Float>().asTypedList(frames * ch);
              for (var i = 0; i < frames; i++) {
                var s = 0.0;
                for (var c = 0; c < ch; c++) {
                  s += f[i * ch + c];
                }
                mono[i] = s / ch;
              }
            } else if (bits == 16) {
              final f = ppData.value.cast<Int16>().asTypedList(frames * ch);
              for (var i = 0; i < frames; i++) {
                var s = 0;
                for (var c = 0; c < ch; c++) {
                  s += f[i * ch + c];
                }
                mono[i] = s / ch / 32768;
              }
            }
          }
          cap.releaseBuffer(frames);
          pcm.add(rs.push(mono));
          packet = cap.getNextPacketSize();
        }
        if (pcm.isNotEmpty) out.send(TransferableTypedData.fromList([pcm.takeBytes()]));
      }
    } catch (e) {
      out.send('Le son du PC ne peut pas être capté ($e)');
    } finally {
      try {
        client?.stop();
      } catch (_) {}
      if (fmt != null) CoTaskMemFree(fmt.cast());
      calloc
        ..free(ppData)
        ..free(pFrames)
        ..free(pFlags);
      CoUninitialize();
      inbox.close();
    }
  }
}
