import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Le « tableau » de Clicky : quand tu ne comprends pas, ou quand tu veux
/// apprendre quelque chose, Clicky dessine son explication (étapes, schéma
/// fléché, cycle, comparaison, frise, graphique, formule, vocabulaire, à
/// retenir) et peut finir par un petit quiz.
///
/// L'IA l'écrit en JSON entre `[TABLEAU]` et `[/TABLEAU]`, après sa réponse
/// orale ; Mon Hub le dessine lui-même (rien n'est exécuté).
class ClickyBoard {
  const ClickyBoard({required this.title, required this.blocks});

  final String title;
  final List<BoardBlock> blocks;

  static final _re = RegExp(r'\[TABLEAU\]([\s\S]*?)\[/TABLEAU\]', caseSensitive: false);
  static final _open = RegExp(r'\[TABLEAU\][\s\S]*$', caseSensitive: false);

  /// Le tableau est en train de s'écrire (balise ouverte, pas encore fermée).
  static bool writing(String raw) => _open.hasMatch(raw.replaceAll(_re, ''));

  /// Retire les tableaux (même à moitié écrits) du texte affiché.
  static String strip(String raw) =>
      raw.replaceAll(_re, ' ').replaceFirst(_open, '').replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();

  /// Sépare la réponse orale et le tableau (null s'il n'y en a pas ou s'il
  /// est illisible).
  static (String, ClickyBoard?) extract(String raw) {
    final m = _re.allMatches(raw).lastOrNull;
    final text = strip(raw);
    if (m == null) return (text, null);
    return (text, parse(m.group(1)!));
  }

  static ClickyBoard? parse(String src) {
    var s = src.trim();
    // Parfois entouré de ```json … ```.
    s = s.replaceFirst(RegExp(r'^```(?:json)?\s*'), '').replaceFirst(RegExp(r'\s*```$'), '');
    Object? d;
    try {
      d = jsonDecode(s);
    } catch (_) {
      final a = s.indexOf('{'), b = s.lastIndexOf('}');
      if (a < 0 || b <= a) return null;
      try {
        d = jsonDecode(s.substring(a, b + 1));
      } catch (_) {
        return null;
      }
    }
    if (d is List) d = <String, Object?>{'blocs': d};
    if (d is! Map) return null;
    final rawBlocks = d['blocs'] ?? d['blocks'] ?? const [];
    final blocks = <BoardBlock>[
      if (rawBlocks is List)
        for (final b in rawBlocks)
          if (b is Map && b['type'] != null) BoardBlock('${b['type']}'.toLowerCase(), b.cast()),
    ];
    if (blocks.isEmpty) return null;
    return ClickyBoard(title: str(d['titre'] ?? d['title']), blocks: blocks);
  }

  /// Titre lisible (pour la mémoire de Clicky).
  String get summary => title.isNotEmpty ? title : 'tableau visuel';

  bool get hasQuiz => blocks.any((b) => b.type == 'quiz');
}

class BoardBlock {
  const BoardBlock(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;

  String s(String k) => str(data[k]);
  List<dynamic> l(String k) => data[k] is List ? data[k] as List : const [];
}

String str(Object? v) => v == null ? '' : (v is String ? v : '$v').trim();

/// Un schéma : nœuds et flèches (avec légende), en étages ou en cycle.
class SchemaGraph {
  SchemaGraph(this.nodes, this.edges, {this.cycle = false});

  final List<String> nodes;
  final List<(int, int, String)> edges;
  final bool cycle;

  factory SchemaGraph.from(BoardBlock b) {
    final nodes = <String>[];
    for (final n in b.l('noeuds')) {
      final label = n is Map ? str(n['texte'] ?? n['label'] ?? n['nom']) : str(n);
      if (label.isNotEmpty && nodes.length < 12) nodes.add(label);
    }
    int? idx(Object? v) {
      if (v is num) {
        final i = v.toInt();
        return i >= 0 && i < nodes.length ? i : null;
      }
      final t = str(v);
      final n = int.tryParse(t);
      if (n != null) return n >= 0 && n < nodes.length ? n : null;
      final i = nodes.indexWhere((x) => x.toLowerCase() == t.toLowerCase());
      if (i >= 0) return i;
      if (t.isNotEmpty && nodes.length < 12) {
        nodes.add(t);
        return nodes.length - 1;
      }
      return null;
    }

    final edges = <(int, int, String)>[];
    for (final e in b.l('liens')) {
      Object? a, z, label;
      if (e is List && e.length >= 2) {
        a = e[0];
        z = e[1];
        label = e.length > 2 ? e[2] : null;
      } else if (e is Map) {
        a = e['de'] ?? e['from'];
        z = e['vers'] ?? e['to'];
        label = e['texte'] ?? e['label'];
      } else {
        continue;
      }
      final i = idx(a), j = idx(z);
      if (i != null && j != null && i != j) edges.add((i, j, str(label)));
    }
    final forme = b.s('forme').toLowerCase();
    final cycle = forme.startsWith('cycl') || forme == 'cercle';
    // Pas de flèches : on enchaîne les nœuds dans l'ordre.
    if (edges.isEmpty && nodes.length > 1) {
      for (var i = 0; i + 1 < nodes.length; i++) {
        edges.add((i, i + 1, ''));
      }
      if (cycle) edges.add((nodes.length - 1, 0, ''));
    }
    return SchemaGraph(nodes, edges, cycle: cycle);
  }

