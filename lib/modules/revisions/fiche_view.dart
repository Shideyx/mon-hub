import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../docs/doc_format.dart';

/// Une fiche de révision (Markdown) mise en page : titres en couleur,
/// définitions en gras, listes, encadrés.
class FicheView extends StatelessWidget {
  const FicheView({super.key, required this.markdown, required this.color});
  final String markdown;
  final Color color;

  static Color? _hex(Object? c) {
    if (c is! String) return null;
    final h = c.replaceFirst('#', '');
    final v = int.tryParse(h.length == 6 ? h : '', radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge!.copyWith(height: 1.5);
    final out = <Widget>[];
    var n = 0;
    for (final l in DocFormat.lines(DocFormat.fromMarkdown(markdown))) {
      final b = l.block;
      final h = (b['header'] as num?)?.toInt();
      final style = switch (h) {
        1 => theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w900, color: color),
        2 => theme.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w800, color: Color.lerp(color, theme.colorScheme.onSurface, 0.25)),
        3 => theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w800),
        _ => base,
      };
      final spans = [
        for (final r in l.runs)
          if (r.embed == null)
            TextSpan(
              text: r.text,
              style: TextStyle(
                fontWeight: r.attrs['bold'] == true ? FontWeight.w800 : null,
                fontStyle: r.attrs['italic'] == true ? FontStyle.italic : null,
                decoration: r.attrs['strike'] == true ? TextDecoration.lineThrough : null,
                color: r.attrs['link'] != null ? color : (r.attrs['bold'] == true && h == null ? Color.lerp(color, theme.colorScheme.onSurface, 0.35) : null),
                backgroundColor: _hex(r.attrs['background'])?.withValues(alpha: 0.5),
                fontFamily: r.attrs['code'] == true ? 'Consolas' : null,
              ),
            ),
      ];
      if (spans.isEmpty) {
        out.add(const SizedBox(height: 6));
        continue;
      }
      Widget text = Text.rich(TextSpan(style: style, children: spans));
      final list = b['list'];
      n = list == 'ordered' ? n + 1 : 0;
      final indent = ((b['indent'] as num?)?.toInt() ?? 0) * 18.0;
      if (list != null) {
        text = Padding(
          padding: EdgeInsets.only(left: indent, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: switch (list) {
                  'ordered' => Text('$n.', style: base.copyWith(fontWeight: FontWeight.w800, color: color)),
                  'checked' => Icon(Icons.check_box_rounded, size: 20, color: color),
                  'unchecked' => Icon(Icons.check_box_outline_blank_rounded, size: 20, color: color),
                  _ => Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  ),
                },
              ),
              Expanded(child: text),
            ],
          ),
        );
      } else if (b['blockquote'] == true) {
        text = Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          child: text,
        );
      } else if (h != null) {
        text = Padding(padding: EdgeInsets.only(top: h == 1 ? 4 : 18, bottom: 6), child: text);
      } else {
        text = Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: text);
      }
      out.add(text);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
  }
}

/// La fiche en grand, à lire (et à copier).
class FichePage extends StatelessWidget {
  const FichePage({super.key, required this.title, required this.markdown, required this.color, this.docLink});
  final String title;
  final String markdown;
  final Color color;
  final String? docLink;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title, overflow: TextOverflow.ellipsis),
      actions: [
        if (docLink != null)
          IconButton(
            tooltip: 'Ouvrir dans Google Docs',
            icon: const Icon(Icons.description_rounded),
            onPressed: () => Browser.open(docLink!),
          ),
        IconButton(
          tooltip: 'Copier la fiche',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: markdown));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fiche copiée')));
          },
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                child: FicheView(markdown: markdown, color: color),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
