import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/hub_files.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';
import 'books_module.dart';
import 'read_finder.dart';

/// Ouvre la lecture d'un livre ou d'un manga de la bibliothèque : retrouve
/// tout seul où le lire (la première fois), puis reprend là où tu t'es
/// arrêté. [choose] = redemander le bon titre.
Future<void> openReading(BuildContext context, BooksModule m, Book b, {bool choose = false}) async {
  if (b.read == null || choose) {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FindReadingSheet(module: m, book: b, auto: !choose),
    );
    if (ok != true || !context.mounted) return;
  }
  final link = b.read;
  if (link == null) return;
  final Widget page = switch (link.source) {
    'mangadex' => ScanReaderPage(module: m, book: b),
    'gutenberg' || 'gutenberg-au' || 'wikisource' => TextReaderPage(module: m, book: b),
    _ => WebBookPage(module: m, book: b),
  };
  final r = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => page));
  if (r == 'choose' && context.mounted) await openReading(context, m, b, choose: true);
}

/// Réglages du lecteur (mode, sens, taille du texte…), gardés sur l'appareil.
T? _opt<T>(BooksModule m, String k) {
  final v = m.store.getJson<Map<String, dynamic>>('reader')?[k];
  return v is T ? v : null;
}

Future<void> _setOpt(BooksModule m, String k, Object v) =>
    m.store.setJson('reader', {...?m.store.getJson<Map<String, dynamic>>('reader'), k: v});

IconData _sourceIcon(String source) => switch (source) {
  'mangadex' => Icons.auto_awesome_mosaic_rounded,
  'gutenberg' || 'gutenberg-au' || 'wikisource' => Icons.menu_book_rounded,
  _ => Icons.account_balance_rounded,
};

String _flags(List<String> langs) => [if (langs.contains('fr')) '🇫🇷', if (langs.contains('en')) '🇬🇧'].join(' ');

// ---------------------------------------------------------------------------
// « C'est celui-ci ? » : choisir où lire
// ---------------------------------------------------------------------------

class _FindReadingSheet extends StatefulWidget {
  const _FindReadingSheet({required this.module, required this.book, required this.auto});
  final BooksModule module;
  final Book book;
  final bool auto;

  @override
  State<_FindReadingSheet> createState() => _FindReadingSheetState();
}

class _FindReadingSheetState extends State<_FindReadingSheet> {
  late final q = TextEditingController(text: ReadQuery.parse(widget.book.title).title);
  List<ReadMatch>? results;
  bool loading = false;
  String? error;
  int _id = 0;

