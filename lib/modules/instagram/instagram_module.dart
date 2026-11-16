import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

class IgUser {
  IgUser(this.id, this.username, this.fullName, this.pic);
  final String id;
  final String username;
  final String fullName;
  final String? pic;
  String get display => fullName.isNotEmpty ? fullName : username;

  factory IgUser.fromJson(Map<String, dynamic> j) => IgUser(
        '${j['pk'] ?? j['pk_id'] ?? j['id']}',
        j['username'] as String? ?? '',
        j['full_name'] as String? ?? '',
        j['profile_pic_url'] as String?,
      );
}

class IgMessage {
  IgMessage(this.id, this.userId, this.text, this.at);
  final String id;
  final String userId;
  final String text;
  final DateTime at;

  factory IgMessage.fromJson(Map<String, dynamic> j) {
    final type = j['item_type'] as String? ?? '';
    final text = switch (type) {
      'text' => j['text'] as String? ?? '',
      'like' => '❤️',
      'media_share' || 'clip' || 'xma_media_share' => '🎬 a partagé une publication',
      'media' || 'raven_media' => '📷 Photo / vidéo',
      'voice_media' => '🎤 Message vocal',
      'animated_media' => 'GIF',
      'link' => (j['link'] as Map?)?['text'] as String? ?? '🔗 Lien',
      'reel_share' || 'story_share' => '📖 a réagi à une story',
      _ => j['text'] as String? ?? 'Nouveau message',
    };
    final ts = int.tryParse('${j['timestamp']}') ?? 0;
    return IgMessage(
      '${j['item_id']}',
      '${j['user_id']}',
      text,
      DateTime.fromMicrosecondsSinceEpoch(ts),
    );
  }
}

class IgThread {
  IgThread(this.id, this.title, this.users, this.last, this.unread);
  final String id;
  final String title;
  final List<IgUser> users;
  final IgMessage? last;
  final bool unread;
}

/// Client pour l'API privée d'Instagram (celle de instagram.com), comme les
/// projets listés sur github.com/topics/instagram-api (instagrapi, etc.).
/// On s'authentifie avec le cookie de session de ton navigateur, ce qui évite
/// les vérifications de connexion d'Instagram à chaque démarrage.
class InstagramApi {
  /// [auth] : soit la valeur du cookie `sessionid`, soit l'en-tête Cookie
  /// complet récupéré par la connexion intégrée (permet d'envoyer).
  InstagramApi(String auth, [http.Client? client])
      : _http = client ?? http.Client(),
        _cookies = _parse(auth);

  final http.Client _http;
  final Map<String, String> _cookies;

  static Map<String, String> _parse(String auth) {
    if (!auth.contains('=')) return {'sessionid': auth};
    return {
      for (final part in auth.split(';'))
        if (part.contains('='))
          part.split('=').first.trim(): part.substring(part.indexOf('=') + 1).trim(),
    };
  }

  String get sessionId => _cookies['sessionid'] ?? '';
  String get _userId =>
      _cookies['ds_user_id'] ?? Uri.decodeComponent(sessionId).split(':').first;
  String? get _csrf => _cookies['csrftoken'];

  Map<String, String> get _headers => {
        'Cookie': {
          ..._cookies,
          'ds_user_id': _userId,
        }.entries.map((e) => '${e.key}=${e.value}').join('; '),
        'X-CSRFToken': ?_csrf,
        'X-IG-App-ID': '936619743392459',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': 'https://www.instagram.com/direct/inbox/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36',
      };

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _http.get(Uri.parse('https://www.instagram.com/api/v1$path'),
        headers: _headers);
    if (r.statusCode == 401 || r.statusCode == 403 || r.body.startsWith('<')) {
      throw 'Session Instagram expirée : reconnecte ton compte';
    }
    if (r.statusCode == 429) throw 'Instagram demande de ralentir';
    if (r.statusCode >= 400) throw 'Instagram : erreur ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Envoie un message texte dans une conversation.
  Future<void> send(String threadId, String text) async {
    if (_csrf == null) {
      throw 'Pour envoyer, reconnecte Instagram avec le bouton « Connecter » '
          '(connexion intégrée)';
    }
    final ctx = '${DateTime.now().microsecondsSinceEpoch}${DateTime.now().millisecond}';
    final r = await _http.post(
      Uri.parse('https://www.instagram.com/api/v1/direct_v2/threads/broadcast/text/'),
      headers: {..._headers, 'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'action': 'send_item',
        'client_context': ctx,
        'mutation_token': ctx,
        'offline_threading_id': ctx,
        'thread_ids': '[$threadId]',
        'text': text,
      },
    );
    if (r.statusCode >= 400 || r.body.startsWith('<')) {
      throw 'Instagram a refusé l\'envoi (code ${r.statusCode})';
    }
  }

