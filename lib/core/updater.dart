import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'version.dart';

/// Une nouvelle version publiée sur GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.number,
    required this.url,
    this.size = 0,
    this.sha256,
    this.notes = '',
  });

  /// « v1.23 ».
  final String tag;
  final int number;

  /// Adresse du fichier MonHub-Windows.zip.
  final String url;
  final int size;

  /// Empreinte annoncée par GitHub (vérifiée après le téléchargement).
  final String? sha256;
  final String notes;

  /// Lit la réponse de l'API GitHub (dernière release).
  static UpdateInfo? fromRelease(Map<String, dynamic> j, {String asset = 'MonHub-Windows.zip'}) {
    final tag = '${j['tag_name'] ?? ''}';
    final n = Updater.versionNumber(tag);
    if (n == null) return null;
    final a = ((j['assets'] as List?) ?? const [])
        .whereType<Map>()
        .where((x) => x['name'] == asset)
        .firstOrNull;
    if (a == null) return null;
    final digest = '${a['digest'] ?? ''}';
    return UpdateInfo(
      tag: tag,
      number: n,
      url: '${a['browser_download_url']}',
      size: (a['size'] as num?)?.toInt() ?? 0,
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
      notes: '${j['body'] ?? ''}'.trim(),
    );
  }
}

/// Mises à jour automatiques (Windows) : Mon Hub regarde régulièrement s'il
/// existe une version plus récente sur GitHub. Si oui, l'appli se met en
/// pause, un écran de téléchargement s'affiche, la nouvelle version est
/// téléchargée, vérifiée, installée par-dessus, et Mon Hub redémarre.
///
/// Le dépôt se change à la compilation (`--dart-define=UPDATE_REPO=compte/depot`)
/// pour distribuer l'appli sous un autre nom.
class Updater extends ChangeNotifier {
  Updater._();
  static final instance = Updater._();

