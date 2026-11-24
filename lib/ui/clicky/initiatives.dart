// Ce que Smily repère tout seul dans tes messages, sans IA : un
// rendez-vous, une date limite, une note…

/// Une date repérée dans un message (« réunion jeudi à 18 h »).
class SpottedDate {
  const SpottedDate(this.at, {required this.hasTime, required this.kind, required this.cue, required this.sentence});

  final DateTime at;

  /// L'heure est donnée (sinon : toute la journée / date limite).
  final bool hasTime;

  /// 'rdv' (un moment où il faut être là) ou 'limite' (à rendre avant).
  final String kind;

  /// Le mot qui a fait tilt (« réunion », « à rendre »…).
  final String cue;

  /// La phrase d'où vient la date.
  final String sentence;
}

class DateSpotter {
  DateSpotter._();

  static const _months = {
    'janvier': 1,
    'janv': 1,
    'fevrier': 2,
    'fevr': 2,
    'fev': 2,
    'mars': 3,
    'avril': 4,
    'avr': 4,
    'mai': 5,
    'juin': 6,
    'juillet': 7,
    'juil': 7,
    'aout': 8,
    'septembre': 9,
    'sept': 9,
    'octobre': 10,
    'oct': 10,
    'novembre': 11,
    'nov': 11,
    'decembre': 12,
    'dec': 12,
  };
  static const _days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  static final _rdv = RegExp(
    r'\b(reunion|rendez vous|rdv|rencontre|entretien|conseil de classe|sortie scolaire|sortie|voyage|match|'
    r'entrainement|repetition|anniversaire|soiree|seance|visite|examen|oral|epreuve|on se voit|on se retrouve|'
    r'retrouve moi|rejoins moi|on s appelle|appel|visio|concert|cine|cinema)\b',
  );
  static final _limit = RegExp(
    r'\b(a rendre|rendre|date limite|avant le|au plus tard|pour le|delai|inscriptions?|a remettre|deadline|'
    r'controle|interro|interrogation|evaluation|devoir surveille|ds|dm|expose)\b',
  );

  /// Minuscules et sans accents (garde les chiffres, « / » et « : »).
  static String fold(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return '$b'
        .replaceAll(RegExp(r"[’'\-]"), ' ')
        .replaceAll(RegExp(r'[^a-z0-9/: ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Les dates à venir (60 jours max) annoncées dans [text].
  static List<SpottedDate> find(String text, DateTime now) {
    final out = <SpottedDate>[];
    final today = DateTime(now.year, now.month, now.day);
    for (final raw in text.split(RegExp(r'[.!?\n;]+'))) {
      final s = fold(raw);
      if (s.length < 6) continue;
      final rdv = _rdv.firstMatch(s);
      final lim = _limit.firstMatch(s);
      if (rdv == null && lim == null) continue;
      final day = _day(s, today);
      if (day == null) continue;
      final time = _time(s);
      final at = time == null ? day : DateTime(day.year, day.month, day.day, time.$1, time.$2);
      if (time != null ? !at.isAfter(now) : day.isBefore(today)) continue;
      if (day.difference(today).inDays > 60) continue;
      // Un moment précis avec un mot de rendez-vous = rendez-vous ; sinon date limite.
      final kind = rdv != null && (time != null || lim == null) ? 'rdv' : 'limite';
      out.add(
        SpottedDate(
          at,
          hasTime: time != null,
          kind: kind,
          cue: (kind == 'rdv' ? rdv : lim)!.group(1)!,
          sentence: raw.trim(),
        ),
      );
    }
    return out;
  }

  static DateTime? _day(String s, DateTime today) {
    if (RegExp(r'\bapres demain\b').hasMatch(s)) return today.add(const Duration(days: 2));
    if (RegExp(r'\bdemain\b').hasMatch(s)) return today.add(const Duration(days: 1));
    if (RegExp(r'\b(aujourd hui|ce soir|cet apres midi|ce matin|tout a l heure)\b').hasMatch(s)) return today;
    // « le 12 décembre », « 3 janv. »
    final named = RegExp(r'\b(\d{1,2})(?:er)? (' + _months.keys.join('|') + r')\b(?: (\d{4}))?').firstMatch(s);
    if (named != null) {
      return _build(int.parse(named[1]!), _months[named[2]!]!, named[3], today);
    }
    // « 12/12 », « 12/12/2026 »
    final num = RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b').firstMatch(s);
    if (num != null) return _build(int.parse(num[1]!), int.parse(num[2]!), num[3], today);
    // « jeudi », « jeudi prochain »
    final wd = RegExp(r'\b(' + _days.join('|') + r')\b( prochain)?').firstMatch(s);
    if (wd != null) {
      var ahead = (_days.indexOf(wd[1]!) + 1 - today.weekday) % 7;
      if (ahead == 0) ahead = 7;
      return today.add(Duration(days: ahead));
    }
    // « le 12 » (ce mois-ci, sinon le suivant)
    final lone = RegExp(r'\b(?:le|du|au|avant le|pour le) (\d{1,2})(?:er)?\b(?! ?h)(?! ?:)').firstMatch(s);
    if (lone != null) {
      final d = int.parse(lone[1]!);
      if (d < 1 || d > 31) return null;
      var at = DateTime(today.year, today.month, d);
      if (at.month != today.month) return null;
      if (at.isBefore(today)) at = DateTime(today.year, today.month + 1, d);
      return at;
    }
    return null;
  }

  static DateTime? _build(int d, int m, String? y, DateTime today) {
    if (d < 1 || d > 31 || m < 1 || m > 12) return null;
    var year = y == null ? today.year : int.parse(y.length == 2 ? '20$y' : y);
    var at = DateTime(year, m, d);
    if (at.month != m) return null; // 31/02…
    // Sans année et déjà passé : l'an prochain (« le 5 janvier » dit en décembre).
    if (y == null && today.difference(at).inDays > 30) at = DateTime(++year, m, d);
    return at;
  }

  static (int, int)? _time(String s) {
    if (RegExp(r'\bmidi\b').hasMatch(s) && !RegExp(r'apres midi').hasMatch(s)) return (12, 0);
    final m = RegExp(r"\b(?:a |vers |des |de )?(\d{1,2}) ?(?:heures?|h|:) ?(\d{2})?\b").firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m[1]!);
    final min = int.tryParse(m[2] ?? '') ?? 0;
    if (h < 6 || h > 23 || min > 59) return null;
    return (h, min);
  }

  /// « 12,5/20 » → 12.5 sur 20 (null si absent, « Abs », etc.).
  static double? grade20(String note) {
    final m = RegExp(r'^\s*(\d+(?:[.,]\d+)?)\s*/\s*(\d+(?:[.,]\d+)?)\s*$').firstMatch(note);
    if (m == null) return null;
    final v = double.parse(m[1]!.replaceAll(',', '.'));
    final on = double.parse(m[2]!.replaceAll(',', '.'));
    if (on <= 0 || v > on) return null;
    return v / on * 20;
  }
}
