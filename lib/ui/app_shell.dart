import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/notifications.dart';
import 'home_page.dart';
import 'settings_page.dart';

/// Squelette de l'appli : menu latéral sur grand écran (PC, tablette),
/// barre en bas sur téléphone. Chaque module actif devient une section.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller, required this.notifications});

  final HubController controller;
  final NotificationCenter notifications;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// null = Accueil.
  String? selected;

  void open(HubModule m) => setState(() => selected = m.id);

  Widget _badgeIcon(HubModule m, {bool selected = false}) => ValueListenableBuilder(
        valueListenable: m.badge,
        builder: (context, n, _) => Badge(
          isLabelVisible: n > 0,
          label: Text('$n'),
          backgroundColor: m.color,
          child: Icon(m.icon, color: selected ? m.color : null),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final modules = widget.controller.enabled;
        final current =
            modules.where((m) => m.id == selected).firstOrNull;
        final body = current == null
            ? HomePage(
                controller: widget.controller,
                notifications: widget.notifications,
                onOpen: open,
              )
            : KeyedSubtree(
                key: ValueKey(current.id),
                child: Builder(builder: current.buildPage),
              );

        final wide = MediaQuery.sizeOf(context).width >= 840;
        if (wide) {
          final index = current == null ? 0 : modules.indexOf(current) + 1;
          return Scaffold(
            body: Row(
              children: [
                _SideMenu(
                  modules: modules,
                  index: index,
                  badgeIcon: _badgeIcon,
                  onSelect: (i) => setState(() => selected = i == 0 ? null : modules[i - 1].id),
                  onSettings: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsPage(
                          controller: widget.controller, notifications: widget.notifications),
                    ),
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(key: ValueKey(selected), child: body),
                  ),
                ),
              ],
            ),
          );
        }

        // Téléphone : 4 sections favorites + « Plus ».
        final pinned = modules.take(3).toList();
        final rest = modules.skip(3).toList();
        int index;
        if (current == null) {
          index = 0;
        } else if (pinned.contains(current)) {
          index = pinned.indexOf(current) + 1;
        } else {
          index = pinned.length + 1;
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) async {
              if (i == 0) return setState(() => selected = null);
              if (i <= pinned.length) return setState(() => selected = pinned[i - 1].id);
              final m = await showModalBottomSheet<HubModule>(
                context: context,
                showDragHandle: true,
                builder: (c) => SafeArea(
                  child: Wrap(children: [
                    for (final m in rest)
                      ListTile(
                        leading: _badgeIcon(m),
                        title: Text(m.name),
                        onTap: () => Navigator.pop(c, m),
                      ),
                  ]),
                ),
              );
              if (m != null) open(m);
            },
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Accueil'),
              for (final m in pinned)
                NavigationDestination(
                    icon: _badgeIcon(m), selectedIcon: _badgeIcon(m, selected: true), label: m.name),
              if (rest.isNotEmpty)
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: rest.any((m) => m.badge.value > 0),
                    smallSize: 8,
                    child: const Icon(Icons.apps_rounded),
                  ),
                  label: 'Plus',
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SideMenu extends StatelessWidget {
  const _SideMenu({
    required this.modules,
    required this.index,
    required this.onSelect,
    required this.onSettings,
    required this.badgeIcon,
  });

  final List<HubModule> modules;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onSettings;
  final Widget Function(HubModule, {bool selected}) badgeIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Widget item(int i, Widget icon, String label, Color color) {
      final sel = i == index;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          color: sel ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onSelect(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(children: [
                icon,
                const SizedBox(width: 14),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel ? color : null)),
                ),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF13141A) : Colors.white,
        border: Border(right: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                        colors: [Color(0xFF6D4AFF), Color(0xFFE0457B)]),
                  ),
                  child: const Icon(Icons.hub_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Text('Mon Hub',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ]),
            ),
            Expanded(
              child: ListView(
                children: [
                  item(
                      0,
                      Icon(index == 0 ? Icons.home_rounded : Icons.home_outlined,
                          color: index == 0 ? theme.colorScheme.primary : null),
                      'Accueil',
                      theme.colorScheme.primary),
                  const SizedBox(height: 8),
                  for (var i = 0; i < modules.length; i++)
                    item(i + 1, badgeIcon(modules[i], selected: index == i + 1), modules[i].name,
                        modules[i].color),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Réglages'),
                onTap: onSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