  /// Étage de chaque nœud (0 = en haut), en suivant les flèches.
  List<int> layers() {
    final n = nodes.length;
    final indeg = List.filled(n, 0);
    for (final (_, j, _) in edges) {
      indeg[j]++;
    }
    final order = <int>[];
    final queue = [
      for (var i = 0; i < n; i++)
        if (indeg[i] == 0) i,
    ];
    final seen = List.filled(n, false);
    final deg = [...indeg];
    while (order.length < n) {
      if (queue.isEmpty) {
        // Boucle : on reprend au premier nœud pas encore placé.
        final next = List.generate(n, (i) => i).firstWhere((i) => !seen[i]);
        queue.add(next);
      }
      final v = queue.removeAt(0);
      if (seen[v]) continue;
      seen[v] = true;
      order.add(v);
      for (final (i, j, _) in edges) {
        if (i == v && !seen[j] && --deg[j] == 0) queue.add(j);
      }
    }
    final pos = List.filled(n, 0);
    for (var k = 0; k < order.length; k++) {
      pos[order[k]] = k;
    }
    final depth = List.filled(n, 0);
    for (final v in order) {
      for (final (i, j, _) in edges) {
        if (i == v && pos[j] > pos[v]) depth[j] = math.max(depth[j], depth[v] + 1);
      }
    }
    return depth;
  }
}

// ---------------------------------------------------------------------------
// Dessin
// ---------------------------------------------------------------------------

const _blue = Color(0xFF3B82F6);

/// Le tableau, en carte : titre, blocs, et boutons pour aller plus loin.
class ClickyBoardView extends StatelessWidget {
  const ClickyBoardView({
    super.key,
    required this.board,
    required this.onClose,
    required this.onAsk,
    this.busy = false,
  });

  final ClickyBoard board;
  final VoidCallback onClose;

