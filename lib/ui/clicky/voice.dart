import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Une voix du système (Windows : Paul, Hortense, Julie…).
class SystemVoice {
  const SystemVoice(this.name, this.locale);
  final String name;
  final String locale;

  /// Voix d'homme (pour Jarvis), d'après le nom.
  bool get male => RegExp(
    r'paul|claude|henri|remy|rémy|guy|david|mark|george|ryan|thomas|daniel|james|male',
    caseSensitive: false,
  ).hasMatch(name);
}

/// La voix de Clicky : voix de Windows (hors ligne), choix de la voix, de la
/// vitesse et de la hauteur, et lecture **phrase par phrase pendant que la
/// réponse s'écrit** (il commence à parler sans attendre la fin).
class ClickyVoice {
  FlutterTts? _tts;
  int _generation = 0;
  final _queue = <String>[];
  bool _running = false;
  Completer<void>? _drained;

  /// Ce qui a déjà été mis dans la file (pour la lecture en direct).
  int _fed = 0;
  String _lastSpoken = '';

  /// Réglages appliqués avant chaque phrase.
  String voiceName = '';
  String language = 'fr-FR';
  double rate = 1;
  double pitch = 1;

  /// Dernier texte lu (pour « répète »).
  String get lastSpoken => _lastSpoken;

  bool get speaking => _running;

  FlutterTts get _engine => _tts ??= FlutterTts();

  static List<SystemVoice>? _voices;

  /// Voix installées sur l'appareil.
  Future<List<SystemVoice>> voices() async {
    final cached = _voices;
    if (cached != null) return cached;
    try {
      final raw = await _engine.getVoices;
      final out = <SystemVoice>[
        for (final v in (raw as List? ?? const []))
          if (v is Map) SystemVoice('${v['name'] ?? ''}', '${v['locale'] ?? ''}'),
      ]..removeWhere((v) => v.name.isEmpty);
      out.sort((a, b) => '${a.locale}${a.name}'.compareTo('${b.locale}${b.name}'));
      return _voices = out;
    } catch (_) {
      return const [];
    }
  }

  /// La voix à utiliser pour [lang] : celle choisie si elle parle cette
  /// langue, sinon une voix de cette langue (d'homme si [preferMale]).
  Future<SystemVoice?> pick(String lang, {bool preferMale = false}) async {
    final all = await voices();
    final prefix = lang.split('-').first.toLowerCase();
    bool speaks(SystemVoice v) => v.locale.toLowerCase().replaceAll('_', '-').startsWith(prefix);
    final chosen = all.where((v) => v.name == voiceName).firstOrNull;
    if (chosen != null && speaks(chosen)) return chosen;
    final same = all.where(speaks).toList();
    if (same.isEmpty) return null;
    if (preferMale) return same.where((v) => v.male).firstOrNull ?? same.first;
    return same.first;
  }

  bool preferMale = false;

  Future<void> _apply() async {
    final t = _engine;
    await t.setLanguage(language);
    final v = await pick(language, preferMale: preferMale);
    if (v != null) {
      try {
        await t.setVoice({'name': v.name, 'locale': v.locale});
      } catch (_) {}
    }
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    await t.setSpeechRate(((mobile ? 0.5 : 0.55) * rate).clamp(0.1, 1.0));
    try {
      await t.setPitch(pitch.clamp(0.5, 2.0));
    } catch (_) {}
    await t.awaitSpeakCompletion(true);
  }

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
    // pour éviter les micro-coupures).
    var end = 0;
    for (final s in RegExp(r'[\s\S]*?[.!?…:;](?=\s)').allMatches(rest)) {
      end = s.end;
      if (end >= 24) break;
    }
    if (end < 24) return;
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

  Future<void> _run(int gen) async {
    _running = true;
    try {
      await _apply();
      while (_queue.isNotEmpty && gen == _generation) {
        final s = _queue.removeAt(0);
        try {
          await _engine.speak(s);
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      if (gen == _generation) {
        _running = false;
        _drained?.complete();
        _drained = null;
      }
    }
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
      unawaited(_tts?.stop());
    } catch (_) {}
  }

  /// Réinitialise la lecture en direct (nouvelle réponse).
  void resetLive() => _fed = 0;
}

/// Petit son « bip-bip » de Jarvis (généré, aucun fichier).
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
        final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}monhub-jarvis.wav');
        f.writeAsBytesSync(wav());
        return f.path;
      }();
      final p = _p ??= AudioPlayer();
      await p.stop();
      await p.play(DeviceFileSource(path));
    } catch (_) {}
  }
}
