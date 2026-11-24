import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/claude_bridge.dart';

/// Un souci de micro, expliqué simplement, avec (si possible) la page des
/// réglages qui le règle.
class EarsProblem {
  const EarsProblem(this.message, {this.fixLabel, this.fixUri, this.code = ''});

  final String message;
  final String? fixLabel;
  final String? fixUri;

  /// Code technique (pour le test du micro).
  final String code;

  @override
  String toString() => message;
}

/// Résultat d'une réparation du micro par Nexo.
class EarsRepair {
  const EarsRepair({required this.problem, required this.steps});

  /// Le souci qui reste (null : le micro marche).
  final EarsProblem? problem;

  /// Ce que Nexo a essayé, dans l'ordre (pour l'afficher ou l'expliquer).
  final List<String> steps;

  bool get ok => problem == null;
}

/// Les pannes de lancement que Nexo répare tout seul en essayant une
/// autre façon de démarrer PowerShell (les autres demandent un réglage).
bool isLaunchProblem(EarsProblem p) =>
    p.code == 'launch' || p.code == 'died' || p.code == 'timeout' || p.code == 'start-timeout';

/// Façons de lancer le script de reconnaissance vocale, de la meilleure à
/// la plus robuste.
enum EarsLaunch {
  /// Script en paramètre, sans fenêtre (par défaut).
  encoded('sans fichier, sans fenêtre'),

  /// Fichier .ps1, sans fenêtre (si le paramètre est refusé).
  file('avec un fichier de script'),

  /// Script en paramètre, processus normal : marche même quand Windows
  /// refuse le lancement « détaché ».
  normal('lancement classique');

  const EarsLaunch(this.label);
  final String label;

  bool get detached => this != EarsLaunch.normal;
}

/// Ce que Nexo envoie à l'IA quand il n'a pas pu réparer le micro tout
/// seul : la panne, ce qu'il a déjà essayé, et ce qu'on attend de lui.
String micRepairPrompt(EarsProblem problem, EarsRepair repair, {String system = ''}) {
  final tried = repair.steps.isEmpty
      ? ''
      : ' Tu as déjà essayé tout seul (inutile de relancer clicky_reparer_micro) : ${repair.steps.join(' ; ')}.';
  return 'Mon micro ne marche pas avec toi (Nexo, dans Mon Hub${system.isEmpty ? '' : ' sur $system'}). '
      'Erreur affichée : « ${problem.message} »${problem.code.isEmpty ? '' : ' (code ${problem.code})'}.$tried '
      'Explique-moi simplement ce qui bloque et comment le régler, étape par étape '
      '(quel réglage ouvrir, quoi cocher). Rappelle-moi qu\'en attendant je peux écrire, '
      'ou utiliser la dictée de Windows (Win + H).';
}

/// Les « oreilles » de Nexo : transforment ce que tu dis en texte.
///
/// * Windows : la reconnaissance vocale moderne de Windows (la même que la
///   dictée Win + H), en français, via un petit script PowerShell gardé
///   ouvert en arrière-plan. L'ancien module (speech_to_text_windows)
///   n'écoutait qu'en anglais et perdait les événements du micro : Nexo
///   n'entendait rien.
/// * Android, iPhone, Mac : le module speech_to_text.
abstract class ClickyEars {
  /// Commence à écouter. Renvoie un souci si le micro ne peut pas démarrer.
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  });

  /// Arrête d'écouter et renvoie tout ce qui a été compris.
  Future<String> stop();

  /// Arrête sans rien garder.
  Future<void> cancel();

  /// Prépare le micro à l'avance (démarrage plus rapide).
  void warmUp() {}

  /// Remet le micro à zéro et essaie toutes les façons de le relancer.
  /// Renvoie ce qui a été fait, et le souci s'il reste.
  Future<EarsRepair> repair() async {
    try {
      await cancel();
    } catch (_) {}
    return const EarsRepair(problem: null, steps: ['Micro remis à zéro.']);
  }

  /// Langue réellement utilisée (ex. fr-FR), une fois connue.
  String? get language;

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static ClickyEars create() => !kIsWeb && Platform.isWindows ? WindowsEars() : PluginEars();
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

