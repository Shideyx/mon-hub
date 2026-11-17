import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/browser.dart';
import '../../core/hub_module.dart';
import '../../core/powershell.dart';

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
      toolName == 'pc_commande' || toolName == 'pc_ecrire_fichier';

  /// Ce que Clicky sait faire sur le PC (ajouté à ses consignes).
  static String get guide =>
      '''
Contrôle du PC : quand la personne te demande de FAIRE quelque chose sur son ordinateur (ouvrir ou fermer une appli, ranger, renommer, chercher ou créer des fichiers, installer un logiciel, régler le son, le Wi-Fi, le mode sombre, éteindre, redémarrer, nettoyer, voir l'espace disque…), fais-le vraiment avec les outils pc_ au lieu d'expliquer comment faire :
- pc_commande : une commande ${Platform.isWindows ? 'PowerShell (Windows) ; winget pour installer un logiciel ; admin=true seulement si nécessaire (Windows demande alors la confirmation)' : 'shell'}. Non interactive (pas de question en attente, -Force / -y quand il faut), puis lis la sortie pour vérifier que ça a marché ;
- pc_ouvrir : ouvrir une appli, un fichier, un dossier, un site ou une page de réglages (ms-settings:…) ;
- pc_lire : lire un fichier texte ou lister un dossier ;
- pc_ecrire_fichier : créer ou modifier un fichier texte.
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
        ]
      : const [];

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
      r'|\bmkfs|\bdd\s+if=|:\(\)\s*\{|chmod\s+-r\s+777\s+/|\bshutdown\b|stop-computer|restart-computer',
    ).hasMatch(c);
  }

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
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', t], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      final isApp = !t.contains('/') && !t.contains(':');
      await Process.start('open', isApp ? ['-a', t] : [t], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [t], mode: ProcessStartMode.detached);
    }
    return 'Ouvert : $t';
  }

  /// Lit un fichier (début) ou liste un dossier.
  static Future<Object> read(String path) async {
    final p = expand(path);
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
    final f = File(p);
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: append ? FileMode.append : FileMode.write, flush: true);
    return '${append ? 'Ajouté à' : 'Écrit'} : $p (${content.length} caractères)';
  }
}
