import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Un livre trouvé sur internet (Open Library ou Google Livres).
class BookMatch {
  const BookMatch({
    required this.title,
    this.author = '',
    this.coverUrl,
    this.thumbUrl,
    this.pages,
    this.year,
    this.source = '',
    this.popularity = 0,
    this.score = 0,
  });

  final String title;
  final String author;

  /// Couverture en grand (pour la bibliothèque).
  final String? coverUrl;

  /// Couverture en petit (listes).
  final String? thumbUrl;
  final int? pages;
  final int? year;
  final String source;

  /// Nombre d'éditions / de notes : aide à départager deux livres du même nom.
  final int popularity;

  BookMatch withScore(double s) => BookMatch(
    title: title,
    author: author,
    coverUrl: coverUrl,
    thumbUrl: thumbUrl,
    pages: pages,
    year: year,
    source: source,
    popularity: popularity,
    score: s,
  );

  /// Note de ressemblance avec ce qui a été cherché.
  final double score;
}

/// Retrouve tout seul le livre dont tu parles à partir de son titre (et de
/// l'auteur si tu le donnes) : cherche sur Open Library **et** Google Livres
/// (bien meilleur pour les éditions françaises), note chaque résultat
/// (ressemblance du titre, de l'auteur, présence d'une couverture,
/// popularité) et garde le meilleur.
///
/// Sans clé ni compte : ce sont des API publiques ; seul le titre cherché
/// part sur internet.
class BookFinder {
  BookFinder([http.Client? client]) : _http = client ?? http.Client();
  final http.Client _http;

  /// Le livre le plus probable (null si rien de convaincant).
  Future<BookMatch?> find(String title, {String author = ''}) async {
    final list = await candidates(title, author: author);
    if (list.isEmpty) return null;
    final best = list.first;
    return best.score >= 0.55 ? best : null;
  }

