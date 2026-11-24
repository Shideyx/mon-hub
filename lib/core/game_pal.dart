import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'hub_files.dart';
import 'prompt_shield.dart';

/// Reconnaître un jeu, **sans deviner** (v1.62).
///
/// Avant, « plein écran et pas dans une liste d'applis connues » = un jeu :
/// une appli agrandie qu'on ne connaissait pas (Claude, Notion, WhatsApp…)
/// devenait un jeu (« tu joues à Claude »). Maintenant il faut un **vrai
/// signe** : le jeu est rangé dans un dossier de jeux (Steam, Epic, Riot,
/// Xbox, Battle.net, Ubisoft, EA, GOG…), c'est un jeu connu, ou le titre
/// d'un site de jeux dans le navigateur. Sans signe : ce n'est pas un jeu.
class GameRules {
  const GameRules._();

  /// Programmes qui ne sont **jamais** des jeux, même dans un dossier
  /// bizarre (lanceurs, navigateurs, applis de discussion, outils).
  static final never = RegExp(
    r'^(chrome|msedge|firefox|opera|brave|vivaldi|arc|vlc|mpc-hc64|mpv|potplayer|powerpnt|winword|excel|onenote|outlook|'
    r'hub|explorer|applicationframehost|netflix|obs64|zoom|teams|ms-teams|slack|acrord32|acrobat|photos|code|devenv|'
    r'idea64|pycharm64|robloxstudiobeta|discord|spotify|lockapp|searchhost|shellexperiencehost|startmenuexperiencehost|'
    r'claude|chatgpt|notion|obsidian|figma|whatsapp|telegram|signal|messenger|snapchat|instagram|tiktok|capcut|'
    r'steam|steamwebhelper|epicgameslauncher|riotclientservices|riotclientux|battle\.net|eadesktop|origin|upc|'
    r'ubisoftconnect|galaxyclient|xboxapp|gamingservices|overwolf|medal|nvidia share|nvcontainer|radeonsoftware|'
    r'taskmgr|cmd|powershell|windowsterminal|wt|notepad|mspaint|snippingtool|calculatorapp|systemsettings)(\.exe)?$',
    caseSensitive: false,
  );

  /// Jeux connus par leur programme → leur nom.
  static const knownExe = {
    'robloxplayerbeta': 'Roblox',
    'windows10universal': 'Roblox',
    'javaw': 'Minecraft',
    'minecraft.windows': 'Minecraft',
    'minecraftlauncher': 'Minecraft',
    'fortniteclient-win64-shipping': 'Fortnite',
    'valorant-win64-shipping': 'Valorant',
    'league of legends': 'League of Legends',
    'r5apex': 'Apex Legends',
    'r5apex_dx12': 'Apex Legends',
    'cs2': 'Counter-Strike 2',
    'csgo': 'Counter-Strike',
    'gta5': 'GTA V',
    'gta5_enhanced': 'GTA V',
    'playgta5': 'GTA V',
    'rocketleague': 'Rocket League',
    'overwatch': 'Overwatch 2',
    'genshinimpact': 'Genshin Impact',
    'yuanshen': 'Genshin Impact',
    'starrail': 'Honkai: Star Rail',
    'zenlesszonezero': 'Zenless Zone Zero',
    'osu!': 'osu!',
    'terraria': 'Terraria',
    'stardew valley': 'Stardew Valley',
    'dota2': 'Dota 2',
    'hearthstone': 'Hearthstone',
    'eldenring': 'Elden Ring',
    'fifa23': 'EA Sports FC',
    'fc24': 'EA Sports FC',
    'fc25': 'EA Sports FC',
    'fc26': 'EA Sports FC',
    'rainbowsix': 'Rainbow Six Siege',
    'rainbowsix_vulkan': 'Rainbow Six Siege',
    'cod': 'Call of Duty',
    'cod24-cod': 'Call of Duty',
    'brawlhalla': 'Brawlhalla',
    'among us': 'Among Us',
    'fallguys_client_game': 'Fall Guys',
    'rust': 'Rust',
    'rustclient': 'Rust',
    'hollow_knight': 'Hollow Knight',
    'deadbycaylight-win64-shipping': 'Dead by Daylight',
    'palworld-win64-shipping': 'Palworld',
    'helldivers2': 'Helldivers 2',
    'cyberpunk2077': 'Cyberpunk 2077',
    'witcher3': 'The Witcher 3',
    'thesims4': 'Les Sims 4',
    'ts4_x64': 'Les Sims 4',
    'marvelrivals_launcher': 'Marvel Rivals',
    'marvel-win64-shipping': 'Marvel Rivals',
  };

