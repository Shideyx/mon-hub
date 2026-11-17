import 'dart:math' as math;

/// Une carte de révision (recto : la question, verso : la réponse) et son
/// état de mémoire.
class StudyCard {
  StudyCard({
    required this.id,
    required this.front,
    required this.back,
    DateTime? created,
    this.state = 0,
    this.stability = 0,
    this.difficulty = 0,
    this.last,
    DateTime? due,
    this.reps = 0,
    this.lapses = 0,
  }) : created = created ?? DateTime.now(),
       due = due ?? DateTime.now();

  final String id;
  String front;
  String back;
  final DateTime created;

  /// 0 nouvelle, 1 en apprentissage, 2 apprise, 3 à réapprendre.
  int state;
  double stability;
  double difficulty;
  DateTime? last;
  DateTime due;
  int reps;
  int lapses;

  bool get isNew => state == 0;

  /// Bien ancrée dans la mémoire (plus de 3 semaines de stabilité).
  bool get mastered => state == 2 && stability >= 21;

  StudyCard copy() => StudyCard.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'f': front,
    'b': back,
    'c': created.millisecondsSinceEpoch,
    's': state,
    'st': stability,
    'd': difficulty,
    if (last != null) 'l': last!.millisecondsSinceEpoch,
    'due': due.millisecondsSinceEpoch,
    'r': reps,
    'la': lapses,
  };

  factory StudyCard.fromJson(Map j) => StudyCard(
    id: '${j['id']}',
    front: '${j['f'] ?? ''}',
    back: '${j['b'] ?? ''}',
    created: DateTime.fromMillisecondsSinceEpoch((j['c'] as num?)?.toInt() ?? 0),
    state: (j['s'] as num?)?.toInt() ?? 0,
    stability: (j['st'] as num?)?.toDouble() ?? 0,
    difficulty: (j['d'] as num?)?.toDouble() ?? 0,
    last: j['l'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['l'] as num).toInt()),
    due: DateTime.fromMillisecondsSinceEpoch((j['due'] as num?)?.toInt() ?? 0),
    reps: (j['r'] as num?)?.toInt() ?? 0,
    lapses: (j['la'] as num?)?.toInt() ?? 0,
  );
}

/// FSRS-5 (Free Spaced Repetition Scheduler), l'algorithme d'Anki : chaque
/// carte revient **juste avant que tu l'oublies**. Réponses : 1 « À revoir »,
/// 2 « Difficile », 3 « Bien », 4 « Facile ».
class Fsrs {
  Fsrs._();

  /// Paramètres par défaut de FSRS-5.
  static const w = [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192, //
    1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
  ];

  static const decay = -0.5;
  static const factor = 19 / 81;

  /// Probabilité visée de se souvenir le jour de la révision.
  static const retention = 0.9;

  /// Plus long intervalle (jours).
  static const maxDays = 365;

  /// Probabilité de se souvenir après [days] jours avec une stabilité [s].
  static double recall(double days, double s) => math.pow(1 + factor * days / s, decay).toDouble();

  static double interval(double s) => s / factor * (math.pow(retention, 1 / decay) - 1);

  static double initDifficulty(int g) => (w[4] - math.exp(w[5] * (g - 1)) + 1).clamp(1, 10).toDouble();

  static double nextDifficulty(double d, int g) {
    final delta = -w[6] * (g - 3);
    final damped = d + delta * (10 - d) / 9;
    return (w[7] * initDifficulty(4) + (1 - w[7]) * damped).clamp(1, 10).toDouble();
  }

  static double stabilityAfterRecall(double d, double s, double r, int g) =>
      s *
      (1 +
          math.exp(w[8]) *
              (11 - d) *
              math.pow(s, -w[9]) *
              (math.exp(w[10] * (1 - r)) - 1) *
              (g == 2 ? w[15] : 1) *
              (g == 4 ? w[16] : 1));

