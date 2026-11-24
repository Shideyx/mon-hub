import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/desktop_widgets.dart';
import '../../core/hub_home.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/motion.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

/// Une vidéo YouTube.
class YtVideo {
  const YtVideo(this.id, this.title, {this.channel = '', this.length = '', this.views = ''});
  final String id;
  final String title;
  final String channel;
  final String length;
  final String views;

  String get thumb => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
  String get url => 'https://www.youtube.com/watch?v=$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'titre': title,
    if (channel.isNotEmpty) 'chaine': channel,
    if (length.isNotEmpty) 'duree': length,
    if (views.isNotEmpty) 'vues': views,
  };
}

/// Recherche YouTube sans compte ni clé : la page de résultats publique de
/// youtube.com, lue comme le fait le site (rien n'est envoyé à part la
/// recherche).
class YouTubeSearch {
  YouTubeSearch._();

  static Uri resultsUri(String q) =>
      Uri.parse('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}&hl=fr&gl=FR');

  static Future<List<YtVideo>> search(String q, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(
            resultsUri(q),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/131.0.0.0 Safari/537.36',
              'Accept-Language': 'fr-FR,fr;q=0.9',
              // Sans ce cookie, YouTube (en Europe) montre d'abord la page
              // des cookies au lieu des résultats.
              'Cookie': 'SOCS=CAI',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'YouTube : erreur ${r.statusCode}';
      return parse(utf8.decode(r.bodyBytes, allowMalformed: true));
    } finally {
      if (client == null) c.close();
    }
  }

  /// Lit les vidéos de la page de résultats (les données `ytInitialData`).
  static List<YtVideo> parse(String html) {
    final start = RegExp(r'(?:var ytInitialData|window\["ytInitialData"\])\s*=\s*').firstMatch(html);
    final out = <YtVideo>[];
    final seen = <String>{};
    if (start != null) {
      final end = html.indexOf(';</script>', start.end);
      if (end > start.end) {
        try {
          _walk(jsonDecode(html.substring(start.end, end)), out, seen);
        } catch (_) {}
      }
    }
    return out;
  }

  static String _text(Object? t) {
    if (t is! Map) return '';
    if (t['simpleText'] is String) return t['simpleText'] as String;
    final runs = t['runs'];
    if (runs is List) return [for (final r in runs) if (r is Map) '${r['text'] ?? ''}'].join();
    return '';
  }

  static void _walk(Object? node, List<YtVideo> out, Set<String> seen) {
    if (out.length >= 20) return;
    if (node is Map) {
      final v = node['videoRenderer'];
      if (v is Map && v['videoId'] is String && seen.add(v['videoId'] as String)) {
        out.add(
          YtVideo(
            v['videoId'] as String,
            _text(v['title']),
            channel: _text(v['ownerText'] ?? v['longBylineText']),
            length: _text(v['lengthText']),
            views: _text(v['shortViewCountText'] ?? v['viewCountText']),
          ),
        );
        return;
      }
      for (final x in node.values) {
        _walk(x, out, seen);
      }
    } else if (node is List) {
      for (final x in node) {
        _walk(x, out, seen);
      }
    }
  }

  /// L'identifiant d'une vidéo dans une adresse YouTube.
  static String? videoId(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.host.endsWith('youtu.be')) return u.pathSegments.firstOrNull;
    if (u.path == '/watch') return u.queryParameters['v'];
    final s = u.pathSegments;
    if (s.length >= 2 && (s[0] == 'shorts' || s[0] == 'live' || s[0] == 'embed')) return s[1];
    return null;
  }
}

/// YouTube : **tout le vrai YouTube** dans Mon Hub (ton compte, tes
/// abonnements, tes playlists…), une recherche rapide et « Reprendre » sur
/// l'accueil, et Smily qui peut chercher et lancer une vidéo. L'historique
/// reste sur l'appareil.
class YouTubeModule extends HubModule {
  @override
  String get id => 'youtube';
  @override
  String get name => 'YouTube';
  @override
  String get description => 'Tout YouTube dans Mon Hub';
  @override
  IconData get icon => Icons.smart_display_rounded;
  @override
  Color get color => const Color(0xFFFF0033);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  static const home = 'https://www.youtube.com/';

  /// La page YouTube ouverte en ce moment (pour la piloter).
  InAppWebViewController? _page;

