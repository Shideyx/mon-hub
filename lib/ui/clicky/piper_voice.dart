import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';
import '../../core/module_store.dart';
import 'whisper.dart';

/// Une voix Piper (française).
@immutable
class PiperVoiceInfo {
  const PiperVoiceInfo(
    this.id,
    this.name,
    this.about,
    this.path, {
    this.speaker,
    this.githubTar,
    this.githubSha256,
    this.tarName,
  });
  final String id;
  final String name;
  final String about;

  /// Chemin dans le dépôt des voix Piper (sans « .onnx »).
  final String path;

  /// Voix à plusieurs locuteurs : lequel.
  final int? speaker;

  /// Copie de secours sur GitHub (archive .tar.gz, empreinte vérifiée), si
  /// Hugging Face ne répond pas ; [tarName] = nom des fichiers dedans.
  final String? githubTar;
  final String? githubSha256;
  final String? tarName;

  String get file => path.split('/').last;
}

/// **La voix de Nexo sur le PC, sans Gemini** : Piper, une voix neuronale
/// libre (projet open source), qui tourne entièrement sur l'ordinateur —
/// gratuite, illimitée, sans internet, toujours le même son, et rapide
/// (une phrase en une fraction de seconde sur un PC normal).
///
/// Installation (une fois, ≈ 85 Mo) dans %APPDATA%\MonHub\piper : le
/// programme (GitHub, **empreinte SHA-256 vérifiée**) et une voix française
/// (Hugging Face, dépôt officiel des voix Piper). Le programme reste ouvert
/// entre deux phrases (la voix est chargée une seule fois).
class PiperVoice {
  PiperVoice._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  static const zipUrl = 'https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip';

  /// Empreinte du programme : un fichier modifié est refusé.
  static const zipSha256 = 'f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea';

  static const voices = [
    PiperVoiceInfo('tom', 'Tom', 'homme, posé (conseillée pour Nexo)', 'fr/fr_FR/tom/medium/fr_FR-tom-medium'),
    PiperVoiceInfo(
      'siwis',
      'Siwis',
      'femme, claire',
      'fr/fr_FR/siwis/medium/fr_FR-siwis-medium',
      githubTar: 'https://github.com/rhasspy/piper/releases/download/v0.0.2/voice-fr-siwis-medium.tar.gz',
      githubSha256: '0c9ecdf9ecac6de4a46be85a162bffe0db7145bd3a4175831cea6cab4b41eefd',
      tarName: 'fr-siwis-medium',
    ),
    PiperVoiceInfo('pierre', 'Pierre', 'homme, plus grave', 'fr/fr_FR/upmc/medium/fr_FR-upmc-medium', speaker: 1),
  ];

  static PiperVoiceInfo voiceOf(String id) => voices.where((v) => v.id == id).firstOrNull ?? voices.first;

  static String modelUrl(PiperVoiceInfo v, {bool json = false}) =>
      'https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/${v.path}.onnx${json ? '.json' : ''}?download=true';

  /// La voix choisie (préférence du compte).
  static String get chosen {
    try {
      return ModuleStore.prefs.getString('clicky.piper.voix') ?? 'tom';
    } catch (_) {
      return 'tom';
    }
  }

  static Future<void> choose(String id) async {
    try {
      await ModuleStore.prefs.setString('clicky.piper.voix', voiceOf(id).id);
    } catch (_) {}
    await instance._stop();
  }

  static String? get folder {
    final base = ClaudeBridge.folder;
    return base == null ? null : '$base${Platform.pathSeparator}piper';
  }

  static String? exePath() {
    final f = folder;
    if (f == null) return null;
    final p = '$f${Platform.pathSeparator}bin${Platform.pathSeparator}piper${Platform.pathSeparator}piper.exe';
    return File(p).existsSync() ? p : null;
  }

  static String? modelPath(PiperVoiceInfo v) {
    final f = folder;
    return f == null ? null : '$f${Platform.pathSeparator}${v.file}.onnx';
  }

