import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../../core/claude_bridge.dart';
import 'ears.dart';

/// Whisper : la reconnaissance vocale d'OpenAI (version libre whisper.cpp),
/// qui tourne **sur ton PC**, sans internet et sans rien envoyer à
/// personne. Bien meilleure en français que celle de Windows, et elle ne
/// dépend d'aucun réglage de Windows.
///
/// Installation à la demande (une seule fois) : le programme whisper.cpp
/// (GitHub, ~ 4 Mo) et un modèle (Hugging Face) rangés dans
/// %APPDATA%\MonHub\whisper.
///
/// Fonctionnement : le micro est enregistré pendant que tu parles (module
/// record), puis whisper-cli transcrit le fichier en français quand tu as
/// fini. Le texte n'apparaît donc qu'à la fin (1 à 3 s pour une phrase).
class Whisper {
  Whisper._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Programme Windows (dernière version publiée avec les exécutables).
  static const binUrl =
      'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-bin-x64.zip';

  /// Modèles : « rapide » (base, 142 Mo) ou « précis » (small, 466 Mo).
  static const models = {
    'base': ('Rapide', 142),
    'small': ('Précis', 466),
  };

  static String modelUrl(String m) =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin';

  static String? get folder {
    final base = ClaudeBridge.folder;
    return base == null ? null : '$base${Platform.pathSeparator}whisper';
  }

  static String? modelPath(String m) {
    final f = folder;
    return f == null ? null : '$f${Platform.pathSeparator}ggml-$m.bin';
  }

  /// Chemin de whisper-cli.exe une fois installé (null sinon).
  static Future<String?> cli() async {
    final f = folder;
    if (f == null) return null;
    final dir = Directory('$f${Platform.pathSeparator}bin');
    if (!await dir.exists()) return null;
    String? fallback;
    await for (final e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final n = e.path.split(Platform.pathSeparator).last.toLowerCase();
      if (n == 'whisper-cli.exe') return e.path;
      if (n == 'main.exe') fallback = e.path;
    }
    return fallback;
  }

  /// Le modèle installé (le plus précis s'il y en a deux).
  static Future<String?> installedModel() async {
    for (final m in ['small', 'base']) {
      final p = modelPath(m);
      if (p != null && await File(p).exists() && await File(p).length() > 10 * 1024 * 1024) return m;
    }
    return null;
  }

  static Future<bool> get ready async => await cli() != null && await installedModel() != null;

  /// Télécharge et installe whisper.cpp et le modèle [model].
  /// [onProgress] reçoit (étape, fraction 0..1).
  static Future<void> install({
    String model = 'base',
    void Function(String step, double progress)? onProgress,
  }) async {
    final f = folder;
    if (f == null) throw 'Dossier de Mon Hub introuvable';
    final sep = Platform.pathSeparator;
    await Directory(f).create(recursive: true);
    final client = http.Client();
    try {
      if (await cli() == null) {
        final zip = await _download(
          client,
          binUrl,
          '$f${sep}whisper-bin.zip',
          (p) => onProgress?.call('Programme Whisper', p),
        );
        onProgress?.call('Installation', 1);
        final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
        final bin = Directory('$f${sep}bin');
        for (final e in archive) {
          if (!e.isFile) continue;
          final name = e.name.replaceAll('/', sep).replaceAll('\\', sep);
          if (name.contains('..')) continue;
          final out = File('${bin.path}$sep$name');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(e.content, flush: true);
        }
        await zip.delete();
        if (await cli() == null) throw 'whisper-cli.exe introuvable dans le téléchargement';
      }
      final mp = modelPath(model)!;
      if (!await File(mp).exists()) {
        await _download(
          client,
          modelUrl(model),
          mp,
          (p) => onProgress?.call('Modèle ${models[model]?.$1 ?? model} (${models[model]?.$2 ?? '?'} Mo)', p),
        );
      }
    } finally {
      client.close();
    }
  }