  /// Vidéos regardées dans Mon Hub (les plus récentes d'abord).
  List<YtVideo> get history => [
    for (final e in store.getJson<List<dynamic>>('history') ?? const [])
      if (e is Map && e['id'] is String)
        YtVideo(e['id'] as String, '${e['title'] ?? ''}', channel: '${e['channel'] ?? ''}'),
  ];

  Future<void> remember(String id, String title) async {
    final clean = title.replaceAll(RegExp(r'\s*-\s*YouTube\s*$'), '').replaceAll(RegExp(r'^\(\d+\)\s*'), '').trim();
    if (clean.isEmpty || clean == 'YouTube') return;
    final list = [
      {'id': id, 'title': clean},
      for (final v in history)
        if (v.id != id) {'id': v.id, 'title': v.title, 'channel': v.channel},
    ].take(30).toList();
    await store.setJson('history', list);
  }

  Future<void> clearHistory() => store.setJson('history', null);

  /// Ouvre YouTube dans Mon Hub (sur une vidéo, une recherche…).
  Future<void> open([BuildContext? context, String url = home]) async {
    final page = _page;
    if (page != null) {
      try {
        await page.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        return;
      } catch (_) {
        _page = null;
      }
    }
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    unawaited(
      Navigator.push(
        ctx,
        MaterialPageRoute<void>(builder: (_) => YouTubePage(module: this, url: url)),
      ),
    );
  }

  Future<void> openSearch(BuildContext? context, String q) =>
      open(context, YouTubeSearch.resultsUri(q).toString());

  Future<Object?> _js(String source) async {
    final p = _page;
    if (p == null) throw 'YouTube n\'est pas ouvert dans Mon Hub';
    return p.evaluateJavascript(source: source);
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'youtube_chercher',
      description: 'Cherche des vidéos sur YouTube (titre, chaîne, durée, id).',
      params: {'recherche': ('string', 'Ce qu\'il faut chercher')},
      required: ['recherche'],
      run: (a) async {
        final q = '${a['recherche']}';
        try {
          final list = await YouTubeSearch.search(q);
          if (list.isNotEmpty) return [for (final v in list.take(8)) v.toJson()];
        } catch (_) {}
        // Lecture impossible : on montre les résultats dans Mon Hub.
        await openSearch(null, q);
        return {'ok': true, 'info': 'Résultats affichés dans YouTube, dans Mon Hub.'};
      },
    ),
    HubTool(
      name: 'youtube_lire',
      description: 'Lance une vidéo YouTube dans Mon Hub (par son id, ou la première trouvée pour une recherche).',
      params: {
        'id': ('string', 'id de la vidéo (youtube_chercher)'),
        'recherche': ('string', 'Sinon : ce qu\'il faut chercher'),
      },
      run: (a) async {
        final id = '${a['id'] ?? ''}'.trim();
        if (id.isEmpty) {
          final q = '${a['recherche'] ?? ''}'.trim();
          if (q.isEmpty) throw 'Donne un id ou une recherche';
          final list = await YouTubeSearch.search(q);
          if (list.isEmpty) {
            await openSearch(null, q);
            return {'ok': true, 'info': 'Résultats affichés : choisis la vidéo.'};
          }
          await open(null, list.first.url);
          return {'ok': true, 'video': list.first.toJson()};
        }
        await open(null, 'https://www.youtube.com/watch?v=$id');
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'youtube_controle',
      description: 'Contrôle la vidéo YouTube ouverte dans Mon Hub.',
      params: {'action': ('string', 'pause, lecture, suivante, plein_ecran, muet ou son')},
      required: ['action'],
      run: (a) async {
        final js = switch ('${a['action']}') {
          'pause' => "document.querySelector('video') && document.querySelector('video').pause()",
          'lecture' => "document.querySelector('video') && document.querySelector('video').play()",
          'suivante' => "document.querySelector('.ytp-next-button') && document.querySelector('.ytp-next-button').click()",
          'plein_ecran' =>
            "document.querySelector('.ytp-fullscreen-button') && document.querySelector('.ytp-fullscreen-button').click()",
          'muet' => "document.querySelector('video') && (document.querySelector('video').muted = true)",
          'son' => "document.querySelector('video') && (document.querySelector('video').muted = false)",
          _ => throw 'Action inconnue',
        };
        await _js(js);
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'youtube_historique',
      description: 'Les dernières vidéos regardées dans Mon Hub.',
      run: (_) async => [for (final v in history.take(15)) v.toJson()],
    ),
  ];

  /// Sur le bureau, le widget est un vrai YouTube : il ne se recharge pas.
  @override
  bool get liveWidget => true;

  @override
  Widget buildSummary(BuildContext context) =>
      DesktopWidgets.inWidgetWindow ? YouTubeMini(module: this) : _YouTubeSummary(module: this);

  @override
  Widget buildPage(BuildContext context) {
    // Une vidéo en petit écran : la page s'ouvre dessus, à la même seconde.
    final p = YouTubeMiniPlayer.instance;
    final id = p.id;
    return YouTubePage(module: this, url: id == null ? home : YouTubeMiniPlayer.watchUrl(id, p.start));
  }
}

/// La carte de l'accueil : une barre de recherche, et les vidéos à reprendre
/// en vignettes.
class _YouTubeSummary extends StatefulWidget {
  const _YouTubeSummary({required this.module});
  final YouTubeModule module;

