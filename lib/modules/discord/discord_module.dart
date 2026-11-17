import 'dart:io' show File;
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/web_login.dart';
import '../../ui/call_page.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import 'discord_api.dart';
import 'discord_phone.dart';

/// Discord : tes messages privés, tous tes serveurs et leurs salons, et les
/// appels reçus et passés dans Mon Hub (le Discord officiel gardé ouvert en
/// fond, voir discord_phone.dart).
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

  /// Recevoir et passer les appels dans Mon Hub (activé par défaut).
  bool get phoneEnabled => store.getJson<bool>('phone') ?? true;

  Future<void> setPhone(bool v) async {
    await store.setJson('phone', v);
    syncPhone();
  }

  /// Ouvre ou ferme le Discord caché qui reçoit les appels.
  void syncPhone() {
    final phone = DiscordPhone.instance;
    if (connected && phoneEnabled) {
      phone.start();
    } else {
      phone.stop();
    }
  }

  /// Le téléphone Discord de Mon Hub est prêt à appeler.
  bool get phoneReady => DiscordPhone.supported && DiscordPhone.allowed && connected && phoneEnabled;

  /// Appelle une conversation privée : dans Mon Hub (Discord caché), sinon
  /// dans une page d'appel.
  Future<void> callDm(BuildContext? context, String channelId, {required String title, bool video = false}) async {
    if (phoneReady) {
      unawaited(DiscordPhone.instance.call(channelId, video: video, title: title));
      return;
    }
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    unawaited(CallPage.open(
      ctx,
      url: 'https://discord.com/channels/@me/$channelId',
      title: title,
      video: video,
      color: color,
    ));
  }

  /// Rejoint un salon vocal d'un serveur.
  Future<void> joinVoice(BuildContext? context, String guildId, DiscordChannel ch) async {
    if (phoneReady) {
      unawaited(DiscordPhone.instance.joinVoice(guildId, ch.id, title: '🔊 ${ch.name}'));
      return;
    }
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    unawaited(Navigator.push(
      ctx,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('🔊 ${ch.name}')),
          body: HubWebView(url: 'https://discord.com/channels/$guildId/${ch.id}', desktopUserAgent: true),
        ),
      ),
    ));
  }

  List<DiscordGuild>? _guilds;
  final _channels = <String, List<DiscordChannel>>{};

  /// Tes serveurs (gardés en mémoire pendant que Mon Hub est ouvert).
  Future<List<DiscordGuild>> guilds({bool force = false}) async {
    if (_guilds != null && !force) return _guilds!;
    final api = await _client();
    if (api == null) throw 'Discord n\'est pas connecté';
    return _guilds = await api.guilds();
  }

  Future<List<DiscordChannel>> channels(String guildId, {bool force = false}) async {
    final known = _channels[guildId];
    if (known != null && !force) return known;
    final api = await _client();
    if (api == null) throw 'Discord n\'est pas connecté';
    return _channels[guildId] = await api.channels(guildId);
  }

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
                  if (d.last != null) 'dernier': '${d.last!.author.name} : ${d.last!.preview}',
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
                {'de': m.author.name, 'texte': m.preview, 'date': m.at},
            ];
          },
        ),
        HubTool(
          name: 'discord_envoyer_fichier',
          description: 'Envoie une photo ou un fichier (sur le PC) dans une conversation Discord.',
          params: {
            'id': ('string', 'id de la conversation (discord_conversations)'),
            'chemin': ('string', 'Chemin du fichier sur le PC'),
            'texte': ('string', 'Message avec le fichier (facultatif)'),
          },
          required: ['id', 'chemin'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Discord n\'est pas connecté';
            final f = File('${a['chemin']}');
            await api.sendFile(
              a['id'] as String,
              f.uri.pathSegments.last,
              await f.readAsBytes(),
              content: '${a['texte'] ?? ''}',
            );
            return {'ok': true};
          },
        ),
        HubTool(
          name: 'discord_appeler',
          description: 'Lance un appel vocal ou vidéo Discord dans Mon Hub.',
          params: {
            'id': ('string', 'id de la conversation (discord_conversations)'),
            'video': ('boolean', 'true : appel vidéo'),
          },
          required: ['id'],
          run: (a) async {
            final id = a['id'] as String;
            final dm = _dms.where((d) => d.id == id).firstOrNull;
            await callDm(null, id, title: dm?.name ?? 'Discord', video: a['video'] == true);
            return {'ok': true, 'appel': a['video'] == true ? 'vidéo' : 'vocal', 'dans_mon_hub': phoneReady};
          },
        ),
        HubTool(
          name: 'discord_appel',
          description: 'Gère l\'appel Discord en cours : répondre (vocal ou vidéo), refuser, raccrocher, '
              'ou voir l\'état (qui appelle).',
          params: {'action': ('string', 'repondre, repondre_video, refuser, raccrocher ou etat')},
          required: ['action'],
          run: (a) async {
            final p = DiscordPhone.instance;
            if (!p.active) throw 'Les appels Discord dans Mon Hub sont désactivés';
            final ok = switch ('${a['action']}') {
              'repondre' => await p.answer(),
              'repondre_video' => await p.answer(video: true),
              'refuser' => await p.decline(),
              'raccrocher' => await p.hangUp(),
              _ => true,
            };
            return {'ok': ok, 'etat': p.state.name, if (p.who.isNotEmpty) 'qui': p.who};
          },
        ),
        HubTool(
          name: 'discord_serveurs',
          description: 'Liste tes serveurs Discord.',
          run: (_) async => [
            for (final g in await guilds())
              {'id': g.id, 'nom': g.name, if (g.online != null) 'en_ligne': g.online},
          ],
        ),
        HubTool(
          name: 'discord_salons',
          description: 'Salons d\'un serveur Discord (textuels et vocaux). Les messages d\'un salon textuel se '
              'lisent avec discord_messages et s\'envoient avec discord_envoyer (id du salon).',
          params: {'serveur': ('string', 'id du serveur (discord_serveurs)')},
          required: ['serveur'],
          run: (a) async => [
            for (final (cat, list) in DiscordChannel.grouped(await channels(a['serveur'] as String)))
              for (final c in list)
                {
                  'id': c.id,
                  'nom': c.name,
                  'type': c.isVoice ? 'vocal' : 'texte',
                  if (cat != null) 'categorie': cat.name,
                },
          ],
        ),
        HubTool(
          name: 'discord_rejoindre_vocal',
          description: 'Rejoint un salon vocal d\'un serveur Discord, dans Mon Hub.',
          params: {
            'serveur': ('string', 'id du serveur'),
            'salon': ('string', 'id du salon vocal (discord_salons)'),
          },
          required: ['serveur', 'salon'],
          run: (a) async {
            final list = await channels(a['serveur'] as String);
            final ch = list.where((c) => c.id == a['salon']).firstOrNull;
            if (ch == null || !ch.isVoice) throw 'Ce salon vocal n\'existe pas';
            await joinVoice(null, a['serveur'] as String, ch);
            return {'ok': true};
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
            body: d.last!.preview,
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
      syncPhone();
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
    DiscordPhone.instance.stop();
    _guilds = null;
    _channels.clear();
    _api = null;
    me = null;
    _dms = [];
    badge.value = 0;
    _loading = null;
    store.changed();
  }

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
              final list = (snap.data ?? []).take(10).toList();
              if (list.isEmpty) {
                return snap.connectionState == ConnectionState.waiting
                    ? const LoadingHint()
                    : EmptyHint(lastError ?? 'Aucun message',
                        action: lastError == null
                            ? null
                            : ('Réessayer', () => load(force: true).then((_) => store.changed())));
              }
              return ChatsSummary(
                color: color,
                items: [
                  for (final d in list)
                    ChatItem(
                      name: d.name,
                      preview: d.last?.preview ?? '',
                      avatarUrl: d.avatarUrl,
                      unread: isUnread(d),
                      at: d.last?.at,
                      mine: d.last != null && d.last!.author.id == me?.id,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => _ConversationPage(module: this, channelId: d.id, title: d.name)),
                      ),
                    ),
                ],
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
              '${d.last!.author.id == me?.id ? 'Toi : ' : ''}${d.last!.preview}',
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
              // la session gardée d'une fois sur l'autre. Si le Discord caché
              // tourne déjà (appels), on l'affiche lui plutôt qu'un deuxième.
              if (webLoginSupported)
                phoneReady
                    ? EmptyHint(
                        'Le vrai Discord, en grand dans Mon Hub (serveurs, salons, appels, '
                        'paramètres…). Reviens ici avec « Réduire ».',
                        icon: Icons.open_in_full_rounded,
                        action: ('Ouvrir Discord', DiscordPhone.instance.show),
                      )
                    : const HubWebView(url: 'https://discord.com/channels/@me', desktopUserAgent: true),
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
          if (DiscordPhone.supported)
            SwitchListTile(
              secondary: const Icon(Icons.ring_volume_rounded),
              title: const Text('Recevoir et passer les appels dans Mon Hub'),
              subtitle: const Text('Discord reste ouvert en fond, sans navigateur : Mon Hub sonne quand on '
                  't\'appelle.'),
              value: phoneEnabled,
              onChanged: (v) async {
                await setPhone(v);
                store.changed();
              },
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

  Widget _guildsTab(BuildContext context) {
    if (!connected) {
      return EmptyHint('Connecte ton compte Discord pour voir tous tes serveurs',
          icon: Icons.dns_rounded, action: ('Connecter mon compte', () => connect(context)));
    }
    return _GuildsGrid(module: this);
  }
}