  /// Prête à parler (programme + voix choisie installés).
  static bool get ready {
    if (!supported) return false;
    try {
      final m = modelPath(voiceOf(chosen));
      return exePath() != null &&
          m != null &&
          File(m).existsSync() &&
          File(m).lengthSync() > 5 * 1024 * 1024 &&
          File('$m.json').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// La vitesse (1 = normale ; plus petit = plus rapide).
  static double lengthScale(double rate) => (1 / rate.clamp(0.6, 1.8)).clamp(0.55, 1.6);

  /// Le texte en une ligne JSON **en ASCII** (accents en \uXXXX) : rien ne
  /// dépend de la page de code de Windows.
  static String jsonLine(String text, {int? speaker}) {
    final b = StringBuffer('{"text":"');
    for (final r in text.replaceAll(RegExp(r'[\r\n]+'), ' ').runes) {
      if (r == 0x22) {
        b.write(r'\"');
      } else if (r == 0x5C) {
        b.write(r'\\');
      } else if (r < 0x20) {
        b.write(' ');
      } else if (r < 0x7F) {
        b.writeCharCode(r);
      } else if (r > 0xFFFF) {
        final v = r - 0x10000;
        b.write('\\u${(0xD800 + (v >> 10)).toRadixString(16).padLeft(4, '0')}');
        b.write('\\u${(0xDC00 + (v & 0x3FF)).toRadixString(16).padLeft(4, '0')}');
      } else {
        b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
      }
    }
    b.write('"');
    if (speaker != null) b.write(',"speaker_id":$speaker');
    b.write('}');
    return '$b';
  }

  /// Nettoie le texte lu (émojis, symboles, Markdown) : Piper lirait les
  /// noms des symboles.
  static String speakable(String s) => s
      .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]', unicode: true), '')
      .replaceAll(RegExp(r'[*_#`>|~]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Le fichier téléchargé correspond-il à l'empreinte attendue ?
  static Future<bool> sha256Matches(File f, String expected) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString() == expected;
  }

  // ------------------------------------------------------------ Installation

  static Future<void>? _installing;

  /// Installe le programme et la voix choisie (ce qui manque seulement).
  static Future<void> install({String? voice, void Function(String step, double progress)? onProgress}) =>
      _installing ??= _install(voice ?? chosen, onProgress).whenComplete(() => _installing = null);

  static bool get installing => _installing != null;

  static Future<void> _install(String voiceId, void Function(String, double)? onProgress) async {
    if (!supported) throw 'La voix du PC marche sous Windows.';
    final f = folder;
    if (f == null) throw 'Dossier de Mon Hub introuvable';
    final sep = Platform.pathSeparator;
    await Directory(f).create(recursive: true);
    final log = <String>[];
    try {
      if (exePath() == null) {
        final zip = await Whisper.download(
          zipUrl,
          '$f${sep}piper.zip',
          (p) => onProgress?.call('Programme de la voix (22 Mo)', p),
          log,
          minBytes: 10 * 1024 * 1024,
        );
        if (!await sha256Matches(zip, zipSha256)) {
          await zip.delete();
          throw 'le programme téléchargé ne correspond pas à l\'original (refusé par sécurité)';
        }
        onProgress?.call('Installation', 1);
        await Whisper.unzip(zip, Directory('$f${sep}bin'), log);
        try {
          await zip.delete();
        } catch (_) {}
        if (exePath() == null) throw 'piper.exe absent du fichier';
      }
      var v = voiceOf(voiceId);
      try {
        await _installVoice(v, onProgress, log);
      } catch (e) {
        // Hugging Face ne répond pas (proxy, antivirus…) : la voix de secours
        // hébergée sur GitHub (empreinte vérifiée), pour que Nexo parle quand même.
        final backup = voices.firstWhere((x) => x.githubTar != null);
        log.add('Voix ${v.name} : $e → secours ${backup.name} (GitHub)');
        await _installFromGitHub(backup, onProgress, log);
        v = backup;
        try {
          await ModuleStore.prefs.setString('clicky.piper.voix', backup.id);
        } catch (_) {}
      }
      await _checkConfig(v);
    } catch (e) {
      log.add('Échec : $e');
      rethrow;
    } finally {
      try {
        await File('$f${sep}installation.log')
            .writeAsString('${DateTime.now()}\n${log.join('\n')}\n\n', mode: FileMode.append);
      } catch (_) {}
    }
  }

  static bool _modelOk(PiperVoiceInfo v) {
    final m = modelPath(v)!;
    return File(m).existsSync() && File(m).lengthSync() >= 5 * 1024 * 1024 && File('$m.json').existsSync();
  }

  static Future<void> _installVoice(
    PiperVoiceInfo v,
    void Function(String, double)? onProgress,
    List<String> log,
  ) async {
    if (_modelOk(v)) return;
    final m = modelPath(v)!;
    await Whisper.download(
      modelUrl(v),
      m,
      (p) => onProgress?.call('Voix ${v.name} (≈ 60 Mo)', p),
      log,
      minBytes: 5 * 1024 * 1024,
    );
    await Whisper.download(modelUrl(v, json: true), '$m.json', (_) {}, log, minBytes: 500);
  }

  /// La voix depuis l'archive de secours (GitHub), après vérification.
  static Future<void> _installFromGitHub(
    PiperVoiceInfo v,
    void Function(String, double)? onProgress,
    List<String> log,
  ) async {
    if (_modelOk(v)) return;
    final m = modelPath(v)!;
    final tar = await Whisper.download(
      v.githubTar!,
      '$m.tar.gz',
      (p) => onProgress?.call('Voix ${v.name} (≈ 58 Mo)', p),
      log,
      minBytes: 5 * 1024 * 1024,
    );
    try {
      if (!await sha256Matches(tar, v.githubSha256!)) {
        throw 'la voix téléchargée ne correspond pas à l\'original (refusée par sécurité)';
      }
      final files = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(await tar.readAsBytes()));
      for (final f in files) {
        if (!f.isFile) continue;
        final name = f.name.split('/').last;
        if (name == '${v.tarName}.onnx') await File(m).writeAsBytes(f.content, flush: true);
        if (name == '${v.tarName}.onnx.json') await File('$m.json').writeAsBytes(f.content, flush: true);
      }
    } finally {
      try {
        await tar.delete();
      } catch (_) {}
    }
    if (!_modelOk(v)) throw 'voix de secours incomplète';
  }

  /// Le réglage de la voix doit être un vrai fichier de voix Piper.
  static Future<void> _checkConfig(PiperVoiceInfo v) async {
    final cfg = File('${modelPath(v)!}.json');
    final j = jsonDecode(await cfg.readAsString());
    if (j is! Map || j['audio'] is! Map) {
      await cfg.delete();
      throw 'réglage de la voix illisible';
    }
  }

  /// Supprime la voix du PC.
  static Future<void> uninstall() async {
    await instance._stop();
    final f = folder;
    if (f != null && await Directory(f).exists()) await Directory(f).delete(recursive: true);
  }

  // ------------------------------------------------------------ Parler

  static final instance = PiperVoice._();

  Process? _proc;
  String _procKey = '';
  final _waiting = <Completer<void>>[];
  Future<void> _lock = Future.value();
  int _n = 0;
  bool _noPersist = false;

  /// Le son (WAV) d'un texte. [rate] : la vitesse (1 = normale).
  static Future<Uint8List> synthesize(String text, {double rate = 1}) => instance._synth(text, rate);

  Future<Uint8List> _synth(String text, double rate) {
    final t = speakable(text);
    if (t.isEmpty) return Future.value(Uint8List(0));
    // Une phrase à la fois (le programme lit ses demandes dans l'ordre).
    final run = _lock.then((_) => _one(t, rate));
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Uint8List> _one(String text, double rate) async {
    final exe = exePath();
    final v = voiceOf(chosen);
    final model = modelPath(v);
    if (exe == null || model == null || !File(model).existsSync()) throw 'La voix du PC n\'est pas installée';
    final out = Directory('${folder!}${Platform.pathSeparator}sortie');
    await out.create(recursive: true);
    if (!_noPersist) {
      try {
        return await _viaProcess(exe, model, v, out, text, rate);
      } catch (_) {
        // Le programme gardé ouvert ne répond pas comme prévu : jusqu'au
        // prochain démarrage, une phrase = un lancement (plus lent, sûr).
        _noPersist = true;
        await _stop();
      }
    }
    return _oneShot(exe, model, v, out, text, rate);
  }

  Future<Uint8List> _viaProcess(
    String exe,
    String model,
    PiperVoiceInfo v,
    Directory out,
    String text,
    double rate,
  ) async {
    final key = '$model|${lengthScale(rate).toStringAsFixed(2)}';
    var p = _proc;
    if (p == null || key != _procKey) {
      await _stop();
      p = _proc = await Process.start(
        exe,
        [
          '--model',
          model,
          '--json-input',
          '--output_dir',
          out.path,
          '--length_scale',
          lengthScale(rate).toStringAsFixed(2),
          '--sentence_silence',
          '0.15',
          if (v.speaker != null) ...['--speaker', '${v.speaker}'],
        ],
        workingDirectory: File(exe).parent.path,
        // Sans fenêtre noire (et on ne lit jamais son code de sortie : la fin
        // se voit à la sortie qui se ferme).
        mode: ProcessStartMode.detachedWithStdio,
      );
      _procKey = key;
      final mine = p;
      void ended() {
        if (identical(_proc, mine)) _proc = null;
        for (final w in _waiting) {
          if (!w.isCompleted) w.completeError('la voix s\'est arrêtée');
        }
        _waiting.clear();
      }

      // Une ligne sur la sortie = une phrase prête (le nom de son fichier).
      mine.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line.trim().isEmpty || _waiting.isEmpty) return;
              _waiting.removeAt(0).complete();
            },
            onDone: ended,
            onError: (Object _) => ended(),
          );
      mine.stderr.drain<void>().then((_) {}, onError: (_) {});
    }
    final before = {for (final f in out.listSync().whereType<File>()) f.path};
    final done = Completer<void>();
    _waiting.add(done);
    p.stdin.add(utf8.encode('${jsonLine(text, speaker: v.speaker)}\n'));
    await p.stdin.flush();
    await done.future.timeout(Duration(seconds: 12 + text.length ~/ 25));
    final made = out.listSync().whereType<File>().where((f) => f.path.endsWith('.wav') && !before.contains(f.path));
    final f = made.isEmpty
        ? null
        : (made.toList()..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()))).first;
    if (f == null) throw 'pas de son';
    final bytes = await f.readAsBytes();
    unawaited(f.delete().then((_) {}, onError: (_) {}));
    return bytes;
  }

  Future<Uint8List> _oneShot(
    String exe,
    String model,
    PiperVoiceInfo v,
    Directory out,
    String text,
    double rate,
  ) async {
    final path = '${out.path}${Platform.pathSeparator}nexo-${_n++ % 8}.wav';
    final p = await Process.start(
      exe,
      [
        '--model',
        model,
        '--json-input',
        '--output_file',
        path,
        '--length_scale',
        lengthScale(rate).toStringAsFixed(2),
        if (v.speaker != null) ...['--speaker', '${v.speaker}'],
      ],
      workingDirectory: File(exe).parent.path,
      mode: ProcessStartMode.detachedWithStdio,
    );
    p.stderr.drain<void>().then((_) {}, onError: (_) {});
    p.stdin.add(utf8.encode('${jsonLine(text, speaker: v.speaker)}\n'));
    await p.stdin.close();
    // Le programme a fini quand sa sortie se ferme.
    try {
      await p.stdout.drain<void>().timeout(const Duration(seconds: 40));
    } catch (_) {
      p.kill();
      throw 'la voix du PC met trop de temps';
    }
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() < 100) throw 'la voix du PC n\'a pas marché';
    return f.readAsBytes();
  }

  Future<void> _stop() async {
    final p = _proc;
    _proc = null;
    _procKey = '';
    if (p == null) return;
    try {
      await p.stdin.close();
    } catch (_) {}
    p.kill();
  }

  // ------------------------------------------------------------ Tout seul

  /// Installée d'office, une fois, en fond (la voix ne tombe plus jamais en
  /// panne quand le quota de Gemini est épuisé). [notify] : prévenir.
  static Future<void> autoInstall({void Function(String title, String body)? notify}) async {
    if (!supported || ready || installing) return;
    try {
      if (ModuleStore.global.getBool('app.piper.auto') == false) return;
      final failed = DateTime.tryParse(ModuleStore.global.getString('app.piper.echec') ?? '');
      if (failed != null && DateTime.now().difference(failed) < const Duration(days: 1)) return;
    } catch (_) {}
    try {
      await install();
      notify?.call(
        '🔊 Nexo a sa voix sur le PC',
        'Il parle maintenant même sans Gemini ni internet (voix ${voiceOf(chosen).name}). Réglages de Nexo → Voix.',
      );
    } catch (e) {
      try {
        await ModuleStore.global.setString('app.piper.echec', DateTime.now().toIso8601String());
      } catch (_) {}
    }
  }
}
