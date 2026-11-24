import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import 'shot_encode.dart';
import '../../core/token_budget.dart';

/// Cerveau « Claude Pro » de Nexo : ton propre Claude Code, connecté à ton
/// abonnement Claude (Pro, Max…).
///
/// Mon Hub ne voit **jamais** ta connexion : tu te connectes toi-même dans
/// Claude Code (la page officielle d'Anthropic s'ouvre), puis Mon Hub lance
/// simplement le programme officiel `claude`, sans le modifier, comme tu le
/// ferais dans un terminal (c'est ce qu'Anthropic autorise). Les questions
/// comptent dans les limites de ton abonnement.
///
/// Claude Code reçoit la capture d'écran et peut utiliser les actions de
/// Mon Hub (agenda, notes, messages…) et celles de Nexo (contrôle du PC,
/// avec ta permission) via le pont local (`/mcp`), mais aucun de ses propres
/// outils de programmation.
class ClaudeCode {
  ClaudeCode._();

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static const models = {
    '': 'Celui de ton abonnement (par défaut)',
    // Conseillé : Nexo n'appelle plus Claude que pour les demandes
    // difficiles, autant qu'elles aient le meilleur.
    'claude-opus-5-5': 'Claude Opus 5.5 (conseillé)',
    'sonnet': 'Sonnet (rapide)',
    'opus': 'Opus (le plus malin)',
    'haiku': 'Haiku (le plus rapide)',
  };

  static String get model {
    final m = ClaudeApi.store.getJson<String>('claudecode.model') ?? '';
    if (models.containsKey(m)) return m;
    // Économe : Sonnet (moins de ton forfait Claude utilisé), Opus seulement
    // pour « réfléchis bien ».
    return ClaudeApi.econome && !ClaudeApi.deep ? 'sonnet' : '';
  }

  static Future<void> setModel(String m) => ClaudeApi.store.setJson('claudecode.model', m);

  static String? _path;
  static DateTime? _foundAt;