  /// Dossiers où les jeux sont installés → nom du dossier du jeu juste après.
  static final _gameFolders = [
    RegExp(r'[\\/]steamapps[\\/]common[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]Epic Games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]Riot Games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]XboxGames[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]Ubisoft Game Launcher[\\/]games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]EA Games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]GOG Galaxy[\\/]Games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]GOG Games[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/](?:Battle\.net|Blizzard)[\\/]([^\\/]+)', caseSensitive: false),
    RegExp(r'[\\/]Roblox[\\/]Versions[\\/]', caseSensitive: false),
    RegExp(r'[\\/]itch[\\/]apps[\\/]([^\\/]+)', caseSensitive: false),
  ];

  /// Sites de jeux dans le navigateur (titre de l'onglet).
  static final _webGames = RegExp(
    r'\b(poki|crazygames|jeux\.fr|jeu\.fr|miniclip|agar\.io|slither\.io|krunker|lichess|chess\.com|geoguessr|'
    r'skribbl|gartic|wordle|y8|friv|coolmathgames|1001 ?jeux|shellshock)\b',
    caseSensitive: false,
  );

  static String _base(String exe) =>
      exe.trim().split(RegExp(r'[\\/]')).last.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');

  /// Le nom du jeu, ou null si ce n'est **pas** un jeu.
  /// [engine] : le dossier du programme contient UnityPlayer.dll / un
  /// dossier « _Data » (Unity) ou c'est un « -Win64-Shipping » (Unreal).
  static String? gameOf({required String exe, String path = '', String title = '', bool engine = false}) {
    final e = _base(exe.isEmpty ? path : exe);
    if (e.isEmpty) return null;
    // Navigateur : seulement un site de jeux reconnu.
    if (RegExp(r'^(chrome|msedge|firefox|opera|brave|vivaldi|arc)$').hasMatch(e)) {
      final m = _webGames.firstMatch(title);
      if (m == null) return null;
      final t = title.split(RegExp(r'\s+[-–|]\s+')).first.trim();
      return t.isEmpty || t.length > 40 ? m.group(1)! : t;
    }
    if (never.hasMatch(e)) return null;
    // Java : Minecraft seulement si la fenêtre le dit (sinon c'est peut-être
    // un logiciel de cours en Java).
    if (e == 'javaw' || e == 'java') {
      return title.isEmpty || RegExp(r'minecraft', caseSensitive: false).hasMatch(title) ? 'Minecraft' : null;
    }
    if (knownExe[e] case final n?) return n;
    for (final re in _gameFolders) {
      final m = re.firstMatch(path);
      if (m == null) continue;
      if (m.groupCount == 0 || m.group(1) == null) return 'Roblox';
      return _tidy(m.group(1)!);
    }
    if (e.endsWith('-win64-shipping') || e.endsWith('-wingdk-shipping')) {
      return _tidy(e.replaceFirst(RegExp(r'-win(?:64|gdk)-shipping$'), ''));
    }
    if (engine) return _tidy(title.isNotEmpty && title.length <= 40 ? title : e);
    return null;
  }

  /// « EldenRing » → « Elden Ring », « hollow_knight » → « Hollow knight ».
  static String _tidy(String s) {
    var t = s.replaceAll(RegExp(r'[_]+'), ' ').replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return s;
    return t[0].toUpperCase() + t.substring(1);
  }

  /// Ce que Smily sait du jeu, pour les consignes de l'IA.
  static String promptLine(String game, {String summary = '', String genres = '', Duration played = Duration.zero}) {
    final b = StringBuffer('La personne joue en ce moment à **$game**');
    if (played.inMinutes >= 1) b.write(' (depuis ${played.inMinutes} min)');
    b.write('.');
    if (genres.isNotEmpty) b.write(' Genre : $genres.');
    if (summary.isNotEmpty) b.write(' Le jeu : $summary');
    b.write(
      '\nSi elle te parle du jeu (« aide-moi », « comment je passe ça », « c\'est quoi le meilleur… »), aide-la '
      'vraiment : regarde la capture d\'écran pour voir où elle en est, donne des astuces concrètes et courtes '
      '(touches, stratégie, où aller), cherche sur internet (wiki du jeu) si tu n\'es pas sûr. Pas de triche en '
      'ligne (logiciels, exploits) : ça fait bannir le compte. Ne lui fais pas la morale sur le temps de jeu.',
    );
    return b.toString();
  }
}

