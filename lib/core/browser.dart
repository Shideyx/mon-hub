import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'module_store.dart';

/// Ouvre les pages web : dans **Google Chrome** s'il est installé (réglage
/// par défaut), sinon dans le navigateur par défaut de Windows.
class Browser {
  Browser._();

  static const _key = 'app.browser';

  /// 'chrome' (par défaut) ou 'defaut'.
  static String get choice {
    try {
      return ModuleStore.global.getString(_key) ?? 'chrome';
    } catch (_) {
      return 'chrome';
    }
  }

  static Future<void> setChoice(String v) => ModuleStore.global.setString(_key, v);

  static String? _chrome;
  static bool _looked = false;

  /// Où est installé Chrome (null s'il ne l'est pas).
  static String? chromePath() {
    if (_looked) return _chrome;
    _looked = true;
    if (kIsWeb || !Platform.isWindows) return null;
    final env = Platform.environment;
    for (final base in [env['ProgramFiles'], env['ProgramFiles(x86)'], env['LOCALAPPDATA']]) {
      if (base == null) continue;
      final p = '$base\\Google\\Chrome\\Application\\chrome.exe';
      if (File(p).existsSync()) return _chrome = p;
    }
    return null;
  }

  /// Ouvre un lien. Les pages web vont dans Chrome ; le reste (spotify:,
  /// ms-settings:, fichiers…) dans l'appli qui convient.
  static Future<bool> open(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final web = uri.scheme == 'http' || uri.scheme == 'https';
    if (web && choice == 'chrome') {
      final chrome = chromePath();
      if (chrome != null) {
        try {
          await Process.start(chrome, [uri.toString()], mode: ProcessStartMode.detached);
          return true;
        } catch (_) {}
      }
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
