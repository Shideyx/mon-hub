import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera_guard.dart';
import 'hub_module.dart';
import 'module_store.dart';
import 'powershell.dart';

/// Les règles du bouclier d'appel, **sans Windows** : testables.
class CallRules {
  const CallRules._();

  /// Les applis d'appel (celles qui ont le droit d'utiliser caméra et micro
  /// pendant un appel).
  static const callApps = {'Discord', 'Teams', 'Zoom', 'Skype', 'WhatsApp', 'Chrome', 'Edge', 'Firefox', 'Snapchat'};

  /// Celles qui ont toujours le droit (Mon Hub lui-même : Nexo écoute ta
  /// question ; le magnétophone de Windows quand c'est toi qui le lances).
  static const alwaysOk = {'Mon Hub', 'OBS', 'Appareil photo'};

  /// L'appli de l'appel en cours : une appli d'appel qui a le micro ouvert.
  /// (Chrome / Edge / Firefox : Meet, Discord web…)
  static String? callApp(SensorState mic) {
    for (final u in mic.active) {
      if (callApps.contains(u.app)) return u.app;
    }
    return null;
  }

  /// Pendant un appel : les **autres** applis qui filment ou écoutent.
  static List<(SensorUse, bool)> intruders(SensorState cam, SensorState mic, String call) => [
    for (final u in cam.active)
      if (u.app != call && !alwaysOk.contains(u.app)) (u, false),
    for (final u in mic.active)
      if (u.app != call && !alwaysOk.contains(u.app)) (u, true),
  ];

  /// Ce qu'il dit quand une appli espionne pendant l'appel.
  static String alert(String app, String call, {required bool mic}) =>
      'Pendant ton appel $call, $app ${mic ? 'écoute ton micro' : 'utilise ta caméra'}. Si ce n\'est pas toi, '
      'je peux lui couper l\'accès (seulement à elle : ton appel continue).';

  /// Comment flouter l'arrière-plan dans l'appli d'appel (elles le font
  /// toutes elles-mêmes, gratuitement : c'est le seul vrai flou sans pilote).
  static String blurHow(String call) => switch (call) {
    'Discord' =>
      'Sur Discord : pendant l\'appel, la petite flèche à côté du bouton caméra → « Arrière-plan vidéo » → « Flou ».',
    'Teams' => 'Sur Teams : « … » → « Effets vidéo » → « Flou » (ou avant l\'appel : « Effets d\'arrière-plan »).',
    'Zoom' => 'Sur Zoom : la flèche à côté de « Arrêter la vidéo » → « Flouter mon arrière-plan ».',
    'Chrome' || 'Edge' || 'Firefox' =>
      'Sur Google Meet : les trois points → « Appliquer des effets visuels » → « Flouter l\'arrière-plan ». '
          'Sur Discord dans le navigateur : la flèche à côté de la caméra → « Arrière-plan vidéo ».',
    'WhatsApp' => 'WhatsApp sur PC n\'a pas de flou : coupe la caméra avec le bouton de l\'appel si tu préfères.',
    _ =>
      'Dans ton appli d\'appel, cherche « effets vidéo » ou « arrière-plan » → « flou ». Si ton PC a les « effets de '
          'studio Windows », ils sont aussi dans Paramètres → Bluetooth et appareils → Caméras.',
  };
}

/// **Bouclier d'appel** (v1.62) : pendant un appel, seule l'appli de
/// l'appel a le droit de filmer et d'écouter. Si une autre appli allume la
/// caméra ou le micro, Nexo le dit tout de suite et propose de **lui**
/// couper l'accès (le réglage de Windows, appli par appli). Et « coupe mon
/// micro » met le micro en sourdine **pour de vrai**, dans toutes les applis
/// à la fois, instantanément (et « remets mon micro » le rallume).
class CallShield extends ChangeNotifier {
  CallShield._();
  static final instance = CallShield._();

  static const _kOn = 'app.appel.bouclier';