  @override
  State<_YouTubeSummary> createState() => _YouTubeSummaryState();
}

class _YouTubeSummaryState extends State<_YouTubeSummary> {
  YouTubeModule get module => widget.module;
  final player = YouTubeMiniPlayer.instance;

  @override
  void initState() {
    super.initState();
    player.cardAttached();
  }

  @override
  void dispose() {
    player.cardDetached();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = module.color;
    return ListenableBuilder(
      listenable: Listenable.merge([module.store, player, HubHome.instance]),
      builder: (context, _) {
        // La vidéo en cours se joue ici, dans la carte.
        if (player.inCard) return _CardVideo(player: player, color: c);
        final h = module.history;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Rechercher sur YouTube',
                  prefixIcon: Icon(Icons.search_rounded, color: c),
                  filled: true,
                  fillColor: c.withValues(alpha: 0.07),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                ),
                onSubmitted: (q) {
                  if (q.trim().isNotEmpty) module.openSearch(context, q.trim());
                },
              ),
              const SizedBox(height: 10),
              if (h.isEmpty)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => module.open(context),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          colors: [c.withValues(alpha: 0.85), const Color(0xFF7C1F3C)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: const Row(
                        children: [
                          Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 42),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Tout YouTube dans Mon Hub : tes abonnements, tes playlists, les tendances…',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...[
                Text(
                  'REPRENDRE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final w = (box.maxHeight - 20) * 16 / 9;
                      return ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: h.length.clamp(0, 12),
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, i) => _Thumb(
                          video: h[i],
                          width: w.clamp(120, 260).toDouble(),
                          // La vidéo se joue directement dans la carte.
                          onTap: () => player.show(module, h[i].id, 0, title: h[i].title),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.video, required this.width, required this.onTap});
  final YtVideo video;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              video.thumb,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(color: const Color(0xFF282828)),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Color(0xCC000000)],
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 34)),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.2),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Le vrai YouTube, dans Mon Hub.
class YouTubePage extends StatefulWidget {
  const YouTubePage({super.key, required this.module, required this.url});
  final YouTubeModule module;
  final String url;

  @override
  State<YouTubePage> createState() => _YouTubePageState();
}

class _YouTubePageState extends State<YouTubePage> {
  InAppWebViewController? _c;
  Timer? _watch;
  String? _lastId;

