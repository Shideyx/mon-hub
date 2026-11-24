import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import 'roblox_charts.dart';
import 'roblox_dashboard.dart';
import 'roblox_game.dart';

class RobloxAccount {
  RobloxAccount({
    required this.id,
    required this.name,
    required this.displayName,
    this.avatarUrl,
    this.friends,
    this.presence = 0,
    this.location = '',
  });

  final int id;
  final String name;
  final String displayName;
  String? avatarUrl;
  int? friends;

  /// 0 hors ligne, 1 en ligne, 2 en jeu, 3 dans Studio.
  int presence;
  String location;

  String get presenceLabel => const ['Hors ligne', 'En ligne', 'En jeu', 'Dans Studio'][presence.clamp(0, 3)];
}

/// API publiques Roblox (users / thumbnails / friends / presence).
/// Elles sont utilisées par le site lui-même et accessibles sans connexion,
/// mais Roblox ne les documente pas officiellement pour les tiers.
class RobloxApi {
  RobloxApi([http.Client? client]) : _http = client ?? http.Client();
  final http.Client _http;

  Future<RobloxAccount?> lookup(String username) async {
    final res = await _http.post(
      Uri.parse('https://users.roblox.com/v1/usernames/users'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'usernames': [username],
        'excludeBannedUsers': false,
      }),
    );
    final data = jsonDecode(res.body)['data'] as List? ?? [];
    if (data.isEmpty) return null;
    final u = data.first as Map<String, dynamic>;
    return RobloxAccount(id: u['id'] as int, name: u['name'] as String, displayName: u['displayName'] as String);
  }

  Future<void> refresh(List<RobloxAccount> accounts) async {
    if (accounts.isEmpty) return;
    final ids = accounts.map((a) => a.id).toList();
    final byId = {for (final a in accounts) a.id: a};

    final thumbs = await _http.get(
      Uri.parse(
        'https://thumbnails.roblox.com/v1/users/avatar-headshot'
        '?userIds=${ids.join(',')}&size=150x150&format=Png&isCircular=true',
      ),
    );
    for (final t in (jsonDecode(thumbs.body)['data'] as List? ?? [])) {
      byId[t['targetId']]?.avatarUrl = t['imageUrl'] as String?;
    }

    final presence = await _http.post(
      Uri.parse('https://presence.roblox.com/v1/presence/users'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'userIds': ids}),
    );
    for (final p in (jsonDecode(presence.body)['userPresences'] as List? ?? [])) {
      final a = byId[p['userId']];
      if (a == null) continue;
      a.presence = p['userPresenceType'] as int? ?? 0;
      a.location = p['lastLocation'] as String? ?? '';
    }

    await Future.wait(
      accounts.map((a) async {
        final r = await _http.get(Uri.parse('https://friends.roblox.com/v1/users/${a.id}/friends/count'));
        a.friends = jsonDecode(r.body)['count'] as int?;
      }),
    );
  }
}

class RobloxModule extends HubModule {
  final api = RobloxApi();
  List<RobloxAccount> _cache = [];
  Future<List<RobloxAccount>>? _loading;

  @override
  String get id => 'roblox';
  @override
  String get name => 'Roblox';
  @override
  String get description => 'Tableau de bord de ton jeu + tes comptes Roblox';
  @override
  IconData get icon => Icons.sports_esports_outlined;
  @override
  Color get color => const Color(0xFFE2231A);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  List<RobloxAccount> _saved() {
    final raw = store.getJson<List<dynamic>>('accounts') ?? const [];
    return raw
        .map(
          (e) => RobloxAccount(id: e['id'] as int, name: e['name'] as String, displayName: e['displayName'] as String),
        )
        .toList();
  }

