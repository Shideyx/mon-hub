import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/widgets.dart';
import 'roblox_charts.dart';
import 'roblox_game.dart';
import 'roblox_module.dart';

enum _Range {
  day('24 h', Duration(hours: 24)),
  week('7 j', Duration(days: 7)),
  month('30 j', Duration(days: 30)),
  all('Tout', Duration(days: 3650));

  const _Range(this.label, this.span);
  final String label;
  final Duration span;
}

/// Tuile de l'accueil : l'essentiel du jeu suivi.
class GameSummary extends StatelessWidget {
  const GameSummary({super.key, required this.module, required this.id});
  final RobloxModule module;
  final int id;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: module.loadGame(id),
      builder: (context, snap) {
        final g = module.game(id);
        if (g.name.isEmpty) {
          if (snap.hasError) return EmptyHint('${snap.error}');
          return const LoadingHint();
        }
        final h = module.history(id);
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _Img(url: g.icon, size: 36, radius: 8),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _mini(context, fmtShort(g.playing), 'en ligne', live: g.playing > 0),
                  _mini(context, fmtShort(g.visits), 'visites'),
                  _mini(context, fmtShort(g.favorites), 'favoris'),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: h.length < 2
                    ? Center(
                        child: Text(
                          'Courbe des joueurs dès les prochains relevés',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                        ),
                      )
                    : LineChart(
                        points: [
                          for (final x in h.where((x) => DateTime.now().difference(x.at).inHours < 24))
                            (x.at, x.playing.toDouble()),
                        ],
                        color: module.color,
                        height: 90,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _mini(BuildContext context, String v, String label, {bool live = false}) => Expanded(
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (live) ...[const Icon(Icons.circle, size: 8, color: Colors.green), const SizedBox(width: 4)],
            Text(v, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}

/// Tableau de bord complet de ton jeu.
class GameDashboard extends StatefulWidget {
  const GameDashboard({super.key, required this.module});
  final RobloxModule module;

  @override
  State<GameDashboard> createState() => _GameDashboardState();
}

class _GameDashboardState extends State<GameDashboard> with AutomaticKeepAliveClientMixin {
  RobloxModule get m => widget.module;
  _Range range = _Range.day;
  Future<RobloxGame>? future;
  Timer? _auto;
  int? _for;

  @override
  bool get wantKeepAlive => true;

  void _load({bool force = false}) {
    final id = m.selectedGame;
    _for = id;
    final f = id == null ? null : m.loadGame(id, force: force);
    setState(() {
      future = f;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Page ouverte : chiffres en direct toutes les 60 s.
    _auto = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _load(force: true);
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  Future<void> _add() async {
    final r = await askFields(
      context,
      title: 'Ajouter ton jeu',
      message:
          'Colle le lien de ton jeu (roblox.com/games/…), le lien du Creator Hub, '
          'ou son ID.',
      labels: ['Lien ou ID du jeu'],
    );
    final v = r?.first.trim() ?? '';
    if (v.isEmpty || !mounted) return;
    try {
      await m.addGame(v);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: m.store,
      builder: (context, _) {
        if (m.selectedGame != _for) {
          WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _load() : null);
        }
        if (m.gameIds.isEmpty) {
          return EmptyHint(
            'Ajoute ton jeu Roblox pour suivre en direct ses joueurs, ses visites, '
            'ses favoris, ses serveurs, ses badges et ses passes.',
            icon: Icons.videogame_asset_rounded,
            action: ('Ajouter mon jeu', _add),
          );
        }
        return FutureBuilder(
          future: future,
          builder: (context, snap) {
            final id = m.selectedGame!;
            final g = m.game(id);
            if (g.name.isEmpty) {
              if (snap.hasError) {
                return EmptyHint('${snap.error}', action: ('Réessayer', () => _load(force: true)));
              }
              return const LoadingHint();
            }
            return RefreshIndicator(
              onRefresh: () async {
                _load(force: true);
                await future;
              },
              child: _body(context, g, snap.connectionState == ConnectionState.waiting),
            );
          },
        );
      },
    );
  }

  Widget _body(BuildContext context, RobloxGame g, bool loading) {
    final h = m.history(g.universeId);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final sections = <Widget>[
      _players(context, g, h),
      _growth(context, g, h),
      _servers(context, g),
      _badges(context, g),
      _passes(context, g),
      _about(context, g),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
      children: [
        _gamePicker(context, g, loading),
        const SizedBox(height: 12),
        _hero(context, g),
        const SizedBox(height: 12),
        _kpis(context, g, h),
        const SizedBox(height: 12),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(children: [sections[0], sections[2], sections[4]])),
              const SizedBox(width: 12),
              Expanded(child: Column(children: [sections[1], sections[3], sections[5]])),
            ],
          )
        else
          ...sections,
      ],
    );
  }

  Widget _gamePicker(BuildContext context, RobloxGame g, bool loading) {
    final ids = m.gameIds;
    return Row(
      children: [
        Expanded(
          child: ids.length < 2
              ? Text('Tableau de bord', style: Theme.of(context).textTheme.titleLarge)
              : DropdownButton<int>(
                  value: g.universeId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final id in ids)
                      DropdownMenuItem(value: id, child: Text(m.game(id).name.isEmpty ? 'Jeu $id' : m.game(id).name)),
                  ],
                  onChanged: (v) => v == null ? null : m.selectGame(v),
                ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (g.fetchedAt != null)
          Text('à ${fmtWhen(g.fetchedAt!, withDay: false)}', style: Theme.of(context).textTheme.labelSmall),
        IconButton(tooltip: 'Actualiser', icon: const Icon(Icons.refresh_rounded), onPressed: () => _load(force: true)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'add') await _add();
            if (v == 'remove') {
              await m.removeGame(g.universeId);
              _load();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'add', child: Text('Ajouter un autre jeu')),
            PopupMenuItem(value: 'remove', child: Text('Retirer ce jeu')),
          ],
        ),
      ],
    );
  }

  Widget _hero(BuildContext context, RobloxGame g) {
    final banner = g.thumbnails.firstOrNull;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Stack(
        children: [
          Positioned.fill(
            child: banner == null
                ? Container(color: m.color.withValues(alpha: 0.2))
                : Image.network(banner, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.05), Colors.black.withValues(alpha: 0.8)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 70, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Img(url: g.icon, size: 72, radius: 14),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.name,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        [
                          if (g.creator.isNotEmpty) 'par ${g.creator}',
                          if (g.genre.isNotEmpty && g.genre != 'All') g.genre,
                          if (g.updated != null) 'mis à jour ${timeAgo(g.updated!)}',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Jouer'),
                            onPressed: () => openLink(context, g.playUrl),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.insights_rounded),
                            label: const Text('Analytics (Creator Hub)'),
                            onPressed: () => openLink(context, g.analyticsUrl),
                          ),
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.settings_rounded),
                            label: const Text('Gérer'),
                            onPressed: () => openLink(context, g.creatorHubUrl),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  GameSnapshot? _ago(List<GameSnapshot> h, Duration d) {
    final t = DateTime.now().subtract(d);
    GameSnapshot? best;
    for (final x in h) {
      if (x.at.isAfter(t)) break;
      best = x;
    }
    // Pas de relevé assez ancien : on prend le plus ancien s'il a au moins 1 h.
    if (best == null && h.isNotEmpty && DateTime.now().difference(h.first.at).inMinutes >= 60) {
      best = h.first;
    }
    return best;
  }

  Widget _kpis(BuildContext context, RobloxGame g, List<GameSnapshot> h) {
    final day = _ago(h, const Duration(hours: 24));
    String? delta(int now, int? then) {
      if (then == null) return null;
      final d = now - then;
      return '${d >= 0 ? '+' : ''}${fmtShort(d)} ${_since(day!.at)}';
    }

    final peak = h.isEmpty ? g.playing : math.max(g.playing, h.map((x) => x.playing).reduce(math.max));
    final like = g.likeRatio;
    final fill = g.servers.isEmpty
        ? null
        : g.servers.map((s) => s.maxPlayers == 0 ? 0.0 : s.playing / s.maxPlayers).reduce((a, b) => a + b) /
              g.servers.length;
    final tiles = [
      _Kpi(
        'Joueurs en ligne',
        fmtInt(g.playing),
        Icons.circle,
        sub: 'pic enregistré : ${fmtInt(peak)}',
        live: g.playing > 0,
      ),
      _Kpi(
        'Visites',
        fmtShort(g.visits),
        Icons.visibility_rounded,
        sub: delta(g.visits, day?.visits) ?? fmtInt(g.visits),
      ),
      _Kpi(
        'Favoris',
        fmtShort(g.favorites),
        Icons.star_rounded,
        sub:
            delta(g.favorites, day?.favorites) ??
            (g.visits == 0
                ? null
                : '${(g.favorites / g.visits * 100).toStringAsFixed(2).replaceAll('.', ',')} % des visites'),
      ),
      _Kpi(
        'J\'aime',
        like == null ? '—' : '${(like * 100).round()} %',
        Icons.thumb_up_alt_rounded,
        sub: '👍 ${fmtShort(g.upVotes)} · 👎 ${fmtShort(g.downVotes)}',
      ),
      _Kpi(
        'Serveurs actifs',
        '${g.servers.length}${g.serversTruncated ? '+' : ''}',
        Icons.dns_rounded,
        sub: fill == null ? '${g.maxPlayers} places par serveur' : 'remplis à ${(fill * 100).round()} %',
      ),
      _Kpi(
        'Badges',
        '${g.badges.length}',
        Icons.military_tech_rounded,
        sub: g.badges.isEmpty ? null : '${fmtShort(g.badges.fold<int>(0, (a, b) => a + b.pastDay))} obtenus en 24 h',
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final cols = (box.maxWidth / 200).floor().clamp(2, 6);
        final w = (box.maxWidth - (cols - 1) * 10) / cols;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }

  String _since(DateTime t) {
    final d = DateTime.now().difference(t);
    return d.inHours >= 23 ? 'en 24 h' : 'en ${d.inHours} h';
  }

  Widget _section(BuildContext context, String title, Widget child, {Widget? trailing, String? note}) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
          if (note != null) ...[const SizedBox(height: 8), Text(note, style: Theme.of(context).textTheme.labelSmall)],
        ],
      ),
    ),
  );

  Widget _rangePicker() => SegmentedButton<_Range>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: [for (final r in _Range.values) ButtonSegment(value: r, label: Text(r.label))],
    selected: {range},
    onSelectionChanged: (s) => setState(() => range = s.first),
  );

