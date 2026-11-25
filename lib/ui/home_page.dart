import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import '../core/desktop_widgets.dart';
import '../core/freeze_watch.dart';
import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import '../core/online/online.dart';
import '../core/online/spaces.dart';
import '../core/pc_apps.dart';
import '../core/session.dart';
import 'apps_page.dart';
import 'clicky/clicky.dart';
import 'clicky/skills.dart';
import 'hub_feed_view.dart';
import 'hud/home_layout.dart';
import 'hud/hud.dart';
import 'notifications_page.dart';
import 'online/online_page.dart';
import 'phone_link_page.dart';
import 'settings_page.dart';
import 'spaces/spaces_page.dart';

/// **Aujourd'hui** : l'accueil de Mon Hub, façon HUD. En haut la console de
/// Nexo (une question, ou le nom d'une appli à lancer), puis des blocs que
/// l'on range comme on veut (« Personnaliser » : glisser, taille, ajouter,
/// retirer).
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.notifications,
    this.onOpen,
    this.onOpenSpace,
    this.onOpenSpaces,
    this.onOpenApps,
  });

  final HubController controller;
  final NotificationCenter notifications;

  /// Ouvre la section d'un module (fourni par le squelette de l'appli).
  final ValueChanged<HubModule>? onOpen;
  final ValueChanged<Space>? onOpenSpace;
  final VoidCallback? onOpenSpaces;
  final VoidCallback? onOpenApps;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    if (PcApps.supported) unawaited(PcApps.instance.load());
  }

  Set<String> get _specialsHere => {'fil', 'espaces', 'taches', 'discussions', if (PcApps.supported) 'applis'};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.controller, DesktopWidgets.instance, HomeLayout.instance]),
        builder: (context, _) {
          final desk = DesktopWidgets.instance;
          final all = widget.controller.enabled;
          // Les widgets détachés vivent sur le bureau, pas dans l'accueil.
          final modules = [
            for (final m in all)
              if (!desk.isDetached(m.id)) m,
          ];
          final away = [
            for (final m in all)
              if (desk.isDetached(m.id)) m,
          ];
          final byId = {for (final m in modules) m.id: m};
          final layout = HomeLayout.instance;
          final blocks = layout.blocks(modules: modules.map((m) => m.id).toList(), specialsHere: _specialsHere);
          return RefreshIndicator(
            onRefresh: widget.notifications.pollNow,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(controller: widget.controller, notifications: widget.notifications, modules: all),
                ),
                SliverToBoxAdapter(
                  child: _Console(onOpenApps: widget.onOpenApps, onOpenSpace: widget.onOpenSpace),
                ),
                if (away.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(_side(context), 4, _side(context), 4),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Sur le bureau', style: Theme.of(context).textTheme.bodySmall),
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
                if (layout.editing)
                  SliverToBoxAdapter(
                    child: _EditBar(blocks: blocks, modules: modules, specialsHere: _specialsHere),
                  ),
                if (blocks.isEmpty)
                  SliverToBoxAdapter(
                    child: HudEmpty(
                      'Ton accueil est vide. « Personnaliser » pour y mettre des blocs.',
                      action: HudButton(label: 'Personnaliser', onPressed: () => layout.setEditing(true)),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(_side(context), 12, _side(context), 32),
                    sliver: _Grid(blocks: blocks, editing: layout.editing, builder: (b) => _block(context, b, byId)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _block(BuildContext context, HomeBlock b, Map<String, HubModule> byId) {
    final m = b.moduleId == null ? null : byId[b.moduleId];
    if (m != null) return _ModuleBlock(key: ValueKey(m.id), module: m, onOpen: widget.onOpen);
    return switch (b.id) {
      'fil' => HubFeedStrip(controller: widget.controller, onOpen: widget.onOpen),
      'espaces' => _SpacesBlock(onOpen: widget.onOpenSpace, onAll: widget.onOpenSpaces),
      'taches' => _TasksBlock(onOpen: widget.onOpenSpace),
      'discussions' => _ChatsBlock(onOpen: widget.onOpenSpace, onAll: widget.onOpenSpaces),
      'applis' => _AppsBlock(onAll: widget.onOpenApps),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Marge sur les côtés : plus petite sur un téléphone.
double _side(BuildContext context) => MediaQuery.sizeOf(context).width < 600 ? 12 : 24;

/// Hauteur d'un bloc (le fil garde la sienne).
double? _heightOf(HomeBlock b) => b.id == 'fil' ? null : 268;

/// Les blocs, rangés en rangées de 1 à 4 colonnes (selon la largeur). Les
/// rangées sont construites **seulement quand elles arrivent à l'écran** :
/// l'accueil s'ouvre vite même avec beaucoup de modules.
class _Grid extends StatelessWidget {
  const _Grid({required this.blocks, required this.editing, required this.builder});
  final List<HomeBlock> blocks;
  final bool editing;
  final Widget Function(HomeBlock) builder;

  static const gap = 16.0;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final cols = columnsFor(width);
        final colW = (width - gap * (cols - 1)) / cols;
        final rows = HomeLayout.rows(blocks, cols);
        double widthOf(HomeBlock b) {
          final span = HomeLayout.spanIn(b, cols);
          return colW * span + gap * (span - 1);
        }

        Widget cell(HomeBlock b) => SizedBox(
          key: ValueKey('bloc-${b.id}'),
          width: widthOf(b),
          height: _heightOf(b),
          child: editing ? _Editable(block: b, blocks: blocks, child: builder(b)) : RepaintBoundary(child: builder(b)),
        );

        return SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) => Padding(
            padding: EdgeInsets.only(bottom: i == rows.length - 1 ? 0 : gap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (j, b) in rows[i].indexed) ...[if (j > 0) const SizedBox(width: gap), cell(b)],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 1 à 4 colonnes d'au moins 300 points.
  static int columnsFor(double width) => ((width + gap) / (300 + gap)).floor().clamp(1, 4);
}

/// Un bloc en mode « Personnaliser » : on l'attrape pour le déplacer, on
/// change sa largeur, on le retire.
class _Editable extends StatelessWidget {
  const _Editable({required this.block, required this.blocks, required this.child});
  final HomeBlock block;
  final List<HomeBlock> blocks;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final layout = HomeLayout.instance;
    final touch = Platform.isAndroid || Platform.isIOS;
    final bar = Material(
      color: c.hotBg,
      shape: const SlantBorder(slant: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drag_indicator_rounded, size: 18, color: c.accentText),
            for (final s in const [1, 2, 3])
              Tooltip(
                message: s == 3 ? 'Toute la largeur' : '$s colonne${s > 1 ? 's' : ''}',
                child: InkWell(
                  onTap: () => layout.resize(blocks, block.id, s),
                  child: Container(
                    width: 28,
                    height: 26,
                    alignment: Alignment.center,
                    color: block.span == s ? c.accent : Colors.transparent,
                    child: Text(
                      s == 3 ? 'L' : (s == 2 ? 'M' : 'S'),
                      style: hudLabel(context, size: 11, color: block.span == s ? Colors.white : c.muted),
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Retirer de l\'accueil',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: c.bad),
              onPressed: () => layout.remove(blocks, block.id),
            ),
          ],
        ),
      ),
    );
    final framed = Stack(
      // Le bloc lui-même donne la taille (le fil n'a pas de hauteur fixe).
      fit: StackFit.passthrough,
      children: [
        IgnorePointer(child: Opacity(opacity: 0.55, child: child)),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: hudCut(14, side: BorderSide(color: c.accent, width: 1.5)),
              ),
            ),
          ),
        ),
        Positioned(top: 8, right: 8, child: bar),
      ],
    );
    final feedback = Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 260,
        height: 90,
        child: HudPanel(
          hot: true,
          child: Center(child: Text(_title(block), style: hudTitle(context, size: 16))),
        ),
      ),
    );
    final draggable = touch
        ? LongPressDraggable<String>(
            data: block.id,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: .3, child: framed),
            child: framed,
          )
        : Draggable<String>(
            data: block.id,
            feedback: feedback,
            childWhenDragging: Opacity(opacity: .3, child: framed),
            child: MouseRegion(cursor: SystemMouseCursors.grab, child: framed),
          );
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != block.id,
      onAcceptWithDetails: (d) => layout.move(blocks, d.data, block.id),
      builder: (context, cand, _) => cand.isEmpty
          ? draggable
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: ShapeDecoration(
                shape: hudCut(14, side: BorderSide(color: c.pink, width: 3)),
              ),
              child: draggable,
            ),
    );
  }
}