  /// La vidéo en cours (pour passer en petit écran quand on quitte la page).
  VideoState? _now;
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    // Une seule vidéo à la fois : le petit écran se ferme.
    YouTubeMiniPlayer.instance.close();
  }

  @override
  void dispose() {
    _watch?.cancel();
    if (identical(widget.module._page, _c)) widget.module._page = null;
    // On quitte YouTube pendant une vidéo : elle continue en petit écran.
    final n = _now;
    if (!_handedOff && n != null && n.playing && !DesktopWidgets.inWidgetWindow) {
      final age = DateTime.now().difference(n.at);
      if (age < const Duration(seconds: 10)) {
        YouTubeMiniPlayer.instance.show(widget.module, n.id, n.time + age.inMilliseconds / 1000, title: n.title);
      }
    }
    super.dispose();
  }

  /// Passe la vidéo en petit écran et revient au menu.
  Future<void> _mini() async {
    final c = _c;
    final s = c == null ? null : await VideoState.read(c);
    if (s == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lance d\'abord une vidéo')));
      }
      return;
    }
    try {
      await c!.evaluateJavascript(source: "(function(){var v=document.querySelector('video');if(v)v.pause();})()");
    } catch (_) {}
    _handedOff = true;
    YouTubeMiniPlayer.instance.show(widget.module, s.id, s.time, title: s.title);
    HubHome.instance.go();
  }

  void _attach(InAppWebViewController c) {
    _c = c;
    widget.module._page = c;
    // Retient les vidéos regardées (sur l'appareil seulement).
    _watch = Timer.periodic(const Duration(seconds: 4), (_) async {
      try {
        _now = await VideoState.read(c);
        final url = '${await c.getUrl() ?? ''}';
        final id = YouTubeSearch.videoId(url);
        if (id == null || id == _lastId) return;
        // Le titre de la page met un instant à changer.
        await Future<void>.delayed(const Duration(seconds: 2));
        final title = await c.getTitle() ?? '';
        if (await c.getUrl().then((u) => YouTubeSearch.videoId('$u')) != id) return;
        _lastId = id;
        await widget.module.remember(id, title);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(m.icon, color: m.color),
            const SizedBox(width: 10),
            const Text('YouTube'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Petit écran (la vidéo continue pendant que tu fais autre chose)',
            icon: const Icon(Icons.picture_in_picture_alt_rounded),
            onPressed: _mini,
          ),
          IconButton(
            tooltip: 'Accueil YouTube',
            icon: const Icon(Icons.home_rounded),
            onPressed: () => _c?.loadUrl(urlRequest: URLRequest(url: WebUri(YouTubeModule.home))),
          ),
          IconButton(
            tooltip: 'Ouvrir dans le navigateur',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () async {
              final u = await _c?.getUrl();
              await Browser.open('${u ?? YouTubeModule.home}');
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') {
                await m.clearHistory();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Historique de Mon Hub effacé')),
                  );
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Effacer « Reprendre » (historique de Mon Hub)')),
            ],
          ),
        ],
      ),
      body: webLoginSupported
          ? HubWebView(url: widget.url, desktopUserAgent: true, onController: _attach)
          : EmptyHint(
              'YouTube s\'ouvre dans ton navigateur sur cet appareil.',
              icon: m.icon,
              action: ('Ouvrir YouTube', () => Browser.open(widget.url)),
            ),
    );
  }
}

/// Le vrai YouTube dans le widget du bureau (version mobile, faite pour les
/// petites fenêtres) : tu regardes ta vidéo et tu navigues sans rien ouvrir
/// d'autre.
class YouTubeMini extends StatefulWidget {
  const YouTubeMini({super.key, required this.module, this.url = 'https://m.youtube.com/'});
  final YouTubeModule module;
  final String url;

  static const mobileUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Mobile Safari/537.36';

  @override
  State<YouTubeMini> createState() => _YouTubeMiniState();
}

class _YouTubeMiniState extends State<YouTubeMini> {
  InAppWebViewController? _c;
  final _search = TextEditingController();
  Timer? _watch;
  String? _lastId;
  double _progress = 0;

  /// La vidéo ouverte : elle s'affiche en grand dans tout le widget.
  String? _video;
  int _videoStart = 0;

  void _opened(InAppWebViewController c, String url) {
    final id = YouTubeSearch.videoId(url);
    if (id == null || id == _video) return;
    // La page mobile se met en pause : la vidéo joue en grand à la place.
    unawaited(c.evaluateJavascript(source: "(function(){var v=document.querySelector('video');if(v)v.pause();})()")
        .catchError((Object _) => null));
    setState(() {
      _video = id;
      _videoStart = 0;
    });
  }

  void _backToBrowse() {
    setState(() => _video = null);
    unawaited(_c?.goBack());
  }