/// Tous tes serveurs, en grandes icônes.
class _GuildsGrid extends StatefulWidget {
  const _GuildsGrid({required this.module});
  final DiscordModule module;

  @override
  State<_GuildsGrid> createState() => _GuildsGridState();
}

class _GuildsGridState extends State<_GuildsGrid> {
  late Future<List<DiscordGuild>> future = widget.module.guilds();
  String query = '';

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final theme = Theme.of(context);
    return FutureBuilder(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return EmptyHint('${snap.error}', action: ('Réessayer', () {
            setState(() => future = m.guilds(force: true));
          }));
        }
        if (!snap.hasData) return const LoadingHint();
        final all = snap.data!;
        final q = query.toLowerCase();
        final list = q.isEmpty ? all : all.where((g) => g.name.toLowerCase().contains(q)).toList();
        return RefreshIndicator(
          onRefresh: () async {
            final f = m.guilds(force: true);
            setState(() => future = f);
            await f;
          },
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Chercher parmi tes ${all.length} serveurs',
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisExtent: 150,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final g = list[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => _GuildPage(module: m, guild: g)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            _GuildIcon(guild: g, size: 64, color: m.color),
                            const SizedBox(height: 8),
                            Text(
                              g.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (g.online != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Dot(color: Color(0xFF23A55A), size: 7),
                                  const SizedBox(width: 4),
                                  Text('${g.online} en ligne', style: theme.textTheme.labelSmall),
                                ],
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// L'icône d'un serveur (ou ses initiales).
class _GuildIcon extends StatelessWidget {
  const _GuildIcon({required this.guild, required this.size, required this.color});
  final DiscordGuild guild;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final initials = guild.name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(3)
        .map((w) => w.characters.first)
        .join();
    final fallback = Container(
      color: color,
      alignment: Alignment.center,
      child: Text(
        initials.isEmpty ? '#' : initials,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.3),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.3),
      child: SizedBox(
        width: size,
        height: size,
        child: guild.iconUrl == null
            ? fallback
            : Image.network(guild.iconUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

/// Les salons d'un serveur, rangés par catégorie comme dans Discord.
class _GuildPage extends StatefulWidget {
  const _GuildPage({required this.module, required this.guild});
  final DiscordModule module;
  final DiscordGuild guild;

  @override
  State<_GuildPage> createState() => _GuildPageState();
}

class _GuildPageState extends State<_GuildPage> {
  late Future<List<DiscordChannel>> future = widget.module.channels(widget.guild.id);

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final g = widget.guild;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _GuildIcon(guild: g, size: 32, color: m.color),
            const SizedBox(width: 12),
            Expanded(child: Text(g.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() => future = m.channels(g.id, force: true)),
          ),
        ],
      ),
      body: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return EmptyHint('${snap.error}');
          if (!snap.hasData) return const LoadingHint();
          final groups = DiscordChannel.grouped(snap.data!);
          if (groups.isEmpty) return const EmptyHint('Aucun salon visible');
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            children: [
              for (final (cat, list) in groups) ...[
                if (cat != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
                    child: Text(
                      cat.name.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final c in list)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                    child: ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      leading: Icon(
                        c.isVoice
                            ? Icons.volume_up_rounded
                            : c.type == 5
                                ? Icons.campaign_rounded
                                : Icons.tag_rounded,
                        color: c.isVoice ? const Color(0xFF23A55A) : m.color,
                      ),
                      title: Text(c.name, overflow: TextOverflow.ellipsis),
                      subtitle: c.topic.isEmpty
                          ? null
                          : Text(c.topic, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: c.isVoice
                          ? FilledButton.tonalIcon(
                              icon: const Icon(Icons.headset_mic_rounded, size: 18),
                              label: const Text('Rejoindre'),
                              onPressed: () => m.joinVoice(context, g.id, c),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: () => c.isVoice
                          ? m.joinVoice(context, g.id, c)
                          : Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _ConversationPage(
                                  module: m,
                                  channelId: c.id,
                                  title: '#${c.name}',
                                  canCall: false,
                                ),
                              ),
                            ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ConversationPage extends StatefulWidget {
  const _ConversationPage({required this.module, required this.channelId, required this.title, this.canCall = true});
  final DiscordModule module;
  final String channelId;
  final String title;

  /// Conversation privée (on peut appeler) ; non pour un salon de serveur.
  final bool canCall;

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
        if (widget.canCall) ...[
          IconButton(
            tooltip: 'Appel vocal',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => module.callDm(context, widget.channelId, title: widget.title),
          ),
          IconButton(
            tooltip: 'Appel vidéo',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => module.callDm(context, widget.channelId, title: widget.title, video: true),
          ),
        ],
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
                            extra: m.isVoice
                                ? VoiceNotePlayer(
                                    url: m.audioUrl!,
                                    duration: m.audioLength,
                                    waveform: m.waveform,
                                    color: module.color,
                                    onColor: mine
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.onSurface,
                                  )
                                : null,
                            reactions: [
                              for (final r in m.reactions)
                                Reaction(r.label, const [], count: r.count, mine: r.me),
                            ],
                            onWho: (r) async {
                              final dr = m.reactions.firstWhere((x) => x.label == r.emoji);
                              final api = await module._client();
                              final users = await api!.reactors(widget.channelId, m.id, dr);
                              return [for (final u in users) u.name];
                            },
                            onDoubleTap: m.reactions.any((r) => r.me && r.name == '❤️')
                                ? null
                                : () async {
                                    try {
                                      final api = await module._client();
                                      await api!.react(widget.channelId, m.id);
                                      await _load();
                                    } catch (e) {
                                      if (context.mounted) showError(context, e);
                                    }
                                  },
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
              // Une ou plusieurs photos (ou n'importe quel fichier).
              final files = await openFiles(acceptedTypeGroups: const [
                XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']),
                XTypeGroup(label: 'Tous les fichiers'),
              ]);
              if (files.isEmpty) return;
              final api = await module._client();
              for (final file in files) {
                final sent = await api!.sendFile(widget.channelId, file.name, await file.readAsBytes());
                setState(() => msgs = [sent, ...?msgs]);
              }
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
