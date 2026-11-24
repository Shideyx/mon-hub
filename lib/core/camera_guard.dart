import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hub_module.dart';
import 'module_store.dart';
import 'perf.dart';
import 'powershell.dart';

/// Une appli qui a utilisé (ou utilise) la caméra ou le micro.
@immutable
class SensorUse {
  const SensorUse({required this.key, required this.app, required this.active, this.at});

  /// La clé du registre (chemin du programme, ou nom du paquet Windows).
  final String key;

  /// Le nom lisible (« Discord », « Chrome », « Appareil photo »).
  final String app;

  /// Vrai si l'appli l'utilise **en ce moment**.
  final bool active;

  /// Début (si c'est en cours) ou fin de la dernière utilisation.
  final DateTime? at;

  @override
  bool operator ==(Object other) => other is SensorUse && other.key == key && other.active == active;

  @override
  int get hashCode => Object.hash(key, active);
}

/// L'état de la caméra (ou du micro) : coupée ou non, et qui s'en sert.
@immutable
class SensorState {
  const SensorState({this.blocked = false, this.uses = const []});
  final bool blocked;
  final List<SensorUse> uses;

  List<SensorUse> get active => [
    for (final u in uses)
      if (u.active) u,
  ];

  /// Les dernières utilisations, la plus récente d'abord.
  List<SensorUse> get recent {
    final l = [...uses]..sort((a, b) => (b.at ?? DateTime(2000)).compareTo(a.at ?? DateTime(2000)));
    return l;
  }
}

/// Les règles, **sans Windows** : testables.
class CameraRules {
  const CameraRules._();

  /// Noms lisibles des applis les plus courantes.
  static const names = {
    'discord': 'Discord',
    'chrome': 'Chrome',
    'msedge': 'Edge',
    'firefox': 'Firefox',
    'zoom': 'Zoom',
    'teams': 'Teams',
    'ms-teams': 'Teams',
    'skype': 'Skype',
    'obs64': 'OBS',
    'obs': 'OBS',
    'whatsapp': 'WhatsApp',
    'snapchat': 'Snapchat',
    'windowscamera': 'Appareil photo',
    'microsoft.windowscamera': 'Appareil photo',
    'hub': 'Mon Hub',
    'roblox': 'Roblox',
    'robloxplayerbeta': 'Roblox',
    'steam': 'Steam',
    'vlc': 'VLC',
  };

  /// Les applis dont il est **normal** qu'elles ouvrent la caméra.
  static const expected = {
    'Discord',
    'Chrome',
    'Edge',
    'Firefox',
    'Zoom',
    'Teams',
    'Skype',
    'OBS',
    'WhatsApp',
    'Snapchat',
    'Appareil photo',
    'Mon Hub',
  };

