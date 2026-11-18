import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/browser.dart';
import '../../core/hub_module.dart';
import '../../core/powershell.dart';
import '../../core/safe_open.dart';
import '../../core/tidy.dart';

/// Clicky agit sur ton ordinateur quand tu le lui demandes : commandes
/// (PowerShell sur Windows), fichiers, applis, réglages du système.
///
/// Réglage « Contrôle du PC » (module Claude → Réglages → Clicky) :
/// * `ask` (par défaut) : chaque commande et chaque écriture de fichier
///   s'affiche et attend ton « Autoriser » ;
/// * `auto` : Clicky agit sans demander, sauf pour les commandes
///   dangereuses (formatage, suppression d'un disque, registre système…) ;
/// * `off` : Clicky ne touche pas au PC.
class PcControl {
  PcControl._();

  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Longueur maximale d'une sortie renvoyée à l'IA.
  static const maxOutput = 12000;

  /// Les actions qui changent quelque chose (permission, sauf mode auto).
  static bool isWrite(String toolName) =>
      toolName == 'pc_commande' ||
      toolName == 'pc_ecrire_fichier' ||
      toolName == 'pc_ranger' ||
      toolName == 'pc_ranger_annuler';

  /// Ce que Clicky sait faire sur le PC (ajouté à ses consignes).
  static String get guide =>
      '''
Contrôle du PC : quand la personne te demande de FAIRE quelque chose sur son ordinateur (ouvrir ou fermer une appli, ranger, renommer, chercher ou créer des fichiers, installer un logiciel, régler le son, le Wi-Fi, le mode sombre, éteindre, redémarrer, nettoyer, voir l'espace disque…), fais-le vraiment avec les outils pc_ au lieu d'expliquer comment faire :
- pc_commande : une commande ${Platform.isWindows ? 'PowerShell (Windows) ; winget pour installer un logiciel ; admin=true seulement si nécessaire (Windows demande alors la confirmation)' : 'shell'}. Non interactive (pas de question en attente, -Force / -y quand il faut), puis lis la sortie pour vérifier que ça a marché ;
- pc_ouvrir : ouvrir une appli, un fichier, un dossier, un site ou une page de réglages (ms-settings:…) ;
- pc_lire : lire un fichier texte ou lister un dossier ;
- pc_ecrire_fichier : créer ou modifier un fichier texte ;
- pc_ranger_apercu puis pc_ranger : ranger un dossier (Téléchargements, Bureau, Documents, Images ou un chemin) par type et par matière, doublons mis de côté ; dis d'abord ce qui va être rangé ; pc_ranger_annuler remet tout en place. Pour ranger, utilise ces outils plutôt que des commandes.
Fais d'abord les étapes qui lisent, puis celle qui agit. Ne supprime ou n'écrase rien que la personne n'a pas demandé, et dis en une phrase ce que tu as fait.''';

