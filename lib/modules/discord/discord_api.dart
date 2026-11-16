import 'dart:convert';

import 'package:http/http.dart' as http;

class DiscordUser {
  DiscordUser(this.id, this.name, this.avatar);
  final String id;
  final String name;
  final String? avatar;

  String? get avatarUrl => avatar == null
      ? null
      : 'https://cdn.discordapp.com/avatars/$id/$avatar.png?size=64';

  factory DiscordUser.fromJson(Map<String, dynamic> j) => DiscordUser(
        '${j['id']}',
        (j['global_name'] as String?) ?? (j['username'] as String? ?? '?'),
        j['avatar'] as String?,
      );
}

/// Une réaction sous un message Discord.
class DiscordReaction {
  DiscordReaction(this.name, this.emojiId, this.count, this.me, [this.animated = false]);
  final String name;
  final String? emojiId;
  final int count;
  final bool me;
  final bool animated;

  /// Texte affiché : l'emoji lui-même, ou :nom: pour un emoji de serveur.
  String get label => emojiId == null ? name : ':$name:';

  /// Forme attendue par l'API (nom, ou nom:id pour un emoji de serveur).
  String get apiKey => emojiId == null ? name : '$name:$emojiId';
}

class DiscordMessage {
  DiscordMessage(
    this.id,
    this.author,
    this.content,
    this.at, [
    this.images = const [],
    this.audioUrl,
    this.audioLength,
    this.waveform = const [],
    this.reactions = const [],
  ]);
  final String id;
  final DiscordUser author;
  final String content;
  final DateTime at;
  final List<String> images;

  /// Message vocal (ou fichier audio) : adresse, durée, onde.
  final String? audioUrl;
  final Duration? audioLength;
  final List<double> waveform;
  final List<DiscordReaction> reactions;

  bool get isVoice => audioUrl != null;

  /// Texte court (liste des conversations, alertes).
  String get preview => content.isNotEmpty
      ? content
      : isVoice
      ? '🎤 Message vocal'
      : images.isNotEmpty
      ? '📷 Photo'
      : '';

  /// Onde des messages vocaux : octets 0..255 en base64.
  static List<double> _wave(Object? b64) {
    if (b64 is! String || b64.isEmpty) return const [];
    try {
      return [for (final b in base64.decode(b64)) b / 255];
    } catch (_) {
      return const [];
    }
  }