String _title(HomeBlock b) => HomeLayout.specials[b.id] ?? (b.moduleId ?? b.id);

/// La barre du mode « Personnaliser ».
class _EditBar extends StatelessWidget {
  const _EditBar({required this.blocks, required this.modules, required this.specialsHere});
  final List<HomeBlock> blocks;
  final List<HubModule> modules;
  final Set<String> specialsHere;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final layout = HomeLayout.instance;
    return Padding(
      padding: EdgeInsets.fromLTRB(_side(context), 8, _side(context), 0),
      child: HudPanel(
        hot: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Hatch(width: 10, height: 40),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('MODE PERSONNALISATION', style: hudTitle(context, size: 17)),
                    Text(
                      'Glisse les blocs, S / M / L pour la largeur, × pour retirer.',
                      style: TextStyle(color: c.muted, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                HudButton(label: '+ Bloc', onPressed: () => _add(context)),
                HudButton(label: 'Réinitialiser', onPressed: () => layout.reset()),
                HudButton(label: 'Terminé', primary: true, onPressed: () => layout.setEditing(false)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final shown = {for (final b in blocks) b.id};
    final options = [
      for (final e in HomeLayout.specials.entries)
        if (specialsHere.contains(e.key) && !shown.contains(e.key)) (e.key, e.value, Icons.dashboard_customize_rounded),
      for (final m in modules)
        if (!shown.contains('mod:${m.id}')) ('mod:${m.id}', m.name, m.icon),
    ];
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: options.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('Tous les blocs sont déjà sur ton accueil.'))
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text('AJOUTER UN BLOC', style: hudTitle(ctx, size: 18)),
                  ),
                  for (final o in options)
                    ListTile(
                      leading: Icon(o.$3),
                      title: Text(o.$2),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: () => Navigator.pop(ctx, o.$1),
                    ),
                ],
              ),
      ),
    );
    if (id != null) await HomeLayout.instance.add(blocks, id, span: id == 'fil' ? 3 : 1);
  }
}

