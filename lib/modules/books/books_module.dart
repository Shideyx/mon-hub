import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';

class Book {
  Book({
    required this.id,
    required this.title,
    this.author = '',
    this.coverUrl,
    DateTime? finishedOn,
    this.rating = 0,
    this.notes = '',
  }) : finishedOn = finishedOn ?? DateTime.now();

  final String id;
  String title;
  String author;
  String? coverUrl;
  DateTime finishedOn;
  int rating; // 0 à 5
  String notes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'finishedOn': finishedOn.toIso8601String(),
        'rating': rating,
        'notes': notes,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        title: j['title'] as String,
        author: j['author'] as String? ?? '',
        coverUrl: j['coverUrl'] as String?,
        finishedOn: DateTime.tryParse(j['finishedOn'] as String? ?? ''),
        rating: j['rating'] as int? ?? 0,
        notes: j['notes'] as String? ?? '',
      );
}

/// Tous les livres lus. Stockage local + recherche via Open Library
/// (API publique gratuite, sans compte).
class BooksModule extends HubModule {
  @override
  String get id => 'books';
  @override
  String get name => 'Mes livres';
  @override
  String get description => 'Tous les livres que tu as lus';
  @override
  IconData get icon => Icons.menu_book_outlined;
  @override
  Color get color => const Color(0xFF8E6C3F);
  @override
  ApiAccess get access => ApiAccess.local;

  List<Book> get books {
    final raw = store.getJson<List<dynamic>>('books') ?? const [];
    final list = raw.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
    list.sort((a, b) => b.finishedOn.compareTo(a.finishedOn));
    return list;
  }

  Future<void> save(List<Book> list) =>
      store.setJson('books', list.map((b) => b.toJson()).toList());

  Future<void> upsert(Book b) {
    final list = books..removeWhere((x) => x.id == b.id);
    return save(list..add(b));
  }

  Future<void> remove(Book b) => save(books..removeWhere((x) => x.id == b.id));

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final all = books;
          if (all.isEmpty) {
            return const EmptyHint('Ajoute ton premier livre', icon: Icons.add);
          }
          final year = DateTime.now().year;
          final thisYear = all.where((b) => b.finishedOn.year == year).length;
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${all.length} livres lus · $thisYear en $year',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final b in all.take(8))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _Cover(book: b, width: 80),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );

  @override
  Widget buildPage(BuildContext context) => _BooksPage(module: this);
}

class _Cover extends StatelessWidget {
  const _Cover({required this.book, required this.width});
  final Book book;
  final double width;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(4),
      alignment: Alignment.center,
      child: Text(book.title,
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        child: book.coverUrl == null
            ? fallback
            : Image.network(book.coverUrl!,
                fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class _BooksPage extends StatefulWidget {
  const _BooksPage({required this.module});
  final BooksModule module;

  @override
  State<_BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<_BooksPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    return Scaffold(
      appBar: AppBar(title: Text(m.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: ListenableBuilder(
        listenable: m.store,
        builder: (context, _) {
          final q = query.toLowerCase();
          final list = m.books
              .where((b) =>
                  b.title.toLowerCase().contains(q) ||
                  b.author.toLowerCase().contains(q))
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Chercher dans mes livres'),
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyHint('Aucun livre pour l\'instant')
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final b = list[i];
                          return ListTile(
                            leading: SizedBox(
                                height: 56, child: _Cover(book: b, width: 40)),
                            title: Text(b.title),
                            subtitle: Text([
                              if (b.author.isNotEmpty) b.author,
                              'fini le ${b.finishedOn.day}/${two(b.finishedOn.month)}/${b.finishedOn.year}',
                            ].join(' · ')),
                            trailing: Text('★' * b.rating),
                            onTap: () => _edit(context, b),
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

  Future<void> _edit(BuildContext context, Book? book) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BookEditor(book: book),
    );
    if (result is Book) await widget.module.upsert(result);
    if (result == 'delete' && book != null) await widget.module.remove(book);
  }
}

class _BookEditor extends StatefulWidget {
  const _BookEditor({this.book});
  final Book? book;

  @override
  State<_BookEditor> createState() => _BookEditorState();
}

class _BookEditorState extends State<_BookEditor> {
  late final title = TextEditingController(text: widget.book?.title);
  late final author = TextEditingController(text: widget.book?.author);
  late final notes = TextEditingController(text: widget.book?.notes);
  late String? cover = widget.book?.coverUrl;
  late int rating = widget.book?.rating ?? 0;
  late DateTime finished = widget.book?.finishedOn ?? DateTime.now();
  List<Map<String, dynamic>> results = [];
  bool searching = false;

  Future<void> _search() async {
    if (title.text.trim().isEmpty) return;
    setState(() => searching = true);
    try {
      final uri = Uri.https('openlibrary.org', '/search.json', {
        'q': '${title.text} ${author.text}'.trim(),
        'limit': '8',
        'fields': 'title,author_name,cover_i',
      });
      final res = await http.get(uri);
      final docs = (jsonDecode(res.body)['docs'] as List).cast<Map<String, dynamic>>();
      setState(() => results = docs);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.book == null ? 'Nouveau livre' : 'Modifier',
                style: Theme.of(context).textTheme.titleLarge),
            TextField(
                controller: title,
                decoration: InputDecoration(
                  labelText: 'Titre',
                  suffixIcon: IconButton(
                    tooltip: 'Chercher la couverture (Open Library)',
                    icon: searching
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.travel_explore),
                    onPressed: _search,
                  ),
                )),
            TextField(
                controller: author,
                decoration: const InputDecoration(labelText: 'Auteur')),
            if (results.isNotEmpty)
              SizedBox(
                height: 130,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final r in results)
                      InkWell(
                        onTap: () => setState(() {
                          title.text = r['title'] as String? ?? title.text;
                          final a = r['author_name'] as List?;
                          if (a != null && a.isNotEmpty) author.text = a.first as String;
                          cover = r['cover_i'] == null
                              ? null
                              : 'https://covers.openlibrary.org/b/id/${r['cover_i']}-M.jpg';
                          results = [];
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: _Cover(
                            width: 70,
                            book: Book(
                              id: '',
                              title: r['title'] as String? ?? '?',
                              coverUrl: r['cover_i'] == null
                                  ? null
                                  : 'https://covers.openlibrary.org/b/id/${r['cover_i']}-S.jpg',
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    icon: Icon(i <= rating ? Icons.star : Icons.star_border,
                        color: Colors.amber),
                    onPressed: () => setState(() => rating = i == rating ? 0 : i),
                  ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text('${finished.day}/${two(finished.month)}/${finished.year}'),
                  onPressed: () async {
                    final d = await showDatePicker(
                        context: context,
                        initialDate: finished,
                        firstDate: DateTime(1990),
                        lastDate: DateTime.now().add(const Duration(days: 1)));
                    if (d != null) setState(() => finished = d);
                  },
                ),
              ],
            ),
            TextField(
                controller: notes,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes / avis')),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.book != null)
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'delete'),
                    child: const Text('Supprimer'),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    if (title.text.trim().isEmpty) return;
                    Navigator.pop(
                      context,
                      Book(
                        id: widget.book?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        title: title.text.trim(),
                        author: author.text.trim(),
                        coverUrl: cover,
                        finishedOn: finished,
                        rating: rating,
                        notes: notes.text.trim(),
                      ),
                    );
                  },
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
