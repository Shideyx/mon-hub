import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;


import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/web_login.dart';
import '../../core/photo.dart';
import '../../ui/call_page.dart';
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

/// Cherche la première image (la plus grande) n'importe où dans un objet
/// renvoyé par Instagram.
String? findIgImage(Object? node, [int depth = 0]) {
  if (depth > 8 || node == null) return null;
  if (node is Map) {
    final iv = node['image_versions2'];
    if (iv is Map && iv['candidates'] is List && (iv['candidates'] as List).isNotEmpty) {
      return (iv['candidates'] as List).first['url'] as String?;
    }
    for (final v in node.values) {
      final r = findIgImage(v, depth + 1);
      if (r != null) return r;
    }
  } else if (node is List) {
    for (final v in node) {
      final r = findIgImage(v, depth + 1);
      if (r != null) return r;
    }
  }
  return null;
}

class IgMessage {
  IgMessage(
    this.id,
    this.userId,
    this.text,
    this.at, [
    this.image,
    this.audioUrl,
    this.audioLength,
    this.waveform = const [],
    this.reactions = const [],
    this.isLike = false,
  ]);
  final String id;
  final String userId;
  final String text;
  final DateTime at;
  final String? image;

  /// Message vocal : adresse du son, durée et onde.
  final String? audioUrl;
  final Duration? audioLength;
  final List<double> waveform;

  /// Réactions : (emoji, id de la personne).
  final List<(String, String)> reactions;

  /// Le message est un simple ❤️ (bouton « J'aime » d'Instagram).
  final bool isLike;

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
    final image = type == 'text' || type == 'like' || type == 'voice_media' ? null : findIgImage(j);
    final audio = ((j['voice_media'] as Map?)?['media'] as Map?)?['audio'] as Map?;
    final ms = (audio?['duration'] as num?)?.toInt();
    final r = j['reactions'] as Map?;
    return IgMessage(
      '${j['item_id']}',
      '${j['user_id']}',
      image != null && (type == 'media' || type == 'raven_media') ? '' : text,
      DateTime.fromMicrosecondsSinceEpoch(ts),
      image,
      audio?['audio_src'] as String?,
      ms == null ? null : Duration(milliseconds: ms),
      [
        for (final v in (audio?['waveform_data'] as List?) ?? const [])
          if (v is num) v.toDouble(),
      ],
      [
        for (final l in (r?['likes'] as List?) ?? const [])
          if (l is Map) ('❤️', '${l['sender_id']}'),
        for (final e in (r?['emojis'] as List?) ?? const [])
          if (e is Map) ('${e['emoji'] ?? '❤️'}', '${e['sender_id']}'),
      ],
      type == 'like',
    );
  }

  /// Le message est un vocal qu'on peut écouter.
  bool get isVoice => audioUrl != null && audioUrl!.isNotEmpty;
}

/// Une ligne de l'activité Instagram (« X a aimé ta publication »…).
class IgActivity {
  IgActivity(this.text, this.at, this.pic, this.thumb, this.isLike);
  final String text;
  final DateTime at;
  final String? pic;
  final String? thumb;
  final bool isLike;

  factory IgActivity.fromJson(Map<String, dynamic> j) {
    final a = (j['args'] as Map?) ?? const {};
    final text = '${a['rich_text'] ?? a['text'] ?? ''}'
        // Texte enrichi : {nom|couleur|gras|lien} → nom.
        .replaceAllMapped(RegExp(r'\{([^|{}]*)\|[^{}]*\}'), (m) => m[1] ?? '');
    final ts = (a['timestamp'] as num?)?.toDouble() ?? 0;
    final media = a['media'];
    final thumb = media is List && media.isNotEmpty && media.first is Map
        ? (media.first as Map)['image'] as String?
        : null;
    final low = text.toLowerCase();
    return IgActivity(
      text,
      DateTime.fromMillisecondsSinceEpoch((ts * 1000).round()),
      a['profile_image'] as String?,
      thumb,
      low.contains('aim') || low.contains('like') || j['story_type'] == 60,
    );
  }
}

class IgPost {
  IgPost(
    this.id,
    this.code,
    this.user,
    this.images,
    this.caption,
    this.likes,
    this.comments,
    this.liked,
    this.isVideo,
    this.at,
  );
  final String id;
  final String code;
  final IgUser user;
  final List<String> images;
  final String caption;
  int likes;
  final int comments;
  bool liked;
  final bool isVideo;
  final DateTime at;

