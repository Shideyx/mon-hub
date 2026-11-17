import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';
import 'neural_voice.dart';

/// La voix de Clicky : voix neurales (Microsoft, gratuite et sans limite ;
/// ou Gemini avec ta clé), vitesse et hauteur réglables, et lecture **phrase
/// par phrase pendant que la réponse s'écrit** (il commence à parler sans
/// attendre la fin).
///
/// La voix de Windows a été retirée : elle sonnait robotique, et son module
/// (flutter_tts) faisait planter le programme sous Windows. Sans internet,
/// Clicky répond par écrit.
class ClickyVoice {
  int _generation = 0;
  final _queue = <String>[];
  bool _running = false;
  Completer<void>? _drained;

  /// Ce qui a déjà été mis dans la file (pour la lecture en direct).
  int _fed = 0;
  String _lastSpoken = '';

  /// Réglages appliqués avant chaque phrase.
  String language = 'fr-FR';
  double rate = 1;
  double pitch = 1;

  /// Dernier texte lu (pour « répète »).
  String get lastSpoken => _lastSpoken;

  bool get speaking => _running;

  /// Lit tout un texte (et attend la fin).
  Future<void> say(String text) async {
    stop();
    _enqueue(text);
    await done();
  }

  /// Lecture en direct : on lui donne le texte (propre) au fur et à mesure,
  /// il lit chaque phrase dès qu'elle est terminée.
  void feed(String cleanText) {
    if (cleanText.length < _fed) _fed = 0; // texte reparti de zéro
    final rest = cleanText.substring(_fed);
    // On lit par morceaux d'au moins une phrase complète (et 24 lettres,
    // pour éviter les micro-coupures). Le tout premier morceau part dès la
    // première virgule : Clicky commence à parler plus tôt.
    final first = _fed == 0;
    final cut = first ? RegExp(r'[\s\S]*?[.!?…:;,](?=\s)') : RegExp(r'[\s\S]*?[.!?…:;](?=\s)');
    final min = first ? 14 : 24;
    var end = 0;
    for (final s in cut.allMatches(rest)) {
      end = s.end;
      if (end >= min) break;
    }
    if (end < min) return;
    _enqueue(rest.substring(0, end));
    _fed += end;
  }

  /// Fin de la réponse : lit ce qui reste.
  void finish(String cleanText) {
    if (cleanText.length >= _fed) _enqueue(cleanText.substring(_fed));
    _fed = 0;
  }

