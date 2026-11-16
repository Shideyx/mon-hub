import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';
import 'discord_api.dart';

/// Discord : tes messages privés (avec ton jeton, lecture seule) + l'état de
/// tes serveurs via le widget public officiel.
class DiscordModule extends HubModule {
  @override
  String get id => 'discord';
  @override
  String get name => 'Discord';
  @override
  String get description => 'Tes messages privés et tes serveurs';
  @override
  IconData get icon => Icons.forum_rounded;
  @override
  Color get color => const Color(0xFF5865F2);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  DiscordApi? _api;
  DiscordUser? me;
  List<DiscordDm> _dms = [];
  final _lastSeenId = <String, String>{};
  final _lastMsg = <String, DiscordMessage>{};
  Future<List<DiscordDm>>? _loading;
  String? lastError;

  bool get connected => store.getJson<bool>('connected') == true;

  Future<DiscordApi?> _client() async {
    if (_api != null) return _api;
    final t = await store.readSecret('token');
    if (t == null || t.isEmpty) return null;
    return _api = DiscordApi(t);
  }

  Map<String, String> get _readUpTo =>
      (store.getJson<Map<String, dynamic>>('read') ?? const {}).cast<String, String>();

  bool _isNewer(String? a, String? b) =>
      (BigInt.tryParse(a ?? '0') ?? BigInt.zero) > (BigInt.tryParse(b ?? '0') ?? BigInt.zero);

  bool isUnread(DiscordDm d) =>
      d.last != null &&
      d.last!.author.id != me?.id &&
      _isNewer(d.lastMessageId, _readUpTo[d.id]);