  /// Où est installé `claude` (null s'il n'est pas installé).
  static Future<String?> find({bool refresh = false}) async {
    if (!supported) return null;
    final at = _foundAt;
    if (!refresh && at != null && DateTime.now().difference(at).inMinutes < 2) return _path;
    _foundAt = DateTime.now();
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final candidates = Platform.isWindows
        ? [
            '$home\\.local\\bin\\claude.exe',
            '${env['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\claude.exe',
            '${env['APPDATA']}\\npm\\claude.cmd',
          ]
        : [
            '$home/.local/bin/claude',
            '/opt/homebrew/bin/claude',
            '/usr/local/bin/claude',
            '/usr/bin/claude',
            '$home/.npm-global/bin/claude',
          ];
    for (final c in candidates) {
      if (await File(c).exists()) return _path = c;
    }
    // Sinon : on demande au système (PATH).
    try {
      final out = Platform.isWindows
          ? await _hiddenOutput('where.exe', ['claude'])
          : '${(await Process.run('/bin/sh', ['-lc', 'command -v claude'])).stdout}';
      final first = out
          .split(RegExp(r'[\r\n]+'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('INFO'))
          .firstOrNull;
      if (first != null && await File(first).exists()) return _path = first;
    } catch (_) {}
    return _path = null;
  }

  /// Sortie d'une commande Windows lancée sans fenêtre de console.
  static Future<String> _hiddenOutput(String exe, List<String> args) async {
    final p = await Process.start(exe, args, mode: ProcessStartMode.detachedWithStdio);
    await p.stdin.close();
    return p.stdout.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
  }

  /// Lance `claude` sans fenêtre de console (Windows : processus détaché,
  /// avec ses entrées / sorties branchées sur Mon Hub).
  static Future<Process> _start(String path, List<String> args, {String? cwd}) => Process.start(
    path,
    args,
    workingDirectory: cwd,
    runInShell: Platform.isWindows && path.toLowerCase().endsWith('.cmd'),
    mode: Platform.isWindows ? ProcessStartMode.detachedWithStdio : ProcessStartMode.normal,
  );

  /// État de la connexion : (connecté ?, détail lisible).
  static Future<(bool, String)> status() async {
    final path = await find(refresh: true);
    if (path == null) return (false, 'Claude Code n\'est pas installé sur ce PC.');
    try {
      final p = await _start(path, ['auth', 'status']);
      await p.stdin.close();
      final out = await p.stdout.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      final j = jsonDecode(out.substring(out.indexOf('{'))) as Map;
      final method = '${j['authMethod'] ?? 'none'}';
      final who = j['email'] ?? j['account']?['email'] ?? '';
      if (method == 'none' || j['loggedIn'] == false) {
        return (false, 'Claude Code est installé, mais pas encore connecté à ton compte.');
      }
      final plan = '${j['subscriptionType'] ?? j['plan'] ?? ''}'.trim();
      return (true, 'Connecté${who == '' ? '' : ' : $who'}${plan.isEmpty || plan == 'null' ? '' : ' ($plan)'}');
    } catch (_) {
      return (false, 'Claude Code est installé, mais sa connexion n\'a pas pu être vérifiée.');
    }
  }

  static String _ps(String s) => "'${s.replaceAll("'", "''")}'";

  /// Ouvre la connexion officielle (une fenêtre Claude Code + ton navigateur).
  static Future<void> openLogin() async {
    final path = await find(refresh: true);
    if (path == null) return;
    if (Platform.isWindows) {
      await Process.start('powershell.exe', [
        '-NoProfile',
        '-Command',
        'Start-Process -FilePath ${_ps(path)} -ArgumentList \'auth\',\'login\'',
      ]);
    } else if (Platform.isMacOS) {
      await Process.start('osascript', [
        '-e',
        'tell application "Terminal" to do script "\\"$path\\" auth login"',
        '-e',
        'tell application "Terminal" to activate',
      ]);
    } else {
      await Process.start('x-terminal-emulator', ['-e', path, 'auth', 'login']);
    }
  }

  /// Installe Claude Code avec la commande officielle (Windows), dans une
  /// fenêtre PowerShell visible.
  static Future<bool> install() async {
    if (!Platform.isWindows) return false;
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-Command',
      "Start-Process powershell -ArgumentList '-NoExit','-Command','irm https://claude.ai/install.ps1 | iex'",
    ]);
    return true;
  }

  /// Dossier de travail vide, pour que Claude Code ne charge aucun projet.
  static Future<Directory> _workdir() async {
    final base = ClaudeBridge.folder;
    final dir = Directory(
      base == null
          ? '${Directory.systemTemp.path}${Platform.pathSeparator}monhub-clicky'
          : '$base${Platform.pathSeparator}clicky-claude-code',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// Actions de Mon Hub : adresse du pont local, lue dans bridge.json.
  static Map<String, dynamic>? _mcpConfig([Set<String>? groups]) {
    final dir = ClaudeBridge.folder;
    if (dir == null) return null;
    try {
      final info = jsonDecode(File('$dir${Platform.pathSeparator}bridge.json').readAsStringSync()) as Map;
      return {
        'mcpServers': {
          'monhub': {
            'type': 'http',
            // Nexo économe : seulement les actions utiles à la question.
            'url':
                'http://127.0.0.1:${info['port']}/mcp'
                '${groups == null || groups.isEmpty ? '' : '?groupes=${Uri.encodeQueryComponent(groups.join(','))}'}',
            'headers': {'Authorization': 'Bearer ${info['key']}'},
          },
        },
      };
    } catch (_) {
      return null;
    }
  }

  /// Une question à Claude (avec captures d'écran). Le texte arrive au fur et
  /// à mesure via [onText].
  static Future<String> ask({
    required String system,
    required String question,
    List<String> imagesB64 = const [],
    List<String> imageLabels = const [],
    bool withTools = true,
    String? effort,
    bool web = false,
    Set<String>? groups,
    List<Map<String, dynamic>> extraBlocks = const [],
    void Function(String text)? onText,
    void Function(String status)? onStatus,
  }) async {
    final path = await find();
    if (path == null) {
      throw 'Claude Code n\'est pas installé : module Claude → Réglages → « Installer Claude Code ».';
    }
    final dir = await _workdir();
    final sep = Platform.pathSeparator;
    final sysFile = File('${dir.path}${sep}clicky-system.txt');
    await sysFile.writeAsString(system);
    final mcp = withTools ? _mcpConfig(groups) : null;
    final mcpFile = File('${dir.path}${sep}clicky-mcp.json');
    if (mcp != null) await mcpFile.writeAsString(jsonEncode(mcp));

    final args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      // Aucun outil de programmation : ni commandes, ni fichiers. Seulement,
      // si tu l'as permis, la recherche web d'Anthropic.
      '--tools', web ? 'WebSearch,WebFetch' : '',
      '--permission-mode', 'dontAsk',
      '--system-prompt-file', sysFile.path,
      '--no-session-persistence',
      '--max-turns', '12',
      // Seulement les actions de Mon Hub (pas tes autres serveurs MCP).
      '--strict-mcp-config',
      if (mcp != null) ...['--mcp-config', mcpFile.path],
      if (mcp != null || web) ...[
        '--allowedTools',
        [
          if (mcp != null) 'mcp__monhub',
          if (web) ...['WebSearch', 'WebFetch'],
        ].join(','),
      ],
      if (model.isNotEmpty) ...['--model', model],
      if (effort != null) ...['--effort', effort],
    ];

    final Process p;
    try {
      p = await _start(path, args, cwd: dir.path);
    } catch (e) {
      throw 'Impossible de lancer Claude Code : $e';
    }
    final message = {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          for (var i = 0; i < imagesB64.length; i++) ...[
            if (i < imageLabels.length) {'type': 'text', 'text': imageLabels[i]},
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': imageMime(imagesB64[i]), 'data': imagesB64[i]},
            },
          ],
          ...extraBlocks,
          {'type': 'text', 'text': question},
        ],
      },
      'parent_tool_use_id': null,
    };
    p.stdin.writeln(jsonEncode(message));
    await p.stdin.flush();
    await p.stdin.close();

    _running.add(p);
    final errors = StringBuffer();
    final errSub = p.stderr.transform(utf8.decoder).listen((s) {
      if (errors.length < 4000) errors.write(s);
    });
    var current = '';
    String? result;
    var failed = false;
    try {
      await for (final line
          in p.stdout.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(minutes: 4))) {
        if (!line.startsWith('{')) continue;
        final Map e;
        try {
          e = jsonDecode(line) as Map;
        } catch (_) {
          continue;
        }
        switch (e['type']) {
          case 'stream_event':
            final ev = e['event'] as Map? ?? const {};
            if (ev['type'] == 'message_start') current = '';
            final d = ev['delta'] as Map?;
            if (ev['type'] == 'content_block_delta' && d?['type'] == 'text_delta') {
              current += '${d!['text']}';
              onText?.call(current);
            }
          case 'assistant':
            for (final b in ((e['message'] as Map?)?['content'] as List?) ?? const []) {
              if (b is Map && b['type'] == 'tool_use') {
                final name = '${b['name']}';
                onStatus?.call(switch (name) {
                  'WebSearch' => 'Je cherche sur internet…',
                  'WebFetch' => 'Je lis une page web…',
                  'mcp__monhub__pc_commande' => 'J\'agis sur ton PC…',
                  'mcp__monhub__pc_ouvrir' => 'J\'ouvre ça…',
                  'mcp__monhub__pc_lire' => 'Je regarde sur ton PC…',
                  'mcp__monhub__pc_ecrire_fichier' => 'J\'écris le fichier…',
                  'mcp__monhub__clicky_reparer_micro' => 'Je répare le micro…',
                  _ => 'J\'utilise ${name.replaceFirst('mcp__monhub__', '').replaceAll('_', ' ')}…',
                });
              }
            }
          case 'system':
            if (e['subtype'] == 'api_retry') onStatus?.call('Claude est occupé, je réessaie…');
          case 'result':
            result = '${e['result'] ?? ''}';
            // Les jetons de la réponse (abonnement : pas facturés à l'unité,
            // mais comptés pour que Nexo se règle).
            final u = e['usage'];
            if (u is Map) unawaited(TokenBudget.instance.recordClaude(ClaudeApi.model, u).catchError((Object _) {}));
            failed = e['is_error'] == true || '${e['subtype']}' != 'success';
        }
      }
    } on TimeoutException {
      p.kill();
      throw 'Claude Code met trop de temps à répondre, réessaie.';
    } finally {
      _running.remove(p);
      await errSub.cancel();
    }
    if (_cancelled.remove(p)) throw const ClaudeCodeCancelled();
    final text = (result ?? current).trim();
    if (failed || (result == null && text.isEmpty)) throw _explain('$text\n$errors');
    return text;
  }

  static final _running = <Process>{};
  static final _cancelled = <Process>{};

  /// Une réponse est en cours.
  static bool get busy => _running.isNotEmpty;

  /// Arrête toutes les réponses en cours (Échap, « stop »).
  static void cancelAll() {
    for (final p in [..._running]) {
      _cancelled.add(p);
      try {
        p.kill();
      } catch (_) {}
    }
  }

  /// Message d'erreur compréhensible.
  static String _explain(String raw) {
    final r = raw.toLowerCase();
    if (r.contains('login') || r.contains('log in') || r.contains('authenticat') || r.contains('api key')) {
      return 'Claude Code n\'est pas connecté à ton compte : module Claude → Réglages → « Se connecter ».';
    }
    if (r.contains('usage limit') || r.contains('limit reached') || r.contains('rate limit')) {
      return 'Tu as atteint la limite de ton abonnement Claude pour le moment. Réessaie plus tard.';
    }
    if (r.contains('not supported') && r.contains('model')) {
      return 'Ce modèle n\'est pas disponible avec ton abonnement : choisis « par défaut » dans les réglages.';
    }
    final first = raw.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return first.isEmpty ? 'Claude Code n\'a pas pu répondre.' : 'Claude Code : $first';
  }
}

/// La réponse a été arrêtée (Échap, « stop »).
class ClaudeCodeCancelled implements Exception {
  const ClaudeCodeCancelled();
  @override
  String toString() => 'Réponse arrêtée.';
}
