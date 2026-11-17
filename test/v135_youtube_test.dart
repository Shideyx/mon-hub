import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/youtube/youtube_module.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String page(Object data) => '<html><script>var ytInitialData = ${jsonEncode(data)};</script></html>';

void main() {
  final data = {
    'contents': {
      'twoColumnSearchResultsRenderer': {
        'primaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'itemSectionRenderer': {
                  'contents': [
                    {'adSlotRenderer': {}},
                    {
                      'videoRenderer': {
                        'videoId': 'abcDEF12345',
                        'title': {
                          'runs': [
                            {'text': 'Lofi '},
                            {'text': 'pour réviser'},
                          ],
                        },
                        'ownerText': {
                          'runs': [
                            {'text': 'Lofi Girl'},
                          ],
                        },
                        'lengthText': {'simpleText': '1:02:03'},
                        'shortViewCountText': {'simpleText': '2 M de vues'},
                      },
                    },
                    {
                      'videoRenderer': {
                        'videoId': 'abcDEF12345',
                        'title': {'simpleText': 'doublon'},
                      },
                    },
                    {
                      'videoRenderer': {
                        'videoId': 'zzz_-999999',
                        'title': {'simpleText': 'Deuxième'},
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      },
    },
  };

  test('YouTube : lecture des résultats (sans doublon, titre en morceaux)', () {
    final list = YouTubeSearch.parse(page(data));
    expect(list.map((v) => v.id), ['abcDEF12345', 'zzz_-999999']);
    expect(list.first.title, 'Lofi pour réviser');
    expect(list.first.channel, 'Lofi Girl');
    expect(list.first.length, '1:02:03');
    expect(list.first.thumb, 'https://i.ytimg.com/vi/abcDEF12345/mqdefault.jpg');
    expect(YouTubeSearch.parse('<html>rien</html>'), isEmpty);
  });

  test('YouTube : recherche avec le cookie qui évite la page des cookies', () async {
    late http.Request seen;
    final c = MockClient((r) async {
      seen = r;
      return http.Response.bytes(utf8.encode(page(data)), 200);
    });
    final list = await YouTubeSearch.search('lofi réviser', client: c);
    expect(list, hasLength(2));
    expect(seen.url.queryParameters['search_query'], 'lofi réviser');
    expect(seen.headers['Cookie'], contains('SOCS'));
  });

  test('YouTube : id de vidéo dans toutes les adresses', () {
    expect(YouTubeSearch.videoId('https://www.youtube.com/watch?v=abcDEF12345&t=3'), 'abcDEF12345');
    expect(YouTubeSearch.videoId('https://youtu.be/abcDEF12345'), 'abcDEF12345');
    expect(YouTubeSearch.videoId('https://www.youtube.com/shorts/abcDEF12345'), 'abcDEF12345');
    expect(YouTubeSearch.videoId('https://www.youtube.com/feed/subscriptions'), isNull);
  });
}
