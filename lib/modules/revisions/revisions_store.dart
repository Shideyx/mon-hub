import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import 'fsrs.dart';

/// Une question de quiz préparée (la bonne réponse et trois pièges).
class QuizQuestion {
  QuizQuestion(this.question, this.answer, this.wrong);
  final String question;
  final String answer;
  final List<String> wrong;

  Map<String, dynamic> toJson() => {'q': question, 'a': answer, 'w': wrong};
  factory QuizQuestion.fromJson(Map j) =>
      QuizQuestion('${j['q'] ?? ''}', '${j['a'] ?? ''}', [for (final w in (j['w'] as List?) ?? const []) '$w']);
}

/// Un paquet de cartes (une matière, un chapitre…).
class Deck {
  Deck({
    required this.id,
    required this.name,
    this.color = 0xFF7C5CFF,
    DateTime? created,
    List<StudyCard>? cards,
    this.sheet,
    List<QuizQuestion>? quiz,
    this.testId,
    this.testDate,
    this.sheetDoc,
  }) : created = created ?? DateTime.now(),
       cards = cards ?? [],
       quiz = quiz ?? [];

  final String id;
  String name;
  int color;
  final DateTime created;
  final List<StudyCard> cards;

  /// La fiche de révision (Markdown), préparée par Smily.
  String? sheet;

  /// Le quiz préparé (QCM avec de vrais pièges).
  final List<QuizQuestion> quiz;

  /// Le contrôle d'École Directe pour lequel ce paquet a été préparé.
  String? testId;
  DateTime? testDate;

  /// La fiche, aussi en Google Doc.
  String? sheetDoc;

  /// Cartes à revoir maintenant (sans les nouvelles).
  List<StudyCard> dueReviews(DateTime now) => [
    for (final c in cards)
      if (!c.isNew && !c.due.isAfter(now)) c,
  ]..sort((a, b) => a.due.compareTo(b.due));

  List<StudyCard> get fresh => [
    for (final c in cards)
      if (c.isNew) c,
  ];

  /// Part des cartes bien ancrées (0..1).
  double get mastery => cards.isEmpty ? 0 : cards.where((c) => c.mastered).length / cards.length;

  /// Part des cartes déjà vues au moins une fois.
  double get seen => cards.isEmpty ? 0 : cards.where((c) => !c.isNew).length / cards.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'created': created.millisecondsSinceEpoch,
    'cards': [for (final c in cards) c.toJson()],
    'sheet': ?sheet,
    if (quiz.isNotEmpty) 'quiz': [for (final q in quiz) q.toJson()],
    'test': ?testId,
    if (testDate != null) 'testDate': testDate!.millisecondsSinceEpoch,
    'sheetDoc': ?sheetDoc,
  };

  factory Deck.fromJson(Map j) => Deck(
    id: '${j['id']}',
    name: '${j['name'] ?? 'Paquet'}',
    color: (j['color'] as num?)?.toInt() ?? 0xFF7C5CFF,
    created: DateTime.fromMillisecondsSinceEpoch((j['created'] as num?)?.toInt() ?? 0),
    cards: [
      for (final c in (j['cards'] as List?) ?? const [])
        if (c is Map) StudyCard.fromJson(c),
    ],
    sheet: j['sheet'] as String?,
    quiz: [
      for (final q in (j['quiz'] as List?) ?? const [])
        if (q is Map) QuizQuestion.fromJson(q),
    ],
    testId: j['test'] as String?,
    testDate: j['testDate'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['testDate'] as num).toInt()),
    sheetDoc: j['sheetDoc'] as String?,
  );
}

/// Ce qu'on a fait un jour donné.
class StudyDay {
  StudyDay({this.cards = 0, this.fresh = 0, this.minutes = 0, this.right = 0});
  int cards;
  int fresh;
  int minutes;
  int right;

