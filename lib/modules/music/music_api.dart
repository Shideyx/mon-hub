import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/module_store.dart';
import 'music_models.dart';

// ---------------------------------------------------------------------------
// Spotify (API officielle, connexion PKCE avec TON identifiant d'appli)
// ---------------------------------------------------------------------------

/// Spotify : ta musique (titres likés, playlists, écoutes récentes, ce qui
/// joue) avec l'API officielle.
///
/// Spotify n'autorise que les applis déclarées : tu crées la tienne en deux
/// minutes sur developer.spotify.com (gratuit), tu colles son « Client ID »
/// dans Mon Hub, puis tu te connectes sur la page de Spotify. Mon Hub ne
/// voit jamais ton mot de passe ; seul un jeton est gardé, chiffré.
class SpotifyApi {
  SpotifyApi(this.store, [http.Client? client]) : _http = client ?? http.Client();
  final ModuleStore store;
  final http.Client _http;

  static const port = 47614;
  static const redirect = 'http://127.0.0.1:$port/callback';
  static const scopes = [
    'user-read-currently-playing',
    'user-read-playback-state',
    'user-modify-playback-state',
    'user-library-read',
    'user-library-modify',
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-read-recently-played',
  ];

  String? get clientId => store.getJson<String>('spotify.clientId');
  bool get connected => store.getJson<bool>('spotify.connected') == true;

  String? _access;
  DateTime? _expires;

