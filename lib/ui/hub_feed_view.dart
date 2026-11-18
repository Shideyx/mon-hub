import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_feed.dart';
import '../core/hub_module.dart';
import 'motion.dart';

/// « Ton fil » à l'accueil : ce qui compte maintenant, relié entre les
/// modules (le cours qui arrive, le contrôle et sa fiche, la lecture en
/// cours, les messages…). Un clic ouvre le bon module.
class HubFeedStrip extends StatefulWidget {
  const HubFeedStrip({super.key, required this.controller, this.onOpen});
  final HubController controller;
  final ValueChanged<HubModule>? onOpen;

  @override
  State<HubFeedStrip> createState() => _HubFeedStripState();
}

class _HubFeedStripState extends State<HubFeedStrip> {
  HubFeedTicker? _ticker;
  Timer? _first;

  @override
  void initState() {
    super.initState();
    // Un peu après l'affichage de l'accueil (rien ne ralentit l'ouverture).
    _first = Timer(const Duration(milliseconds: 1500), _refresh);
    _ticker = HubFeedTicker(_refresh);
  }

  @override
  void dispose() {
    _first?.cancel();
    _ticker?.dispose();
    super.dispose();
  }

  void _refresh({bool force = false}) {
    final mods = widget.controller.enabled;
    final tools = {for (final m in mods) for (final t in m.tools) t.name: t};
    unawaited(
      HubFeed.instance
          .refresh(
            call: (name, args) async => tools[name]?.run(args),
            tools: tools.keys.toSet(),
            badges: {for (final m in mods) m.id: m.badge.value},
            names: {for (final m in mods) m.id: m.name},
            force: force,
          )
          .catchError((Object _) {}),
    );
  }

  HubModule? _module(String id) => widget.controller.enabled.where((m) => m.id == id).firstOrNull;

  void _open(FeedItem i) {
    final m = _module(i.moduleId);
    if (m == null) return;
    widget.onOpen != null
        ? widget.onOpen!(m)
        : Navigator.push(context, MaterialPageRoute(builder: (ctx) => m.buildPage(ctx)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: HubFeed.instance,
      builder: (context, _) {
        final items = [
          for (final i in HubFeed.instance.items)
            if (_module(i.moduleId) != null) i,
        ];
        return AnimatedSize(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: items.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 0, 16, 6),
                        child: Row(
                          children: [
                            Icon(Icons.bolt_rounded, size: 18, color: theme.colorScheme.primary),
                            const SizedBox(width: 6),
                            Text('Ton fil', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(width: 8),
                            Text(
                              'tes modules, ensemble',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 118,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          scrollDirection: Axis.horizontal,
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, n) => EnterAnimation(
                            key: ValueKey('feed-${items[n].id}'),
                            index: n,
                            step: 60,
                            offset: 14,
                            child: PressScale(
                              child: _FeedCard(
                                item: items[n],
                                module: _module(items[n].moduleId)!,
                                sources: [for (final id in items[n].from) ?_module(id)],
                                onTap: () => _open(items[n]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _FeedCard extends StatefulWidget {
  const _FeedCard({required this.item, required this.module, required this.sources, required this.onTap});
  final FeedItem item;
  final HubModule module;
  final List<HubModule> sources;
  final VoidCallback onTap;

  @override
  State<_FeedCard> createState() => _FeedCardState();
}

class _FeedCardState extends State<_FeedCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = widget.item;
    final c = widget.module.color;
    final urgent = i.priority >= 80;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: 268,
          transform: Matrix4.translationValues(0, hover ? -3 : 0, 0),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: theme.cardTheme.color ?? theme.colorScheme.surface,
            gradient: LinearGradient(
              colors: [c.withValues(alpha: hover ? 0.20 : 0.13), c.withValues(alpha: 0.03)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: c.withValues(alpha: urgent ? 0.7 : (hover ? 0.45 : 0.2)), width: urgent ? 1.6 : 1),
            boxShadow: [
              if (hover) BoxShadow(color: c.withValues(alpha: 0.22), blurRadius: 18, offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [c, Color.lerp(c, Colors.black, 0.3)!]),
                    ),
                    child: Icon(i.icon, color: Colors.white, size: 16),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      i.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Text(
                  i.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Row(
                children: [
                  // D'où vient l'info : on voit les modules qui se parlent.
                  for (final (n, s) in widget.sources.indexed) ...[
                    if (n > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(Icons.arrow_forward_rounded, size: 11, color: theme.colorScheme.onSurfaceVariant),
                      ),
                    Tooltip(message: s.name, child: Icon(s.icon, size: 14, color: s.color)),
                  ],
                  const Spacer(),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: theme.textTheme.labelMedium!.copyWith(color: c, fontWeight: hover ? FontWeight.w800 : FontWeight.w600),
                    child: Text(i.action),
                  ),
                  AnimatedPadding(
                    duration: const Duration(milliseconds: 200),
                    padding: EdgeInsets.only(left: hover ? 6 : 2),
                    child: Icon(Icons.chevron_right_rounded, size: 18, color: c),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