  static Future<File> _download(
    http.Client client,
    String url,
    String path,
    void Function(double) progress,
  ) async {
    final res = await client.send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode != 200) throw 'Téléchargement refusé (code ${res.statusCode}) : $url';
    final total = res.contentLength ?? 0;
    final part = File('$path.part');
    final sink = part.openWrite();
    var got = 0;
    var last = DateTime(0);
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        final now = DateTime.now();
        if (total > 0 && now.difference(last).inMilliseconds > 200) {
          last = now;
          progress(got / total);
        }
      }
      await sink.close();
    } catch (e) {
      await sink.close();
      if (await part.exists()) await part.delete();
      throw 'Téléchargement interrompu : $e';
    }
    progress(1);
    final f = File(path);
    if (await f.exists()) await f.delete();
    return part.rename(path);
  }

  /// Supprime Whisper (programme et modèles).
  static Future<void> uninstall() async {
    final f = folder;
    if (f != null && await Directory(f).exists()) await Directory(f).delete(recursive: true);
  }

  /// Transcrit un fichier WAV (16 kHz mono) en texte.
  static Future<String> transcribe(String wav, {String lang = 'fr'}) async {
    final exe = await cli();
    final model = await installedModel();
    if (exe == null || model == null) throw 'Whisper n\'est pas installé';
    final threads = Platform.numberOfProcessors.clamp(2, 8);
    // Sans fenêtre de console ; on lit la sortie jusqu'au bout (un processus
    // détaché n'a pas de code de sortie, on ne le lit donc pas).
    final p = await Process.start(
      exe,
      [
        '-m', modelPath(model)!,
        '-f', wav,
        '-l', lang,
        '-t', '$threads',
        '-nt',
        '-np',
      ],
      workingDirectory: File(exe).parent.path,
      mode: ProcessStartMode.detachedWithStdio,
    );
    unawaited(p.stdin.close().then((_) {}, onError: (_) {}));
    final err = StringBuffer();
    unawaited(
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach((s) {
        if (err.length < 4000) err.write(s);
      }).then((_) {}, onError: (_) {}),
    );
    final out = await p.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 90), onTimeout: () {
          p.kill();
          throw 'Whisper met trop de temps (essaie le modèle « Rapide »)';
        });
    final text = clean(out);
    if (text.isEmpty && err.toString().toLowerCase().contains('error')) {
      throw 'Whisper : ${err.toString().trim().split('\n').last}';
    }
    return text;
  }

  /// Nettoie la sortie de whisper-cli (horodatages, « [Musique] »…).
  @visibleForTesting
  static String clean(String out) => out
      .split(RegExp(r'[\r\n]+'))
      .map((l) => l.replaceFirst(RegExp(r'^\s*\[[0-9:.\s\->]+\]\s*'), '').trim())
      .where((l) => l.isNotEmpty && !RegExp(r'^[\[(].*[\])]$').hasMatch(l))
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Les « oreilles » de Clicky avec Whisper : enregistre, puis transcrit.
class WhisperEars extends ClickyEars {
  final _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  String? _wav;
  bool _listening = false;
  String _text = '';
  bool _spoke = false;
  DateTime? _quietSince;
  void Function()? _onFinalPhrase;
  void Function(String)? _onText;

  @override
  String? get language => 'fr-FR (Whisper)';