  static List<HubTool> tools() => supported
      ? [
          HubTool(
            name: 'pc_commande',
            description: Platform.isWindows
                ? 'Exécute une commande PowerShell sur le PC de la personne et renvoie sa sortie '
                      '(applis, fichiers, réglages, logiciels avec winget, infos système…).'
                : 'Exécute une commande shell sur l\'ordinateur de la personne et renvoie sa sortie.',
            params: {
              'commande': ('string', 'La commande à exécuter (non interactive).'),
              'pourquoi': ('string', 'En quelques mots, ce que fait la commande (affiché à la personne).'),
              'dossier': ('string', 'Dossier de travail (facultatif).'),
              'admin': ('boolean', 'Lancer en administrateur (Windows, facultatif).'),
              'delai': ('integer', 'Temps maximum en secondes (défaut 120, max 220).'),
            },
            required: ['commande'],
            run: (a) => run(
              '${a['commande'] ?? ''}',
              cwd: _str(a['dossier']),
              admin: a['admin'] == true,
              timeout: Duration(seconds: ((a['delai'] as num?)?.toInt() ?? 120).clamp(5, 220)),
            ),
          ),
          HubTool(
            name: 'pc_ouvrir',
            description:
                'Ouvre une appli, un fichier, un dossier, un site web ou une page de réglages '
                '(ex. « notepad », « C:\\Users\\…\\Documents », « https://… », « ms-settings:sound »).',
            params: {'cible': ('string', 'Ce qu\'il faut ouvrir.')},
            required: ['cible'],
            run: (a) => open('${a['cible'] ?? ''}'),
          ),
          HubTool(
            name: 'pc_lire',
            description:
                'Lit un fichier texte (début du fichier) ou liste le contenu d\'un dossier sur le PC. '
                '« ~ » = le dossier de la personne.',
            params: {'chemin': ('string', 'Chemin du fichier ou du dossier.')},
            required: ['chemin'],
            run: (a) => read('${a['chemin'] ?? ''}'),
          ),
          HubTool(
            name: 'pc_ecrire_fichier',
            description: 'Crée ou modifie un fichier texte sur le PC (« ~ » = le dossier de la personne).',
            params: {
              'chemin': ('string', 'Chemin du fichier.'),
              'contenu': ('string', 'Texte à écrire.'),
              'ajouter': ('boolean', 'true : ajoute à la fin au lieu de remplacer.'),
            },
            required: ['chemin', 'contenu'],
            run: (a) => write('${a['chemin'] ?? ''}', '${a['contenu'] ?? ''}', append: a['ajouter'] == true),
          ),
          HubTool(
            name: 'pc_ranger_apercu',
            description: 'Prépare le rangement d\'un dossier du PC : où irait chaque fichier en vrac (sans rien toucher).',
            params: {
              'dossier': ('string', 'telechargements, bureau, documents, images, ou un chemin'),
              'par_matiere': ('boolean', 'Ranger les cours par matière (Cours/Maths…), oui par défaut'),
            },
            required: ['dossier'],
            run: (a) async {
              final plan = await _plan(a);
              return {
                'dossier': plan.root,
                'fichiers': plan.moves.length,
                'laisses_en_place': plan.skipped,
                'rangement': {
                  for (final e in plan.groups.entries)
                    e.key: {'nombre': e.value.length, 'exemples': [for (final m in e.value.take(4)) m.name]},
                },
              };
            },
          ),
          HubTool(
            name: 'pc_ranger',
            description: 'Range pour de vrai un dossier du PC (après pc_ranger_apercu). Rien n\'est supprimé ; annulable.',
            params: {
              'dossier': ('string', 'telechargements, bureau, documents, images, ou un chemin'),
              'par_matiere': ('boolean', 'Ranger les cours par matière, oui par défaut'),
            },
            required: ['dossier'],
            run: (a) async {
              final (n, errors) = await PcTidy.apply(await _plan(a));
              return {'ranges': n, if (errors.isNotEmpty) 'erreurs': errors.take(5).toList()};
            },
          ),
          HubTool(
            name: 'pc_ranger_annuler',
            description: 'Annule le dernier rangement du PC (remet les fichiers à leur place).',
            run: (_) async => {'remis_en_place': await PcTidy.undoLast()},
          ),
        ]
      : const [];

  static Future<TidyPlan> _plan(Map<String, dynamic> a) async {
    final what = '${a['dossier'] ?? ''}'.trim();
    final dir = PcTidy.folder(what) ?? (what.isEmpty ? null : PcTidy.folder(expand(what)));
    if (dir == null) throw 'Dossier introuvable : $what';
    return PcTidy.analyze(dir, bySubject: a['par_matiere'] != false);
  }

  static String? _str(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty || s == 'null' ? null : s;
  }

  /// « ~ » et %VARIABLES% remplacés.
  static String expand(String path) {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    var p = path.trim();
    if (p == '~' || p.startsWith('~/') || p.startsWith('~\\')) p = '$home${p.substring(1)}';
    return p.replaceAllMapped(RegExp(r'%([A-Za-z0-9_]+)%'), (m) => env[m[1]!] ?? m[0]!);
  }