  Future<List<RobloxAccount>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      final list = _saved();
      try {
        await api.refresh(list);
      } catch (_) {
        // Hors ligne : on affiche quand même les comptes.
      }
      return _cache = list;
    }();
  }

  // ---------- Mes jeux ----------

  final gamesApi = RobloxGamesApi();
  final _games = <int, RobloxGame>{};

  List<int> get gameIds => [for (final e in store.getJson<List<dynamic>>('games') ?? const []) (e as num).toInt()];

  int? get selectedGame {
    final s = store.getJson<int>('game');
    final ids = gameIds;
    return ids.contains(s) ? s : ids.firstOrNull;
  }

  Future<void> selectGame(int id) => store.setJson('game', id);

  RobloxGame game(int id) => _games[id] ??= RobloxGame(id);

  Future<RobloxGame> addGame(String input) async {
    final id = await gamesApi.resolve(input);
    final g = game(id);
    await gamesApi.refreshAll(g);
    record(g);
    await store.setJson('games', {...gameIds, id}.toList());
    await selectGame(id);
    return g;
  }

  Future<void> removeGame(int id) async {
    await store.setJson('games', gameIds.where((x) => x != id).toList());
    await store.setJson('hist.$id', null);
    _games.remove(id);
  }

  final _full = <int, Future<RobloxGame>>{};

  /// Données complètes (images, serveurs, badges…), rechargées au plus
  /// toutes les 60 s sauf [force].
  Future<RobloxGame> loadGame(int id, {bool force = false}) {
    final g = game(id);
    final fresh = g.fetchedAt != null && DateTime.now().difference(g.fetchedAt!).inSeconds < 60 && g.name.isNotEmpty;
    if (!force && fresh && _full[id] != null) return _full[id]!;
    return _full[id] = () async {
      try {
        await gamesApi.refreshAll(g);
        record(g);
      } catch (e) {
        _full.remove(id);
        rethrow;
      }
      return g;
    }();
  }

  /// Relevés enregistrés sur l'appareil (pour les courbes).
  List<GameSnapshot> history(int id) => [
    for (final e in store.getJson<List<dynamic>>('hist.$id') ?? const []) ?GameSnapshot.fromJson(e),
  ];

  /// Ajoute un relevé (au plus un toutes les 5 minutes).
  void record(RobloxGame g) {
    if (g.name.isEmpty) return;
    final h = history(g.universeId);
    final now = DateTime.now();
    if (h.isNotEmpty && now.difference(h.last.at).inMinutes < 5) return;
    h.add(GameSnapshot(now, g.playing, g.visits, g.favorites, g.upVotes, g.downVotes));
    // On garde ~30 jours : au-delà de 2 jours, un relevé par heure suffit.
    final cutoff = now.subtract(const Duration(days: 2));
    final kept = <GameSnapshot>[];
    DateTime? lastHour;
    for (final x in h) {
      if (now.difference(x.at).inDays > 60) continue;
      if (x.at.isBefore(cutoff)) {
        final hour = DateTime(x.at.year, x.at.month, x.at.day, x.at.hour);
        if (hour == lastHour) continue;
        lastHour = hour;
      }
      kept.add(x);
    }
    store.setJson('hist.${g.universeId}', [for (final x in kept) x.toJson()]);
  }

  DateTime? _lastGamePoll;

  @override
  Future<List<HubNotification>> poll() async {
    final ids = gameIds;
    if (ids.isEmpty) return const [];
    final last = _lastGamePoll;
    if (last != null && DateTime.now().difference(last).inMinutes < 10) return _gameAlerts;
    _lastGamePoll = DateTime.now();
    final out = <HubNotification>[];
    for (final id in ids) {
      final g = game(id);
      try {
        await gamesApi.refreshStats(g);
      } catch (_) {
        continue;
      }
      record(g);
      for (final (value, what, emoji) in [
        (g.visits, 'visites', '🚀'),
        (g.favorites, 'favoris', '⭐'),
        (g.playing, 'joueurs en même temps', '🎮'),
      ]) {
        final m = milestone(value);
        if (m > 0) {
          out.add(
            HubNotification(
              id: 'rbx:$id:$what:$m',
              title: '$emoji ${g.name} : ${fmtInt(m)} $what !',
              body: 'Ton jeu vient de passer ${fmtInt(m)} $what.',
            ),
          );
        }
      }
    }
    store.changed();
    return _gameAlerts = out;
  }

  List<HubNotification> _gameAlerts = const [];

  /// Plus grand palier (10, 25, 50, 100, 250…) atteint.
  static int milestone(int v) {
    var best = 0;
    for (var p = 10; p <= v; p *= 10) {
      for (final k in [1, 2.5, 5]) {
        final m = (p * k).round();
        if (m <= v) best = m;
      }
    }
    return best;
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'roblox_jeu_stats',
      description:
          'Statistiques du jeu Roblox suivi : joueurs en ligne, visites, '
          'favoris, j\'aime, serveurs, badges.',
      run: (_) async => [
        for (final id in gameIds)
          await loadGame(id).then(
            (g) => {
              'jeu': g.name,
              'joueurs_en_ligne': g.playing,
              'visites': g.visits,
              'favoris': g.favorites,
              'jaime': g.upVotes,
              'jaime_pas': g.downVotes,
              'serveurs': g.servers.length,
              'mis_a_jour': g.updated,
              'badges': [
                for (final b in g.badges.take(20)) {'nom': b.name, 'obtenu': b.awarded, 'taux': b.winRate},
              ],
            },
          ),
      ],
    ),
    HubTool(
      name: 'roblox_statut',
      description: 'Statut des comptes Roblox suivis (en ligne, en jeu…).',
      run: (_) async => [
        for (final a in await load(force: true)) {'pseudo': a.name, 'nom': a.displayName, 'statut': a.presenceLabel},
      ],
    ),
  ];

  Future<void> addAccount(String username) async {
    final acc = await api.lookup(username);
    if (acc == null) throw 'Compte « $username » introuvable';
    final list = _saved()..removeWhere((a) => a.id == acc.id);
    list.add(acc);
    await _persist(list);
  }

  Future<void> removeAccount(RobloxAccount a) => _persist(_saved()..removeWhere((x) => x.id == a.id));

  Future<void> _persist(List<RobloxAccount> list) async {
    await store.setJson('accounts', [
      for (final a in list) {'id': a.id, 'name': a.name, 'displayName': a.displayName},
    ]);
    await load(force: true);
  }

  Widget _avatar(RobloxAccount a, double r) => CircleAvatar(
    radius: r,
    backgroundImage: a.avatarUrl == null ? null : NetworkImage(a.avatarUrl!),
    child: a.avatarUrl == null ? Text(a.name[0].toUpperCase()) : null,
  );

  Color _presenceColor(int p) => const [Colors.grey, Colors.blue, Colors.green, Colors.orange][p.clamp(0, 3)];

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => selectedGame != null
        ? GameSummary(module: this, id: selectedGame!)
        : FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) {
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return const EmptyHint('Ajoute ton jeu ou tes comptes Roblox', icon: Icons.add);
              }
              // Les comptes en visages : l'anneau dit s'ils jouent.
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final a in list)
                        SummaryFace(
                          name: a.displayName,
                          url: a.avatarUrl,
                          color: color,
                          ring: a.presence == 0 ? null : _presenceColor(a.presence),
                          sub: a.presenceLabel,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );

  @override
  Widget buildPage(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(name),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Mon jeu'),
            Tab(text: 'Comptes'),
          ],
        ),
      ),
      body: TabBarView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          GameDashboard(module: this),
          _accountsPage(context),
        ],
      ),
    ),
  );

  Widget _accountsPage(BuildContext context) => Scaffold(
    floatingActionButton: Builder(
      builder: (context) => FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Ajouter un compte'),
        onPressed: () async {
          final r = await askFields(context, title: 'Compte Roblox', labels: ['Nom d\'utilisateur']);
          if (r == null || r[0].isEmpty) return;
          try {
            await addAccount(r[0]);
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        },
      ),
    ),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) => FutureBuilder(
        future: load(),
        initialData: _cache,
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (list.isEmpty) return const EmptyHint('Aucun compte');
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              for (final a in list)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: _avatar(a, 24),
                    title: Text('${a.displayName}  (@${a.name})'),
                    subtitle: Text(
                      [
                        a.presenceLabel,
                        if (a.location.isNotEmpty) a.location,
                        if (a.friends != null) '${a.friends} amis',
                      ].join(' · '),
                    ),
                    onTap: () => openLink(context, 'https://www.roblox.com/users/${a.id}/profile'),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => removeAccount(a)),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Le statut « en jeu » n\'apparaît que si le compte autorise '
                  'tout le monde à voir où il joue (paramètres de '
                  'confidentialité Roblox).',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
