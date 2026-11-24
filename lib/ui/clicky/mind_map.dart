import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../core/nav.dart';
import 'clicky.dart';

/// Une idée de la carte mentale.
class MindNode {
  MindNode(this.title, {this.detail = '', List<MindNode>? children}) : children = children ?? [];
  final String title;
  final String detail;
  final List<MindNode> children;
  bool open = false;
  MindNode? parent;
  int branch = 0;

  int get depth => parent == null ? 0 : parent!.depth + 1;

  /// En Markdown (pour un Google Doc ou des cartes de révision).
  String markdown([int level = 0]) => [
    if (level == 0) '# $title' else '${'  ' * (level - 1)}- **$title**${detail.isEmpty ? '' : ' : $detail'}',
    for (final c in children) c.markdown(level + 1),
  ].join('\n');
}

/// **Carte mentale animée** d'un cours ou d'un sujet : les branches se
/// déplient, on zoome, et Smily explique une branche à voix haute.
class MindMaps {
  MindMaps._();

  static String prompt(String input) {
    final course = input.trim().length > 240;
    return '${course ? 'À partir de ce cours' : 'Sur le sujet « ${input.trim()} »'}, fais une carte mentale de révision pour un lycéen.\n'
        'Réponds UNIQUEMENT avec un objet JSON :\n'
        '{"titre": "idée centrale (3 à 6 mots)", "enfants": [{"titre": "branche (2 à 5 mots)", "detail": "1 ou 2 phrases '
        'simples", "enfants": [{"titre": "…", "detail": "…", "enfants": [ … ]}]}]}\n'
        '4 à 7 branches, 2 à 5 idées par branche, 3 niveaux au plus. Des mots-clés courts, les définitions, dates et '
        'exemples importants.'
        '${course ? '\n\nLe cours :\n${input.length > 60000 ? input.substring(0, 60000) : input}' : ''}';
  }

  static MindNode? parse(String answer) {
    final a = answer.indexOf('{');
    final b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Object? j;
    try {
      j = jsonDecode(answer.substring(a, b + 1));
    } catch (_) {
      return null;
    }
    MindNode? node(Object? v, int depth) {
      if (v is! Map) return null;
      var t = '${v['titre'] ?? ''}'.trim();
      if (t.isEmpty) return null;
      if (t.length > 60) t = '${t.substring(0, 60)}…';
      var d = '${v['detail'] ?? ''}'.trim();
      if (d.length > 400) d = '${d.substring(0, 400)}…';
      final kids = depth >= 3 ? const [] : (v['enfants'] is List ? v['enfants'] as List : const []);
      return MindNode(t, detail: d, children: [for (final k in kids.take(8)) ?node(k, depth + 1)]);
    }

    final root = node(j, 0);
    if (root == null || root.children.isEmpty) return null;
    void link(MindNode n, int branch) {
      n.branch = branch;
      for (var i = 0; i < n.children.length; i++) {
        n.children[i].parent = n;
        link(n.children[i], n.parent == null ? i : branch);
      }
    }

    link(root, 0);
    return root;
  }

  /// Les positions des idées visibles : la racine au centre, chaque niveau
  /// sur un cercle plus grand, chaque branche dans sa part du cercle.
  static Map<MindNode, Offset> layout(MindNode root) {
    final out = <MindNode, Offset>{root: Offset.zero};
    void place(MindNode n, double from, double to) {
      if (!n.open || n.children.isEmpty) return;
      final step = (to - from) / n.children.length;
      for (var i = 0; i < n.children.length; i++) {
        final c = n.children[i];
        final a = from + step * (i + 0.5);
        final r = 240.0 + (c.depth - 1) * 200.0;
        out[c] = Offset(math.cos(a) * r, math.sin(a) * r);
        place(c, from + step * i, from + step * (i + 1));
      }
    }

    place(root, -math.pi / 2, 3 * math.pi / 2);
    return out;
  }

  static Future<MindNode> make(String input) async {
    final r = parse(
      await AiText.ask(prompt(input), system: 'Tu es un professeur clair. Tu réponds seulement en JSON valide.'),
    );
    if (r == null) throw 'Je n\'ai pas réussi à faire la carte. Essaie avec un sujet plus précis.';
    return r;
  }
}

