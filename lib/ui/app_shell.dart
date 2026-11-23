import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_home.dart';
import '../core/hub_module.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import '../core/online/online.dart';
import '../core/online/spaces.dart';
import '../core/pc_apps.dart';
import '../core/version.dart';
import 'apps_page.dart';
import 'home_page.dart';
import 'hud/home_layout.dart';
import 'hud/hud.dart';
import 'motion.dart';
import 'online/online_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'spaces/space_page.dart';
import 'spaces/spaces_page.dart';

/// Squelette de l'appli (v1.60, façon HUD) : un menu à gauche sur grand
/// écran (Aujourd'hui, Mes applis, espaces épinglés, discussions, modules),
/// une barre en bas + le menu en tiroir sur téléphone.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller, required this.notifications});

  final HubController controller;
  final NotificationCenter notifications;

  @override
  State<AppShell> createState() => _AppShellState();
}

/// Ce qui est affiché : « home », « apps », « spaces », « space:ID » ou
/// « mod:ID ».
class _AppShellState extends State<AppShell> {
  String selected = 'home';
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Bandeaux d'alerte affichés dans la fenêtre.
  final _banners = <HubNotification>[];
  StreamSubscription<HubNotification>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.notifications.banners.stream.listen(_banner);
    // Bouton « Menu » : retour à l'accueil depuis n'importe où.
    HubHome.instance.onHome = () {
      if (mounted && selected != 'home') setState(() => selected = 'home');
    };
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    HubHome.instance
      ..onHome = null
      ..setInModule(false);
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

  void _go(String key) {
    _scaffold.currentState?.closeDrawer();
    if (key != 'home') HomeLayout.instance.setEditing(false);
    setState(() => selected = key);
  }

  void open(HubModule m) => _go('mod:${m.id}');
  void openSpace(Space s) => _go('space:${s.id}');

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
                      final space = n.id.startsWith('espace:') ? Spaces.instance.byId(n.id.split(':')[1]) : null;
                      if (space != null) return openSpace(space);
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

