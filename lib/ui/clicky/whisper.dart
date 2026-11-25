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

  /// Programme Windows : les dernières versions publiées avec les
  /// exécutables (la plus récente d'abord, les autres en secours).
  static const binUrls = [
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-bin-x64.zip',
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.1/whisper-bin-x64.zip',
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.0/whisper-bin-x64.zip',
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.7.6/whisper-bin-x64.zip',
  ];

  /// Modèles : « rapide » (base, 142 Mo) ou « précis » (small, 466 Mo).
  static const models = {'base': ('Rapide', 142), 'small': ('Précis', 466)};

  static String modelUrl(String m) =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin?download=true';

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
  ///
  /// Robuste : plusieurs versions du programme, et si le téléchargement
  /// intégré échoue (antivirus, proxy…), `curl.exe` et `tar.exe` de
  /// Windows prennent le relais. Chaque erreur est notée dans
  /// whisper\installation.log.
  static Future<void> install({String model = 'base', void Function(String step, double progress)? onProgress}) async {
    final f = folder;
    if (f == null) throw 'Dossier de Mon Hub introuvable';
    final sep = Platform.pathSeparator;
    await Directory(f).create(recursive: true);
    final log = <String>[];
    final client = http.Client();
    try {
      if (await cli() == null) {
        Object? last;
        for (final url in binUrls) {
          try {
            final zip = await _download(
              client,
              url,
              '$f${sep}whisper-bin.zip',
              (p) => onProgress?.call('Programme Whisper', p),
              log,
            );
            onProgress?.call('Installation du programme', 1);
            await _unzip(zip, Directory('$f${sep}bin'), log);
            try {
              await zip.delete();
            } catch (_) {}
            if (await cli() != null) break;
            log.add('$url : whisper-cli.exe absent du fichier');
          } catch (e) {
            last = e;
            log.add('$url : $e');
          }
        }
        if (await cli() == null) {
          throw 'Impossible d\'installer le programme Whisper${last == null ? '' : ' ($last)'}';
        }
      }
      final mp = modelPath(model)!;
      if (!await File(mp).exists() || await File(mp).length() < 30 * 1024 * 1024) {
        await _download(
          client,
          modelUrl(model),
          mp,
          (p) => onProgress?.call('Modèle ${models[model]?.$1 ?? model} (${models[model]?.$2 ?? '?'} Mo)', p),
          log,
          minBytes: 30 * 1024 * 1024,
        );
      }
    } catch (e) {
      log.add('Échec : $e');
      rethrow;
    } finally {
      client.close();
      try {
        await File('$f${sep}installation.log')
            .writeAsString('${DateTime.now()}\n${log.join('\n')}\n\n', mode: FileMode.append);
      } catch (_) {}
    }
  }

  /// Télécharge un fichier (le même chemin que Whisper : module intégré, sinon
  /// curl.exe de Windows). Sert aussi à la voix du PC (Piper).
  static Future<File> download(
    String url,
    String path,
    void Function(double) progress,
    List<String> log, {
    int minBytes = 100 * 1024,
  }) async {
    final c = http.Client();
    try {
      return await _download(c, url, path, progress, log, minBytes: minBytes);
    } finally {
      c.close();
    }
  }

  /// Décompresse un zip (voir [_unzip]).
  static Future<void> unzip(File zip, Directory dest, List<String> log) => _unzip(zip, dest, log);

  /// Décompresse (module intégré, sinon tar.exe de Windows).
  static Future<void> _unzip(File zip, Directory dest, List<String> log) async {
    final sep = Platform.pathSeparator;
    await dest.create(recursive: true);
    try {
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final e in archive) {
        if (!e.isFile) continue;
        final name = e.name.replaceAll('/', sep).replaceAll('\\', sep);
        if (name.contains('..')) continue;
        final out = File('${dest.path}$sep$name');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(e.content, flush: true);
      }
    } catch (e) {
      log.add('Décompression intégrée : $e → tar.exe');
      final r = await Process.run('tar', ['-xf', zip.path, '-C', dest.path], runInShell: true);
      if (r.exitCode != 0) throw 'Décompression impossible : ${r.stderr}';
    }
  }

  static Future<File> _download(
    http.Client client,
    String url,
    String path,
    void Function(double) progress,
    List<String> log, {
    int minBytes = 100 * 1024,
  }) async {
    try {
      final f = await _downloadDart(client, url, path, progress);
      if (await f.length() < minBytes) throw 'fichier incomplet (${await f.length()} octets)';
      return f;
    } catch (e) {
      log.add('Téléchargement intégré de $url : $e → curl.exe');
      if (!Platform.isWindows) rethrow;
      progress(0);
      final part = '$path.part';
      final r = await Process.run('curl.exe', [
        '-L',
        '--fail',
        '--retry',
        '3',
        '--connect-timeout',
        '20',
        '-s',
        '-o',
        part,
        url,
      ], runInShell: true);
      final f = File(part);
      if (r.exitCode != 0 || !await f.exists() || await f.length() < minBytes) {
        throw 'téléchargement impossible (code ${r.exitCode}${'${r.stderr}'.trim().isEmpty ? '' : ' : ${'${r.stderr}'.trim()}'}). '
            'Vérifie ta connexion internet, ou que ton antivirus ne bloque pas Mon Hub.';
      }
      progress(1);
      final dest = File(path);
      if (await dest.exists()) await dest.delete();
      return f.rename(path);
    }
  }

  static Future<File> _downloadDart(http.Client client, String url, String path, void Function(double) progress) async {
    final req = http.Request('GET', Uri.parse(url))
      ..followRedirects = true
      ..maxRedirects = 10
      ..headers['user-agent'] = 'MonHub';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw 'refusé (code ${res.statusCode})';
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
      throw 'interrompu : $e';
    }
    if (total > 0 && got < total) throw 'incomplet ($got / $total octets)';
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
  static Future<String> transcribe(
    String wav, {
    String lang = 'fr',
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final exe = await cli();
    final model = await installedModel();
    if (exe == null || model == null) throw 'Whisper n\'est pas installé';
    final threads = Platform.numberOfProcessors.clamp(2, 8);
    // Sans fenêtre de console ; on lit la sortie jusqu'au bout (un processus
    // détaché n'a pas de code de sortie, on ne le lit donc pas).
    final p = await Process.start(
      exe,
      ['-m', modelPath(model)!, '-f', wav, '-l', lang, '-t', '$threads', '-nt', '-np'],
      workingDirectory: File(exe).parent.path,
      mode: ProcessStartMode.detachedWithStdio,
    );
    unawaited(p.stdin.close().then((_) {}, onError: (_) {}));
    final err = StringBuffer();
    unawaited(
      p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach((s) {
            if (err.length < 4000) err.write(s);
          })
          .then((_) {}, onError: (_) {}),
    );
    final out = await p.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(
          timeout,
          onTimeout: () {
            p.kill();
            throw 'Whisper met trop de temps (essaie le modèle « Rapide »)';
          },
        );
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

/// Les « oreilles » de Nexo avec Whisper : enregistre, puis transcrit
/// sur le PC.
class WhisperEars extends RecordingEars {
  @override
  String get name => 'Whisper (sur le PC)';

  @override
  Future<bool> get isReady => Whisper.ready;

  @override
  Future<String> transcribeFile(String wav) => Whisper.transcribe(wav);

  @override
  EarsProblem get missing => const EarsProblem(
    'Whisper n\'est pas encore installé sur ce PC.',
    fixLabel: 'Installer Whisper',
    fixUri: whisperInstallUri,
    code: 'whisper-missing',
  );
}

/// Les « oreilles » avec Gemini (ta clé gratuite de Google AI Studio) :
/// le son est envoyé à Google pour être transcrit. Marche sans rien
/// installer, mais demande internet.
class GeminiEars extends RecordingEars {
  GeminiEars(this.key);

  /// Clé Gemini (celle de la voix de Nexo).
  final String Function() key;

  @override
  String get name => 'Gemini (en ligne)';

  @override
  Future<bool> get isReady async => key().trim().isNotEmpty;

  @override
  Future<String> transcribeFile(String wav) => GeminiTranscriber.transcribe(wav, key());

  @override
  EarsProblem get missing => const EarsProblem(
    'Pas de clé Gemini : ajoute ta clé gratuite (aistudio.google.com) dans Réglages Nexo → Voix.',
    code: 'gemini-missing',
  );
}

/// Transcription par Gemini (audio envoyé à Google).
class GeminiTranscriber {
  GeminiTranscriber._();

  static const models = ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash'];

  static Future<String> transcribe(
    String wav,
    String key, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (key.trim().isEmpty) throw 'Pas de clé Gemini';
    final audio = base64Encode(await File(wav).readAsBytes());
    final c = client ?? http.Client();
    Object? last;
    try {
      for (final model in models) {
        try {
          final r = await c
              .post(
                Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
                headers: {'content-type': 'application/json', 'x-goog-api-key': key.trim()},
                body: jsonEncode({
                  'contents': [
                    {
                      'parts': [
                        {
                          'text':
                              'Transcris exactement ce qui est dit dans cet enregistrement (en français, '
                              'ou dans la langue parlée). Réponds uniquement avec le texte transcrit, sans '
                              'guillemets ni commentaire. S\'il n\'y a pas de parole, réponds par une chaîne vide.',
                        },
                        {
                          'inline_data': {'mime_type': 'audio/wav', 'data': audio},
                        },
                      ],
                    },
                  ],
                  'generationConfig': {'temperature': 0},
                }),
              )
              .timeout(timeout);
          if (r.statusCode == 404) {
            last = 'modèle $model indisponible';
            continue;
          }
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (r.statusCode != 200) {
            final e = j is Map ? j['error'] : null;
            final err = e is Map ? e['message'] : null;
            throw 'Gemini (code ${r.statusCode}) : ${err ?? ''}';
          }
          final parts =
              ((((j as Map)['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
          return [
            for (final p in parts ?? const [])
              if (p is Map && p['text'] != null) '${p['text']}',
          ].join(' ').trim();
        } on TimeoutException {
          last = 'Gemini met trop de temps';
        }
      }
      throw '$last';
    } finally {
      if (client == null) c.close();
    }
  }
}

/// Oreilles qui enregistrent le micro puis transcrivent le fichier.
abstract class RecordingEars extends ClickyEars {
  String get name;
  Future<bool> get isReady;
  Future<String> transcribeFile(String wav);
  EarsProblem get missing;

  /// Dernière erreur de transcription (affichée à la place du texte).
  String? lastError;

  /// Créé seulement quand on s'en sert (pas au démarrage des deux
  /// programmes).
  AudioRecorder? _recorder;
  AudioRecorder get _rec => _recorder ??= AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  String? _wav;
  bool _listening = false;
  String _text = '';
  bool _spoke = false;
  DateTime? _quietSince;
  void Function()? _onFinalPhrase;
  void Function(String)? _onText;

  @override
  String? get language => 'fr-FR ($name)';

  @override
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  }) async {
    if (_listening) await cancel();
    if (!await isReady) return missing;
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
      await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: _wav!);
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
      _text = await transcribeFile(path);
      lastError = null;
      _onText?.call(_text);
    } catch (e) {
      lastError = '$e';
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
      await _recorder?.cancel();
    } catch (_) {}
    _text = '';
  }

  @override
  Future<EarsRepair> repair() async {
    await cancel();
    final ok = await isReady;
    return EarsRepair(problem: ok ? null : missing, steps: [ok ? '$name est prêt.' : missing.message]);
  }
}

/// « Bouton » spécial des soucis de micro : installe Whisper.
const whisperInstallUri = 'monhub:installer-whisper';

/// Choisit les oreilles selon le réglage : Windows, Whisper, ou
/// automatique (Windows, et Whisper dès que Windows ne marche pas).
class SmartEars extends ClickyEars {
  SmartEars(this.windows, this.whisper, this.gemini, this.mode);

  final ClickyEars windows;
  final WhisperEars whisper;
  final GeminiEars gemini;

  /// 'auto', 'windows', 'whisper' ou 'gemini'.
  String Function() mode;

  /// Windows a échoué : on reste sur le relais jusqu'au redémarrage.
  bool _windowsFailed = false;
  ClickyEars? _current;

  ClickyEars get active => _current ?? windows;

  @override
  String? get language => active.language;

  @override
  void warmUp() {
    if (mode() == 'auto' || mode() == 'windows') windows.warmUp();
  }

  /// Le premier relais prêt : Whisper (sur le PC), sinon Gemini (en ligne).
  Future<RecordingEars?> _relay() async {
    if (await whisper.isReady) return whisper;
    if (await gemini.isReady) return gemini;
    return null;
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
    if (m == 'whisper') return go(whisper);
    if (m == 'gemini') return go(gemini);
    if (m == 'auto' && _windowsFailed) {
      final r = await _relay();
      if (r != null) return go(r);
    }
    final p = await go(windows);
    if (p == null || m != 'auto') return p;
    // Windows ne marche pas : Whisper, sinon Gemini, prend le relais.
    final r = await _relay();
    if (r != null) {
      _windowsFailed = true;
      return go(r);
    }
    return EarsProblem(
      '${p.message}\n\nSolution sûre : installe Whisper (reconnaissance vocale sur ton PC, '
      'sans internet, 142 Mo une seule fois), ou ajoute ta clé Gemini gratuite (Réglages → Voix).',
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
    if (mode() == 'gemini') return gemini.repair();
    final r = await windows.repair();
    if (r.ok || mode() != 'auto') return r;
    final relay = await _relay();
    if (relay != null) {
      _windowsFailed = true;
      return EarsRepair(problem: null, steps: [...r.steps, 'Windows ne marche pas : je passe sur ${relay.name}.']);
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