  Future<(IgUser, List<IgThread>)> inbox() async {
    final j = await _get('/direct_v2/inbox/?persistentBadging=true&limit=20&thread_message_limit=1');
    final viewer = IgUser.fromJson(j['viewer'] as Map<String, dynamic>);
    final threads = <IgThread>[];
    for (final t in (j['inbox']?['threads'] as List? ?? [])) {
      final users = [
        for (final u in t['users'] as List? ?? []) IgUser.fromJson(u as Map<String, dynamic>)
      ];
      final items = t['items'] as List? ?? [];
      final last = items.isEmpty ? null : IgMessage.fromJson(items.first as Map<String, dynamic>);
      final title = (t['thread_title'] as String?)?.isNotEmpty == true
          ? t['thread_title'] as String
          : users.map((u) => u.display).join(', ');
      // read_state 1 ou « last_seen_at » antérieur = non lu.
      final unread = (t['read_state'] ?? 0) == 1;
      threads.add(IgThread('${t['thread_id']}', title, users, last, unread));
    }
    return (viewer, threads);
  }

  Future<List<IgMessage>> thread(String id) async {
    final j = await _get('/direct_v2/threads/$id/?limit=30');
    return [
      for (final m in j['thread']?['items'] as List? ?? [])
        IgMessage.fromJson(m as Map<String, dynamic>)
    ];
  }
}

class InstagramModule extends HubModule {
  @override
  String get id => 'instagram';
  @override
  String get name => 'Instagram';
  @override
  String get description => 'Tes messages Instagram';
  @override
  IconData get icon => Icons.camera_alt_rounded;
  @override
  Color get color => const Color(0xFFE1306C);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  InstagramApi? _api;
  IgUser? me;
  List<IgThread> _threads = [];
  Future<List<IgThread>>? _loading;
  String? lastError;

  bool get connected => store.getJson<bool>('connected') == true;

  Future<InstagramApi?> _client() async {
    if (_api != null) return _api;
    final s = await store.readSecret('sessionid');
    if (s == null || s.isEmpty) return null;
    return _api = InstagramApi(s);
  }