  /// Tous les résultats, du plus probable au moins probable.
  Future<List<BookMatch>> candidates(String title, {String author = '', int max = 12}) async {
    final t = title.trim();
    if (t.isEmpty) return const [];
    final results = await Future.wait([
      _openLibrary(t, author).catchError((_) => <BookMatch>[]),
      _google(t, author, french: true).catchError((_) => <BookMatch>[]),
      _google(t, author, french: false).catchError((_) => <BookMatch>[]),
    ]);
    final all = [for (final r in results) ...r];
    final scored = [for (final m in all) m.withScore(score(t, author, m))]
      ..sort((a, b) => b.score.compareTo(a.score));
    // Un seul exemplaire par livre (même titre + auteur), en gardant la
    // meilleure couverture.
    final seen = <String>{};
    final out = <BookMatch>[];
    for (final m in scored) {
      final key = '${normalize(m.title)}|${normalize(m.author).split(' ').lastOrNull ?? ''}';
      if (!seen.add(key)) continue;
      out.add(m);
      if (out.length >= max) break;
    }
    return out;
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final r = await _http.get(uri, headers: {'accept': 'application/json'}).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    String text;
    try {
      text = utf8.decode(r.bodyBytes);
    } on FormatException {
      text = latin1.decode(r.bodyBytes);
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<List<BookMatch>> _openLibrary(String title, String author) async {
    final j = await _json(
      Uri.https('openlibrary.org', '/search.json', {
        'title': title,
        if (author.trim().isNotEmpty) 'author': author.trim(),
        'limit': '10',
        'fields': 'title,author_name,cover_i,number_of_pages_median,first_publish_year,edition_count',
      }),
    );
    return [
      for (final d in (j['docs'] as List?) ?? const [])
        if (d is Map)
          BookMatch(
            title: '${d['title'] ?? ''}',
            author: ((d['author_name'] as List?) ?? const []).take(2).join(', '),
            coverUrl: d['cover_i'] == null ? null : 'https://covers.openlibrary.org/b/id/${d['cover_i']}-L.jpg?default=false',
            thumbUrl: d['cover_i'] == null ? null : 'https://covers.openlibrary.org/b/id/${d['cover_i']}-M.jpg?default=false',
            pages: (d['number_of_pages_median'] as num?)?.toInt(),
            year: (d['first_publish_year'] as num?)?.toInt(),
            source: 'Open Library',
            popularity: (d['edition_count'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Future<List<BookMatch>> _google(String title, String author, {required bool french}) async {
    final q = [
      'intitle:$title',
      if (author.trim().isNotEmpty) 'inauthor:${author.trim()}',
    ].join(' ');
    final j = await _json(
      Uri.https('www.googleapis.com', '/books/v1/volumes', {
        'q': q,
        'maxResults': '10',
        'printType': 'books',
        if (french) 'langRestrict': 'fr',
      }),
    );
    return [
      for (final it in (j['items'] as List?) ?? const [])
        if (it is Map && it['volumeInfo'] is Map) _fromGoogle(it['volumeInfo'] as Map),
    ];
  }

  static BookMatch _fromGoogle(Map v) {
    final links = v['imageLinks'] as Map?;
    String? img(Object? u) {
      if (u is! String || u.isEmpty) return null;
      return u.replaceFirst('http://', 'https://').replaceAll('&edge=curl', '');
    }

    final thumb = img(links?['thumbnail'] ?? links?['smallThumbnail']);
    final big = img(links?['large'] ?? links?['medium'] ?? links?['small']) ?? thumb;
    final sub = '${v['subtitle'] ?? ''}'.trim();
    return BookMatch(
      title: '${v['title'] ?? ''}${sub.isEmpty ? '' : ' : $sub'}',
      author: ((v['authors'] as List?) ?? const []).take(2).join(', '),
      coverUrl: big,
      thumbUrl: thumb,
      pages: (v['pageCount'] as num?)?.toInt(),
      year: int.tryParse('${v['publishedDate'] ?? ''}'.split('-').first),
      source: 'Google Livres',
      popularity: (v['ratingsCount'] as num?)?.toInt() ?? 0,
    );
  }

  // ---- Note de ressemblance ----

  static const _stop = {
    'le', 'la', 'les', 'l', 'un', 'une', 'des', 'de', 'du', 'd', 'et', 'a', 'au', 'aux', 'en',
    'the', 'an', 'of', 'and', 'tome', 'volume', 'vol', 't',
  };

  /// Minuscules, sans accents ni ponctuation.
  static String normalize(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return '$b'.replaceAll(RegExp(r"[^a-z0-9]+"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _words(String s) => [for (final w in normalize(s).split(' ')) if (w.isNotEmpty && !_stop.contains(w)) w];

  /// Ressemblance de deux titres (0 à 1) : mots en commun, en tolérant une
  /// faute de frappe et un sous-titre en plus.
  static double titleSimilarity(String query, String candidate) {
    final nq = normalize(query), nc = normalize(candidate);
    if (nq.isEmpty || nc.isEmpty) return 0;
    if (nq == nc) return 1;
    final main = normalize(candidate.split(RegExp(r'\s[:\-–(]\s?|\s?[:(]')).first);
    if (main == nq) return 0.97;
    final q = _words(query), c = _words(candidate);
    if (q.isEmpty || c.isEmpty) return nc.contains(nq) ? 0.8 : 0;
    var hits = 0.0;
    for (final w in q) {
      if (c.contains(w)) {
        hits += 1;
      } else if (w.length > 3 && c.any((x) => x.length > 3 && _close(w, x))) {
        hits += 0.8;
      }
    }
    final recall = hits / q.length;
    final precision = hits / c.length;
    // Le titre cherché en entier compte plus que les mots en trop (sous-titre).
    return (0.75 * recall + 0.25 * precision).clamp(0.0, 1.0);
  }

  /// Une faute de frappe au plus (distance d'édition ≤ 1, ou 2 pour les longs mots).
  static bool _close(String a, String b) {
    if ((a.length - b.length).abs() > 2) return false;
    final max = a.length > 7 ? 2 : 1;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = [i, ...List.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce(math.min);
      }
      prev = cur;
    }
    return prev[b.length] <= max;
  }

  static double score(String title, String author, BookMatch m) {
    var s = titleSimilarity(title, m.title);
    if (author.trim().isNotEmpty) {
      final a = _words(author), b = _words(m.author);
      final common = a.where(b.contains).length;
      s += common > 0 ? 0.15 : (b.isEmpty ? 0 : -0.25);
    }
    if (m.coverUrl != null) s += 0.12;
    if (m.source == 'Open Library' && m.coverUrl != null) s += 0.03; // grandes couvertures
    s += math.min(0.08, math.log(1 + m.popularity) / 60);
    return s;
  }
}