  @override
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  }) async {
    if (_listening) await cancel();
    if (!await Whisper.ready) {
      return const EarsProblem(
        'Whisper n\'est pas encore installé sur ce PC.',
        fixLabel: 'Installer Whisper',
        fixUri: whisperInstallUri,
        code: 'whisper-missing',
      );
    }
    try {
      if (!await _rec.hasPermission()) {
        return const EarsProblem(
          'Windows empêche Mon Hub d\'utiliser le micro. Dans Paramètres → Confidentialité et sécurité '
          '→ Microphone, active l\'accès pour les applications de bureau.',
          fixLabel: 'Ouvrir les réglages du micro',
          fixUri: 'ms-settings:privacy-microphone',
          code: 'whisper-permission',
        );
      }
      final dir = await Directory.systemTemp.createTemp('clicky-voix');
      _wav = '${dir.path}${Platform.pathSeparator}voix.wav';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
        path: _wav!,
      );
    } catch (e) {
      return EarsProblem(
        'Je n\'arrive pas à ouvrir le micro ($e). Vérifie qu\'il est branché et choisi par défaut.',
        fixLabel: 'Ouvrir les réglages du son',
        fixUri: 'ms-settings:sound',
        code: 'whisper-mic',
      );
    }
    _listening = true;
    _text = '';
    _spoke = false;
    _quietSince = null;
    _onFinalPhrase = onFinalPhrase;
    _onText = onText;
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((a) {
      // dBFS : -60 (silence) à 0 (très fort).
      final level = ((a.current + 55) / 45).clamp(0.04, 1.0);
      onLevel(level);
      final speaking = a.current > -38;
      if (speaking) {
        _spoke = true;
        _quietSince = null;
      } else if (_spoke) {
        _quietSince ??= DateTime.now();
        // Une phrase finie (1,2 s de silence après avoir parlé).
        if (DateTime.now().difference(_quietSince!) > const Duration(milliseconds: 1200)) {
          _spoke = false;
          _onFinalPhrase?.call();
        }
      }
    });
    return null;
  }

  @override
  Future<String> stop() async {
    if (!_listening) return _text;
    _listening = false;
    await _amp?.cancel();
    _amp = null;
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    path ??= _wav;
    if (path == null || !await File(path).exists()) return _text;
    try {
      _text = await Whisper.transcribe(path);
      _onText?.call(_text);
    } catch (_) {
      _text = '';
    } finally {
      try {
        await File(path).parent.delete(recursive: true);
      } catch (_) {}
    }
    return _text;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    await _amp?.cancel();
    _amp = null;
    try {
      await _rec.cancel();
    } catch (_) {}
    _text = '';
  }

  @override
  Future<EarsRepair> repair() async {
    await cancel();
    final ok = await Whisper.ready;
    return EarsRepair(
      problem: ok
          ? null
          : const EarsProblem(
              'Whisper n\'est pas installé.',
              fixLabel: 'Installer Whisper',
              fixUri: whisperInstallUri,
              code: 'whisper-missing',
            ),
      steps: [ok ? 'Whisper est installé et prêt.' : 'Whisper n\'est pas installé.'],
    );
  }
}

/// « Bouton » spécial des soucis de micro : installe Whisper.
const whisperInstallUri = 'monhub:installer-whisper';

/// Choisit les oreilles selon le réglage : Windows, Whisper, ou
/// automatique (Windows, et Whisper dès que Windows ne marche pas).
class SmartEars extends ClickyEars {
  SmartEars(this.windows, this.whisper, this.mode);

  final ClickyEars windows;
  final WhisperEars whisper;

  /// 'auto', 'windows' ou 'whisper'.
  String Function() mode;

  /// Windows a échoué : on reste sur Whisper jusqu'au redémarrage.
  bool _windowsFailed = false;
  ClickyEars? _current;

  ClickyEars get active => _current ?? windows;

  @override
  String? get language => active.language;

  @override
  void warmUp() {
    if (mode() != 'whisper') windows.warmUp();
  }

  @override
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  }) async {
    Future<EarsProblem?> go(ClickyEars e) {
      _current = e;
      return e.start(onText: onText, onLevel: onLevel, onProblem: onProblem, onFinalPhrase: onFinalPhrase);
    }

    final m = mode();
    if (m == 'whisper' || (m == 'auto' && _windowsFailed && await Whisper.ready)) return go(whisper);
    final p = await go(windows);
    if (p == null || m != 'auto') return p;
    // Windows ne marche pas : Whisper prend le relais s'il est installé.
    if (await Whisper.ready) {
      _windowsFailed = true;
      return go(whisper);
    }
    return EarsProblem(
      '${p.message}\n\nSolution sûre : installe Whisper (reconnaissance vocale sur ton PC, '
      'sans internet, 142 Mo une seule fois).',
      fixLabel: 'Installer Whisper',
      fixUri: whisperInstallUri,
      code: p.code,
    );
  }

  @override
  Future<String> stop() => active.stop();

  @override
  Future<void> cancel() => active.cancel();

  @override
  Future<EarsRepair> repair() async {
    if (mode() == 'whisper') return whisper.repair();
    final r = await windows.repair();
    if (r.ok || mode() != 'auto') return r;
    if (await Whisper.ready) {
      _windowsFailed = true;
      return EarsRepair(
        problem: null,
        steps: [...r.steps, 'Windows ne marche pas : je passe sur Whisper (installé sur ton PC).'],
      );
    }
    return EarsRepair(
      problem: EarsProblem(
        '${r.problem!.message}\n\nSolution sûre : installe Whisper (reconnaissance vocale sur ton PC).',
        fixLabel: 'Installer Whisper',
        fixUri: whisperInstallUri,
        code: r.problem!.code,
      ),
      steps: r.steps,
    );
  }
}