  static double stabilityAfterForget(double d, double s, double r) => math.min(
    w[11] * math.pow(d, -w[12]) * (math.pow(s + 1, w[13]) - 1) * math.exp(w[14] * (1 - r)),
    s,
  );

  /// Révision le jour même (apprentissage).
  static double shortTerm(double s, int g) => s * math.exp(w[17] * (g - 3 + w[18]));

  static int _days(double s) => interval(s).round().clamp(1, maxDays);

  /// La carte après ta réponse [g] (1 à 4), à l'instant [now].
  static StudyCard review(StudyCard card, int g, DateTime now) {
    final c = card.copy();
    g = g.clamp(1, 4);
    c.reps++;
    switch (c.state) {
      case 0:
        c
          ..stability = w[g - 1]
          ..difficulty = initDifficulty(g);
        if (g == 4) {
          c
            ..state = 2
            ..due = now.add(Duration(days: _days(c.stability)));
        } else {
          c
            ..state = 1
            ..due = now.add(Duration(minutes: const [1, 6, 10][g - 1]));
        }
      case 1 || 3:
        c
          ..stability = math.max(0.1, shortTerm(c.stability, g))
          ..difficulty = nextDifficulty(c.difficulty, g);
        if (g >= 3) {
          c
            ..state = 2
            ..due = now.add(Duration(days: g == 4 ? math.max(_days(c.stability), 2) : _days(c.stability)));
        } else {
          c.due = now.add(Duration(minutes: g == 1 ? 1 : 6));
        }
      default:
        final elapsed = math.max(0.0, now.difference(c.last ?? now).inMinutes / 1440);
        final r = recall(elapsed, math.max(c.stability, 0.1));
        if (g == 1) {
          c
            ..lapses += 1
            ..stability = math.max(0.1, stabilityAfterForget(c.difficulty, c.stability, r))
            ..difficulty = nextDifficulty(c.difficulty, 1)
            ..state = 3
            ..due = now.add(const Duration(minutes: 10));
        } else {
          final before = c.stability;
          c
            ..stability = stabilityAfterRecall(c.difficulty, c.stability, r, g)
            ..difficulty = nextDifficulty(c.difficulty, g);
          var days = _days(c.stability);
          // « Bien » et « Facile » ne reviennent jamais plus tôt qu'avant.
          if (g >= 3) days = math.max(days, _days(before) + (g == 4 ? 1 : 0));
          c.due = now.add(Duration(days: days));
        }
    }
    c.last = now;
    return c;
  }

  /// « < 1 min », « 10 min », « 3 j », « 2 sem », « 4 mois ».
  static String label(StudyCard c, int g, DateTime now) {
    final d = review(c, g, now).due.difference(now);
    if (d.inMinutes < 1) return '< 1 min';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} h';
    if (d.inDays < 14) return '${d.inDays} j';
    if (d.inDays < 60) return '${(d.inDays / 7).round()} sem';
    if (d.inDays < 365) return '${(d.inDays / 30).round()} mois';
    return '${(d.inDays / 365).toStringAsFixed(1)} an';
  }
}

/// Compare une réponse écrite à la bonne réponse (sans tenir compte des
/// accents, majuscules, ponctuation, petites fautes de frappe).
class Answer {
  Answer._();

  static String normalize(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return '$b'.replaceAll(RegExp(r"[^a-z0-9 ]+"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static int distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = [i, ...List.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce(math.min);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// Juste (ou presque : une faute de frappe par tranche de 6 lettres).
  static bool correct(String given, String expected) {
    final g = normalize(given);
    if (g.isEmpty) return false;
    // Plusieurs réponses acceptées : « Paris / la capitale ».
    for (final part in expected.split(RegExp(r'\s*[/;]\s*|\s+ou\s+'))) {
      final e = normalize(part);
      if (e.isEmpty) continue;
      if (g == e) return true;
      if (distance(g, e) <= (e.length / 6).floor()) return true;
    }
    return false;
  }
}
