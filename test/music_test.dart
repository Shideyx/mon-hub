import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/music/cd_case.dart';
import 'package:hub/modules/music/music_api.dart';
import 'package:hub/modules/music/music_models.dart';
import 'package:material_ui/material_ui.dart' show HSVColor;

void main() {
  test('la boîte de CD tourne : pochette, demi-tour, dos, demi-tour', () {
    expect(math.cos(SpinningCdCase.angleAt(0.1)) > 0, isTrue, reason: 'pochette');
    expect(math.cos(SpinningCdCase.angleAt(0.6)) < 0, isTrue, reason: 'tracklist au dos');
    expect(SpinningCdCase.angleAt(0.999), closeTo(2 * math.pi, 0.01));
  });

  test('couleur de la pochette', () {
    // 64 pixels rouges vifs + 64 gris.
    final px = Uint8List(128 * 4);
    for (var i = 0; i < 128; i++) {
      px.setAll(i * 4, i < 64 ? [200, 40, 40, 255] : [120, 120, 120, 255]);
    }
    final c = pickAccent(px)!;
    expect((c.r * 255).round(), greaterThan((c.g * 255).round() + 60));
    // Pochette grise : une couleur calme (avant : aucune, la page gardait la
    // couleur de l'album précédent).
    final gray = pickAccent(Uint8List.fromList(List.filled(40, 128)))!;
    expect(HSVColor.fromColor(gray).saturation, lessThan(0.15));
  });

  test('titre en cours retrouvé dans l\'album', () {
    final a = AlbumInfo(
      title: 'natsuko garage',
      artist: 'johnny5',
      tracks: const [
        MusicTrack(title: 'SETSUNA'),
        MusicTrack(title: "J'INSULTE 1 PORC (feat. hafner)"),
      ],
    );
    expect(a.indexOf("j'insulte 1 porc"), 2);
    expect(a.indexOf('Setsuna - Remastered 2026'), 1);
    expect(a.indexOf('Inconnu'), 0);
    final np = NowPlaying(
      title: 'x',
      position: const Duration(seconds: 10),
      playing: true,
      at: DateTime(2026, 1, 1, 10),
    );
    expect(np.positionNow(DateTime(2026, 1, 1, 10, 0, 5)), const Duration(seconds: 15));
    expect(const NowPlaying(title: 'x', app: 'Spotify.exe').appName, 'Spotify');
    expect(formatClock(const Duration(hours: 1, minutes: 1)), '01:01:00');
    expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
  });

  test('Deezer : album d\'un morceau (pochette + tracklist), profil', () async {
    final client = MockClient((req) async {
      final u = req.url;
      if (u.path == '/search/album') {
        expect(u.queryParameters['q'], 'artist:"johnny5" album:"natsuko garage"');
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 77},
            ],
          }),
          200,
        );
      }
      if (u.path == '/album/77') {
        return http.Response(
          jsonEncode({
            'title': 'natsuko garage',
            'artist': {'name': 'johnny5'},
            'cover_xl': 'https://cdn/xl.jpg',
            'release_date': '2026-05-01',
            'tracks': {
              'data': [
                {
                  'id': 1,
                  'title': 'SETSUNA',
                  'duration': 180,
                  'artist': {'name': 'johnny5'},
                  'preview': 'https://p/1.mp3',
                },
                {
                  'id': 2,
                  'title': 'GANG SIGN',
                  'duration': 150,
                  'artist': {'name': 'johnny5'},
                },
              ],
            },
          }),
          200,
        );
      }
      if (u.path == '/user/123/tracks') {
        return http.Response(
          jsonEncode({
            'error': {'type': 'OAuthException', 'code': 200, 'message': 'x'},
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final d = DeezerApi(client);
    final a = (await d.findAlbum('johnny5 & 44absol', 'natsuko garage', 'SETSUNA'))!;
    expect(a.cover, 'https://cdn/xl.jpg');
    expect(a.year, '2026');
    expect(a.tracks.map((t) => t.title), ['SETSUNA', 'GANG SIGN']);
    expect(a.tracks.first.number, 1);
    expect(a.tracks.first.preview, 'https://p/1.mp3');
    expect(a.tracks.first.cover, 'https://cdn/xl.jpg');
    expect(() => d.favorites('123'), throwsA(contains('privé')));
    expect(DeezerApi.profileId('https://www.deezer.com/fr/profile/123456789'), '123456789');
    expect(DeezerApi.profileId('pas un lien'), isNull);
  });

  test('Spotify : morceau lu', () {
    final t = SpotifyApi.track({
      'name': 'SETSUNA',
      'id': 'abc',
      'uri': 'spotify:track:abc',
      'duration_ms': 181000,
      'track_number': 1,
      'artists': [
        {'name': 'johnny5'},
        {'name': '44absol'},
      ],
      'album': {
        'name': 'natsuko garage',
        'images': [
          {'url': 'https://i.scdn.co/big.jpg'},
        ],
      },
    });
    expect(t.artist, 'johnny5, 44absol');
    expect(t.cover, 'https://i.scdn.co/big.jpg');
    expect(t.duration, const Duration(seconds: 181));
    expect(t.uri, 'spotify:track:abc');
  });
}
