import 'dart:convert';

import 'package:http/http.dart' as http;

/// Données publiques d'un jeu (« expérience ») Roblox, lues sur les mêmes
/// API que le site roblox.com (sans connexion). Les chiffres privés
/// (Robux gagnés, rétention…) restent sur le Creator Hub.
class RobloxGame {
  RobloxGame(this.universeId);
  final int universeId;

  int rootPlaceId = 0;
  String name = '';
  String description = '';
  String creator = '';
  String genre = '';
  int playing = 0;
  int visits = 0;
  int favorites = 0;
  int maxPlayers = 0;
  int upVotes = 0;
  int downVotes = 0;
  DateTime? created;
  DateTime? updated;
  String? icon;
  List<String> thumbnails = [];
  List<RobloxServer> servers = [];
  bool serversTruncated = false;
  List<RobloxBadge> badges = [];
  List<RobloxPass> passes = [];
  DateTime? fetchedAt;

  double? get likeRatio => upVotes + downVotes == 0 ? null : upVotes / (upVotes + downVotes);
  String get playUrl => 'https://www.roblox.com/games/$rootPlaceId';
  String get creatorHubUrl =>
      'https://create.roblox.com/dashboard/creations/experiences/$universeId/overview';
  String get analyticsUrl =>
      'https://create.roblox.com/dashboard/creations/experiences/$universeId/analytics/performance';
}

class RobloxServer {
  RobloxServer(this.id, this.playing, this.maxPlayers, this.ping, this.fps);
  final String id;
  final int playing;
  final int maxPlayers;
  final int? ping;
  final double? fps;
}

class RobloxBadge {
  RobloxBadge(this.id, this.name, this.awarded, this.pastDay, this.winRate, this.enabled);
  final int id;
  final String name;
  final int awarded;
  final int pastDay;

  /// Pourcentage des joueurs qui l'ont obtenu (rareté).
  final double winRate;
  final bool enabled;
  String? icon;
}

class RobloxPass {
  RobloxPass(this.id, this.name, this.price);
  final int id;
  final String name;
  final int? price;
  String? icon;
}

/// Un relevé enregistré sur l'appareil (pour les courbes d'évolution).
class GameSnapshot {
  GameSnapshot(this.at, this.playing, this.visits, this.favorites, this.up, this.down);
  final DateTime at;
  final int playing;
  final int visits;
  final int favorites;
  final int up;
  final int down;

  List<int> toJson() => [at.millisecondsSinceEpoch, playing, visits, favorites, up, down];

  static GameSnapshot? fromJson(Object? e) {
    if (e is! List || e.length < 6) return null;
    int n(int i) => (e[i] as num?)?.toInt() ?? 0;
    return GameSnapshot(DateTime.fromMillisecondsSinceEpoch(n(0)), n(1), n(2), n(3), n(4), n(5));
  }
}

class RobloxGamesApi {
  RobloxGamesApi([http.Client? client]) : _http = client ?? http.Client();
  final http.Client _http;

