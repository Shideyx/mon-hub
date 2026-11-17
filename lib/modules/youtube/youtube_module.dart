import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/desktop_widgets.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
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
/// l'accueil, et Clicky qui peut chercher et lancer une vidéo. L'historique
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
  Widget buildPage(BuildContext context) => YouTubePage(module: this, url: home);
}

/// La carte de l'accueil : une barre de recherche, et les vidéos à reprendre
/// en vignettes.
class _YouTubeSummary extends StatelessWidget {
  const _YouTubeSummary({required this.module});
  final YouTubeModule module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = module.color;
    return ListenableBuilder(
      listenable: module.store,
      builder: (context, _) {
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
                          onTap: () => module.open(context, h[i].url),
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

  @override
  void dispose() {
    _watch?.cancel();
    if (identical(widget.module._page, _c)) widget.module._page = null;
    super.dispose();
  }

  void _attach(InAppWebViewController c) {
    _c = c;
    widget.module._page = c;
    // Retient les vidéos regardées (sur l'appareil seulement).
    _watch = Timer.periodic(const Duration(seconds: 4), (_) async {
      try {
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
                tooltip: 'Retour',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                onPressed: () async {
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
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
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
      ],
    );
  }
}
