import 'dart:io';

import 'package:flutter/foundation.dart';

import 'module_store.dart';

/// Raccourcis pour lancer Mon Hub sans chercher le dossier.
///
/// Windows : Bureau + menu Démarrer (et, si on veut, démarrage de Windows).
/// Créés tout seuls au premier lancement, et réparés automatiquement si le
/// dossier de Mon Hub change (nouvelle version décompressée ailleurs,
/// dossier déplacé…). Le vrai dossier du Bureau est demandé à Windows : ça
/// marche aussi quand le Bureau est synchronisé par OneDrive.
/// Linux : une entrée dans le menu des applications.
class AppShortcuts {
  AppShortcuts._();

  static const _targetKey = 'shortcut.target';
  static const _startupKey = 'shortcut.startup';

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  static String get _exe => Platform.resolvedExecutable;

  static bool get startup => ModuleStore.global.getBool(_startupKey) ?? false;

  /// Au démarrage : crée ou répare les raccourcis si besoin.
  static Future<void> ensure() async {
    if (!supported) return;
    // En développement (« flutter run »), on ne touche à rien.
    if (kDebugMode) return;
    if (ModuleStore.global.getString(_targetKey) == _exe) return;
    if (await create()) await ModuleStore.global.setString(_targetKey, _exe);
  }

  /// (Re)crée les raccourcis. Renvoie true si tout s'est bien passé.
  static Future<bool> create({bool? withStartup}) async {
    if (!supported) return false;
    final atStartup = withStartup ?? startup;
    try {
      if (Platform.isWindows) return await _windows(atStartup);
      return await _linux();
    } catch (e) {
      debugPrint('Raccourcis : $e');
      return false;
    }
  }

  static Future<void> setStartup(bool v) async {
    await ModuleStore.global.setBool(_startupKey, v);
    await create(withStartup: v);
  }

  static String _ps(String s) => "'${s.replaceAll("'", "''")}'";

  static Future<bool> _windows(bool atStartup) async {
    final r = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Command',
      windowsScript(_exe, atStartup),
    ]);
    if (r.exitCode != 0) debugPrint('Raccourcis : ${r.stderr}');
    return r.exitCode == 0;
  }

  /// Script PowerShell qui crée les raccourcis vers [exe].
  @visibleForTesting
  static String windowsScript(String exe, bool atStartup) {
    final dir = exe.substring(0, exe.lastIndexOf(RegExp(r'[\\/]')));
    String link(String folder) =>
        '\$s=\$sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath($folder)) \'Mon Hub.lnk\'));'
        '\$s.TargetPath=${_ps(exe)};\$s.WorkingDirectory=${_ps(dir)};'
        '\$s.IconLocation=${_ps('$exe,0')};\$s.Description=\'Mon Hub\';\$s.Save();';
    final script =
        StringBuffer(r"$ErrorActionPreference='Stop';$sh=New-Object -ComObject WScript.Shell;")
          ..write(link("'Desktop'"))
          ..write(link("'Programs'"));
    final startupLink = "(Join-Path ([Environment]::GetFolderPath('Startup')) 'Mon Hub.lnk')";
    script.write(
      atStartup
          ? link("'Startup'")
          : 'if(Test-Path $startupLink){Remove-Item $startupLink -Force};',
    );
    return '$script';
  }

  static Future<bool> _linux() async {
    final home = Platform.environment['HOME'];
    if (home == null) return false;
    final exe = _exe;
    final dir = File(exe).parent.path;
    final apps = Directory('$home/.local/share/applications');
    await apps.create(recursive: true);
    await File('${apps.path}/mon-hub.desktop').writeAsString('''
[Desktop Entry]
Type=Application
Name=Mon Hub
Comment=Agenda, École Directe, mails, Discord, Roblox… au même endroit
Exec="$exe"
Path=$dir
Icon=$dir/data/flutter_assets/assets/logo.png
Terminal=false
Categories=Utility;Education;
''');
    return true;
  }
}
