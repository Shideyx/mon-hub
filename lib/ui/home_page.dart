import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import 'notifications_page.dart';
import 'settings_page.dart';
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
        listenable: controller,
        builder: (context, _) {
          final modules = controller.enabled;
          return RefreshIndicator(
            onRefresh: notifications.pollNow,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(
                      controller: controller, notifications: notifications, modules: modules),
                ),
                if (modules.isEmpty)
                  const SliverFillRemaining(
                    child: EmptyHint('Aucun module actif. Active-en dans les réglages.'),
                  )
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
                      itemCount: modules.length,
                      itemBuilder: (context, i) => ModuleCard(module: modules[i], onOpen: onOpen),
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
          BoxShadow(
            color: const Color(0xFF7C5CFF).withValues(alpha: 0.3),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
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
                    '${frDays[now.weekday - 1]} ${now.day} ${frMonths[now.month - 1]}'
                        .toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85), letterSpacing: 1.2),
                  ),
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
                              builder: (_) => NotificationsPage(
                                  notifications: notifications, controller: controller)));
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Réglages',
                  color: Colors.white,
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            SettingsPage(controller: controller, notifications: notifications)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$_greeting${userName.isEmpty ? '' : ' $userName'} 👋',
              style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: Listenable.merge([for (final m in modules) m.badge]),
              builder: (context, _) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _HeaderChip(icon: Icons.schedule_rounded, text: hhmm(now)),
                  for (final m in modules)
                    if (m.badge.value > 0)
                      _HeaderChip(icon: m.icon, text: '${m.badge.value} · ${m.name}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );
}

class ModuleCard extends StatefulWidget {
  const ModuleCard({super.key, required this.module, this.onOpen});

  final HubModule module;
  final ValueChanged<HubModule>? onOpen;

  @override
  State<ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<ModuleCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: AnimatedScale(
        scale: hover ? 1.015 : 1,
        duration: const Duration(milliseconds: 160),
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
                    gradient: RadialGradient(colors: [
                      m.color.withValues(alpha: 0.22),
                      m.color.withValues(alpha: 0),
                    ]),
                  ),
                ),
              ),
              InkWell(
                onTap: () => widget.onOpen != null
                    ? widget.onOpen!(m)
                    : Navigator.push(
                        context,
                        MaterialPageRoute(builder: (ctx) => m.buildPage(ctx)),
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(11),
                              gradient: LinearGradient(
                                colors: [m.color, Color.lerp(m.color, Colors.black, 0.3)!],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: Icon(m.icon, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(m.name,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis),
                          ),
                          ValueListenableBuilder(
                            valueListenable: m.badge,
                            builder: (context, n, _) => n == 0
                                ? const SizedBox.shrink()
                                : Container(
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: m.color,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text('$n',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12)),
                                  ),
                          ),
                          Icon(Icons.chevron_right_rounded,
                              color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                    Expanded(child: m.buildSummary(context)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
