import '../../modules/ecoledirecte/grade_math.dart';

/// **Prépare ton sac** (sans IA) : d'après les cours de demain, les affaires
/// à prendre (tenue de sport le jour d'EPS, calculatrice en maths…), et les
/// devoirs à rendre ou les contrôles. Les affaires de chaque matière se
/// règlent (« EPS : tenue, baskets, gourde »).
class SchoolBag {
  SchoolBag._();

  static String _norm(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final k = from.indexOf(ch);
      b.write(k < 0 ? ch : to[k]);
    }
    return ' ${b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()} ';
  }

  /// Les affaires habituelles par matière (motif dans le nom du cours).
  static const defaults = <(String, List<String>)>[
    (r' (eps|sport|ed physique|education physique) ', ['ta tenue de sport', 'tes baskets', 'une gourde']),
    (r' (math|mathematiques) ', ['ta calculatrice', 'ta règle et ton équerre']),
    (r' (physique|chimie) ', ['ta calculatrice', 'ta blouse s\'il y a TP']),
    (r' (svt|vie|terre) ', ['ta blouse s\'il y a TP']),
    (r' anglais ', ['ton livre d\'anglais']),
    (r' espagnol ', ['ton livre d\'espagnol']),
    (r' allemand ', ['ton livre d\'allemand']),
    (r' italien ', ['ton livre d\'italien']),
    (r' (arts plastiques|arts pla) ', ['ton matériel d\'arts plastiques']),
    (r' (musique|education musicale) ', ['ton cahier de musique']),
    (r' (techno|technologie) ', ['ta clé USB']),
  ];

  /// « EPS : tenue, baskets » (une matière par ligne) → affaires choisies.
  static Map<String, List<String>> parseCustom(String text) => {
    for (final line in text.split('\n'))
      if (line.contains(':') && line.split(':').first.trim().isNotEmpty)
        line.split(':').first.trim(): [
          for (final i in line.substring(line.indexOf(':') + 1).split(RegExp(r'[,;]')))
            if (i.trim().isNotEmpty) i.trim(),
        ],
  };

  static String customText(Map<String, List<String>> custom) =>
      [for (final e in custom.entries) '${e.key} : ${e.value.join(', ')}'].join('\n');

  /// Les affaires d'un cours (ce que tu as réglé remplace les habituelles).
  static List<String> itemsFor(String subject, [Map<String, List<String>> custom = const {}]) {
    final n = _norm(subject);
    for (final e in custom.entries) {
      final k = _norm(e.key).trim();
      // « Maths » = « MATHEMATIQUES », « SVT » = « SCIENCES VIE & TERRE »…
      if (k.isNotEmpty && (n.contains(' $k') || GradeMath.matchSubject(e.key, [subject]) != null)) return e.value;
    }
    // Une seule famille par cours (« ED. PHYSIQUE & SPORT » = sport, pas
    // physique-chimie).
    for (final (pattern, items) in defaults) {
      if (RegExp(pattern).hasMatch(n)) return items;
    }
    return const [];
  }

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('${v ?? ''}');

  /// Ce qu'il faut pour [day] : (cours, affaires, devoirs à rendre,
  /// contrôles). Null : pas cours ce jour-là.
  static ({List<String> subjects, List<String> items, List<String> homework, List<String> tests})? plan({
    required List<Map> events,
    required List<Map> homework,
    required DateTime day,
    Map<String, List<String>> custom = const {},
  }) {
    final d = DateTime(day.year, day.month, day.day);
    bool same(DateTime? x) => x != null && x.year == d.year && x.month == d.month && x.day == d.day;
    final lessons = [
      for (final e in events)
        if (e['annule'] != true && same(_date(e['debut'])) && '${e['source'] ?? ''}'.toLowerCase().contains('cole')) e,
    ]..sort((a, b) => _date(a['debut'])!.compareTo(_date(b['debut'])!));
    if (lessons.isEmpty) return null;
    final subjects = <String>[];
    for (final l in lessons) {
      final t = '${l['titre'] ?? ''}'.trim();
      if (t.isNotEmpty && !subjects.contains(t)) subjects.add(t);
    }
    final items = <String>[];
    for (final s in subjects) {
      for (final i in itemsFor(s, custom)) {
        if (!items.contains(i)) items.add(i);
      }
    }
    final hw = <String>[], tests = <String>[];
    for (final h in homework) {
      if (!same(_date(h['pour_le']))) continue;
      final s = '${h['matiere'] ?? ''}'.trim();
      if (h['controle'] == true) {
        if (!tests.contains(s)) tests.add(s);
      } else if (h['fait'] != true && !hw.contains(s)) {
        hw.add(s);
      }
    }
    return (subjects: subjects, items: items, homework: hw, tests: tests);
  }

  static String _list(List<String> l) =>
      l.length <= 1 ? l.join() : '${l.sublist(0, l.length - 1).join(', ')} et ${l.last}';

  /// Ce que Nexo dit ([day] : « demain », « lundi »).
  static String say(
    ({List<String> subjects, List<String> items, List<String> homework, List<String> tests}) p,
    String day,
  ) {
    final cap = day.isEmpty ? day : day[0].toUpperCase() + day.substring(1);
    return [
      '$cap, tu as ${_list(p.subjects)}.',
      if (p.items.isNotEmpty) 'Dans ton sac : ${_list(p.items)}.' else 'Pas d\'affaires spéciales à prévoir.',
      if (p.homework.isNotEmpty) 'Devoirs pour $day : ${_list(p.homework)}, vérifie qu\'ils sont faits.',
      if (p.tests.isNotEmpty) 'Et contrôle de ${_list(p.tests)} $day : une dernière révision ce soir ?',
    ].join(' ');
  }
}