  Widget _body(List<HubModule> modules) {
    if (selected.startsWith('mod:')) {
      final m = modules.where((m) => m.id == selected.substring(4)).firstOrNull;
      if (m != null) return KeyedSubtree(key: ValueKey(m.id), child: Builder(builder: m.buildPage));
    }
    if (selected.startsWith('space:')) {
      return SpacePage(key: ValueKey(selected), spaceId: selected.substring(6), onClosed: () => _go('spaces'));
    }
    if (selected == 'spaces') return SpacesPage(onOpen: openSpace);
    if (selected == 'apps' && PcApps.supported) return const AppsPage();
    return HomePage(
      controller: widget.controller,
      notifications: widget.notifications,
      onOpen: open,
      onOpenSpace: openSpace,
      onOpenSpaces: () => _go('spaces'),
      onOpenApps: PcApps.supported ? () => _go('apps') : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final modules = widget.controller.enabled;
        if (selected.startsWith('mod:') && !modules.any((m) => m.id == selected.substring(4))) selected = 'home';
        HubHome.instance.setInModule(selected != 'home');
        final body = _body(modules);
        final menu = _SideMenu(
          modules: modules,
          selected: selected,
          onGo: _go,
          onSettings: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SettingsPage(controller: widget.controller, notifications: widget.notifications)),
          ),
        );
        // Changement de section : fondu + petite montée (façon Spotify).
        final switcher = AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          reverseDuration: const Duration(milliseconds: 120),
          switchInCurve: motionCurve,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a), child: child),
          ),
          child: KeyedSubtree(key: ValueKey(selected), child: body),
        );

        final wide = MediaQuery.sizeOf(context).width >= 840;
        if (wide) {
          return Scaffold(
            body: HudBackground(
              child: _withBanners(Row(
                children: [
                  RepaintBoundary(child: menu),
                  Expanded(child: switcher),
                ],
              )),
            ),
          );
        }

        // Téléphone : Accueil, Espaces, Chercher + le menu complet en tiroir.
        final index = switch (selected) {
          'home' => 0,
          'spaces' => 1,
          _ when selected.startsWith('space:') => 1,
          _ => 3,
        };
        return Scaffold(
          key: _scaffold,
          drawer: Drawer(width: 290, child: menu),
          body: HudBackground(child: SafeArea(bottom: false, child: _withBanners(switcher))),
          bottomNavigationBar: ListenableBuilder(
            listenable: Spaces.instance,
            builder: (context, _) => NavigationBar(
              selectedIndex: index,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: (i) {
                switch (i) {
                  case 0:
                    _go('home');
                  case 1:
                    _go('spaces');
                  case 2:
                    unawaited(SearchPage.show());
                  default:
                    _scaffold.currentState?.openDrawer();
                }
              },
              destinations: [
                const NavigationDestination(icon: Icon(Icons.blur_on_rounded), label: 'Aujourd\'hui'),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: Spaces.instance.totalUnread > 0,
                    label: Text('${Spaces.instance.totalUnread}'),
                    child: const Icon(Icons.hub_rounded),
                  ),
                  label: 'Espaces',
                ),
                const NavigationDestination(icon: Icon(Icons.search_rounded), label: 'Chercher'),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: modules.any((m) => m.badge.value > 0),
                    smallSize: 8,
                    child: const Icon(Icons.menu_rounded),
                  ),
                  label: 'Menu',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SideMenu extends StatelessWidget {
  const _SideMenu({required this.modules, required this.selected, required this.onGo, required this.onSettings});

  final List<HubModule> modules;
  final String selected;
  final ValueChanged<String> onGo;
  final VoidCallback onSettings;

  static const _foldKey = 'hub.menu.replie';

  static Set<String> get _folded => (ModuleStore.prefs.getStringList(_foldKey) ?? const []).toSet();

  static Future<void> _toggle(String section) async {
    final f = _folded;
    f.contains(section) ? f.remove(section) : f.add(section);
    await ModuleStore.prefs.setStringList(_foldKey, f.toList());
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return StatefulBuilder(
      builder: (context, setLocal) => ListenableBuilder(
        listenable: Listenable.merge([Spaces.instance, Online.instance]),
        builder: (context, _) {
          final sp = Spaces.instance;
          final folded = _folded;
          Future<void> fold(String s) async {
            await _toggle(s);
            setLocal(() {});
          }

          return Container(
            width: 252,
            decoration: BoxDecoration(color: c.side, border: Border(right: BorderSide(color: c.line.withValues(alpha: .7)))),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 12, 10),
                    child: Row(
                      children: [
                        HexAvatar('MH', size: 40, color: c.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('MON HUB', style: hudTitle(context, size: 17).copyWith(letterSpacing: 1.4)),
                              Text(
                                '$appVersion // ${sp.available ? '${sp.spaces.length} espace${sp.spaces.length > 1 ? 's' : ''}' : 'hors ligne'}'.toUpperCase(),
                                style: hudLabel(context, size: 9),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: InkWell(
                      onTap: () => SearchPage.show(),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(color: c.panelLow, border: Border.all(color: c.line)),
                        child: Row(
                          children: [
                            Text('>', style: hudMono(context, color: c.pink, weight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(PcApps.supported ? 'chercher, une appli…' : 'chercher…', style: hudMono(context, size: 12, color: c.muted))),
                            const HudKey('Ctrl K'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      children: [
                        const HudSectionLabel('Perso'),
                        _Item(label: 'Aujourd\'hui', icon: Icons.blur_on_rounded, selected: selected == 'home', onTap: () => onGo('home')),
                        if (PcApps.supported)
                          _Item(label: 'Mes applis', icon: Icons.apps_rounded, selected: selected == 'apps', onTap: () => onGo('apps')),
                        HudSectionLabel(
                          'Espaces',
                          open: !folded.contains('espaces'),
                          onTap: () => fold('espaces'),
                          trailing: sp.available
                              ? PopupMenuButton<String>(
                                  tooltip: 'Nouvel espace / rejoindre',
                                  padding: EdgeInsets.zero,
                                  iconSize: 16,
                                  icon: Icon(Icons.add_rounded, size: 16, color: c.muted),
                                  onSelected: (a) async {
                                    final s = a == 'join' ? await SpaceActions.join(context) : await SpaceActions.create(context);
                                    if (s != null) onGo('space:${s.id}');
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'new', child: Text('Créer un espace')),
                                    PopupMenuItem(value: 'join', child: Text('Rejoindre avec un code')),
                                  ],
                                )
                              : null,
                        ),
                        if (!folded.contains('espaces')) ...[
                          if (!sp.available)
                            _Item(
                              label: 'Partager avec des amis',
                              icon: Icons.cloud_outlined,
                              dim: true,
                              onTap: () => OnlinePage.open(context),
                            )
                          else ...[
                            for (final s in sp.spaces)
                              _Item(
                                label: s.name,
                                leading: HudDiamond(s.colorValue),
                                selected: selected == 'space:${s.id}',
                                count: sp.unread[s.id] ?? 0,
                                pinned: sp.isPinned(s.id),
                                onTap: () => onGo('space:${s.id}'),
                              ),
                            _Item(label: 'Tous les espaces', icon: Icons.grid_view_rounded, dim: true, selected: selected == 'spaces', onTap: () => onGo('spaces')),
                          ],
                        ],
                        if (sp.available) ...[
                          HudSectionLabel(
                            'Discussions',
                            open: !folded.contains('discussions'),
                            onTap: () => fold('discussions'),
                            trailing: IconButton(
                              tooltip: 'Nouveau message',
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: Icon(Icons.add_rounded, size: 16, color: c.muted),
                              onPressed: () async {
                                final s = await SpaceActions.message(context);
                                if (s != null) onGo('space:${s.id}');
                              },
                            ),
                          ),
                          if (!folded.contains('discussions'))
                            for (final d in sp.chats)
                              _Item(
                                label: sp.titleOf(d),
                                leading: HexAvatar(sp.titleOf(d).isEmpty ? '?' : sp.titleOf(d).substring(0, 1).toUpperCase(), size: 20),
                                selected: selected == 'space:${d.id}',
                                count: sp.unread[d.id] ?? 0,
                                onTap: () => onGo('space:${d.id}'),
                              ),
                        ],
                        HudSectionLabel('Modules', open: !folded.contains('modules'), onTap: () => fold('modules')),
                        if (!folded.contains('modules'))
                          for (final m in modules)
                            ValueListenableBuilder(
                              valueListenable: m.badge,
                              builder: (context, n, _) => _Item(
                                label: m.name,
                                icon: m.icon,
                                iconColor: m.color,
                                selected: selected == 'mod:${m.id}',
                                count: n,
                                onTap: () => onGo('mod:${m.id}'),
                              ),
                            ),
                      ],
                    ),
                  ),
                  const Padding(padding: EdgeInsets.fromLTRB(18, 0, 18, 8), child: Hatch(height: 6, opacity: .55)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    child: Column(
                      children: [
                        _Item(
                          label: 'Personnaliser',
                          icon: Icons.dashboard_customize_outlined,
                          onTap: () {
                            onGo('home');
                            HomeLayout.instance.setEditing(true);
                          },
                        ),
                        _Item(label: 'Réglages', icon: Icons.tune_rounded, onTap: onSettings),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Une ligne du menu : « > » violet quand elle est choisie.
class _Item extends StatelessWidget {
  const _Item({
    required this.label,
    required this.onTap,
    this.icon,
    this.iconColor,
    this.leading,
    this.selected = false,
    this.count = 0,
    this.pinned = false,
    this.dim = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final bool selected;
  final int count;
  final bool pinned;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.selected : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: selected ? Text('>', textAlign: TextAlign.center, style: hudMono(context, color: c.accent, weight: FontWeight.w700)) : null,
                ),
                SizedBox(
                  width: 24,
                  child: Center(child: leading ?? (icon == null ? null : Icon(icon, size: 18, color: selected ? (iconColor ?? c.accentText) : (iconColor ?? c.muted)))),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? c.text : (dim ? c.muted : c.text.withValues(alpha: .82)),
                    ),
                  ),
                ),
                if (pinned) Icon(Icons.push_pin_rounded, size: 11, color: c.dim),
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, right: 6),
                    child: HudTag(count > 99 ? '99+' : '$count', color: c.pink, textColor: Colors.white),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
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
    final c = HudColors.of(context);
    final color = module?.color ?? c.accent;
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
          color: Colors.transparent,
          shadowColor: Colors.black54,
          shape: hudCut(12),
          child: HudPanel(
            hot: true,
            cut: 12,
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            onTap: onOpen,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HexAvatar('', size: 28, color: color, child: Icon(module?.icon ?? Icons.notifications_active_rounded, size: 15, color: Colors.white)),
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
    );
  }
}