  /// Commandes qu'on ne lance jamais sans demander, même en mode auto.
  static bool dangerous(String command) {
    final c = command.toLowerCase();
    return RegExp(
      r'format-volume|\bformat(\.com)?\s+[a-z]:|diskpart|clear-disk|initialize-disk|remove-partition'
      r'|bcdedit|cipher\s+/w|vssadmin\s+delete|wbadmin\s+delete'
      r'|reg(\.exe)?\s+delete\s+hk(lm|ey_local_machine)|remove-item\s+.*hklm:'
      r'|set-mppreference|disable-?realtime|netsh\s+advfirewall\s+set\s+.*state\s+off'
      r'|(remove-item|\brm\b|\bdel\b|\brd\b|rmdir)\b[^|;\n]*(\s-r\b|-recurse|\s/s\b|\s-rf\b|\s-fr\b)'
      r'|\bmkfs|\bdd\s+if=|:\(\)\s*\{|chmod\s+-r\s+777\s+/|\bshutdown\b|stop-computer|restart-computer'
      // Télécharger puis exécuter, code caché (base64), scripts lancés en douce.
      r'|\biex\b|invoke-expression|downloadstring|downloadfile|net\.webclient|frombase64string'
      r'|\s-e(nc|ncodedcommand)?\s+[a-z0-9+/=]{16,}|start-bitstransfer|bitsadmin|certutil[^\n]*-(urlcache|decode)'
      r'|\b(iwr|irm|invoke-webrequest|invoke-restmethod|curl(\.exe)?|wget)\b[^\n]*\|\s*(powershell|pwsh|cmd|sh|bash|python)'
      r'|\bmshta\b|\brundll32\b|\bregsvr32\b|\bwscript\b|\bcscript\b|\bmsiexec\b[^\n]*https?:'
      // Données envoyées vers un site, mots de passe et clés.
      r'|-method\s+(post|put)|send-mailmessage|-infile\b|\bcurl(\.exe)?\b[^\n]*\s(-d|--data|-f|-t|--upload-file)\s'
      r'|login data|\bcookies\b|local state|key4\.db|logins\.json|bridge\.json|vault\.key|\\credentials\b|\\protect\\|\.ssh|id_rsa|\.kdbx|cmdkey|vaultcmd|mimikatz|lsass'
      // S'installer pour se relancer tout seul, désactiver les protections.
      r'|schtasks[^\n]*/create|register-scheduledtask|new-service|\bsc(\.exe)?\s+create|currentversion\\run'
      r'|\\startup\\|start menu\\programs\\startup|shell:startup|add-mppreference|set-mppreference'
      r'|set-executionpolicy\s+(unrestricted|bypass)|new-localuser|\bnet\s+user\b|add-localgroupmember|net\s+localgroup'
      r'|wevtutil\s+cl|clear-eventlog|\btakeown\b|icacls[^\n]*/grant|\buac\b|enablelua|disable-computerrestore',
    ).hasMatch(c);
  }

  /// Fichiers que Clicky ne lit **jamais** : mots de passe des navigateurs,
  /// cookies, clés (SSH, coffres), la clé du pont de Mon Hub, les secrets de
  /// Windows… Même si on le lui demande (ou si un message piégé le lui demande).
  static bool secretPath(String path) {
    final p = path.toLowerCase().replaceAll('/', '\\');
    return RegExp(
      r'\\monhub\\(bridge\.json|.*\.key|clicky-mcp\.json)$|\\clicky-claude-code\\clicky-mcp\.json$'
      r'|\\(login data|login data for account|cookies|web data|local state|key4\.db|logins\.json|cookies\.sqlite|signons\.sqlite)$'
      r'|\\\.ssh(\\|$)|\\\.aws\\|\\\.gnupg(\\|$)|\\\.azure\\|\\\.kube\\|\\\.docker\\config\.json$'
      r'|\\\.claude\\\.credentials\.json$|\\\.git-credentials$|\\\.npmrc$|\\\.pypirc$|\\\.netrc$|\\\.env(\.[a-z]+)?$'
      r'|\.(kdbx|kdb|pfx|p12|pem|key|ppk|ovpn|rdp)$|\\id_(rsa|dsa|ecdsa|ed25519)[^\\]*$|wallet\.dat$'
      r'|\\microsoft\\(credentials|protect|vault)(\\|$)|\\config\\(sam|security|system)$|ntuser\.dat|\\flutter_secure_storage',
    ).hasMatch(p);
  }

