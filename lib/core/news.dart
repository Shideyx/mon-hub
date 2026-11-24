import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Un titre d'actualité.
class NewsItem {
  const NewsItem(this.title, this.summary, this.source, this.at, this.link);
  final String title;
  final String summary;
  final String source;
  final DateTime? at;
  final String link;

  Map<String, Object?> toJson() => {
    'titre': title,
    if (summary.isNotEmpty) 'resume': summary,
    'source': source,
    'quand': at?.toIso8601String(),
  };
}

/// Actualités gratuites et sans clé : les flux RSS des grands médias
/// (France et international).
class News {
  News._();

  static const feeds = {
    'france': [
      ('franceinfo', 'https://www.francetvinfo.fr/titres.rss'),
      ('Le Monde', 'https://www.lemonde.fr/rss/une.xml'),
    ],
    'monde': [
      ('Le Monde International', 'https://www.lemonde.fr/international/rss_full.xml'),
      ('France 24', 'https://www.france24.com/fr/rss'),
    ],
    'sport': [('L\'Équipe', 'https://dwh.lequipe.fr/api/edito/rss?path=/')],
    'tech': [('Le Monde Pixels', 'https://www.lemonde.fr/pixels/rss_full.xml')],
  };

  static final _cache = <String, (DateTime, List<NewsItem>)>{};

  static String _text(String s) => s
      .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String? _tag(String item, String tag) =>
      RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false).firstMatch(item)?.group(1);

  /// Lit un flux RSS.
  static List<NewsItem> parse(String xml, String source) {
    final out = <NewsItem>[];
    for (final m in RegExp(r'<item[\s>][\s\S]*?</item>', caseSensitive: false).allMatches(xml)) {
      final it = m.group(0)!;
      final title = _text(_tag(it, 'title') ?? '');
      if (title.isEmpty) continue;
      var summary = _text(_tag(it, 'description') ?? '');
      if (summary.length > 240) summary = '${summary.substring(0, 237)}…';
      DateTime? at;
      final d = _tag(it, 'pubDate');
      if (d != null) at = _rfc822(_text(d));
      out.add(NewsItem(title, summary, source, at, _text(_tag(it, 'link') ?? '')));
    }
    return out;
  }

  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  /// « Tue, 17 Nov 2026 06:12:00 +0100 ».
  static DateTime? _rfc822(String s) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})(?::(\d{2}))? ?([+-]\d{4}|GMT|UT|Z)?').firstMatch(s);
    if (m == null) return DateTime.tryParse(s);
    final mo = _months[m.group(2)!.toLowerCase()];
    if (mo == null) return null;
    var d = DateTime.utc(
      int.parse(m.group(3)!),
      mo,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.tryParse(m.group(6) ?? '') ?? 0,
    );
    final z = m.group(7);
    if (z != null && (z.startsWith('+') || z.startsWith('-'))) {
      final sign = z.startsWith('-') ? -1 : 1;
      d = d.subtract(
        Duration(hours: sign * int.parse(z.substring(1, 3)), minutes: sign * int.parse(z.substring(3, 5))),
      );
    }
    return d.toLocal();
  }

  /// Les derniers titres d'une rubrique (france, monde, sport, tech), mis
  /// en cache 15 minutes. Les doublons entre médias sont retirés.
  static Future<List<NewsItem>> latest(String zone, {int max = 8, http.Client? client}) async {
    final z = feeds.containsKey(zone) ? zone : 'france';
    final c = _cache[z];
    if (c != null && DateTime.now().difference(c.$1) < const Duration(minutes: 15)) {
      return c.$2.take(max).toList();
    }
    final h = client ?? http.Client();
    final all = <NewsItem>[];
    await Future.wait([
      for (final (name, url) in feeds[z]!)
        () async {
          try {
            final r = await h
                .get(Uri.parse(url), headers: {'user-agent': 'Mozilla/5.0 MonHub'})
                .timeout(const Duration(seconds: 12));
            if (r.statusCode == 200) {
              all.addAll(parse(utf8.decode(r.bodyBytes, allowMalformed: true), name));
            }
          } catch (_) {}
        }(),
    ]);
    all.sort((a, b) => (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
    final seen = <String>{};
    final unique = [
      for (final n in all)
        if (seen.add(n.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').padRight(40).substring(0, 40))) n,
    ];
    if (unique.isEmpty) throw 'Actualités indisponibles (pas d\'internet ?)';
    _cache[z] = (DateTime.now(), unique);
    return unique.take(max).toList();
  }
}