  Future<List<IgThread>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      final api = await _client();
      if (api == null) return _threads = [];
      try {
        lastError = null;
        final (viewer, threads) = await api.inbox();
        me = viewer;
        _threads = threads;
        badge.value = threads.where((t) => t.unread).length;
      } catch (e) {
        lastError = '$e';
      }
      return _threads;
    }();
  }

  @override
  Future<List<HubNotification>> poll() async {
    if (!connected) return const [];
    final threads = await load(force: true);
    store.changed();
    return [
      for (final t in threads)
        if (t.last != null && t.last!.userId != me?.id)
          HubNotification(
            id: t.last!.id,
            title: 'Instagram · ${t.title}',
            body: t.last!.text,
          ),
    ];
  }

  Future<void> connect(BuildContext context) async {
    String s;
    if (webLoginSupported) {
      s = await WebLoginPage.open(
            context,
            const WebLoginPage(
              title: 'Connexion à Instagram',
              url: 'https://www.instagram.com/accounts/login/',
              cookieName: 'sessionid',
              cookieUrl: 'https://www.instagram.com',
              returnAllCookies: true,
            ),
          ) ??
          '';
    } else {
      final r = await askFields(
        context,
        title: 'Connecter Instagram',
        message: '1. Ouvre instagram.com dans ton navigateur et connecte-toi.\n'
            '2. F12 > onglet « Application » > Cookies > instagram.com.\n'
            '3. Copie la valeur du cookie « sessionid ».',
        labels: ['sessionid'],
        obscure: {0},
      );
      s = r?.first.trim() ?? '';
    }
    if (s.isEmpty || !context.mounted) return;
    try {
      final (viewer, _) = await InstagramApi(s).inbox();
      await store.writeSecret('sessionid', s);
      _api = null;
      await store.setJson('connected', true);
      await load(force: true);
      store.changed();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connecté en tant que @${viewer.username}')));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> disconnect() async {
    await store.writeSecret('sessionid', null);
    await store.setJson('connected', null);
    _api = null;
    me = null;
    _threads = [];
    _loading = null;
    badge.value = 0;
    store.changed();
  }

  Widget _threadTile(BuildContext context, IgThread t, {bool dense = false}) => ListTile(
        dense: dense,
        visualDensity: dense ? VisualDensity.compact : null,
        leading: HubAvatar(
            url: t.users.length == 1 ? t.users.first.pic : null,
            label: t.title,
            color: color,
            size: dense ? 30 : 40),
        title: Text(t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: t.unread ? FontWeight.w700 : FontWeight.w500)),
        subtitle: t.last == null
            ? null
            : Text('${t.last!.userId == me?.id ? 'Toi : ' : ''}${t.last!.text}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: t.last == null
            ? null
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(timeAgo(t.last!.at), style: Theme.of(context).textTheme.labelSmall),
                  if (t.unread) ...[const SizedBox(height: 4), Dot(color: color)],
                ],
              ),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => _ThreadPage(module: this, thread: t))),
      );

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (!connected) {
            return EmptyHint('Connecte ton compte pour voir tes messages',
                icon: Icons.link_rounded, action: ('Connecter', () => connect(context)));
          }
          return FutureBuilder(
            future: load(),
            initialData: _threads,
            builder: (context, snap) {
              final list = (snap.data ?? []).take(4).toList();
              if (list.isEmpty) {
                return snap.connectionState == ConnectionState.waiting
                    ? const LoadingHint()
                    : EmptyHint(lastError ?? 'Aucun message');
              }
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                physics: const NeverScrollableScrollPhysics(),
                children: [for (final t in list) _threadTile(context, t, dense: true)],
              );
            },
          );
        },
      );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name), actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => load(force: true).then((_) => store.changed()),
          ),
          IconButton(
            tooltip: 'Ouvrir Instagram',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => openLink(context, 'https://www.instagram.com/direct/inbox/'),
          ),
        ]),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            if (!connected) {
              return EmptyHint(
                  'Connecte ton compte Instagram pour lire tes messages ici '
                  'et recevoir une alerte à chaque nouveau message.',
                  icon: icon,
                  action: ('Connecter mon compte', () => connect(context)));
            }
            return FutureBuilder(
              future: load(),
              initialData: _threads,
              builder: (context, snap) => ListView(
                children: [
                  if (me != null)
                    ListTile(
                      leading: HubAvatar(url: me!.pic, label: me!.username, color: color),
                      title: Text('@${me!.username}'),
                      subtitle: const Text('Connecté'),
                      trailing: TextButton(onPressed: disconnect, child: const Text('Déconnecter')),
                    ),
                  if (lastError != null) ErrorBanner(lastError!),
                  const Divider(),
                  for (final t in snap.data ?? <IgThread>[]) _threadTile(context, t),
                ],
              ),
            );
          },
        ),
      );
}

class _ThreadPage extends StatefulWidget {
  const _ThreadPage({required this.module, required this.thread});
  final InstagramModule module;
  final IgThread thread;

  @override
  State<_ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<_ThreadPage> {
  List<IgMessage>? msgs;
  String? error;
  Timer? _timer;

  InstagramModule get module => widget.module;
  IgThread get thread => widget.thread;

  Future<void> _load() async {
    try {
      final api = await module._client();
      final m = await api!.thread(thread.id);
      if (mounted) setState(() => msgs = m);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final u in thread.users) u.id: u.display};
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          HubAvatar(
              url: thread.users.length == 1 ? thread.users.first.pic : null,
              label: thread.title,
              color: module.color,
              size: 32),
          const SizedBox(width: 10),
          Expanded(child: Text(thread.title, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      body: Column(
        children: [
          Expanded(
            child: error != null && msgs == null
                ? EmptyHint(error!)
                : msgs == null
                    ? const LoadingHint()
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.all(12),
                        itemCount: msgs!.length,
                        itemBuilder: (context, i) {
                          final m = msgs![i];
                          final mine = m.userId == module.me?.id;
                          return ChatBubble(
                            text: m.text,
                            author: mine || thread.users.length < 2 ? null : names[m.userId],
                            time: '${dayLabel(m.at)} ${hhmm(m.at)}',
                            mine: mine,
                            color: module.color,
                          );
                        },
                      ),
          ),
          ChatComposer(
            color: module.color,
            hint: 'Écrire à ${thread.title}',
            onSend: (text) async {
              final api = await module._client();
              await api!.send(thread.id, text);
              await _load();
            },
          ),
        ],
      ),
    );
  }
}
