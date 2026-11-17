import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import '../../ui/widgets.dart';
import 'book_finder.dart';

enum BookStatus {
  read('Lu', Icons.check_circle_rounded, Color(0xFF2EAD6B)),
  reading('En cours', Icons.auto_stories_rounded, Color(0xFFF29D38)),
  toRead('À lire', Icons.bookmark_rounded, Color(0xFF5B8DEF));

  const BookStatus(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

class Book {
  Book({
    required this.id,
    required this.title,
    this.author = '',
    this.coverUrl,
    this.coverPath,
    this.status = BookStatus.read,
    DateTime? addedOn,
    this.finishedOn,
    this.rating = 0,
    this.takeaway = '',
    this.pages,
  }) : addedOn = addedOn ?? DateTime.now();

  final String id;
  String title;
  String author;
  String? coverUrl;

  /// Couverture enregistrée sur l'appareil (s'affiche toujours, même hors
  /// ligne ou quand le site des couvertures est lent).
  String? coverPath;
  BookStatus status;
  DateTime addedOn;
  DateTime? finishedOn;
  int rating; // 0 à 5
  /// Ce que tu veux retenir du livre.
  String takeaway;
  int? pages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'coverPath': coverPath,
        'status': status.name,
        'addedOn': addedOn.toIso8601String(),
        'finishedOn': finishedOn?.toIso8601String(),
        'rating': rating,
        'takeaway': takeaway,
        'pages': pages,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        title: j['title'] as String,
        author: j['author'] as String? ?? '',
        coverUrl: j['coverUrl'] as String?,
        coverPath: j['coverPath'] as String?,
        status: BookStatus.values.asNameMap()[j['status']] ?? BookStatus.read,
        addedOn: DateTime.tryParse(j['addedOn'] as String? ?? '') ??
            DateTime.tryParse(j['finishedOn'] as String? ?? ''),
        finishedOn: DateTime.tryParse(j['finishedOn'] as String? ?? ''),
        rating: j['rating'] as int? ?? 0,
        // Compatibilité avec l'ancien champ « notes ».
        takeaway: j['takeaway'] as String? ?? j['notes'] as String? ?? '',
        pages: j['pages'] as int?,
      );
}

/// Bibliothèque : tous tes livres (lus, en cours, à lire), avec couvertures,
/// étoiles et ce que tu veux en retenir. Recherche via Open Library.
class BooksModule extends HubModule {
  @override
  String get id => 'books';
  @override
  String get name => 'Bibliothèque';
  @override
  String get description => 'Tes livres lus, en cours et à lire';
  @override
  IconData get icon => Icons.menu_book_rounded;
  @override
  Color get color => const Color(0xFFB7793F);
  @override
  ApiAccess get access => ApiAccess.local;

  List<Book> get books {
    final raw = store.getJson<List<dynamic>>('books') ?? const [];
    final list = raw.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
    list.sort((a, b) => (b.finishedOn ?? b.addedOn).compareTo(a.finishedOn ?? a.addedOn));
    return list;
  }

  Future<void> save(List<Book> list) =>
      store.setJson('books', list.map((b) => b.toJson()).toList());

  Future<void> upsert(Book b) {
    final list = books;
    final i = list.indexWhere((x) => x.id == b.id);
    i < 0 ? list.add(b) : list[i] = b;
    return save(list);
  }

  Future<void> remove(Book b) => save(books..removeWhere((x) => x.id == b.id));

  final finder = BookFinder();

  /// Retrouve le livre à partir de son titre et complète ce qui manque
  /// (couverture, auteur, pages). Renvoie true si quelque chose a changé.
  Future<bool> complete(Book b, {bool force = false}) async {
    final list = await finder.candidates(b.title, author: b.author);
    final good = [for (final m in list) if (m.score >= 0.55) m];
    if (good.isEmpty) return false;
    final best = good.first;
    var changed = false;
    if (b.author.trim().isEmpty && best.author.isNotEmpty) {
      b.author = best.author;
      changed = true;
    }
    if (b.pages == null && best.pages != null) {
      b.pages = best.pages;
      changed = true;
    }
    if (force || b.coverPath == null) {
      // Essaie les couvertures dans l'ordre jusqu'à en avoir une vraie,
      // enregistrée sur l'appareil.
      for (final m in good.where((m) => m.coverUrl != null).take(6)) {
        final path = await saveCover(b.id, m.coverUrl!);
        if (path != null) {
          b.coverUrl = m.coverUrl;
          b.coverPath = path;
          changed = true;
          break;
        }
      }
    }
    if (changed) await upsert(b);
    return changed;
  }