  Future<List<DiscordDm>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      final api = await _client();
      if (api == null) return _dms = [];
      try {
        lastError = null;
        me ??= await api.me();
        final dms = await api.dms();
        // La liste s'affiche tout de suite, même si la lecture des derniers
        // messages échoue ensuite (avant : tout restait vide jusqu'à une
        // reconnexion).
        for (final d in dms) {
          d.last = _lastMsg[d.id];
        }
        _dms = dms;
        // On ne relit que les conversations qui ont bougé (10 plus récentes),
        // pour rester discret vis-à-vis de Discord.
        for (final d in dms.take(10)) {
          if (d.lastMessageId == null) continue;
          if (_lastSeenId[d.id] != d.lastMessageId || _lastMsg[d.id] == null) {
            try {
              final msgs = await api.messages(d.id, limit: 1);
              if (msgs.isNotEmpty) _lastMsg[d.id] = msgs.first;
              _lastSeenId[d.id] = d.lastMessageId!;
            } catch (_) {
              // Une conversation illisible n'empêche pas les autres.
            }
          }
          d.last = _lastMsg[d.id];
        }
        badge.value = dms.where(isUnread).length;
      } catch (e) {
        lastError = '$e';
        if ('$e'.contains('expirée')) {
          _api = null;
        }
      }
      if (lastError != null && _dms.isEmpty) _loading = null;
      return _dms;
    }();
  }

  @override
  List<HubTool> get tools => [
        HubTool(
          name: 'discord_conversations',
          description: 'Conversations privées Discord (MP) avec le dernier message.',
          run: (_) async {
            final dms = await load();
            if (lastError != null && dms.isEmpty) throw lastError!;
            return [
              for (final d in dms.take(25))
                {
                  'id': d.id,
                  'nom': d.name,
                  if (d.last != null) 'dernier': '${d.last!.author.name} : ${d.last!.content}',
                  'non_lu': isUnread(d),
                },
            ];
          },
        ),
        HubTool(
          name: 'discord_messages',
          description: 'Messages d\'une conversation Discord.',
          params: {'id': ('string', 'id donné par discord_conversations')},
          required: ['id'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Discord n\'est pas connecté';
            return [
              for (final m in (await api.messages(a['id'] as String)).reversed)
                {'de': m.author.name, 'texte': m.content, 'date': m.at},
            ];
          },
        ),
        HubTool(
          name: 'discord_envoyer',
          description: 'Envoie un message dans une conversation Discord.',
          params: {'id': ('string', 'id de la conversation'), 'texte': ('string', 'Message')},
          required: ['id', 'texte'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Discord n\'est pas connecté';
            await api.send(a['id'] as String, a['texte'] as String);
            return {'ok': true};
          },
        ),
      ];

  @override
  Future<List<HubNotification>> poll() async {
    if (!connected) return const [];
    final dms = await load(force: true);
    store.changed();
    return [
      for (final d in dms.take(8))
        if (d.last != null && d.last!.author.id != me?.id)
          HubNotification(
            id: d.last!.id,
            title: 'Discord · ${d.last!.author.name}',
            body: d.last!.content,
          ),
    ];
  }

  Future<void> markAllRead() async {
    await store.setJson('read', {
      for (final d in _dms)
        if (d.lastMessageId != null) d.id: d.lastMessageId!,
    });
    badge.value = 0;
  }

  Future<void> connect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Connecter ton compte Discord'),
        content: const SingleChildScrollView(
          child: Text(
            'La page de connexion officielle de Discord va s\'ouvrir dans l\'appli. '
            'Connecte-toi normalement : Mon Hub récupère ensuite ta session toute seule '
            '(elle reste chiffrée sur cet appareil).\n\n'
            '⚠️ Discord interdit officiellement l\'usage d\'un compte par une appli '
            'tierce. Mon Hub ne fait que lire tes MP toutes les quelques minutes, '
            'mais un risque de suspension existe.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continuer')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    String token;
    if (webLoginSupported) {
      token = await WebLoginPage.open(
            context,
            WebLoginPage(
              title: 'Connexion à Discord',
              url: 'https://discord.com/login',
              captureAuthorizationHeader: true,
              // On ne garde que le vrai jeton du compte (pas une requête
              // anonyme faite avant la connexion).
              validate: (t) async {
                try {
                  await DiscordApi(t).me();
                  return true;
                } catch (_) {
                  return false;
                }
              },
            ),
          ) ??
          '';
    } else {
      final r = await askFields(context,
          title: 'Jeton Discord',
          message: 'Sur discord.com/app : F12 > Réseau > une requête « messages » > '
              'copie l\'en-tête « authorization ».',
          labels: ['authorization'],
          obscure: {0});
      token = r?.first.trim().replaceAll('"', '') ?? '';
    }
    if (token.isEmpty || !context.mounted) return;
    try {
      final u = await DiscordApi(token).me();
      await store.writeSecret('token', token);
      _api = null;
      me = u;
      _lastMsg.clear();
      _lastSeenId.clear();
      await store.setJson('connected', true);
      await load(force: true);
      store.changed();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Connecté en tant que ${u.name}')));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> disconnect() async {
    await store.writeSecret('token', null);
    await store.setJson('connected', null);
    _api = null;
    me = null;
    _dms = [];
    badge.value = 0;
    _loading = null;
    store.changed();
  }

  // ---------- Serveurs (widget public officiel) ----------

  List<String> get guildIds =>
      (store.getJson<List<dynamic>>('guilds') ?? const []).cast<String>();

  Future<List<Map<String, dynamic>>> fetchGuilds() => Future.wait(guildIds.map((id) async {
        try {
          final r = await http.get(Uri.parse('https://discord.com/api/guilds/$id/widget.json'));
          if (r.statusCode != 200) return {'id': id, 'error': 'Widget désactivé'};
          return {'id': id, ...jsonDecode(r.body) as Map<String, dynamic>};
        } catch (e) {
          return {'id': id, 'error': '$e'};
        }
      }));

  // ---------- Interface ----------

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (!connected) {
            return EmptyHint('Connecte ton compte pour voir tes MP',
                icon: Icons.link_rounded, action: ('Connecter', () => connect(context)));
          }
          return FutureBuilder(
            future: load(),
            initialData: _dms,
            builder: (context, snap) {
              final list = (snap.data ?? []).take(4).toList();
              if (list.isEmpty) {
                return snap.connectionState == ConnectionState.waiting
                    ? const LoadingHint()
                    : EmptyHint(lastError ?? 'Aucun message',
                        action: lastError == null
                            ? null
                            : ('Réessayer', () => load(force: true).then((_) => store.changed())));
              }
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                physics: const NeverScrollableScrollPhysics(),
                children: [for (final d in list) _dmTile(context, d, dense: true)],
              );
            },
          );
        },
      );

  Widget _dmTile(BuildContext context, DiscordDm d, {bool dense = false}) {
    final unread = isUnread(d);
    return ListTile(
      dense: dense,
      visualDensity: dense ? VisualDensity.compact : null,
      leading: HubAvatar(url: d.avatarUrl, label: d.name, color: color, size: dense ? 30 : 40),
      title: Text(d.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
      subtitle: d.last == null
          ? null
          : Text(
              '${d.last!.author.id == me?.id ? 'Toi : ' : ''}${d.last!.content}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      trailing: d.last == null
          ? null
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(timeAgo(d.last!.at), style: Theme.of(context).textTheme.labelSmall),
                if (unread) ...[
                  const SizedBox(height: 4),
                  Dot(color: color),
                ],
              ],
            ),
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => _ConversationPage(module: this, channelId: d.id, title: d.name))),
    );
  }

  @override
  Widget buildPage(BuildContext context) {
    markAllRead();
    return DefaultTabController(
      length: webLoginSupported ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => load(force: true).then((_) => store.changed()),
            ),
            IconButton(
              tooltip: 'Ouvrir Discord',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => openLink(context, 'https://discord.com/channels/@me'),
            ),
          ],
          bottom: TabBar(tabs: [
            const Tab(text: 'Messages privés'),
            const Tab(text: 'Serveurs'),
            if (webLoginSupported) const Tab(text: 'Discord complet'),
          ]),
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _dmsTab(context),
              _guildsTab(context),
              // Le vrai Discord (serveurs, salons, appels…) dans l'appli, avec
              // la session gardée d'une fois sur l'autre.
              if (webLoginSupported)
                const HubWebView(url: 'https://discord.com/channels/@me', desktopUserAgent: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dmsTab(BuildContext context) {
    if (!connected) {
      return EmptyHint('Connecte ton compte Discord pour lire tes messages privés ici '
          'et recevoir une alerte à chaque nouveau message.',
          icon: Icons.forum_rounded, action: ('Connecter mon compte', () => connect(context)));
    }
    return FutureBuilder(
      future: load(),
      initialData: _dms,
      builder: (context, snap) => ListView(
        children: [
          if (me != null)
            ListTile(
              leading: HubAvatar(url: me!.avatarUrl, label: me!.name, color: color),
              title: Text('Connecté : ${me!.name}'),
              trailing: TextButton(onPressed: disconnect, child: const Text('Déconnecter')),
            ),
          if (lastError != null) ...[
            ErrorBanner(lastError!),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, children: [
                OutlinedButton(
                  onPressed: () => load(force: true).then((_) => store.changed()),
                  child: const Text('Réessayer'),
                ),
                OutlinedButton(onPressed: () => connect(context), child: const Text('Reconnecter')),
              ]),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Nouveau message'),
              onPressed: () => _newMessage(context),
            ),
          ),
          const Divider(),
          if (snap.connectionState == ConnectionState.waiting && (snap.data ?? []).isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: LoadingHint()),
          for (final d in snap.data ?? <DiscordDm>[]) _dmTile(context, d),
        ],
      ),
    );
  }

  Future<void> _newMessage(BuildContext context) async {
    final api = await _client();
    if (api == null || !context.mounted) return;
    final friend = await showModalBottomSheet<DiscordUser>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SizedBox(
        height: MediaQuery.of(c).size.height * 0.7,
        child: FutureBuilder(
          future: api.friends(),
          builder: (c, snap) {
            if (snap.hasError) return EmptyHint('${snap.error}');
            if (!snap.hasData) return const LoadingHint();
            return ListView(children: [
              for (final f in snap.data!)
                ListTile(
                  leading: HubAvatar(url: f.avatarUrl, label: f.name, color: color),
                  title: Text(f.name),
                  onTap: () => Navigator.pop(c, f),
                ),
            ]);
          },
        ),
      ),
    );
    if (friend == null || !context.mounted) return;
    try {
      final channelId = await api.openDm(friend.id);
      if (!context.mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => _ConversationPage(module: this, channelId: channelId, title: friend.name)));
      await load(force: true);
      store.changed();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Widget _guildsTab(BuildContext context) => FutureBuilder(
        future: fetchGuilds(),
        builder: (context, snap) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            for (final g in snap.data ?? <Map<String, dynamic>>[])
              ListTile(
                leading: HubAvatar(label: g['name'] as String? ?? '#', color: color),
                title: Text(g['name'] as String? ?? g['id'] as String),
                subtitle: Text(g['error'] as String? ?? '● ${g['presence_count']} en ligne'),
                onTap: () => openLink(context, 'https://discord.com/channels/${g['id']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => store.setJson(
                      'guilds', guildIds.where((x) => x != g['id']).toList()),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter un serveur'),
                onPressed: () async {
                  final r = await askFields(context,
                      title: 'ID du serveur',
                      labels: ['Clic droit sur le serveur > Copier l\'identifiant']);
                  final v = r?.first.trim() ?? '';
                  if (v.isNotEmpty) await store.setJson('guilds', {...guildIds, v}.toList());
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Le nombre de membres en ligne s\'affiche si le widget est activé '
                '(Paramètres du serveur > Widget).',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
}

class _ConversationPage extends StatefulWidget {
  const _ConversationPage({required this.module, required this.channelId, required this.title});
  final DiscordModule module;
  final String channelId;
  final String title;

  @override
  State<_ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<_ConversationPage> {
  List<DiscordMessage>? msgs;
  String? error;
  Timer? _timer;

  DiscordModule get module => widget.module;

  Future<void> _load() async {
    try {
      final api = await module._client();
      if (api == null) throw 'Discord n\'est pas connecté';
      final m = await api.messages(widget.channelId, limit: 50);
      if (mounted) {
        setState(() {
          msgs = m;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Conversation ouverte : on rafraîchit plus souvent.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(
          tooltip: 'Appel vocal / vidéo (ouvre Discord)',
          icon: const Icon(Icons.call_rounded),
          onPressed: () => openLink(context, 'https://discord.com/channels/@me/${widget.channelId}'),
        ),
      ]),
      body: Column(
        children: [
          Expanded(
            child: error != null && msgs == null
                ? EmptyHint(error!, action: ('Réessayer', () {
                    setState(() => error = null);
                    _load();
                  }))
                : msgs == null
                    ? const LoadingHint()
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.all(12),
                        itemCount: msgs!.length,
                        itemBuilder: (context, i) {
                          final m = msgs![i];
                          final mine = m.author.id == module.me?.id;
                          return ChatBubble(
                            text: m.content,
                            images: m.images,
                            author: mine ? null : m.author.name,
                            time: '${dayLabel(m.at)} ${hhmm(m.at)}',
                            mine: mine,
                            color: module.color,
                          );
                        },
                      ),
          ),
          ChatComposer(
            color: module.color,
            hint: 'Écrire à ${widget.title}',
            onAttach: () async {
              final file = await openFile(acceptedTypeGroups: const [
                XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp']),
              ]);
              if (file == null) return;
              final api = await module._client();
              final sent = await api!.sendFile(widget.channelId, file.name, await file.readAsBytes());
              setState(() => msgs = [sent, ...?msgs]);
            },
            onSend: (text) async {
              final api = await module._client();
              final sent = await api!.send(widget.channelId, text);
              setState(() => msgs = [sent, ...?msgs]);
            },
          ),
        ],
      ),
    );
  }
}
