import 'dart:typed_data';

/// Un morceau (Spotify, Deezer, ou lu à l'écran par Windows).
class MusicTrack {
  const MusicTrack({
    required this.title,
    this.artist = '',
    this.album = '',
    this.cover,
    this.duration,
    this.id = '',
    this.uri = '',
    this.preview,
    this.link,
    this.number = 0,
    this.addedAt,
  });

  final String title;
  final String artist;
  final String album;

  /// Adresse de la pochette.
  final String? cover;
  final Duration? duration;

  /// Identifiant chez le service (Spotify ou Deezer).
  final String id;

  /// spotify:track:… (pour lancer la lecture).
  final String uri;

  /// Extrait de 30 s (Deezer).
  final String? preview;

  /// Page du morceau (ouvrir dans l'appli).
  final String? link;

  /// Numéro dans l'album.
  final int number;
  final DateTime? addedAt;
}

/// Une playlist.
class MusicPlaylist {
  const MusicPlaylist({
    required this.id,
    required this.name,
    this.cover,
    this.count = 0,
    this.owner = '',
    this.uri = '',
    this.link,
  });
  final String id;
  final String name;
  final String? cover;
  final int count;
  final String owner;
  final String uri;
  final String? link;
}

/// Album en cours : pochette en grand et liste des titres.
class AlbumInfo {
  const AlbumInfo({
    required this.title,
    required this.artist,
    this.cover,
    this.tracks = const [],
    this.year,
    this.label,
  });
  final String title;
  final String artist;
  final String? cover;
  final List<MusicTrack> tracks;
  final String? year;
  final String? label;

  /// Numéro du titre en cours dans l'album (0 = inconnu).
  int indexOf(String title) {
    final t = _norm(title);
    for (var i = 0; i < tracks.length; i++) {
      final x = _norm(tracks[i].title);
      if (x == t || x.startsWith(t) || t.startsWith(x)) return i + 1;
    }
    return 0;
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '')
      .replaceAll(RegExp(r'\s*-\s*(remaster|live|radio edit).*$'), '')
      .replaceAll(RegExp(r'[^a-z0-9àâäéèêëïîôöùûüç ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Ce qui joue en ce moment.
class NowPlaying {
  const NowPlaying({
    required this.title,
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.coverUrl,
    this.coverBytes,
    this.position = Duration.zero,
    this.duration,
    this.playing = false,
    this.app = '',
    this.at,
    this.trackNumber = 0,
    this.spotifyAlbumId,
    this.trackId = '',
    this.liked,
  });

  final String title;
  final String artist;
  final String album;
  final String albumArtist;
  final String? coverUrl;
  final Uint8List? coverBytes;

  /// Position au moment [at].
  final Duration position;
  final Duration? duration;
  final bool playing;

  /// Appli qui joue (Spotify, Deezer, navigateur…).
  final String app;
  final DateTime? at;
  final int trackNumber;
  final String? spotifyAlbumId;
  final String trackId;
  final bool? liked;

  /// Position estimée maintenant (le morceau avance tout seul).
  Duration positionNow([DateTime? now]) {
    if (!playing || at == null) return position;
    final p = position + (now ?? DateTime.now()).difference(at!);
    final d = duration;
    if (d != null && d > Duration.zero && p > d) return d;
    return p;
  }

  String get key => '$artist|$album|$title';

  /// Nom lisible de l'appli (Spotify.exe → Spotify).
  String get appName {
    final a = app.toLowerCase();
    if (a.contains('spotify')) return 'Spotify';
    if (a.contains('deezer')) return 'Deezer';
    if (a.contains('chrome')) return 'Chrome';
    if (a.contains('msedge') || a.contains('edge')) return 'Edge';
    if (a.contains('firefox')) return 'Firefox';
    if (a.contains('zune') || a.contains('music')) return 'Musique';
    return app.split(RegExp(r'[\\/!]')).last.replaceAll('.exe', '');
  }
}

/// « 3:07 », ou « 1:02:07 ».
String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// « 00 : 01 : 23 » (compteur façon lecteur CD).
String formatClock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