  @override
  void dispose() {
    _watch?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _go(String url) => _c?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  void _attach(InAppWebViewController c) {
    _c = c;
    // Retient les vidéos regardées (sur l'appareil seulement).
    _watch = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final id = YouTubeSearch.videoId('${await c.getUrl() ?? ''}');
        if (id == null || id == _lastId) return;
        await Future<void>.delayed(const Duration(seconds: 2));
        final title = await c.getTitle() ?? '';
        _lastId = id;
        await widget.module.remember(id, title);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.module.color;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              IconButton(
                tooltip: _video == null ? 'Retour' : 'Revenir à YouTube',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                onPressed: () async {
                  if (_video != null) return _backToBrowse();
                  if (await _c?.canGoBack() ?? false) await _c?.goBack();
                },
              ),
              IconButton(
                tooltip: 'Accueil YouTube',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.home_rounded, size: 18, color: c),
                onPressed: () => _go(widget.url),
              ),
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Rechercher',
                    prefixIcon: const Icon(Icons.search_rounded, size: 16),
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                    filled: true,
                  ),
                  onSubmitted: (q) {
                    if (q.trim().isEmpty) return;
                    _go('https://m.youtube.com/results?search_query=${Uri.encodeQueryComponent(q.trim())}');
                  },
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
        if (_progress < 1) LinearProgressIndicator(value: _progress, minHeight: 2, color: c),
        Expanded(
          child: Stack(
            children: [
              // La navigation reste ouverte derrière la vidéo (pas rechargée).
              Positioned.fill(
                child: Offstage(
                  offstage: _video != null,
                  child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            onUpdateVisitedHistory: (c, url, _) => _opened(c, '${url ?? ''}'),
            initialSettings: InAppWebViewSettings(
              userAgent: YouTubeMini.mobileUa,
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              thirdPartyCookiesEnabled: true,
            ),
            onWebViewCreated: _attach,
            onProgressChanged: (_, p) {
              if (mounted) setState(() => _progress = p / 100);
            },
            onPermissionRequest: (_, req) async =>
                PermissionResponse(resources: req.resources, action: PermissionResponseAction.GRANT),
                  ),
                ),
              ),
              if (_video != null)
                Positioned.fill(
                  child: MiniVideoView(
                    key: ValueKey('widget-$_video'),
                    id: _video!,
                    start: _videoStart,
                    onTime: (t) => _videoStart = t.floor(),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}


/// Où en est la vidéo d'une page YouTube.
class VideoState {
  const VideoState(this.id, this.time, {required this.playing, required this.at, this.title = ''});
  final String id;
  final double time;
  final bool playing;
  final DateTime at;
  final String title;

  static const script =
      "(function(){var v=document.querySelector('video');"
      "return v?JSON.stringify({t:v.currentTime,p:!v.paused&&!v.ended}):'';})()";

  /// Lit la vidéo de la page (null si ce n'est pas une page de vidéo).
  static Future<VideoState?> read(InAppWebViewController c) async {
    try {
      final id = YouTubeSearch.videoId('${await c.getUrl() ?? ''}');
      if (id == null) return null;
      final r = await c.evaluateJavascript(source: script);
      final j = r is String && r.isNotEmpty ? jsonDecode(r) : r;
      if (j is! Map) return null;
      final title = (await c.getTitle() ?? '').replaceAll(RegExp(r'\s*-\s*YouTube\s*$'), '').replaceAll(RegExp(r'^\(\d+\)\s*'), '');
      return VideoState(id, (j['t'] as num?)?.toDouble() ?? 0, playing: j['p'] == true, at: DateTime.now(), title: title);
    } catch (_) {
      return null;
    }
  }
}

/// Le petit écran YouTube : la vidéo continue dans une petite fenêtre
/// au-dessus de tout Mon Hub pendant que tu fais autre chose.
class YouTubeMiniPlayer extends ChangeNotifier {
  YouTubeMiniPlayer._();
  static final instance = YouTubeMiniPlayer._();

  YouTubeModule? _module;
  String? id;
  int start = 0;
  String title = '';
  InAppWebViewController? _c;

  bool get active => id != null;

  /// Cartes YouTube affichées sur l'accueil.
  int _cards = 0;
  // (Prévenu juste après : jamais pendant que l'écran se construit.)
  void cardAttached() {
    _cards++;
    scheduleMicrotask(notifyListeners);
  }

  void cardDetached() {
    _cards = (_cards - 1).clamp(0, 99);
    scheduleMicrotask(notifyListeners);
  }

  /// La vidéo se joue dans la carte de l'accueil (elle est à l'écran) ;
  /// sinon dans la petite fenêtre flottante.
  bool get inCard => active && _cards > 0 && !HubHome.instance.away;

  /// Où en est la vidéo (pour la reprendre ailleurs à la même seconde).
  void tick(double t) => start = t.floor();

  /// L'adresse de la vidéo, à la bonne seconde.
  static String watchUrl(String id, int start) =>
      'https://www.youtube.com/watch?v=$id${start > 0 ? '&t=${start}s' : ''}';

  /// Ne garde que la vidéo, en grand dans la petite fenêtre.
  static const css =
      'html,body{overflow:hidden!important;background:#000!important}'
      '#masthead-container,#secondary,#below,#guide,tp-yt-app-drawer,ytd-mini-guide-renderer,#chat{display:none!important}'
      '#movie_player{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;'
      'z-index:2147483647!important;background:#000!important}'
      '#movie_player video{width:100vw!important;height:100vh!important;left:0!important;top:0!important;object-fit:contain!important}'
      '.ytp-chrome-bottom{width:calc(100vw - 24px)!important;left:12px!important}';

  static const script =
      "(function(){if(!document.getElementById('mh-mini')){var s=document.createElement('style');s.id='mh-mini';"
      "s.textContent='$css';(document.head||document.documentElement).appendChild(s);}"
      "setTimeout(function(){window.dispatchEvent(new Event('resize'));},800);"
      "var v=document.querySelector('video');if(v&&v.paused)v.play().catch(function(){});})()";

  void show(YouTubeModule module, String id, double time, {String? title}) {
    _module = module;
    this.id = id;
    start = time.floor();
    this.title = title ?? '';
    notifyListeners();
  }

  void close() {
    if (id == null) return;
    final m = _module;
    if (m != null && identical(m._page, _c)) m._page = null;
    id = null;
    _c = null;
    notifyListeners();
  }

  void _attach(InAppWebViewController c) {
    _c = c;
    // Smily peut mettre en pause, passer… la vidéo du petit écran.
    final m = _module;
    if (m != null && m._page == null) m._page = c;
  }

  /// Rouvre la vidéo en grand, à la même seconde.
  Future<void> expand() async {
    final m = _module;
    final v = id;
    if (m == null || v == null) return close();
    var t = start;
    final c = _c;
    if (c != null) t = ((await VideoState.read(c))?.time ?? start).floor();
    close();
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => YouTubePage(module: m, url: watchUrl(v, t)))));
  }
}

/// La petite fenêtre (en bas à droite, déplaçable).
class YouTubeMiniLayer extends StatefulWidget {
  const YouTubeMiniLayer({super.key, required this.child});
  final Widget child;

