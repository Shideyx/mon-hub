import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'book_finder.dart';

/// Ce qui est cherché, débarrassé des « Tome 3 », « chap. 12 », sous-titres…
class ReadQuery {
  const ReadQuery({required this.title, required this.full, this.volume, this.chapter});

  /// Le titre nettoyé (« One Piece »).
  final String title;

  /// Le titre tel qu'il a été écrit (« One Piece - Tome 03 : … »).
  final String full;
  final int? volume;
  final double? chapter;

  static final _chapter = RegExp(r'\b(?:chapitres?|chapters?|chap\.?|ch\.|ch|#)\s*(\d+(?:[.,]\d+)?)', caseSensitive: false);
  static final _volume = RegExp(r'\b(?:tomes?|volumes?|vol\.?|t\.)\s*(\d{1,3})\b', caseSensitive: false);

  /// Coupe le sous-titre (« : … », « - … », « (… ») sans casser « Re:Zero »
  /// ni « Spider-Man ».
  static final _subtitle = RegExp(r'\s[:\-–—(|]|:\s|\(');

  static ReadQuery parse(String raw) {
    final full = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    final ch = _chapter.firstMatch(full);
    final vol = _volume.firstMatch(full);
    var cut = full.length;
    for (final m in [ch, vol]) {
      if (m != null && m.start > 0) cut = math.min(cut, m.start);
    }
    final sub = _subtitle.firstMatch(full);
    if (sub != null && sub.start > 1) cut = math.min(cut, sub.start);
    var title = full.substring(0, cut).trim();
    title = title.replaceAll(RegExp(r'[\s:\-–—,.]+$'), '').trim();
    if (title.isEmpty) title = full;
    return ReadQuery(
      title: title,
      full: full,
      volume: vol == null ? null : int.tryParse(vol.group(1)!),
      chapter: ch == null ? null : double.tryParse(ch.group(1)!.replaceAll(',', '.')),
    );
  }
}

/// Un endroit où lire le livre ou le manga, trouvé tout seul.
class ReadMatch {
  const ReadMatch({
    required this.source,
    required this.id,
    required this.title,
    this.author = '',
    this.coverUrl,
    this.languages = const [],
    this.textUrl,
    this.webUrl,
    this.year,
    this.rank = 0,
    this.score = 0,
    this.similarity = 0,
    this.altTitles = const [],
  });

  /// `mangadex` (scans de manga), `gutenberg` (livres libres, texte),
  /// `archive` (livres scannés, Internet Archive).
  final String source;
  final String id;
  final String title;
  final String author;
  final String? coverUrl;
  final List<String> languages;

  /// Texte brut du livre (Gutenberg) : lu dans le lecteur de Mon Hub.
  final String? textUrl;

  /// Page web de lecture (Internet Archive).
  final String? webUrl;
  final int? year;

  /// Place dans les résultats du site (0 = le plus pertinent).
  final int rank;
  final double score;

  /// Ressemblance du titre seul (0 à 1).
  final double similarity;
  final List<String> altTitles;

  bool get isManga => source == 'mangadex';

  String get sourceLabel => switch (source) {
    'mangadex' => 'Scans manga (MangaDex)',
    'gutenberg' => 'Livre libre (Projet Gutenberg)',
    'archive' => 'Livre scanné (Internet Archive)',
    _ => source,
  };

  ReadMatch withScore(double s, {double? similarity}) => ReadMatch(
    source: source,
    id: id,
    title: title,
    author: author,
    coverUrl: coverUrl,
    languages: languages,
    textUrl: textUrl,
    webUrl: webUrl,
    year: year,
    rank: rank,
    score: s,
    similarity: similarity ?? this.similarity,
    altTitles: altTitles,
  );
}

/// Un chapitre de manga.
class ScanChapter {
  const ScanChapter({
    required this.id,
    this.number,
    this.volume,
    this.title = '',
    this.lang = '',
    this.pages = 0,
    this.externalUrl,
  });

  final String id;
  final String? number;
  final String? volume;
  final String title;
  final String lang;
  final int pages;

