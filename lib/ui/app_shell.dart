import 'dart:async';
import 'dart:math' as math;

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

  /// Bandeaux d'alerte affichés dans la fenêtre.
  final _banners = <HubNotification>[];
  StreamSubscription<HubNotification>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.notifications.banners.stream.listen(_banner);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _banner(HubNotification n) {
    if (!mounted) return;
    setState(() {
      _banners.insert(0, n);
      if (_banners.length > 3) _banners.removeLast();
    });
    Future<void>.delayed(const Duration(seconds: 7), () {
      if (mounted) setState(() => _banners.remove(n));
    });
  }

  Widget _withBanners(Widget child) {
    final byId = {for (final m in widget.controller.available) m.id: m};
    return Stack(
      children: [
        child,
        Positioned(
          top: 12,
          right: 12,
          width: math.min(360.0, MediaQuery.sizeOf(context).width - 24),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final n in _banners)
                  _Banner(
                    key: ValueKey(n.id),
                    n: n,
                    module: byId[n.moduleId],
                    onOpen: () {
                      setState(() => _banners.remove(n));
                      final m = byId[n.moduleId];
                      if (m != null && widget.controller.enabled.contains(m)) open(m);
                    },
                    onClose: () => setState(() => _banners.remove(n)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

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
            body: _withBanners(Row(
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
                // Le contenu sur un « calque » légèrement plus clair, aux coins
                // arrondis, comme dans les applis de Windows 11.
                Expanded(child: _ContentLayer(child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(key: ValueKey(selected), child: body),
                  ))),
              ],
            )),
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
          body: _withBanners(body),
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

/// Le menu de gauche, façon Windows 11 (comme l'appli Paramètres) : fond
/// de la fenêtre, éléments arrondis, petite barre de couleur d'accent sur
/// la section ouverte.
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
    final accent = theme.colorScheme.primary;
    final selectedBg = (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    Widget item(int i, Widget icon, String label, {VoidCallback? onTap}) {
      final sel = i == index;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
        child: Material(
          color: sel ? selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap ?? () => onSelect(i),
            child: SizedBox(
              height: 38,
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 3,
                    height: sel ? 16 : 0,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 11),
                  IconTheme.merge(data: const IconThemeData(size: 18), child: icon),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 260,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6)),
                    child: Icon(Icons.hub_rounded, color: theme.colorScheme.onPrimary, size: 15),
                  ),
                  const SizedBox(width: 12),
                  Text('Mon Hub', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  item(0, Icon(index == 0 ? Icons.home_rounded : Icons.home_outlined), 'Accueil'),
                  const SizedBox(height: 4),
                  for (var i = 0; i < modules.length; i++)
                    item(i + 1, badgeIcon(modules[i], selected: index == i + 1), modules[i].name),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: item(-1, const Icon(Icons.settings_outlined), 'Réglages', onTap: onSettings),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un bandeau d'alerte dans la fenêtre (glisse depuis la droite).
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.n, required this.module, required this.onOpen, required this.onClose});
  final HubNotification n;
  final HubModule? module;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final color = module?.color ?? Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset((1 - t) * 80, 0), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border(left: BorderSide(color: color, width: 4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(module?.icon ?? Icons.notifications_active_rounded, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(n.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Fermer',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Le calque du contenu (coin arrondi en haut à gauche, trait fin), comme
/// l'appli Paramètres de Windows 11.
class _ContentLayer extends StatelessWidget {
  const _ContentLayer({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final layer = dark ? const Color(0xFF272727) : const Color(0xFFF9F9F9);
    return Container(
      decoration: BoxDecoration(
        color: layer,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(8)),
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: layer,
          canvasColor: layer,
          appBarTheme: theme.appBarTheme.copyWith(backgroundColor: layer),
        ),
        child: child,
      ),
    );
  }
}