  /// Nom lisible depuis la clé du registre.
  ///
  /// Windows écrit soit un chemin (`C:#Program Files#Zoom#bin#Zoom.exe`),
  /// soit le nom d'un paquet (`Microsoft.WindowsCamera_8wekyb3d8bbwe`).
  static String appName(String key) {
    var k = key.trim();
    if (k.isEmpty) return 'Une appli';
    if (k.contains('#') || k.contains(r'\')) {
      k = k.split(RegExp(r'[#\\]')).where((p) => p.isNotEmpty).last;
    } else if (k.contains('_')) {
      // Paquet Windows : « Microsoft.WindowsCamera_8wekyb3d8bbwe ».
      k = k.split('_').first;
    }
    final file = k.toLowerCase().replaceAll('.exe', '');
    final known = names[file] ?? names[file.split('.').last];
    if (known != null) return known;
    final plain = k.replaceAll('.exe', '').split('.').last;
    return plain.isEmpty ? 'Une appli' : plain[0].toUpperCase() + plain.substring(1);
  }

  /// Une appli dont on ne s'attend pas à ce qu'elle filme.
  static bool unexpected(String app) => !expected.contains(app);

  /// Date Windows (FILETIME, 100 ns depuis 1601) → date normale.
  static DateTime? fromFileTime(num? v) {
    if (v == null || v <= 0) return null;
    final ms = v / 10000 - 11644473600000;
    if (ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms.round());
  }

  /// Lit ce que le registre a répondu pour une capacité.
  static SensorState parse(Object? json) {
    if (json is! Map) return const SensorState();
    final blocked = json['bloque'] == true;
    final out = <SensorUse>[];
    final seen = <String>{};
    for (final a in (json['apps'] is List ? json['apps'] as List : const [])) {
      if (a is! Map) continue;
      final key = '${a['cle'] ?? ''}';
      if (key.isEmpty || key == 'NonPackaged' || !seen.add(key)) continue;
      final start = (a['debut'] as num?) ?? 0;
      final stop = (a['fin'] as num?) ?? 0;
      // Windows met la fin à 0 pendant que l'appli s'en sert.
      final active = start > 0 && stop == 0;
      out.add(SensorUse(key: key, app: appName(key), active: active, at: fromFileTime(active ? start : stop)));
    }
    return SensorState(blocked: blocked, uses: out);
  }

  /// La phrase dite à la personne (ou à Smily).
  static String say(SensorState cam, SensorState mic) {
    final parts = <String>[];
    if (cam.blocked) {
      parts.add('Ta caméra est coupée : aucune appli ne peut filmer.');
    } else if (cam.active.isEmpty) {
      parts.add('Ta caméra est allumée mais personne ne s\'en sert.');
    } else {
      parts.add('Ta caméra est utilisée en ce moment par ${cam.active.map((u) => u.app).join(', ')}.');
    }
    if (mic.blocked) {
      parts.add('Ton micro est coupé.');
    } else if (mic.active.isNotEmpty) {
      parts.add('Ton micro est utilisé par ${mic.active.map((u) => u.app).join(', ')}.');
    }
    final last = cam.recent.where((u) => !u.active && u.at != null).firstOrNull;
    if (cam.active.isEmpty && !cam.blocked && last != null) {
      parts.add('La dernière fois, c\'était ${last.app}.');
    }
    return parts.join(' ');
  }
}

/// **Protection de la caméra et du micro** (Windows, sur ce PC).
///
/// Deux choses :
/// * un interrupteur « caméra coupée » : plus aucune appli ne peut filmer
///   (le réglage de confidentialité de Windows, mis sur « refuser ») ;
/// * une alerte dès qu'une appli allume la caméra, surtout une appli à
///   laquelle on ne s'attend pas.
///
/// Rien n'est envoyé nulle part : tout se lit dans le registre de Windows.
class CameraGuard extends ChangeNotifier {
  CameraGuard._();
  static final instance = CameraGuard._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  static const _kAlert = 'app.camera.alerte';