  Future<dynamic> _get(String url) async {
    final r = await _http
        .get(Uri.parse(url), headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 429) throw 'Roblox demande de ralentir, réessaie dans une minute';
    if (r.statusCode >= 400) throw 'Roblox : erreur ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  static int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  /// Trouve le jeu à partir d'un lien roblox.com/games/…, d'un ID de place
  /// ou d'un ID d'univers.
  Future<int> resolve(String input) async {
    final s = input.trim();
    final fromUrl = RegExp(r'games/(\d+)').firstMatch(s)?.group(1);
    final fromCreator = RegExp(r'experiences/(\d+)').firstMatch(s)?.group(1);
    if (fromCreator != null) return int.parse(fromCreator);
    final id = fromUrl ?? RegExp(r'^\d+$').firstMatch(s)?.group(0);
    if (id == null) throw 'Colle le lien de ton jeu (roblox.com/games/…) ou son ID';
    try {
      final j = await _get('https://apis.roblox.com/universes/v1/places/$id/universe');
      final u = _i((j as Map)['universeId']);
      if (u > 0) return u;
    } catch (_) {}
    // Ce n'était pas un ID de place : on essaie comme ID d'univers.
    final j = await _get('https://games.roblox.com/v1/games?universeIds=$id');
    if (((j as Map)['data'] as List?)?.isNotEmpty == true) return int.parse(id);
    throw 'Jeu introuvable';
  }

  /// Statistiques principales (léger : sert aussi au relevé régulier).
  Future<void> refreshStats(RobloxGame g) async {
    final d = await _get('https://games.roblox.com/v1/games?universeIds=${g.universeId}');
    final list = (d as Map)['data'] as List? ?? const [];
    if (list.isEmpty) throw 'Jeu introuvable (ID ${g.universeId})';
    final j = list.first as Map;
    g
      ..rootPlaceId = _i(j['rootPlaceId'])
      ..name = '${j['name'] ?? ''}'
      ..description = '${j['description'] ?? ''}'
      ..creator = '${(j['creator'] as Map?)?['name'] ?? ''}'
      ..genre = '${j['genre'] ?? ''}'
      ..playing = _i(j['playing'])
      ..visits = _i(j['visits'])
      ..favorites = _i(j['favoritedCount'])
      ..maxPlayers = _i(j['maxPlayers'])
      ..created = DateTime.tryParse('${j['created'] ?? ''}')?.toLocal()
      ..updated = DateTime.tryParse('${j['updated'] ?? ''}')?.toLocal();
    try {
      final v = await _get('https://games.roblox.com/v1/games/votes?universeIds=${g.universeId}');
      final vj = ((v as Map)['data'] as List).first as Map;
      g
        ..upVotes = _i(vj['upVotes'])
        ..downVotes = _i(vj['downVotes']);
    } catch (_) {}
    g.fetchedAt = DateTime.now();
  }

  /// Tout le tableau de bord : stats, images, serveurs, badges, passes.
  Future<void> refreshAll(RobloxGame g) async {
    await refreshStats(g);
    final u = g.universeId;
    await Future.wait([
      () async {
        final j = await _get(
          'https://thumbnails.roblox.com/v1/games/icons?universeIds=$u'
          '&returnPolicy=PlaceHolder&size=256x256&format=Png&isCircular=false',
        );
        g.icon = (((j as Map)['data'] as List?)?.firstOrNull as Map?)?['imageUrl'] as String?;
      }(),
      () async {
        final j = await _get(
          'https://thumbnails.roblox.com/v1/games/multiget/thumbnails?universeIds=$u'
          '&countPerUniverse=6&defaults=true&size=768x432&format=Png&isCircular=false',
        );
        final first = ((j as Map)['data'] as List?)?.firstOrNull as Map?;
        g.thumbnails = [
          for (final t in (first?['thumbnails'] as List?) ?? const [])
            if ((t as Map)['imageUrl'] != null) '${t['imageUrl']}',
        ];
      }(),
      _servers(g),
      _badges(g),
      _passes(g),
    ].map((f) => f.catchError((_) {})));
  }

  Future<void> _servers(RobloxGame g) async {
    if (g.rootPlaceId == 0) return;
    final out = <RobloxServer>[];
    String? cursor;
    for (var page = 0; page < 4; page++) {
      final j = await _get(
        'https://games.roblox.com/v1/games/${g.rootPlaceId}/servers/0'
        '?sortOrder=Desc&excludeFullGames=false&limit=100'
        '${cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}'}',
      ) as Map;
      for (final s in (j['data'] as List?) ?? const []) {
        final m = s as Map;
        out.add(RobloxServer(
          '${m['id']}',
          _i(m['playing']),
          _i(m['maxPlayers']),
          (m['ping'] as num?)?.toInt(),
          (m['fps'] as num?)?.toDouble(),
        ));
      }
      cursor = j['nextPageCursor'] as String?;
      if (cursor == null) break;
    }
    g.servers = out;
    g.serversTruncated = cursor != null;
  }

  Future<void> _badges(RobloxGame g) async {
    final j = await _get(
      'https://badges.roblox.com/v1/universes/${g.universeId}/badges?limit=100&sortOrder=Asc',
    ) as Map;
    final list = [
      for (final b in (j['data'] as List?) ?? const [])
        () {
          final m = b as Map;
          final st = m['statistics'] as Map? ?? const {};
          return RobloxBadge(
            _i(m['id']),
            '${m['name'] ?? ''}',
            _i(st['awardedCount']),
            _i(st['pastDayAwardedCount']),
            (st['winRatePercentage'] as num?)?.toDouble() ?? 0,
            m['enabled'] != false,
          );
        }(),
    ];
    if (list.isNotEmpty) {
      try {
        final ic = await _get(
          'https://thumbnails.roblox.com/v1/badges/icons?badgeIds=${list.map((b) => b.id).join(',')}'
          '&size=150x150&format=Png&isCircular=false',
        ) as Map;
        final byId = {for (final b in list) b.id: b};
        for (final t in (ic['data'] as List?) ?? const []) {
          byId[_i((t as Map)['targetId'])]?.icon = t['imageUrl'] as String?;
        }
      } catch (_) {}
    }
    g.badges = list;
  }

  Future<void> _passes(RobloxGame g) async {
    List<RobloxPass> list;
    try {
      final j = await _get(
        'https://apis.roblox.com/game-passes/v1/universes/${g.universeId}/game-passes'
        '?passView=Full&pageSize=100',
      ) as Map;
      list = [
        for (final p in (j['gamePasses'] as List?) ?? const [])
          RobloxPass(
            _i((p as Map)['id']),
            '${p['name'] ?? p['displayName'] ?? ''}',
            p['price'] == null ? null : _i(p['price']),
          ),
      ];
    } catch (_) {
      final j = await _get(
        'https://games.roblox.com/v1/games/${g.universeId}/game-passes?limit=100&sortOrder=Asc',
      ) as Map;
      list = [
        for (final p in (j['data'] as List?) ?? const [])
          RobloxPass(
            _i((p as Map)['id']),
            '${p['name'] ?? p['displayName'] ?? ''}',
            p['price'] == null ? null : _i(p['price']),
          ),
      ];
    }
    if (list.isNotEmpty) {
      try {
        final ic = await _get(
          'https://thumbnails.roblox.com/v1/game-passes?gamePassIds=${list.map((p) => p.id).join(',')}'
          '&size=150x150&format=Png&isCircular=false',
        ) as Map;
        final byId = {for (final p in list) p.id: p};
        for (final t in (ic['data'] as List?) ?? const []) {
          byId[_i((t as Map)['targetId'])]?.icon = t['imageUrl'] as String?;
        }
      } catch (_) {}
    }
    g.passes = list;
  }
}
