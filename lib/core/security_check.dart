import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'module_store.dart';
import 'powershell.dart';

/// Un point du bilan de sécurité.
class SecurityItem {
  const SecurityItem({
    required this.id,
    required this.title,
    required this.detail,
    this.ok,
    this.fix,
    this.fixLabel = 'Régler',
    this.manual = false,
  });

  final String id;
  final String title;
  final String detail;

  /// true : tout va bien ; false : à régler ; null : à vérifier soi-même.
  final bool? ok;

  /// Ce qui ouvre le bon réglage (« ms-settings:… », « windowsdefender: », un site).
  final String? fix;
  final String fixLabel;

  /// À cocher soi-même (la double authentification d'un compte).
  final bool manual;
}

/// **Bilan de sécurité** du PC et des comptes (sans IA, sur le PC) :
/// antivirus, pare-feu, mises à jour de Windows, contrôle des comptes, et la
/// double authentification (Discord vérifiée, les autres avec le lien
/// direct pour l'activer).
class SecurityCheck {
  SecurityCheck._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Ce que Windows dit de sa protection (JSON). Sans droits d'administrateur.
  static const script = r'''
$o = @{}
try { $o.av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop | ForEach-Object { @{ nom = "$($_.displayName)"; etat = [int]$_.productState } }) } catch { $o.av = @() }
try { $m = Get-MpComputerStatus -ErrorAction Stop; $o.defender = @{ actif = [bool]$m.AntivirusEnabled; tempsReel = [bool]$m.RealTimeProtectionEnabled; signaturesJours = [int]$m.AntivirusSignatureAge } } catch {}
try { $o.parefeu = @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object { @{ nom = "$($_.Name)"; actif = [bool]$_.Enabled } }) } catch {}
try { $h = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1; if ($h) { $o.majJours = [int]((Get-Date) - $h.InstalledOn).TotalDays } } catch {}
$o.redemarrage = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
try { $o.uac = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA } catch {}
$o | ConvertTo-Json -Depth 4 -Compress
''';

  /// Les comptes dont la double authentification se vérifie soi-même.
  static const accounts = [
    ('google', 'Google', 'https://myaccount.google.com/signinoptions/twosv'),
    ('roblox', 'Roblox', 'https://www.roblox.com/my/account#!/security'),
    ('instagram', 'Instagram', 'https://accountscenter.instagram.com/password_and_security/two_factor/'),
    ('microsoft', 'Microsoft (Xbox, Minecraft)', 'https://account.microsoft.com/security'),
    ('epic', 'Epic Games (Fortnite)', 'https://www.epicgames.com/account/password'),
    ('steam', 'Steam', 'https://store.steampowered.com/twofactor/manage'),
  ];

  static const _doneKey = 'secu.fait';