  bool get on {
    try {
      return ModuleStore.global.getBool(_kOn) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setOn(bool v) async {
    try {
      await ModuleStore.global.setBool(_kOn, v);
    } catch (_) {}
    notifyListeners();
  }

  /// L'appel en cours (null sinon).
  String? call;

  /// Prévenir (branché par Mon Hub) : titre, texte, et la clé de l'appli à
  /// couper (pour la proposition de Nexo).
  void Function(String title, String body, String key, bool mic)? warn;

  /// Au début d'un appel avec caméra : comment flouter (une fois par appel).
  void Function(String call, String how)? onCallStart;

  final _told = <String>{};
  bool _blurTold = false;

  /// Un tour (après celui de la garde de la caméra, qui a relu le registre).
  void tick() {
    if (!CameraGuard.supported || !on) return;
    final g = CameraGuard.instance;
    final now = CallRules.callApp(g.micro);
    if (now != call) {
      call = now;
      _told.clear();
      _blurTold = false;
      notifyListeners();
    }
    if (now == null) return;
    if (!_blurTold && g.camera.active.any((u) => u.app == now)) {
      _blurTold = true;
      onCallStart?.call(now, CallRules.blurHow(now));
    }
    for (final (u, mic) in CallRules.intruders(g.camera, g.micro, now)) {
      if (!_told.add('${u.key}|$mic')) continue;
      warn?.call(
        mic ? '🚨 ${u.app} écoute ton micro' : '🚨 ${u.app} utilise ta caméra',
        CallRules.alert(u.app, now, mic: mic),
        u.key,
        mic,
      );
    }
  }

  // ------------------------------------------------------ Une seule appli

  static const _blockAppScript = r'''
param($cap, $cle, $etat)
$root = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$cap"
$p = if ($cle -like '*#*') { "$root\NonPackaged\$cle" } else { "$root\$cle" }
if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
Set-ItemProperty -Path $p -Name Value -Value $etat
'Ok'
''';

  /// Coupe (ou rend) la caméra / le micro à **une** appli.
  Future<bool> blockApp(String key, {required bool mic, bool off = true}) async {
    if (!CameraGuard.supported || key.isEmpty || key.contains(RegExp(r'[\\/"`$]'))) return false;
    try {
      final r = await PowerShell.run(_blockAppScript, {
        'cap': mic ? 'microphone' : 'webcam',
        'cle': key,
        'etat': off ? 'Deny' : 'Allow',
      }, const Duration(seconds: 20));
      return '${r.stdout}'.contains('Ok');
    } catch (_) {
      return false;
    }
  }

  // ----------------------------------------------------- Micro en sourdine

  /// Sourdine du micro par défaut de Windows (console + communications) :
  /// toutes les applis l'entendent à la fois, l'appel continue.
  static const muteScript = r'''
param($mode)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int f0(); int f1(); int f2(); int f3(); int f4(); int f5(); int f6(); int f7(); int f8(); int f9(); int f10();
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
  int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid id, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int f0();
  int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}
public static class MonHubMic {
  static IAudioEndpointVolume Vol(int role) {
    var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
    IMMDevice dev;
    if (en.GetDefaultAudioEndpoint(1, role, out dev) != 0 || dev == null) return null;
    var iid = typeof(IAudioEndpointVolume).GUID;
    object o;
    if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return null;
    return (IAudioEndpointVolume)o;
  }
  public static string Run(string mode) {
    var ctx = Guid.Empty;
    var a = Vol(0); var b = Vol(2);
    if (a == null) return "aucun";
    bool m; a.GetMute(out m);
    bool want = mode == "on" ? true : mode == "off" ? false : mode == "toggle" ? !m : m;
    if (mode != "etat") { a.SetMute(want, ref ctx); if (b != null) b.SetMute(want, ref ctx); }
    a.GetMute(out m);
    return m ? "muet" : "ouvert";
  }
}
'@
[MonHubMic]::Run($mode)
''';

  /// État de la sourdine après l'ordre : true = muet, false = ouvert, null =
  /// pas de micro / échec.
  Future<bool?> mute(String mode) async {
    if (!CameraGuard.supported) return null;
    try {
      final r = await PowerShell.run(muteScript, {'mode': mode}, const Duration(seconds: 20));
      final out = '${r.stdout}'.trim();
      if (out.endsWith('muet')) return true;
      if (out.endsWith('ouvert')) return false;
    } catch (_) {}
    return null;
  }

  List<HubTool> tools() => [
    HubTool(
      name: 'micro_sourdine',
      description:
          'Met le micro du PC en sourdine tout de suite (dans toutes les applis à la fois, l\'appel continue), le '
          'rallume, ou bascule. À utiliser pour « coupe mon micro », « mute-moi », « remets mon micro », « je '
          'suis muet ? ».',
      params: {'mode': ('string', 'on = sourdine, off = rallumer, toggle = basculer, etat = juste dire l\'état')},
      run: (a) async {
        if (!CameraGuard.supported) return {'resume': 'La sourdine du micro n\'existe que sur le PC.'};
        final mode = '${a['mode'] ?? 'toggle'}'.toLowerCase();
        final m = await mute(const {'on', 'off', 'toggle', 'etat'}.contains(mode) ? mode : 'toggle');
        if (m == null) return {'resume': 'Je ne trouve pas de micro sur ce PC.', 'fait': false};
        return {
          'resume': m ? '🔇 Ton micro est coupé : plus personne ne t\'entend.' : '🎙️ Ton micro est rallumé.',
          'muet': m,
          'fait': true,
        };
      },
    ),
    HubTool(
      name: 'camera_bloquer_appli',
      description:
          'Coupe la caméra ou le micro à UNE appli précise (celle qui espionne pendant un appel), sans toucher aux '
          'autres. Ou le lui rend avec rendre=oui.',
      params: {
        'cle': ('string', 'La clé de l\'appli (donnée par l\'alerte ou par camera_etat)'),
        'appareil': ('string', 'camera ou micro'),
        'rendre': ('string', 'oui pour lui rendre l\'accès'),
      },
      required: const ['cle'],
      run: (a) async {
        final key = '${a['cle'] ?? ''}';
        final mic = '${a['appareil'] ?? ''}'.toLowerCase().startsWith('mic');
        final back = '${a['rendre'] ?? ''}'.toLowerCase().startsWith('o');
        final ok = await blockApp(key, mic: mic, off: !back);
        final app = CameraRules.appName(key);
        return {
          'resume': !ok
              ? 'Je n\'ai pas réussi (Windows a refusé).'
              : back
              ? '$app peut de nouveau utiliser ${mic ? 'le micro' : 'la caméra'}.'
              : 'C\'est fait : $app ne peut plus utiliser ${mic ? 'ton micro' : 'ta caméra'}. Ton appel continue. '
                    '(Il faudra peut-être fermer et rouvrir $app pour que ce soit total.)',
          'fait': ok,
        };
      },
    ),
    HubTool(
      name: 'appel_flou',
      description: 'Explique comment flouter son arrière-plan dans l\'appli de l\'appel en cours (Discord, Meet, Teams…).',
      run: (_) async => {
        'appel': call,
        'resume': CallRules.blurHow(call ?? ''),
      },
    ),
  ];
}
