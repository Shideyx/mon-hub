import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';

/// Mot d'activation (Windows) : dis « Jarvis » (ou « Clicky ») et il
/// t'écoute, sans toucher au clavier.
///
/// La reconnaissance vocale de Windows ne cherche que ces quelques mots
/// (liste fermée), sur le PC : rien n'est envoyé tant que le mot n'a pas été
/// entendu. Elle se met en pause pendant que Clicky écoute ta question.
class WakeWord {
  WakeWord(this.onWake);
  final void Function() onWake;

  static bool get supported => !kIsWeb && Platform.isWindows;

  Process? _proc;
  bool _paused = false;
  List<String> _words = const [];

  bool get running => _proc != null;

  static List<String> phrasesFor(String word) {
    final w = word.toLowerCase().trim().isEmpty ? 'jarvis' : word.toLowerCase().trim();
    return [w, 'hey $w', 'ok $w', 'dis $w', 'hé $w', 'salut $w'];
  }

  Future<void> start(String word) async {
    if (!supported) return;
    final words = phrasesFor(word);
    if (_proc != null && listEquals(words, _words)) {
      resume();
      return;
    }
    await stop();
    _words = words;
    try {
      final base = ClaudeBridge.folder ?? Directory.systemTemp.path;
      final f = File('$base${Platform.pathSeparator}clicky-reveil.ps1');
      await f.parent.create(recursive: true);
      if (!await f.exists() || await f.readAsString() != script) await f.writeAsString(script);
      final p = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        f.path,
        '-Words',
        words.join('|'),
      ], mode: ProcessStartMode.detachedWithStdio);
      _proc = p;
      _paused = false;
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (l) {
              if (l.contains('"wake"') && !_paused) {
                _paused = true; // le script s'est mis en pause tout seul
                onWake();
              }
            },
            onDone: () => _proc == p ? _proc = null : null,
            onError: (_) {},
          );
      unawaited(p.stderr.drain<void>().catchError((_) {}));
    } catch (_) {
      _proc = null;
    }
  }

  void _send(String cmd) {
    try {
      _proc?.stdin.writeln(cmd);
    } catch (_) {}
  }

  /// Pendant que Clicky écoute ou parle.
  void pause() {
    if (_proc == null || _paused) return;
    _paused = true;
    _send('pause');
  }

  void resume() {
    if (_proc == null || !_paused) return;
    _paused = false;
    _send('resume');
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    if (p == null) return;
    try {
      p.stdin.writeln('quit');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      p.kill();
    } catch (_) {}
  }

  @visibleForTesting
  static const script = r'''
param([string]$Words = 'jarvis')
$ErrorActionPreference = 'Stop'
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput())
$out.AutoFlush = $true
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
  $asTaskOp = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $asTaskAction = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
  function AwaitOp($op, [Type]$type) { $t = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); $null = $t.Wait(-1); return $t.Result }
  function AwaitAction($a) { $t = $asTaskAction.Invoke($null, @($a)); $null = $t.Wait(-1) }
  $null = [Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]
  $langs = @([Windows.Media.SpeechRecognition.SpeechRecognizer]::SupportedGrammarLanguages)
  $pick = $langs | Where-Object { $_.LanguageTag -like 'fr*' } | Select-Object -First 1
  if ($pick) { $rec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer($pick) } else { $rec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer }
  $list = New-Object 'System.Collections.Generic.List[string]'
  foreach ($w in $Words.Split('|')) { if ($w.Trim()) { $list.Add($w.Trim()) } }
  $c = New-Object Windows.Media.SpeechRecognition.SpeechRecognitionListConstraint([System.Collections.Generic.IEnumerable[string]]$list, 'reveil')
  $rec.Constraints.Add($c)
  $compiled = AwaitOp ($rec.CompileConstraintsAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
  $session = $rec.ContinuousRecognitionSession
  $session.AutoStopSilenceTimeout = [TimeSpan]::FromDays(1)
  $null = Register-ObjectEvent -InputObject $session -EventName ResultGenerated -SourceIdentifier 'res'
  $null = Register-ObjectEvent -InputObject $session -EventName Completed -SourceIdentifier 'done'
  AwaitAction ($session.StartAsync())
  $script:on = $true
  $out.WriteLine('{"t":"ready"}')
} catch {
  $out.WriteLine('{"t":"error"}')
  exit 1
}
$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
$line = $in.ReadLineAsync()
while ($true) {
  if ($line.IsCompleted) {
    $cmd = $null
    try { $cmd = $line.Result } catch {}
    if ($null -eq $cmd -or $cmd.Trim() -eq 'quit') { break }
    $cmd = $cmd.Trim()
    if ($cmd -eq 'pause' -and $script:on) { try { AwaitAction ($session.StopAsync()) } catch {}; $script:on = $false }
    if ($cmd -eq 'resume' -and -not $script:on) { Start-Sleep -Milliseconds 300; try { AwaitAction ($session.StartAsync()); $script:on = $true } catch {} }
    $line = $in.ReadLineAsync()
  }
  foreach ($e in @(Get-Event -ErrorAction SilentlyContinue)) {
    try {
      if ($e.SourceIdentifier -eq 'res') {
        $r = $e.SourceEventArgs.Result
        $conf = [string]$r.Confidence
        if ($r.Status -eq [Windows.Media.SpeechRecognition.SpeechRecognitionResultStatus]::Success -and ($conf -eq 'High' -or $conf -eq 'Medium')) {
          try { AwaitAction ($session.StopAsync()) } catch {}
          $script:on = $false
          $out.WriteLine('{"t":"wake"}')
        }
      } elseif ($e.SourceIdentifier -eq 'done' -and $script:on) {
        try { AwaitAction ($session.StartAsync()) } catch {}
      }
    } catch {}
    Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 40
}
try { if ($script:on) { AwaitAction ($session.StopAsync()) } } catch {}
''';
}