  factory IgPost.fromJson(Map<String, dynamic> m) {
    final carousel = m['carousel_media'] as List?;
    final images = carousel != null
        ? [for (final c in carousel) findIgImage(c)].whereType<String>().toList()
        : [
            findIgImage({
              'x': m['image_versions2'] == null ? null : {'image_versions2': m['image_versions2']},
            }),
          ].whereType<String>().toList();
    return IgPost(
      '${m['id'] ?? m['pk']}',
      '${m['code'] ?? ''}',
      IgUser.fromJson(m['user'] as Map<String, dynamic>),
      images,
      (m['caption'] as Map?)?['text'] as String? ?? '',
      m['like_count'] as int? ?? 0,
      m['comment_count'] as int? ?? 0,
      m['has_liked'] == true,
      m['media_type'] == 2,
      DateTime.fromMillisecondsSinceEpoch(((m['taken_at'] ?? 0) as int) * 1000),
    );
  }
}

class IgStoryUser {
  IgStoryUser(this.reelId, this.user, this.seen);
  final String reelId;
  final IgUser user;
  final bool seen;
}

class IgStoryItem {
  IgStoryItem(this.image, this.isVideo, this.at);
  final String image;
  final bool isVideo;
  final DateTime at;
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
  String get _userId => _cookies['ds_user_id'] ?? Uri.decodeComponent(sessionId).split(':').first;
  String? get _csrf => _cookies['csrftoken'];

  /// Après un échec sur instagram.com, on bascule sur l'API mobile
  /// (i.instagram.com, celle de l'appli Android) avec la même session.
  bool _mobile = false;

  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';
  static const _mobileUa =
      'Instagram 361.0.0.35.82 Android (34/14; 480dpi; 1080x2400; '
      'samsung; SM-S918B; dm3q; qcom; fr_FR; 674675155)';

  String get _host => _mobile ? 'https://i.instagram.com' : 'https://www.instagram.com';

  Map<String, String> get _headers => _mobile
      ? {
          'User-Agent': _mobileUa,
          'X-IG-App-ID': '567067343352427',
          'X-IG-Capabilities': '3brTv10=',
          'X-IG-Connection-Type': 'WIFI',
          'Accept-Language': 'fr-FR, en-US',
          'IG-U-DS-USER-ID': _userId,
          'Authorization':
              'Bearer IGT:2:${base64.encode(utf8.encode(jsonEncode({'ds_user_id': _userId, 'sessionid': Uri.decodeComponent(sessionId)})))}',
        }
      : {
          'Cookie': {
            ..._cookies,
            'ds_user_id': _userId,
          }.entries.map((e) => '${e.key}=${e.value}').join('; '),
          'X-CSRFToken': ?_csrf,
          'X-IG-App-ID': '936619743392459',
          'X-ASBD-ID': '129477',
          'X-IG-WWW-Claim': '0',
          'X-Requested-With': 'XMLHttpRequest',
          'Origin': 'https://www.instagram.com',
          'Referer': 'https://www.instagram.com/direct/inbox/',
          'User-Agent': _webUa,
        };