class WindowsEars extends ClickyEars {
  Process? _proc;
  Completer<EarsProblem?>? _boot;
  Completer<void>? _stopped;
  bool _listening = false;
  bool _stopping = false;
  bool _speech = false;
  Timer? _wave;
  String _final = '';
  String _hyp = '';
  String? _lang;

  void Function(String)? _onText;
  void Function(double)? _onLevel;
  void Function(EarsProblem)? _onProblem;
  void Function()? _onFinalPhrase;
  Completer<EarsProblem?>? _starting;

  @override
  String? get language => _lang;

  String get _text => [_final, _hyp].where((s) => s.trim().isNotEmpty).join(' ').trim();

  bool _warmed = false;

  /// Façon de lancer PowerShell. Par défaut sans fichier de script
  /// (-EncodedCommand), car certains PC bloquent les fichiers .ps1 ; si ça
  /// ne marche pas, Nexo passe tout seul à la suivante.
  EarsLaunch _launch = EarsLaunch.encoded;

  /// Façon de lancer utilisée en ce moment.
  EarsLaunch get launch => _launch;
  int? _exit;
  final _errors = StringBuffer();

  /// Le script en paramètre de PowerShell (UTF-16 en base64), sans fichier :
  /// marche même quand Windows bloque les fichiers .ps1.
  static String encodedScript() {
    final code = windowsScript.replaceFirst(RegExp(r"^\s*param\(\[string\]\$Lang = 'fr-FR'\)"), "\$Lang = 'fr-FR'");
    final units = code.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = units[i] >> 8;
    }
    return base64Encode(bytes);
  }

  /// Première ligne utile d'une erreur PowerShell.
  static String errorDetail(String stderr) {
    final lines = stderr
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('+') && !l.startsWith('At ') && !l.startsWith('Au caract'))
        .toList();
    if (lines.isEmpty) return '';
    final l = lines.first;
    return l.length > 220 ? '${l.substring(0, 217)}…' : l;
  }

  /// Paramètres de PowerShell pour une façon de lancer.
  @visibleForTesting
  static List<String> launchArgs(EarsLaunch how, String scriptPath) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    if (how == EarsLaunch.file) ...[
      '-File',
      scriptPath,
      '-Lang',
      'fr-FR',
    ] else ...[
      if (how == EarsLaunch.normal) ...['-WindowStyle', 'Hidden'],
      '-EncodedCommand',
      encodedScript(),
    ],
  ];

  /// Une seule fois : si le micro est en panne, on ne relance pas PowerShell
  /// en boucle (le prochain essai se fera quand tu parleras).
  @override
  void warmUp() {
    if (_warmed) return;
    _warmed = true;
    unawaited(_ensure());
  }

  Future<String> _writeScript() async {
    final base = ClaudeBridge.folder ?? Directory.systemTemp.path;
    final f = File('$base${Platform.pathSeparator}clicky-ecoute.ps1');
    await f.parent.create(recursive: true);
    // Réécrit seulement si le script a changé (nouvelle version de Mon Hub).
    if (!await f.exists() || await f.readAsString() != windowsScript) {
      await f.writeAsString(windowsScript);
    }
    return f.path;
  }

  Future<EarsProblem?> _ensure() {
    final b = _boot;
    if (b != null && _proc != null) return b.future;
    final boot = _boot = Completer<EarsProblem?>();
    () async {
      Process? started;
      try {
        final script = await _writeScript();
        _errors.clear();
        final how = _launch;
        final p = await Process.start(
          'powershell.exe',
          launchArgs(how, script),
          // Sans fenêtre de console, entrées / sorties branchées sur Mon Hub.
          mode: how.detached ? ProcessStartMode.detachedWithStdio : ProcessStartMode.normal,
        );
        started = p;
        _proc = p;
        _exit = null;
        // Un processus « détaché » n'a pas de code de sortie : le lire
        // lève « Bad state: Process is detached ».
        if (!how.detached) {
          unawaited(p.exitCode.then((c) => _exit = c, onError: (Object _) => -1));
        }
        p.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_line, onDone: () => _died(p), onError: (_) => _died(p));
        p.stderr.transform(utf8.decoder).listen((e) {
          if (_errors.length < 3000) _errors.write(e);
        }, onError: (_) {});
        Timer(const Duration(seconds: 20), () {
          if (!boot.isCompleted) {
            boot.complete(
              const EarsProblem(
                'La reconnaissance vocale de Windows met trop de temps à démarrer. Réessaie dans un instant.',
                code: 'timeout',
              ),
            );
            _kill();
          }
        });
      } catch (e) {
        // PowerShell a pu démarrer avant l'erreur : on ne le laisse pas
        // tourner pour rien.
        try {
          started?.kill();
        } catch (_) {}
        _proc = null;
        _boot = null;
        if (!boot.isCompleted) {
          boot.complete(
            EarsProblem('Impossible de lancer la reconnaissance vocale de Windows (PowerShell) : $e', code: 'launch'),
          );
        }
      }
    }();
    return boot.future;
  }

  void _kill() {
    try {
      _proc?.stdin.writeln('quit');
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
    _boot = null;
  }

  void _died(Process p) {
    if (_proc != p) return;
    _proc = null;
    final boot = _boot;
    _boot = null;
    if (boot != null && !boot.isCompleted) {
      // Le code de sortie arrive juste après : il dit pourquoi PowerShell
      // s'est arrêté (bloqué par Windows, antivirus…).
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (boot.isCompleted) return;
        final detail = errorDetail('$_errors');
        final code = _exit == null
            ? ''
            : ' (code ${_exit! < 0 ? '0x${(_exit! & 0xFFFFFFFF).toRadixString(16).toUpperCase()}' : _exit})';
        boot.complete(
          EarsProblem(
            'La reconnaissance vocale de Windows s\'est arrêtée tout de suite$code'
            '${detail.isEmpty ? '. PowerShell semble bloqué sur ce PC (antivirus ou règles de sécurité) : '
                      'utilise la dictée Windows (Win + H) en attendant.' : ' : $detail'}',
            code: 'died',
          ),
        );
      });
    }
    if (_listening && !_stopping) {
      _listening = false;
      _stopWave();
      _onProblem?.call(const EarsProblem('Le micro s\'est coupé. Réessaie.', code: 'died'));
    }
    _stopped?.complete();
    _stopped = null;
  }

  void _send(String cmd) {
    try {
      _proc?.stdin.writeln(cmd);
    } catch (_) {}
  }

  void _line(String line) {
    final Map<String, dynamic> m;
    try {
      final d = jsonDecode(line.trim());
      if (d is! Map) return;
      m = d.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final t = '${m['t'] ?? ''}';
    switch (t) {
      case 'ready':
        _lang = m['lang'] as String?;
        if (_boot?.isCompleted == false) _boot!.complete(null);
      case 'error':
        final p = windowsProblem('${m['code'] ?? ''}', '${m['msg'] ?? ''}');
        if (_boot?.isCompleted == false) {
          _boot!.complete(p);
        } else if (_starting?.isCompleted == false) {
          _starting!.complete(p);
        } else if (_listening) {
          _listening = false;
          _stopWave();
          _onProblem?.call(p);
        }
      case 'listening':
        if (_starting?.isCompleted == false) _starting!.complete(null);
      case 'state':
        final s = '${m['s'] ?? ''}';
        _speech = s == 'SoundStarted' || s == 'SpeechDetected';
      case 'hyp':
        _hyp = '${m['text'] ?? ''}';
        _speech = true;
        _onText?.call(_text);
      case 'res':
        final r = '${m['text'] ?? ''}'.trim();
        if (r.isNotEmpty) _final = [_final, r].where((s) => s.isNotEmpty).join(' ');
        _hyp = '';
        _onText?.call(_text);
        if (r.isNotEmpty) _onFinalPhrase?.call();
      case 'ended':
        // La session s'est arrêtée toute seule (silence, micro perdu…).
        if (_listening && !_stopping) {
          final status = '${m['status'] ?? ''}';
          if (status != 'Success' && status != 'TimeoutExceeded' && status != 'UserCanceled') {
            _listening = false;
            _stopWave();
            _onProblem?.call(windowsProblem(status, ''));
          } else {
            _onFinalPhrase?.call();
          }
        }
      case 'stopped':
        _stopped?.complete();
        _stopped = null;
    }
  }

  void _startWave() {
    _wave?.cancel();
    final rnd = math.Random();
    _wave = Timer.periodic(const Duration(milliseconds: 90), (_) {
      _onLevel?.call(_speech ? 0.35 + rnd.nextDouble() * 0.65 : 0.06 + rnd.nextDouble() * 0.06);
    });
  }

  void _stopWave() {
    _wave?.cancel();
    _wave = null;
  }

  @override
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  }) async {
    if (_listening) await cancel();
    _onText = onText;
    _onLevel = onLevel;
    _onProblem = onProblem;
    _onFinalPhrase = onFinalPhrase;
    _final = '';
    _hyp = '';
    _speech = false;
    final boot = await _bootWithFallback();
    if (boot != null) return boot;
    final starting = _starting = Completer<EarsProblem?>();
    _listening = true;
    _stopping = false;
    _send('start');
    final p = await starting.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () =>
          const EarsProblem('Le micro ne répond pas. Vérifie qu\'il est bien branché.', code: 'start-timeout'),
    );
    if (p != null) {
      _listening = false;
      return p;
    }
    _startWave();
    return null;
  }

  /// Démarre PowerShell ; s'il ne se lance pas, essaie tout seul les
  /// autres façons de le lancer (réparation automatique).
  Future<EarsProblem?> _bootWithFallback({List<String>? log}) async {
    var boot = await _ensure();
    // Trop lent : une autre façon de lancer ne changerait rien, sauf
    // pendant une réparation (log != null) où l'on essaie tout.
    bool retry(EarsProblem b) => log != null ? isLaunchProblem(b) : b.code == 'launch' || b.code == 'died';
    while (boot != null && retry(boot) && _launch.index < EarsLaunch.values.length - 1) {
      log?.add('Échec ${_launch.label} : ${boot.message}');
      _kill();
      _launch = EarsLaunch.values[_launch.index + 1];
      log?.add('J\'essaie autrement (${_launch.label}).');
      boot = await _ensure();
    }
    if (boot != null) _kill();
    return boot;
  }

  @override
  Future<EarsRepair> repair() async {
    final log = <String>[];
    if (_listening) {
      try {
        await cancel();
      } catch (_) {}
    }
    _listening = false;
    _stopping = false;
    _onText = null;
    _onLevel = null;
    _onProblem = null;
    _onFinalPhrase = null;
    _stopWave();
    _kill();
    _warmed = true;
    log.add('J\'ai arrêté l\'ancienne écoute.');
    // On repart de la meilleure façon de lancer, puis on descend la liste.
    _launch = EarsLaunch.encoded;
    final boot = await _bootWithFallback(log: log);
    if (boot != null) {
      log.add('Toujours bloqué : ${boot.message}');
      return EarsRepair(problem: boot, steps: log);
    }
    log.add('La reconnaissance vocale démarre (${_launch.label}, langue ${_lang ?? '?'}).');
    // Vérifie que le micro s'ouvre vraiment, puis le referme.
    final starting = _starting = Completer<EarsProblem?>();
    _send('start');
    final p = await starting.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () =>
          const EarsProblem('Le micro ne répond pas. Vérifie qu\'il est bien branché.', code: 'start-timeout'),
    );
    if (p != null) {
      log.add('Le micro ne s\'ouvre pas : ${p.message}');
      return EarsRepair(problem: p, steps: log);
    }
    final done = _stopped = Completer<void>();
    _send('stop');
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    log.add('Le micro s\'ouvre et se referme correctement.');
    return EarsRepair(problem: null, steps: log);
  }

  @override
  Future<String> stop() async {
    if (!_listening) return _text;
    _stopping = true;
    final done = _stopped = Completer<void>();
    _send('stop');
    // Windows finit la dernière phrase avant de répondre « stopped ».
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    _listening = false;
    _stopping = false;
    _stopWave();
    return _text;
  }

  @override
  Future<void> cancel() async {
    await stop();
    _final = '';
    _hyp = '';
  }

  /// Script PowerShell : reconnaissance vocale de Windows (WinRT
  /// Windows.Media.SpeechRecognition), dictée continue. Il reste ouvert et
  /// obéit à « start », « stop », « quit » (une commande par ligne). Il
  /// répond par une ligne JSON (en ASCII) par évènement.
  @visibleForTesting
  static const windowsScript = r'''
param([string]$Lang = 'fr-FR')
$ErrorActionPreference = 'Stop'

$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false))
$out.AutoFlush = $true
function Say($o) {
  $j = $o | ConvertTo-Json -Compress
  $j = [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
  $out.WriteLine($j)
}
function Code($err) {
  $x = $err.Exception
  while ($x.InnerException) { $x = $x.InnerException }
  return @(('0x{0:X8}' -f $x.HResult), $x.Message)
}

try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
  $asTaskOp = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $asTaskAction = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
  function AwaitOp($op, [Type]$type) {
    $task = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op))
    $null = $task.Wait(-1)
    return $task.Result
  }
  function AwaitAction($action) {
    $task = $asTaskAction.Invoke($null, @($action))
    $null = $task.Wait(-1)
  }

  $null = [Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

  $prefix = $Lang.Split('-')[0]
  $langs = @([Windows.Media.SpeechRecognition.SpeechRecognizer]::SupportedTopicLanguages)
  $pick = $langs | Where-Object { $_.LanguageTag -eq $Lang } | Select-Object -First 1
  if (-not $pick) { $pick = $langs | Where-Object { $_.LanguageTag -like "$prefix*" } | Select-Object -First 1 }
  if ($pick) {
    $rec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer($pick)
  } else {
    $rec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer
    Say @{ t = 'warn'; code = 'nolang'; lang = $rec.CurrentLanguage.LanguageTag }
  }

  $topic = New-Object Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint([Windows.Media.SpeechRecognition.SpeechRecognitionScenario]::Dictation, 'dictee')
  $rec.Constraints.Add($topic)
  $compiled = AwaitOp ($rec.CompileConstraintsAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
  if ($compiled.Status -ne [Windows.Media.SpeechRecognition.SpeechRecognitionResultStatus]::Success) {
    Say @{ t = 'error'; code = [string]$compiled.Status; msg = 'compile' }
    exit 1
  }
  $rec.Timeouts.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(1200)
  $session = $rec.ContinuousRecognitionSession
  $session.AutoStopSilenceTimeout = [TimeSpan]::FromMinutes(2)

  $null = Register-ObjectEvent -InputObject $session -EventName ResultGenerated -SourceIdentifier 'res'
  $null = Register-ObjectEvent -InputObject $session -EventName Completed -SourceIdentifier 'done'
  $null = Register-ObjectEvent -InputObject $rec -EventName HypothesisGenerated -SourceIdentifier 'hyp'
  $null = Register-ObjectEvent -InputObject $rec -EventName StateChanged -SourceIdentifier 'state'
} catch {
  $c = Code $_
  Say @{ t = 'error'; code = $c[0]; msg = $c[1] }
  exit 1
}

function Drain {
  foreach ($e in @(Get-Event -ErrorAction SilentlyContinue)) {
    try {
      $a = $e.SourceEventArgs
      switch ($e.SourceIdentifier) {
        'hyp' { Say @{ t = 'hyp'; text = $a.Hypothesis.Text } }
        'res' {
          $r = $a.Result
          if ($r.Status -eq [Windows.Media.SpeechRecognition.SpeechRecognitionResultStatus]::Success -and $r.Confidence -ne [Windows.Media.SpeechRecognition.SpeechRecognitionConfidence]::Rejected) {
            Say @{ t = 'res'; text = $r.Text }
          }
        }
        'state' { Say @{ t = 'state'; s = [string]$a.State } }
        'done' { $script:on = $false; Say @{ t = 'ended'; status = [string]$a.Status } }
      }
    } catch {}
    Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
  }
}

$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
$line = $in.ReadLineAsync()
$script:on = $false
Say @{ t = 'ready'; lang = $rec.CurrentLanguage.LanguageTag }

while ($true) {
  if ($line.IsCompleted) {
    $cmd = $null
    try { $cmd = $line.Result } catch {}
    if ($null -eq $cmd -or $cmd.Trim() -eq 'quit') { break }
    $cmd = $cmd.Trim()
    if ($cmd -eq 'start') {
      if (-not $script:on) {
        Drain
        try {
          AwaitAction ($session.StartAsync())
          $script:on = $true
          Say @{ t = 'listening' }
        } catch {
          $c = Code $_
          Say @{ t = 'error'; code = $c[0]; msg = $c[1] }
        }
      } else {
        Say @{ t = 'listening' }
      }
    } elseif ($cmd -eq 'stop') {
      if ($script:on) {
        try { AwaitAction ($session.StopAsync()) } catch {}
        $script:on = $false
      }
      Start-Sleep -Milliseconds 150
      Drain
      Say @{ t = 'stopped' }
    }
    $line = $in.ReadLineAsync()
  }
  Drain
  Start-Sleep -Milliseconds 30
}
try { if ($script:on) { AwaitAction ($session.StopAsync()) } } catch {}
''';
}

