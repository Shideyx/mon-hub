import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/claude_bridge.dart';
import '../../core/powershell.dart';
import '../../ui/clicky/win.dart';
import 'music_models.dart';

/// Ce qui joue sur le PC, lu dans Windows (les commandes multimédia du
/// système) : marche avec l'appli **Spotify**, **Deezer**, un navigateur…,
/// sans connexion ni clé. Donne le titre, l'artiste, l'album, la pochette,
/// la position, et permet lecture / pause / suivant / précédent.
class WindowsMediaSession {
  WindowsMediaSession(this.onChange);
  final void Function(NowPlaying? np) onChange;

  static bool get supported => !kIsWeb && Platform.isWindows;

  Process? _proc;
  Uint8List? _cover;
  String _coverKey = '';
  bool _stopped = false;

  /// Dernière erreur de Windows (affichée dans les réglages de la musique).
  String? error;
  final _errors = StringBuffer();

  /// Windows ne donne rien : on lit le titre de la fenêtre Spotify.
  bool fallback = false;
  Timer? _fallbackTimer;
  int _deaths = 0;

  Future<void> start() async {
    if (!supported || _proc != null) return;
    _stopped = false;
    if (_deaths >= 2) return _startFallback();
    try {
      final base = ClaudeBridge.folder ?? Directory.systemTemp.path;
      await Directory(base).create(recursive: true);
      final thumb = '$base${Platform.pathSeparator}musique-pochette.bin';
      _errors.clear();
      // Sans fichier .ps1 : marche même si Windows bloque les scripts.
      final p = await PowerShell.start(script, {'Thumb': thumb});
      _proc = p;
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _line(l, thumb), onDone: () => _died(p), onError: (_) => _died(p));
      p.stderr.transform(utf8.decoder).listen((e) {
        if (_errors.length < 3000) _errors.write(e);
      }, onError: (_) {});
    } catch (e) {
      _proc = null;
      error = '$e';
      _startFallback();
    }
  }

  /// Repli : « Artiste - Titre » dans le titre de la fenêtre de Spotify, et
  /// les touches multimédia du clavier pour les commandes.
  void _startFallback() {
    if (fallback) return;
    fallback = true;
    _fallbackTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      try {
        final titles = Win.titlesOf('Spotify.exe');
        final np = parseSpotifyTitle(titles);
        onChange(np);
      } catch (_) {}
    });
  }

  /// Titre de la fenêtre Spotify → morceau (null si en pause / fermé).
  static NowPlaying? parseSpotifyTitle(List<String> titles) {
    for (final t in titles) {
      final i = t.indexOf(' - ');
      if (i <= 0 || t.startsWith('Spotify')) continue;
      return NowPlaying(
        title: t.substring(i + 3).trim(),
        artist: t.substring(0, i).trim(),
        playing: true,
        app: 'Spotify.exe',
        at: DateTime.now(),
      );
    }
    return null;
  }

  void _died(Process p) {
    if (_proc != p) return;
    _proc = null;
    _deaths++;
    final e = PowerShell.firstError('$_errors');
    if (e.isNotEmpty) error = e;
    // Relance (PowerShell fermé, veille…), sauf si on a arrêté exprès.
    if (!_stopped) Timer(const Duration(seconds: 5), start);
  }

  Future<void> _line(String line, String thumbPath) async {
    final Map m;
    try {
      final j = jsonDecode(line.trim());
      if (j is! Map) return;
      m = j;
    } catch (_) {
      return;
    }
    if (m['t'] == 'error') {
      error = '${m['msg'] ?? 'erreur'}';
      _deaths = 2; // inutile d'insister : on passe au repli
      return _startFallback();
    }
    if (m['t'] == 'none') return onChange(null);
    if (m['t'] != 'np') return;
    final title = '${m['title'] ?? ''}'.trim();
    if (title.isEmpty) return onChange(null);
    final key = '${m['thumbKey'] ?? ''}';
    if (key.isNotEmpty && key != _coverKey) {
      _coverKey = key;
      try {
        _cover = await File(thumbPath).readAsBytes();
      } catch (_) {
        _cover = null;
      }
    } else if (key.isEmpty) {
      _cover = null;
      _coverKey = '';
    }
    final dur = (m['dur'] as num?)?.toDouble() ?? 0;
    onChange(
      NowPlaying(
        title: title,
        artist: '${m['artist'] ?? ''}',
        album: '${m['album'] ?? ''}',
        albumArtist: '${m['albumArtist'] ?? ''}',
        coverBytes: _cover,
        position: Duration(milliseconds: (((m['pos'] as num?) ?? 0) * 1000).round()),
        duration: dur > 0 ? Duration(milliseconds: (dur * 1000).round()) : null,
        playing: m['status'] == 'Playing',
        app: '${m['app'] ?? ''}',
        at: m['upd'] is num
            ? DateTime.fromMillisecondsSinceEpoch((m['upd'] as num).toInt())
            : DateTime.now(),
        trackNumber: (m['track'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  void _send(String cmd) {
    try {
      _proc?.stdin.writeln(cmd);
    } catch (_) {}
  }

  void toggle() => _proc != null ? _send('toggle') : Win.mediaKey('toggle');
  void next() => _proc != null ? _send('next') : Win.mediaKey('next');
  void previous() => _proc != null ? _send('prev') : Win.mediaKey('prev');

  Future<void> stop() async {
    _stopped = true;
    _fallbackTimer?.cancel();
    fallback = false;
    final p = _proc;
    _proc = null;
    try {
      p?.stdin.writeln('quit');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      p?.kill();
    } catch (_) {}
  }

  /// Script PowerShell : lit la session multimédia de Windows (WinRT
  /// GlobalSystemMediaTransportControlsSessionManager) chaque seconde, écrit
  /// une ligne JSON, et obéit à toggle / next / prev / quit.
  @visibleForTesting
  static const script = r'''
param([string]$Thumb)
$ErrorActionPreference = 'Stop'
$out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding $false))
$out.AutoFlush = $true
function Say($o) {
  $j = $o | ConvertTo-Json -Compress
  $j = [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
  $out.WriteLine($j)
}
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
  $asTaskOp = $methods | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  function Await($op, [Type]$type) { $t = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); $null = $t.Wait(-1); return $t.Result }
  $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
} catch {
  Say @{ t = 'error'; msg = $_.Exception.Message }
  exit 1
}
$in = New-Object System.IO.StreamReader([Console]::OpenStandardInput())
$line = $in.ReadLineAsync()
$lastThumb = ''
$thumbKey = ''
while ($true) {
  if ($line.IsCompleted) {
    $cmd = $null
    try { $cmd = $line.Result } catch {}
    if ($null -eq $cmd -or $cmd.Trim() -eq 'quit') { break }
    try {
      $s = $mgr.GetCurrentSession()
      if ($s) {
        switch ($cmd.Trim()) {
          'toggle' { $null = Await ($s.TryTogglePlayPauseAsync()) ([bool]) }
          'next' { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
          'prev' { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
        }
      }
    } catch {}
    $line = $in.ReadLineAsync()
  }
  try {
    $s = $mgr.GetCurrentSession()
    if ($null -eq $s) {
      Say @{ t = 'none' }
    } else {
      $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
      $info = $s.GetPlaybackInfo()
      $tl = $s.GetTimelineProperties()
      $id = "$($p.Artist)|$($p.AlbumTitle)|$($p.Title)"
      if ($id -ne $lastThumb) {
        $lastThumb = $id
        $thumbKey = ''
        if ($p.Thumbnail) {
          try {
            $stream = Await ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
            $size = [uint32]$stream.Size
            $reader = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
            $null = Await ($reader.LoadAsync($size)) ([uint32])
            $bytes = New-Object byte[] $size
            $reader.ReadBytes($bytes)
            [System.IO.File]::WriteAllBytes($Thumb, $bytes)
            $thumbKey = [string][DateTime]::Now.Ticks
          } catch {}
        }
      }
      Say @{
        t = 'np'; app = $s.SourceAppUserModelId; title = $p.Title; artist = $p.Artist;
        album = $p.AlbumTitle; albumArtist = $p.AlbumArtist; track = $p.TrackNumber;
        status = [string]$info.PlaybackStatus; pos = $tl.Position.TotalSeconds;
        dur = $tl.EndTime.TotalSeconds; upd = $tl.LastUpdatedTime.ToUnixTimeMilliseconds();
        thumbKey = $thumbKey
      }
    }
  } catch {}
  Start-Sleep -Milliseconds 1000
}
''';
}
