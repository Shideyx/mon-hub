import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import '../core/desktop_widgets.dart';
import '../core/session.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import 'notifications_page.dart';
import 'settings_page.dart';
import 'clicky/win.dart';
import 'widgets.dart';

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
          final modules = [for (final m in all) if (!desk.isDetached(m.id)) m];
          final away = [for (final m in all) if (desk.isDetached(m.id)) m];
          return RefreshIndicator(
            onRefresh: notifications.pollNow,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(
                      controller: controller, notifications: notifications, modules: all),
                ),
                if (away.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
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
                  const SliverFillRemaining(
                    child: EmptyHint('Aucun module actif. Active-en dans les réglages.'),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 440,
                        mainAxisExtent: 268,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: modules.length,
                      itemBuilder: (context, i) => ModuleCard(
                        module: modules[i],
                        onOpen: onOpen,
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
    final windows = !kIsWeb && Platform.isWindows;
    // En-tête façon Windows 11 : grand titre, date, boutons discrets.
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_greeting${userName.isEmpty ? '' : ' $userName'}',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontFamily: windows ? 'Segoe UI Variable Display' : null,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${frDays[now.weekday - 1]} ${now.day} ${frMonths[now.month - 1]} · ${hhmm(now)}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                ListenableBuilder(
                  listenable: notifications,
                  builder: (context, _) => IconButton(
                    tooltip: 'Notifications',
                    icon: Badge(
                      isLabelVisible: notifications.unread > 0,
                      label: Text('${notifications.unread}'),
                      child: const Icon(Icons.notifications_none_rounded),
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
                  icon: Icon(theme.brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                  onPressed: () => AppSession.instance.setThemeMode(
                    theme.brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
                  ),
                ),
                IconButton(
                  tooltip: 'Réglages',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => SettingsPage(controller: controller, notifications: notifications)),
                  ),
                ),
              ],
            ),
            ListenableBuilder(
              listenable: Listenable.merge([for (final m in modules) m.badge]),
              builder: (context, _) {
                final busy = [for (final m in modules) if (m.badge.value > 0) m];
                if (busy.isEmpty) return const SizedBox(height: 4);
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final m in busy) _HeaderChip(icon: m.icon, color: m.color, text: '${m.badge.value} · ${m.name}')],
                  ),
                );
              },
            ),
            if (DesktopWidgets.supported)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Astuce : attrape un widget par son titre et lâche-le en dehors de Mon Hub pour le poser sur le bureau.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

class ModuleCard extends StatefulWidget {
  const ModuleCard({super.key, required this.module, this.onOpen, this.onDropped});

  final HubModule module;
  final ValueChanged<HubModule>? onOpen;

  /// Une autre carte a été lâchée sur celle-ci (pour les réordonner).
  final ValueChanged<HubModule>? onDropped;

  @override
  State<ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<ModuleCard> {
  bool hover = false;

  void _open(BuildContext context) {
    final m = widget.module;
    widget.onOpen != null
        ? widget.onOpen!(m)
        : Navigator.push(context, MaterialPageRoute(builder: (ctx) => m.buildPage(ctx)));
  }

  /// Le titre de la carte (on l'attrape pour la déplacer).
  Widget _header(BuildContext context, {bool dragging = false}) {
    final m = widget.module;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(6)),
            child: Icon(m.icon, color: Colors.white, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              m.name,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ValueListenableBuilder(
            valueListenable: m.badge,
            builder: (context, n, _) => n == 0
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      '$n',
                      style: TextStyle(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w700, fontSize: 11),
                    ),
                  ),
          ),
          if (!dragging && DesktopWidgets.supported)
            IconButton(
              tooltip: 'Détacher sur le bureau',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              onPressed: () => DesktopWidgets.instance.detach(m.id),
            ),
          if (!dragging)
            IconButton(
              tooltip: 'Ouvrir',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right_rounded, size: 20),
              onPressed: () => _open(context),
            ),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: hover
              ? Color.lerp(theme.cardTheme.color, theme.colorScheme.onSurface, 0.025)
              : theme.cardTheme.color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: hover ? 1 : 0.7)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Le titre s'attrape : lâché hors de Mon Hub, le widget part
            // sur le bureau ; lâché sur une autre carte, elles s'échangent.
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
                      color: theme.cardTheme.color,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.colorScheme.primary),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 6))],
                    ),
                    child: _header(context, dragging: true),
                  ),
                ),
              ),
              onDragEnd: (d) {
                final size = MediaQuery.sizeOf(context);
                final p = d.offset;
                // Hors de la fenêtre (ou tout contre son bord : Windows ne
                // suit pas toujours la souris au-delà).
                const edge = 12.0;
                final outside = p.dx < edge || p.dy < edge || p.dx > size.width - edge || p.dy > size.height - edge;
                if (outside && DesktopWidgets.supported) {
                  final at = Win.cursor();
                  unawaited(DesktopWidgets.instance.detach(m.id, at: at));
                }
              },
              child: MouseRegion(cursor: SystemMouseCursors.grab, child: _header(context)),
            ),
            Expanded(
              child: InkWell(onTap: () => _open(context), child: m.buildSummary(context)),
            ),
          ],
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
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.primary, width: 2),
              ),
              child: card,
            ),
    );
  }
}