  List<GameSnapshot> _inRange(List<GameSnapshot> h) {
    final t = DateTime.now().subtract(range.span);
    return h.where((x) => x.at.isAfter(t)).toList();
  }

  Widget _players(BuildContext context, RobloxGame g, List<GameSnapshot> h) {
    final pts = [for (final x in _inRange(h)) (x.at, x.playing.toDouble())];
    return _section(
      context,
      'Joueurs en ligne',
      LineChart(points: pts, color: m.color, height: 200),
      trailing: _rangePicker(),
      note: 'Un relevé toutes les 10 min tant que Mon Hub est ouvert (toutes les 5 min quand cette page est ouverte).',
    );
  }

  Widget _growth(BuildContext context, RobloxGame g, List<GameSnapshot> h) {
    // Nouvelles visites par jour (différence entre le premier et le dernier
    // relevé de chaque jour, 14 derniers jours).
    final byDay = <DateTime, (int, int)>{};
    for (final x in h) {
      final d = DateTime(x.at.year, x.at.month, x.at.day);
      final cur = byDay[d];
      byDay[d] = cur == null ? (x.visits, x.visits) : (math.min(cur.$1, x.visits), math.max(cur.$2, x.visits));
    }
    final days = byDay.keys.toList()..sort();
    final bars = <(String, double)>[];
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      // Visites du jour = fin du jour − fin du jour précédent (ou début du jour).
      final start = i > 0 ? byDay[days[i - 1]]!.$2 : byDay[d]!.$1;
      bars.add(('${d.day}/${d.month}', (byDay[d]!.$2 - start).toDouble()));
    }
    final last14 = bars.length > 14 ? bars.sublist(bars.length - 14) : bars;
    return _section(
      context,
      'Nouvelles visites par jour',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BarChart(bars: last14, color: m.color),
          const SizedBox(height: 16),
          Text('Favoris au fil du temps', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          LineChart(
            points: [for (final x in _inRange(h)) (x.at, x.favorites.toDouble())],
            color: m.color,
            height: 140,
            zeroBased: false,
          ),
        ],
      ),
      note: 'Les jours apparaissent au fur et à mesure des relevés faits par Mon Hub.',
    );
  }

  Widget _servers(BuildContext context, RobloxGame g) {
    final scheme = Theme.of(context).colorScheme;
    final list = [...g.servers]..sort((a, b) => b.playing.compareTo(a.playing));
    return _section(
      context,
      'Serveurs publics (${g.servers.length}${g.serversTruncated ? '+' : ''})',
      list.isEmpty
          ? const Text('Aucun serveur ouvert en ce moment.')
          : Column(
              children: [
                for (final s in list.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 76,
                          child: Text(
                            '${s.playing}/${s.maxPlayers}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: s.maxPlayers == 0 ? 0 : s.playing / s.maxPlayers,
                              minHeight: 8,
                              color: m.color,
                              backgroundColor: scheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: Text(
                            [
                              if (s.ping != null) '${s.ping} ms',
                              if (s.fps != null) '${s.fps!.round()} img/s',
                            ].join(' · '),
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (list.length > 12)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '… et ${list.length - 12} autres serveurs',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _badges(BuildContext context, RobloxGame g) {
    final list = [...g.badges]..sort((a, b) => b.awarded.compareTo(a.awarded));
    return _section(
      context,
      'Badges (${g.badges.length})',
      list.isEmpty
          ? const Text('Ton jeu n\'a pas encore de badge.')
          : Column(
              children: [
                for (final b in list.take(15))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _Img(url: b.icon, size: 36, radius: 18),
                    title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${fmtInt(b.awarded)} obtenus · +${fmtInt(b.pastDay)} en 24 h'),
                    trailing: Text(
                      '${b.winRate.toStringAsFixed(1).replaceAll('.', ',')} %',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
      note: list.isEmpty ? null : 'Le pourcentage = part des joueurs qui ont obtenu le badge (rareté).',
    );
  }

  Widget _passes(BuildContext context, RobloxGame g) {
    return _section(
      context,
      'Game passes (${g.passes.length})',
      g.passes.isEmpty
          ? const Text('Aucun game pass en vente.')
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final p in g.passes)
                  SizedBox(
                    width: 120,
                    child: Column(
                      children: [
                        _Img(url: p.icon, size: 72, radius: 12),
                        const SizedBox(height: 4),
                        Text(p.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                        Text(
                          p.price == null ? 'Pas en vente' : '${fmtInt(p.price!)} R\$',
                          style: TextStyle(color: m.color, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      note: 'Les Robux gagnés et les ventes détaillées sont sur le Creator Hub (bouton Analytics).',
    );
  }

  Widget _about(BuildContext context, RobloxGame g) {
    return _section(
      context,
      'Fiche du jeu',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (g.thumbnails.length > 1)
            SizedBox(
              height: 110,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in g.thumbnails)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          t,
                          height: 110,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          if (g.description.isNotEmpty) SelectableText(g.description, maxLines: 8),
          const SizedBox(height: 8),
          Text(
            [
              if (g.created != null) 'Créé le ${g.created!.day}/${g.created!.month}/${g.created!.year}',
              '${g.maxPlayers} joueurs max par serveur',
              'ID univers ${g.universeId}',
              'ID place ${g.rootPlaceId}',
            ].join(' · '),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.icon, {this.sub, this.live = false});
  final String label;
  final String value;
  final IconData icon;
  final String? sub;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: live ? 10 : 16, color: live ? Colors.green : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            if (sub != null)
              Text(sub!, style: Theme.of(context).textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _Img extends StatelessWidget {
  const _Img({required this.url, required this.size, required this.radius});
  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.videogame_asset_rounded, size: size * 0.5),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? box
          : Image.network(url!, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => box),
    );
  }
}