  /// Télécharge une couverture et la garde sur l'appareil. Renvoie son
  /// chemin, ou null si ce n'est pas une vraie image de couverture.
  Future<String?> saveCover(String bookId, String url) async {
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
      final b = r.bodyBytes;
      if (r.statusCode != 200 || b.length < 2500) return null;
      final jpeg = b[0] == 0xFF && b[1] == 0xD8;
      final png = b[0] == 0x89 && b[1] == 0x50;
      final webp = b.length > 12 && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';
      if (!jpeg && !png && !webp) return null;
      final dir = await HubFiles.dir();
      if (dir == null) return null;
      final folder = Directory('${dir.path}${Platform.pathSeparator}couvertures');
      await folder.create(recursive: true);
      final f = File('${folder.path}${Platform.pathSeparator}$bookId.${png ? 'png' : webp ? 'webp' : 'jpg'}');
      await f.writeAsBytes(b, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Après un ajout ou un changement de couverture : la garde sur
  /// l'appareil (ou en cherche une autre si le lien ne marche pas).
  Future<void> ensureCover(Book b) async {
    if (b.coverPath != null && await File(b.coverPath!).exists()) return;
    if (b.coverUrl != null) {
      final path = await saveCover(b.id, b.coverUrl!);
      if (path != null) {
        b.coverPath = path;
        await upsert(b);
        return;
      }
    }
    await complete(b, force: true);
  }

  bool _filling = false;

  /// Livres dont la couverture n'est pas encore sur l'appareil : on la
  /// télécharge (ou on retrouve le livre), en arrière-plan.
  Future<void> fillMissingCovers() async {
    if (_filling) return;
    _filling = true;
    try {
      final tried = {...(store.getJson<List<dynamic>>('coverTried2') ?? const []).cast<String>()};
      for (final b in books.where((b) => !tried.contains(b.id))) {
        if (b.coverPath != null && await File(b.coverPath!).exists()) continue;
        try {
          await ensureCover(b);
        } catch (_) {}
        tried.add(b.id);
        await store.setJson('coverTried2', tried.toList());
      }
    } finally {
      _filling = false;
    }
  }

  @override
  List<HubTool> get tools => [
        HubTool(
          name: 'livres_lister',
          description: 'Tous les livres de la bibliothèque (statut, note, à retenir).',
          run: (_) async => [
            for (final b in books)
              {
                'titre': b.title,
                'auteur': b.author,
                'statut': b.status.label,
                if (b.rating > 0) 'etoiles': b.rating,
                if (b.takeaway.isNotEmpty) 'a_retenir': b.takeaway,
              },
          ],
        ),
        HubTool(
          name: 'livre_ajouter',
          description: 'Ajoute un livre (ou met à jour s\'il a le même titre).',
          params: {
            'titre': ('string', 'Titre'),
            'auteur': ('string', 'Auteur'),
            'statut': ('string', 'lu, en_cours ou a_lire'),
            'etoiles': ('integer', 'Note de 0 à 5'),
            'a_retenir': ('string', 'Ce qu\'il faut retenir du livre'),
          },
          required: ['titre'],
          run: (a) async {
            final title = (a['titre'] as String).trim();
            final b = books.where((x) => x.title.toLowerCase() == title.toLowerCase()).firstOrNull ??
                Book(id: '${DateTime.now().microsecondsSinceEpoch}', title: title);
            if (a['auteur'] is String) b.author = a['auteur'] as String;
            b.status = switch ('${a['statut'] ?? ''}') {
              'en_cours' => BookStatus.reading,
              'a_lire' => BookStatus.toRead,
              'lu' => BookStatus.read,
              _ => b.status,
            };
            if (a['etoiles'] is num) b.rating = (a['etoiles'] as num).toInt().clamp(0, 5);
            if (a['a_retenir'] is String) b.takeaway = a['a_retenir'] as String;
            await upsert(b);
            // Retrouve le livre tout seul : couverture, auteur, pages.
            try {
              if (b.coverUrl == null) await complete(b);
              await ensureCover(b);
            } catch (_) {}
            store.changed();
            return {
              'ok': true,
              'titre': b.title,
              if (b.author.isNotEmpty) 'auteur': b.author,
              'couverture': b.coverUrl != null,
            };
          },
        ),
      ];

  bool _autoCovers = false;

  @override
  Widget buildSummary(BuildContext context) {
    if (!_autoCovers) {
      _autoCovers = true;
      unawaited(fillMissingCovers());
    }
    return _summary(context);
  }

  Widget _summary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final all = books;
          if (all.isEmpty) {
            return EmptyHint('Ta bibliothèque est vide',
                icon: Icons.auto_stories_rounded,
                action: ('Ajouter un livre', () => addBook(context, this)));
          }
          final reading = all.where((b) => b.status == BookStatus.reading).toList();
          final shown = [...reading, ...all.where((b) => b.status != BookStatus.reading)];
          final read = all.where((b) => b.status == BookStatus.read).length;
          final toRead = all.where((b) => b.status == BookStatus.toRead).length;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$read lus · ${reading.length} en cours · $toRead à lire',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shown.length.clamp(0, 12),
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => AspectRatio(
                      aspectRatio: 0.66,
                      child: BookCover(book: shown[i], showStatus: true),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );

  @override
  Widget buildPage(BuildContext context) => _LibraryPage(module: this);
}

// ---------------------------------------------------------------------------
// Couverture
// ---------------------------------------------------------------------------

class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book, this.showStatus = false, this.radius = 10});