  /// Prévenir quand une appli allume la caméra (oui par défaut).
  bool get alerts {
    try {
      return ModuleStore.global.getBool(_kAlert) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setAlerts(bool v) async {
    try {
      await ModuleStore.global.setBool(_kAlert, v);
    } catch (_) {}
    notifyListeners();
  }

  /// Prévenir la personne (branché par Mon Hub).
  void Function(String title, String body)? warn;

  SensorState camera = const SensorState();
  SensorState micro = const SensorState();
  DateTime? _readAt;

  static const _root = r'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore';

  static const readScript =
      '''
\$out = @{}
function Lire(\$cap) {
  \$root = "$_root\\\$cap"
  \$o = @{ bloque = \$false; apps = @() }
  try { \$v = (Get-ItemProperty -Path \$root -Name Value -ErrorAction Stop).Value; \$o.bloque = (\$v -eq 'Deny') } catch {}
  foreach (\$r in @(\$root, "\$root\\NonPackaged")) {
    try {
      Get-ChildItem -Path \$r -ErrorAction Stop | ForEach-Object {
        \$p = Get-ItemProperty -Path \$_.PSPath -ErrorAction SilentlyContinue
        if (\$p -and (\$p.PSObject.Properties.Name -contains 'LastUsedTimeStart')) {
          \$o.apps += @{ cle = "\$(\$_.PSChildName)"; debut = [int64]\$p.LastUsedTimeStart; fin = [int64]\$p.LastUsedTimeStop }
        }
      }
    } catch {}
  }
  return \$o
}
\$out.camera = Lire 'webcam'
\$out.micro = Lire 'microphone'
\$out | ConvertTo-Json -Depth 5 -Compress
''';

  static const writeScript =
      '''
param(\$cap, \$etat)
\$root = "$_root\\\$cap"
foreach (\$r in @(\$root, "\$root\\NonPackaged")) {
  if (-not (Test-Path \$r)) { New-Item -Path \$r -Force | Out-Null }
  Set-ItemProperty -Path \$r -Name Value -Value \$etat
}
'Ok'
''';

  /// Relit l'état (au plus une fois toutes les 10 secondes).
  Future<void> read({bool force = false}) async {
    if (!supported) return;
    final now = DateTime.now();
    if (!force && _readAt != null && now.difference(_readAt!) < const Duration(seconds: 10)) return;
    _readAt = now;
    try {
      final r = await PowerShell.run(readScript, const {}, const Duration(seconds: 20));
      final out = '${r.stdout}'.trim();
      if (out.isEmpty) return;
      final j = jsonDecode(out);
      if (j is! Map) return;
      camera = CameraRules.parse(j['camera']);
      micro = CameraRules.parse(j['micro']);
      notifyListeners();
    } catch (_) {}
  }

  /// Coupe (ou rallume) la caméra, ou le micro avec [mic].
  Future<bool> setBlocked(bool off, {bool mic = false}) async {
    if (!supported) return false;
    try {
      final r = await PowerShell.run(writeScript, {
        'cap': mic ? 'microphone' : 'webcam',
        'etat': off ? 'Deny' : 'Allow',
      }, const Duration(seconds: 20));
      if ('${r.stdout}'.contains('Ok')) {
        await read(force: true);
        return mic ? micro.blocked == off : camera.blocked == off;
      }
    } catch (_) {}
    return false;
  }

  /// Ce que Smily dit de l'état.
  String say() => CameraRules.say(camera, micro);

  // Les applis déjà signalées (on ne prévient pas deux fois).
  final _told = <String>{};
  DateTime? _tick;

  /// Un tour de garde (appelé par le tour de 15 s de Mon Hub).
  Future<void> tick() async {
    if (!supported || !alerts) return;
    final now = DateTime.now();
    // En mode léger, on regarde deux fois moins souvent.
    if (_tick != null && now.difference(_tick!) < Perf.slow(const Duration(seconds: 30), factor: 2)) return;
    _tick = now;
    await read(force: true);
    final live = {for (final u in camera.active) u.key};
    for (final u in camera.active) {
      if (!_told.add(u.key)) continue;
      final odd = CameraRules.unexpected(u.app);
      warn?.call(
        odd ? '🚨 ${u.app} filme avec ta caméra' : '📷 ${u.app} utilise ta caméra',
        odd
            ? 'Cette appli n\'est pas censée filmer. Si ce n\'est pas toi : Réglages → Sécurité → coupe la caméra.'
            : 'Si ce n\'est pas toi, coupe la caméra dans Réglages → Sécurité et vie privée.',
      );
    }
    _told.removeWhere((k) => !live.contains(k));
  }
}

/// Les outils de Smily pour la caméra et le micro.
extension CameraTools on CameraGuard {
  List<HubTool> tools() => [
    HubTool(
      name: 'camera_etat',
      description:
          'État de la caméra et du micro du PC : coupés ou non, quelle appli s\'en sert en ce moment, '
          'et laquelle s\'en est servi en dernier. À utiliser quand la personne demande si sa caméra '
          'est allumée, qui l\'utilise, ou si elle a peur d\'être filmée.',
      run: (_) async {
        if (!CameraGuard.supported) return {'resume': 'Cette protection n\'existe que sur le PC.'};
        await read(force: true);
        return {
          'resume': say(),
          'camera_coupee': camera.blocked,
          'micro_coupe': micro.blocked,
          'camera_en_cours': [for (final u in camera.active) u.app],
          'micro_en_cours': [for (final u in micro.active) u.app],
          'camera_dernieres': [
            for (final u in camera.recent.take(5))
              {'appli': u.app, 'quand': u.at?.toIso8601String(), 'en_cours': u.active},
          ],
        };
      },
    ),
    HubTool(
      name: 'camera_couper',
      description:
          'Coupe la caméra du PC (plus aucune appli ne peut filmer), ou la rallume. Avec appareil=micro, '
          'fait pareil pour le micro. À utiliser quand la personne dit « coupe ma caméra », « je ne veux '
          'pas être filmé », « rallume ma caméra ».',
      params: {
        'couper': ('string', 'oui (défaut) pour couper, non pour rallumer'),
        'appareil': ('string', 'camera (défaut) ou micro'),
      },
      run: (a) async {
        if (!CameraGuard.supported) return {'resume': 'Cette protection n\'existe que sur le PC.'};
        final off = !'${a['couper'] ?? 'oui'}'.toLowerCase().startsWith('n');
        final mic = '${a['appareil'] ?? ''}'.toLowerCase().startsWith('mic');
        final ok = await setBlocked(off, mic: mic);
        final what = mic ? 'Le micro' : 'La caméra';
        return {
          'resume': ok
              ? '$what ${off ? 'est coupé${mic ? '' : 'e'} : plus aucune appli ne peut ${mic ? 'écouter' : 'filmer'}.' : 'remarche.'}'
              : 'Je n\'ai pas réussi à changer ça (Windows a refusé). Réglages → Confidentialité → Caméra.',
          'fait': ok,
        };
      },
    ),
  ];
}