  @override
  State<YouTubeMiniLayer> createState() => _YouTubeMiniLayerState();
}

class _YouTubeMiniLayerState extends State<YouTubeMiniLayer> {
  /// Distance au coin en bas à droite.
  Offset _pos = const Offset(24, 96);
  bool _big = false;

  @override
  Widget build(BuildContext context) {
    final p = YouTubeMiniPlayer.instance;
    return Stack(
      children: [
        Positioned.fill(key: const ValueKey('mini-hub'), child: widget.child),
        Positioned(
          key: const ValueKey('mini-player'),
          right: 0,
          bottom: 0,
          left: 0,
          top: 0,
          child: ListenableBuilder(
              listenable: Listenable.merge([p, HubHome.instance]),
              builder: (context, _) {
                if (!p.active || p.inCard) return const SizedBox.shrink();
                final size = MediaQuery.sizeOf(context);
                final w = (_big ? 560.0 : 380.0).clamp(200.0, (size.width - 32).clamp(200.0, double.infinity));
                final h = w * 9 / 16;
                // Jamais en dehors de la fenêtre (même toute petite).
                final maxRight = (size.width - w).clamp(0.0, double.infinity);
                final maxBottom = (size.height - h - 40).clamp(0.0, double.infinity);
                return Stack(
                  children: [
                    if (!p.inCard)
                    Positioned(
                      right: _pos.dx.clamp(0.0, maxRight),
                      bottom: _pos.dy.clamp(0.0, maxBottom),
                      child: _MiniWindow(
                        key: ValueKey('yt-mini-${p.id}'),
                        player: p,
                        width: w,
                        height: h,
                        big: _big,
                        onDrag: (d) => setState(() => _pos = Offset(_pos.dx - d.dx, _pos.dy - d.dy)),
                        onSize: () => setState(() => _big = !_big),
                      ),
                    ),
                  ],
                );
              },
            ),
        ),
      ],
    );
  }
}

class _MiniWindow extends StatefulWidget {
  const _MiniWindow({
    super.key,
    required this.player,
    required this.width,
    required this.height,
    required this.big,
    required this.onDrag,
    required this.onSize,
  });
  final YouTubeMiniPlayer player;
  final double width;
  final double height;
  final bool big;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onSize;