  /// Transforme une réponse d'Instagram en message clair.
  static String _explain(http.Response r) {
    String msg = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) msg = '${j['message'] ?? j['error_type'] ?? ''}';
    } catch (_) {}
    final m = msg.toLowerCase();
    if (m.contains('checkpoint') || m.contains('challenge')) {
      return 'Instagram demande une vérification : ouvre l\'appli Instagram ou instagram.com, '
          'valide « C\'était moi », puis reconnecte-toi dans Mon Hub';
    }
    if (m.contains('login_required') || r.statusCode == 401) {
      return 'Session Instagram expirée : appuie sur Déconnecter puis Connecter';
    }
    if (r.statusCode == 429 || m.contains('wait')) {
      return 'Instagram demande de patienter quelques minutes';
    }
    if (r.body.trimLeft().startsWith('<')) {
      return 'Instagram a renvoyé une page web au lieu des données (code ${r.statusCode})';
    }
    return 'Instagram : erreur ${r.statusCode}${msg.isEmpty ? '' : ' ($msg)'}';
  }

  static bool _ok(http.Response r) => r.statusCode < 400 && !r.body.trimLeft().startsWith('<');

  /// Envoie une requête, en essayant l'API web puis l'API mobile.
  Future<http.Response> _send(
    String path, {
    Map<String, String>? form,
    List<int>? bytes,
    Map<String, String> extra = const {},
    bool api = true,
  }) async {
    Future<http.Response> go() {
      final uri = Uri.parse('$_host${api ? '/api/v1' : ''}$path');
      final h = {..._headers, ...extra};
      if (form == null && bytes == null) return _http.get(uri, headers: h);
      if (form != null) h['Content-Type'] = 'application/x-www-form-urlencoded';
      return _http.post(uri, headers: h, body: form ?? bytes);
    }

    http.Response r;
    try {
      r = await go().timeout(const Duration(seconds: 25));
    } catch (e) {
      throw 'Instagram injoignable (vérifie ta connexion internet) : $e';
    }
    if (!_ok(r) && !_mobile && r.statusCode != 429) {
      final first = r;
      _mobile = true;
      try {
        r = await go().timeout(const Duration(seconds: 25));
      } catch (_) {
        r = first;
      }
      if (!_ok(r)) {
        _mobile = false;
        // Le message le plus parlant des deux.
        final m = _explain(r);
        throw m.startsWith('Instagram : erreur') ? _explain(first) : m;
      }
    }
    if (!_ok(r)) throw _explain(r);
    return r;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _send(path);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Vérifie la session et renvoie le compte connecté.
  Future<IgUser> me() async {
    try {
      final j = await _get('/accounts/current_user/?edit=true');
      return IgUser.fromJson(j['user'] as Map<String, dynamic>);
    } catch (_) {
      final (viewer, _) = await inbox();
      return viewer;
    }
  }

  void _needCsrf() {
    if (_csrf == null && !_cookies.containsKey('ds_user_id')) {
      throw 'Pour envoyer, reconnecte Instagram avec le bouton « Connecter » '
          '(connexion intégrée)';
    }
  }

  /// Envoie un message texte dans une conversation.
  Future<void> send(String threadId, String text) async {
    _needCsrf();
    final ctx = '${DateTime.now().microsecondsSinceEpoch}${DateTime.now().millisecond}';
    await _send(
      '/direct_v2/threads/broadcast/text/',
      form: {
        'action': 'send_item',
        'client_context': ctx,
        'mutation_token': ctx,
        'offline_threading_id': ctx,
        'thread_ids': '[$threadId]',
        'text': text,
      },
    );
  }

  /// Envoie une photo (JPEG/PNG) dans une conversation.
  Future<void> sendPhoto(String threadId, List<int> bytes, int width, int height) async {
    _needCsrf();
    final uploadId = '${DateTime.now().millisecondsSinceEpoch}';
    final name = 'fb_uploader_$uploadId';
    await _send(
      '/rupload_igphoto/$name',
      api: false,
      bytes: bytes,
      extra: {
        'Content-Type': 'image/jpeg',
        'Offset': '0',
        'X-Entity-Name': name,
        'X-Entity-Length': '${bytes.length}',
        'X-Entity-Type': 'image/jpeg',
        'X-Instagram-Rupload-Params': jsonEncode({
          'media_type': 1,
          'upload_id': uploadId,
          'upload_media_height': height,
          'upload_media_width': width,
        }),
      },
    );
    final ctx = '${DateTime.now().microsecondsSinceEpoch}';
    await _send(
      '/direct_v2/threads/broadcast/configure_photo/',
      form: {
        'action': 'send_item',
        'thread_ids': '[$threadId]',
        'upload_id': uploadId,
        'allow_full_aspect_ratio': 'true',
        'client_context': ctx,
        'mutation_token': ctx,
        'offline_threading_id': ctx,
      },
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, String> body) async {
    final r = await _send(path, form: body);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Fil d'actualité (publications des comptes que tu suis).
  Future<List<IgPost>> timeline() async {
    Map<String, dynamic> j;
    try {
      j = await _post('/feed/timeline/', {
        'is_async_ads_rti': '0',
        'is_async_ads_double_request': '0',
      });
    } catch (_) {
      j = await _get('/feed/timeline/');
    }
    final items = (j['feed_items'] as List?) ?? (j['items'] as List?) ?? const [];
    final out = <IgPost>[];
    for (final it in items) {
      final m = (it is Map && it['media_or_ad'] != null) ? it['media_or_ad'] : it;
      if (m is! Map<String, dynamic> || m['user'] == null) continue;
      if (m['injected'] != null || m['ad_id'] != null) continue; // pas de pubs
      out.add(IgPost.fromJson(m));
    }
    return out;
  }

  /// Personnes qui ont aimé une publication.
  Future<List<IgUser>> likers(String mediaId) async {
    final j = await _get('/media/$mediaId/likers/');
    return [
      for (final u in (j['users'] as List?) ?? const [])
        if (u is Map) IgUser.fromJson(u.cast<String, dynamic>()),
    ];
  }

  /// Activité : qui a aimé, commenté, s'est abonné…
  Future<List<IgActivity>> activity() async {
    final j = await _get('/news/inbox/?could_truncate_feed=true');
    return [
      for (final key in const ['new_stories', 'old_stories'])
        for (final it in (j[key] as List?) ?? const [])
          if (it is Map) IgActivity.fromJson(it.cast<String, dynamic>()),
    ]..sort((a, b) => b.at.compareTo(a.at));
  }

  /// Tes propres publications (avec leurs « J'aime »).
  Future<List<IgPost>> myPosts() async {
    final j = await _get('/feed/user/$_userId/?count=24');
    return [
      for (final m in (j['items'] as List?) ?? const [])
        if (m is Map<String, dynamic> && m['user'] != null) IgPost.fromJson(m),
    ];
  }

  /// Met un ❤️ sur un message d'une conversation.
  Future<void> likeMessage(String threadId, String itemId, {String emoji = '❤️'}) async {
    _needCsrf();
    final ctx = '${DateTime.now().microsecondsSinceEpoch}';
    await _send(
      '/direct_v2/threads/broadcast/reaction/',
      form: {
        'action': 'send_item',
        'item_type': 'reaction',
        'reaction_type': 'like',
        'reaction_status': 'created',
        'node_type': 'item',
        'item_id': itemId,
        'emoji': emoji,
        'thread_ids': '[$threadId]',
        'client_context': ctx,
        'mutation_token': ctx,
        'offline_threading_id': ctx,
      },
    );
  }

  Future<void> like(String mediaId) => _post('/web/likes/$mediaId/like/', {});
  Future<void> unlike(String mediaId) => _post('/web/likes/$mediaId/unlike/', {});

  /// Bandeau des stories.
  Future<List<IgStoryUser>> storiesTray() async {
    final j = await _get('/feed/reels_tray/');
    return [
      for (final t in (j['tray'] as List? ?? []))
        if (t['user'] != null)
          IgStoryUser(
            '${t['id']}',
            IgUser.fromJson(t['user'] as Map<String, dynamic>),
            (t['seen'] ?? 0) != 0 && (t['seen'] ?? 0) >= (t['latest_reel_media'] ?? 0),
          ),
    ];
  }

  /// Images des stories d'un compte.
  Future<List<IgStoryItem>> stories(String reelId) async {
    final j = await _get('/feed/reels_media/?reel_ids=$reelId');
    final reel = (j['reels'] as Map?)?[reelId] ?? (j['reels_media'] as List?)?.firstOrNull;
    return [
      for (final it in (reel?['items'] as List? ?? []))
        IgStoryItem(
          findIgImage(it) ?? '',
          (it['video_versions'] as List?)?.isNotEmpty == true,
          DateTime.fromMillisecondsSinceEpoch(((it['taken_at'] ?? 0) as int) * 1000),
        ),
    ].where((e) => e.image.isNotEmpty).toList();
  }

  Future<(IgUser, List<IgThread>)> inbox() async {
    final j = await _get(
      '/direct_v2/inbox/?persistentBadging=true&limit=20&thread_message_limit=1',
    );
    final viewer = IgUser.fromJson(j['viewer'] as Map<String, dynamic>);
    final threads = <IgThread>[];
    for (final t in (j['inbox']?['threads'] as List? ?? [])) {
      final users = [
        for (final u in t['users'] as List? ?? []) IgUser.fromJson(u as Map<String, dynamic>),
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
        IgMessage.fromJson(m as Map<String, dynamic>),
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
  List<HubTool> get tools => [
        HubTool(
          name: 'instagram_conversations',
          description: 'Conversations Instagram (messages privés) avec le dernier message.',
          run: (_) async {
            final threads = await load(force: true);
            if (lastError != null && threads.isEmpty) throw lastError!;
            return [
              for (final t in threads)
                {
                  'id': t.id,
                  'nom': t.title,
                  if (t.last != null) 'dernier': t.last!.text,
                  'non_lu': t.unread,
                },
            ];
          },
        ),
        HubTool(
          name: 'instagram_messages',
          description: 'Messages d\'une conversation Instagram.',
          params: {'id': ('string', 'id donné par instagram_conversations')},
          required: ['id'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Instagram n\'est pas connecté';
            final t = _threads.where((x) => x.id == a['id']).firstOrNull;
            String who(String uid) => uid == me?.id
                ? 'moi'
                : t?.users.where((u) => u.id == uid).firstOrNull?.display ?? uid;
            return [
              for (final m in (await api.thread(a['id'] as String)).reversed)
                {'de': who(m.userId), 'texte': m.text, 'date': m.at},
            ];
          },
        ),
        HubTool(
          name: 'instagram_envoyer_photo',
          description: 'Envoie une photo (fichier sur le PC : JPEG, PNG, WebP…) dans une conversation Instagram.',
          params: {
            'id': ('string', 'id de la conversation (instagram_conversations)'),
            'chemin': ('string', 'Chemin de la photo sur le PC'),
          },
          required: ['id', 'chemin'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Instagram n\'est pas connecté';
            final (jpeg, w, h) = await Photo.toJpeg(await File('${a['chemin']}').readAsBytes());
            await api.sendPhoto(a['id'] as String, jpeg, w, h);
            return {'ok': true};
          },
        ),
        HubTool(
          name: 'instagram_appeler',
          description: 'Lance un appel vocal ou vidéo Instagram dans Mon Hub.',
          params: {
            'id': ('string', 'id de la conversation (instagram_conversations)'),
            'video': ('boolean', 'true : appel vidéo'),
          },
          required: ['id'],
          run: (a) async {
            final ctx = await hubDialogContext();
            if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
            final t = _threads.where((x) => x.id == a['id']).firstOrNull;
            unawaited(CallPage.open(
              ctx,
              url: 'https://www.instagram.com/direct/t/${a['id']}/',
              title: t?.title ?? 'Instagram',
              video: a['video'] == true,
              color: color,
            ));
            return {'ok': true, 'appel': a['video'] == true ? 'vidéo' : 'vocal'};
          },
        ),
        HubTool(
          name: 'instagram_envoyer',
          description: 'Envoie un message dans une conversation Instagram.',
          params: {'id': ('string', 'id de la conversation'), 'texte': ('string', 'Message')},
          required: ['id', 'texte'],
          run: (a) async {
            final api = await _client();
            if (api == null) throw 'Instagram n\'est pas connecté';
            await api.send(a['id'] as String, a['texte'] as String);
            return {'ok': true};
          },
        ),
      ];

  @override
  Future<List<HubNotification>> poll() async {
    if (!connected) return const [];
    final threads = await load(force: true);
    store.changed();
    return [
      for (final t in threads)
        if (t.last != null && t.last!.userId != me?.id)
          HubNotification(id: t.last!.id, title: 'Instagram · ${t.title}', body: t.last!.text),
    ];
  }

  Future<void> connect(BuildContext context) async {
    String s;
    if (webLoginSupported) {
      s =
          await WebLoginPage.open(
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
        message:
            '1. Ouvre instagram.com dans ton navigateur et connecte-toi.\n'
            '2. F12 > onglet « Application » > Cookies > instagram.com.\n'
            '3. Copie la valeur du cookie « sessionid ».',
        labels: ['sessionid'],
        obscure: {0},
      );
      s = r?.first.trim() ?? '';
    }
    if (s.isEmpty || !context.mounted) return;
    // On garde la session tout de suite : même si la vérification échoue
    // (réseau, vérification Instagram…), il suffira d'actualiser.
    await store.writeSecret('sessionid', s);
    _api = null;
    await store.setJson('connected', true);
    try {
      final viewer = await InstagramApi(s).me();
      await load(force: true);
      store.changed();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Connecté en tant que @${viewer.username}')));
      }
    } catch (e) {
      await load(force: true);
      store.changed();
      if (context.mounted) showError(context, 'Compte enregistré, mais : $e');
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
      size: dense ? 30 : 40,
    ),
    title: Text(
      t.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontWeight: t.unread ? FontWeight.w700 : FontWeight.w500),
    ),
    subtitle: t.last == null
        ? null
        : Text(
            '${t.last!.userId == me?.id ? 'Toi : ' : ''}${t.last!.text}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
      context,
      MaterialPageRoute(
        builder: (_) => _ThreadPage(module: this, thread: t),
      ),
    ),
  );

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (!connected) {
        return EmptyHint(
          'Connecte ton compte pour voir tes messages',
          icon: Icons.link_rounded,
          action: ('Connecter', () => connect(context)),
        );
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
  Widget buildPage(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => load(force: true).then((_) => store.changed()),
          ),
          IconButton(
            tooltip: 'Ouvrir Instagram',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => openLink(context, 'https://www.instagram.com/'),
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Fil d\'actu'),
            Tab(text: 'Messages'),
            Tab(text: 'Activité'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (!connected) {
            return EmptyHint(
              'Connecte ton compte Instagram pour voir ton fil, tes stories et '
              'tes messages ici.',
              icon: icon,
              action: ('Connecter mon compte', () => connect(context)),
            );
          }
          return TabBarView(
            children: [
              _FeedTab(module: this),
              FutureBuilder(
                future: load(),
                initialData: _threads,
                builder: (context, snap) => ListView(
                  children: [
                    if (me != null)
                      ListTile(
                        leading: HubAvatar(url: me!.pic, label: me!.username, color: color),
                        title: Text('@${me!.username}'),
                        subtitle: const Text('Connecté'),
                        trailing: TextButton(
                          onPressed: disconnect,
                          child: const Text('Déconnecter'),
                        ),
                      ),
                    if (lastError != null) ErrorBanner(lastError!),
                    const Divider(),
                    for (final t in snap.data ?? <IgThread>[]) _threadTile(context, t),
                  ],
                ),
              ),
              _ActivityTab(module: this),
            ],
          );
        },
      ),
    ),
  );
}

class _FeedTab extends StatefulWidget {
  const _FeedTab({required this.module});
  final InstagramModule module;

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> with AutomaticKeepAliveClientMixin {
  late Future<(List<IgStoryUser>, List<IgPost>)> future = _load();

  @override
  bool get wantKeepAlive => true;

  Future<(List<IgStoryUser>, List<IgPost>)> _load() async {
    final api = await widget.module._client();
    if (api == null) return (<IgStoryUser>[], <IgPost>[]);
    List<IgStoryUser> tray = [];
    try {
      tray = await api.storiesTray();
    } catch (_) {}
    final posts = await api.timeline();
    return (tray, posts);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final color = widget.module.color;
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => future = _load());
        await future;
      },
      child: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return ListView(children: [ErrorBanner('${snap.error}')]);
          if (!snap.hasData) return const LoadingHint();
          final (tray, posts) = snap.data!;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView.builder(
                itemCount: posts.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    if (tray.isEmpty) return const SizedBox(height: 8);
                    return SizedBox(
                      height: 104,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        itemCount: tray.length,
                        itemBuilder: (context, j) {
                          final t = tray[j];
                          return GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                fullscreenDialog: true,
                                builder: (_) => _StoryViewer(module: widget.module, story: t),
                              ),
                            ),
                            child: SizedBox(
                              width: 76,
                              child: Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: t.seen
                                          ? null
                                          : const LinearGradient(
                                              colors: [
                                                Color(0xFFFEDA75),
                                                Color(0xFFFA7E1E),
                                                Color(0xFFD62976),
                                                Color(0xFF962FBF),
                                              ],
                                            ),
                                      color: t.seen ? Colors.grey.shade400 : null,
                                    ),
                                    child: HubAvatar(
                                      url: t.user.pic,
                                      label: t.user.username,
                                      color: color,
                                      size: 58,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    t.user.username,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }
                  return _PostCard(module: widget.module, post: posts[i - 1]);
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PostCard extends StatefulWidget {
  const _PostCard({required this.module, required this.post});
  final InstagramModule module;
  final IgPost post;

  @override
  State<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<_PostCard> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: HubAvatar(
              url: p.user.pic,
              label: p.user.username,
              color: widget.module.color,
              size: 36,
            ),
            title: Text(p.user.username, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(timeAgo(p.at)),
          ),
          if (p.images.isNotEmpty)
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  PageView(
                    onPageChanged: (i) => setState(() => page = i),
                    children: [
                      for (final url in p.images)
                        GestureDetector(
                          onTap: () => showPhoto(context, url),
                          onDoubleTap: _toggleLike,
                          child: Image.network(
                            url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Center(child: Icon(Icons.broken_image_rounded)),
                          ),
                        ),
                    ],
                  ),
                  if (p.isVideo)
                    const Center(
                      child: Icon(Icons.play_circle_fill_rounded, size: 64, color: Colors.white70),
                    ),
                  if (p.images.length > 1)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${page + 1}/${p.images.length}',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  p.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: p.liked ? Colors.red : null,
                ),
                onPressed: _toggleLike,
              ),
              InkWell(
                onTap: () => showLikers(context, widget.module, p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${p.likes} j\'aime',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'Commentaires / vidéo (ouvre Instagram)',
                icon: const Icon(Icons.mode_comment_outlined),
                onPressed: () => openLink(context, 'https://www.instagram.com/p/${p.code}/'),
              ),
              Text('${p.comments}'),
            ],
          ),
          if (p.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${p.user.username} ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: p.caption),
                  ],
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleLike() async {
    final p = widget.post;
    setState(() {
      p.liked = !p.liked;
      p.likes += p.liked ? 1 : -1;
    });
    try {
      final api = await widget.module._client();
      p.liked ? await api!.like(p.id) : await api!.unlike(p.id);
    } catch (e) {
      if (mounted) {
        setState(() {
          p.liked = !p.liked;
          p.likes += p.liked ? 1 : -1;
        });
        showError(context, e);
      }
    }
  }
}

