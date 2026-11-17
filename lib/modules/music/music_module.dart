import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/hub_module.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';
import 'cd_case.dart';
import 'media_session.dart';
import 'music_api.dart';
import 'music_models.dart';

/// Musique : ce que tu écoutes (Spotify, Deezer, ou n'importe quel lecteur
/// du PC), avec la boîte de CD qui tourne, la pochette et la tracklist ; tes
/// titres likés, tes playlists, tes écoutes récentes.
class MusicModule extends HubModule {
  @override
  String get id => 'music';
  @override
  String get name => 'Musique';
  @override
  String get description => 'Ce que tu écoutes sur Spotify ou Deezer, titres likés et playlists';
  @override
  IconData get icon => Icons.album_rounded;
  @override
  Color get color => musicRed;
  @override
  ApiAccess get access => ApiAccess.official;

  late final spotify = SpotifyApi(store);
  final deezer = DeezerApi();
  late final player = MusicPlayer(this);

  String? get deezerId => store.getJson<String>('deezer.user');

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'musique_en_cours',
      description: 'Le morceau en train de jouer (titre, artiste, album, position) et la liste des titres de l\'album.',
      run: (_) async {
        await player.refresh();
        final np = player.now;
        if (np == null) return 'Rien en écoute';
        return {
          'titre': np.title,
          'artiste': np.artist,
          'album': np.album,
          'en_lecture': np.playing,
          'position': formatDuration(np.positionNow()),
          if (np.duration != null) 'duree': formatDuration(np.duration!),
          'appli': np.appName,
          if (player.album != null) 'tracklist': [for (final t in player.album!.tracks) t.title],
        };
      },
    ),
    HubTool(
      name: 'musique_titres_likes',
      description: 'Mes titres likés (Spotify, ou favoris Deezer), les plus récents d\'abord.',
      run: (_) async => [
        for (final t in (await player.liked()).take(60)) '${t.artist} - ${t.title}',
      ],
    ),
    HubTool(
      name: 'musique_playlists',
      description: 'Mes playlists (Spotify ou Deezer).',
      run: (_) async => [
        for (final p in await player.playlists()) {'nom': p.name, 'titres': p.count},
      ],
    ),
    HubTool(
      name: 'musique_commande',
      description: 'Contrôle la musique : lecture, pause, suivant ou precedent.',
      params: {'action': ('string', 'lecture, pause, suivant ou precedent')},
      required: ['action'],
      run: (a) async {
        switch ('${a['action']}'.toLowerCase()) {
          case 'suivant' || 'next':
            await player.next();
          case 'precedent' || 'précédent' || 'previous':
            await player.previous();
          default:
            await player.toggle();
        }
        return {'ok': true};
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => NowPlayingTile(module: this);

  @override
  Widget buildPage(BuildContext context) => _MusicPage(module: this);

  Future<void> showSettings(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => _MusicSettings(module: this),
  );
}

/// État de la musique : morceau en cours, album, couleur, commandes.
class MusicPlayer extends ChangeNotifier {
  MusicPlayer(this.m);
  final MusicModule m;

  NowPlaying? _win;
  NowPlaying? _spot;
  AlbumInfo? album;
  Color accent = musicRed;
  String? error;
  bool? isLiked;

  WindowsMediaSession? _session;
  Timer? _poll;
  bool _started = false;
  String _albumKey = '';
  String _accentKey = '';
  String _likedId = '';
  final _albums = <String, AlbumInfo?>{};

  /// Ce qui joue : le lecteur du PC s'il joue, sinon Spotify.
  NowPlaying? get now {
    final w = _win, s = _spot;
    if (w != null && (w.playing || s == null || !s.playing)) {
      // Même morceau sur Spotify : on garde ses infos (album, j'aime).
      if (s != null && s.title == w.title) {
        return NowPlaying(
          title: w.title,
          artist: w.artist,
          album: w.album.isEmpty ? s.album : w.album,
          albumArtist: s.albumArtist,
          coverUrl: s.coverUrl,
          coverBytes: w.coverBytes,
          position: w.position,
          duration: w.duration ?? s.duration,
          playing: w.playing,
          app: w.app,
          at: w.at,
          trackNumber: s.trackNumber,
          spotifyAlbumId: s.spotifyAlbumId,
          trackId: s.trackId,
        );
      }
      return w;
    }
    return s;
  }

  /// Pour les tests et les captures : un morceau et son album.
  @visibleForTesting
  void debugShow(NowPlaying np, AlbumInfo? a, {Color? color}) {
    _started = true;
    _win = np;
    album = a;
    _albumKey = 'debug';
    _accentKey = 'debug';
    if (color != null) accent = color;
    notifyListeners();
  }

  /// Démarre la lecture de « ce qui joue » (une seule fois).
  void ensureStarted() {
    if (_started) return;
    _started = true;
    if (WindowsMediaSession.supported) {
      _session = WindowsMediaSession((np) {
        _win = np;
        _changed();
      })..start();
    }
    unawaited(refresh());
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => refresh());
  }

  Future<void> refresh() async {
    if (!m.spotify.connected) {
      _spot = null;
      return;
    }
    try {
      _spot = await m.spotify.current();
      error = null;
    } catch (e) {
      error = '$e';
    }
    _changed();
  }

  void _changed() {
    notifyListeners();
    final np = now;
    if (np == null) return;
    unawaited(_loadAlbum(np));
    unawaited(_loadAccent(np));
    unawaited(_loadLiked(np));
  }

  Future<void> _loadAlbum(NowPlaying np) async {
    final key =
        np.spotifyAlbumId ??
        '${np.albumArtist.isEmpty ? np.artist : np.albumArtist}|${np.album}|${np.album.isEmpty ? np.title : ''}';
    if (key == _albumKey) return;
    _albumKey = key;
    if (_albums.containsKey(key)) {
      album = _albums[key];
      return notifyListeners();
    }
    album = null;
    AlbumInfo? a;
    try {
      if (np.spotifyAlbumId != null && m.spotify.connected) {
        a = await m.spotify.album(np.spotifyAlbumId!);
      } else {
        a = await m.deezer.findAlbum(
          np.albumArtist.isEmpty ? np.artist : np.albumArtist,
          np.album,
          np.title,
        );
      }
    } catch (_) {}
    _albums[key] = a;
    if (_albumKey == key) {
      album = a;
      notifyListeners();
      if (a?.cover != null) unawaited(_loadAccent(np));
    }
  }

  /// Pochette à montrer : celle de l'album en HD, sinon celle de Windows.
  String? get coverUrl => album?.cover ?? now?.coverUrl;

  Future<void> _loadAccent(NowPlaying np) async {
    final p = CoverImage.provider(coverUrl, np.coverBytes);
    final key = coverUrl ?? '${np.coverBytes?.length}';
    if (p == null || key == _accentKey) return;
    _accentKey = key;
    final c = await coverAccent(p);
    if (c != null && c != accent) {
      accent = c;
      notifyListeners();
    }
  }

  Future<void> _loadLiked(NowPlaying np) async {
    if (np.trackId.isEmpty || np.trackId == _likedId || !m.spotify.connected) return;
    _likedId = np.trackId;
    try {
      isLiked = await m.spotify.isLiked(np.trackId);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleLike() async {
    final np = now;
    if (np == null || np.trackId.isEmpty) return;
    final next = !(isLiked ?? false);
    isLiked = next;
    notifyListeners();
    try {
      await m.spotify.setLiked(np.trackId, next);
    } catch (e) {
      isLiked = !next;
      error = '$e';
      notifyListeners();
    }
  }

  bool get _useWindows => _session != null && _win != null;

  Future<void> toggle() async {
    if (_useWindows) return _session!.toggle();
    final np = now;
    if (np == null) return;
    np.playing ? await m.spotify.pause() : await m.spotify.resume();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refresh();
  }

  Future<void> next() async {
    if (_useWindows) return _session!.next();
    await m.spotify.next();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await refresh();
  }

  Future<void> previous() async {
    if (_useWindows) return _session!.previous();
    await m.spotify.previous();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await refresh();
  }

  /// Titres likés : Spotify si connecté, sinon favoris Deezer.
  Future<List<MusicTrack>> liked() async {
    if (m.spotify.connected) return m.spotify.liked();
    final d = m.deezerId;
    if (d != null) return m.deezer.favorites(d);
    throw 'Connecte Spotify ou ton profil Deezer (icône réglages)';
  }

  Future<List<MusicPlaylist>> playlists() async {
    if (m.spotify.connected) return m.spotify.playlists();
    final d = m.deezerId;
    if (d != null) return m.deezer.playlists(d);
    throw 'Connecte Spotify ou ton profil Deezer (icône réglages)';
  }

  Future<List<MusicTrack>> playlistTracks(MusicPlaylist p) =>
      m.spotify.connected && p.uri.isNotEmpty
      ? m.spotify.playlistTracks(p.id)
      : m.deezer.playlistTracks(p.id);

  /// Lance un morceau : sur ton Spotify (Premium) ou dans l'appli.
  Future<void> playTrack(BuildContext context, MusicTrack t, {String? context_}) async {
    if (t.uri.startsWith('spotify:') && m.spotify.connected) {
      try {
        await m.spotify.play(uri: t.uri, context: context_);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await refresh();
        return;
      } catch (_) {
        // Pas Premium, ou aucun appareil actif : on ouvre l'appli.
      }
      final ok = await launchUrl(Uri.parse(t.uri), mode: LaunchMode.externalApplication);
      if (ok) return;
    }
    if (t.link != null && context.mounted) await openLink(context, t.link!);
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_session?.stop());
    super.dispose();
  }
}

/// Reconstruit chaque seconde (compteur) tant que la musique joue.
class _EverySecond extends StatefulWidget {
  const _EverySecond({required this.active, required this.builder});
  final bool active;
  final WidgetBuilder builder;

  @override
  State<_EverySecond> createState() => _EverySecondState();
}

class _EverySecondState extends State<_EverySecond> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_EverySecond old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && _t == null) {
      _t = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    } else if (!widget.active) {
      _t?.cancel();
      _t = null;
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// La boîte de CD du morceau en cours.
Widget _case(MusicPlayer p, NowPlaying? np) {
  final album = p.album;
  final tracks = album?.tracks ?? [if (np != null) MusicTrack(title: np.title, artist: np.artist)];
  final current = np == null ? 0 : (album?.indexOf(np.title) ?? 1);
  return SpinningCdCase(
    spinning: np?.playing ?? false,
    front: CdCaseFront(coverUrl: p.coverUrl, coverBytes: np?.coverBytes, color: p.accent),
    back: CdCaseBack(
      title: album?.title ?? np?.album ?? np?.title ?? 'Mon Hub',
      artist: album?.artist ?? np?.artist ?? '',
      tracks: tracks,
      current: current == 0 && album == null ? 1 : current,
      color: p.accent,
    ),
  );
}

/// La tuile du tableau de bord : la boîte de CD qui tourne, le titre en
/// cours, les commandes.
class NowPlayingTile extends StatefulWidget {
  const NowPlayingTile({super.key, required this.module});
  final MusicModule module;

  @override
  State<NowPlayingTile> createState() => _NowPlayingTileState();
}

class _NowPlayingTileState extends State<NowPlayingTile> {
  MusicPlayer get p => widget.module.player;

  @override
  void initState() {
    super.initState();
    p.ensureStarted();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: p,
    builder: (context, _) {
      final np = p.now;
      if (np == null) {
        return EmptyHint(
          WindowsMediaSession.supported
              ? 'Lance Spotify ou Deezer : ton morceau apparaît ici, avec sa pochette qui tourne.'
              : 'Connecte Spotify pour voir ce que tu écoutes.',
          icon: Icons.album_rounded,
          action: widget.module.spotify.connected || WindowsMediaSession.supported
              ? null
              : ('Connecter', () => widget.module.showSettings(context)),
        );
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [musicCream, musicCream, p.accent.withValues(alpha: 0.9)],
            stops: const [0, 0.5, 0.5],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(flex: 5, child: Center(child: _case(p, np))),
              const SizedBox(width: 10),
              Expanded(
                flex: 5,
                child: _EverySecond(
                  active: np.playing,
                  builder: (context) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatClock(np.positionNow()).split('').join(' '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        np.title.toLowerCase(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                          height: 1.05,
                          shadows: [Shadow(color: Colors.black26, blurRadius: 6)],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        np.artist.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          letterSpacing: 2.5,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _Controls(p: p, np: np, small: true),
                    ],
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

/// Lecture / pause, précédent, suivant, j'aime.
class _Controls extends StatelessWidget {
  const _Controls({required this.p, required this.np, this.small = false});
  final MusicPlayer p;
  final NowPlaying np;
  final bool small;

  Future<void> _run(BuildContext context, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = small ? 22.0 : 34.0;
    final dense = small ? VisualDensity.compact : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Précédent',
          visualDensity: dense,
          color: Colors.white,
          iconSize: s,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: () => _run(context, p.previous),
        ),
        IconButton(
          tooltip: np.playing ? 'Pause' : 'Lecture',
          visualDensity: dense,
          color: Colors.white,
          iconSize: s * 1.3,
          icon: Icon(
            np.playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
          ),
          onPressed: () => _run(context, p.toggle),
        ),
        IconButton(
          tooltip: 'Suivant',
          visualDensity: dense,
          color: Colors.white,
          iconSize: s,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: () => _run(context, p.next),
        ),
        if (np.trackId.isNotEmpty)
          IconButton(
            tooltip: p.isLiked == true ? 'Retirer des titres likés' : 'Ajouter aux titres likés',
            visualDensity: dense,
            color: Colors.white,
            iconSize: s * 0.8,
            icon: Icon(p.isLiked == true ? Icons.favorite_rounded : Icons.favorite_border_rounded),
            onPressed: () => _run(context, p.toggleLike),
          ),
      ],
    );
  }
}

/// L'écran « En écoute » : fond coupé en deux, titre en grand, artiste,
/// tracklist, compteur, et la boîte de CD qui tourne.
class NowPlayingStage extends StatelessWidget {
  const NowPlayingStage({super.key, required this.p});
  final MusicPlayer p;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: p,
    builder: (context, _) {
      final np = p.now;
      return SplitBackground(
        color: p.accent,
        child: _EverySecond(
          active: np?.playing ?? false,
          builder: (context) => LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 820;
              final left = _left(context, np, wide, box);
              final right = _right(context, np, wide);
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(56, 24, 32, 24),
                  child: Row(
                    children: [
                      Expanded(flex: 46, child: left),
                      const SizedBox(width: 24),
                      Expanded(flex: 54, child: right),
                    ],
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  SizedBox(height: box.maxWidth * 0.95, child: right),
                  left,
                ],
              );
            },
          ),
        ),
      );
    },
  );

  Widget _left(BuildContext context, NowPlaying? np, bool wide, BoxConstraints box) {
    final dark = Color.lerp(p.accent, Colors.black, 0.25)!;
    final album = p.album;
    final current = np == null ? 0 : (album?.indexOf(np.title) ?? 0);
    final title = np?.title ?? 'rien en écoute';
    final big = (wide ? box.maxWidth * 0.075 : box.maxWidth * 0.13).clamp(34.0, 120.0);
    final tracks = album?.tracks ?? const <MusicTrack>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // Le titre écouté, en très grand.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(-0.05, 0), end: Offset.zero).animate(a),
              child: c,
            ),
          ),
          child: Text(
            title.toLowerCase(),
            key: ValueKey(title),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.accent,
              fontSize: big,
              fontWeight: FontWeight.w800,
              height: 0.98,
              letterSpacing: -1,
              shadows: [Shadow(color: p.accent.withValues(alpha: 0.25), blurRadius: 18)],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          (np?.artist ?? '').toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: dark,
            fontSize: 16,
            letterSpacing: 7,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (album != null &&
            album.title.isNotEmpty &&
            album.title.toLowerCase() != title.toLowerCase())
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${album.title}${album.year == null || album.year!.isEmpty ? '' : ' · ${album.year}'}',
              style: TextStyle(
                color: dark.withValues(alpha: 0.7),
                fontSize: 13,
                letterSpacing: 1.5,
              ),
            ),
          ),
        const SizedBox(height: 26),
        if (tracks.isEmpty && np != null)
          Text(
            'Recherche de la tracklist…',
            style: TextStyle(color: dark.withValues(alpha: 0.5), letterSpacing: 2),
          ),
        for (final (i, t) in tracks.take(wide ? 12 : 30).indexed)
          _TrackRow(
            n: i + 1,
            text: '${t.artist.isEmpty ? album!.artist : t.artist} - ${t.title.toUpperCase()}',
            current: i + 1 == current,
            color: p.accent,
          ),
      ],
    );
  }

  Widget _right(BuildContext context, NowPlaying? np, bool wide) => Column(
    children: [
      Text(
        formatClock(np?.positionNow() ?? Duration.zero).split('').join(' '),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 4,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: Center(
          child: FractionallySizedBox(widthFactor: wide ? 0.82 : 0.9, child: _case(p, np)),
        ),
      ),
      if (np != null) ...[
        if (np.duration != null && np.duration! > Duration.zero)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              children: [
                Text(
                  formatDuration(np.positionNow()),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (np.positionNow().inMilliseconds / np.duration!.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      ),
                      minHeight: 3,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatDuration(np.duration!),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        _Controls(p: p, np: np),
        if (np.appName.isNotEmpty)
          Text(
            'sur ${np.appName}',
            style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2),
          ),
      ] else
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Lance un morceau sur Spotify ou Deezer.',
            style: TextStyle(color: Colors.white),
          ),
        ),
    ],
  );
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.n,
    required this.text,
    required this.current,
    required this.color,
  });
  final int n;
  final String text;
  final bool current;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ink = Color.lerp(color, Colors.black, 0.45)!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: current ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              n.toString().padLeft(2, '0'),
              style: TextStyle(
                color: current ? Colors.white : ink.withValues(alpha: 0.45),
                fontSize: 12,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: current ? Colors.white : ink.withValues(alpha: 0.4),
                fontSize: 15,
                letterSpacing: 2,
                fontWeight: current ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          if (current) const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 18),
        ],
      ),
    );
  }
}

