import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'updater.dart';

/// Où vit Mon Hub sur le PC, et où il garde tes connexions.
///
/// Le problème d'avant : Mon Hub se lançait souvent **depuis l'intérieur du
/// zip** (WinRAR le décompresse dans un dossier temporaire
/// `AppData\Local\Temp\Rar$…`). Le navigateur intégré rangeait tes connexions
/// (Discord, Instagram, Google Docs, YouTube…) **à côté du programme**, donc
/// dans ce dossier temporaire : à chaque nouveau zip, ou quand Windows faisait
/// le ménage, tout était perdu et il fallait se reconnecter partout. Et chaque
/// zip ouvert faisait une copie de plus de Mon Hub.
///
/// Maintenant :
/// * les connexions sont rangées dans **un seul dossier fixe**
///   (`%LOCALAPPDATA%\MonHub\WebView2`), quel que soit l'endroit d'où Mon Hub
///   est lancé (les anciennes sont recopiées une fois) ;
/// * lancé depuis un dossier temporaire ou les Téléchargements, Mon Hub
///   **s'installe tout seul** dans `%LOCALAPPDATA%\Programs\Mon Hub` (si la
///   copie lancée est plus récente que celle installée) et redémarre de là ;
///   une vieille copie relancée par erreur ouvre simplement la bonne.
///   Rien n'est jamais supprimé.
class AppInstall {
  AppInstall._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Nom du dossier d'installation (dans `%LOCALAPPDATA%\Programs`).
  static const folderName = 'Mon Hub';

  /// Fichier qui dit quelle version est installée.
  static const versionFile = 'version-monhub.txt';

  static String get _sep => Platform.pathSeparator;

  static String? get _localAppData => Platform.environment['LOCALAPPDATA'];

  /// Dossier d'installation (null si Windows ne le donne pas).
  static String? get installDir {
    final base = _localAppData;
    return base == null || base.isEmpty ? null : '$base${_sep}Programs$_sep$folderName';
  }

  /// Le dossier fixe des connexions du navigateur intégré.
  static String? get webDataDir {
    final base = _localAppData;
    return base == null || base.isEmpty ? null : '$base${_sep}MonHub${_sep}WebView2';
  }

