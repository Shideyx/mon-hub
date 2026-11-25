import 'ed_client.dart';

/// Les calculs sur les notes, **sans IA** : moyennes (avec les coefficients
/// d'École Directe), la note qu'il faut au prochain contrôle, et le bilan de
/// la semaine.
class GradeMath {
  GradeMath._();

  /// Minuscules sans accents ni ponctuation.
  static String norm(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final k = from.indexOf(ch);
      b.write(k < 0 ? ch : to[k]);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  /// La note ramenée sur 20 (null : absent, dispensé, non significative…).
  static double? on20(EdGrade g) {
    if (!g.counts) return null;
    final v = double.tryParse(g.value.replaceAll(',', '.').trim());
    final o = double.tryParse(g.outOf.replaceAll(',', '.').trim());
    if (v == null || o == null || o <= 0 || v < 0 || v > o) return null;
    return v / o * 20;
  }

  /// Les notes de la période en cours (celle de la note la plus récente).
  static List<EdGrade> currentPeriod(List<EdGrade> all) {
    final dated = [...all]..sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    final p = dated.where((g) => g.period.isNotEmpty).firstOrNull?.period;
    if (p == null) return all;
    return [
      for (final g in all)
        if (g.period == p) g,
    ];
  }

  /// Moyenne pondérée sur 20 (null s'il n'y a aucune note qui compte).
  static double? average(Iterable<EdGrade> grades) {
    var sum = 0.0, weight = 0.0;
    for (final g in grades) {
      final v = on20(g);
      if (v == null || g.coef <= 0) continue;
      sum += v * g.coef;
      weight += g.coef;
    }
    return weight == 0 ? null : sum / weight;
  }

  /// Moyenne par matière.
  static Map<String, double> bySubject(Iterable<EdGrade> grades) {
    final groups = <String, List<EdGrade>>{};
    for (final g in grades) {
      groups.putIfAbsent(g.subject, () => []).add(g);
    }
    final out = <String, double>{};
    for (final e in groups.entries) {
      final a = average(e.value);
      if (a != null) out[e.key] = a;
    }
    return out;
  }

  /// Moyenne générale (moyenne des matières).
  static double? general(Iterable<EdGrade> grades) {
    final m = bySubject(grades).values;
    return m.isEmpty ? null : m.reduce((a, b) => a + b) / m.length;
  }

  static const _aliases = {
    'maths': 'mathematiques',
    'math': 'mathematiques',
    'svt': 'vie terre',
    'sciences de la vie': 'vie terre',
    'physique': 'physique',
    'pc': 'physique',
    'chimie': 'physique',
    'physique chimie': 'physique',
    'histoire': 'histoire',
    'geo': 'histoire',
    'geographie': 'histoire',
    'hg': 'histoire',
    'histoire geo': 'histoire',
    'eps': 'sport',
    'sport': 'sport',
    'ses': 'econo',
    'eco': 'econo',
    'philo': 'philo',
    'emc': 'moral',
    'francais': 'francais',
    'anglais': 'anglais',
    'espagnol': 'espagnol',
    'allemand': 'allemand',
    'italien': 'italien',
    'latin': 'latin',
    'nsi': 'numerique',
    'snt': 'numerique',
    'techno': 'techno',
    'musique': 'musique',
    'arts plastiques': 'arts',
    'arts': 'arts',
    'sciences': 'sciences',
  };

  /// Retrouve une matière d'École Directe à partir de ce qui est dit
  /// (« maths » → « MATHEMATIQUES », « SVT » → « SCIENCES VIE & TERRE »).
  static String? matchSubject(String query, Iterable<String> subjects) {
    final q = norm(query).replaceFirst(RegExp(r'^(?:en |de |d |la |le |les )+'), '');
    if (q.isEmpty) return null;
    final key = _aliases[q] ?? q;
    final list = subjects.toList();
    for (final s in list) {
      if (norm(s) == q) return s;
    }
    for (final s in list) {
      final n = norm(s);
      if (key.split(' ').every(n.contains)) return s;
    }
    for (final s in list) {
      if (norm(s).split(' ').any((w) => w.length >= 4 && w.startsWith(q))) return s;
    }
    return null;
  }

  /// La note à avoir au prochain devoir (sur [outOf], coefficient [coef])
  /// pour que la moyenne de [grades] atteigne [target]. Null : aucune note.
  static double? needed(List<EdGrade> grades, double target, {double coef = 1, double outOf = 20}) {
    var sum = 0.0, weight = 0.0;
    for (final g in grades) {
      final v = on20(g);
      if (v == null || g.coef <= 0) continue;
      sum += v * g.coef;
      weight += g.coef;
    }
    if (weight == 0) return null;
    final need20 = (target * (weight + coef) - sum) / coef;
    return need20 / 20 * outOf;
  }

  static String fmt(double v) {
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? '${r.round()}' : r.toStringAsFixed(1).replaceAll('.', ',');
  }

  /// Ce que Nexo dit pour « il me faut combien en maths pour avoir 14 ? ».
  static String sayNeeded(String subject, List<EdGrade> grades, double target, {double coef = 1, double outOf = 20}) {
    final avg = average(grades);
    final n = needed(grades, target, coef: coef, outOf: outOf);
    if (avg == null || n == null) return 'Je n\'ai pas encore de note en $subject ce trimestre.';
    final now = 'Ta moyenne en $subject est de ${fmt(avg)}';
    final c = coef == 1 ? '' : ' (coefficient ${fmt(coef)})';
    if (n <= 0) return '$now : même avec 0 au prochain devoir$c, tu restes au-dessus de ${fmt(target)}. 👌';
    if (n > outOf) {
      return '$now. Pour avoir ${fmt(target)}, il faudrait plus de ${fmt(outOf)}/${fmt(outOf)} au prochain devoir$c : '
          'ce n\'est pas possible en une seule note, mais deux bonnes notes peuvent y arriver.';
    }
    return '$now. Pour monter à ${fmt(target)}, il te faut au moins ${fmt(n)}/${fmt(outOf)} au prochain devoir$c.';
  }

  /// Le bilan de la semaine : les nouvelles notes, et comment les moyennes
  /// ont bougé. Null s'il n'y a pas eu de note.
  static String? weekReport(List<EdGrade> all, DateTime now, {int days = 7}) {
    final period = currentPeriod(all);
    final since = now.subtract(Duration(days: days));
    final fresh = [
      for (final g in period)
        if (g.date != null && g.date!.isAfter(since) && on20(g) != null) g,
    ];
    if (fresh.isEmpty) return null;
    final before = [
      for (final g in period)
        if (!fresh.contains(g)) g,
    ];
    final lines = <String>[];
    final subjects = {for (final g in fresh) g.subject}.toList()..sort();
    for (final s in subjects) {
      final mine = [
        for (final g in fresh)
          if (g.subject == s) g,
      ];
      final a = average([
        for (final g in before)
          if (g.subject == s) g,
      ]);
      final b = average([
        for (final g in period)
          if (g.subject == s) g,
      ]);
      final notes = mine.map((g) => '${g.value}/${g.outOf}').join(', ');
      final trend = a == null || b == null
          ? (b == null ? '' : ' (moyenne ${fmt(b)})')
          : (b - a).abs() < 0.05
          ? ' (moyenne stable à ${fmt(b)})'
          : ' (moyenne ${fmt(a)} → ${fmt(b)} ${b > a ? '↑' : '↓'})';
      lines.add('$s : $notes$trend');
    }
    final ga = general(before), gb = general(period);
    final head = fresh.length == 1 ? '1 nouvelle note cette semaine' : '${fresh.length} nouvelles notes cette semaine';
    final g = ga == null || gb == null
        ? ''
        : (gb - ga).abs() < 0.05
        ? ' Moyenne générale stable : ${fmt(gb)}.'
        : ' Moyenne générale : ${fmt(ga)} → ${fmt(gb)} ${gb > ga ? '↑' : '↓'}.';
    return '$head.$g\n${lines.join('\n')}';
  }
}
