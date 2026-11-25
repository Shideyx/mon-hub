import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hub_files.dart';

/// Un moment vu (ou entendu) par Nexo : la fenêtre, et le texte qu'il y
/// a lu (ou ce qui a été dit dans la vidéo).
class ScreenMoment {
  ScreenMoment({
    required this.at,
    required this.app,
    required this.title,
    this.text = '',
    this.heard = false,
    DateTime? until,
  }) : until = until ?? at;

  final DateTime at;

  /// Jusqu'à quand la même chose est restée à l'écran.
  DateTime until;
  final String app;
  final String title;
  final String text;

  /// Entendu (son du PC) plutôt que vu.
  final bool heard;

  Map<String, dynamic> toJson() => {
    'a': at.millisecondsSinceEpoch,
    if (until != at) 'u': until.millisecondsSinceEpoch,
    'p': app,
    't': title,
    if (text.isNotEmpty) 'x': text,
    if (heard) 'h': true,
  };

  static ScreenMoment? fromJson(Object? j) {
    if (j is! Map || j['a'] is! num) return null;
    final at = DateTime.fromMillisecondsSinceEpoch((j['a'] as num).toInt());
    return ScreenMoment(
      at: at,
      until: j['u'] is num ? DateTime.fromMillisecondsSinceEpoch((j['u'] as num).toInt()) : at,
      app: '${j['p'] ?? ''}',
      title: '${j['t'] ?? ''}',
      text: '${j['x'] ?? ''}',
      heard: j['h'] == true,
    );
  }
}

/// Une recherche trouvée dans la mémoire.
class MemoryHit {
  const MemoryHit(this.moment, this.score, this.excerpt);
  final ScreenMoment moment;
  final int score;

  /// Le bout de texte autour des mots cherchés.
  final String excerpt;

  Map<String, dynamic> toJson() => {
    'quand': moment.at.toIso8601String(),
    'appli': moment.app,
    'fenetre': moment.title,
    if (moment.heard) 'entendu': true,
    if (excerpt.isNotEmpty) 'extrait': excerpt,
  };
}

/// **La mémoire de l'écran** (« Tu te souviens ? ») : ce que Nexo a vu à
/// l'écran (les fenêtres, et le texte lu sur le PC) et entendu (le son des
/// vidéos), pendant 7 jours. **Seulement sur ce PC**, chiffré, jamais
/// synchronisé ni envoyé ; jamais tes messageries, ta banque, tes mots de
/// passe ni la navigation privée (voir `SenseRules.privateWindow`).
class ScreenMemory extends ChangeNotifier {
  ScreenMemory._();
  static final instance = ScreenMemory._();

  static const keepDays = 7;
  static const maxMoments = 1500;
  static const maxText = 1500;

  final _file = JsonFile<List<ScreenMoment>>(
    'memoire-ecran.json',
    empty: () => <ScreenMoment>[],
    decode: (j) => [for (final e in (j is List ? j : const [])) ?ScreenMoment.fromJson(e)],
    encode: (v) => [for (final m in v) m.toJson()],
  );

  List<ScreenMoment> get moments => _file.value;
  bool _loaded = false;
  int _unsaved = 0;
  DateTime _savedAt = DateTime.now();

  Future<void> load() async {
    await _file.load();
    _loaded = true;
  }

  /// Ajoute ce qu'il vient de voir. La même fenêtre avec le même texte
  /// prolonge le dernier moment au lieu d'en créer un nouveau.
  Future<void> add(ScreenMoment m, {DateTime? now}) async {
    if (!_loaded) await load();
    final n = now ?? m.at;
    final list = moments;
    final text = m.text.length > maxText ? m.text.substring(0, maxText) : m.text;
    ScreenMoment? same;
    for (var i = list.length - 1; i >= 0 && i >= list.length - 8; i--) {
      final x = list[i];
      if (x.title == m.title && x.heard == m.heard && x.app == m.app) {
        same = x;
        break;
      }
    }
    if (same != null && same.text == text && m.at.difference(same.until) < const Duration(minutes: 30)) {
      same.until = m.at;
    } else {
      list.add(ScreenMoment(at: m.at, app: m.app, title: m.title, text: text, heard: m.heard));
      _unsaved++;
    }
    final keep = n.subtract(const Duration(days: keepDays));
    list.removeWhere((x) => x.until.isBefore(keep));
    if (list.length > maxMoments) list.removeRange(0, list.length - maxMoments);
    // Enregistré de temps en temps (le fichier chiffré est gros).
    if (_unsaved >= 12 || n.difference(_savedAt) > const Duration(minutes: 5)) await flush(now: n);
    notifyListeners();
  }

  Future<void> flush({DateTime? now}) async {
    if (!_loaded) return;
    _unsaved = 0;
    _savedAt = now ?? DateTime.now();
    await _file.save();
  }

  /// Oublie les [last] dernières minutes (ou tout).
  Future<int> forget({Duration? last, DateTime? now}) async {
    if (!_loaded) await load();
    final n = now ?? DateTime.now();
    final before = moments.length;
    if (last == null) {
      moments.clear();
    } else {
      final from = n.subtract(last);
      moments.removeWhere((m) => !m.until.isBefore(from));
    }
    await flush(now: n);
    notifyListeners();
    return before - moments.length;
  }