/// Explique un code d'erreur de la reconnaissance vocale de Windows.
EarsProblem windowsProblem(String code, String detail) {
  final c = code.toUpperCase();
  if (c.contains('80045509') || c == 'NETWORKFAILURE') {
    return EarsProblem(
      c == 'NETWORKFAILURE'
          ? 'La reconnaissance vocale de Windows a besoin d\'internet. Vérifie ta connexion, puis réessaie.'
          : 'Windows bloque la dictée : active « Reconnaissance vocale en ligne » '
                '(Paramètres → Confidentialité et sécurité → Voix), puis réessaie.',
      fixLabel: 'Ouvrir les réglages Voix',
      fixUri: 'ms-settings:privacy-speech',
      code: code,
    );
  }
  if (c.contains('80070005') || c.contains('ACCESSDENIED')) {
    return EarsProblem(
      'Windows empêche Mon Hub d\'utiliser le micro. Dans Paramètres → Confidentialité et sécurité '
      '→ Microphone, active « Accès au microphone » et « Autoriser les applications de bureau à '
      'accéder à votre microphone », puis réessaie.',
      fixLabel: 'Ouvrir les réglages du micro',
      fixUri: 'ms-settings:privacy-microphone',
      code: code,
    );
  }
  if (c == 'MICROPHONEUNAVAILABLE' || c.contains('8004503F') || c.contains('80070490') || c.contains('80045055')) {
    return EarsProblem(
      'Je ne trouve pas de micro (ou une autre appli l\'utilise). Branche-le et choisis-le comme '
      'micro par défaut dans les réglages du son.',
      fixLabel: 'Ouvrir les réglages du son',
      fixUri: 'ms-settings:sound',
      code: code,
    );
  }
  if (c == 'TOPICLANGUAGENOTSUPPORTED' || c == 'NOLANG' || c.contains('8004503A')) {
    return EarsProblem(
      'La reconnaissance vocale en français n\'est pas installée sur ce PC. Dans Paramètres → '
      'Heure et langue → Langue et région, ajoute « Français (France) » avec « Reconnaissance vocale ».',
      fixLabel: 'Ouvrir les réglages de langue',
      fixUri: 'ms-settings:regionlanguage',
      code: code,
    );
  }
  if (c == 'AUDIOQUALITYFAILURE') {
    return EarsProblem(
      'Le son du micro est trop faible ou trop bruité. Rapproche-toi du micro.',
      fixLabel: 'Ouvrir les réglages du son',
      fixUri: 'ms-settings:sound',
      code: code,
    );
  }
  return EarsProblem(
    'La reconnaissance vocale de Windows ne marche pas ici'
    '${code.isEmpty ? '' : ' ($code${detail.isEmpty ? '' : ' : $detail'})'}. '
    'Tu peux utiliser la dictée de Windows (Win + H) dans la zone de texte.',
    fixLabel: 'Ouvrir les réglages Voix',
    fixUri: 'ms-settings:speech',
    code: code,
  );
}

