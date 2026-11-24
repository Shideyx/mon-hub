// **Veille sur ce que tu aimes** (v1.58) : deux fois par jour, Smily regarde
// les artistes de tes titres likés (Spotify ou Deezer) et te prévient quand
// l'un d'eux sort un nouveau son (API publique de Deezer, sans compte ni
// clé : seuls les noms d'artistes sont cherchés).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/hub_files.dart';
import '../../core/module_store.dart';

class ArtistWatch {
  ArtistWatch._();
  static final instance = ArtistWatch._();

  static const _key = 'app.veille';

  static bool get on {
    try {
      return ModuleStore.global.getBool(_key) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setOn(bool v) => ModuleStore.global.setBool(_key, v);

  /// Requêtes web (tests).
  @visibleForTesting
  static http.Client Function() client = http.Client.new;

  final _file = JsonFile<Map<String, dynamic>>(
    'veille.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  /// Branché par Mon Hub : les titres likés (« Artiste - Titre ») et
  /// prévenir.
  Future<Object?> Function(String tool, Map<String, dynamic> args)? call;
  void Function(String title, String body)? alert;
  Timer? _timer;

  /// Les artistes les plus présents dans tes titres likés.
  static List<String> topArtists(List<String> liked, {int max = 8}) {
    final count = <String, int>{};
    final names = <String, String>{};
    for (final l in liked) {
      final i = l.indexOf(' - ');
      if (i <= 0) continue;
      final a = l.substring(0, i).split(RegExp(r',| & | feat\.? | ft\.? ', caseSensitive: false)).first.trim();
      if (a.isEmpty) continue;
      final k = a.toLowerCase();
      count[k] = (count[k] ?? 0) + 1;
      names[k] ??= a;
    }
    final list = count.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list.take(max)) names[e.key]!];
  }

  /// Les sorties récentes (moins de [days] jours) pas encore annoncées.
  static List<Map> fresh(List albums, Set<String> seen, DateTime now, {int days = 10}) => [
    for (final a in albums)
      if (a is Map &&
          !seen.contains('${a['id']}') &&
          DateTime.tryParse('${a['release_date']}') != null &&
          !DateTime.parse('${a['release_date']}').isAfter(now) &&
          now.difference(DateTime.parse('${a['release_date']}')).inDays <= days)
        a,
  ];

  static String say(String artist, Map album) {
    final type = switch ('${album['record_type']}') {
      'album' => 'un nouvel album',
      'ep' => 'un nouvel EP',
      _ => 'un nouveau son',
    };
    return '🎵 $artist a sorti $type : « ${album['title']} ».';
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => unawaited(check().catchError((Object _) => 0)));
    Timer(const Duration(minutes: 3), () => unawaited(check().catchError((Object _) => 0)));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Deux fois par jour au plus : les nouveautés de tes artistes.
  Future<int> check({DateTime? now, bool force = false}) async {
    if (!on || call == null) return 0;
    final n = now ?? DateTime.now();
    await _file.load();
    final d = _file.value;
    final at = (d['at'] as num?)?.toInt() ?? 0;
    if (!force && n.millisecondsSinceEpoch - at < const Duration(hours: 12).inMilliseconds) return 0;
    d['at'] = n.millisecondsSinceEpoch;
    final liked = await call!('musique_titres_likes', const {});
    final artists = topArtists([for (final l in (liked is List ? liked : const [])) '$l']);
    if (artists.isEmpty) {
      await _file.save(d);
      return 0;
    }
    final ids = Map<String, dynamic>.from((d['ids'] as Map?) ?? const {});
    final seen = {for (final s in (d['vus'] as List?) ?? const []) '$s'};
    var told = 0;
    final c = client();
    try {
      for (final a in artists) {
        var id = ids[a.toLowerCase()];
        if (id == null) {
          final r = await c
              .get(Uri.parse('https://api.deezer.com/search/artist?q=${Uri.encodeQueryComponent(a)}&limit=1'))
              .timeout(const Duration(seconds: 10));
          final first = ((jsonDecode(r.body) as Map)['data'] as List?)?.firstOrNull;
          if (first is! Map) continue;
          id = first['id'];
          ids[a.toLowerCase()] = id;
        }
        final r = await c
            .get(Uri.parse('https://api.deezer.com/artist/$id/albums?limit=10'))
            .timeout(const Duration(seconds: 10));
        final albums = ((jsonDecode(r.body) as Map)['data'] as List?) ?? const [];
        for (final al in fresh(albums, seen, n)) {
          seen.add('${al['id']}');
          if (told < 3) {
            alert?.call('🎵 Nouveau chez $a', say(a, al));
            told++;
          }
        }
      }
    } catch (_) {
    } finally {
      c.close();
    }
    d['ids'] = ids;
    d['vus'] = seen.toList().reversed.take(300).toList();
    await _file.save(d);
    return told;
  }
}