// ------------------------------------------------------------ En-tête

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.notifications, required this.modules});

  final HubController controller;
  final NotificationCenter notifications;
  final List<HubModule> modules;

  static const _days = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM', 'DIM'];

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final now = DateTime.now();
    final userName = ModuleStore.prefs.getString('hub.name') ?? AppSession.instance.current?.name ?? '';
    final greeting = now.hour < 5 || now.hour >= 18 ? 'BONSOIR' : 'BONJOUR';
    String two(int n) => n.toString().padLeft(2, '0');
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sep = TextSpan(
      text: '  //  ',
      style: TextStyle(color: c.bracket),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(_side(context), 24, _side(context) - 8, 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 16,
        runSpacing: 12,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  style: hudLabel(context),
                  children: [
                    TextSpan(text: '${_days[now.weekday - 1]} ${two(now.day)}.${two(now.month)}.${now.year}'),
                    sep,
                    TextSpan(text: '${two(now.hour)}:${two(now.minute)}'),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$greeting${userName.isEmpty ? '' : ' ${userName.toUpperCase()}'}',
                style: hudTitle(context, size: MediaQuery.sizeOf(context).width < 600 ? 32 : 40),
              ),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: Listenable.merge([for (final m in modules) m.badge, Spaces.instance]),
                builder: (context, _) {
                  final stats = [
                    for (final m in modules)
                      if (m.badge.value > 0) '${m.badge.value} ${m.name}',
                    if (Spaces.instance.totalUnread > 0)
                      '${Spaces.instance.totalUnread} message${Spaces.instance.totalUnread > 1 ? 's' : ''} en ligne',
                  ];
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Hatch(width: 56, height: 8),
                      const SizedBox(width: 12),
                      // Une phrase normale plutôt que du jargon en majuscules.
                      Flexible(
                        child: Text(
                          stats.isEmpty ? 'Rien de nouveau' : 'Nouveau : ${stats.take(3).join(', ')}',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          // Un seul menu « Plus » : avant, sept boutons en haut, dont trois
          // qui refaisaient ce que le menu de gauche fait déjà.
          Wrap(
            spacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ListenableBuilder(
                listenable: notifications,
                builder: (context, _) => IconButton(
                  tooltip: 'Notifications',
                  icon: Badge(
                    isLabelVisible: notifications.unread > 0,
                    label: Text('${notifications.unread}'),
                    backgroundColor: c.pink,
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
              PopupMenuButton<String>(
                tooltip: 'Plus',
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (a) {
                  switch (a) {
                    case 'clicky':
                      ClickySkillsPage.open(context);
                    case 'telephone':
                      PhoneLinkPage.open(context);
                    case 'theme':
                      AppSession.instance.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark);
                    case 'perso':
                      HomeLayout.instance.setEditing(!HomeLayout.instance.editing);
                    case 'reglages':
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SettingsPage(controller: controller, notifications: notifications),
                        ),
                      );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'clicky',
                    child: ListTile(leading: Icon(Icons.auto_awesome_outlined), title: Text('Ce que Nexo sait faire')),
                  ),
                  if (Platform.isWindows)
                    const PopupMenuItem(
                      value: 'telephone',
                      child: ListTile(leading: Icon(Icons.devices_rounded), title: Text('Mon téléphone')),
                    ),
                  PopupMenuItem(
                    value: 'theme',
                    child: ListTile(
                      leading: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                      title: Text(dark ? 'Passer en clair' : 'Passer en sombre'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'perso',
                    child: ListTile(
                      leading: Icon(Icons.dashboard_customize_outlined),
                      title: Text('Personnaliser l\'accueil'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'reglages',
                    child: ListTile(leading: Icon(Icons.tune_rounded), title: Text('Réglages')),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ Console

/// La console de Nexo : une question (Entrée), ou le nom d'une appli du PC
/// (elle apparaît tout de suite : Entrée l'ouvre).
class _Console extends StatefulWidget {
  const _Console({this.onOpenApps, this.onOpenSpace});
  final VoidCallback? onOpenApps;
  final ValueChanged<Space>? onOpenSpace;

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  final _text = TextEditingController();
  List<PcApp> _apps = const [];
  List<Space> _spaces = const [];

  static const _shortcuts = [
    'fais le point',
    'qu\'est-ce que j\'ai raté',
    'prépare mon sac',
    'mode concentration 25 min',
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed(String q) {
    final t = q.trim();
    setState(() {
      _apps = t.length < 2 || !PcApps.supported ? const [] : PcApps.instance.search(t, max: 6);
      final low = t.toLowerCase();
      _spaces = t.length < 2
          ? const []
          : Spaces.instance.all.where((s) => Spaces.instance.titleOf(s).toLowerCase().contains(low)).take(3).toList();
    });
  }

  /// Entrée : l'appli dont le nom commence par le texte, sinon Nexo.
  void _submit(String q) {
    final t = q.trim();
    if (t.isEmpty) return;
    final low = t.toLowerCase();
    final app = _apps.where((a) => a.name.toLowerCase().startsWith(low)).firstOrNull;
    _clear();
    if (app != null) {
      unawaited(PcApps.instance.launch(app));
      return;
    }
    FreezeWatch.note('console : question à Nexo');
    unawaited(ClickyController.instance.ask(t));
  }

  void _clear() {
    _text.clear();
    setState(() {
      _apps = const [];
      _spaces = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(_side(context), 14, _side(context), 4),
      child: HudPanel(
        hot: true,
        padding: EdgeInsets.zero,
        cut: 18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipPath(
                    clipper: const _TabClipper(),
                    child: Container(
                      color: c.accent,
                      padding: EdgeInsets.fromLTRB(narrow ? 12 : 18, 0, narrow ? 26 : 34, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.near_me_rounded, color: Colors.white, size: 18),
                          if (!narrow) ...[
                            const SizedBox(width: 10),
                            Text(
                              'NEXO',
                              style: hudTitle(context, size: 15, color: Colors.white).copyWith(letterSpacing: 2.4),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(left: narrow ? 8 : 14, right: 6),
                    child: Center(
                      child: Text(
                        '>_',
                        style: hudMono(context, size: 17, color: c.accentText, weight: FontWeight.w700),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: TextField(
                        controller: _text,
                        onChanged: _changed,
                        onSubmitted: _submit,
                        style: hudMono(context, size: 15),
                        decoration: InputDecoration(
                          hintText: narrow
                              ? 'Demande à Nexo…'
                              : 'Demande quelque chose à Nexo, ou tape le nom d\'une appli…',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 18),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: narrow ? 6 : 12, vertical: 9),
                    child: Row(
                      children: [
                        if (!narrow) ...[const HudKey('Ctrl K'), const SizedBox(width: 10)],
                        HudButton(
                          icon: Icons.mic_rounded,
                          primary: true,
                          tooltip: 'Parler à Nexo',
                          onPressed: () => unawaited(ClickyController.instance.startListening()),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_apps.isNotEmpty || _spaces.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.hotLine)),
                ),
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (_apps.isNotEmpty)
                      Text('Applis', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.muted)),
                    for (final a in _apps)
                      ActionChip(
                        avatar: HexAvatar(a.initials, size: 20, color: HexAvatar.colorFor(a.name)),
                        label: Text(a.name),
                        onPressed: () {
                          _clear();
                          unawaited(PcApps.instance.launch(a));
                        },
                      ),
                    if (_spaces.isNotEmpty)
                      Text('Espaces', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.muted)),
                    for (final s in _spaces)
                      ActionChip(
                        avatar: HudDiamond(s.colorValue),
                        label: Text(Spaces.instance.titleOf(s)),
                        onPressed: () {
                          _clear();
                          widget.onOpenSpace?.call(s);
                        },
                      ),
                    Text(
                      _apps.isNotEmpty ? 'Entrée : ouvrir l\'appli' : 'Entrée : demander à Nexo',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.dim),
                    ),
                  ],
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.hotLine)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Essaie :', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.muted)),
                    for (final s in _shortcuts) _Cmd(text: s, onTap: () => unawaited(ClickyController.instance.ask(s))),
                    if (PcApps.supported) _Cmd(text: 'mes applis', onTap: widget.onOpenApps),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabClipper extends CustomClipper<Path> {
  const _TabClipper();

  @override
  Path getClip(Size s) => Path()
    ..lineTo(s.width, 0)
    ..lineTo(s.width - 18, s.height)
    ..lineTo(0, s.height)
    ..close();

  @override
  bool shouldReclip(_TabClipper oldClipper) => false;
}

class _Cmd extends StatelessWidget {
  const _Cmd({required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    const shape = SlantBorder(slant: 8);
    return Material(
      color: c.chip,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '» ',
                  style: TextStyle(color: c.pink, fontWeight: FontWeight.w700),
                ),
                TextSpan(text: text),
              ],
            ),
            style: hudMono(context, size: 12),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- Blocs

/// En-tête commun des blocs : « [n] TITRE » + lien.
class _BlockHead extends StatelessWidget {
  const _BlockHead({
    required this.title,
    this.action,
    this.onAction,
    this.trailing,
    this.icon,
    this.color,
    this.natural = false,
  });
  final String title;

  /// Le nom tel quel (un module), en police des titres.
  final bool natural;
  final String? action;
  final VoidCallback? onAction;
  final Widget? trailing;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          HexAvatar(
            '',
            size: 26,
            color: color ?? c.accent,
            child: Icon(icon, size: 14, color: Colors.white),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: natural
              ? Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: hudTitle(context, size: 16, weight: FontWeight.w600),
                )
              : Text(title.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: hudLabel(context)),
        ),
        ?trailing,
        if (action != null)
          InkWell(
            onTap: onAction,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text('${action!.toUpperCase()} ›', style: hudLabel(context, size: 10, color: c.accentText)),
            ),
          ),
      ],
    );
  }
}

class _ModuleBlock extends StatefulWidget {
  const _ModuleBlock({super.key, required this.module, this.onOpen});
  final HubModule module;
  final ValueChanged<HubModule>? onOpen;

  @override
  State<_ModuleBlock> createState() => _ModuleBlockState();
}

class _ModuleBlockState extends State<_ModuleBlock> {
  /// Le résumé est gardé tel quel (pas reconstruit à chaque passage de
  /// souris : avant, l'accueil ramait).
  Widget? _summary;

  @override
  void didUpdateWidget(_ModuleBlock old) {
    super.didUpdateWidget(old);
    if (old.module != widget.module) _summary = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _summary = null; // thème, taille…
  }

  void _open() {
    final m = widget.module;
    FreezeWatch.note('ouvre ${m.name}');
    widget.onOpen != null
        ? widget.onOpen!(m)
        : Navigator.push(context, MaterialPageRoute(builder: (ctx) => m.buildPage(ctx)));
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final c = HudColors.of(context);
    return HudPanel(
      padding: EdgeInsets.zero,
      onTap: _open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 4),
            child: _BlockHead(
              title: m.name,
              natural: true,
              icon: m.icon,
              color: m.color,
              trailing: ValueListenableBuilder(
                valueListenable: m.badge,
                builder: (context, n, _) =>
                    n == 0 ? const SizedBox.shrink() : HudTag('$n', color: c.pink, textColor: Colors.white),
              ),
              action: 'ouvrir',
              onAction: _open,
            ),
          ),
          Expanded(child: RepaintBoundary(child: _summary ??= m.buildSummary(context))),
        ],
      ),
    );
  }
}

/// Bloc « non connecté » : invitation à Mon Hub en ligne.
Widget _offline(BuildContext context, String title, String text) => HudPanel(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _BlockHead(title: title, icon: Icons.hub_rounded),
      const Spacer(),
      Text(text, style: TextStyle(color: HudColors.of(context).muted, height: 1.4)),
      const SizedBox(height: 12),
      HudButton(label: 'Compte en ligne', compact: true, primary: true, onPressed: () => OnlinePage.open(context)),
    ],
  ),
);

class _SpacesBlock extends StatelessWidget {
  const _SpacesBlock({this.onOpen, this.onAll});
  final ValueChanged<Space>? onOpen;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Spaces.instance, Online.instance]),
      builder: (context, _) {
        final s = Spaces.instance;
        if (!s.available) {
          return _offline(
            context,
            'Mes espaces',
            'Partage des tâches et discute avec tes amis, ta classe ou ton équipe.',
          );
        }
        final list = s.spaces;
        return HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BlockHead(title: 'Mes espaces', icon: Icons.hub_rounded, action: 'tous', onAction: onAll),
              const SizedBox(height: 8),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: HudButton(
                          label: '+ Créer un espace',
                          primary: true,
                          onPressed: () => unawaited(
                            SpaceActions.create(context).then((x) {
                              if (x != null) onOpen?.call(x);
                            }),
                          ),
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          for (final sp in list.take(6))
                            InkWell(
                              onTap: () => onOpen?.call(sp),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 9),
                                child: Row(
                                  children: [
                                    HudDiamond(sp.colorValue),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text(sp.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                    if (s.isPinned(sp.id)) Icon(Icons.push_pin_rounded, size: 13, color: c.dim),
                                    if ((s.unread[sp.id] ?? 0) > 0) ...[
                                      const SizedBox(width: 8),
                                      HudTag('${s.unread[sp.id]}', color: c.pink, textColor: Colors.white),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TasksBlock extends StatefulWidget {
  const _TasksBlock({this.onOpen});
  final ValueChanged<Space>? onOpen;

  @override
  State<_TasksBlock> createState() => _TasksBlockState();
}

class _TasksBlockState extends State<_TasksBlock> {
  List<SpaceTask> _tasks = const [];
  DateTime? _at;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    Spaces.instance.addListener(_maybeLoad);
    _maybeLoad();
  }

  @override
  void dispose() {
    Spaces.instance.removeListener(_maybeLoad);
    super.dispose();
  }

  /// Relu au plus toutes les 20 s (les espaces préviennent souvent).
  void _maybeLoad() {
    final at = _at;
    if (_loading || !Spaces.instance.available) return;
    if (at != null && DateTime.now().difference(at) < const Duration(seconds: 20)) return;
    _loading = true;
    _at = DateTime.now();
    unawaited(
      Spaces.instance
          .allTasks()
          .then((t) {
            if (mounted) setState(() => _tasks = t);
          })
          .catchError((Object _) {})
          .whenComplete(() => _loading = false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final s = Spaces.instance;
    if (!s.available) return _offline(context, 'Mes tâches', 'Les tâches de tous tes espaces partagés, ici.');
    final me = s.me;
    final mine = [
      for (final t in _tasks)
        if (t.assignee == me || t.assignee == null) t,
    ]..sort((a, b) => (a.due ?? DateTime(2999)).compareTo(b.due ?? DateTime(2999)));
    return HudPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BlockHead(
            title: 'Mes tâches',
            icon: Icons.view_kanban_rounded,
            color: const Color(0xFF3B82F6),
            trailing: Text(mine.length.toString().padLeft(2, '0'), style: hudTitle(context, size: 26, color: c.pink)),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: mine.isEmpty
                ? Center(
                    child: Text('Rien à faire pour toi. 👌', style: TextStyle(color: c.muted)),
                  )
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final t in mine.take(8))
                        InkWell(
                          onTap: () {
                            final sp = s.byId(t.spaceId);
                            if (sp != null) widget.onOpen?.call(sp);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: c.line.withValues(alpha: .6))),
                            ),
                            child: Row(
                              children: [
                                HudDiamond(s.byId(t.spaceId)?.colorValue ?? c.accent, size: 7),
                                const SizedBox(width: 10),
                                Expanded(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                if (t.due != null)
                                  Text(
                                    '${t.due!.day.toString().padLeft(2, '0')}.${t.due!.month.toString().padLeft(2, '0')}',
                                    style: hudMono(
                                      context,
                                      size: 11,
                                      color: t.lateAt(DateTime.now()) ? c.bad : c.muted,
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
      ),
    );
  }
}

class _ChatsBlock extends StatelessWidget {
  const _ChatsBlock({this.onOpen, this.onAll});
  final ValueChanged<Space>? onOpen;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Spaces.instance, Online.instance]),
      builder: (context, _) {
        final s = Spaces.instance;
        if (!s.available) {
          return _offline(context, 'Discussions', 'Écris à tes amis avec leur @pseudo, et laisse vos Nexo se parler.');
        }
        final list = [...s.chats, ...s.spaces]..sort((a, b) => (s.unread[b.id] ?? 0).compareTo(s.unread[a.id] ?? 0));
        return HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BlockHead(
                title: 'Discussions',
                icon: Icons.forum_rounded,
                color: c.pink,
                action: 'nouveau',
                onAction: () => unawaited(
                  SpaceActions.message(context).then((x) {
                    if (x != null) onOpen?.call(x);
                  }),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text('Pas encore de discussion.', style: TextStyle(color: c.muted)),
                      )
                    : ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          for (final sp in list.take(6))
                            InkWell(
                              onTap: () => onOpen?.call(sp),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Row(
                                  children: [
                                    sp.isDm
                                        ? HexAvatar(
                                            s.titleOf(sp).isEmpty ? '?' : s.titleOf(sp).substring(0, 1).toUpperCase(),
                                            size: 26,
                                          )
                                        : SizedBox(width: 26, child: Center(child: HudDiamond(sp.colorValue))),
                                    const SizedBox(width: 10),
                                    Expanded(child: Text(s.titleOf(sp), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                    if ((s.unread[sp.id] ?? 0) > 0)
                                      HudTag('${s.unread[sp.id]}', color: c.pink, textColor: Colors.white),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppsBlock extends StatelessWidget {
  const _AppsBlock({this.onAll});
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: PcApps.instance,
      builder: (context, _) {
        final p = PcApps.instance;
        final apps = [...p.pinned, ...p.frequent().where((a) => !p.isPinned(a))].take(8).toList();
        return HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BlockHead(
                title: 'Mes applis',
                icon: Icons.apps_rounded,
                color: const Color(0xFF0EA5E9),
                action: 'toutes',
                onAction: onAll,
              ),
              const SizedBox(height: 4),
              Expanded(
                child: apps.isEmpty
                    ? Center(
                        child: Text(
                          p.apps.isEmpty
                              ? 'Je lis la liste des applis du PC…'
                              : 'Ouvre une appli depuis « toutes » (clic droit : épingler).',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted),
                        ),
                      )
                    : GridView.extent(
                        maxCrossAxisExtent: 92,
                        padding: EdgeInsets.zero,
                        childAspectRatio: .95,
                        children: [
                          for (final a in apps) AppTile(app: a, small: true, onOpen: (x) => unawaited(p.launch(x))),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
