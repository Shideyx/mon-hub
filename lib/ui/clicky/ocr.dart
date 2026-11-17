import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';

/// Lecture du texte à l'écran (OCR) avec la reconnaissance de texte
/// intégrée à Windows (Windows.Media.Ocr), hors ligne et sans rien
/// installer. Sert quand le texte est trop petit pour être bien vu.
class ClickyOcr {
  ClickyOcr._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Texte lu sur une image PNG (vide si rien / indisponible).
  static Future<String> read(Uint8List png) async {
    if (!supported) return '';
    final dir = Directory(ClaudeBridge.folder ?? Directory.systemTemp.path);
    await dir.create(recursive: true);
    final sep = Platform.pathSeparator;
    final img = File('${dir.path}${sep}clicky-ocr.png');
    final script = File('${dir.path}${sep}clicky-ocr.ps1');
    try {
      await img.writeAsBytes(png, flush: true);
      if (!await script.exists() || await script.readAsString() != _script) {
        await script.writeAsString(_script);
      }
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Path',
        img.path,
      ], stdoutEncoding: utf8).timeout(const Duration(seconds: 25));
      return '${r.stdout}'.trim();
    } catch (_) {
      return '';
    } finally {
      try {
        await img.delete();
      } catch (_) {}
    }
  }

  static const _script = r'''
param([string]$Path)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asTask = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
  $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  $null = $t.Wait(-1)
  return $t.Result
}
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { exit 0 }
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
foreach ($line in $result.Lines) { [Console]::Out.WriteLine($line.Text) }
''';
}