  @override
  void initState() {
    super.initState();
    _search(auto: widget.auto);
  }

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  Future<void> _search({bool auto = false}) async {
    final text = q.text.trim();
    if (text.isEmpty) return;
    final id = ++_id;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await widget.module.readFinder.find(text, author: widget.book.author);
      if (!mounted || id != _id) return;
      if (auto && ReadFinder.confident(r)) return await _pick(r.first);
      setState(() => results = r);
    } catch (e) {
      if (mounted) setState(() => error = 'Recherche impossible : $e');
    } finally {
      if (mounted && id == _id) setState(() => loading = false);
    }
  }

  Future<void> _pick(ReadMatch m) async {
    widget.book.read = ReadLink.fromMatch(m);
    await widget.module.upsert(widget.book);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = results ?? const <ReadMatch>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: q,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Titre du manga ou du livre (en anglais ou japonais aussi)',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: loading
                      ? const Padding(padding: EdgeInsets.all(14), child: LoadingHint())
                      : IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _search),
                ),
              ),
            ),
            if (error != null) ErrorBanner(error!),
            Expanded(
              child: loading && results == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 60, width: 200, child: LoadingHint()),
                          Text('Je cherche « ${q.text} » en scans et en livres libres…'),
                        ],
                      ),
                    )
                  : results != null && list.isEmpty
                  ? _nothing(context)
                  : ListView(
                      padding: const EdgeInsets.all(8),
                      children: [
                        if (list.isNotEmpty) _best(context, list.first),
                        for (final r in list.skip(1))
                          ListTile(
                            leading: SizedBox(
                              width: 40,
                              height: 60,
                              child: BookCover(
                                radius: 4,
                                book: Book(id: '', title: r.title, coverUrl: r.coverUrl),
                              ),
                            ),
                            title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [
                                r.sourceLabel,
                                if (r.author.isNotEmpty) r.author,
                                _flags(r.languages),
                              ].where((x) => x.isNotEmpty).join(' · '),
                            ),
                            trailing: Icon(_sourceIcon(r.source)),
                            onTap: () => _pick(r),
                          ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'Sources gratuites et légales : MangaDex (scans), Projet Gutenberg, Wikisource, '
                            'Gutenberg Australie (classiques libres en France, comme 1984) et Internet Archive. '
                            'Jamais de site pirate. Seul le titre part sur internet.',
                            style: theme.textTheme.labelSmall,
                            textAlign: TextAlign.center,
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

  Widget _best(BuildContext context, ReadMatch m) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _pick(m),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 90,
                height: 135,
                child: BookCover(
                  book: Book(id: '', title: m.title, author: m.author, coverUrl: m.coverUrl),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('C\'est celui-ci ?', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Text(m.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    if (m.author.isNotEmpty) Text(m.author),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(_sourceIcon(m.source), size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text('${m.sourceLabel}  ${_flags(m.languages)}', style: theme.textTheme.labelSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.chrome_reader_mode_rounded),
                      label: const Text('Lire'),
                      onPressed: () => _pick(m),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nothing(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.search_off_rounded, size: 48),
        const SizedBox(height: 12),
        Text(
          'Je n\'ai rien trouvé à lire gratuitement pour « ${q.text} ».\n'
          'Essaie le titre anglais ou japonais. Les gros mangas sous licence (One Piece, '
          'Jujutsu Kaisen…) se lisent gratuitement et légalement sur les sites officiels ; '
          'un livre récent s\'emprunte à la médiathèque (souvent aussi en numérique).',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('MANGA Plus'),
              onPressed: () => Browser.open('https://mangaplus.shueisha.co.jp/'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('WEBTOON'),
              onPressed: () => Browser.open('https://www.webtoons.com/fr/'),
            ),
          ],
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Lecteur de scans (manga)
// ---------------------------------------------------------------------------

/// Les scans d'un manga, page par page (ou en défilement continu), avec le
/// chapitre suivant à la fin et la reprise là où tu t'es arrêté.
class ScanReaderPage extends StatefulWidget {
  const ScanReaderPage({super.key, required this.module, required this.book});
  final BooksModule module;
  final Book book;

  @override
  State<ScanReaderPage> createState() => _ScanReaderPageState();
}

class _ScanReaderPageState extends State<ScanReaderPage> {
  ReadLink get link => widget.book.read!;
  ReadFinder get finder => widget.module.readFinder;

  List<ScanChapter>? chapters;
  int index = 0;
  List<String>? pages;
  int page = 0;
  String? error;
  bool bars = true;
  PageController? ctrl;
  final scroll = ScrollController();
  final focus = FocusNode();
  Timer? _saveLater;

  late bool vertical = _opt<bool>(widget.module, 'vertical') ?? false;
  late bool rtl = _opt<bool>(widget.module, 'rtl') ?? false;
  late bool saver = _opt<bool>(widget.module, 'saver') ?? false;

  ScanChapter? get chapter => chapters == null || chapters!.isEmpty ? null : chapters![index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveLater?.cancel();
    _save();
    ctrl?.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await finder.chapters(link.id);
      if (!mounted) return;
      if (list.isEmpty) {
        return setState(() {
          chapters = list;
          error = 'Aucun chapitre en français ni en anglais pour l\'instant.';
        });
      }
      var i = link.chapterId == null ? -1 : list.indexWhere((c) => c.id == link.chapterId);
      var start = link.page;
      if (i < 0) {
        // Pas encore commencé : le tome / chapitre écrit dans le titre, sinon le début.
        i = ReadFinder.startIndex(list, ReadQuery.parse(widget.book.title));
        start = 0;
      }
      setState(() => chapters = list);
      await _openChapter(i, page: start);
    } catch (e) {
      if (mounted) setState(() => error = 'Chargement impossible : $e');
    }
  }

  Future<void> _openChapter(int i, {int page = 0}) async {
    final list = chapters;
    if (list == null || i < 0 || i >= list.length) return;
    setState(() {
      index = i;
      pages = null;
      error = null;
      this.page = 0;
    });
    final c = list[i];
    if (!c.readable) return; // sur le site officiel : bouton pour l'ouvrir
    try {
      final p = await finder.pages(c.id, saver: saver);
      if (!mounted || index != i) return;
      final start = page.clamp(0, p.isEmpty ? 0 : p.length - 1);
      ctrl?.dispose();
      ctrl = PageController(initialPage: start);
      setState(() {
        pages = p;
        this.page = start;
      });
      if (scroll.hasClients) scroll.jumpTo(0);
      if (vertical && start > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients) scroll.jumpTo(start * _estimatedHeight);
        });
      }
      _precache();
      _saveSoon();
    } catch (e) {
      if (mounted) setState(() => error = 'Ce chapitre ne se charge pas : $e');
    }
  }

  double get _estimatedHeight => (MediaQuery.of(context).size.width.clamp(0, 900)) * 1.45;

  void _precache() {
    final p = pages;
    if (p == null) return;
    for (var k = page + 1; k <= page + 3 && k < p.length; k++) {
      precacheImage(NetworkImage(p[k]), context, onError: (_, _) {});
    }
  }

  void _saveSoon() {
    _saveLater?.cancel();
    _saveLater = Timer(const Duration(milliseconds: 800), _save);
  }

  void _save() {
    final c = chapter;
    if (c == null || widget.book.read == null) return;
    link
      ..chapterId = c.id
      ..chapterLabel = c.number == null ? c.label : 'Chapitre ${c.number}'
      ..page = page
      ..at = DateTime.now();
    if (widget.book.status == BookStatus.toRead) widget.book.status = BookStatus.reading;
    unawaited(widget.module.upsert(widget.book));
  }

  void _setPage(int p) {
    setState(() => page = p);
    _precache();
    _saveSoon();
  }

  /// Page suivante (+1) ou précédente (-1) ; au bout, chapitre voisin.
  void _go(int delta) {
    final p = pages;
    if (p == null) {
      if (delta > 0 && index + 1 < (chapters?.length ?? 0)) _openChapter(index + 1);
      if (delta < 0 && index > 0) _openChapter(index - 1);
      return;
    }
    if (vertical) {
      if (!scroll.hasClients) return;
      final h = MediaQuery.of(context).size.height * 0.85;
      scroll.animateTo(
        (scroll.offset + delta * h).clamp(0, scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    final target = page + delta;
    if (target < 0) {
      if (index > 0) _openChapter(index - 1);
      return;
    }
    if (target > p.length) {
      if (index + 1 < chapters!.length) _openChapter(index + 1);
      return;
    }
    ctrl?.animateToPage(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final forward = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final back = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    if (k == forward ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.pageDown ||
        (!vertical && k == LogicalKeyboardKey.arrowDown)) {
      _go(1);
    } else if (k == back || k == LogicalKeyboardKey.pageUp || (!vertical && k == LogicalKeyboardKey.arrowUp)) {
      _go(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _setOption(String key, bool v) async {
    await _setOpt(widget.module, key, v);
    setState(() {
      if (key == 'vertical') vertical = v;
      if (key == 'rtl') rtl = v;
      if (key == 'saver') saver = v;
    });
    if (key == 'saver') await _openChapter(index, page: page);
    if (key == 'vertical') {
      ctrl?.dispose();
      ctrl = PageController(initialPage: page);
    }
  }

  Future<void> _pickChapter() async {
    final list = chapters;
    if (list == null) return;
    final i = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => ListView.builder(
        controller: ScrollController(initialScrollOffset: (index * 56.0 - 120).clamp(0, double.infinity)),
        itemCount: list.length,
        itemExtent: 56,
        itemBuilder: (_, k) {
          final ch = list[k];
          return ListTile(
            selected: k == index,
            leading: Text(ch.flag, style: const TextStyle(fontSize: 18)),
            title: Text(ch.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: ch.vol == null ? null : Text('Tome ${ch.vol}'),
            trailing: ch.readable ? null : const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => Navigator.pop(c, k),
          );
        },
      ),
    );
    if (i != null) await _openChapter(i);
  }

  @override
  Widget build(BuildContext context) {
    final c = chapter;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: bars
            ? AppBar(
                backgroundColor: const Color(0xFF111111),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      link.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16),
                    ),
                    if (c != null)
                      Text(
                        '${c.label} ${c.flag}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'Chapitres',
                    icon: const Icon(Icons.format_list_numbered_rounded),
                    onPressed: _pickChapter,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Réglages de lecture',
                    icon: const Icon(Icons.tune_rounded),
                    onSelected: (v) {
                      if (v == 'choose') Navigator.pop(context, 'choose');
                      if (v == 'vertical') _setOption('vertical', !vertical);
                      if (v == 'rtl') _setOption('rtl', !rtl);
                      if (v == 'saver') _setOption('saver', !saver);
                    },
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(
                        value: 'vertical',
                        checked: vertical,
                        child: const Text('Défilement continu (webtoon)'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'rtl',
                        checked: rtl,
                        child: const Text('Sens japonais (de droite à gauche)'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'saver',
                        checked: saver,
                        child: const Text('Images légères (connexion lente)'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'choose', child: Text('Ce n\'est pas le bon manga')),
                    ],
                  ),
                ],
              )
            : null,
        body: Focus(focusNode: focus, autofocus: true, onKeyEvent: _onKey, child: _body(context)),
        bottomNavigationBar: bars && pages != null && !vertical ? _bottom(context) : null,
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (error != null && pages == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ErrorBanner(error!),
            if (chapters != null && chapters!.isNotEmpty)
              FilledButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Réessayer'),
                onPressed: () => _openChapter(index),
              ),
            TextButton(onPressed: () => Navigator.pop(context, 'choose'), child: const Text('Choisir un autre manga')),
          ],
        ),
      );
    }
    final c = chapter;
    if (c != null && !c.readable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_rounded, size: 48, color: Colors.white70),
              const SizedBox(height: 12),
              Text(
                '${c.label} est publié gratuitement sur le site officiel de l\'éditeur.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Le lire sur le site officiel'),
                onPressed: () => Browser.open(c.externalUrl!),
              ),
              const SizedBox(height: 8),
              _chapterNav(),
            ],
          ),
        ),
      );
    }
    final p = pages;
    if (p == null) return const Center(child: SizedBox(width: 220, height: 80, child: LoadingHint()));
    if (vertical) {
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final max = n.metrics.maxScrollExtent;
          if (max > 0) {
            final k = (n.metrics.pixels / max * p.length).floor().clamp(0, p.length - 1);
            if (k != page) _setPage(k);
          }
          return false;
        },
        child: GestureDetector(
          onTap: () => setState(() => bars = !bars),
          child: ListView.builder(
            controller: scroll,
            itemCount: p.length + 1,
            itemBuilder: (_, k) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: k == p.length ? _endOfChapter() : _ScanImage(url: p[k], fit: BoxFit.fitWidth),
              ),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        onTapUp: (d) {
          final x = d.localPosition.dx / box.maxWidth;
          if (x < 0.3) {
            _go(rtl ? 1 : -1);
          } else if (x > 0.7) {
            _go(rtl ? -1 : 1);
          } else {
            setState(() => bars = !bars);
          }
        },
        child: PageView.builder(
          controller: ctrl,
          reverse: rtl,
          itemCount: p.length + 1,
          onPageChanged: _setPage,
          itemBuilder: (_, k) => k == p.length
              ? Center(child: _endOfChapter())
              : InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: _ScanImage(url: p[k], fit: BoxFit.contain),
                  ),
                ),
        ),
      ),
    );
  }

  bool get _hasNext => chapters != null && index + 1 < chapters!.length;

  Widget _chapterNav() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      TextButton.icon(
        onPressed: index > 0 ? () => _openChapter(index - 1) : null,
        icon: const Icon(Icons.skip_previous_rounded),
        label: const Text('Précédent'),
      ),
      const SizedBox(width: 12),
      TextButton.icon(
        onPressed: _hasNext ? () => _openChapter(index + 1) : null,
        icon: const Icon(Icons.skip_next_rounded),
        label: const Text('Suivant'),
      ),
    ],
  );

  Widget _endOfChapter() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Fin du ${chapter?.number == null ? 'chapitre' : 'chapitre ${chapter!.number}'}',
          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        if (_hasNext)
          FilledButton.icon(
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(chapters![index + 1].label, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: () => _openChapter(index + 1),
          )
        else
          const Text('Tu es à jour : c\'est le dernier chapitre disponible.', style: TextStyle(color: Colors.white70)),
      ],
    ),
  );

  Widget _bottom(BuildContext context) {
    final n = pages!.length;
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SafeArea(
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Chapitre précédent',
                onPressed: index > 0 ? () => _openChapter(index - 1) : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              Expanded(
                child: n < 2
                    ? const SizedBox()
                    : Slider(
                        value: page.clamp(0, n - 1).toDouble(),
                        max: (n - 1).toDouble(),
                        divisions: n - 1,
                        onChanged: (v) => ctrl?.jumpToPage(v.round()),
                      ),
              ),
              Text('${(page + 1).clamp(1, n)} / $n', style: const TextStyle(color: Colors.white70)),
              IconButton(
                tooltip: 'Chapitre suivant',
                onPressed: _hasNext ? () => _openChapter(index + 1) : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Une page de scan, avec chargement et « Réessayer » si elle ne vient pas.
class _ScanImage extends StatefulWidget {
  const _ScanImage({required this.url, required this.fit});
  final String url;
  final BoxFit fit;

  @override
  State<_ScanImage> createState() => _ScanImageState();
}

class _ScanImageState extends State<_ScanImage> {
  int _try = 0;

  @override
  Widget build(BuildContext context) {
    final placeholder = SizedBox(
      height: MediaQuery.of(context).size.width.clamp(0, 900) * 1.45,
      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
    return Image.network(
      widget.url,
      key: ValueKey('${widget.url}#$_try'),
      fit: widget.fit,
      filterQuality: FilterQuality.medium,
      loadingBuilder: (_, child, p) => p == null ? child : placeholder,
      errorBuilder: (_, _, _) => SizedBox(
        height: 300,
        child: Center(
          child: TextButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Cette page ne s\'affiche pas — réessayer'),
            onPressed: () => setState(() => _try++),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lecteur de livres (texte, Projet Gutenberg)
// ---------------------------------------------------------------------------

enum _Paper {
  light('Clair', Color(0xFFFFFFFF), Color(0xFF1E1E1E)),
  sepia('Sépia', Color(0xFFF6EEDB), Color(0xFF3B2F22)),
  dark('Sombre', Color(0xFF141414), Color(0xFFDADADA));

  const _Paper(this.label, this.bg, this.fg);
  final String label;
  final Color bg;
  final Color fg;
}

/// Un livre libre de droits lu comme sur une liseuse : pages, taille du
/// texte, papier clair / sépia / sombre, reprise là où tu t'es arrêté. Le
/// texte est gardé sur l'appareil (lisible hors ligne ensuite).
class TextReaderPage extends StatefulWidget {
  const TextReaderPage({super.key, required this.module, required this.book});
  final BooksModule module;
  final Book book;

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class _TextReaderPageState extends State<TextReaderPage> {
  ReadLink get link => widget.book.read!;
  List<String>? paras;
  List<List<String>> pages = [];

  /// Premier paragraphe de chaque page.
  List<int> starts = [];
  int page = 0;
  String? error;
  PageController? ctrl;
  final focus = FocusNode();
  Timer? _saveLater;

  late double font = (_opt<num>(widget.module, 'font') ?? 19).toDouble();
  late _Paper paper = _Paper.values.asNameMap()[_opt<String>(widget.module, 'paper')] ?? _Paper.sepia;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveLater?.cancel();
    _save();
    ctrl?.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<File?> _cache() async {
    final dir = await HubFiles.dir();
    if (dir == null) return null;
    final safe = link.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}lectures${Platform.pathSeparator}${link.source}-$safe.txt');
  }

  Future<void> _load() async {
    try {
      String? text;
      final f = await _cache();
      if (f != null && await f.exists()) text = await f.readAsString();
      if (text == null || text.isEmpty) {
        text = await widget.module.readFinder.bookText(link.textUrl!);
        if (f != null) {
          await f.parent.create(recursive: true);
          await f.writeAsString(text, flush: true);
        }
      }
      if (!mounted) return;
      paras = ReadFinder.paragraphs(text);
      _paginate(link.page);
    } catch (e) {
      if (mounted) setState(() => error = 'Le livre ne se charge pas : $e');
    }
  }

  /// Refait les pages (taille du texte changée) en restant au même endroit.
  void _paginate(int paragraph) {
    final p = paras ?? const <String>[];
    pages = ReadFinder.paginate(p, chars: (1600 * 19 / font).round());
    starts = [];
    var k = 0;
    for (final pg in pages) {
      starts.add(k);
      k += pg.length;
    }
    var at = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= paragraph) at = i;
    }
    ctrl?.dispose();
    ctrl = PageController(initialPage: at);
    setState(() => page = at);
  }

  void _saveSoon() {
    _saveLater?.cancel();
    _saveLater = Timer(const Duration(milliseconds: 800), _save);
  }

  void _save() {
    if (starts.isEmpty || widget.book.read == null) return;
    link
      ..page = starts[page.clamp(0, starts.length - 1)]
      ..total = paras?.length
      ..at = DateTime.now();
    if (widget.book.status == BookStatus.toRead) widget.book.status = BookStatus.reading;
    unawaited(widget.module.upsert(widget.book));
  }

  void _go(int d) => ctrl?.animateToPage(
    (page + d).clamp(0, pages.length - 1),
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
  );

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.pageDown) {
      _go(1);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      _go(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _setFont(double f) {
    final here = starts.isEmpty ? 0 : starts[page];
    font = f.clamp(14, 30);
    _setOpt(widget.module, 'font', font.round());
    _paginate(here);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paper.bg,
      appBar: AppBar(
        backgroundColor: paper.bg,
        foregroundColor: paper.fg,
        title: Text(link.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Texte plus petit',
            icon: const Icon(Icons.text_decrease_rounded),
            onPressed: () => _setFont(font - 1),
          ),
          IconButton(
            tooltip: 'Texte plus grand',
            icon: const Icon(Icons.text_increase_rounded),
            onPressed: () => _setFont(font + 1),
          ),
          PopupMenuButton<String>(
            tooltip: 'Papier',
            icon: const Icon(Icons.palette_outlined),
            onSelected: (v) {
              if (v == 'choose') return Navigator.pop(context, 'choose');
              setState(() => paper = _Paper.values.byName(v));
              _setOpt(widget.module, 'paper', v);
            },
            itemBuilder: (_) => [
              for (final p in _Paper.values)
                CheckedPopupMenuItem(value: p.name, checked: p == paper, child: Text(p.label)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'choose', child: Text('Ce n\'est pas le bon livre')),
            ],
          ),
        ],
      ),
      body: Focus(focusNode: focus, autofocus: true, onKeyEvent: _onKey, child: _body()),
      bottomNavigationBar: pages.length < 2
          ? null
          : SafeArea(
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: page.toDouble(),
                        max: (pages.length - 1).toDouble(),
                        onChanged: (v) => ctrl?.jumpToPage(v.round()),
                      ),
                    ),
                    Text('${page + 1} / ${pages.length}', style: TextStyle(color: paper.fg)),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _body() {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ErrorBanner(error!),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () {
                    setState(() => error = null);
                    _load();
                  },
                  child: const Text('Réessayer'),
                ),
                // Le texte ne se télécharge pas : on le lit sur le site même.
                if (link.webUrl != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.public_rounded),
                    label: const Text('Lire sur le site'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WebBookPage(module: widget.module, book: widget.book),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    if (paras == null) return const Center(child: SizedBox(width: 220, height: 80, child: LoadingHint()));
    final style = TextStyle(color: paper.fg, fontSize: font, height: 1.55, fontFamily: 'Georgia');
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        onTapUp: (d) {
          final x = d.localPosition.dx / box.maxWidth;
          if (x < 0.25) _go(-1);
          if (x > 0.75) _go(1);
        },
        child: PageView.builder(
          controller: ctrl,
          itemCount: pages.length,
          onPageChanged: (p) {
            setState(() => page = p);
            _saveSoon();
          },
          itemBuilder: (_, k) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final para in pages[k])
                      Padding(
                        padding: EdgeInsets.only(bottom: font * 0.8),
                        child: Text(para, style: style, textAlign: TextAlign.justify),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Livre scanné (Internet Archive), dans Mon Hub
// ---------------------------------------------------------------------------

class WebBookPage extends StatefulWidget {
  const WebBookPage({super.key, required this.module, required this.book});
  final BooksModule module;
  final Book book;

  @override
  State<WebBookPage> createState() => _WebBookPageState();
}

class _WebBookPageState extends State<WebBookPage> {
  @override
  void initState() {
    super.initState();
    final b = widget.book;
    b.read!.at = DateTime.now();
    if (b.status == BookStatus.toRead) b.status = BookStatus.reading;
    unawaited(widget.module.upsert(b));
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.book.read!;
    final url = link.webUrl ?? 'https://archive.org/details/${link.id}';
    return Scaffold(
      appBar: AppBar(
        title: Text(link.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Ce n\'est pas le bon livre',
            icon: const Icon(Icons.swap_horiz_rounded),
            onPressed: () => Navigator.pop(context, 'choose'),
          ),
          IconButton(
            tooltip: 'Ouvrir dans le navigateur',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => Browser.open(url),
          ),
        ],
      ),
      body: HubWebView(url: url, desktopUserAgent: true),
    );
  }
}