  static const repo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'Shideyx/mon-hub');

  /// Seulement l'appli Windows compilée par GitHub (pas les versions de
  /// développement).
  static bool get supported => !kIsWeb && Platform.isWindows && current != null;

  /// Numéro de la version installée (v1.22 → 22), ou null.
  static int? get current => versionNumber(appVersion);

  static int? versionNumber(String tag) {
    final m = RegExp(r'^v?\d+\.(\d+)$').firstMatch(tag.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Nouvelle version trouvée (l'écran de mise à jour s'affiche).
  UpdateInfo? available;

  /// « Plus tard » : on ne repropose pas avant le prochain démarrage.
  bool postponed = false;

  /// 0..1 pendant le téléchargement.
  double? progress;
  int received = 0;
  String status = '';
  String? error;
  bool busy = false;

  /// Appelé juste avant de quitter pour installer (arrêter Clicky partout…).
  Future<void> Function()? beforeInstall;

  Timer? _timer;
  http.Client? _client;

  bool get showing => available != null && !postponed;

  void start() {
    if (!supported || _timer != null) return;
    unawaited(check());
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => check());
  }

  /// Regarde sur GitHub. Renvoie la nouvelle version, ou null.
  Future<UpdateInfo?> check({bool manual = false}) async {
    if (!supported) return null;
    if (busy || (postponed && !manual)) return available;
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
            headers: {'accept': 'application/vnd.github+json', 'user-agent': 'MonHub-Updater'},
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final info = UpdateInfo.fromRelease(
        jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>,
      );
      if (info == null || info.number <= (current ?? 1 << 30)) return null;
      available = info;
      if (manual) postponed = false;
      notifyListeners();
      // Directement : l'appli se met en pause et télécharge.
      if (!postponed) unawaited(install());
      return info;
    } catch (_) {
      return null;
    }
  }

  void later() {
    postponed = true;
    _client?.close();
    _client = null;
    busy = false;
    notifyListeners();
  }

  void _set({String? status, double? progress, String? error}) {
    if (status != null) this.status = status;
    this.progress = progress;
    this.error = error;
    notifyListeners();
  }

  /// Télécharge, vérifie, prépare et lance l'installation.
  Future<void> install() async {
    final info = available;
    if (info == null || busy) return;
    busy = true;
    error = null;
    received = 0;
    final sep = Platform.pathSeparator;
    final work = Directory('${Directory.systemTemp.path}${sep}MonHub-maj$sep${info.tag}');
    try {
      await work.create(recursive: true);
      final zip = File('${work.path}${sep}MonHub-Windows.zip');

      // 1. Téléchargement (avec la progression).
      _set(status: 'Téléchargement de ${info.tag}…', progress: 0);
      final client = _client = http.Client();
      final res = await client.send(
        http.Request('GET', Uri.parse(info.url))..headers['user-agent'] = 'MonHub-Updater',
      );
      if (res.statusCode != 200) throw 'Téléchargement refusé par GitHub (code ${res.statusCode})';
      final total = res.contentLength ?? info.size;
      final sink = zip.openWrite();
      try {
        await for (final chunk in res.stream) {
          if (postponed) throw 'Mise à jour reportée';
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) _set(progress: (received / total).clamp(0, 1).toDouble());
        }
      } finally {
        await sink.close();
        client.close();
        _client = null;
      }

      // 2. Vérification : le fichier est bien celui publié.
      _set(status: 'Vérification du fichier…', progress: null);
      if (info.sha256 != null) {
        final digest = sha256.convert(await zip.readAsBytes()).toString();
        if (digest != info.sha256) {
          throw 'Le fichier téléchargé est abîmé (empreinte différente) : réessaie';
        }
      }

      // 3. Décompression.
      _set(status: 'Préparation de la nouvelle version…', progress: null);
      final out = Directory('${work.path}${sep}app');
      if (await out.exists()) await out.delete(recursive: true);
      await extractFileToDisk(zip.path, out.path);
      final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
      var src = out.path;
      if (!await File('$src$sep$exeName').exists()) {
        // Zip avec un dossier à l'intérieur.
        final sub = (await out.list().toList())
            .where((e) => e is Directory && File('${e.path}$sep$exeName').existsSync())
            .firstOrNull;
        if (sub == null) throw 'La nouvelle version est incomplète ($exeName introuvable)';
        src = sub.path;
      }

      // 4. Installation : un petit script remplace les fichiers une fois
      // Mon Hub fermé, puis le relance.
      _set(status: 'Installation : Mon Hub va redémarrer…', progress: null);
      final dst = File(Platform.resolvedExecutable).parent.path;
      final script = File('${work.path}${sep}installer.ps1');
      await script.writeAsString(installScript);
      await beforeInstall?.call();
      await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-Src',
        src,
        '-Dst',
        dst,
        '-Exe',
        exeName,
        '-ParentPid',
        '$pid',
      ], mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      exit(0);
    } catch (e) {
      busy = false;
      if (postponed) return;
      _set(status: '', progress: null, error: '$e');
    }
  }

  /// Remplace les fichiers de Mon Hub (une fois fermé) et le relance. Si le
  /// dossier est protégé (Program Files…), Windows demande l'autorisation.
  @visibleForTesting
  static const installScript = r'''
param([string]$Src, [string]$Dst, [string]$Exe = 'hub.exe', [int]$ParentPid = 0)
$ErrorActionPreference = 'Continue'
if ($ParentPid -gt 0) { try { Wait-Process -Id $ParentPid -Timeout 30 -ErrorAction SilentlyContinue } catch {} }
$name = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Dst, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
$ok = $false
for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
  robocopy "$Src" "$Dst" /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -lt 8) { $ok = $true } else { Start-Sleep -Seconds 2 }
}
$target = Join-Path $Dst $Exe
if ($ok) {
  Start-Process -FilePath $target -ArgumentList '--updated'
} else {
  $cmd = "robocopy '$Src' '$Dst' /E /R:3 /W:1; Start-Process '$target' -ArgumentList '--updated'"
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command $cmd"
}
''';
}