  final Book book;
  final bool showStatus;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final hue = (book.title.hashCode % 360).abs().toDouble();
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            HSLColor.fromAHSL(1, hue, 0.45, 0.42).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.28).toColor(),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(book.title,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13, height: 1.15)),
          const Spacer(),
          Text(book.author,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 10)),
        ],
      ),
    );
    // Toujours au format d'un livre (2:3), centré dans la place donnée.
    return Center(
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: _frame(fallback),
      ),
    );
  }

  /// La couverture : le fichier gardé sur l'appareil, sinon le lien.
  Widget _image(Widget fallback) {
    Widget net() => book.coverUrl == null
        ? fallback
        : Image.network(book.coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
    final path = book.coverPath;
    if (path != null && !kIsWeb) {
      return Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, _, _) => net());
    }
    return net();
  }

  Widget _frame(Widget fallback) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _image(fallback),
            // Reflet « reliure » à gauche.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 6,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.black.withValues(alpha: 0.25),
                    Colors.white.withValues(alpha: 0.08),
                  ]),
                ),
              ),
            ),
            if (showStatus && book.status != BookStatus.read)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: book.status.color, shape: BoxShape.circle),
                  child: Icon(book.status.icon, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.value, this.onChanged, this.size = 16});
  final int value;
  final ValueChanged<int>? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            GestureDetector(
              onTap: onChanged == null ? null : () => onChanged!(i == value ? 0 : i),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: onChanged == null ? 0 : 3),
                child: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: size, color: const Color(0xFFFFB400)),
              ),
            ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Page bibliothèque
// ---------------------------------------------------------------------------

class _LibraryPage extends StatefulWidget {
  const _LibraryPage({required this.module});
  final BooksModule module;