  /// Chapitre publié sur le site officiel de l'éditeur (MANGA Plus…) : il
  /// s'ouvre là-bas.
  final String? externalUrl;

  double? get num => double.tryParse((number ?? '').replaceAll(',', '.'));
  int? get vol => int.tryParse(volume ?? '');
  bool get readable => externalUrl == null && pages > 0;

  String get label {
    final n = number == null || number!.isEmpty ? 'Chapitre unique' : 'Chapitre $number';
    return title.trim().isEmpty ? n : '$n — ${title.trim()}';
  }

  String get flag => switch (lang) {
    'fr' => '🇫🇷',
    'en' => '🇬🇧',
    _ => lang,
  };
}

/// L'algorithme qui retrouve le manga ou le livre que tu lis et te donne de
/// quoi le lire dans Mon Hub :
///
/// 1. nettoie le titre (« One Piece - Tome 03 : … » → « One Piece », tome 3) ;
/// 2. cherche en même temps sur MangaDex (scans de manga, en français puis en
///    anglais), le Projet Gutenberg (livres libres de droits) et Internet
///    Archive (livres scannés en accès libre) ;
/// 3. note chaque résultat (ressemblance du titre et des autres titres —
///    japonais, anglais… —, auteur, langue française, couverture, place dans
///    le site) et garde le meilleur.
///
/// Que des sources publiques et légales, sans compte : seul le titre cherché
/// part sur internet. Contenus pour adultes exclus.
class ReadFinder {
  ReadFinder([http.Client? client]) : _http = client ?? http.Client();
  final http.Client _http;

  static const _ua = {'accept': 'application/json', 'user-agent': 'MonHub/1.0'};
  static const langs = ['fr', 'en'];