  /// Pose une nouvelle question à Clicky (boutons « Je n'ai pas compris »…).
  final void Function(String question) onAsk;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final topic = board.title.isEmpty ? 'ça' : '« ${board.title} »';
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(18),
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _blue,
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            child: Row(
              children: [
                const Icon(Icons.draw_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    board.title.isEmpty ? 'Le tableau de Clicky' : board.title,
                    style: text.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer le tableau',
                  visualDensity: VisualDensity.compact,
                  color: Colors.white,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Flexible(
            // Façon tableau dessiné à la main : papier, écriture manuscrite,
            // et chaque bloc qui se dessine l'un après l'autre.
            child: CustomPaint(
              painter: _PaperPainter(dark: Theme.of(context).brightness == Brightness.dark),
              child: Theme(
                data: Theme.of(context).copyWith(
                  textTheme: Theme.of(context).textTheme.apply(
                    fontFamily: sketchFont,
                    fontFamilyFallback: sketchFallback,
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, b) in board.blocks.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: DrawIn(
                            delay: Duration(milliseconds: 250 + i * 700),
                            child: BoardBlockView(block: b, onAsk: onAsk),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Chip(
                  icon: Icons.help_outline_rounded,
                  label: 'Je n\'ai pas compris',
                  onTap: busy
                      ? null
                      : () => onAsk(
                          'Je n\'ai pas compris $topic. Réexplique-moi autrement, plus simplement, '
                          'avec une comparaison de la vie de tous les jours et un nouveau tableau.',
                        ),
                ),
                _Chip(
                  icon: Icons.lightbulb_outline_rounded,
                  label: 'Un autre exemple',
                  onTap: busy
                      ? null
                      : () => onAsk(
                          'Donne-moi un autre exemple résolu pas à pas sur $topic, avec un tableau.',
                        ),
                ),
                _Chip(
                  icon: Icons.quiz_outlined,
                  label: 'Teste-moi',
                  onTap: busy
                      ? null
                      : () => onAsk(
                          'Pose-moi un petit quiz de 3 questions sur $topic pour vérifier que '
                          'j\'ai compris, dans un tableau.',
                        ),
                ),
                _Chip(
                  icon: Icons.trending_up_rounded,
                  label: 'Plus loin',
                  onTap: busy
                      ? null
                      : () => onAsk(
                          'J\'ai compris $topic ! Apprends-moi la suite, un cran plus loin, avec un tableau.',
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 16),
    label: Text(label),
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
  );
}

/// Un bloc du tableau.
class BoardBlockView extends StatelessWidget {
  const BoardBlockView({super.key, required this.block, required this.onAsk});
  final BoardBlock block;
  final void Function(String question) onAsk;

  @override
  Widget build(BuildContext context) {
    final b = block;
    return switch (b.type) {
      'etapes' || 'steps' => _Steps(b),
      'schema' || 'schéma' || 'cycle' => _Schema(b),
      'comparaison' || 'tableau' || 'table' => _Compare(b),
      'frise' || 'chronologie' || 'timeline' => _Timeline(b),
      'graphique' || 'chart' => _Bars(b),
      'formule' => _Formula(b),
      'exemple' => _Note(b, icon: Icons.edit_note_rounded, label: 'Exemple', tint: Colors.teal),
      'retenir' || 'a_retenir' => _Remember(b),
      'vocabulaire' || 'mots' => _Vocab(b),
      'quiz' => _Quiz(b, onAsk: onAsk),
      _ => _Note(b),
    };
  }
}

Widget _heading(BuildContext context, String t) => t.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          t,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      );

class _Note extends StatelessWidget {
  const _Note(this.b, {this.icon, this.label, this.tint});
  final BoardBlock b;
  final IconData? icon;
  final String? label;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = b.s('texte').isNotEmpty ? b.s('texte') : b.s('text');
    final title = b.s('titre').isNotEmpty ? b.s('titre') : (label ?? '');
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: tint), const SizedBox(width: 6)],
              Expanded(child: _heading(context, title)),
            ],
          ),
        Text(body, style: text.bodyMedium?.copyWith(height: 1.4)),
      ],
    );
    if (tint == null) return content;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint!.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint!.withValues(alpha: 0.35)),
      ),
      child: content,
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final items = b.l('items');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre')),
        for (var i = 0; i < items.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 30,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: _blue,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (i < items.length - 1)
                        Expanded(child: Container(width: 2, color: _blue.withValues(alpha: 0.35))),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12, top: 3),
                    child: () {
                      final it = items[i];
                      final t = it is Map ? str(it['titre']) : '';
                      final d = it is Map ? str(it['texte']) : str(it);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (t.isNotEmpty)
                            Text(t, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                          if (d.isNotEmpty)
                            Text(
                              d,
                              style: text.bodyMedium?.copyWith(
                                height: 1.35,
                                color: t.isEmpty ? null : scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      );
                    }(),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Schema extends StatelessWidget {
  const _Schema(this.b);
  final BoardBlock b;

  static const nodeH = 50.0;
  static const rowGap = 46.0;

  @override
  Widget build(BuildContext context) {
    final g = SchemaGraph.from(
      b.type == 'cycle' ? BoardBlock(b.type, {...b.data, 'forme': 'cycle'}) : b,
    );
    if (g.nodes.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre')),
        LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth.isFinite ? box.maxWidth : 400.0;
            final (rects, height) = g.cycle && g.nodes.length > 2 ? _cycle(g, w) : _layered(g, w);
            return SizedBox(
              width: w,
              height: height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EdgePainter(
                        g: g,
                        rects: rects,
                        color: scheme.onSurfaceVariant,
                        labelBg: scheme.surface,
                        labelStyle: DefaultTextStyle.of(context).style.merge(
                          TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        center: g.cycle ? Offset(w / 2, height / 2) : null,
                      ),
                    ),
                  ),
                  for (var i = 0; i < g.nodes.length; i++)
                    Positioned.fromRect(
                      rect: rects[i],
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(_blue.withValues(alpha: 0.12), scheme.surface),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _blue, width: 1.5),
                        ),
                        child: Text(
                          g.nodes[i],
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  (List<Rect>, double) _layered(SchemaGraph g, double w) {
    final depth = g.layers();
    final rows = depth.fold(0, math.max) + 1;
    final perRow = List.generate(
      rows,
      (r) => [
        for (var i = 0; i < depth.length; i++)
          if (depth[i] == r) i,
      ],
    );
    final widest = perRow.map((r) => r.length).fold(1, math.max);
    const gap = 10.0;
    final nodeW = math.min(170.0, (w - gap * (widest - 1)) / widest);
    final rects = List<Rect>.filled(g.nodes.length, Rect.zero);
    for (var r = 0; r < rows; r++) {
      final ids = perRow[r];
      final total = ids.length * nodeW + (ids.length - 1) * gap;
      var x = (w - total) / 2;
      final y = r * (nodeH + rowGap);
      for (final id in ids) {
        rects[id] = Rect.fromLTWH(x, y, nodeW, nodeH);
        x += nodeW + gap;
      }
    }
    return (rects, rows * nodeH + (rows - 1) * rowGap + 4);
  }

  (List<Rect>, double) _cycle(SchemaGraph g, double w) {
    final n = g.nodes.length;
    final nodeW = math.min(130.0, w * 0.34);
    final r = math.min((w - nodeW) / 2 - 4, 50.0 + n * 18);
    final h = 2 * r + nodeH + 12;
    final c = Offset(w / 2, h / 2);
    return (
      [
        for (var i = 0; i < n; i++)
          Rect.fromCenter(
            center: c + Offset(math.sin(2 * math.pi * i / n), -math.cos(2 * math.pi * i / n)) * r,
            width: nodeW,
            height: nodeH,
          ),
      ],
      h,
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.g,
    required this.rects,
    required this.color,
    required this.labelBg,
    required this.labelStyle,
    this.center,
  });

  final SchemaGraph g;
  final List<Rect> rects;
  final Color color;
  final Color labelBg;
  final TextStyle labelStyle;
  final Offset? center;

  /// Point où la droite centre → [toward] sort du rectangle.
  static Offset _exit(Rect r, Offset toward) {
    final c = r.center;
    final d = toward - c;
    if (d.distance < 0.001) return c;
    final tx = d.dx.abs() < 0.001 ? double.infinity : (r.width / 2 + 3) / d.dx.abs();
    final ty = d.dy.abs() < 0.001 ? double.infinity : (r.height / 2 + 3) / d.dy.abs();
    return c + d * math.min(tx, ty);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final head = Paint()..color = color;
    final depth = center == null ? g.layers() : null;
    final labels = <(Offset, String)>[];
    for (final (i, j, label) in g.edges) {
      final a = rects[i], b = rects[j];
      // Courbure : vers l'extérieur pour un cycle, sur le côté pour une
      // flèche qui remonte ou reste au même étage.
      var bend = 0.0;
      if (center != null) {
        bend = 22;
      } else if (depth != null && depth[j] <= depth[i]) {
        bend = 46;
      }
      final p0 = _exit(a, b.center), p1 = _exit(b, a.center);
      final mid = (p0 + p1) / 2;
      final dir = p1 - p0;
      final len = dir.distance;
      if (len < 4) continue;
      var normal = Offset(-dir.dy, dir.dx) / len;
      if (center != null && (mid + normal - center!).distance < (mid - center!).distance) {
        normal = -normal;
      }
      if (center == null && normal.dx < 0) normal = -normal;
      final ctrl = mid + normal * bend;
      final path = Path()
        ..moveTo(p0.dx, p0.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, p1.dx, p1.dy);
      canvas.drawPath(path, line);
      // Pointe de flèche, dans le sens de la courbe à l'arrivée.
      final t = p1 - ctrl;
      final tl = t.distance;
      if (tl > 0.001) {
        final u = t / tl;
        final nrm = Offset(-u.dy, u.dx);
        final tip = p1;
        final base = tip - u * 9;
        canvas.drawPath(
          Path()
            ..moveTo(tip.dx, tip.dy)
            ..lineTo(base.dx + nrm.dx * 5, base.dy + nrm.dy * 5)
            ..lineTo(base.dx - nrm.dx * 5, base.dy - nrm.dy * 5)
            ..close(),
          head,
        );
      }
      if (label.isNotEmpty) labels.add((mid + normal * bend * 0.5, label));
    }
    for (final (at, label) in labels) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
        textAlign: TextAlign.center,
      )..layout(maxWidth: 130);
      final r = Rect.fromCenter(center: at, width: tp.width + 10, height: tp.height + 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(8)),
        Paint()..color = labelBg.withValues(alpha: 0.92),
      );
      tp.paint(canvas, r.topLeft + const Offset(5, 2));
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.g != g || old.color != color || old.rects != rects;
}

class _Compare extends StatelessWidget {
  const _Compare(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cols = [for (final c in b.l('colonnes')) str(c)];
    final rows = [
      for (final r in b.l('lignes'))
        if (r is List) [for (final c in r) str(c)],
    ];
    final n = [cols.length, ...rows.map((r) => r.length)].fold(0, math.max);
    if (n == 0) return const SizedBox.shrink();
    List<String> pad(List<String> r) => [...r, for (var i = r.length; i < n; i++) ''];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre')),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Table(
            border: TableBorder.all(color: scheme.outlineVariant),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              if (cols.isNotEmpty)
                TableRow(
                  decoration: const BoxDecoration(color: _blue),
                  children: [
                    for (final c in pad(cols))
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          c,
                          style: text.labelLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                    color: i.isOdd ? scheme.surfaceContainerHighest.withValues(alpha: 0.5) : null,
                  ),
                  children: [
                    for (var k = 0; k < n; k++)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          pad(rows[i])[k],
                          style: k == 0
                              ? text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                              : text.bodyMedium,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final items = b.l('items');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre')),
        for (var i = 0; i < items.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 84,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Text(
                      items[i] is Map ? str((items[i] as Map)['date']) : '',
                      textAlign: TextAlign.right,
                      style: text.labelLarge?.copyWith(color: _blue, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                SizedBox(
                  width: 16,
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(color: _blue, shape: BoxShape.circle),
                      ),
                      if (i < items.length - 1)
                        Expanded(child: Container(width: 2, color: _blue.withValues(alpha: 0.35))),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      items[i] is Map ? str((items[i] as Map)['texte']) : str(items[i]),
                      style: text.bodyMedium?.copyWith(height: 1.35),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars(this.b);
  final BoardBlock b;

  static String _fmt(double v) {
    final s = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.replaceAll('.', ',');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unit = b.s('unite');
    final values = <(String, double)>[
      for (final v in b.l('valeurs'))
        if (v is Map)
          (
            str(v['label'] ?? v['nom']),
            (v['valeur'] is num ? v['valeur'] as num : num.tryParse(str(v['valeur'])) ?? 0)
                .toDouble(),
          ),
    ];
    if (values.isEmpty) return const SizedBox.shrink();
    final max = values.map((v) => v.$2.abs()).fold(0.0, math.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre')),
        for (final (label, v) in values)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(
                    label,
                    style: text.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) => Row(
                      children: [
                        Container(
                          height: 18,
                          width: math.max(2, (box.maxWidth - 70) * (max == 0 ? 0 : v.abs() / max)),
                          decoration: BoxDecoration(
                            color: _blue,
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${_fmt(v)}${unit.isEmpty ? '' : ' $unit'}',
                            style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Formula extends StatelessWidget {
  const _Formula(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final legend = b.l('legende');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, b.s('titre')),
          Text(
            b.s('formule'),
            textAlign: TextAlign.center,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: _blue),
          ),
          if (legend.isNotEmpty) const SizedBox(height: 8),
          for (final l in legend)
            if (l is Map)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${str(l['terme'])}  ',
                        style: const TextStyle(fontWeight: FontWeight.w700, color: _blue),
                      ),
                      TextSpan(text: str(l['sens'])),
                    ],
                  ),
                  style: text.bodyMedium,
                ),
              ),
        ],
      ),
    );
  }
}

class _Remember extends StatelessWidget {
  const _Remember(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const amber = Color(0xFFF59E0B);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: amber.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.push_pin_rounded, size: 18, color: amber),
              const SizedBox(width: 6),
              Expanded(child: _heading(context, b.s('titre').isEmpty ? 'À retenir' : b.s('titre'))),
            ],
          ),
          for (final it in b.l('items'))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.check_rounded, size: 16, color: amber),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(str(it), style: text.bodyMedium?.copyWith(height: 1.35))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Vocab extends StatelessWidget {
  const _Vocab(this.b);
  final BoardBlock b;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, b.s('titre').isEmpty ? 'Vocabulaire' : b.s('titre')),
        for (final it in b.l('items'))
          if (it is Map)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      str(it['mot']),
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: _blue),
                    ),
                  ),
                  Expanded(flex: 3, child: Text(str(it['sens']), style: text.bodyMedium)),
                ],
              ),
            ),
      ],
    );
  }
}