  /// Dossier d'où un programme ne devrait pas tourner : un dossier temporaire
  /// (l'intérieur d'un zip ouvert avec WinRAR / 7-Zip / Windows) ou les
  /// Téléchargements. Sans Windows : testable.
  static bool isTemporary(String exePath) {
    final p = exePath.replaceAll('/', r'\').toLowerCase();
    if (p.contains(r'\appdata\local\temp\') || p.contains(r'\windows\temp\')) return true;
    if (RegExp(r'\\(rar\$|7z[a-z0-9]*\.tmp|temp\d*_)').hasMatch(p)) return true;
    return RegExp(r'\\(downloads|téléchargements)\\').hasMatch(p);
  }

  /// Le même dossier ? (casse et séparateurs ignorés).
  static bool sameDir(String a, String b) {
    String n(String s) => s.replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();
    return n(a) == n(b);
  }

  /// Ce qu'il faut faire au démarrage. Sans Windows : testable.
  /// * [here] : version de la copie lancée (null = développement) ;
  /// * [installed] : version déjà installée (null = rien d'installé).
  static InstallStep decide({
    required String exePath,
    required String? installDir,
    required int? here,
    required int? installed,
    required bool installedExists,
  }) {
    if (here == null || installDir == null) return InstallStep.stay;
    final cut = exePath.lastIndexOf(RegExp(r'[\\/]'));
    final dir = cut <= 0 ? exePath : exePath.substring(0, cut);
    if (sameDir(dir, installDir)) return InstallStep.stay;
    if (!isTemporary(exePath)) return InstallStep.stay;
    // Une copie installée plus récente (ou la même) : c'est elle qu'on ouvre.
    if (installedExists && installed != null && installed >= here) return InstallStep.openInstalled;
    return InstallStep.install;
  }

  /// Tout au début de `main`, pour **tous** les programmes de Mon Hub (même
  /// dossier, sinon WebView2 refuse de s'ouvrir) : les connexions vont dans
  /// le dossier fixe.
  static void useStableWebData() {
    if (!supported) return;
    final dir = webDataDir;
    if (dir == null) return;
    const name = 'WEBVIEW2_USER_DATA_FOLDER';
    // Déjà réglé par le programme qui nous a lancés : on garde le même.
    if ((Platform.environment[name] ?? '').isNotEmpty) return;
    try {
      using((a) => SetEnvironmentVariable(name.toPcwstr(allocator: a), dir.toPcwstr(allocator: a)));
    } catch (_) {}
  }

  /// Dossiers de cache du navigateur : inutiles à recopier (ils se refont).
  static const _caches = {
    'cache',
    'code cache',
    'gpucache',
    'dawncache',
    'dawngraphitecache',
    'dawnwebgpucache',
    'grshadercache',
    'shadercache',
    'graphitedawncache',
    'crashpad',
    'cachestorage',
    'scriptcache',
  };

  /// Ce fichier (chemin relatif au profil) se recopie ? Sans Windows : testable.
  static bool worthCopying(String relative) {
    final parts = relative.replaceAll('/', r'\').toLowerCase().split(r'\');
    if (parts.any(_caches.contains)) return false;
    final name = parts.last;
    // Verrous du navigateur ouvert : jamais recopiés.
    return name != 'lockfile' && name != 'singletonlock';
  }

  /// Une fois : recopie les connexions rangées à côté du programme (ancien
  /// endroit) dans le dossier fixe. Avant que le navigateur intégré s'ouvre.
  static Future<void> migrateWebData() async {
    if (!supported) return;
    final dst = webDataDir;
    if (dst == null) return;
    try {
      final target = Directory(dst);
      if (await target.exists() && !(await target.list().isEmpty)) return;
      final exe = File(Platform.resolvedExecutable);
      final name = exe.uri.pathSegments.last;
      final old = Directory('${exe.parent.path}$_sep$name.WebView2');
      if (!await old.exists()) return;
      await target.create(recursive: true);
      await for (final e in old.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = e.path.substring(old.path.length).replaceFirst(RegExp(r'^[\\/]+'), '');
        if (!worthCopying(rel)) continue;
        try {
          final to = File('$dst$_sep$rel');
          await to.parent.create(recursive: true);
          await e.copy(to.path);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static int? _readInstalled(String dir) {
    try {
      final f = File('$dir$_sep$versionFile');
      if (!f.existsSync()) return null;
      return Updater.versionNumber(f.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  /// Note la version installée (à chaque démarrage depuis le bon dossier).
  static Future<void> stamp(String tag) async {
    if (!supported || Updater.versionNumber(tag) == null) return;
    final dir = installDir;
    final here = File(Platform.resolvedExecutable).parent.path;
    if (dir == null || !sameDir(here, dir)) return;
    try {
      await File('$here$_sep$versionFile').writeAsString(tag);
    } catch (_) {}
  }

  /// Lancé depuis un dossier temporaire : installe (ou ouvre la copie
  /// installée) puis relance. Renvoie true si ce programme doit s'arrêter.
  static Future<bool> moveIfTemporary(String tag) async {
    if (!supported || kDebugMode) return false;
    final dir = installDir;
    final exe = Platform.resolvedExecutable;
    final name = File(exe).uri.pathSegments.last;
    final installedExe = dir == null ? null : File('$dir$_sep$name');
    final step = decide(
      exePath: exe,
      installDir: dir,
      here: Updater.versionNumber(tag),
      installed: dir == null ? null : _readInstalled(dir),
      installedExists: installedExe?.existsSync() ?? false,
    );
    if (step == InstallStep.stay || dir == null || installedExe == null) return false;
    try {
      if (step == InstallStep.install) {
        final src = File(exe).parent.path;
        await Directory(dir).create(recursive: true);
        await _copyApp(src, dir);
        await File('$dir$_sep$versionFile').writeAsString(tag);
      }
      await Process.start(installedExe.path, const ['--relance'], workingDirectory: dir, mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      // Installation impossible (disque plein, droits…) : on reste ici.
      debugPrint('Installation : $e');
      return false;
    }
  }

  /// On peut relancer Mon Hub d'un bouton (Windows, version compilée).
  static bool get canRestart => supported && !kDebugMode;

  /// Redémarre Mon Hub (la nouvelle copie attend que celle-ci soit partie).
  static Future<void> restart() async {
    if (!canRestart) return;
    final exe = Platform.resolvedExecutable;
    try {
      await Process.start(exe, const ['--relance'], workingDirectory: File(exe).parent.path, mode: ProcessStartMode.detached);
    } catch (_) {
      return;
    }
    exit(0);
  }

  /// Copie le programme (sans le profil du navigateur, qui a son dossier).
  /// Un fichier en cours d'utilisation est renommé au lieu d'être écrasé
  /// (comme la mise à jour).
  static Future<void> _copyApp(String src, String dst) async {
    final stage = Directory('${Directory.systemTemp.path}${_sep}MonHub-installation');
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create(recursive: true);
    final from = Directory(src);
    await for (final e in from.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(src.length).replaceFirst(RegExp(r'^[\\/]+'), '');
      final top = rel.split(RegExp(r'[\\/]')).first.toLowerCase();
      if (top.endsWith('.webview2') || rel.contains(Updater.oldSuffix)) continue;
      final to = File('${stage.path}$_sep$rel');
      await to.parent.create(recursive: true);
      await e.copy(to.path);
    }
    await Updater.replaceInPlace(stage.path, dst);
    try {
      await stage.delete(recursive: true);
    } catch (_) {}
  }
}

/// Ce que fait Mon Hub au démarrage.
enum InstallStep {
  /// Il est déjà au bon endroit (ou version de développement).
  stay,

  /// Il s'installe (copie plus récente), puis redémarre de là.
  install,

  /// Une copie installée plus récente existe : c'est elle qui s'ouvre.
  openInstalled,
}
