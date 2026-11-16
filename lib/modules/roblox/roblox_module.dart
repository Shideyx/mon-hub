import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';

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

  String get presenceLabel =>
      const ['Hors ligne', 'En ligne', 'En jeu', 'Dans Studio'][presence.clamp(0, 3)];
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
      body: jsonEncode({'usernames': [username], 'excludeBannedUsers': false}),
    );
    final data = jsonDecode(res.body)['data'] as List? ?? [];
    if (data.isEmpty) return null;
    final u = data.first as Map<String, dynamic>;
    return RobloxAccount(
        id: u['id'] as int,
        name: u['name'] as String,
        displayName: u['displayName'] as String);
  }

  Future<void> refresh(List<RobloxAccount> accounts) async {
    if (accounts.isEmpty) return;
    final ids = accounts.map((a) => a.id).toList();
    final byId = {for (final a in accounts) a.id: a};

    final thumbs = await _http.get(Uri.parse(
        'https://thumbnails.roblox.com/v1/users/avatar-headshot'
        '?userIds=${ids.join(',')}&size=150x150&format=Png&isCircular=true'));
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

    await Future.wait(accounts.map((a) async {
      final r = await _http.get(
          Uri.parse('https://friends.roblox.com/v1/users/${a.id}/friends/count'));
      a.friends = jsonDecode(r.body)['count'] as int?;
    }));
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
  String get description => 'Tes comptes Roblox : statut, amis, avatar';
  @override
  IconData get icon => Icons.sports_esports_outlined;
  @override
  Color get color => const Color(0xFFE2231A);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  List<RobloxAccount> _saved() {
    final raw = store.getJson<List<dynamic>>('accounts') ?? const [];
    return raw
        .map((e) => RobloxAccount(
            id: e['id'] as int,
            name: e['name'] as String,
            displayName: e['displayName'] as String))
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

  Future<void> addAccount(String username) async {
    final acc = await api.lookup(username);
    if (acc == null) throw 'Compte « $username » introuvable';
    final list = _saved()..removeWhere((a) => a.id == acc.id);
    list.add(acc);
    await _persist(list);
  }

  Future<void> removeAccount(RobloxAccount a) =>
      _persist(_saved()..removeWhere((x) => x.id == a.id));

  Future<void> _persist(List<RobloxAccount> list) async {
    await store.setJson('accounts', [
      for (final a in list)
        {'id': a.id, 'name': a.name, 'displayName': a.displayName}
    ]);
    await load(force: true);
  }

  Widget _avatar(RobloxAccount a, double r) => CircleAvatar(
        radius: r,
        backgroundImage: a.avatarUrl == null ? null : NetworkImage(a.avatarUrl!),
        child: a.avatarUrl == null ? Text(a.name[0].toUpperCase()) : null,
      );

  Color _presenceColor(int p) =>
      const [Colors.grey, Colors.blue, Colors.green, Colors.orange][p.clamp(0, 3)];

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => FutureBuilder(
          future: load(),
          initialData: _cache,
          builder: (context, snap) {
            final list = snap.data ?? [];
            if (list.isEmpty) {
              return const EmptyHint('Ajoute tes comptes Roblox', icon: Icons.add);
            }
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final a in list)
                  ListTile(
                    dense: true,
                    leading: _avatar(a, 16),
                    title: Text(a.displayName),
                    subtitle: Text('@${a.name}'),
                    trailing: Text(a.presenceLabel,
                        style: TextStyle(color: _presenceColor(a.presence))),
                  ),
              ],
            );
          },
        ),
      );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name), actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => load(force: true).then((_) => store.changed()),
          ),
        ]),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Ajouter un compte'),
            onPressed: () async {
              final r = await askFields(context,
                  title: 'Compte Roblox', labels: ['Nom d\'utilisateur']);
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
                        subtitle: Text([
                          a.presenceLabel,
                          if (a.location.isNotEmpty) a.location,
                          if (a.friends != null) '${a.friends} amis',
                        ].join(' · ')),
                        onTap: () => openLink(
                            context, 'https://www.roblox.com/users/${a.id}/profile'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => removeAccount(a),
                        ),
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