  @override
  State<_LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<_LibraryPage> {
  BookStatus? filter;
  String query = '';
  String sort = 'date';

  @override
  void initState() {
    super.initState();
    widget.module.fillMissingCovers();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ma bibliothèque'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Trier',
            icon: const Icon(Icons.sort_rounded),
            initialValue: sort,
            onSelected: (v) => setState(() => sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'date', child: Text('Plus récents')),
              PopupMenuItem(value: 'rating', child: Text('Mieux notés')),
              PopupMenuItem(value: 'title', child: Text('Titre (A → Z)')),
              PopupMenuItem(value: 'author', child: Text('Auteur')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => addBook(context, m),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Ajouter un livre'),
      ),
      body: ListenableBuilder(
        listenable: m.store,
        builder: (context, _) {
          final all = m.books;
          final q = query.toLowerCase();
          final list = all
              .where((b) => filter == null || b.status == filter)
              .where((b) =>
                  q.isEmpty ||
                  b.title.toLowerCase().contains(q) ||
                  b.author.toLowerCase().contains(q))
              .toList();
          switch (sort) {
            case 'rating':
              list.sort((a, b) => b.rating.compareTo(a.rating));
            case 'title':
              list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
            case 'author':
              list.sort((a, b) => a.author.toLowerCase().compareTo(b.author.toLowerCase()));
          }
          int count(BookStatus s) => all.where((b) => b.status == s).length;
          final year = DateTime.now().year;
          final thisYear = all
              .where((b) => b.status == BookStatus.read && b.finishedOn?.year == year)
              .length;

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(children: [
                    _Stat(value: '${count(BookStatus.read)}', label: 'lus', color: BookStatus.read.color),
                    _Stat(value: '$thisYear', label: 'en $year', color: m.color),
                    _Stat(value: '${count(BookStatus.reading)}', label: 'en cours', color: BookStatus.reading.color),
                    _Stat(value: '${count(BookStatus.toRead)}', label: 'à lire', color: BookStatus.toRead.color),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Chercher un titre ou un auteur'),
                    onChanged: (v) => setState(() => query = v),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    _FilterChip(
                        label: 'Tous (${all.length})',
                        selected: filter == null,
                        onTap: () => setState(() => filter = null)),
                    for (final s in BookStatus.values)
                      _FilterChip(
                        label: '${s.label} (${count(s)})',
                        icon: s.icon,
                        color: s.color,
                        selected: filter == s,
                        onTap: () => setState(() => filter = s),
                      ),
                  ]),
                ),
              ),
              if (list.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyHint('Aucun livre ici pour l\'instant',
                      icon: Icons.auto_stories_rounded),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      childAspectRatio: 0.5,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final b = list[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => BookDetailPage(module: m, book: b)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Hero(
                                tag: 'cover-${b.id}',
                                child: BookCover(book: b, showStatus: true),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(b.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700, height: 1.2)),
                            Text(b.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                            const SizedBox(height: 2),
                            if (b.status == BookStatus.read)
                              StarRating(value: b.rating, size: 14)
                            else
                              Text(b.status.label,
                                  style: TextStyle(
                                      color: b.status.color,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: color)),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ]),
        ),
      );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          avatar: icon == null ? null : Icon(icon, size: 16, color: color),
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => onTap(),
        ),
      );
}

// ---------------------------------------------------------------------------
// Fiche d'un livre
// ---------------------------------------------------------------------------