/// Ce qu'on a trouvé sur un jeu (gardé dans `jeux-infos.json`).
class GameInfo {
  const GameInfo({required this.name, this.summary = '', this.genres = '', this.url = '', this.at});

  final String name;
  final String summary;
  final String genres;
  final String url;
  final DateTime? at;

  Map<String, dynamic> toJson() => {
    'nom': name,
    if (summary.isNotEmpty) 'resume': summary,
    if (genres.isNotEmpty) 'genres': genres,
    if (url.isNotEmpty) 'lien': url,
    if (at != null) 'quand': at!.toIso8601String(),
  };

  static GameInfo? fromJson(Object? j) {
    if (j is! Map || '${j['nom'] ?? ''}'.isEmpty) return null;
    return GameInfo(
      name: '${j['nom']}',
      summary: '${j['resume'] ?? ''}',
      genres: '${j['genres'] ?? ''}',
      url: '${j['lien'] ?? ''}',
      at: DateTime.tryParse('${j['quand'] ?? ''}'),
    );
  }

  /// Le texte d'une fiche Steam (sans balises), coupé proprement.
  static String clean(String s, {int max = 320}) {
    var t = s.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'&quot;'), '"').replaceAll('&amp;', '&');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    final cut = t.lastIndexOf('. ', max);
    return cut > 80 ? t.substring(0, cut + 1) : '${t.substring(0, max)}…';
  }
}

/// **Smily et tes jeux** : il reconnaît le jeu au premier plan, va lire ce
/// qu'il y a à savoir dessus (fiche Steam en français, sinon Wikipédia), et
/// s'en sert quand tu lui demandes de l'aide. Rien n'est envoyé ailleurs que
/// ces deux sites publics (seulement le nom du jeu).
class GamePal {
  GamePal._();
  static final instance = GamePal._();

  /// Pour les tests.
  http.Client? client;

  String current = '';
  DateTime? since;