class _StoryViewer extends StatefulWidget {
  const _StoryViewer({required this.module, required this.story});
  final InstagramModule module;
  final IgStoryUser story;

  @override
  State<_StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<_StoryViewer> {
  late final Future<List<IgStoryItem>> future = widget.module._client().then(
    (api) => api!.stories(widget.story.reelId),
  );
  int index = 0;
  Timer? timer;

  void _next(int count) {
    if (index < count - 1) {
      setState(() => index++);
      _arm(count);
    } else {
      Navigator.pop(context);
    }
  }

  void _arm(int count) {
    timer?.cancel();
    timer = Timer(const Duration(seconds: 6), () => _next(count));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return EmptyHint('${snap.error}');
          if (!snap.hasData) return const LoadingHint();
          final items = snap.data!;
          if (items.isEmpty) return const EmptyHint('Story indisponible');
          if (timer == null) _arm(items.length);
          final it = items[index];
          return GestureDetector(
            onTapUp: (d) {
              final left = d.localPosition.dx < MediaQuery.sizeOf(context).width / 3;
              if (left && index > 0) {
                setState(() => index--);
                _arm(items.length);
              } else if (!left) {
                _next(items.length);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(it.image, fit: BoxFit.contain),
                if (it.isVideo)
                  Center(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Vidéo : ouvrir dans Instagram'),
                      onPressed: () => openLink(
                        context,
                        'https://www.instagram.com/stories/${widget.story.user.username}/',
                      ),
                    ),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            for (var i = 0; i < items.length; i++)
                              Expanded(
                                child: Container(
                                  height: 3,
                                  margin: const EdgeInsets.symmetric(horizontal: 2),
                                  color: i <= index ? Colors.white : Colors.white30,
                                ),
                              ),
                          ],
                        ),
                        ListTile(
                          leading: HubAvatar(
                            url: widget.story.user.pic,
                            label: widget.story.user.username,
                            color: widget.module.color,
                            size: 32,
                          ),
                          title: Text(
                            widget.story.user.username,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            timeAgo(it.at),
                            style: const TextStyle(color: Colors.white70),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
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

  /// Double-clic : ❤️ sur le message.
  Future<void> _like(IgMessage m) async {
    if (m.reactions.any((r) => r.$2 == module.me?.id)) return;
    try {
      final api = await module._client();
      await api!.likeMessage(thread.id, m.id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
        title: Row(
          children: [
            HubAvatar(
              url: thread.users.length == 1 ? thread.users.first.pic : null,
              label: thread.title,
              color: module.color,
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(thread.title, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Appel vocal',
            icon: const Icon(Icons.call_rounded),
            onPressed: () => CallPage.open(
              context,
              url: 'https://www.instagram.com/direct/t/${thread.id}/',
              title: thread.title,
              video: false,
              color: module.color,
            ),
          ),
          IconButton(
            tooltip: 'Appel vidéo',
            icon: const Icon(Icons.videocam_rounded),
            onPressed: () => CallPage.open(
              context,
              url: 'https://www.instagram.com/direct/t/${thread.id}/',
              title: thread.title,
              video: true,
              color: module.color,
            ),
          ),
        ],
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
                      String who(String id) => id == module.me?.id ? 'Toi' : (names[id] ?? '@$id');
                      final byEmoji = <String, List<String>>{};
                      for (final (e, id) in m.reactions) {
                        (byEmoji[e] ??= []).add(who(id));
                      }
                      return ChatBubble(
                        text: m.isVoice ? '' : (m.isLike ? '' : m.text),
                        images: [?m.image],
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
                            : m.isLike
                            ? const Text('❤️', style: TextStyle(fontSize: 40))
                            : null,
                        reactions: [
                          for (final e in byEmoji.entries)
                            Reaction(e.key, e.value, mine: e.value.contains('Toi')),
                        ],
                        onDoubleTap: () => _like(m),
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
            onAttach: () async {
              // Une ou plusieurs photos, converties en JPEG (seul format
              // accepté par Instagram).
              final files = await openFiles(
                acceptedTypeGroups: const [XTypeGroup(label: 'Photos', extensions: Photo.extensions)],
              );
              if (files.isEmpty) return;
              final api = await module._client();
              for (final file in files) {
                final (jpeg, w, h) = await Photo.toJpeg(await file.readAsBytes());
                await api!.sendPhoto(thread.id, jpeg, w, h);
              }
              await _load();
            },
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

/// Qui a aimé une publication.
Future<void> showLikers(BuildContext context, InstagramModule module, IgPost p) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SizedBox(
        height: MediaQuery.sizeOf(c).height * 0.7,
        child: FutureBuilder(
          future: module._client().then((api) => api!.likers(p.id)),
          builder: (c, snap) {
            if (snap.hasError) return EmptyHint('${snap.error}');
            if (!snap.hasData) return const LoadingHint();
            final users = snap.data!;
            return ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.favorite_rounded, color: Colors.red),
                  title: Text('${p.likes} j\'aime'),
                  subtitle: users.length < p.likes
                      ? Text('Instagram montre ${users.length} personnes sur ${p.likes}')
                      : null,
                ),
                for (final u in users)
                  ListTile(
                    leading: HubAvatar(url: u.pic, label: u.username, color: module.color),
                    title: Text(u.display),
                    subtitle: Text('@${u.username}'),
                    onTap: () => openLink(c, 'https://www.instagram.com/${u.username}/'),
                  ),
              ],
            );
          },
        ),
      ),
    );

/// Activité : tes publications avec leurs « J'aime », et qui a aimé,
/// commenté, s'est abonné.
class _ActivityTab extends StatefulWidget {
  const _ActivityTab({required this.module});
  final InstagramModule module;

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab> with AutomaticKeepAliveClientMixin {
  late Future<(List<IgPost>, List<IgActivity>, String?)> future = _load();

  @override
  bool get wantKeepAlive => true;

  Future<(List<IgPost>, List<IgActivity>, String?)> _load() async {
    final api = await widget.module._client();
    if (api == null) return (<IgPost>[], <IgActivity>[], null);
    var posts = <IgPost>[];
    var acts = <IgActivity>[];
    String? err;
    try {
      posts = await api.myPosts();
    } catch (e) {
      err = '$e';
    }
    try {
      acts = await api.activity();
    } catch (e) {
      err ??= '$e';
    }
    return (posts, acts, err);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final color = widget.module.color;
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => future = _load());
        await future;
      },
      child: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (!snap.hasData) return const LoadingHint();
          final (posts, acts, err) = snap.data!;
          final likes = posts.fold<int>(0, (a, p) => a + p.likes);
          return ListView(
            children: [
              if (err != null && posts.isEmpty && acts.isEmpty) ErrorBanner(err),
              if (posts.isNotEmpty) ...[
                ListTile(
                  leading: const Icon(Icons.favorite_rounded, color: Colors.red),
                  title: Text('$likes j\'aime sur tes ${posts.length} dernières publications'),
                  subtitle: const Text('Touche une publication pour voir qui l\'a aimée'),
                ),
                SizedBox(
                  height: 130,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final p in posts)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: InkWell(
                            onTap: () => showLikers(context, widget.module, p),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Stack(
                                children: [
                                  SizedBox(
                                    width: 110,
                                    height: 120,
                                    child: p.images.isEmpty
                                        ? ColoredBox(color: color.withValues(alpha: 0.2))
                                        : Image.network(
                                            p.images.first,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                const Icon(Icons.broken_image_rounded),
                                          ),
                                  ),
                                  Positioned(
                                    left: 6,
                                    bottom: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '❤️ ${p.likes}  💬 ${p.comments}',
                                        style: const TextStyle(color: Colors.white, fontSize: 11),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(),
              ],
              if (acts.isEmpty && err == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: EmptyHint('Aucune activité récente'),
                ),
              for (final a in acts)
                ListTile(
                  leading: HubAvatar(url: a.pic, label: a.text, color: color),
                  title: Text(a.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text(timeAgo(a.at)),
                  trailing: a.thumb != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            a.thumb!,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox(width: 44),
                          ),
                        )
                      : (a.isLike ? const Icon(Icons.favorite_rounded, color: Colors.red) : null),
                ),
            ],
          );
        },
      ),
    );
  }
}