// ---------------------------------------------------------------------------
// Android, iPhone, Mac
// ---------------------------------------------------------------------------

class PluginEars extends ClickyEars {
  final _stt = SpeechToText();
  bool _ready = false;
  String? _locale;
  String _text = '';
  Completer<void>? _done;
  void Function(EarsProblem)? _onProblem;
  bool _listening = false;

  @override
  String? get language => _locale;

  Future<EarsProblem?> _init() async {
    if (_ready) return null;
    try {
      // On réessaie à chaque fois : la permission a pu être donnée entre-temps.
      _ready = await _stt.initialize(
        onError: (e) {
          if (!_listening) return;
          // « Pas de correspondance » ou silence : ce n'est pas une panne.
          if (e.errorMsg == 'error_no_match' || e.errorMsg == 'error_speech_timeout') {
            _done?.complete();
            return;
          }
          _listening = false;
          _onProblem?.call(_pluginProblem(e.errorMsg));
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            if (_done?.isCompleted == false) _done!.complete();
          }
        },
      );
    } catch (e) {
      return EarsProblem('Micro indisponible : $e', code: 'init');
    }
    if (!_ready) {
      return const EarsProblem(
        'Je n\'ai pas accès au micro. Autorise Mon Hub à utiliser le micro et la reconnaissance '
        'vocale dans les réglages de l\'appareil.',
        code: 'permission',
      );
    }
    try {
      final locales = await _stt.locales();
      final fr =
          locales.where((l) => l.localeId.replaceAll('-', '_') == 'fr_FR').firstOrNull ??
          locales.where((l) => l.localeId.toLowerCase().startsWith('fr')).firstOrNull;
      _locale = fr?.localeId ?? (await _stt.systemLocale())?.localeId;
    } catch (_) {}
    return null;
  }

  EarsProblem _pluginProblem(String msg) => switch (msg) {
    'error_permission' || 'error_insufficient_permissions' => const EarsProblem(
      'Je n\'ai pas accès au micro : autorise-le pour Mon Hub dans les réglages de l\'appareil.',
      code: 'permission',
    ),
    'error_network' || 'error_network_timeout' => const EarsProblem(
      'La reconnaissance vocale a besoin d\'internet. Vérifie ta connexion.',
      code: 'network',
    ),
    'error_busy' => const EarsProblem('Le micro est déjà utilisé. Réessaie dans un instant.', code: 'busy'),
    _ => EarsProblem('Souci de micro ($msg). Réessaie.', code: msg),
  };

  @override
  Future<EarsProblem?> start({
    required void Function(String text) onText,
    required void Function(double level) onLevel,
    required void Function(EarsProblem problem) onProblem,
    required void Function() onFinalPhrase,
  }) async {
    _onProblem = onProblem;
    final p = await _init();
    if (p != null) return p;
    _text = '';
    _done = Completer<void>();
    _listening = true;
    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          localeId: _locale,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
        ),
        onSoundLevelChange: (l) => onLevel(((l + 2) / 12).clamp(0.05, 1.0)),
        onResult: (r) {
          _text = r.recognizedWords;
          onText(_text);
          if (r.finalResult) onFinalPhrase();
        },
      );
    } catch (e) {
      _listening = false;
      return EarsProblem('Micro : $e', code: 'listen');
    }
    return null;
  }

  @override
  Future<String> stop() async {
    if (!_listening) return _text;
    try {
      await _stt.stop();
    } catch (_) {}
    // Laisse le temps au dernier mot d'arriver.
    await (_done?.future ?? Future<void>.value()).timeout(const Duration(milliseconds: 1200), onTimeout: () {});
    _listening = false;
    return _text;
  }

  @override
  Future<void> cancel() async {
    _listening = false;
    try {
      await _stt.cancel();
    } catch (_) {}
    _text = '';
  }
}