  Map<String, dynamic> toJson() => {'c': cards, 'n': fresh, 'm': minutes, 'r': right};
  factory StudyDay.fromJson(Map j) => StudyDay(
    cards: (j['c'] as num?)?.toInt() ?? 0,
    fresh: (j['n'] as num?)?.toInt() ?? 0,
    minutes: (j['m'] as num?)?.toInt() ?? 0,
    right: (j['r'] as num?)?.toInt() ?? 0,
  );
}

class RevisionsData {
  RevisionsData({List<Deck>? decks, Map<String, StudyDay>? days, this.newPerDay = 20})
    : decks = decks ?? [],
      days = days ?? {};
  final List<Deck> decks;
  final Map<String, StudyDay> days;
  int newPerDay;
}

/// Tes révisions, chiffrées sur l'appareil.
class RevisionsStore extends ChangeNotifier {
  RevisionsStore._();
  static final instance = RevisionsStore._();

  static const palette = [
    0xFF7C5CFF,
    0xFFE0457B,
    0xFF0B6FB8,
    0xFF16A085,
    0xFFE67E22,
    0xFF8E44AD,
    0xFFC0392B,
    0xFF2B579A,
  ];

  final _file = JsonFile<RevisionsData>(
    'revisions.json',
    empty: RevisionsData.new,
    decode: (j) {
      final m = j is Map ? j : const {};
      return RevisionsData(
        decks: [
          for (final d in (m['decks'] as List?) ?? const [])
            if (d is Map) Deck.fromJson(d),
        ],
        days: {
          for (final e in ((m['days'] as Map?) ?? const {}).entries)
            if (e.value is Map) '${e.key}': StudyDay.fromJson(e.value as Map),
        },
        newPerDay: (m['newPerDay'] as num?)?.toInt() ?? 20,
      );
    },
    encode: (v) => {
      'decks': [for (final d in v.decks) d.toJson()],
      'days': {for (final e in v.days.entries) e.key: e.value.toJson()},
      'newPerDay': v.newPerDay,
    },
  );

  RevisionsData get data => _file.value;
  List<Deck> get decks => data.decks;

  Future<RevisionsData> load() async {
    if (await _file.reload()) notifyListeners();
    return _file.value;
  }

  Future<void> _save() async {
    await _file.save();
    notifyListeners();
  }

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  StudyDay today([DateTime? now]) => data.days[dayKey(now ?? DateTime.now())] ?? StudyDay();

  Deck? deck(String idOrName) {
    final q = idOrName.trim().toLowerCase();
    return decks.where((d) => d.id == idOrName).firstOrNull ??
        decks.where((d) => d.name.toLowerCase() == q).firstOrNull ??
        decks.where((d) => d.name.toLowerCase().contains(q) && q.isNotEmpty).firstOrNull;
  }

  Future<Deck> createDeck(String name, {int? color}) async {
    await load();
    final existing = deck(name);
    if (existing != null && existing.name.toLowerCase() == name.trim().toLowerCase()) return existing;
    final d = Deck(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Paquet' : name.trim(),
      color: color ?? palette[decks.length % palette.length],
    );
    data.decks.add(d);
    await _save();
    return d;
  }

  Future<int> addCards(String deckId, List<(String, String)> cards) async {
    final d = deck(deckId);
    if (d == null) return 0;
    var n = 0;
    final now = DateTime.now();
    for (final (f, b) in cards) {
      if (f.trim().isEmpty || b.trim().isEmpty) continue;
      d.cards.add(StudyCard(id: '${now.microsecondsSinceEpoch}-${n++}', front: f.trim(), back: b.trim()));
    }
    await _save();
    return n;
  }

  Future<void> updateCard(String deckId, StudyCard card) async {
    final d = deck(deckId);
    if (d == null) return;
    final i = d.cards.indexWhere((c) => c.id == card.id);
    if (i >= 0) d.cards[i] = card;
    await _save();
  }