class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.module, required this.book});
  final BooksModule module;
  final Book book;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late final Book b = widget.book;
  late final takeaway = TextEditingController(text: b.takeaway);

  Future<void> _save() => widget.module.upsert(b);

  void _setStatus(BookStatus s) {
    setState(() {
      b.status = s;
      if (s == BookStatus.read) b.finishedOn ??= DateTime.now();
      if (s != BookStatus.read) b.finishedOn = null;
    });
    _save();
  }

  @override
  void dispose() {
    if (takeaway.text != b.takeaway) {
      b.takeaway = takeaway.text;
      _save();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Modifier',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () async {
              final r = await askFields(context,
                  title: 'Modifier',
                  labels: ['Titre', 'Auteur', 'Lien de la couverture (facultatif)'],
                  initial: [b.title, b.author, b.coverUrl ?? '']);
              if (r == null || r[0].isEmpty) return;
              setState(() {
                b.title = r[0];
                b.author = r[1];
                final url = r[2].isEmpty ? null : r[2];
                if (url != b.coverUrl) b.coverPath = null;
                b.coverUrl = url;
              });
              await _save();
              unawaited(widget.module.ensureCover(b).then((_) {
                if (mounted) setState(() {});
              }));
            },
          ),
          IconButton(
            tooltip: 'Trouver la couverture',
            icon: const Icon(Icons.image_search_rounded),
            onPressed: () async {
              final x = await pickCover(context, widget.module, b);
              if (x == null) return;
              final path = await widget.module.saveCover(b.id, x.coverUrl!);
              setState(() {
                b.coverUrl = x.coverUrl;
                b.coverPath = path;
                if (b.author.trim().isEmpty) b.author = x.author;
                b.pages ??= x.pages;
              });
              _save();
            },
          ),
          IconButton(
            tooltip: 'Supprimer',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('Supprimer « ${b.title} » ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Supprimer')),
                  ],
                ),
              );
              if (ok != true) return;
              await widget.module.remove(b);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // En-tête : couverture sur fond flouté.
          SizedBox(
            height: 380,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (b.coverUrl != null)
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: b.coverPath != null
                        ? Image.file(File(b.coverPath!), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox())
                        : Image.network(b.coverUrl!,
                        fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                  )
                else
                  Container(color: widget.module.color.withValues(alpha: 0.4)),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        theme.colorScheme.surface.withValues(alpha: 0.2),
                        theme.colorScheme.surface,
                      ],
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 60, bottom: 20),
                    child: AspectRatio(
                      aspectRatio: 0.66,
                      child: Hero(tag: 'cover-${b.id}', child: BookCover(book: b, radius: 14)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(b.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    if (b.author.isNotEmpty)
                      Text(b.author,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 20),
                    SegmentedButton<BookStatus>(
                      segments: [
                        for (final s in BookStatus.values)
                          ButtonSegment(value: s, label: Text(s.label), icon: Icon(s.icon)),
                      ],
                      selected: {b.status},
                      onSelectionChanged: (v) => _setStatus(v.first),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: StarRating(
                        value: b.rating,
                        size: 36,
                        onChanged: (v) {
                          setState(() => b.rating = v);
                          _save();
                        },
                      ),
                    ),
                    if (b.status == BookStatus.read)
                      TextButton.icon(
                        icon: const Icon(Icons.event_rounded),
                        label: Text(b.finishedOn == null
                            ? 'Date de fin de lecture'
                            : 'Fini le ${b.finishedOn!.day} ${frMonths[b.finishedOn!.month - 1]} ${b.finishedOn!.year}'),
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: b.finishedOn ?? DateTime.now(),
                            firstDate: DateTime(1990),
                            lastDate: DateTime.now().add(const Duration(days: 1)),
                          );
                          if (d == null) return;
                          setState(() => b.finishedOn = d);
                          _save();
                        },
                      ),
                    const SizedBox(height: 16),
                    Row(children: [
                      Icon(Icons.lightbulb_rounded, color: widget.module.color),
                      const SizedBox(width: 8),
                      Text('À retenir',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 8),
                    TextField(
                      controller: takeaway,
                      minLines: 4,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        hintText: 'Les idées, citations ou passages que tu veux garder…',
                      ),
                      onChanged: (v) => b.takeaway = v,
                      onEditingComplete: _save,
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ajout d'un livre (recherche Open Library)
// ---------------------------------------------------------------------------

Future<void> addBook(BuildContext context, BooksModule m) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddBookSheet(module: m),
    );

class _AddBookSheet extends StatefulWidget {
  const _AddBookSheet({required this.module});
  final BooksModule module;

  @override
  State<_AddBookSheet> createState() => _AddBookSheetState();
}

class _AddBookSheetState extends State<_AddBookSheet> {
  final q = TextEditingController();
  List<BookMatch> results = [];
  bool loading = false;
  BookStatus status = BookStatus.read;
  String? error;
  Timer? _debounce;
  int _searchId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    q.dispose();
    super.dispose();
  }

  /// Cherche pendant que tu écris (le meilleur résultat en premier).
  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 550), _search);
  }

  Future<void> _search() async {
    final text = q.text.trim();
    if (text.length < 2) return setState(() => results = []);
    final id = ++_searchId;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await widget.module.finder.candidates(text);
      if (id == _searchId && mounted) setState(() => results = r);
    } catch (e) {
      if (mounted) setState(() => error = 'Recherche impossible : $e');
    } finally {
      if (id == _searchId && mounted) setState(() => loading = false);
    }
  }

  Future<void> _add(Book b, {bool find = false}) async {
    await widget.module.upsert(b);
    // La couverture est gardée sur l'appareil (ajouté à la main : on
    // retrouve d'abord le livre tout seul).
    unawaited(() async {
      try {
        if (find) await widget.module.complete(b);
        await widget.module.ensureCover(b);
      } catch (_) {}
    }());
    if (!mounted) return;
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => BookDetailPage(module: widget.module, book: b)));
  }

  Book _fromMatch(BookMatch r) => Book(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    title: r.title,
    author: r.author,
    coverUrl: r.coverUrl,
    pages: r.pages,
    status: status,
    finishedOn: status == BookStatus.read ? DateTime.now() : null,
  );

  @override
  Widget build(BuildContext context) {
    final best = results.isNotEmpty && results.first.score >= 0.55 ? results.first : null;
    final rest = best == null ? results : results.skip(1).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  TextField(
                    controller: q,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                    onSubmitted: (_) {
                      _debounce?.cancel();
                      _search();
                    },
                    decoration: InputDecoration(
                      hintText: 'Le titre du livre (et l\'auteur si tu veux)…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: loading
                          ? const Padding(padding: EdgeInsets.all(14), child: LoadingHint())
                          : IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _search),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<BookStatus>(
                    segments: [
                      for (final s in BookStatus.values)
                        ButtonSegment(value: s, label: Text(s.label), icon: Icon(s.icon)),
                    ],
                    selected: {status},
                    onSelectionChanged: (v) => setState(() => status = v.first),
                  ),
                ],
              ),
            ),
            if (error != null) ErrorBanner(error!),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  if (best != null)
                    Card(
                      margin: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _add(_fromMatch(best)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 90,
                                height: 135,
                                child: BookCover(book: Book(id: '', title: best.title, author: best.author, coverUrl: best.coverUrl)),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('C\'est celui-ci ?', style: Theme.of(context).textTheme.labelMedium),
                                    const SizedBox(height: 4),
                                    Text(
                                      best.title,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                                    ),
                                    if (best.author.isNotEmpty) Text(best.author),
                                    Text(
                                      [
                                        if (best.year != null) '${best.year}',
                                        if (best.pages != null) '${best.pages} pages',
                                      ].join(' · '),
                                      style: Theme.of(context).textTheme.labelSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    FilledButton.icon(
                                      icon: const Icon(Icons.add_rounded),
                                      label: const Text('Ajouter'),
                                      onPressed: () => _add(_fromMatch(best)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  for (final r in rest)
                    ListTile(
                      leading: SizedBox(
                        width: 40,
                        height: 60,
                        child: BookCover(radius: 4, book: Book(id: '', title: r.title, coverUrl: r.thumbUrl ?? r.coverUrl)),
                      ),
                      title: Text(r.title),
                      subtitle: Text([if (r.author.isNotEmpty) r.author, if (r.year != null) '${r.year}'].join(' · ')),
                      trailing: const Icon(Icons.add_circle_outline_rounded),
                      onTap: () => _add(_fromMatch(r)),
                    ),
                  if (q.text.isNotEmpty && !loading)
                    ListTile(
                      leading: const Icon(Icons.edit_note_rounded),
                      title: Text('Ajouter « ${q.text} » à la main'),
                      subtitle: const Text('Je chercherai quand même sa couverture.'),
                      onTap: () => _add(
                        Book(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          title: q.text.trim(),
                          status: status,
                          finishedOn: status == BookStatus.read ? DateTime.now() : null,
                        ),
                        find: true,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Choisir la bonne couverture parmi les livres trouvés.
Future<BookMatch?> pickCover(BuildContext context, BooksModule m, Book b) => showDialog<BookMatch>(
  context: context,
  builder: (c) => AlertDialog(
    title: Text('Couverture de « ${b.title} »'),
    content: SizedBox(
      width: 560,
      height: 460,
      child: FutureBuilder(
        future: m.finder.candidates(b.title, author: b.author, max: 16),
        builder: (context, snap) {
          if (snap.hasError) return ErrorBanner('${snap.error}');
          if (!snap.hasData) return const LoadingHint();
          final list = [for (final x in snap.data!) if (x.coverUrl != null) x];
          if (list.isEmpty) return const EmptyHint('Aucune couverture trouvée');
          return GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              childAspectRatio: 0.52,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final x = list[i];
              return InkWell(
                onTap: () => Navigator.pop(c, x),
                child: Column(
                  children: [
                    Expanded(child: BookCover(radius: 6, book: Book(id: '', title: x.title, coverUrl: x.coverUrl))),
                    const SizedBox(height: 4),
                    Text(x.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              );
            },
          );
        },
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler'))],
  ),
);