  void _enqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _queue.add(t);
    _lastSpoken = _lastSpoken.isEmpty || !_running ? t : '$_lastSpoken $t';
    if (!_running) unawaited(_run(_generation));
  }

  /// Moteur : 'edge' (voix neurale Microsoft, gratuite, sans limite) ou
  /// 'gemini' (clé gratuite).
  String engine = 'edge';
  String neuralVoice = 'fr-FR-RemyMultilingualNeural';
  String geminiKey = '';
  String geminiVoice = 'Charon';

  /// Dernier souci de la voix (affiché dans les réglages).
  String? neuralError;

  AudioPlayer? _player;

  /// Gemini a échoué (quota gratuit épuisé…) : voix Microsoft un moment.
  DateTime? _geminiDownUntil;

  bool get _geminiOk =>
      geminiKey.trim().isNotEmpty && (_geminiDownUntil == null || DateTime.now().isAfter(_geminiDownUntil!));

  /// La voix d'une réponse, choisie une fois pour toute la réponse : jamais
  /// deux voix différentes en même temps.
  String _pickEngine() => engine == 'gemini' && _geminiOk ? 'gemini' : 'edge';

  Future<Uint8List> _synthWith(String eng, String text) => eng == 'gemini'
      ? GeminiVoice.synthesize(text, key: geminiKey, voice: geminiVoice)
      : EdgeVoice.synthesize(
          text,
          voice: EdgeVoice.forLanguage(language, neuralVoice),
          rate: rate,
          pitch: pitch,
        );

  /// Synthèse avec la voix choisie (sans mélanger : l'échec remonte).
  Future<Uint8List> synth(String text) => _synthWith(_pickEngine(), text);

  int _file = 0;

  /// Durée d'un WAV (d'après son en-tête), pour savoir quand il finit.
  static Duration? wavDuration(Uint8List b) {
    if (b.length < 44 || b[0] != 0x52 || b[1] != 0x49) return null;
    final d = ByteData.sublistView(b);
    final byteRate = d.getUint32(28, Endian.little);
    if (byteRate == 0) return null;
    return Duration(microseconds: ((b.length - 44) * 1000000 / byteRate).round());
  }

  /// Durée d'un MP3 de la voix Microsoft (48 kbit/s), d'après sa taille.
  static Duration mp3Duration(Uint8List b) => Duration(milliseconds: (b.length * 8 / 48).round());

  /// Joue un son (MP3 ou WAV) et attend **vraiment** la fin (l'évènement
  /// « terminé » de Windows arrive parfois trop tôt ou jamais : on se fie
  /// aussi à la durée du son).
  Future<void> _play(Uint8List bytes, int gen) async {
    final p = _player ??= AudioPlayer();
    final wav = bytes.length > 4 && bytes[0] == 0x52;
    final f = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}monhub-voix-${_file++ % 4}.${wav ? 'wav' : 'mp3'}',
    );
    await f.writeAsBytes(bytes, flush: true);
    if (gen != _generation) return;
    var finished = false;
    final sub = p.onPlayerComplete.listen((_) => finished = true);
    final started = DateTime.now();
    try {
      await p.play(DeviceFileSource(f.path));
      // WAV : durée exacte ; MP3 de la voix Microsoft : 48 kbit/s.
      final dur = wavDuration(bytes) ?? mp3Duration(bytes);
      final max = dur + const Duration(milliseconds: 1500);
      final min = dur;
      while (gen == _generation) {
        final elapsed = DateTime.now().difference(started);
        if (elapsed >= max) break;
        if (finished && elapsed >= min - const Duration(milliseconds: 250)) break;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _run(int gen) async {
    _running = true;
    await VoiceLock.acquire();
    try {
      var eng = _pickEngine();
      Future<Uint8List>? next;
      while (_queue.isNotEmpty && gen == _generation) {
        final s = _queue.removeAt(0);
        try {
          final audio = await (next ?? _synthWith(eng, s));
          next = null;
          if (gen != _generation) break;
          // On prépare la phrase suivante (même voix) pendant la lecture.
          if (_queue.isNotEmpty) {
            final n = _synthWith(eng, _queue.first);
            n.then((_) {}, onError: (Object _) {});
            next = n;
          }
          await _play(audio, gen);
          neuralError = null;
        } catch (e) {
          neuralError = '$e';
          next = null;
          try {
            await _player?.stop();
          } catch (_) {}
          if (gen != _generation) break;
          // L'autre voix lit la suite de la réponse (on ne revient pas en
          // arrière au milieu) ; sans aucune voix, Clicky répond par écrit.
          if (eng == 'gemini') {
            // Quota gratuit épuisé : voix Microsoft (sans limite) une heure.
            _geminiDownUntil = DateTime.now().add(
              RegExp(r'429|quota|RESOURCE_EXHAUSTED', caseSensitive: false).hasMatch('$e')
                  ? const Duration(hours: 1)
                  : const Duration(minutes: 10),
            );
            eng = 'edge';
          } else if (_geminiOk) {
            eng = 'gemini';
          } else {
            break;
          }
          try {
            await _play(await _synthWith(eng, s), gen);
          } catch (_) {
            break;
          }
        }
      }
    } catch (_) {
    } finally {
      VoiceLock.release();
      if (gen == _generation) {
        _queue.clear();
        _running = false;
        _drained?.complete();
        _drained = null;
      }
    }
  }

  /// Essaie la voix choisie (bouton « Écouter » des réglages).
  Future<String?> test(String text) async {
    _geminiDownUntil = null;
    neuralError = null;
    await say(text);
    return neuralError;
  }

  /// Attend que tout soit lu.
  Future<void> done() {
    if (!_running && _queue.isEmpty) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  /// Se tait tout de suite.
  void stop() {
    _generation++;
    _queue.clear();
    _fed = 0;
    _running = false;
    final d = _drained;
    _drained = null;
    d?.complete();
    try {
      unawaited(_player?.stop());
    } catch (_) {}
  }

  /// Réinitialise la lecture en direct (nouvelle réponse).
  void resetLive() => _fed = 0;
}

/// Petit son « bip-bip » de Clicky (généré, aucun fichier).
class ClickyChime {
  ClickyChime._();
  static AudioPlayer? _p;
  static String? _path;

  static Uint8List wav({double volume = 0.25}) {
    const rate = 22050;
    final tones = [(880.0, 0.07), (0.0, 0.03), (1320.0, 0.09)];
    final samples = <int>[];
    for (final (f, d) in tones) {
      final n = (rate * d).round();
      for (var i = 0; i < n; i++) {
        final env = math.min(1.0, math.min(i, n - i) / (rate * 0.01));
        final v = f == 0 ? 0.0 : math.sin(2 * math.pi * f * i / rate) * env * volume;
        samples.add((v * 32767).round());
      }
    }
    final data = ByteData(44 + samples.length * 2);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  static Future<void> play() async {
    if (kIsWeb) return;
    try {
      final path = _path ??= () {
        final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}monhub-clicky.wav');
        f.writeAsBytesSync(wav());
        return f.path;
      }();
      final p = _p ??= AudioPlayer();
      await p.stop();
      await p.play(DeviceFileSource(path));
    } catch (_) {}
  }
}


/// Une seule voix à la fois sur le PC, même quand Mon Hub et « Clicky
/// partout » parlent en même temps : celui qui parle tient un petit verrou
/// (fichier voix.lock), l'autre attend son tour.
class VoiceLock {
  VoiceLock._();

  static Timer? _beat;
  static int _depth = 0;

  static File? get _file {
    final d = ClaudeBridge.folder;
    return d == null || kIsWeb ? null : File('$d${Platform.pathSeparator}voix.lock');
  }

  static bool _heldByOther(File f) {
    try {
      if (!f.existsSync()) return false;
      final parts = f.readAsStringSync().split(' ');
      final owner = int.tryParse(parts.first);
      final at = int.tryParse(parts.length > 1 ? parts[1] : '');
      if (owner == null || at == null || owner == pid) return false;
      // Verrou abandonné (programme fermé) au bout de 3 s sans nouvelles.
      return DateTime.now().millisecondsSinceEpoch - at < 3000;
    } catch (_) {
      return false;
    }
  }

  static void _write(File f) {
    try {
      f.writeAsStringSync('$pid ${DateTime.now().millisecondsSinceEpoch}', flush: true);
    } catch (_) {}
  }

  /// Attend que l'autre programme ait fini de parler (40 s au plus).
  static Future<void> acquire() async {
    _depth++;
    final f = _file;
    if (f == null) return;
    final until = DateTime.now().add(const Duration(seconds: 40));
    while (_heldByOther(f) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _write(f);
    _beat ??= Timer.periodic(const Duration(milliseconds: 900), (_) => _write(f));
  }

  static void release() {
    if (_depth > 0) _depth--;
    if (_depth > 0) return;
    _beat?.cancel();
    _beat = null;
    final f = _file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.readAsStringSync().startsWith('$pid ')) f.deleteSync();
    } catch (_) {}
  }
}