  /// Enregistre les changements d'un paquet (fiche, quiz…).
  Future<void> saveDeck() => _save();

  /// Le paquet préparé pour un contrôle.
  Deck? forTest(String testId) => decks.where((d) => d.testId == testId).firstOrNull;

  Future<void> removeCard(String deckId, String cardId) async {
    deck(deckId)?.cards.removeWhere((c) => c.id == cardId);
    await _save();
  }

  Future<void> renameDeck(String id, String name) async {
    final d = deck(id);
    if (d == null || name.trim().isEmpty) return;
    d.name = name.trim();
    await _save();
  }

  Future<void> deleteDeck(String id) async {
    data.decks.removeWhere((d) => d.id == id);
    await _save();
  }

  /// Nouvelles cartes encore permises aujourd'hui (toutes matières).
  int freshLeft([DateTime? now]) => (data.newPerDay - today(now).fresh).clamp(0, 9999);

  /// Les cartes d'une séance : à revoir d'abord, puis des nouvelles.
  List<(Deck, StudyCard)> session({String? deckId, DateTime? now, int max = 200}) {
    final n = now ?? DateTime.now();
    final list = deckId == null ? decks : [?deck(deckId)];
    final due = <(Deck, StudyCard)>[
      for (final d in list)
        for (final c in d.dueReviews(n)) (d, c),
    ];
    var left = freshLeft(n);
    final fresh = <(Deck, StudyCard)>[];
    for (final d in list) {
      for (final c in d.fresh) {
        if (left-- <= 0) break;
        fresh.add((d, c));
      }
    }
    return [...due, ...fresh].take(max).toList();
  }

  int dueCount([DateTime? now]) => session(now: now).length;

  /// Enregistre une réponse (FSRS) et les statistiques du jour.
  Future<StudyCard> grade(String deckId, StudyCard card, int g, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    final next = Fsrs.review(card, g, n);
    final d = deck(deckId);
    if (d != null) {
      final i = d.cards.indexWhere((c) => c.id == card.id);
      if (i >= 0) d.cards[i] = next;
    }
    final day = data.days.putIfAbsent(dayKey(n), StudyDay.new);
    day.cards++;
    if (card.isNew) day.fresh++;
    if (g >= 3) day.right++;
    await _save();
    return next;
  }

  /// Minutes de concentration (minuteur) ou de quiz.
  Future<void> addMinutes(int minutes, {DateTime? now}) async {
    if (minutes <= 0) return;
    await load();
    data.days.putIfAbsent(dayKey(now ?? DateTime.now()), StudyDay.new).minutes += minutes;
    await _save();
  }

  /// Jours de suite où tu as révisé (aujourd'hui compte s'il y a déjà eu
  /// quelque chose, sinon la série d'hier tient encore).
  int streak([DateTime? now]) {
    final n = now ?? DateTime.now();
    bool active(DateTime d) {
      final s = data.days[dayKey(d)];
      return s != null && (s.cards > 0 || s.minutes > 0);
    }

    var day = DateTime(n.year, n.month, n.day);
    if (!active(day)) day = day.subtract(const Duration(days: 1));
    var count = 0;
    while (active(day)) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  Future<void> setNewPerDay(int n) async {
    data.newPerDay = n.clamp(0, 200);
    await _save();
  }

  /// Lit des cartes « question - réponse » (une par ligne ; séparateurs :
  /// tabulation, « - », « : », « = », « ; »), comme l'import de Quizlet.
  static List<(String, String)> parseLines(String text) {
    final out = <(String, String)>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim().replaceFirst(RegExp(r'^[-*•]\s+'), '');
      if (line.isEmpty) continue;
      final m = RegExp(r'^(.+?)\s*(?:\t|\s[-–—]\s|\s?:\s|\s=\s|;)\s*(.+)$').firstMatch(line);
      if (m != null) out.add((m.group(1)!.trim(), m.group(2)!.trim()));
    }
    return out;
  }
}
