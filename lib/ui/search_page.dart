import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/everywhere_search.dart';
import '../core/nav.dart';
import 'clicky/clicky.dart';
import 'file_viewer.dart';
import 'widgets.dart';

/// **Recherche partout** (Ctrl + Espace) : un mot, et les résultats du PC,
/// du Drive, de Google Docs, des mails, de Discord, d'École Directe, du
/// Carnet, des cours et des révisions arrivent au fur et à mesure.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initial = ''});
  final String initial;

  static bool _open = false;

  /// Ouvre la recherche par-dessus l'appli (une seule à la fois).
  static Future<void> show([String text = '']) async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null || _open) return;
    _open = true;
    try {
      await nav.push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.black54,
          barrierDismissible: true,
          pageBuilder: (_, _, _) => SearchPage(initial: text),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      );
    } finally {
      _open = false;
    }
  }

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _text = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  bool _busy = false;
  int _run = 0;
  String _done = '';

  static const _icons = {
    'PC': Icons.computer_rounded,
    'Drive': Icons.add_to_drive_rounded,
    'Google Docs': Icons.description_rounded,
    'Mails': Icons.mail_rounded,
    'Discord': Icons.forum_rounded,
    'École Directe': Icons.school_rounded,
    'Devoirs': Icons.menu_book_rounded,
    'Carnet': Icons.sticky_note_2_rounded,
    'Presse-papier': Icons.content_paste_rounded,
    'Cours écoutés': Icons.mic_rounded,
    'Révisions': Icons.style_rounded,
    'Livres': Icons.auto_stories_rounded,
  };

  @override
  void initState() {
    super.initState();
    if (widget.initial.trim().isNotEmpty) unawaited(_search(widget.initial));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q == _done) return;
    final run = ++_run;
    if (q.length < 2) {
      setState(() {
        _hits = const [];
        _busy = false;
        _done = q;
      });
      return;
    }
    setState(() {
      _busy = true;
      _hits = const [];
    });
    final all = await ClickyController.instance.search(q, onPart: (part) {
      if (mounted && run == _run) setState(() => _hits = part);
    });
    if (!mounted || run != _run) return;
    setState(() {
      _hits = all;
      _busy = false;
      _done = q;
    });
  }

  Future<void> _openHit(SearchHit h) async {
    final nav = Navigator.of(context);
    if (h.path != null && h.path!.isNotEmpty) {
      final f = File(h.path!);
      nav.pop();
      await FileViewer.open(nav.context, h.title, () => f.readAsBytes());
      return;
    }
    if (h.link != null) {
      nav.pop();
      await Browser.open(h.link!);
      return;
    }
    final m = ClickyController.instance.hub?.enabled.where((m) => m.id == h.moduleId).firstOrNull;
    if (m != null) {
      nav.pop();
      await nav.push(MaterialPageRoute<void>(builder: (ctx) => m.buildPage(ctx)));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(h.title),
        content: SingleChildScrollView(child: SelectableText(h.detail)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = EverywhereSearch.words(_text.text);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: SafeArea(
        child: Align(
          alignment: const Alignment(0, -0.6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.search_rounded, size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _text,
                              focusNode: _focus,
                              autofocus: true,
                              style: theme.textTheme.titleLarge,
                              decoration: const InputDecoration(
                                hintText: 'Cherche partout : PC, Drive, mails, Discord, cours…',
                                border: InputBorder.none,
                              ),
                              onChanged: _changed,
                              onSubmitted: (q) {
                                if (_hits.isNotEmpty && q.trim() == _done) {
                                  unawaited(_openHit(_hits.first));
                                } else {
                                  _debounce?.cancel();
                                  unawaited(_search(q));
                                }
                              },
                            ),
                          ),
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.all(8),
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          IconButton(
                            tooltip: 'Fermer (Échap)',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: _hits.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _busy
                                    ? 'Je cherche…'
                                    : _done.length >= 2
                                    ? 'Rien trouvé pour « $_done ».'
                                    : 'Tape un mot (un nom, une matière, un fichier…). Entrée ouvre le premier résultat.\n'
                                          'Partout sur le PC : Ctrl + Alt + Espace.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: theme.colorScheme.outline),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: _hits.length.clamp(0, 60),
                              itemBuilder: (context, i) {
                                final h = _hits[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(_icons[h.source] ?? Icons.label_rounded, color: theme.colorScheme.primary),
                                  title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    [
                                      h.source,
                                      if (h.date != null) dayLabel(h.date!),
                                      if (h.detail.isNotEmpty) EverywhereSearch.around(h.detail, w, 110),
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => _openHit(h),
                                );
                              },
                            ),
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