  // ------------------------------------------------------------ Recherche

  static const _stop = {
    'les',
    'des',
    'une',
    'que',
    'qui',
    'quoi',
    'sur',
    'dans',
    'avec',
    'pour',
    'par',
    'est',
    'etait',
    'vu',
    'site',
    'page',
    'video',
    'truc',
    'chose',
    'celui',
    'celle',
    'ceux',
    'mon',
    'ton',
    'son',
    'mes',
    'tes',
    'ses',
    'moi',
    'toi',
    'j',
    'je',
    'tu',
    'il',
    'elle',
    'on',
    'ai',
    'as',
    'avais',
    'avait',
    'regarde',
    'regardais',
    'lu',
    'lisais',
    'ouvert',
    'parlait',
    'parle',
    'qu',
    'quel',
    'quelle',
    'cetait',
    'cest',
    'ca',
    'cela',
    'ce',
    'cet',
    'cette',
    'souviens',
    'rappelles',
    'hier',
    'aujourd',
    'hui',
    'matin',
    'soir',
    'midi',
    'apres',
    'tout',
    'heure',
    'heures',
    'vers',
  };

  /// Minuscules, sans accents ni ponctuation.
  static String fold(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  /// Les mots qui comptent dans une recherche.
  static List<String> words(String q) => {
    for (final w in fold(q).split(' '))
      if (w.length >= 3 && !_stop.contains(w)) w,
  }.toList();

  /// Cherche [q] (mots), dans la période [from]–[to] si donnée.
  List<MemoryHit> search(String q, {DateTime? from, DateTime? to, int limit = 8}) {
    // « volcans » retrouve aussi « volcan » (pluriels).
    final ws = [
      for (final w in words(q)) w.length > 4 && (w.endsWith('s') || w.endsWith('x')) ? w.substring(0, w.length - 1) : w,
    ];
    final out = <MemoryHit>[];
    for (final m in moments) {
      if (from != null && m.until.isBefore(from)) continue;
      if (to != null && m.at.isAfter(to)) continue;
      if (ws.isEmpty) {
        out.add(MemoryHit(m, 1, _cut(m.text, 0)));
        continue;
      }
      final title = fold('${m.app} ${m.title}');
      final body = fold(m.text);
      var score = 0, found = 0, at = -1;
      for (final w in ws) {
        final inTitle = title.contains(w);
        final i = body.indexOf(w);
        if (inTitle || i >= 0) found++;
        if (inTitle) score += 3;
        if (i >= 0) {
          score += 1;
          if (at < 0) at = i;
        }
      }
      // La moitié des mots au moins (tous s'il n'y en a qu'un ou deux).
      if (found < (ws.length <= 2 ? ws.length : (ws.length + 1) ~/ 2)) continue;
      out.add(MemoryHit(m, score, at < 0 ? '' : _cut(body, at)));
    }
    out.sort((a, b) => b.score != a.score ? b.score.compareTo(a.score) : b.moment.at.compareTo(a.moment.at));
    // Une seule fois la même fenêtre.
    final seen = <String>{};
    return [
      for (final h in out)
        if (seen.add('${h.moment.title}|${h.moment.heard}')) h,
    ].take(limit).toList();
  }

  static String _cut(String text, int at) {
    if (text.isEmpty) return '';
    final start = (at - 60).clamp(0, text.length);
    final end = (at + 140).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end).trim()}${end < text.length ? '…' : ''}';
  }

  /// Ce qui était à l'écran entre [from] et [to] (dans l'ordre).
  List<ScreenMoment> between(DateTime from, DateTime to) => [
    for (final m in moments)
      if (!m.until.isBefore(from) && !m.at.isAfter(to)) m,
  ];

  // ---------------------------------------------------------- Les phrases

  static String hm(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static const _days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  /// « hier vers 16 h 10 », « aujourd'hui à 9 h », « mardi vers 14 h ».
  static String when(DateTime at, DateTime now) {
    final d = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
    final day = d <= 0
        ? 'aujourd\'hui'
        : d == 1
        ? 'hier'
        : d < 7
        ? _days[at.weekday - 1]
        : 'le ${at.day}/${at.month}';
    return '$day vers ${hm(at)}';
  }

  /// La réponse à « tu te souviens de… ? ».
  static String say(String q, List<MemoryHit> hits, DateTime now) {
    if (hits.isEmpty) {
      return 'Je ne retrouve rien sur « ${q.trim()} » dans ce que j\'ai vu ces 7 derniers jours.';
    }
    String one(MemoryHit h) {
      final m = h.moment;
      final where = m.heard ? 'entendu dans « ${m.title} »' : 'dans ${m.app} : « ${m.title} »';
      return '${when(m.at, now)}, $where';
    }

    final first = hits.first;
    final more = hits.skip(1).take(2).map(one).toList();
    return 'Oui ! ${_cap(one(first))}.${more.isEmpty ? '' : ' Et aussi : ${more.join(' ; ')}.'}';
  }

  /// La réponse à « qu'est-ce que je faisais mardi vers 16 h ? ».
  static String sayBetween(List<ScreenMoment> list, DateTime from, DateTime to, DateTime now) {
    if (list.isEmpty) return 'Je n\'ai rien vu à ce moment-là (tu n\'étais pas sur le PC, ou je ne regardais pas).';
    final byApp = <String, int>{};
    for (final m in list) {
      if (m.heard) continue;
      final secs = m.until.difference(m.at).inSeconds + 15;
      byApp[m.app] = (byApp[m.app] ?? 0) + secs;
    }
    final apps = byApp.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final titles = <String>[];
    for (final m in list.where((m) => !m.heard)) {
      if (!titles.contains(m.title) && m.title.trim().isNotEmpty) titles.add(m.title);
      if (titles.length >= 3) break;
    }
    final head = apps.isEmpty ? '' : 'surtout ${apps.take(3).map((e) => e.key).join(', ')}';
    return '${_cap(when(from.add(to.difference(from) ~/ 2), now))} : $head'
        '${titles.isEmpty ? '' : ' (${titles.map((t) => '« $t »').join(', ')})'}.';
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// La période dont on parle (« hier », « ce matin », « mardi vers 16 h »,
/// « il y a 20 minutes », « tout à l'heure »…).
class TimeWindow {
  const TimeWindow(this.from, this.to);
  final DateTime from;
  final DateTime to;

  static const _days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  /// La période trouvée dans [q], ou null.
  static TimeWindow? parse(String q, DateTime now) {
    final n = ScreenMemory.fold(q);
    final today = DateTime(now.year, now.month, now.day);
    final ago = RegExp(r'\bil y a (\d+) ?(minutes?|min|heures?|h)\b').firstMatch(n);
    if (ago != null) {
      final k = int.parse(ago[1]!);
      final d = ago[2]!.startsWith('h') ? Duration(hours: k) : Duration(minutes: k);
      final at = now.subtract(d);
      final spread = d.inMinutes <= 30 ? const Duration(minutes: 10) : const Duration(minutes: 30);
      return TimeWindow(at.subtract(spread), at.add(spread));
    }
    if (RegExp(r'\btout a l heure\b|\btout a lheure\b').hasMatch(n)) {
      return TimeWindow(now.subtract(const Duration(hours: 3)), now);
    }
    if (RegExp(r'\bla semaine derniere\b').hasMatch(n)) {
      final monday = today.subtract(Duration(days: now.weekday - 1));
      return TimeWindow(monday.subtract(const Duration(days: 7)), monday);
    }
    if (RegExp(r'\bcette semaine\b').hasMatch(n)) {
      return TimeWindow(today.subtract(Duration(days: now.weekday - 1)), now);
    }
    // Le jour.
    DateTime? day;
    if (RegExp(r'\bavant hier\b').hasMatch(n)) {
      day = today.subtract(const Duration(days: 2));
    } else if (RegExp(r'\bhier\b').hasMatch(n)) {
      day = today.subtract(const Duration(days: 1));
    } else if (RegExp(r'\baujourd hui\b|\bce matin\b|\bcet apres midi\b|\bce soir\b|\bce midi\b').hasMatch(n)) {
      day = today;
    } else {
      for (var i = 0; i < 7; i++) {
        if (RegExp('\\b${_days[i]}\\b').hasMatch(n)) {
          var back = (now.weekday - (i + 1)) % 7;
          if (back == 0) back = 7;
          day = today.subtract(Duration(days: back));
          break;
        }
      }
    }
    // L'heure (« vers 16 h », « à 16h30 »).
    final h = RegExp(r'\b(?:vers|a|a partir de|autour de)? ?(\d{1,2}) ?h(?: ?(\d{2}))?\b').firstMatch(n);
    if (h != null) {
      final hour = int.parse(h[1]!), minute = int.tryParse(h[2] ?? '') ?? 0;
      if (hour <= 23 && minute <= 59) {
        var d = day ?? today;
        var at = DateTime(d.year, d.month, d.day, hour, minute);
        // « vers 16 h » sans jour, alors qu'il n'est que 10 h : c'était hier.
        if (day == null && at.isAfter(now)) at = at.subtract(const Duration(days: 1));
        return TimeWindow(at.subtract(const Duration(minutes: 45)), at.add(const Duration(minutes: 45)));
      }
    }
    if (day == null) return null;
    final dd = day;
    DateTime at(int hour) => DateTime(dd.year, dd.month, dd.day, hour);
    if (RegExp(r'\bmatin\b').hasMatch(n)) return TimeWindow(at(5), at(12));
    if (RegExp(r'\bapres midi\b|\bmidi\b').hasMatch(n)) return TimeWindow(at(12), at(18));
    if (RegExp(r'\bsoir\b').hasMatch(n)) return TimeWindow(at(18), dd.add(const Duration(days: 1, hours: 2)));
    final end = dd.add(const Duration(days: 1));
    return TimeWindow(dd, end.isAfter(now) ? now : end);
  }
}