/// Une question à choix : on clique, Clicky dit si c'est juste et pourquoi.
class _Quiz extends StatefulWidget {
  const _Quiz(this.b, {required this.onAsk});
  final BoardBlock b;
  final void Function(String question) onAsk;

  @override
  State<_Quiz> createState() => _QuizState();
}

class _QuizState extends State<_Quiz> {
  int? picked;

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final choices = [for (final c in b.l('choix')) str(c)];
    final rep = b.data['reponse'];
    final answer = rep is num
        ? rep.toInt()
        : int.tryParse(str(rep)) ?? choices.indexWhere((c) => c == str(rep));
    final done = picked != null;
    final right = done && picked == answer;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _blue.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.quiz_rounded, size: 18, color: _blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  b.s('question'),
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < choices.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  backgroundColor: !done
                      ? null
                      : i == answer
                      ? Colors.green.withValues(alpha: 0.15)
                      : i == picked
                      ? Colors.red.withValues(alpha: 0.12)
                      : null,
                  side: BorderSide(
                    color: !done
                        ? scheme.outline
                        : i == answer
                        ? Colors.green
                        : i == picked
                        ? Colors.red
                        : scheme.outlineVariant,
                  ),
                ),
                onPressed: done ? null : () => setState(() => picked = i),
                child: Row(
                  children: [
                    Text(
                      '${String.fromCharCode(65 + i)}.  ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Expanded(
                      child: Text(choices[i], style: TextStyle(color: scheme.onSurface)),
                    ),
                    if (done && i == answer)
                      const Icon(Icons.check_circle_rounded, color: Colors.green, size: 18)
                    else if (done && i == picked)
                      const Icon(Icons.cancel_rounded, color: Colors.red, size: 18),
                  ],
                ),
              ),
            ),
          if (done) ...[
            Text(
              right ? 'Bravo, c\'est juste !' : 'Pas tout à fait…',
              style: text.titleSmall?.copyWith(
                color: right ? Colors.green : Colors.red,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (b.s('explication').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(b.s('explication'), style: text.bodyMedium?.copyWith(height: 1.35)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 4,
                children: [
                  if (!right)
                    TextButton(
                      onPressed: () => widget.onAsk(
                        'Au quiz « ${b.s('question')} », j\'ai répondu « ${choices[picked!]} » '
                        'au lieu de « ${answer >= 0 && answer < choices.length ? choices[answer] : '?'} ». '
                        'Explique-moi mon erreur simplement, avec un tableau.',
                      ),
                      child: const Text('Pourquoi ?'),
                    ),
                  TextButton(
                    onPressed: () => setState(() => picked = null),
                    child: const Text('Recommencer'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}


/// Écriture « à la main » (polices installées avec Windows, puis Mac).
const sketchFont = 'Segoe Print';
const sketchFallback = ['Ink Free', 'Comic Sans MS', 'Bradley Hand', 'Chalkboard SE', 'Noteworthy'];

/// Un élément qui « se dessine » : il apparaît après [delay], comme si un
/// crayon le traçait de gauche à droite.
class DrawIn extends StatefulWidget {
  const DrawIn({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  State<DrawIn> createState() => _DrawInState();
}

class _DrawInState extends State<DrawIn> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.delay, () {
      if (mounted) _a.forward();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    child: widget.child,
    builder: (context, child) {
      final t = Curves.easeOutCubic.transform(_a.value);
      return Opacity(
        opacity: t,
        child: ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => LinearGradient(
                colors: const [Colors.black, Colors.black, Colors.transparent],
                stops: [0, t, (t + 0.08).clamp(0.0, 1.0)],
              ).createShader(r),
              child: Transform.translate(offset: Offset(0, (1 - t) * 6), child: child),
            ),
          ),
        ),
      );
    },
  );
}

/// Papier légèrement quadrillé (ardoise en mode sombre).
class _PaperPainter extends CustomPainter {
  _PaperPainter({required this.dark});
  final bool dark;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = dark ? const Color(0xFF1F2522) : const Color(0xFFFFFDF6));
    final line = Paint()
      ..color = (dark ? Colors.white : const Color(0xFF7FA7D9)).withValues(alpha: dark ? 0.05 : 0.12)
      ..strokeWidth = 1;
    for (var y = 22.0; y < s.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(s.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_PaperPainter old) => old.dark != dark;
}
