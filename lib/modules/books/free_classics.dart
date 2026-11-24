import 'book_finder.dart';
import 'read_finder.dart';

/// Classiques **libres en France** (auteur mort depuis plus de 70 ans) mais
/// absents du Projet Gutenberg américain, où ils sont encore protégés.
///
/// Exemple : George Orwell est mort en 1950, ses livres sont dans le domaine
/// public en France depuis le 1er janvier 2021. Le Projet Gutenberg
/// Australie les publie (texte original anglais). Les traductions françaises,
/// elles, sont encore protégées : pas de version française gratuite légale
/// pour l'instant (la médiathèque en prête).
class FreeClassics {
  FreeClassics._();

  static const _au = 'https://gutenberg.net.au/ebooks01';

  /// Le catalogue (texte brut lu dans le lecteur de Mon Hub).
  static const all = <({String id, String title, String author, List<String> alt, String url, int year})>[
    (
      id: '0100021',
      title: 'Nineteen Eighty-Four',
      author: 'George Orwell',
      alt: ['1984', 'Mil neuf cent quatre-vingt-quatre', 'Nineteen Eighty Four', '1984 Orwell'],
      url: '$_au/0100021.txt',
      year: 1949,
    ),
    (
      id: '0100011',
      title: 'Animal Farm',
      author: 'George Orwell',
      alt: ['La Ferme des animaux', 'La ferme des animaux', 'Animal Farm: A Fairy Story'],
      url: '$_au/0100011.txt',
      year: 1945,
    ),
  ];

  /// Les classiques qui ressemblent à ce qui est cherché.
  static List<ReadMatch> match(String title, {String author = ''}) {
    final q = ReadQuery.parse(title);
    final out = <ReadMatch>[];
    for (final c in all) {
      var best = 0.0;
      for (final t in [c.title, ...c.alt]) {
        final s = BookFinder.titleSimilarity(q.title, t);
        if (s > best) best = s;
      }
      // « 1984 » tout court : seulement s'il n'y a pas d'autre auteur demandé.
      final a = BookFinder.normalize(author);
      if (a.isNotEmpty && !BookFinder.normalize(c.author).split(' ').any((w) => w.length > 2 && a.contains(w))) {
        best -= 0.3;
      }
      if (best < 0.8) continue;
      out.add(
        ReadMatch(
          source: 'gutenberg-au',
          id: c.id,
          title: c.title,
          author: c.author,
          languages: const ['en'],
          textUrl: c.url,
          webUrl: c.url.replaceFirst('.txt', 'h.html'),
          year: c.year,
          altTitles: c.alt,
        ),
      );
    }
    return out;
  }

  /// Enlève l'en-tête et la licence du Projet Gutenberg Australie.
  static String clean(String raw) {
    var t = raw.replaceAll('\r\n', '\n');
    // L'en-tête se termine par une ligne de tirets.
    final head = RegExp(r'\n-{20,}\s*\n').firstMatch(t);
    if (head != null && head.start < 4000) t = t.substring(head.end);
    // La licence commence après « THE END » ou par le texte de licence.
    final end = RegExp(
      r'\n\s*(THE END|-{20,}\s*\n\s*This eBook|Project Gutenberg of Australia License)',
      caseSensitive: false,
    ).allMatches(t).lastOrNull;
    if (end != null && end.start > t.length * 0.8) t = t.substring(0, end.start);
    return t.trim();
  }
}

/// Wikisource en français : des milliers de classiques libres (Hugo, Zola,
/// Maupassant, Molière, Verne…), en texte, par l'API publique de Wikimedia.
class Wikisource {
  Wikisource._();

  /// Recherche (titres d'œuvres seulement, pas les sous-pages).
  static Uri search(String title, {String author = ''}) => Uri.https('fr.wikisource.org', '/w/api.php', {
    'action': 'query',
    'list': 'search',
    'srsearch': [title, if (author.trim().isNotEmpty) author.trim()].join(' '),
    'srnamespace': '0',
    'srlimit': '10',
    'format': 'json',
  });

  /// Le texte complet d'une œuvre (assemblé par l'outil d'export de
  /// Wikisource).
  static String textUrl(String page) =>
      Uri.https('ws-export.wmcloud.org', '/', {'format': 'txt', 'lang': 'fr', 'page': page}).toString();

  static String webUrl(String page) =>
      'https://fr.wikisource.org/wiki/${Uri.encodeComponent(page.replaceAll(' ', '_'))}';

  /// Lit la réponse de la recherche.
  static List<ReadMatch> fromSearch(Map j) {
    final out = <ReadMatch>[];
    var rank = 0;
    for (final r in ((j['query'] as Map?)?['search'] as List?) ?? const []) {
      if (r is! Map) continue;
      final page = '${r['title'] ?? ''}'.trim();
      // Sous-pages (« Germinal/Partie 1 ») et pages d'auteur : ignorées.
      if (page.isEmpty || page.contains('/') || page.startsWith('Auteur:') || page.startsWith('Livre:')) continue;
      // « Germinal (Zola) » → titre « Germinal », auteur « Zola ».
      final m = RegExp(r'^(.*?)\s*\(([^)]*)\)$').firstMatch(page);
      out.add(
        ReadMatch(
          source: 'wikisource',
          id: page,
          title: m?.group(1) ?? page,
          author: m?.group(2) ?? '',
          languages: const ['fr'],
          textUrl: textUrl(page),
          webUrl: webUrl(page),
          rank: rank++,
        ),
      );
      if (rank >= 8) break;
    }
    return out;
  }
}