  /// Écritures qui peuvent faire lancer un programme plus tard (démarrage de
  /// Windows, profil PowerShell, scripts) ou toucher au système : toujours
  /// demandées, même en mode auto.
  static bool riskyWrite(String path) {
    final p = expand(path).toLowerCase().replaceAll('/', '\\');
    return secretPath(p) ||
        SafeOpen.risky(p) ||
        RegExp(
          r'\\startup\\|\\start menu\\|\\windows\\|\\program files|\\programdata\\|\\system32'
          r'|powershell\\.*profile\.ps1$|\\\.(bashrc|profile|zshrc|bash_profile)$|\\autostart\\|\\launchagents\\'
          r'|\\monhub\\|\\appdata\\roaming\\microsoft\\windows\\',
        ).hasMatch(p);
  }

  /// Demande la permission avant d'ouvrir quelque chose qui peut lancer un
  /// programme ([SafeOpen.risky]). Sans réponse : refusé.
  static Future<bool> Function(String target)? confirmRisky;

  /// Lance une commande et renvoie sa sortie.
  static Future<Map<String, Object?>> run(
    String command, {
    String? cwd,
    bool admin = false,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (command.trim().isEmpty) throw 'Commande vide.';
    final dir = cwd == null ? null : expand(cwd);
    if (dir != null && !await Directory(dir).exists()) throw 'Dossier introuvable : $dir';
    if (Platform.isWindows) {
      return admin ? _runAdmin(command, dir, timeout) : _runPs(command, dir, timeout);
    }
    if (admin) throw 'Le mode administrateur n\'est disponible que sur Windows (utilise sudo dans la commande si besoin).';
    return _collect(await Process.start('/bin/sh', ['-lc', command], workingDirectory: dir), timeout);
  }

  /// Le script PowerShell lancé : sortie en UTF-8, erreurs lisibles.
  @visibleForTesting
  static String psScript(String command) =>
      '''
\$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$OutputEncoding = [System.Text.Encoding]::UTF8
& {
$command
} 2>&1 | Out-String -Width 200
''';

  static Future<Map<String, Object?>> _runPs(String command, String? dir, Duration timeout) async {
    final p = await Process.start(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', PowerShell.encode(psScript(command))],
      workingDirectory: dir,
    );
    return _collect(p, timeout);
  }

  /// Administrateur : Windows affiche sa propre confirmation (UAC) ; la
  /// sortie passe par un fichier temporaire.
  static Future<Map<String, Object?>> _runAdmin(String command, String? dir, Duration timeout) async {
    final tmp = await Directory.systemTemp.createTemp('clicky-admin');
    final out = '${tmp.path}\\sortie.txt';
    final inner = PowerShell.encode(
      '${dir == null ? '' : "Set-Location -LiteralPath '${dir.replaceAll("'", "''")}'\n"}'
      '${psScript(command)} | Set-Content -LiteralPath \'${out.replaceAll("'", "''")}\' -Encoding UTF8',
    );
    final launcher =
        "\$p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru "
        "-ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','$inner'; "
        "exit \$p.ExitCode";
    try {
      final p = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        PowerShell.encode(launcher),
      ]);
      final r = await _collect(p, timeout);
      final f = File(out);
      final text = await f.exists() ? await f.readAsString() : '';
      if (text.isEmpty && '${r['sortie']}'.toLowerCase().contains('annul')) {
        throw 'La personne a refusé la demande administrateur de Windows.';
      }
      return {...r, 'sortie': _cut(text.isEmpty ? '${r['sortie']}' : text), 'admin': true};
    } finally {
      unawaited(tmp.delete(recursive: true).then((_) {}, onError: (_) {}));
    }
  }

  static Future<Map<String, Object?>> _collect(Process p, Duration timeout) async {
    unawaited(p.stdin.close().then((_) {}, onError: (_) {}));
    final out = StringBuffer();
    final err = StringBuffer();
    final a = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      if (out.length < maxOutput * 2) out.write(s);
    }).asFuture<void>();
    final b = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      if (err.length < maxOutput) err.write(s);
    }).asFuture<void>();
    int? code;
    var timedOut = false;
    try {
      code = await p.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      p.kill();
    }
    await Future.wait([a, b]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    return {
      'code': code,
      if (timedOut) 'arretee': 'Trop longue (plus de ${timeout.inSeconds} s) : arrêtée.',
      'sortie': _cut('$out'.trim()),
      if ('$err'.trim().isNotEmpty) 'erreurs': _cut(PowerShell.firstError('$err').isEmpty ? '$err'.trim() : '$err'.trim()),
    };
  }

  static String _cut(String s) =>
      s.length <= maxOutput ? s : '${s.substring(0, maxOutput)}\n… (${s.length - maxOutput} caractères coupés)';

  /// Ouvre une appli, un fichier, un dossier, un site, un réglage.
  static Future<String> open(String target) async {
    final t = expand(target);
    if (t.isEmpty) throw 'Rien à ouvrir.';
    // Pages web : dans Google Chrome (réglage « Ouvrir les liens »).
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t) && await Browser.open(t)) return 'Ouvert : $t';
    // Un programme, un script, un raccourci, un partage réseau : seulement
    // avec l'accord de la personne.
    if (SafeOpen.risky(t)) {
      final ask = confirmRisky;
      if (ask == null || !await ask(t)) {
        throw 'Je n\'ouvre pas « $t » sans ton accord (ça peut lancer un programme).';
      }
    }
    // Comme un double-clic : aucune commande n'est interprétée.
    if (!await SafeOpen.launch(t)) throw 'Impossible d\'ouvrir « $t ».';
    return 'Ouvert : $t';
  }

  /// Lit un fichier (début) ou liste un dossier.
  static Future<Object> read(String path) async {
    final p = expand(path);
    if (secretPath(p)) {
      throw 'Fichier protégé : Clicky ne lit jamais les mots de passe, cookies, clés ou fichiers de connexion.';
    }
    if (await Directory(p).exists()) {
      final items = <String>[];
      await for (final e in Directory(p).list(followLinks: false)) {
        final name = e.path.split(RegExp(r'[\\/]')).last;
        items.add(e is Directory ? '$name${Platform.pathSeparator}' : name);
        if (items.length >= 400) break;
      }
      items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return {'dossier': p, 'elements': items};
    }
    final f = File(p);
    if (!await f.exists()) throw 'Introuvable : $p';
    final size = await f.length();
    final raf = await f.open();
    try {
      final bytes = await raf.read(maxOutput);
      return {
        'fichier': p,
        'taille': size,
        'contenu': _cut(utf8.decode(bytes, allowMalformed: true)),
        if (size > maxOutput) 'note': 'Seulement le début du fichier.',
      };
    } finally {
      await raf.close();
    }
  }

  static Future<String> write(String path, String content, {bool append = false}) async {
    final p = expand(path);
    if (p.isEmpty) throw 'Chemin vide.';
    if (secretPath(p)) throw 'Fichier protégé : Clicky ne modifie pas les fichiers de mots de passe ou de clés.';
    final f = File(p);
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: append ? FileMode.append : FileMode.write, flush: true);
    return '${append ? 'Ajouté à' : 'Écrit'} : $p (${content.length} caractères)';
  }
}
