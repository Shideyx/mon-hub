import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/custom_modules.dart';
import '../core/desktop_widgets.dart';
import '../core/session.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import 'add_module.dart';
import 'ar_page.dart';
import 'hub_feed_view.dart';
import 'notifications_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'clicky/win.dart';
import 'motion.dart';
import 'widgets.dart';
import '../core/freeze_watch.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller, required this.notifications, this.onOpen});

  final HubController controller;
  final NotificationCenter notifications;

  /// Ouvre la section d'un module (fourni par le squelette de l'appli).
  final ValueChanged<HubModule>? onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([controller, DesktopWidgets.instance]),
        builder: (context, _) {
          final desk = DesktopWidgets.instance;
          final all = controller.enabled;
          // Les widgets détachés vivent sur le bureau, pas dans l'accueil.
          final modules = [
            for (final m in all)
              if (!desk.isDetached(m.id)) m,
          ];
          final away = [
            for (final m in all)
              if (desk.isDetached(m.id)) m,
          ];
          return RefreshIndicator(
            onRefresh: notifications.pollNow,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: EnterAnimation(
                    offset: 10,
                    child: _Header(controller: controller, notifications: notifications, modules: all),
                  ),
                ),
                // Ce qui compte maintenant, relié entre les modules.
                SliverToBoxAdapter(
                  child: HubFeedStrip(controller: controller, onOpen: onOpen),
                ),
                if (away.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Sur le bureau :', style: Theme.of(context).textTheme.bodySmall),
                          for (final m in away)
                            InputChip(
                              avatar: Icon(m.icon, size: 16, color: m.color),
                              label: Text(m.name),
                              tooltip: 'Afficher la fenêtre',
                              onPressed: () => desk.launch(m.id),
                              deleteIcon: const Icon(Icons.close_fullscreen_rounded, size: 16),
                              deleteButtonTooltipMessage: 'Remettre dans Mon Hub',
                              onDeleted: () => desk.attach(m.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (modules.isEmpty)
                  const SliverFillRemaining(child: EmptyHint('Aucun module actif. Active-en dans les réglages.'))
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 440,
                        mainAxisExtent: 268,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                      ),
                      // La dernière carte : « + Ajouter un module ».
                      itemCount: modules.length + 1,
                      // Les cartes arrivent en cascade et s'enfoncent quand on appuie.
                      itemBuilder: (context, i) => i == modules.length
                          ? EnterAnimation(
                              key: const ValueKey('enter-add'),
                              index: i + 1,
                              child: AddModuleCard(controller: controller),
                            )
                          : EnterAnimation(
                              key: ValueKey('enter-${modules[i].id}'),
                              index: i + 1,
                              child: PressScale(
                                scale: 0.975,
                                child: ModuleCard(
                                  module: modules[i],
                                  onOpen: onOpen,
                                  onRemove: CustomModules.isCustom(modules[i].id)
                                      ? () async {
                                          final m = modules[i];
                                          final ok = await showDialog<bool>(
                                            context: context,
                                            builder: (c) => AlertDialog(
                                              title: Text('Retirer « ${m.name} » ?'),
                                              content: const Text(
                                                'Le module disparaît de ton accueil. Tu pourras le rajouter quand tu veux.',
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.pop(c, false),
                                                  child: const Text('Annuler'),
                                                ),
                                                FilledButton(
                                                  onPressed: () => Navigator.pop(c, true),
                                                  child: const Text('Retirer'),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (ok != true) return;
                                          await CustomModules.remove(m.id);
                                          controller.remove(m.id);
                                        }
                                      : null,
                                  // Glisser une carte sur une autre : elles échangent leur place.
                                  onDropped: (dragged) {
                                    final order = controller.ordered.map((m) => m.id).toList();
                                    final from = order.indexOf(dragged.id);
                                    final to = order.indexOf(modules[i].id);
                                    if (from >= 0 && to >= 0 && from != to) controller.reorder(from, to);
                                  },
                                ),
                              ),
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.notifications, required this.modules});

  final HubController controller;
  final NotificationCenter notifications;
  final List<HubModule> modules;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5 || h >= 18) return 'Bonsoir';
    return 'Bonjour';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final userName = ModuleStore.prefs.getString('hub.name') ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFF6D4AFF), Color(0xFFE0457B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: const Color(0xFF7C5CFF).withValues(alpha: 0.3), blurRadius: 30, offset: const Offset(0, 12)),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${frDays[now.weekday - 1]} ${now.day} ${frMonths[now.month - 1]}'.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                if (ArPage.supported)
                  IconButton(
                    tooltip: 'Hologrammes (réalité augmentée)',
                    color: Colors.white,
                    icon: const Icon(Icons.view_in_ar_rounded),
                    onPressed: () => ArPage.show(),
                  ),
                IconButton(
                  tooltip: 'Chercher partout (Ctrl + Espace)',
                  color: Colors.white,
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => SearchPage.show(),
                ),
                ListenableBuilder(
                  listenable: notifications,
                  builder: (context, _) => IconButton(
                    tooltip: 'Notifications',
                    color: Colors.white,
                    icon: Badge(
                      isLabelVisible: notifications.unread > 0,
                      label: Text('${notifications.unread}'),
                      child: const Icon(Icons.notifications_rounded),
                    ),
                    onPressed: () {
                      notifications.markRead();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NotificationsPage(notifications: notifications, controller: controller),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  tooltip: theme.brightness == Brightness.dark ? 'Mode clair' : 'Mode sombre',
                  color: Colors.white,
                  icon: Icon(theme.brightness == Brightness.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
                  onPressed: () => AppSession.instance.setThemeMode(
                    theme.brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
                  ),
                ),
                IconButton(
                  tooltip: 'Réglages',
                  color: Colors.white,
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(controller: controller, notifications: notifications),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Flexible(
                  child: Text(
                    '$_greeting${userName.isEmpty ? '' : ' $userName'}',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // La main fait coucou une fois, à l'ouverture.
                const _WavingHand(),
              ],
            ),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: Listenable.merge([for (final m in modules) m.badge]),
              builder: (context, _) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _HeaderChip(icon: Icons.schedule_rounded, text: hhmm(now)),
                  for (final (n, m) in [for (final m in modules) if (m.badge.value > 0) m].indexed)
                    // Les pastilles arrivent l'une après l'autre.
                    EnterAnimation(
                      key: ValueKey('chip-${m.id}-${m.badge.value}'),
                      index: n + 1,
                      step: 70,
                      offset: 8,
                      child: _HeaderChip(icon: m.icon, text: '${m.badge.value} · ${m.name}'),
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

/// 👋 qui fait coucou une seule fois (pas d'animation sans fin).
class _WavingHand extends StatefulWidget {
  const _WavingHand();
  @override
  State<_WavingHand> createState() => _WavingHandState();
}

class _WavingHandState extends State<_WavingHand> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  Timer? _start;

  @override
  void initState() {
    super.initState();
    _start = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _a.forward();
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (context, child) {
      final t = _a.value;
      final angle = math.sin(t * math.pi * 5) * 0.45 * (1 - t);
      return Transform.rotate(angle: angle, alignment: const Alignment(0.3, 0.8), child: child);
    },
    child: Text('👋', style: Theme.of(context).textTheme.headlineMedium),
  );
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(30)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.white),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ],
    ),
  );
}

class ModuleCard extends StatefulWidget {
  const ModuleCard({super.key, required this.module, this.onOpen, this.onDropped, this.onRemove});

  final HubModule module;
  final ValueChanged<HubModule>? onOpen;

  /// Module perso : on peut le retirer (bouton de la carte).
  final VoidCallback? onRemove;

  /// Une autre carte a été lâchée sur celle-ci (pour les réordonner).
  final ValueChanged<HubModule>? onDropped;

  @override
  State<ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<ModuleCard> {
  bool hover = false;

  /// Le contenu de la carte, gardé tel quel quand on la survole : avant, un
  /// simple passage de souris reconstruisait tout le résumé (et relançait
  /// ses chargements), ce qui faisait ramer l'accueil.
  Widget? _summary;

  @override
  void didUpdateWidget(ModuleCard old) {
    super.didUpdateWidget(old);
    _summary = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _summary = null; // thème, taille…
  }

  void _open(BuildContext context) {
    final m = widget.module;
    FreezeWatch.note('ouvre ${m.name}');
    widget.onOpen != null
        ? widget.onOpen!(m)
        : Navigator.push(context, MaterialPageRoute(builder: (ctx) => m.buildPage(ctx)));
  }

  /// Le titre de la carte (on l'attrape pour la déplacer).
  Widget _header(BuildContext context, {bool dragging = false}) {
    final m = widget.module;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
      child: Row(
        children: [
          // Au survol, l'icône se redresse et grandit un peu (une fois).
          AnimatedRotation(
            turns: hover && !dragging ? -0.025 : 0,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutBack,
            child: AnimatedScale(
              scale: hover && !dragging ? 1.12 : 1,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: LinearGradient(
                    colors: [m.color, Color.lerp(m.color, Colors.black, 0.3)!],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    if (hover && !dragging)
                      BoxShadow(color: m.color.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 4)),
                  ],
                ),
                child: Icon(m.icon, color: Colors.white, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              m.name,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ValueListenableBuilder(
            valueListenable: m.badge,
            builder: (context, n, _) => n == 0
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      '$n',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ),
          ),
          if (!dragging && widget.onRemove != null)
            IconButton(
              tooltip: 'Retirer ce module perso',
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onSurfaceVariant,
              icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
              onPressed: widget.onRemove,
            ),
          if (!dragging && DesktopWidgets.supported)
            IconButton(
              tooltip: 'Détacher sur le bureau (ou glisse la carte hors de Mon Hub)',
              visualDensity: VisualDensity.compact,
              color: theme.colorScheme.onSurfaceVariant,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              onPressed: () => DesktopWidgets.instance.detach(m.id),
            ),
          if (!dragging) Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final theme = Theme.of(context);
    final card = MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      // Au survol : la carte se soulève, avec une ombre de sa couleur.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, hover ? -4 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: m.color.withValues(alpha: hover ? 0.28 : 0),
              blurRadius: hover ? 26 : 0,
              offset: Offset(0, hover ? 12 : 0),
            ),
          ],
        ),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Halo coloré discret dans le coin.
              Positioned(
                top: -60,
                right: -60,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [m.color.withValues(alpha: 0.22), m.color.withValues(alpha: 0)]),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _open(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Le titre s'attrape : lâché hors de Mon Hub, le widget
                    // part sur le bureau ; lâché sur une autre carte, elles
                    // échangent leur place.
                    Draggable<HubModule>(
                      data: m,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Opacity(
                          opacity: 0.9,
                          child: Container(
                            width: 320,
                            decoration: BoxDecoration(
                              color: theme.cardTheme.color ?? theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: m.color),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6))],
                            ),
                            child: _header(context, dragging: true),
                          ),
                        ),
                      ),
                      onDragEnd: (d) {
                        final size = MediaQuery.sizeOf(context);
                        final p = d.offset;
                        // Hors de la fenêtre (ou tout contre son bord : Windows
                        // ne suit pas toujours la souris au-delà).
                        const edge = 12.0;
                        final outside =
                            p.dx < edge || p.dy < edge || p.dx > size.width - edge || p.dy > size.height - edge;
                        if (outside && DesktopWidgets.supported) {
                          unawaited(DesktopWidgets.instance.detach(m.id, at: Win.cursor()));
                        }
                      },
                      child: MouseRegion(cursor: SystemMouseCursors.grab, child: _header(context)),
                    ),
                    Expanded(child: RepaintBoundary(child: _summary ??= m.buildSummary(context))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return DragTarget<HubModule>(
      onWillAcceptWithDetails: (d) => d.data.id != m.id,
      onAcceptWithDetails: (d) => widget.onDropped?.call(d.data),
      builder: (context, cand, _) => cand.isEmpty
          ? card
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: m.color, width: 2),
              ),
              child: card,
            ),
    );
  }
}
