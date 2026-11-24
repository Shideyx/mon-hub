/// **« Qu'est-ce que j'ai raté ? »** : ce qui est arrivé pendant ton
/// absence, en quelques phrases et **sans IA** — messages privés Discord,
/// mentions dans tes serveurs, mails importants (pas les pubs), messages
/// École Directe, et qui attend ta réponse.
class CatchUp {
  CatchUp._();

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('${v ?? ''}');

  static List<Map> _maps(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is Map) x,
  ];

  /// Les mails « pub » (newsletters, promos, réseaux sociaux).
  static final _promo = RegExp(
    r'no-?reply|newsletter|news@|promo|marketing|offres?|deals|info@|notification|mailer|bonjour@|hello@',
    caseSensitive: false,
  );
  static final _promoSubject = RegExp(
    r'promo|soldes|-\s?\d+\s?%|offre|r[ée]duction|newsletter|black friday|code promo|gratuit|livraison offerte|unsubscribe|d[ée]sabonn',
    caseSensitive: false,
  );

  static bool importantMail(Map m) {
    final from = '${m['de'] ?? ''}';
    final subject = '${m['objet'] ?? ''}';
    return !_promo.hasMatch(from) && !_promoSubject.hasMatch(subject);
  }

  static String _short(String s, [int max = 60]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  static String _ago(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} jour${d.inDays > 1 ? 's' : ''}';
  }

  static String _list(List<String> l) =>
      l.length <= 1 ? l.join() : '${l.sublist(0, l.length - 1).join(', ')} et ${l.last}';

  /// Le résumé (vide : rien de nouveau).
  static String build({
    List<Map> dms = const [],
    List<Map> mentions = const [],
    List<Map> mails = const [],
    List<Map> school = const [],
    required DateTime now,
    Duration since = const Duration(hours: 12),
  }) {
    final from = now.subtract(since);
    final parts = <String>[];
    final unread = [
      for (final d in dms)
        if (d['non_lu'] == true && d['de_moi'] != true) d,
    ];
    if (unread.isNotEmpty) {
      final shown = [
        for (final d in unread.take(3))
          '${d['nom']}${'${d['dernier'] ?? ''}'.contains(' : ') ? ' (« ${_short('${d['dernier']}'.split(' : ').skip(1).join(' : '), 45)} »)' : ''}',
      ];
      parts.add(
        '${unread.length} message${unread.length > 1 ? 's' : ''} privé${unread.length > 1 ? 's' : ''} sur Discord : '
        '${_list(shown)}${unread.length > 3 ? '…' : ''}',
      );
    }
    final ment = [
      for (final m in mentions)
        if ((_date(m['date']) ?? now).isAfter(from)) m,
    ];
    if (ment.isNotEmpty) {
      final servers = {for (final m in ment) '${m['serveur'] ?? 'un serveur'}'}.toList();
      final last = ment.first;
      parts.add(
        '${ment.length} mention${ment.length > 1 ? 's' : ''} sur ${_list(servers.take(3).toList())}'
        ' (${last['de']} : « ${_short('${last['texte'] ?? ''}', 45)} »)',
      );
    }
    final newMails = [
      for (final m in mails)
        if (m['lu'] == false && (_date(m['date']) ?? now).isAfter(from)) m,
    ];
    final important = [
      for (final m in newMails)
        if (importantMail(m)) m,
    ];
    if (important.isNotEmpty) {
      String who(Map m) => '${m['de'] ?? ''}'.split('<').first.trim();
      parts.add(
        '${important.length} mail${important.length > 1 ? 's' : ''} important${important.length > 1 ? 's' : ''} : '
        '${_list([for (final m in important.take(3)) '${who(m)} (« ${_short('${m['objet']}', 40)} »)'])}',
      );
    }
    final pubs = newMails.length - important.length;
    if (pubs > 0 && parts.isNotEmpty) {
      parts.add('$pubs pub${pubs > 1 ? 's' : ''} ou newsletter${pubs > 1 ? 's' : ''} sans importance');
    }
    final ed = [
      for (final m in school)
        if (m['lu'] == false) m,
    ];
    if (ed.isNotEmpty) {
      parts.add(
        '${ed.length} message${ed.length > 1 ? 's' : ''} École Directe (${_list([for (final m in ed.take(2)) '${m['de']}'])})',
      );
    }
    if (parts.isEmpty) return '';
    // Qui attend une réponse depuis longtemps.
    final waiting = [
      for (final d in unread)
        if (_date(d['date']) case final at? when now.difference(at) >= const Duration(hours: 2))
          (d, now.difference(at)),
    ];
    final wait = waiting.isEmpty
        ? ''
        : ' ${waiting.first.$1['nom']} attend ta réponse depuis ${_ago(waiting.first.$2)}.';
    return 'Pendant ton absence : ${parts.join(' ; ')}.$wait';
  }

  /// Une seule phrase courte (pour le « re-bonjour » de Smily).
  static String short(String full) {
    if (full.isEmpty) return '';
    final body = full.replaceFirst('Pendant ton absence : ', '');
    final first = body.split(' ; ').take(2).map((p) => p.split(' : ').first.split(' (').first).join(' et ');
    return 'Tu as $first.';
  }

  /// Lit les modules (outils de lecture) et fabrique le résumé.
  static Future<String> gather(
    Future<Object?> Function(String tool, Map<String, dynamic> args) call,
    Set<String> tools, {
    Duration since = const Duration(hours: 12),
  }) async {
    Future<Object?> get(String t, [Map<String, dynamic> a = const {}]) async {
      if (!tools.contains(t)) return null;
      try {
        return await call(t, a).timeout(const Duration(seconds: 15));
      } catch (_) {
        return null;
      }
    }

    final r = await Future.wait([
      get('discord_conversations'),
      get('discord_mentions', {'heures': since.inHours.clamp(1, 72)}),
      get('mails_lister', {'nombre': 30}),
      get('ecole_messages'),
    ]);
    return build(
      dms: _maps(r[0]),
      mentions: _maps(r[1]),
      mails: _maps(r[2]),
      school: _maps(r[3]),
      now: DateTime.now(),
      since: since,
    );
  }
}