class _MusicPage extends StatelessWidget {
  const _MusicPage({required this.module});
  final MusicModule module;

  @override
  Widget build(BuildContext context) {
    module.player.ensureStarted();
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(module.name),
          actions: [
            IconButton(
              tooltip: 'Spotify et Deezer',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => module.showSettings(context),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(icon: Icon(Icons.album_rounded), text: 'En écoute'),
              Tab(icon: Icon(Icons.favorite_rounded), text: 'Titres likés'),
              Tab(icon: Icon(Icons.queue_music_rounded), text: 'Playlists'),
              Tab(icon: Icon(Icons.history_rounded), text: 'Récents'),
              Tab(icon: Icon(Icons.public_rounded), text: 'Lecteur web'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: module.store,
          builder: (context, _) => TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              NowPlayingStage(p: module.player),
              _TrackList(
                key: const ValueKey('liked'),
                module: module,
                load: module.player.liked,
                empty: 'Aucun titre liké',
              ),
              _Playlists(module: module),
              module.spotify.connected
                  ? _TrackList(
                      key: const ValueKey('recent'),
                      module: module,
                      load: module.spotify.recent,
                      empty: 'Aucune écoute récente',
                      dates: true,
                    )
                  : EmptyHint(
                      'Les écoutes récentes viennent de Spotify : connecte ton compte.',
                      icon: Icons.history_rounded,
                      action: ('Connecter Spotify', () => module.showSettings(context)),
                    ),
              const _WebPlayer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Liste de morceaux (likés, playlist, récents), avec extrait de 30 s pour
/// Deezer.
class _TrackList extends StatefulWidget {
  const _TrackList({
    super.key,
    required this.module,
    required this.load,
    required this.empty,
    this.dates = false,
    this.contextUri,
  });
  final MusicModule module;
  final Future<List<MusicTrack>> Function() load;
  final String empty;
  final bool dates;
  final String? contextUri;

  @override
  State<_TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<_TrackList> with AutomaticKeepAliveClientMixin {
  late Future<List<MusicTrack>> future = widget.load();
  final search = TextEditingController();
  AudioPlayer? _preview;
  String? _previewing;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    unawaited(_preview?.dispose());
    super.dispose();
  }

  Future<void> _togglePreview(MusicTrack t) async {
    final p = _preview ??= AudioPlayer();
    if (_previewing == t.id) {
      await p.stop();
      setState(() => _previewing = null);
      return;
    }
    setState(() => _previewing = t.id);
    try {
      await p.stop();
      await p.play(UrlSource(t.preview!));
    } catch (e) {
      if (mounted) showError(context, 'Extrait illisible : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final color = widget.module.color;
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => future = widget.load());
        await future;
      },
      child: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ListView(
              children: [
                ErrorBanner('${snap.error}'),
                Center(
                  child: TextButton(
                    onPressed: () => widget.module.showSettings(context),
                    child: const Text('Réglages Spotify / Deezer'),
                  ),
                ),
              ],
            );
          }
          if (!snap.hasData) return const LoadingHint();
          final all = snap.data!;
          return ListenableBuilder(
            listenable: search,
            builder: (context, _) {
              final q = search.text.toLowerCase().trim();
              final list = q.isEmpty
                  ? all
                  : all
                        .where((t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q))
                        .toList();
              return ListView.builder(
                itemCount: list.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: TextField(
                        controller: search,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: all.isEmpty
                              ? widget.empty
                              : 'Rechercher parmi ${all.length} titres',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    );
                  }
                  final t = list[i - 1];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: CoverImage(url: t.cover, color: color),
                      ),
                    ),
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        t.artist,
                        if (t.album.isNotEmpty) t.album,
                        if (widget.dates && t.addedAt != null) timeAgo(t.addedAt!.toLocal()),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (t.duration != null) Text(formatDuration(t.duration!)),
                        if (t.preview != null)
                          IconButton(
                            tooltip: 'Écouter un extrait (30 s)',
                            icon: Icon(
                              _previewing == t.id
                                  ? Icons.stop_circle_rounded
                                  : Icons.play_circle_outline_rounded,
                            ),
                            onPressed: () => _togglePreview(t),
                          ),
                      ],
                    ),
                    onTap: () =>
                        widget.module.player.playTrack(context, t, context_: widget.contextUri),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _Playlists extends StatefulWidget {
  const _Playlists({required this.module});
  final MusicModule module;

  @override
  State<_Playlists> createState() => _PlaylistsState();
}

class _PlaylistsState extends State<_Playlists> with AutomaticKeepAliveClientMixin {
  late Future<List<MusicPlaylist>> future = widget.module.player.playlists();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final m = widget.module;
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => future = m.player.playlists());
        await future;
      },
      child: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return ListView(children: [ErrorBanner('${snap.error}')]);
          if (!snap.hasData) return const LoadingHint();
          final list = snap.data!;
          if (list.isEmpty) return const EmptyHint('Aucune playlist');
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final p = list[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(p.name)),
                      body: _TrackList(
                        module: m,
                        load: () => m.player.playlistTracks(p),
                        empty: 'Playlist vide',
                        contextUri: p.uri.isEmpty ? null : p.uri,
                      ),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CoverImage(url: p.cover, color: m.color),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${p.count} titres${p.owner.isEmpty ? '' : ' · ${p.owner}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Spotify ou Deezer dans l'appli (ton compte habituel).
class _WebPlayer extends StatefulWidget {
  const _WebPlayer();

  @override
  State<_WebPlayer> createState() => _WebPlayerState();
}

class _WebPlayerState extends State<_WebPlayer> with AutomaticKeepAliveClientMixin {
  String? url;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final u = url;
    if (u == null) {
      return Center(
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1DB954)),
              icon: const Icon(Icons.music_note_rounded),
              label: const Text('Spotify'),
              onPressed: () => setState(() => url = 'https://open.spotify.com/'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFA238FF)),
              icon: const Icon(Icons.graphic_eq_rounded),
              label: const Text('Deezer'),
              onPressed: () => setState(() => url = 'https://www.deezer.com/'),
            ),
          ],
        ),
      );
    }
    if (!webLoginSupported) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Ouvrir'),
          onPressed: () => openLink(context, u),
        ),
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('Changer de service'),
            onPressed: () => setState(() => url = null),
          ),
        ),
        Expanded(
          child: HubWebView(key: ValueKey(u), url: u, desktopUserAgent: true),
        ),
      ],
    );
  }
}