  static Set<String> get done {
    try {
      return (ModuleStore.global.getStringList(_doneKey) ?? const []).toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> setDone(String id, bool v) async {
    final d = done;
    v ? d.add(id) : d.remove(id);
    await ModuleStore.global.setStringList(_doneKey, d.toList());
  }

  /// Les points du bilan, à partir de ce que Windows a répondu ([pc]) et de
  /// l'état de Discord ([discord2fa], null : Discord pas connecté).
  static List<SecurityItem> build(Map pc, {bool? discord2fa, Set<String> done = const {}, String pcControl = 'ask'}) {
    final out = <SecurityItem>[];
    final av = [
      for (final a in (pc['av'] is List ? pc['av'] as List : const []))
        if (a is Map) a,
    ];
    final def = pc['defender'] is Map ? pc['defender'] as Map : null;
    // productState : 0x1000 = allumé, 0x10 = signatures en retard.
    final on = [
      for (final a in av)
        if (((a['etat'] as num?)?.toInt() ?? 0) & 0x1000 != 0) '${a['nom']}',
    ];
    final defOn = def?['tempsReel'] == true;
    final protectedBy = on.isNotEmpty ? on.join(', ') : (defOn ? 'Microsoft Defender' : null);
    out.add(
      SecurityItem(
        id: 'antivirus',
        title: 'Antivirus',
        ok: protectedBy != null ? true : (av.isEmpty && def == null ? null : false),
        detail: protectedBy != null
            ? 'Actif : $protectedBy.'
            : 'Aucun antivirus actif ! Allume la protection en temps réel de Microsoft Defender.',
        fix: 'windowsdefender:',
        fixLabel: 'Ouvrir Sécurité Windows',
      ),
    );
    final age = (def?['signaturesJours'] as num?)?.toInt();
    final outdated = av.any(
      (a) => (((a['etat'] as num?)?.toInt() ?? 0) & 0x1000) != 0 && (((a['etat'] as num?)?.toInt() ?? 0) & 0x10) != 0,
    );
    if (age != null || av.isNotEmpty) {
      final bad = outdated || (on.isEmpty && age != null && age > 3);
      out.add(
        SecurityItem(
          id: 'signatures',
          title: 'Antivirus à jour',
          ok: !bad,
          detail: bad
              ? 'L\'antivirus n\'est pas à jour${age == null ? '' : ' ($age jours)'} : lance une mise à jour.'
              : 'Il connaît les derniers virus.',
          fix: 'windowsdefender:',
          fixLabel: 'Mettre à jour',
        ),
      );
    }
    final fw = [
      for (final p in (pc['parefeu'] is List ? pc['parefeu'] as List : const []))
        if (p is Map) p,
    ];
    if (fw.isNotEmpty) {
      final off = [
        for (final p in fw)
          if (p['actif'] != true) '${p['nom']}',
      ];
      out.add(
        SecurityItem(
          id: 'parefeu',
          title: 'Pare-feu',
          ok: off.isEmpty,
          detail: off.isEmpty ? 'Actif sur tous les réseaux.' : 'Coupé pour : ${off.join(', ')}. Rallume-le.',
          fix: 'windowsdefender://network',
          fixLabel: 'Ouvrir le pare-feu',
        ),
      );
    }
    final days = (pc['majJours'] as num?)?.toInt();
    final reboot = pc['redemarrage'] == true;
    out.add(
      SecurityItem(
        id: 'maj',
        title: 'Mises à jour de Windows',
        ok: reboot ? false : (days == null ? null : days <= 45),
        detail: reboot
            ? 'Des mises à jour attendent un redémarrage du PC pour s\'installer.'
            : days == null
            ? 'Vérifie dans Windows Update qu\'il n\'y a rien en attente.'
            : days <= 45
            ? 'Dernière mise à jour il y a $days jour${days > 1 ? 's' : ''}.'
            : 'Pas de mise à jour depuis $days jours : lance Windows Update.',
        fix: 'ms-settings:windowsupdate',
        fixLabel: 'Windows Update',
      ),
    );
    if (pc['uac'] is num) {
      final uac = (pc['uac'] as num).toInt() == 1;
      out.add(
        SecurityItem(
          id: 'uac',
          title: 'Contrôle des comptes (UAC)',
          ok: uac,
          detail: uac
              ? 'Windows demande avant qu\'un programme modifie le PC.'
              : 'Désactivé : un programme peut tout modifier sans demander. Réactive-le.',
        ),
      );
    }
    if (pcControl == 'auto') {
      out.add(
        const SecurityItem(
          id: 'clicky',
          title: 'Nexo contrôle le PC « sans demander »',
          ok: false,
          detail: 'Plus prudent : « Demander » (Réglages de Nexo → Outils avancés → Contrôle du PC).',
        ),
      );
    }
    if (discord2fa != null) {
      out.add(
        SecurityItem(
          id: 'discord',
          title: 'Discord : double authentification',
          ok: discord2fa,
          detail: discord2fa
              ? 'Activée : même avec ton mot de passe, personne ne peut entrer.'
              : 'Pas activée ! Discord → Paramètres → Mon compte → « Activer l\'authentification à deux facteurs ».',
          fix: 'https://discord.com/channels/@me',
          fixLabel: 'Ouvrir Discord',
        ),
      );
    }
    for (final (id, name, url) in accounts) {
      final ok = done.contains(id);
      out.add(
        SecurityItem(
          id: id,
          title: '$name : double authentification',
          ok: ok ? true : null,
          detail: ok ? 'Tu l\'as activée.' : 'Active-la (un code en plus du mot de passe), puis coche « C\'est fait ».',
          fix: url,
          fixLabel: 'Activer',
          manual: true,
        ),
      );
    }
    return out;
  }

  /// Ce que Nexo dit (les soucis d'abord).
  static String say(List<SecurityItem> items) {
    final bad = [
      for (final i in items)
        if (i.ok == false) i,
    ];
    final todo = [
      for (final i in items)
        if (i.ok == null && i.manual) i.title.split(' :').first,
    ];
    final good = items.where((i) => i.ok == true).length;
    if (bad.isEmpty) {
      return 'Ton PC est bien protégé ($good points OK).'
          '${todo.isEmpty ? '' : ' Pense à la double authentification sur ${todo.take(3).join(', ')}${todo.length > 3 ? '…' : ''}.'}';
    }
    return 'À régler : ${bad.map((i) => '${i.title} — ${i.detail}').join(' ')}';
  }

  /// Lance le bilan (Windows + Discord si on sait le lire).
  static Future<List<SecurityItem>> run({Future<bool?> Function()? discord, String pcControl = 'ask'}) async {
    Map pc = const {};
    if (supported) {
      try {
        final r = await PowerShell.run(script, const {}, const Duration(seconds: 40));
        final t = '${r.stdout}'.trim();
        final j = jsonDecode(t.isEmpty ? '{}' : t);
        if (j is Map) pc = j;
      } catch (_) {}
    }
    bool? d;
    try {
      d = await discord?.call();
    } catch (_) {}
    return build(pc, discord2fa: d, done: done, pcControl: pcControl);
  }
}
