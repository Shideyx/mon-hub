import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../core/nav.dart';
import '../core/party.dart';
import '../modules/youtube/youtube_module.dart' show YouTubeMiniPlayer, YouTubeSearch, YtVideo;
import 'phone_link_page.dart' show QrView;
import 'web_login.dart' show HubWebView;

/// L'écran de la soirée sur le PC : le son en cours (YouTube), le QR code
/// pour les invités et la file d'attente, triée par les votes.
class PartyPage extends StatefulWidget {
  const PartyPage({super.key});

  static bool _open = false;

  static Future<void> open() async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null || _open) return;
    _open = true;
    try {
      await nav.push(MaterialPageRoute<void>(builder: (_) => const PartyPage()));
    } finally {
      _open = false;
    }
  }

  @override
  State<PartyPage> createState() => _PartyPageState();
}

class _PartyPageState extends State<PartyPage> {
  final party = Party.instance;
  InAppWebViewController? _c;
  Timer? _poll;
  String? _loaded;
  DateTime _loadedAt = DateTime.now();
  final _search = TextEditingController();
  List<YtVideo> _results = const [];
  bool _searching = false;

  /// L'état du lecteur YouTube : -2 pas prêt, -3 publicité, 0 fini, 1 lecture…
  static const _stateScript =
      "(function(){var p=document.getElementById('movie_player');if(!p||!p.getPlayerState)return -2;"
      "if(p.classList.contains('ad-showing'))return -3;return p.getPlayerState();})()";

  @override
  void initState() {
    super.initState();
    unawaited(party.start());
    party.addListener(_changed);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    party.removeListener(_changed);
    _search.dispose();
    unawaited(party.stop());
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _play(String id) async {
    _loaded = id;
    _loadedAt = DateTime.now();
    await _c?.loadUrl(urlRequest: URLRequest(url: WebUri(YouTubeMiniPlayer.watchUrl(id, 0))));
  }

  /// Toutes les secondes : le son est-il fini ? (alors le suivant).
  Future<void> _tick() async {
    final c = _c;
    if (c == null) return;
    final now = party.playing;
    if (now == null) {
      if (party.queue.isNotEmpty) {
        final n = party.next();
        if (n != null) await _play(n.id);
      }
      return;
    }
    if (_loaded != now.id) return _play(now.id);
    try {
      await c.evaluateJavascript(source: YouTubeMiniPlayer.script);
      final st = await c.evaluateJavascript(source: _stateScript);
      final state = st is num ? st.toInt() : int.tryParse('$st') ?? -2;
      final stuck = state == -1 && DateTime.now().difference(_loadedAt) > const Duration(seconds: 20);
      if (state == 0 || stuck) await _skip();
    } catch (_) {}
  }

  Future<void> _skip() async {
    final n = party.next();
    if (n != null) {
      await _play(n.id);
    } else {
      _loaded = null;
      await _c?.evaluateJavascript(source: "document.querySelector('video')?.pause()");
    }
  }

  Future<void> _togglePause() async {
    await _c?.evaluateJavascript(
      source: "(function(){var v=document.querySelector('video');if(!v)return;v.paused?v.play():v.pause();})()",
    );
  }

  Future<void> _find() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final r = await YouTubeSearch.search(q);
      if (mounted) setState(() => _results = r.take(6).toList());
    } catch (_) {
      if (mounted) setState(() => _results = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<bool> _confirmEnd() async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Terminer la soirée ?'),
          content: const Text('La musique s\'arrête et le lien des invités ne marche plus.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuer')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Terminer')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = party.link;
    final playing = party.playing;
    final panel = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (link != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: SizedBox.square(dimension: 132, child: QrView('$link')),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ajoute tes sons !', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text('Scanne avec l\'appareil photo (même Wi-Fi). Cherche, ajoute, vote 👍.'),
                        const SizedBox(height: 6),
                        SelectableText('$link', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('Pas de Wi-Fi trouvé : branche le PC au Wi-Fi pour que tes amis puissent ajouter des sons.'),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(hintText: 'Ajouter un son…', prefixIcon: Icon(Icons.search_rounded)),
                onSubmitted: (_) => _find(),
              ),
            ),
            if (_searching) const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        for (final v in _results)
          ListTile(
            dense: true,
            title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([v.channel, v.length].where((s) => s.isNotEmpty).join(' · ')),
            trailing: IconButton(
              tooltip: 'Ajouter',
              icon: const Icon(Icons.add_circle_rounded),
              onPressed: () {
                party.add(
                  PartySong(id: v.id, title: v.title, channel: v.channel, length: v.length, by: 'Moi', guest: 'hote'),
                  'hote',
                );
                setState(() => _results = const []);
                _search.clear();
              },
            ),
          ),
        const SizedBox(height: 8),
        Text('À suivre (${party.queue.length})', style: theme.textTheme.titleSmall),
        if (party.queue.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('La file est vide : ajoute un son ou laisse tes amis le faire.'),
          ),
        for (final s in party.upcoming)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, child: Text('${s.votes.length}')),
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([if (s.by.isNotEmpty) 'par ${s.by}', s.length].where((x) => x.isNotEmpty).join(' · ')),
            trailing: IconButton(
              tooltip: 'Retirer',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => party.remove(s.id),
            ),
          ),
      ],
    );
    final player = Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ColoredBox(
              color: Colors.black,
              child: HubWebView(
                url: 'https://www.youtube.com/',
                desktopUserAgent: true,
                reloadButton: false,
                onController: (c) => _c = c,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                playing == null
                    ? 'Rien en cours : ajoute un son 🎶'
                    : '🎶 ${playing.title}${playing.by.isEmpty ? '' : ' — par ${playing.by}'}',
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Pause / lecture',
              onPressed: _togglePause,
              icon: const Icon(Icons.pause_rounded),
            ),
            const SizedBox(width: 6),
            IconButton.filled(tooltip: 'Son suivant', onPressed: _skip, icon: const Icon(Icons.skip_next_rounded)),
          ],
        ),
      ],
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmEnd() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('🎉 Playlist de soirée')),
        body: LayoutBuilder(
          builder: (context, c) => c.maxWidth > 900
              ? Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 0, 16), child: player),
                    ),
                    SizedBox(width: 420, child: panel),
                  ],
                )
              : Column(
                  children: [
                    SizedBox(
                      height: 320,
                      child: Padding(padding: const EdgeInsets.all(12), child: player),
                    ),
                    Expanded(child: panel),
                  ],
                ),
        ),
      ),
    );
  }
}