/// Connexion Spotify (identifiant d'appli à toi) et profil Deezer.
class _MusicSettings extends StatefulWidget {
  const _MusicSettings({required this.module});
  final MusicModule module;

  @override
  State<_MusicSettings> createState() => _MusicSettingsState();
}

class _MusicSettingsState extends State<_MusicSettings> {
  late final clientId = TextEditingController(text: widget.module.spotify.clientId ?? '');
  late final deezer = TextEditingController(text: widget.module.deezerId ?? '');
  bool busy = false;
  String? error;

  MusicModule get m => widget.module;

  Future<void> _connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await m.spotify.login(clientId.text);
      await m.player.refresh();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _saveDeezer() async {
    final id = DeezerApi.profileId(deezer.text);
    if (deezer.text.trim().isEmpty) {
      await m.store.setJson('deezer.user', null);
      return;
    }
    if (id == null) {
      setState(() => error = 'Colle le lien de ton profil Deezer (deezer.com/…/profile/123456)');
      return;
    }
    try {
      final name = await m.deezer.userName(id);
      await m.store.setJson('deezer.user', id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Profil Deezer : $name')));
      }
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Spotify et Deezer'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (WindowsMediaSession.supported)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.check_circle_rounded, color: Colors.green),
                    title: Text('« En écoute » marche déjà'),
                    subtitle: Text(
                      'Mon Hub lit ce que joue l\'appli Spotify, Deezer ou ton navigateur sur ce PC, '
                      'sans connexion. Connecte-toi seulement pour tes titres likés et tes playlists.',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text('Spotify', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                m.spotify.connected
                    ? 'Connecté ✔ (titres likés, playlists, écoutes récentes, j\'aime, commandes).'
                    : '1. Va sur developer.spotify.com/dashboard et crée une appli (gratuit) : '
                          'nom « Mon Hub », Redirect URI ${SpotifyApi.redirect}, coche « Web API ».\n'
                          '2. Dans « User Management », ajoute l\'e-mail de ton compte Spotify.\n'
                          '3. Copie le « Client ID » ici, puis « Se connecter ».',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: clientId,
                decoration: const InputDecoration(
                  labelText: 'Client ID de ton appli Spotify',
                  border: OutlineInputBorder(),
                ),
              ),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Créer l\'appli'),
                    onPressed: () => openLink(context, 'https://developer.spotify.com/dashboard'),
                  ),
                  const Spacer(),
                  if (m.spotify.connected)
                    TextButton(
                      onPressed: () async {
                        await m.spotify.logout();
                        setState(() {});
                      },
                      child: const Text('Déconnecter'),
                    ),
                  FilledButton(
                    onPressed: busy ? null : _connect,
                    child: Text(busy ? 'Connexion…' : 'Se connecter'),
                  ),
                ],
              ),
              const Divider(height: 28),
              Text('Deezer', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Colle le lien de ton profil Deezer (Deezer → ton profil → Partager). Tes favoris et '
                'playlists doivent être publics. Les extraits de 30 s s\'écoutent dans Mon Hub.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: deezer,
                decoration: InputDecoration(
                  labelText: 'Lien du profil Deezer',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check_rounded),
                    onPressed: _saveDeezer,
                  ),
                ),
                onSubmitted: (_) => _saveDeezer(),
              ),
              if (error != null)
                Padding(padding: const EdgeInsets.only(top: 10), child: ErrorBanner(error!)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            if (deezer.text.trim() != (m.deezerId ?? '')) await _saveDeezer();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
