import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'hub_module.dart';
import 'module_store.dart';
import 'updater.dart';
import 'version.dart';

/// Une version publiée sur GitHub (celle que Mon Hub installe tout seul).
@immutable
class Release {
  const Release({required this.tag, required this.date, required this.notes});
  final String tag;
  final DateTime? date;

  /// Les nouveautés, une par ligne, en phrases simples.
  final List<String> notes;

  int? get number => Updater.versionNumber(tag);

  Map<String, dynamic> toJson() => {'tag': tag, 'date': date?.toIso8601String(), 'notes': notes};

  static Release? fromJson(Object? j) {
    if (j is! Map || j['tag'] is! String) return null;
    return Release(
      tag: j['tag'] as String,
      date: DateTime.tryParse('${j['date'] ?? ''}'),
      notes: [for (final n in (j['notes'] as List? ?? const [])) '$n'],
    );
  }
}

/// Les règles des nouveautés, **sans internet** : testables.
class NewsRules {
  const NewsRules._();

  /// Le texte d'une version GitHub → des lignes lisibles (sans les lignes
  /// techniques : signatures, liens, liste des fichiers).
  static List<String> clean(String body) {
    final out = <String>[];
    for (var l in const LineSplitter().convert(body)) {
      l = l.trim().replaceFirst(RegExp(r'^[*\-•]\s+'), '').replaceAll(RegExp(r'\s*\(#\d+\)$'), '').trim();
      if (l.isEmpty || l == '---') continue;
      if (RegExp(
        r'^(co-authored-by|claude-session|signed-off-by|pc windows\s*:|generated with|🤖)',
        caseSensitive: false,
      ).hasMatch(l)) {
        continue;
      }
      if (l.contains('http://') || l.contains('https://')) continue;
      if (out.contains(l)) continue;
      out.add(l.length > 220 ? '${l.substring(0, 219)}…' : l);
      if (out.length >= 8) break;
    }
    return out;
  }

  static Release? fromGitHub(Object? j) {
    if (j is! Map || j['draft'] == true) return null;
    final tag = '${j['tag_name'] ?? ''}';
    if (tag.isEmpty) return null;
    return Release(tag: tag, date: DateTime.tryParse('${j['published_at'] ?? ''}'), notes: clean('${j['body'] ?? ''}'));
  }

  /// Les versions plus récentes que [version] (la plus récente d'abord).
  static List<Release> newerThan(List<Release> all, int version) => [
    for (final r in all)
      if ((r.number ?? 0) > version) r,
  ]..sort((a, b) => (b.number ?? 0).compareTo(a.number ?? 0));

  /// Ce que Smily dit des dernières versions.
  static String say(List<Release> rs, {int max = 3}) {
    if (rs.isEmpty) return 'Pas de nouveauté depuis ta dernière mise à jour.';
    final b = StringBuffer();
    for (final r in rs.take(max)) {
      if (r.notes.isEmpty) continue;
      b.write('${r.tag} : ${r.notes.first}');
      if (r.notes.length > 1) b.write(' (${r.notes.skip(1).take(2).join(' ; ')})');
      b.write('. ');
    }
    final t = '$b'.trim();
    return t.isEmpty ? 'Des corrections, sans grosse nouveauté.' : t;
  }
}

/// **Les nouveautés de Mon Hub** : lues dans les versions publiées sur
/// GitHub (les mêmes que la mise à jour automatique installe). Smily sait
/// ainsi ce qui a changé, et le dit une fois après chaque mise à jour.
class WhatsNew {
  WhatsNew._();
  static final instance = WhatsNew._();

  static const _kCache = 'app.nouveautes';
  static const _kSeen = 'app.version.vue';

  /// Remplace GitHub (tests).
  @visibleForTesting
  static Future<List<Object?>> Function()? fetchOverride;

  static Map<dynamic, dynamic>? _read() {
    try {
      final j = jsonDecode(ModuleStore.global.getString(_kCache) ?? '');
      return j is Map ? j : null;
    } catch (_) {
      return null;
    }
  }

  List<Release> get cached {
    try {
      final m = _read();
      return [for (final r in (m?['versions'] as List? ?? const [])) ?Release.fromJson(r)];
    } catch (_) {
      return const [];
    }
  }

  DateTime? get _fetchedAt {
    try {
      return DateTime.tryParse('${_read()?['lu'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  /// Relit les versions sur GitHub (au plus toutes les 6 heures).
  Future<List<Release>> fetch({bool force = false}) async {
    final at = _fetchedAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(hours: 6)) return cached;
    try {
      final List<Object?> raw;
      if (fetchOverride != null) {
        raw = await fetchOverride!();
      } else {
        final r = await http
            .get(
              Uri.parse('https://api.github.com/repos/${Updater.repo}/releases?per_page=8'),
              headers: {'accept': 'application/vnd.github+json', 'user-agent': 'MonHub-Updater'},
            )
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) return cached;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! List) return cached;
        raw = j;
      }
      final list = [for (final x in raw) ?NewsRules.fromGitHub(x)];
      if (list.isEmpty) return cached;
      await ModuleStore.global.setString(
        _kCache,
        jsonEncode({
          'lu': DateTime.now().toIso8601String(),
          'versions': [for (final r in list) r.toJson()],
        }),
      );
      return list;
    } catch (_) {
      return cached;
    }
  }

  /// Après une mise à jour : les nouveautés à annoncer (une seule fois).
  /// Rien à la toute première ouverture (pas de « mise à jour »).
  Future<List<Release>> afterUpdate({int? current}) async {
    final now = current ?? Updater.current;
    if (now == null) return const [];
    int? seen;
    try {
      seen = ModuleStore.global.getInt(_kSeen);
    } catch (_) {}
    if (seen != null && seen >= now) return const [];
    try {
      await ModuleStore.global.setInt(_kSeen, now);
    } catch (_) {}
    if (seen == null) return const [];
    final all = await fetch(force: true);
    return [
      for (final r in NewsRules.newerThan(all, seen))
        if ((r.number ?? 0) <= now) r,
    ];
  }

  List<HubTool> tools() => [
    HubTool(
      name: 'clicky_nouveautes',
      description:
          'Les nouveautés de Mon Hub et de Smily, lues dans les mises à jour publiées sur GitHub (les mêmes que la '
          'mise à jour automatique installe) : version installée, dernières versions et ce qu\'elles ont changé, '
          'mise à jour en attente. À utiliser pour « quoi de neuf ? », « c\'est quoi la dernière mise à jour ? », '
          '« tu as appris quoi de nouveau ? ».',
      params: {'combien': ('integer', 'Nombre de versions à raconter (3 par défaut)')},
      run: (a) async {
        final n = (a['combien'] is num ? (a['combien'] as num).toInt() : 3).clamp(1, 8);
        final all = await fetch();
        final pending = Updater.instance.available;
        return {
          'resume':
              'Tu as Mon Hub $appVersion. ${NewsRules.say(all, max: n)}'
              '${pending == null ? '' : ' Une mise à jour (${pending.tag}) est prête à s\'installer.'}',
          'version_installee': appVersion,
          'versions': [
            for (final r in all.take(n)) {'version': r.tag, 'date': r.date?.toIso8601String(), 'nouveautes': r.notes},
          ],
        };
      },
    ),
  ];
}