/// La page de la carte mentale.
class MindMapPage extends StatefulWidget {
  const MindMapPage({super.key, this.input});
  final String? input;

  static Future<void> open({String? input}) async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(builder: (_) => MindMapPage(input: input)));
  }

  @override
  State<MindMapPage> createState() => _MindMapPageState();
}

class _MindMapPageState extends State<MindMapPage> with SingleTickerProviderStateMixin {
  late final _input = TextEditingController(text: widget.input ?? '');
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  final _view = TransformationController();
  MindNode? _root;
  MindNode? _selected;
  Map<MindNode, Offset> _from = {};
  Map<MindNode, Offset> _to = {};
  bool _busy = false;
  String? _error;

  static const _colors = [
    Color(0xFF7C5CFF),
    Color(0xFF0EA5E9),
    Color(0xFF16A34A),
    Color(0xFFEA580C),
    Color(0xFFE11D48),
    Color(0xFFCA8A04),
    Color(0xFF0D9488),
    Color(0xFFDB2777),
  ];
  static const _size = 2600.0;

  @override
  void initState() {
    super.initState();
    // Fin de l'animation : les idées repliées disparaissent pour de bon.
    _anim.addStatusListener((st) {
      if (st == AnimationStatus.completed && mounted) setState(() => _from = Map.of(_to));
    });
    if ((widget.input ?? '').trim().isNotEmpty) unawaited(_make());
  }