  static String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// Connexion : ouvre la page de Spotify, attend le retour sur 127.0.0.1.
  Future<void> login(String clientId) async {
    final id = clientId.trim();
    if (id.length < 16) throw 'Colle le « Client ID » de ton appli Spotify';
    await store.setJson('spotify.clientId', id);
    final rnd = Random.secure();
    final verifier = _b64url(List.generate(64, (_) => rnd.nextInt(256)));
    final challenge = _b64url(sha256.convert(utf8.encode(verifier)).bytes);
    final state = _b64url(List.generate(16, (_) => rnd.nextInt(256)));
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (_) {
      throw 'Le port $port est déjà pris : ferme l\'autre fenêtre de connexion et réessaie';
    }
    final code = Completer<String>();
    server.listen((req) async {
      final q = req.uri.queryParameters;
      final ok = q['state'] == state && q['code'] != null;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body style="font-family:sans-serif;text-align:center;padding:60px;background:#121212;color:#fff">'
          '<h2>${ok ? 'Spotify est connecté à Mon Hub ✔' : 'Connexion refusée'}</h2>'
          '<p>Tu peux fermer cette page et revenir dans Mon Hub.</p></body></html>',
        );
      await req.response.close();
      if (!code.isCompleted) {
        ok ? code.complete(q['code']) : code.completeError(q['error'] ?? 'Connexion annulée');
      }
    });
    try {
      final url = Uri.https('accounts.spotify.com', '/authorize', {
        'client_id': id,
        'response_type': 'code',
        'redirect_uri': redirect,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
        'state': state,
        'scope': scopes.join(' '),
      });
      await launchUrl(url, mode: LaunchMode.externalApplication);
      final c = await code.future.timeout(const Duration(minutes: 5));
      final r = await _http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': c,
          'redirect_uri': redirect,
          'client_id': id,
          'code_verifier': verifier,
        },
      );
      await _saveTokens(r);
      await store.setJson('spotify.connected', true);
    } on TimeoutException {
      throw 'Connexion à Spotify trop longue, réessaie';
    } finally {
      await server.close(force: true);
    }
  }

  Future<void> _saveTokens(http.Response r) async {
    final j = jsonDecode(r.body);
    if (r.statusCode != 200 || j is! Map || j['access_token'] == null) {
      final err = j is Map ? (j['error_description'] ?? j['error']) : null;
      throw 'Spotify refuse la connexion${err == null ? '' : ' : $err'}. '
          'Vérifie le Client ID et l\'adresse de retour $redirect dans ton appli Spotify.';
    }
    _access = j['access_token'] as String;
    _expires = DateTime.now().add(
      Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 60),
    );
    final refresh = j['refresh_token'] as String?;
    if (refresh != null) await store.writeSecret('spotify.refresh', refresh);
  }

  Future<void> logout() async {
    _access = null;
    await store.writeSecret('spotify.refresh', null);
    await store.setJson('spotify.connected', null);
  }

  Future<String> _token() async {
    final a = _access;
    if (a != null && _expires != null && DateTime.now().isBefore(_expires!)) return a;
    final refresh = await store.readSecret('spotify.refresh');
    final id = clientId;
    if (refresh == null || id == null) throw 'Spotify n\'est pas connecté';
    final r = await _http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': refresh, 'client_id': id},
    );
    if (r.statusCode == 400) {
      await logout();
      throw 'Connexion Spotify expirée : reconnecte-toi';
    }
    await _saveTokens(r);
    return _access!;
  }

  Future<http.Response> _req(String method, String path, {Object? body}) async {
    final uri = Uri.parse(path.startsWith('http') ? path : 'https://api.spotify.com/v1$path');
    final h = {'authorization': 'Bearer ${await _token()}', 'content-type': 'application/json'};
    final req = http.Request(method, uri)..headers.addAll(h);
    if (body != null) req.body = jsonEncode(body);
    final r = await http.Response.fromStream(await _http.send(req))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) {
      _access = null;
      throw 'Spotify : session expirée, réessaie';
    }
    if (r.statusCode == 403) throw explain403(_msg(r));
    if (r.statusCode == 429) throw 'Spotify demande de patienter un peu (code 429)';
    if (r.statusCode == 404 && path.contains('/me/player')) {
      throw 'Spotify : no active device (404)';
    }
    if (r.statusCode == 404) {
      throw 'Spotify (code 404) : ${_msg(r)}. Cette fonction a peut-être été retirée par Spotify '
          'pour les applis en mode développement (février 2026).';
    }
    if (r.statusCode >= 400) throw 'Spotify (code ${r.statusCode}) : ${_msg(r)}';
    return r;
  }

  /// Refus 403 expliqué. Depuis février 2026, Spotify exige que le compte
  /// qui a créé l'appli (developer.spotify.com) ait Premium, et limite
  /// l'appli à 5 comptes déclarés dans « User Management ».
  static String explain403(String msg) {
    final low = msg.toLowerCase();
    if (low.contains('premium') && (low.contains('owner') || low.contains('subscription'))) {
      return 'Spotify refuse (code 403) : depuis février 2026, le compte Spotify qui a créé l\'appli sur '
          'developer.spotify.com doit avoir Premium. Sans Premium, Mon Hub cherche avec Deezer et ouvre '
          'les morceaux dans ton appli Spotify.';
    }
    if (low.contains('premium')) {
      return 'Cette commande demande Spotify Premium (code 403). Sans Premium, le morceau s\'ouvre dans l\'appli Spotify.';
    }
    if (low.contains('regist') || low.contains('dashboard') || low.contains('user may not')) {
      return 'Spotify refuse ton compte (code 403) : ajoute l\'adresse e-mail de ton compte Spotify dans '
          '« User Management » de ton appli sur developer.spotify.com (5 comptes au plus).';
    }
    return 'Spotify refuse (code 403) : $msg';
  }

  /// L'API ne peut pas servir (compte du créateur sans Premium…) : Mon Hub
  /// passe au mode sans API.
  static bool isBlocked(Object e) => '$e'.contains('code 403') && '$e'.contains('février 2026');

  static String _msg(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      final e = j is Map ? j['error'] : null;
      if (e is Map) return '${e['message'] ?? r.statusCode}';
      if (e != null) return '$e';
    } catch (_) {}
    return 'erreur ${r.statusCode}';
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _req('GET', path);
    if (r.statusCode == 204 || r.body.isEmpty) return const {};
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  static String? _img(Object? images) {
    if (images is List && images.isNotEmpty && images.first is Map) {
      return (images.first as Map)['url'] as String?;
    }
    return null;
  }

  static MusicTrack track(Map t, {DateTime? addedAt}) {
    final album = (t['album'] as Map?) ?? const {};
    return MusicTrack(
      title: '${t['name'] ?? ''}',
      artist: [for (final a in (t['artists'] as List?) ?? const []) '${(a as Map)['name']}']
          .join(', '),
      album: '${album['name'] ?? ''}',
      cover: _img(album['images']),
      duration: t['duration_ms'] is num
          ? Duration(milliseconds: (t['duration_ms'] as num).toInt())
          : null,
      id: '${t['id'] ?? ''}',
      uri: '${t['uri'] ?? ''}',
      link: (t['external_urls'] as Map?)?['spotify'] as String?,
      number: (t['track_number'] as num?)?.toInt() ?? 0,
      addedAt: addedAt,
    );
  }

  /// Ce qui joue sur ton compte (n'importe quel appareil).
  Future<NowPlaying?> current() async {
    final j = await _get('/me/player/currently-playing');
    final t = j['item'];
    if (t is! Map) return null;
    final album = (t['album'] as Map?) ?? const {};
    final tr = track(t);
    return NowPlaying(
      title: tr.title,
      artist: tr.artist,
      album: tr.album,
      albumArtist: [
        for (final a in (album['artists'] as List?) ?? const []) '${(a as Map)['name']}',
      ].join(', '),
      coverUrl: tr.cover,
      position: Duration(milliseconds: ((j['progress_ms'] as num?) ?? 0).toInt()),
      duration: tr.duration,
      playing: j['is_playing'] == true,
      app: 'Spotify',
      at: DateTime.now(),
      trackNumber: tr.number,
      spotifyAlbumId: album['id'] as String?,
      trackId: tr.id,
    );
  }

  /// Album avec sa liste de titres.
  Future<AlbumInfo> album(String id) async {
    final j = await _get('/albums/$id');
    final tracks = <MusicTrack>[];
    var page = j['tracks'] as Map?;
    while (page != null) {
      for (final t in (page['items'] as List?) ?? const []) {
        if (t is Map) tracks.add(track({...t, 'album': j}));
      }
      final next = page['next'];
      page = next is String && tracks.length < 200 ? await _get(next) : null;
    }
    return AlbumInfo(
      title: '${j['name'] ?? ''}',
      artist: [for (final a in (j['artists'] as List?) ?? const []) '${(a as Map)['name']}']
          .join(', '),
      cover: _img(j['images']),
      tracks: tracks,
      year: '${j['release_date'] ?? ''}'.split('-').first,
      label: j['label'] as String?,
    );
  }

  /// Tes titres likés (les plus récents d'abord).
  Future<List<MusicTrack>> liked({int max = 200}) async {
    final out = <MusicTrack>[];
    String? next = '/me/tracks?limit=50';
    while (next != null && out.length < max) {
      final j = await _get(next);
      for (final it in (j['items'] as List?) ?? const []) {
        final t = (it as Map)['track'];
        if (t is Map) out.add(track(t, addedAt: DateTime.tryParse('${it['added_at']}')));
      }
      next = j['next'] as String?;
    }
    return out;
  }

  Future<List<MusicPlaylist>> playlists() async {
    final out = <MusicPlaylist>[];
    String? next = '/me/playlists?limit=50';
    while (next != null && out.length < 200) {
      final j = await _get(next);
      for (final p in (j['items'] as List?) ?? const []) {
        if (p is! Map) continue;
        final count = (p['tracks'] as Map?)?['total'] ?? (p['items'] as Map?)?['total'];
        out.add(
          MusicPlaylist(
            id: '${p['id']}',
            name: '${p['name'] ?? ''}',
            cover: _img(p['images']),
            count: (count as num?)?.toInt() ?? 0,
            owner: '${(p['owner'] as Map?)?['display_name'] ?? ''}',
            uri: '${p['uri'] ?? ''}',
            link: (p['external_urls'] as Map?)?['spotify'] as String?,
          ),
        );
      }
      next = j['next'] as String?;
    }
    return out;
  }

  Future<List<MusicTrack>> playlistTracks(String id) async {
    Map<String, dynamic> j;
    try {
      j = await _get('/playlists/$id/items?limit=100');
    } catch (_) {
      j = await _get('/playlists/$id/tracks?limit=100');
    }
    return [
      for (final it in (j['items'] as List?) ?? const [])
        if (it is Map && (it['track'] ?? it['item']) is Map)
          track(
            (it['track'] ?? it['item']) as Map,
            addedAt: DateTime.tryParse('${it['added_at']}'),
          ),
    ];
  }

  Future<List<MusicTrack>> recent() async {
    final j = await _get('/me/player/recently-played?limit=50');
    return [
      for (final it in (j['items'] as List?) ?? const [])
        if (it is Map && it['track'] is Map)
          track(it['track'] as Map, addedAt: DateTime.tryParse('${it['played_at']}')),
    ];
  }

  /// Lance un titre (dans une playlist / un album si [context], ou dans
  /// une liste de titres [uris]).
  Future<void> play({String? uri, String? context, List<String>? uris}) => _player(
    'PUT',
    '/me/player/play${_device == null ? '' : '?device_id=$_device'}',
    body: {
      if (context != null && context.isNotEmpty) 'context_uri': context,
      if (context != null && uri != null && uri.isNotEmpty) 'offset': {'uri': uri},
      if (context == null && uris != null && uris.isNotEmpty) ...{
        'uris': uris.take(100).toList(),
        if (uri != null && uris.contains(uri)) 'offset': {'uri': uri},
      } else if (context == null && uri != null)
        'uris': [uri],
    },
  );

  /// Appareil choisi dans Mon Hub (null : celui qui joue déjà).
  String? _device;

  /// Fait jouer la musique sur cet appareil (PC, téléphone, enceinte…).
  Future<void> transfer(String deviceId, {bool play = true}) async {
    await _req(
      'PUT',
      '/me/player',
      body: {
        'device_ids': [deviceId],
        'play': play,
      },
    );
    _device = deviceId;
  }

  /// Recherche dans tout Spotify : titres, artistes, albums, playlists.
  Future<SpotifySearch> search(String query, {int limit = 10}) async {
    final j = await _get(
      '/search?q=${Uri.encodeQueryComponent(query)}&type=track,artist,album,playlist&limit=$limit',
    );
    List<Map> items(String k) =>
        (((j[k] as Map?)?['items'] as List?) ?? const []).whereType<Map>().toList();
    String names(Object? artists) =>
        [for (final a in (artists as List?) ?? const []) if (a is Map) '${a['name']}'].join(', ');
    return SpotifySearch(
      tracks: [for (final t in items('tracks')) track(t)],
      artists: [
        for (final a in items('artists'))
          SpotifyItem(
            kind: 'artist',
            id: '${a['id']}',
            name: '${a['name'] ?? ''}',
            sub: (a['genres'] as List?)?.take(2).join(', ') ?? '',
            image: _img(a['images']),
            uri: '${a['uri'] ?? ''}',
          ),
      ],
      albums: [
        for (final a in items('albums'))
          SpotifyItem(
            kind: 'album',
            id: '${a['id']}',
            name: '${a['name'] ?? ''}',
            sub: [names(a['artists']), '${a['release_date'] ?? ''}'.split('-').first]
                .where((x) => x.isNotEmpty)
                .join(' · '),
            image: _img(a['images']),
            uri: '${a['uri'] ?? ''}',
          ),
      ],
      playlists: [
        for (final p in items('playlists'))
          MusicPlaylist(
            id: '${p['id']}',
            name: '${p['name'] ?? ''}',
            cover: _img(p['images']),
            count: (((p['tracks'] ?? p['items']) as Map?)?['total'] as num?)?.toInt() ?? 0,
            owner: '${(p['owner'] as Map?)?['display_name'] ?? ''}',
            uri: '${p['uri'] ?? ''}',
            link: (p['external_urls'] as Map?)?['spotify'] as String?,
          ),
      ],
    );
  }

  /// Des titres d'un artiste (l'adresse « meilleurs titres » a été retirée
  /// par Spotify en 2026 : on passe par la recherche).
  Future<List<MusicTrack>> artistTracks(String name) async {
    final j = await _get(
      '/search?q=${Uri.encodeQueryComponent('artist:"$name"')}&type=track&limit=10',
    );
    return [
      for (final t in ((j['tracks'] as Map?)?['items'] as List?) ?? const [])
        if (t is Map) track(t),
    ];
  }

  /// La file d'attente (ce qui va jouer ensuite).
  Future<List<MusicTrack>> userQueue() async {
    final j = await _get('/me/player/queue');
    return [
      for (final t in (j['queue'] as List?) ?? const [])
        if (t is Map && t['type'] != 'episode') track(t),
    ];
  }

  /// Ajoute un titre précis à la file.
  Future<void> addToQueue(String uri) =>
      _player('POST', '/me/player/queue?uri=${Uri.encodeQueryComponent(uri)}');

  /// Joue l'album ou l'artiste trouvé par une recherche.
  Future<String> searchPlayContext(String query, String type) async {
    final hit = await searchFirst(query, type: type);
    if (hit == null) return 'Rien trouvé sur Spotify pour « $query ».';
    await _player('PUT', '/me/player/play', body: {'context_uri': hit.$1});
    return type == 'artist' ? 'Je lance ${hit.$2}.' : 'Je lance l\'album ${hit.$2}.';
  }

  /// Fait jouer sur l'appareil dont le nom ressemble à [name].
  Future<String> transferByName(String name) async {
    final list = await devices();
    final q = name.toLowerCase().trim();
    final d =
        list.where((d) => '${d['name']}'.toLowerCase() == q).firstOrNull ??
        list.where((d) => '${d['name']}'.toLowerCase().contains(q)).firstOrNull ??
        list.where((d) => '${d['type']}'.toLowerCase().contains(q)).firstOrNull;
    if (d == null) {
      return list.isEmpty
          ? 'Aucun appareil Spotify ouvert.'
          : 'Pas d\'appareil « $name ». Appareils : ${list.map((x) => x['name']).join(', ')}.';
    }
    await transfer('${d['id']}');
    return 'La musique passe sur ${d['name']}.';
  }

  /// Appareils Spotify (PC, téléphone, enceinte…).
  Future<List<Map<String, dynamic>>> devices() async {
    final j = await _get('/me/player/devices');
    return [
      for (final d in (j['devices'] as List?) ?? const [])
        if (d is Map<String, dynamic>) d,
    ];
  }

  /// Aucun appareil actif : on réveille le premier disponible (l'appli
  /// Spotify du PC de préférence), comme le plugin JARVIS.
  Future<void> _wakeDevice() async {
    final list = await devices();
    if (list.isEmpty) {
      throw 'Aucun appareil Spotify ouvert : lance l\'appli Spotify (PC ou téléphone) puis réessaie';
    }
    final pc =
        list.where((d) => '${d['type']}'.toLowerCase() == 'computer').firstOrNull ?? list.first;
    await _req(
      'PUT',
      '/me/player',
      body: {
        'device_ids': [pc['id']],
        'play': false,
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Une commande de lecture, en réveillant un appareil si besoin.
  Future<void> _player(String method, String path, {Object? body}) async {
    try {
      await _req(method, path, body: body);
    } catch (e) {
      if (!'$e'.toLowerCase().contains('device') && !'$e'.contains('404')) rethrow;
      await _wakeDevice();
      await _req(method, path, body: body);
    }
  }

  /// Premier résultat d'une recherche (titre, album, artiste, playlist).
  Future<(String uri, String name)?> searchFirst(String query, {String type = 'track'}) async {
    final j = await _get('/search?q=${Uri.encodeQueryComponent(query)}&type=$type&limit=1');
    final items = ((j['${type}s'] as Map?)?['items'] as List?) ?? const [];
    final it = items.whereType<Map>().firstOrNull;
    if (it == null) return null;
    final who = [for (final a in (it['artists'] as List?) ?? const []) '${(a as Map)['name']}']
        .join(', ');
    return ('${it['uri']}', who.isEmpty ? '${it['name']}' : '${it['name']} — $who');
  }

  /// Cherche et joue un morceau.
  Future<String> searchPlay(String query) async {
    final hit = await searchFirst(query);
    if (hit == null) return 'Rien trouvé sur Spotify pour « $query ».';
    await _player(
      'PUT',
      '/me/player/play',
      body: {
        'uris': [hit.$1],
      },
    );
    return 'J\'écoute : ${hit.$2}';
  }

  /// Joue une de tes playlists (sinon une playlist publique).
  Future<String> playPlaylist(String query) async {
    final q = query.toLowerCase().trim();
    final mine = await playlists();
    var hit =
        mine.where((p) => p.name.toLowerCase() == q).firstOrNull ??
        mine.where((p) => p.name.toLowerCase().contains(q)).firstOrNull;
    String uri, name;
    if (hit != null) {
      uri = hit.uri;
      name = hit.name;
    } else {
      final pub = await searchFirst(query, type: 'playlist');
      if (pub == null) return 'Pas de playlist « $query ».';
      (uri, name) = pub;
    }
    await _player('PUT', '/me/player/play', body: {'context_uri': uri});
    return 'Je lance la playlist $name.';
  }

  Future<String> queue(String query) async {
    final hit = await searchFirst(query);
    if (hit == null) return 'Rien trouvé sur Spotify pour « $query ».';
    await _player('POST', '/me/player/queue?uri=${Uri.encodeQueryComponent(hit.$1)}');
    return 'Ajouté à la file : ${hit.$2}';
  }

  Future<void> volume(int percent) =>
      _player('PUT', '/me/player/volume?volume_percent=${percent.clamp(0, 100)}');

  Future<void> shuffle(bool on) => _player('PUT', '/me/player/shuffle?state=$on');

  Future<void> pause() => _player('PUT', '/me/player/pause');
  Future<void> resume() => _player('PUT', '/me/player/play');
  Future<void> next() => _player('POST', '/me/player/next');
  Future<void> previous() => _player('POST', '/me/player/previous');

  /// Titre liké ? (nouvelle bibliothèque `/me/library` depuis 2026, ancienne
  /// adresse en secours).
  Future<bool> isLiked(String trackId) async {
    http.Response r;
    try {
      r = await _req('GET', '/me/library/contains?uris=${Uri.encodeQueryComponent('spotify:track:$trackId')}');
    } catch (_) {
      r = await _req('GET', '/me/tracks/contains?ids=$trackId');
    }
    final j = jsonDecode(r.body);
    return j is List && j.isNotEmpty && j.first == true;
  }

  Future<void> setLiked(String trackId, bool like) async {
    try {
      await _req(like ? 'PUT' : 'DELETE', '/me/library?uris=${Uri.encodeQueryComponent('spotify:track:$trackId')}');
    } catch (_) {
      await _req(like ? 'PUT' : 'DELETE', '/me/tracks?ids=$trackId');
    }
  }
}

/// Résultats d'une recherche Spotify.
class SpotifySearch {
  const SpotifySearch({
    this.tracks = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
  });
  final List<MusicTrack> tracks;
  final List<SpotifyItem> artists;
  final List<SpotifyItem> albums;
  final List<MusicPlaylist> playlists;

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;
}

/// Un artiste ou un album Spotify.
class SpotifyItem {
  const SpotifyItem({
    required this.kind,
    required this.id,
    required this.name,
    this.sub = '',
    this.image,
    this.uri = '',
  });

  /// 'artist' ou 'album'.
  final String kind;
  final String id;
  final String name;
  final String sub;
  final String? image;
  final String uri;
}

// ---------------------------------------------------------------------------
// Deezer (API publique : sans clé)
// ---------------------------------------------------------------------------

/// Deezer : pochettes et listes de titres des albums (pour n'importe quel
/// morceau), et ton profil public (titres favoris, playlists).
class DeezerApi {
  DeezerApi([http.Client? client]) : _http = client ?? http.Client();
  final http.Client _http;

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _http
        .get(Uri.parse(path.startsWith('http') ? path : 'https://api.deezer.com$path'))
        .timeout(const Duration(seconds: 20));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map<String, dynamic>) throw 'Deezer : réponse illisible';
    final e = j['error'];
    if (e is Map) {
      throw e['code'] == 200 || '${e['type']}'.contains('OAuth')
          ? 'Deezer : ce profil est privé (rends tes favoris publics dans Deezer → Paramètres → Confidentialité)'
          : 'Deezer : ${e['message'] ?? 'erreur'}';
    }
    return j;
  }

  static MusicTrack track(Map t) => MusicTrack(
    title: '${t['title'] ?? ''}',
    artist: '${(t['artist'] as Map?)?['name'] ?? ''}',
    album: '${(t['album'] as Map?)?['title'] ?? ''}',
    cover: ((t['album'] as Map?)?['cover_xl'] ?? (t['album'] as Map?)?['cover_big']) as String?,
    duration: t['duration'] is num ? Duration(seconds: (t['duration'] as num).toInt()) : null,
    id: '${t['id'] ?? ''}',
    preview: (t['preview'] as String?)?.isNotEmpty == true ? t['preview'] as String : null,
    link: t['link'] as String?,
    number: (t['track_position'] as num?)?.toInt() ?? 0,
    addedAt: t['time_add'] is num
        ? DateTime.fromMillisecondsSinceEpoch((t['time_add'] as num).toInt() * 1000)
        : null,
  );

  /// Trouve l'album d'un morceau (pochette HD + liste des titres).
  Future<AlbumInfo?> findAlbum(String artist, String album, String title) async {
    final a = artist.split(RegExp(r',|&| feat\.? | ft\.? ')).first.trim();
    Map<String, dynamic>? hit;
    if (album.trim().isNotEmpty) {
      final j = await _get(
        '/search/album?q=${Uri.encodeQueryComponent('artist:"$a" album:"${album.trim()}"')}&limit=5',
      );
      hit = ((j['data'] as List?) ?? const []).whereType<Map<String, dynamic>>().firstOrNull;
    }
    if (hit == null) {
      // Sans album (navigateur, single…) : on passe par le morceau.
      final j = await _get(
        '/search/track?q=${Uri.encodeQueryComponent('artist:"$a" track:"$title"')}&limit=5',
      );
      final t = ((j['data'] as List?) ?? const []).whereType<Map>().firstOrNull;
      final id = (t?['album'] as Map?)?['id'];
      if (id == null) return null;
      hit = {'id': id};
    }
    return albumById(hit['id']);
  }

  Future<AlbumInfo> albumById(Object? id) async {
    final j = await _get('/album/$id');
    final tracks = [
      for (final (i, t) in (((j['tracks'] as Map?)?['data'] as List?) ?? const []).indexed)
        if (t is Map) track({...t, 'album': j, 'track_position': t['track_position'] ?? i + 1}),
    ];
    return AlbumInfo(
      title: '${j['title'] ?? ''}',
      artist: '${(j['artist'] as Map?)?['name'] ?? ''}',
      cover: (j['cover_xl'] ?? j['cover_big']) as String?,
      tracks: tracks,
      year: '${j['release_date'] ?? ''}'.split('-').first,
      label: j['label'] as String?,
    );
  }

  /// Recherche publique (sans compte) : titres, avec extrait de 30 s.
  Future<List<MusicTrack>> search(String query, {int limit = 25}) async {
    final j = await _get('/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit');
    return [
      for (final t in (j['data'] as List?) ?? const [])
        if (t is Map) track(t),
    ];
  }

  /// Identifiant d'un profil Deezer (lien deezer.com/fr/profile/123… ou nombre).
  static String? profileId(String input) =>
      RegExp(r'(?:profile/)?(\d{3,})').firstMatch(input.trim())?.group(1);

  Future<List<MusicTrack>> favorites(String userId) async {
    final out = <MusicTrack>[];
    String? next = '/user/$userId/tracks?limit=100';
    while (next != null && out.length < 300) {
      final j = await _get(next);
      for (final t in (j['data'] as List?) ?? const []) {
        if (t is Map) out.add(track(t));
      }
      next = j['next'] as String?;
    }
    return out;
  }

  Future<List<MusicPlaylist>> playlists(String userId) async {
    final j = await _get('/user/$userId/playlists?limit=100');
    return [
      for (final p in (j['data'] as List?) ?? const [])
        if (p is Map)
          MusicPlaylist(
            id: '${p['id']}',
            name: '${p['title'] ?? ''}',
            cover: (p['picture_xl'] ?? p['picture_big'] ?? p['picture_medium']) as String?,
            count: (p['nb_tracks'] as num?)?.toInt() ?? 0,
            owner: '${(p['creator'] as Map?)?['name'] ?? ''}',
            link: p['link'] as String?,
          ),
    ];
  }

  Future<List<MusicTrack>> playlistTracks(String id) async {
    final j = await _get('/playlist/$id/tracks?limit=200');
    return [
      for (final t in (j['data'] as List?) ?? const [])
        if (t is Map) track(t),
    ];
  }

  Future<String> userName(String userId) async => '${(await _get('/user/$userId'))['name'] ?? ''}';
}
