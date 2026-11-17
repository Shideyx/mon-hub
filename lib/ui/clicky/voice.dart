import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';
import 'live.dart';
import 'neural_voice.dart';
import 'pcm_player.dart';

/// La voix de Clicky : **une seule voix, celle de Gemini** (demande de la
/// personne : une voix naturelle, toujours la même). Lecture par morceaux
/// pendant que la réponse s'écrit (il commence à parler sans attendre la fin).
///
/// Le quota gratuit de la synthèse Gemini est petit (une quinzaine de
/// lectures par jour) : on lit par **gros morceaux**, et quand il est épuisé,
/// c'est Gemini Live (même voix, autre quota) qui lit. Sans clé Gemini ni
/// internet, Clicky répond par écrit.
///
/// Retirées : la voix de Windows (robotique, et flutter_tts plantait) et la
/// voix Microsoft (Edge) — ne pas les remettre.
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
    for (final c in chunks(text)) {
      _enqueue(c);
    }
    await done();
  }

  /// Lecture en direct : on lui donne le texte (propre) au fur et à mesure.
  /// Le premier morceau part dès la première phrase (Clicky parle vite), les
  /// suivants sont gros (chaque morceau coûte une lecture du quota Gemini).
  void feed(String cleanText) {
    if (cleanText.length < _fed) _fed = 0; // texte reparti de zéro
    final rest = cleanText.substring(_fed);
    final first = _fed == 0;
    final end = cutAt(rest, min: first ? 40 : 420, max: first ? 260 : 900);
    if (end == null) return;
    _enqueue(rest.substring(0, end));
    _fed += end;
  }

  /// Fin de la réponse : lit ce qui reste.
  void finish(String cleanText) {
    if (cleanText.length >= _fed) _enqueue(cleanText.substring(_fed));
    _fed = 0;
  }

  /// Où couper un texte en cours d'écriture : à la fin d'une phrase, entre
  /// [min] et [max] lettres (null : pas encore assez de texte).
  static int? cutAt(String text, {required int min, required int max}) {
    int? best;
    for (final m in RegExp(r'[.!?…](?=\s)|\n').allMatches(text)) {
      if (m.end < min) continue;
      if (m.end > max && best != null) break;
      best = m.end;
      if (m.end >= max) break;
    }
    return best;
  }

  /// Découpe un texte complet en gros morceaux (un premier court pour
  /// commencer vite).
  static List<String> chunks(String text, {int first = 260, int size = 900}) {
    final out = <String>[];
    var rest = text.trim();
    while (rest.isNotEmpty) {
      final max = out.isEmpty ? first : size;
      if (rest.length <= max * 1.25) {
        out.add(rest);
        break;
      }
      final end = cutAt(rest, min: (max * 0.4).round(), max: max) ?? (rest.indexOf(' ', max) < 0 ? rest.length : rest.indexOf(' ', max));
      out.add(rest.substring(0, end).trim());
      rest = rest.substring(end).trim();
    }
    return [for (final c in out) if (c.isNotEmpty) c];
  }

  void _enqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _queue.add(t);
    _lastSpoken = _lastSpoken.isEmpty || !_running ? t : '$_lastSpoken $t';
    if (!_running) unawaited(_run(_generation));
  }

  String geminiKey = '';
  String geminiVoice = 'Charon';

  /// Dernier souci de la voix (affiché dans les réglages).
  String? neuralError;

  AudioPlayer? _player;

  /// La synthèse Gemini a échoué (quota du jour épuisé…) : Gemini Live lit
  /// à sa place jusque-là.
  DateTime? _ttsDownUntil;

  /// Plus aucune voix (ni synthèse ni Live) : réponse écrite jusque-là.
  DateTime? _allDownUntil;

  bool get hasVoice => geminiKey.trim().isNotEmpty;

  bool _down(DateTime? until) => until != null && DateTime.now().isBefore(until);

  /// Lecture par Gemini Live (même voix), quand la synthèse est épuisée.
  final _reader = LiveReader();

  /// Synthèse Gemini (l'échec remonte).
  Future<Uint8List> synth(String text) => GeminiVoice.synthesize(text, key: geminiKey, voice: geminiVoice);

  static bool _quota(Object e) => RegExp(r'429|quota|RESOURCE_EXHAUSTED', caseSensitive: false).hasMatch('$e');

  int _file = 0;

  /// Durée d'un WAV (d'après son en-tête), pour savoir quand il finit.
  static Duration? wavDuration(Uint8List b) {
    if (b.length < 44 || b[0] != 0x52 || b[1] != 0x49) return null;
    final d = ByteData.sublistView(b);
    final byteRate = d.getUint32(28, Endian.little);
    if (byteRate == 0) return null;
    return Duration(microseconds: ((b.length - 44) * 1000000 / byteRate).round());
  }

  /// Durée approximative d'un MP3 (48 kbit/s), d'après sa taille.
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
      if (!hasVoice) {
        neuralError = 'Ajoute ta clé Gemini gratuite pour que Clicky parle (sinon il répond par écrit).';
        return;
      }
      if (_down(_allDownUntil)) return;
      Future<Uint8List>? next;
      while (_queue.isNotEmpty && gen == _generation) {
        final s = _queue.removeAt(0);
        // Quota de la synthèse épuisé : Gemini Live lit (même voix).
        if (_down(_ttsDownUntil)) {
          next = null;
          if (!await _readLive(s, gen)) break;
          continue;
        }
        try {
          final audio = await (next ?? synth(s));
          next = null;
          if (gen != _generation) break;
          // On prépare le morceau suivant pendant la lecture.
          if (_queue.isNotEmpty) {
            final n = synth(_queue.first);
            n.then((_) {}, onError: (Object _) {});
            next = n;
          }
          await _play(audio, gen);
          neuralError = null;
        } catch (e) {
          next = null;
          try {
            await _player?.stop();
          } catch (_) {}
          if (gen != _generation) break;
          _ttsDownUntil = DateTime.now().add(_quota(e) ? const Duration(hours: 2) : const Duration(minutes: 5));
          if (!await _readLive(s, gen)) {
            neuralError = '$e';
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

  /// Lit un morceau avec Gemini Live. Faux si ça n'a pas marché (plus de
  /// voix pour un moment : Clicky répond par écrit).
  Future<bool> _readLive(String text, int gen) async {
    try {
      await _reader.read(text, key: geminiKey, voice: geminiVoice, cancelled: () => gen != _generation);
      neuralError = null;
      return true;
    } catch (e) {
      neuralError = 'Plus de voix Gemini pour le moment ($e) : Clicky répond par écrit.';
      _allDownUntil = DateTime.now().add(const Duration(minutes: 15));
      return false;
    }
  }

  /// Essaie la voix choisie (bouton « Écouter » des réglages).
  Future<String?> test(String text) async {
    _ttsDownUntil = null;
    _allDownUntil = null;
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
    _reader.stop();
  }

  /// Réinitialise la lecture en direct (nouvelle réponse).
  void resetLive() => _fed = 0;
}

/// Gemini Live comme lecteur : on lui envoie un texte, il le lit avec la
/// même voix Gemini (son propre quota, bien plus large que la synthèse).
class LiveReader {
  GeminiLive? _s;
  String _voice = '';
  final _player = PcmPlayer();
  Completer<void>? _turn;
  Timer? _idle;

  static const system =
      'Tu es une voix de lecture. On t\'envoie un texte : lis-le à voix haute en français, mot pour mot, '
      'd\'une voix posée et naturelle. N\'ajoute rien, ne commente pas, ne réponds pas aux questions du texte.';

  Future<void> read(String text, {required String key, required String voice, required bool Function() cancelled}) async {
    if (!PcmPlayer.supported) throw 'lecture en direct impossible ici';
    _idle?.cancel();
    var s = _s;
    if (s == null || !s.connected || _voice != voice) {
      await s?.close();
      s = _s = GeminiLive(key: key, system: system, tools: const [], voice: voice)
        ..onAudio = _player.write
        ..onTurnComplete = (() => _turn?.complete())
        ..onClosed = ((_) {
          _s = null;
          if (!(_turn?.isCompleted ?? true)) _turn?.complete();
        });
      _voice = voice;
      await s.connect();
    }
    final turn = _turn = Completer<void>();
    s.sendText(text);
    await turn.future.timeout(Duration(seconds: 30 + text.length ~/ 8), onTimeout: () {});
    // Le son arrive plus vite qu'il ne se lit : on attend la fin.
    for (var i = 0; i < 3000 && _player.playing && !cancelled(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (cancelled()) _player.stop();
    // La connexion se ferme après une minute sans rien à lire.
    _idle = Timer(const Duration(minutes: 1), () {
      unawaited(_s?.close());
      _s = null;
    });
  }

  void stop() {
    _player.stop();
    if (!(_turn?.isCompleted ?? true)) _turn?.complete();
  }
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