  Future<dynamic> _json(Uri uri) async {
    final r = await _http.get(uri, headers: _ua).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  /// Tous les endroits où lire, du plus probable au moins probable.
  Future<List<ReadMatch>> find(String title, {String author = '', bool manga = true, bool books = true}) async {
    final q = ReadQuery.parse(title);
    if (q.title.isEmpty) return const [];
    final results = await Future.wait([
      if (manga) _mangadex(q.title).catchError((_) => <ReadMatch>[]),
      if (books) _gutenberg(q.title, author).catchError((_) => <ReadMatch>[]),
      if (books) _archive(q.title, author).catchError((_) => <ReadMatch>[]),
    ]);
    final scored = [
      for (final r in results)
        for (final m in r) m.withScore(score(q, author, m), similarity: titleMatch(q, m)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return [for (final m in scored) if (m.score >= 0.45) m];
  }

  /// Assez sûr pour l'ouvrir directement, sans demander « c'est celui-ci ? ».
  static bool confident(List<ReadMatch> list) {
    if (list.isEmpty) return false;
    final best = list.first;
    if (best.similarity < 0.95) return false;
    return list.length == 1 || best.score - list[1].score >= 0.08;
  }

  /// Note de ressemblance entre ce qui est cherché et un résultat.
  static double titleMatch(ReadQuery q, ReadMatch m) {
    var sim = 0.0;
    for (final t in [m.title, ...m.altTitles]) {
      if (t.trim().isEmpty) continue;
      sim = math.max(sim, BookFinder.titleSimilarity(q.title, t));
      if (q.full != q.title) sim = math.max(sim, BookFinder.titleSimilarity(q.full, t) * 0.95);
    }
    return sim;
  }

  static double score(ReadQuery q, String author, ReadMatch m) {
    var s = titleMatch(q, m);
    if (author.trim().isNotEmpty && m.author.isNotEmpty) {
      final a = BookFinder.normalize(author).split(' '), b = BookFinder.normalize(m.author).split(' ');
      s += a.any((w) => w.length > 2 && b.contains(w)) ? 0.1 : -0.1;
    }
    if (m.languages.contains('fr')) s += 0.04;
    if (m.coverUrl != null) s += 0.02;
    s += math.max(0, 10 - m.rank) / 400; // le site le trouve pertinent
    return s;
  }

  // ---- MangaDex (scans) ----

  static const _safe = ['safe', 'suggestive'];

  Future<List<ReadMatch>> _mangadex(String title) async {
    final uri = Uri.https('api.mangadex.org', '/manga', {
      'title': title,
      'limit': '10',
      'includes[]': ['cover_art', 'author'],
      'contentRating[]': _safe,
      'availableTranslatedLanguage[]': langs,
      'order[relevance]': 'desc',
    });
    final j = await _json(uri) as Map;
    final out = <ReadMatch>[];
    var rank = 0;
    for (final d in (j['data'] as List?) ?? const []) {
      if (d is! Map) continue;
      final m = mangaFromJson(d, rank: rank++);
      if (m != null) out.add(m);
    }
    return out;
  }

  static String _pickTitle(Map? titles) {
    if (titles == null || titles.isEmpty) return '';
    for (final k in ['fr', 'en', 'ja-ro', 'ja']) {
      if (titles[k] is String && (titles[k] as String).isNotEmpty) return titles[k] as String;
    }
    return '${titles.values.first}';
  }

  /// Un manga de l'API MangaDex.
  static ReadMatch? mangaFromJson(Map d, {int rank = 0}) {
    final id = '${d['id'] ?? ''}';
    final a = d['attributes'];
    if (id.isEmpty || a is! Map) return null;
    final alt = <String>[];
    for (final t in (a['altTitles'] as List?) ?? const []) {
      if (t is Map) alt.addAll(t.values.whereType<String>());
    }
    final main = a['title'] as Map?;
    if (main != null) alt.addAll(main.values.whereType<String>());
    String? cover;
    final authors = <String>[];
    for (final r in (d['relationships'] as List?) ?? const []) {
      if (r is! Map) continue;
      final ra = r['attributes'];
      if (r['type'] == 'cover_art' && ra is Map && ra['fileName'] is String) {
        cover = 'https://uploads.mangadex.org/covers/$id/${ra['fileName']}.512.jpg';
      }
      if (r['type'] == 'author' && ra is Map && ra['name'] is String) authors.add(ra['name'] as String);
    }
    return ReadMatch(
      source: 'mangadex',
      id: id,
      title: _pickTitle(main).isEmpty ? (alt.firstOrNull ?? '') : _pickTitle(main),
      altTitles: alt,
      author: authors.toSet().take(2).join(', '),
      coverUrl: cover,
      languages: [for (final l in (a['availableTranslatedLanguages'] as List?) ?? const []) '$l'],
      year: (a['year'] as num?)?.toInt(),
      rank: rank,
    );
  }

  /// Tous les chapitres lisibles d'un manga, dans l'ordre, un seul par
  /// numéro (en français si possible, sinon en anglais).
  Future<List<ScanChapter>> chapters(String mangaId) async {
    final all = <ScanChapter>[];
    for (var offset = 0; offset < 5000; offset += 500) {
      final j = await _json(Uri.https('api.mangadex.org', '/manga/$mangaId/feed', {
        'translatedLanguage[]': langs,
        'contentRating[]': _safe,
        'order[volume]': 'asc',
        'order[chapter]': 'asc',
        'includeExternalUrl': '1',
        'limit': '500',
        'offset': '$offset',
      })) as Map;
      final data = (j['data'] as List?) ?? const [];
      for (final d in data) {
        if (d is Map) {
          final c = chapterFromJson(d);
          if (c != null) all.add(c);
        }
      }
      final total = (j['total'] as num?)?.toInt() ?? 0;
      if (data.isEmpty || offset + 500 >= total) break;
    }
    return pickChapters(all);
  }

  static ScanChapter? chapterFromJson(Map d) {
    final a = d['attributes'];
    if (a is! Map || d['id'] == null) return null;
    final ext = a['externalUrl'];
    return ScanChapter(
      id: '${d['id']}',
      number: a['chapter'] as String?,
      volume: a['volume'] as String?,
      title: '${a['title'] ?? ''}',
      lang: '${a['translatedLanguage'] ?? ''}',
      pages: (a['pages'] as num?)?.toInt() ?? 0,
      externalUrl: ext is String && ext.isNotEmpty ? ext : null,
    );
  }

  /// Un chapitre par numéro : lisible dans Mon Hub d'abord, puis en
  /// français, puis celui qui a le plus de pages. Rangés par numéro.
  static List<ScanChapter> pickChapters(List<ScanChapter> all, {List<String> prefer = langs}) {
    final groups = <String, List<ScanChapter>>{};
    for (final c in all) {
      if (!c.readable && c.externalUrl == null) continue;
      final key = c.num != null ? 'n${c.num}' : 'id${c.id}';
      (groups[key] ??= []).add(c);
    }
    int langRank(ScanChapter c) {
      final i = prefer.indexOf(c.lang);
      return i < 0 ? prefer.length : i;
    }

    final out = [
      for (final g in groups.values)
        (g..sort((a, b) {
              if (a.readable != b.readable) return a.readable ? -1 : 1;
              final l = langRank(a).compareTo(langRank(b));
              if (l != 0) return l;
              return b.pages.compareTo(a.pages);
            }))
            .first,
    ];
    out.sort((a, b) {
      final x = a.num ?? -1, y = b.num ?? -1;
      if (x != y) return x.compareTo(y);
      return (a.vol ?? 0).compareTo(b.vol ?? 0);
    });
    return out;
  }

  /// Le chapitre où commencer : celui demandé (« chapitre 12 », « tome 3 »),
  /// sinon le premier.
  static int startIndex(List<ScanChapter> list, ReadQuery q) {
    if (list.isEmpty) return 0;
    if (q.chapter != null) {
      final i = list.indexWhere((c) => c.num != null && c.num! >= q.chapter!);
      if (i >= 0) return i;
    }
    if (q.volume != null) {
      final i = list.indexWhere((c) => c.vol == q.volume);
      if (i >= 0) return i;
      final j = list.indexWhere((c) => (c.vol ?? 0) > q.volume!);
      if (j >= 0) return j;
    }
    return 0;
  }

  /// Les images des pages d'un chapitre (serveurs MangaDex@Home).
  /// [saver] = images plus légères (connexion lente).
  Future<List<String>> pages(String chapterId, {bool saver = false}) async {
    final j = await _json(Uri.https('api.mangadex.org', '/at-home/server/$chapterId')) as Map;
    final base = '${j['baseUrl'] ?? ''}';
    final ch = j['chapter'];
    if (base.isEmpty || ch is! Map) throw 'chapitre introuvable';
    final files = (ch[saver ? 'dataSaver' : 'data'] as List?) ?? const [];
    return [for (final f in files) '$base/${saver ? 'data-saver' : 'data'}/${ch['hash']}/$f'];
  }

  // ---- Projet Gutenberg (livres libres, en texte) ----

  Future<List<ReadMatch>> _gutenberg(String title, String author) async {
    final j = await _json(Uri.https('gutendex.com', '/books/', {
      'search': [title, if (author.trim().isNotEmpty) author.trim()].join(' '),
      'languages': langs.join(','),
    })) as Map;
    final out = <ReadMatch>[];
    var rank = 0;
    for (final d in (j['results'] as List?) ?? const []) {
      if (d is! Map) continue;
      final m = gutenbergFromJson(d, rank: rank++);
      if (m != null) out.add(m);
      if (rank >= 10) break;
    }
    return out;
  }

  static ReadMatch? gutenbergFromJson(Map d, {int rank = 0}) {
    final formats = (d['formats'] as Map?) ?? const {};
    String? text;
    for (final e in formats.entries) {
      final k = '${e.key}';
      if (!k.startsWith('text/plain') || e.value is! String || '${e.value}'.endsWith('.zip')) continue;
      if (text == null || k.contains('utf-8')) text = e.value as String;
    }
    if (text == null) return null;
    String name(Object? a) {
      final n = a is Map ? '${a['name'] ?? ''}' : '';
      // « Hugo, Victor » → « Victor Hugo »
      final p = n.split(', ');
      return p.length == 2 ? '${p[1]} ${p[0]}' : n;
    }

    return ReadMatch(
      source: 'gutenberg',
      id: '${d['id']}',
      title: '${d['title'] ?? ''}',
      author: [for (final a in (d['authors'] as List?) ?? const []) name(a)].take(2).join(', '),
      coverUrl: formats['image/jpeg'] as String?,
      languages: [for (final l in (d['languages'] as List?) ?? const []) '$l'],
      textUrl: text.replaceFirst('http://', 'https://'),
      rank: rank,
    );
  }

  /// Le texte du livre, sans les mentions de licence du début et de la fin.
  Future<String> bookText(String url) async {
    final r = await _http.get(Uri.parse(url), headers: {'user-agent': 'MonHub/1.0'}).timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    return cleanGutenberg(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  static String cleanGutenberg(String raw) {
    var t = raw.replaceAll('\r\n', '\n');
    final start = RegExp(r'\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\n').firstMatch(t);
    if (start != null) t = t.substring(start.end);
    final end = RegExp(r'\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG').firstMatch(t);
    if (end != null) t = t.substring(0, end.start);
    return t.trim();
  }

  /// Découpe le texte en paragraphes (les lignes coupées à 70 caractères sont
  /// recollées).
  static List<String> paragraphs(String text) => [
    for (final p in text.split(RegExp(r'\n\s*\n')))
      if (p.trim().isNotEmpty) p.trim().replaceAll(RegExp(r'[ \t]*\n[ \t]*'), ' ').replaceAll(RegExp(r' {2,}'), ' '),
  ];

  /// Découpe en pages d'environ [chars] caractères, sans couper un
  /// paragraphe (sauf s'il est très long).
  static List<List<String>> paginate(List<String> paras, {int chars = 1600}) {
    final pages = <List<String>>[];
    var cur = <String>[];
    var size = 0;
    void flush() {
      if (cur.isNotEmpty) pages.add(cur);
      cur = [];
      size = 0;
    }

    for (final p in paras) {
      if (p.length > chars * 1.5) {
        flush();
        // Paragraphe géant : coupé aux fins de phrase.
        final parts = p.split(RegExp(r'(?<=[.!?…»])\s+'));
        var buf = StringBuffer();
        for (final s in parts) {
          if (buf.length + s.length > chars && buf.isNotEmpty) {
            pages.add(['$buf'.trim()]);
            buf = StringBuffer();
          }
          buf.write('$s ');
        }
        if (buf.isNotEmpty) pages.add(['$buf'.trim()]);
        continue;
      }
      if (size + p.length > chars && cur.isNotEmpty) flush();
      cur.add(p);
      size += p.length;
    }
    flush();
    return pages;
  }

  // ---- Internet Archive (livres scannés en accès libre) ----

  Future<List<ReadMatch>> _archive(String title, String author) async {
    final j = await _json(Uri.https('openlibrary.org', '/search.json', {
      'title': title,
      if (author.trim().isNotEmpty) 'author': author.trim(),
      'has_fulltext': 'true',
      'limit': '15',
      'fields': 'title,author_name,cover_i,ia,ebook_access,first_publish_year,language',
    })) as Map;
    final out = <ReadMatch>[];
    var rank = 0;
    for (final d in (j['docs'] as List?) ?? const []) {
      if (d is! Map) continue;
      final m = archiveFromJson(d, rank: rank++);
      if (m != null) out.add(m);
    }
    return out;
  }

  /// Seulement les livres en accès **libre** (pas ceux à emprunter).
  static ReadMatch? archiveFromJson(Map d, {int rank = 0}) {
    if (d['ebook_access'] != 'public') return null;
    final ia = (d['ia'] as List?)?.whereType<String>().firstOrNull;
    if (ia == null) return null;
    final lang = [for (final l in (d['language'] as List?) ?? const []) '$l'];
    return ReadMatch(
      source: 'archive',
      id: ia,
      title: '${d['title'] ?? ''}',
      author: ((d['author_name'] as List?) ?? const []).take(2).join(', '),
      coverUrl: d['cover_i'] == null ? null : 'https://covers.openlibrary.org/b/id/${d['cover_i']}-M.jpg',
      languages: [for (final l in lang) l == 'fre' ? 'fr' : l == 'eng' ? 'en' : l],
      webUrl: 'https://archive.org/details/$ia?view=theater',
      year: (d['first_publish_year'] as num?)?.toInt(),
      rank: rank,
    );
  }
}