  final _infos = JsonFile<Map<String, dynamic>>(
    'jeux-infos.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  /// Petit fichier lu par Smily partout (l'autre programme).
  final _now = JsonFile<Map<String, dynamic>>(
    'jeu-en-cours.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  final _fetching = <String>{};

  /// Le programme est-il fait avec Unity / Unreal ? (fichiers à côté du .exe)
  static bool engineNear(String path) {
    if (path.isEmpty || !Platform.isWindows) return false;
    try {
      final dir = File(path).parent;
      final base = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');
      return File('${dir.path}\\UnityPlayer.dll').existsSync() ||
          Directory('${dir.path}\\${base}_Data').existsSync() ||
          Directory('${dir.path}\\Engine\\Binaries').existsSync();
    } catch (_) {
      return false;
    }
  }

  final _engineCache = <String, bool>{};

  /// Le jeu au premier plan (ou null).
  String? detect({required String exe, String path = '', String title = ''}) {
    final engine = path.isEmpty ? false : (_engineCache[path] ??= engineNear(path));
    return GameRules.gameOf(exe: exe, path: path, title: title, engine: engine);
  }

  /// Un tour (toutes les 15 s, dans Mon Hub).
  Future<void> tick({required String exe, String path = '', String title = '', DateTime? now}) async {
    final n = now ?? DateTime.now();
    final g = detect(exe: exe, path: path, title: title) ?? '';
    if (g == current) {
      if (g.isNotEmpty) await _publish(n);
      return;
    }
    current = g;
    since = g.isEmpty ? null : n;
    if (g.isNotEmpty) unawaited(info(g));
    await _publish(n);
  }

  Future<void> _publish(DateTime n) async {
    try {
      if (current.isEmpty) {
        await _now.save(<String, dynamic>{});
        return;
      }
      final i = await cached(current);
      await _now.save({
        'jeu': current,
        'depuis': since?.millisecondsSinceEpoch,
        'at': n.millisecondsSinceEpoch,
        if (i != null) ...i.toJson(),
      });
    } catch (_) {}
  }

  Future<GameInfo?> cached(String game) async {
    try {
      await _infos.load();
      return GameInfo.fromJson(_infos.value[game.toLowerCase()]);
    } catch (_) {
      return null;
    }
  }

  /// Ce qu'il sait du jeu (cherché une fois, gardé 30 jours).
  Future<GameInfo?> info(String game, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    final old = await cached(game);
    if (old != null && old.at != null && n.difference(old.at!) < const Duration(days: 30)) return old;
    if (!_fetching.add(game)) return old;
    try {
      final found = await _steam(game) ?? await _wiki(game);
      if (found == null) return old;
      final i = GameInfo(name: game, summary: found.summary, genres: found.genres, url: found.url, at: n);
      await _infos.update((v) => {...v, game.toLowerCase(): i.toJson()});
      return i;
    } catch (_) {
      return old;
    } finally {
      _fetching.remove(game);
    }
  }

  http.Client get _http => client ?? http.Client();

  Future<GameInfo?> _steam(String game) async {
    final c = _http;
    final s = await c
        .get(
          Uri.https('store.steampowered.com', '/api/storesearch/', {'term': game, 'l': 'french', 'cc': 'FR'}),
        )
        .timeout(const Duration(seconds: 8));
    if (s.statusCode != 200) return null;
    final items = (jsonDecode(s.body) as Map)['items'];
    if (items is! List || items.isEmpty) return null;
    final first = items.first as Map;
    final id = first['id'];
    final d = await c
        .get(Uri.https('store.steampowered.com', '/api/appdetails', {'appids': '$id', 'l': 'french', 'cc': 'FR'}))
        .timeout(const Duration(seconds: 8));
    if (d.statusCode != 200) return null;
    final data = ((jsonDecode(d.body) as Map)['$id'] as Map?)?['data'];
    if (data is! Map) return null;
    final genres = [
      if (data['genres'] is List)
        for (final g in data['genres'] as List)
          if (g is Map) '${g['description']}',
    ].take(3).join(', ');
    return GameInfo(
      name: '${data['name'] ?? game}',
      summary: GameInfo.clean('${data['short_description'] ?? ''}'),
      genres: genres,
      url: 'https://store.steampowered.com/app/$id',
    );
  }

  Future<GameInfo?> _wiki(String game) async {
    final c = _http;
    final s = await c
        .get(
          Uri.https('fr.wikipedia.org', '/w/api.php', {
            'action': 'query',
            'list': 'search',
            'srsearch': '$game jeu vidéo',
            'srlimit': '1',
            'format': 'json',
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (s.statusCode != 200) return null;
    final hits = ((jsonDecode(s.body) as Map)['query'] as Map?)?['search'];
    if (hits is! List || hits.isEmpty) return null;
    final title = '${(hits.first as Map)['title']}';
    final p = await c
        .get(Uri.https('fr.wikipedia.org', '/api/rest_v1/page/summary/${Uri.encodeComponent(title)}'))
        .timeout(const Duration(seconds: 8));
    if (p.statusCode != 200) return null;
    final j = jsonDecode(p.body) as Map;
    return GameInfo(
      name: game,
      summary: GameInfo.clean('${j['extract'] ?? ''}'),
      url: 'https://fr.wikipedia.org/wiki/${Uri.encodeComponent(title)}',
    );
  }

  /// Le bloc des consignes (lu dans le petit fichier : marche aussi dans
  /// Smily partout). Vide si on ne joue pas.
  static Future<String> promptBlock({DateTime? now}) async {
    final f = instance._now;
    try {
      await f.load();
    } catch (_) {
      return '';
    }
    final j = f.value;
    final game = '${j['jeu'] ?? ''}';
    final at = j['at'] is num ? DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()) : null;
    final n = now ?? DateTime.now();
    if (game.isEmpty || at == null || n.difference(at) > const Duration(minutes: 2)) return '';
    final since = j['depuis'] is num ? DateTime.fromMillisecondsSinceEpoch((j['depuis'] as num).toInt()) : null;
    final line = GameRules.promptLine(
      game,
      summary: '${j['resume'] ?? ''}',
      genres: '${j['genres'] ?? ''}',
      played: since == null ? Duration.zero : n.difference(since),
    );
    return '${PromptShield.wrap('jeu_en_cours', line)}\n';
  }

  /// Pour l'outil `jeu_en_cours`.
  Future<Map<String, Object?>> describe() async {
    if (current.isEmpty) return {'jeu': null, 'info': 'Aucun jeu au premier plan.'};
    final i = await info(current);
    return {
      'jeu': current,
      'depuis_minutes': since == null ? 0 : DateTime.now().difference(since!).inMinutes,
      if (i != null) ...i.toJson(),
    };
  }
}