  factory DiscordMessage.fromJson(Map<String, dynamic> j) {
    var content = j['content'] as String? ?? '';
    final atts = (j['attachments'] as List?) ?? const [];
    final images = <String>[
      for (final a in atts)
        if ('${a['content_type'] ?? ''}'.startsWith('image/') ||
            RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch('${a['filename']}'))
          '${a['proxy_url'] ?? a['url']}',
      for (final e in (j['embeds'] as List?) ?? const [])
        if (e['type'] == 'image' || e['type'] == 'gifv')
          if ((e['thumbnail']?['proxy_url'] ?? e['thumbnail']?['url'] ?? e['url']) != null)
            '${e['thumbnail']?['proxy_url'] ?? e['thumbnail']?['url'] ?? e['url']}',
    ];
    // Message vocal (drapeau 8192) ou fichier audio.
    final audio = atts.whereType<Map>().where((a) {
      final type = '${a['content_type'] ?? ''}';
      return type.startsWith('audio/') ||
          a['waveform'] != null ||
          RegExp(r'\.(ogg|mp3|m4a|wav|opus)$', caseSensitive: false).hasMatch('${a['filename']}');
    }).firstOrNull;
    final secs = (audio?['duration_secs'] as num?)?.toDouble();
    final others = atts.length - images.length - (audio == null ? 0 : 1);
    if (content.isEmpty && others > 0) content = '📎 Pièce jointe';

    if (content.isEmpty &&
        images.isEmpty &&
        audio == null &&
        (j['sticker_items'] as List?)?.isNotEmpty == true) {
      content = '🖼️ Sticker';
    }
    if (content.isEmpty && images.isEmpty && audio == null) {
      content = switch (j['type']) {
        3 => '📞 Appel',
        7 => '👋 A rejoint',
        _ => (j['embeds'] as List?)?.isNotEmpty == true ? '🔗 Lien' : '',
      };
    }
    return DiscordMessage(
      '${j['id']}',
      DiscordUser.fromJson((j['author'] as Map?)?.cast<String, dynamic>() ?? const {'id': '0'}),
      content,
      DateTime.tryParse(j['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      images,
      audio == null ? null : '${audio['url'] ?? audio['proxy_url']}',
      secs == null ? null : Duration(milliseconds: (secs * 1000).round()),
      _wave(audio?['waveform']),
      [
        for (final r in (j['reactions'] as List?) ?? const [])
          if (r is Map)
            DiscordReaction(
              '${(r['emoji'] as Map?)?['name'] ?? '?'}',
              (r['emoji'] as Map?)?['id'] as String?,
              (r['count'] as num?)?.toInt() ?? 1,
              r['me'] == true,
              (r['emoji'] as Map?)?['animated'] == true,
            ),
      ],
    );
  }
}

class DiscordDm {
  DiscordDm(this.id, this.name, this.recipients, this.lastMessageId);
  final String id;
  final String name;
  final List<DiscordUser> recipients;
  final String? lastMessageId;
  DiscordMessage? last;

  String? get avatarUrl => recipients.length == 1 ? recipients.first.avatarUrl : null;
}

/// Accès à ton compte Discord avec ton jeton utilisateur (lecture seule).
///
/// ⚠️ Les conditions d'utilisation de Discord interdisent d'automatiser un
/// compte utilisateur. Ce client ne fait que lire, peu souvent, pour limiter
/// le risque, mais celui-ci n'est pas nul.
class DiscordApi {
  DiscordApi(this.token, [http.Client? client]) : _http = client ?? http.Client();

  final String token;
  final http.Client _http;
  static const _base = 'https://discord.com/api/v10';

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  /// Mêmes informations que le client web officiel : sans elles, Discord
  /// renvoie parfois des listes vides ou refuse la lecture des messages.
  static final _superProps = base64.encode(utf8.encode(jsonEncode({
    'os': 'Windows',
    'browser': 'Chrome',
    'device': '',
    'system_locale': 'fr-FR',
    'browser_user_agent': _ua,
    'browser_version': '131.0.0.0',
    'os_version': '10',
    'release_channel': 'stable',
    'client_build_number': 360000,
  })));

  Map<String, String> get _headers => {
        'Authorization': token,
        'Content-Type': 'application/json',
        'User-Agent': _ua,
        'X-Super-Properties': _superProps,
        'X-Discord-Locale': 'fr',
        'X-Discord-Timezone': 'Europe/Paris',
        'Accept-Language': 'fr-FR,fr;q=0.9',
        'Origin': 'https://discord.com',
        'Referer': 'https://discord.com/channels/@me',
      };

  /// Requête avec une nouvelle tentative si Discord demande de ralentir.
  Future<http.Response> _send(Future<http.Response> Function() run) async {
    for (var i = 0; ; i++) {
      final r = await run().timeout(const Duration(seconds: 20));
      if (r.statusCode != 429 || i >= 2) return r;
      double wait = 1;
      try {
        wait = ((jsonDecode(r.body) as Map)['retry_after'] as num).toDouble();
      } catch (_) {}
      await Future<void>.delayed(Duration(milliseconds: (wait.clamp(0.2, 5) * 1000).round()));
    }
  }

  dynamic _check(http.Response r) {
    if (r.statusCode == 401) throw 'Session Discord expirée : reconnecte ton compte';
    if (r.statusCode == 403) throw 'Discord refuse l\'accès à cette conversation';
    if (r.statusCode == 429) throw 'Discord demande de ralentir, réessaie plus tard';
    if (r.statusCode >= 400) throw 'Discord : erreur ${r.statusCode}';
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<dynamic> _post(String path, Object body) async => _check(await _send(() => _http
      .post(Uri.parse('$_base$path'), headers: _headers, body: jsonEncode(body))));

  /// Envoie un message dans une conversation.
  Future<DiscordMessage> send(String channelId, String content) async {
    final nonce = (BigInt.from(DateTime.now().millisecondsSinceEpoch - 1420070400000) << 22).toString();
    final j = await _post('/channels/$channelId/messages',
        {'content': content, 'nonce': nonce, 'tts': false, 'flags': 0});
    return DiscordMessage.fromJson(j as Map<String, dynamic>);
  }

  /// Envoie une photo (ou n'importe quel fichier) dans une conversation.
  Future<DiscordMessage> sendFile(String channelId, String filename, List<int> bytes,
      {String content = ''}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/channels/$channelId/messages'))
      ..headers.addAll({..._headers}..remove('Content-Type'))
      ..fields['payload_json'] = jsonEncode({
        'content': content,
        'attachments': [
          {'id': 0, 'filename': filename}
        ],
      })
      ..files.add(http.MultipartFile.fromBytes('files[0]', bytes, filename: filename));
    final res = await http.Response.fromStream(await _http.send(req));
    return DiscordMessage.fromJson(_check(res) as Map<String, dynamic>);
  }

  /// Tes amis (pour démarrer une nouvelle conversation).
  Future<List<DiscordUser>> friends() async {
    final list = await _get('/users/@me/relationships') as List;
    return [
      for (final r in list)
        if (r['type'] == 1) DiscordUser.fromJson(r['user'] as Map<String, dynamic>)
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Ouvre (ou retrouve) la conversation privée avec un ami.
  Future<String> openDm(String userId) async {
    final j = await _post('/users/@me/channels', {'recipients': [userId]});
    return (j as Map<String, dynamic>)['id'] as String;
  }

  Future<dynamic> _get(String path) async {
    final r = await _send(() => _http.get(Uri.parse('$_base$path'), headers: _headers));
    return _check(r);
  }

  Future<DiscordUser> me() async =>
      DiscordUser.fromJson(await _get('/users/@me') as Map<String, dynamic>);

  /// Conversations privées, de la plus récente à la plus ancienne.
  Future<List<DiscordDm>> dms() async {
    final list = (await _get('/users/@me/channels') as List).cast<Map<String, dynamic>>();
    final out = [
      for (final c in list)
        if (c['type'] == 1 || c['type'] == 3)
          () {
            final users = [
              for (final u in (c['recipients'] as List?) ?? const [])
                DiscordUser.fromJson((u as Map).cast<String, dynamic>())
            ];
            return DiscordDm(
              '${c['id']}',
              (c['name'] as String?)?.isNotEmpty == true
                  ? c['name'] as String
                  : users.isEmpty
                      ? 'Conversation'
                      : users.map((u) => u.name).join(', '),
              users,
              c['last_message_id'] as String?,
            );
          }(),
    ];
    BigInt k(DiscordDm d) => BigInt.tryParse(d.lastMessageId ?? '0') ?? BigInt.zero;
    out.sort((a, b) => k(b).compareTo(k(a)));
    return out;
  }

  /// Qui a mis une réaction sur un message.
  Future<List<DiscordUser>> reactors(String channelId, String messageId, DiscordReaction r) async {
    final list = await _get(
      '/channels/$channelId/messages/$messageId/reactions/${Uri.encodeComponent(r.apiKey)}?limit=100',
    ) as List;
    return [for (final u in list) DiscordUser.fromJson((u as Map).cast<String, dynamic>())];
  }

  /// Ajoute une réaction (❤️ par défaut) à un message.
  Future<void> react(String channelId, String messageId, [String emoji = '❤️']) async {
    final r = await _send(() => _http.put(
          Uri.parse(
            '$_base/channels/$channelId/messages/$messageId/reactions/${Uri.encodeComponent(emoji)}/@me',
          ),
          headers: _headers,
        ));
    _check(r);
  }

  Future<List<DiscordMessage>> messages(String channelId, {int limit = 30}) async {
    final list = await _get('/channels/$channelId/messages?limit=$limit') as List;
    return list.map((m) => DiscordMessage.fromJson(m as Map<String, dynamic>)).toList();
  }
}
