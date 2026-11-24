import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Ouvre une appli, un fichier, un dossier ou un lien **sans passer par
/// l'invite de commandes**.
///
/// Avant, Mon Hub lançait `cmd /c start "" <cible>` : `cmd` relit la ligne,
/// donc une cible comme `notepad & calc` (ou `x | powershell …`) lançait une
/// deuxième commande, sans aucune permission. Sur Windows on demande
/// maintenant directement au système d'ouvrir la cible (ShellExecute),
/// comme un double-clic : rien n'est interprété.
class SafeOpen {
  SafeOpen._();

  /// Liens que Mon Hub ouvre sans demander (sites, réglages, applis connues).
  static const safeSchemes = {
    'http',
    'https',
    'mailto',
    'ms-settings',
    'spotify',
    'steam',
    'roblox',
    'roblox-studio',
    'roblox-player',
    'discord',
    'msteams',
    'zoommtg',
    'whatsapp',
    'tel',
  };

  /// Extensions qui **lancent du code** quand on les ouvre (programmes,
  /// scripts, raccourcis, macros, images disque…).
  static const runnable = {
    'exe',
    'com',
    'bat',
    'cmd',
    'ps1',
    'psm1',
    'psd1',
    'vbs',
    'vbe',
    'js',
    'jse',
    'wsf',
    'wsh',
    'hta',
    'scr',
    'pif',
    'cpl',
    'msi',
    'msp',
    'mst',
    'lnk',
    'url',
    'reg',
    'inf',
    'jar',
    'appx',
    'msix',
    'msixbundle',
    'appref-ms',
    'application',
    'library-ms',
    'search-ms',
    'searchconnector-ms',
    'settingcontent-ms',
    'diagcab',
    'chm',
    'iso',
    'img',
    'vhd',
    'vhdx',
    'xll',
    'docm',
    'xlsm',
    'pptm',
    'dotm',
    'xlam',
    'ppam',
    'sh',
    'command',
    'scpt',
    'app',
    'run',
    'py',
    'pyw',
    'gadget',
  };

  /// Le nom seul d'une appli (« notepad », « spotify », « calc ») : pas de
  /// chemin, pas d'extension, pas de lien.
  static bool _appName(String t) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}$').hasMatch(t) && !t.contains('.');

  /// Vrai si ouvrir [target] peut lancer un programme ou un script inconnu
  /// (il faut alors l'accord de la personne), ou passer par le réseau local
  /// (`\\serveur\partage`, faille classique de Windows).
  static bool risky(String target) {
    final t = target.trim();
    if (t.isEmpty) return false;
    final low = t.toLowerCase();
    // Caractères qui n'ont rien à faire dans une cible (anciennes injections).
    if (RegExp(r'[&|<>^`\r\n]').hasMatch(t) && !low.startsWith('http')) return true;
    if (low.startsWith(r'\\') || low.startsWith('//')) return true;
    // « C:\… » n'est pas un lien : il faut au moins deux lettres avant « : ».
    final scheme = RegExp(r'^([a-z][a-z0-9+.-]{1,30}):').firstMatch(low)?.group(1);
    if (scheme != null) return !safeSchemes.contains(scheme);
    if (_appName(t)) return false;
    final ext = RegExp(r'\.([a-z0-9-]{1,20})$').firstMatch(low.replaceAll(RegExp(r'[\\/]+$'), ''))?.group(1);
    return ext != null && runnable.contains(ext);
  }

  /// Ouvre [target] comme un double-clic. Renvoie false si Windows refuse.
  static Future<bool> launch(String target) async {
    final t = target.trim();
    if (t.isEmpty || kIsWeb) return false;
    if (Platform.isWindows) {
      return using((a) {
        final r = ShellExecute(
          null,
          'open'.toPcwstr(allocator: a),
          t.toPcwstr(allocator: a),
          null,
          null,
          SW_SHOWNORMAL,
        );
        // Au-delà de 32 : réussi (voir la doc de ShellExecute).
        return r.address > 32;
      });
    }
    try {
      if (Platform.isMacOS) {
        final isApp = !t.contains('/') && !t.contains(':');
        await Process.start('open', isApp ? ['-a', t] : [t], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [t], mode: ProcessStartMode.detached);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
