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
        j['id'] as String,
        (j['global_name'] as String?) ?? (j['username'] as String? ?? '?'),
        j['avatar'] as String?,
      );
}

class DiscordMessage {
  DiscordMessage(this.id, this.author, this.content, this.at);
  final String id;
  final DiscordUser author;
  final String content;
  final DateTime at;

  factory DiscordMessage.fromJson(Map<String, dynamic> j) {
    var content = j['content'] as String? ?? '';
    final attachments = (j['attachments'] as List?)?.length ?? 0;
    if (content.isEmpty && attachments > 0) content = '📎 Pièce jointe';
    if (content.isEmpty && (j['sticker_items'] as List?)?.isNotEmpty == true) {
      content = '🖼️ Sticker';
    }
    return DiscordMessage(
      j['id'] as String,
      DiscordUser.fromJson(j['author'] as Map<String, dynamic>),
      content,
      DateTime.tryParse(j['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
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

  Future<dynamic> _get(String path) async {
    final r = await _http.get(Uri.parse('$_base$path'), headers: {
      'Authorization': token,
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36',
    });
    if (r.statusCode == 401) throw 'Jeton Discord invalide ou expiré';
    if (r.statusCode == 429) throw 'Discord demande de ralentir, réessaie plus tard';
    if (r.statusCode >= 400) throw 'Discord : erreur ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<DiscordUser> me() async =>
      DiscordUser.fromJson(await _get('/users/@me') as Map<String, dynamic>);

  /// Conversations privées, de la plus récente à la plus ancienne.
  Future<List<DiscordDm>> dms() async {
    final list = (await _get('/users/@me/channels') as List).cast<Map<String, dynamic>>();
    final out = [
      for (final c in list)
        if (c['type'] == 1 || c['type'] == 3)
          DiscordDm(
            c['id'] as String,
            (c['name'] as String?)?.isNotEmpty == true
                ? c['name'] as String
                : (c['recipients'] as List)
                    .map((u) => DiscordUser.fromJson(u as Map<String, dynamic>).name)
                    .join(', '),
            [
              for (final u in c['recipients'] as List)
                DiscordUser.fromJson(u as Map<String, dynamic>)
            ],
            c['last_message_id'] as String?,
          ),
    ];
    BigInt k(DiscordDm d) => BigInt.tryParse(d.lastMessageId ?? '0') ?? BigInt.zero;
    out.sort((a, b) => k(b).compareTo(k(a)));
    return out;
  }

  Future<List<DiscordMessage>> messages(String channelId, {int limit = 30}) async {
    final list = await _get('/channels/$channelId/messages?limit=$limit') as List;
    return list.map((m) => DiscordMessage.fromJson(m as Map<String, dynamic>)).toList();
  }
}