  @override
  void dispose() {
    _anim.dispose();
    _input.dispose();
    _view.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await MindMaps.make(text);
      if (!mounted) return;
      _root = r;
      _selected = r;
      _from = {r: Offset.zero};
      _to = MindMaps.layout(r);
      setState(() {});
      _center();
      // Les branches sortent du centre.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _toggle(r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _center() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject() as RenderBox?;
      final w = box?.size.width ?? 1000;
      final h = (box?.size.height ?? 700) - 140;
      const scale = 0.78;
      _view.value = Matrix4.identity()
        ..translateByDouble(w / 2 - _size / 2 * scale, h / 2 - _size / 2 * scale + 40, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    });
  }

  Offset _pos(MindNode n) {
    final t = Curves.easeOutBack.transform(_anim.value);
    final to = _to[n] ?? (n.parent == null ? Offset.zero : _pos(n.parent!));
    final from = _from[n] ?? (n.parent == null ? Offset.zero : (_from[n.parent!] ?? _to[n.parent!] ?? Offset.zero));
    return Offset.lerp(from, to, t)!;
  }

  void _toggle(MindNode n) {
    // Les positions de maintenant deviennent le départ de l'animation.
    _from = {
      for (final e in {..._from.keys, ..._to.keys}) e: _pos(e),
    };
    n.open = !n.open;
    if (!n.open) {
      void close(MindNode x) {
        x.open = false;
        x.children.forEach(close);
      }

      n.children.forEach(close);
    }
    _to = MindMaps.layout(_root!);
    _selected = n;
    _anim.forward(from: 0);
    setState(() {});
  }

  Future<void> _explain(MindNode n) async {
    var text = n.detail;
    try {
      text = await AiText.ask(
        'Explique en 3 phrases simples, comme à l\'oral, « ${n.title} » dans le cadre de « ${_root!.title} »'
        '${n.detail.isEmpty ? '' : ' (${n.detail})'}.',
      );
    } catch (_) {}
    if (text.isNotEmpty) await ClickyController.instance.speak(text, force: true);
  }

  Future<void> _tool(String name, Map<String, dynamic> args, String done) async {
    try {
      final t = ClickyController.instance.hubTools.where((t) => t.name == name).firstOrNull;
      if (t == null) throw 'Active le module concerné (Réglages → Modules)';
      await t.run(args);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Iterable<MindNode> _shown() sync* {
    final all = {..._from.keys, ..._to.keys};
    yield* all;
  }

  Widget _map() {
    final root = _root!;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final nodes = _shown().toList()..sort((a, b) => b.depth.compareTo(a.depth));
        final c = const Offset(_size / 2, _size / 2);
        return InteractiveViewer(
          transformationController: _view,
          constrained: false,
          minScale: 0.2,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(800),
          child: SizedBox(
            width: _size,
            height: _size,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _Links([
                      for (final n in nodes)
                        if (n.parent != null)
                          (c + _pos(n.parent!), c + _pos(n), _colors[n.branch % _colors.length], n.depth),
                    ]),
                  ),
                ),
                for (final n in nodes)
                  Positioned(
                    left: c.dx + _pos(n).dx - 90,
                    top: c.dy + _pos(n).dy - 26,
                    width: 180,
                    height: 52,
                    child: Opacity(
                      opacity: _to.containsKey(n) ? 1 : (1 - _anim.value).clamp(0.0, 1.0),
                      child: Center(child: _chip(n, root)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _chip(MindNode n, MindNode root) {
    final color = n == root ? const Color(0xFF7C5CFF) : _colors[n.branch % _colors.length];
    final selected = n == _selected;
    return Material(
      color: n.depth <= 1 ? color : color.withValues(alpha: 0.14),
      elevation: selected ? 8 : 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(n == root ? 26 : 16),
        side: BorderSide(color: color, width: selected ? 3 : 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => n.children.isEmpty ? setState(() => _selected = n) : _toggle(n),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: n == root ? 18 : 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  n.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: n.depth <= 1 ? Colors.white : null,
                    fontWeight: n.depth <= 1 ? FontWeight.w800 : FontWeight.w600,
                    fontSize: n == root ? 16 : 13,
                  ),
                ),
              ),
              if (n.children.isNotEmpty && n != root) ...[
                const SizedBox(width: 4),
                Icon(
                  n.open ? Icons.remove_circle_outline_rounded : Icons.add_circle_outline_rounded,
                  size: 16,
                  color: n.depth <= 1 ? Colors.white : color,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = _root;
    final sel = _selected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Carte mentale'),
        actions: [
          if (root != null) ...[
            IconButton(tooltip: 'Recentrer', icon: const Icon(Icons.center_focus_strong_rounded), onPressed: _center),
            IconButton(
              tooltip: 'En faire un Google Doc',
              icon: const Icon(Icons.description_rounded),
              onPressed: () => _tool('doc_creer', {
                'titre': 'Carte mentale — ${root.title}',
                'contenu': root.markdown(),
              }, 'Google Doc créé ✓'),
            ),
            IconButton(
              tooltip: 'Faire des cartes de révision',
              icon: const Icon(Icons.style_rounded),
              onPressed: () => _tool('revision_generer', {
                'paquet': '🧠 ${root.title}',
                'texte': root.markdown(),
                'nombre': 15,
              }, 'Cartes ajoutées dans Révisions ✓'),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Un sujet (« la photosynthèse ») ou colle ton cours',
                      prefixIcon: Icon(Icons.hub_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _busy ? null : _make, child: Text(_busy ? '…' : 'Faire la carte')),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          Expanded(
            child: root == null
                ? Center(
                    child: _busy
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Je dessine la carte…')],
                          )
                        : const Text(
                            'Écris un sujet ou colle un cours : la carte se dessine ici, branche par branche.',
                          ),
                  )
                : ClipRect(child: _map()),
          ),
          if (sel != null && root != null)
            Material(
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(sel.title, style: theme.textTheme.titleMedium),
                          if (sel.detail.isNotEmpty) Text(sel.detail),
                          if (sel.children.isNotEmpty && !sel.open)
                            Text(
                              'Touche-la pour voir ses ${sel.children.length} idées.',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Smily explique',
                      onPressed: () => _explain(sel),
                      icon: const Icon(Icons.record_voice_over_rounded),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Links extends CustomPainter {
  _Links(this.links);
  final List<(Offset, Offset, Color, int)> links;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (a, b, color, depth) in links) {
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final bend = Offset(-(b.dy - a.dy), b.dx - a.dx) * 0.12;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(mid.dx + bend.dx, mid.dy + bend.dy, b.dx, b.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = depth <= 1 ? 6 : (depth == 2 ? 3.5 : 2),
      );
    }
  }

  @override
  bool shouldRepaint(_Links old) => true;
}