  @override
  State<_MiniWindow> createState() => _MiniWindowState();
}

class _MiniWindowState extends State<_MiniWindow> {
  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (context, s, child) => Transform.scale(scale: s, alignment: Alignment.bottomRight, child: child),
      child: Material(
        elevation: 16,
        shadowColor: Colors.black54,
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: widget.width,
          height: widget.height + 36,
          child: Column(
            children: [
              GestureDetector(
                onPanUpdate: (d) => widget.onDrag(d.delta),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Container(
                    height: 36,
                    color: const Color(0xFF1B1B1F),
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.smart_display_rounded, color: Color(0xFFFF0033), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            p.title.isEmpty ? 'YouTube' : p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                        _MiniButton(
                          icon: widget.big ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
                          tip: widget.big ? 'Plus petit' : 'Plus grand',
                          onTap: widget.onSize,
                        ),
                        _MiniButton(icon: Icons.fullscreen_rounded, tip: 'Revenir en grand', onTap: p.expand),
                        _MiniButton(icon: Icons.close_rounded, tip: 'Fermer', onTap: p.close),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: MiniVideoView(id: p.id!, start: p.start, onTime: p.tick, onController: p._attach)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  // (Pas d'infobulle : la petite fenêtre est au-dessus des pages.)
  Widget build(BuildContext context) => IconButton(
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    color: Colors.white,
    icon: Icon(icon),
    onPressed: onTap,
  );
}


/// La vidéo seule, en grand dans un petit cadre (carte de l'accueil, petite
/// fenêtre, widget du bureau).
class MiniVideoView extends StatefulWidget {
  const MiniVideoView({super.key, required this.id, this.start = 0, this.onTime, this.onController});
  final String id;
  final int start;

  /// Où en est la vidéo (toutes les 3 s).
  final void Function(double seconds)? onTime;
  final void Function(InAppWebViewController c)? onController;

  @override
  State<MiniVideoView> createState() => _MiniVideoViewState();
}

class _MiniVideoViewState extends State<MiniVideoView> {
  Timer? _time;

  @override
  void dispose() {
    _time?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NoPressZone(
    // Un clic dans la vidéo ne déclenche pas la carte en dessous.
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: ColoredBox(
        color: Colors.black,
        child: InAppWebView(
          key: ValueKey('mini-video-${widget.id}'),
          initialUrlRequest: URLRequest(url: WebUri(YouTubeMiniPlayer.watchUrl(widget.id, widget.start))),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            thirdPartyCookiesEnabled: true,
            transparentBackground: true,
          ),
          onWebViewCreated: (c) {
            widget.onController?.call(c);
            _time?.cancel();
            _time = Timer.periodic(const Duration(seconds: 3), (_) async {
              final s = await VideoState.read(c);
              if (s != null) widget.onTime?.call(s.time);
            });
          },
          onLoadStop: (c, _) async {
            try {
              await c.evaluateJavascript(source: YouTubeMiniPlayer.script);
              // YouTube construit sa page un peu après : on repasse.
              await Future<void>.delayed(const Duration(seconds: 2));
              await c.evaluateJavascript(source: YouTubeMiniPlayer.script);
            } catch (_) {}
          },
        ),
      ),
    ),
  );
}

/// La vidéo en cours, dans la carte YouTube de l'accueil.
class _CardVideo extends StatelessWidget {
  const _CardVideo({required this.player, required this.color});
  final YouTubeMiniPlayer player;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: MiniVideoView(
                key: ValueKey('card-${player.id}'),
                id: player.id!,
                start: player.start,
                onTime: player.tick,
                onController: player._attach,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              EqualizerBars(color: color, size: 12),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  player.title.isEmpty ? 'Vidéo en cours' : player.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              NoPressZone(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: 'Grand écran',
                  icon: const Icon(Icons.fullscreen_rounded),
                  onPressed: player.expand,
                ),
              ),
              NoPressZone(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: 'Arrêter',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: player.close,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
