import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/hub_files.dart';
import '../widgets.dart';

/// Une notion vue avec Smily (une question et sa réponse).
class JournalEntry {
  JournalEntry({
    required this.id,
    required this.at,
    required this.question,
    required this.answer,
    required this.topic,
    this.app = '',
    this.level = 0,
    DateTime? due,
    this.reviews = 0,
  }) : due = due ?? at.add(Journal.intervals.first);

  final String id;
  final DateTime at;
  final String question;
  final String answer;
  final String topic;
  final String app;

  /// Palier de révision (0 = à revoir demain).
  int level;
  DateTime due;
  int reviews;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.millisecondsSinceEpoch,
    'q': question,
    'a': answer,
    't': topic,
    if (app.isNotEmpty) 'app': app,
    'l': level,
    'd': due.millisecondsSinceEpoch,
    'r': reviews,
  };

  factory JournalEntry.fromJson(Map j) {
    final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0);
    return JournalEntry(
      id: '${j['id']}',
      at: at,
      question: '${j['q'] ?? ''}',
      answer: '${j['a'] ?? ''}',
      topic: '${j['t'] ?? ''}',
      app: '${j['app'] ?? ''}',
      level: (j['l'] as num?)?.toInt() ?? 0,
      due: DateTime.fromMillisecondsSinceEpoch((j['d'] as num?)?.toInt() ?? at.millisecondsSinceEpoch),
      reviews: (j['r'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Journal des connaissances : chaque question posée à Smily y est notée,
/// et Smily te propose de **réviser** au bon moment (répétition espacée :
/// 1 → 3 → 7 → 14 → 30 → 60 → 120 jours).
class Journal extends ChangeNotifier {
  Journal._();
  static final instance = Journal._();

  static const intervals = [
    Duration(days: 1),
    Duration(days: 3),
    Duration(days: 7),
    Duration(days: 14),
    Duration(days: 30),
    Duration(days: 60),
    Duration(days: 120),
  ];

  final _file = JsonFile<List<JournalEntry>>(
    'clicky-journal.json',
    empty: () => [],
    decode: (j) => [
      for (final e in (j is List ? j : const []))
        if (e is Map) JournalEntry.fromJson(e),
    ],
    encode: (v) => [for (final e in v) e.toJson()],
  );

  List<JournalEntry> get entries => [..._file.value]..sort((a, b) => b.at.compareTo(a.at));

  Future<List<JournalEntry>> load() async {
    if (await _file.reload()) notifyListeners();
    return entries;
  }

  /// Sujet court d'une question (titre du tableau s'il y en a un).
  static String topicOf(String question, [String? board]) {
    if (board != null && board.trim().isNotEmpty) return board.trim();
    final words = question.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ');
    final t = words.take(9).join(' ');
    return words.length > 9 ? '$t…' : t;
  }

  /// Les petites questions pratiques (« ouvre… », « merci ») ne sont pas des
  /// notions à réviser.
  static bool worthKeeping(String q, String a) {
    final n = q.trim().toLowerCase();
    if (n.length < 12 || a.trim().length < 40) return false;
    return !RegExp(r'^(merci|ok|oui|non|ouvre|lance|stop|salut|bonjour)\b').hasMatch(n);
  }

  Future<void> add({required String question, required String answer, String? board, String app = ''}) async {
    if (!worthKeeping(question, answer)) return;
    final now = DateTime.now();
    await _file.update(
      (l) => l
        ..add(
          JournalEntry(
            id: '${now.microsecondsSinceEpoch}',
            at: now,
            question: question,
            answer: answer.length > 1500 ? '${answer.substring(0, 1500)}…' : answer,
            topic: topicOf(question, board),
            app: app,
          ),
        )
        ..removeRange(0, l.length > 2000 ? l.length - 2000 : 0),
    );
    notifyListeners();
  }

  /// Prochaine date de révision après une réponse : su → palier suivant,
  /// pas su → on recommence demain.
  static (int, DateTime) schedule(int level, bool knew, DateTime now) {
    final next = knew ? (level + 1).clamp(0, intervals.length - 1) : 0;
    return (next, now.add(intervals[next]));
  }

  Future<void> grade(String id, bool knew) async {
    final now = DateTime.now();
    await _file.update((l) {
      final e = l.where((x) => x.id == id).firstOrNull;
      if (e != null) {
        final (lv, due) = schedule(e.level, knew, now);
        e
          ..level = lv
          ..due = due
          ..reviews += 1;
      }
      return l;
    });
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await _file.update((l) => l..removeWhere((e) => e.id == id));
    notifyListeners();
  }

  Future<void> clear() async {
    await _file.save([]);
    notifyListeners();
  }

  /// Notions à réviser maintenant.
  List<JournalEntry> due([DateTime? now]) {
    final n = now ?? DateTime.now();
    return [
      for (final e in entries)
        if (!e.due.isAfter(n)) e,
    ]..sort((a, b) => a.due.compareTo(b.due));
  }

  List<JournalEntry> since(DateTime from) => [
    for (final e in entries)
      if (!e.at.isBefore(from)) e,
  ];

  List<JournalEntry> today() {
    final n = DateTime.now();
    return since(DateTime(n.year, n.month, n.day));
  }

  List<JournalEntry> week() => since(DateTime.now().subtract(const Duration(days: 7)));

  /// Résumé texte des entrées, à donner à l'IA.
  static String digest(List<JournalEntry> l, {int max = 40}) => [
    for (final e in l.take(max))
      '- ${dayLabel(e.at)} ${hhmm(e.at)} · ${e.topic}${e.app.isEmpty ? '' : ' (${e.app})'}\n'
          '  Q : ${e.question}\n  R : ${e.answer.length > 300 ? '${e.answer.substring(0, 300)}…' : e.answer}',
  ].join('\n');
}

/// Page du journal : à réviser, aujourd'hui, cette semaine, tout.
class JournalView extends StatefulWidget {
  const JournalView({super.key, required this.color, this.onQuiz});
  final Color color;

  /// Lance un quiz avec Smily sur les notions à réviser.
  final void Function(List<JournalEntry> entries)? onQuiz;

  @override
  State<JournalView> createState() => _JournalViewState();
}

class _JournalViewState extends State<JournalView> {
  final j = Journal.instance;
  String filter = 'due';

  @override
  void initState() {
    super.initState();
    unawaited(j.load());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: j,
      builder: (context, _) {
        final due = j.due();
        final list = switch (filter) {
          'due' => due,
          'today' => j.today(),
          'week' => j.week(),
          _ => j.entries,
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: ListTile(
                leading: Icon(Icons.psychology_rounded, color: widget.color, size: 34),
                title: Text(
                  due.isEmpty
                      ? 'Rien à réviser pour l\'instant 🎉'
                      : '${due.length} notion${due.length > 1 ? 's' : ''} à réviser',
                ),
                subtitle: Text('${j.entries.length} notions dans ton journal · ${j.today().length} aujourd\'hui'),
                trailing: due.isEmpty || widget.onQuiz == null
                    ? null
                    : FilledButton.icon(
                        icon: const Icon(Icons.quiz_rounded),
                        label: const Text('Quiz'),
                        onPressed: () => widget.onQuiz!(due.take(6).toList()),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final (k, l) in const [
                  ('due', 'À réviser'),
                  ('today', 'Aujourd\'hui'),
                  ('week', 'Cette semaine'),
                  ('all', 'Tout'),
                ])
                  ChoiceChip(label: Text(l), selected: filter == k, onSelected: (_) => setState(() => filter = k)),
              ],
            ),
            const SizedBox(height: 8),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: EmptyHint(
                  'Pose des questions à Smily : chaque notion apprise est notée ici pour la réviser plus tard.',
                  icon: Icons.menu_book_rounded,
                ),
              ),
            for (final e in list)
              Card(
                child: ExpansionTile(
                  shape: const Border(),
                  leading: CircleAvatar(
                    backgroundColor: widget.color.withValues(alpha: 0.15),
                    child: Text('${e.level + 1}', style: TextStyle(color: widget.color)),
                  ),
                  title: Text(e.topic, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${dayLabel(e.at)} · prochaine révision : ${dayLabel(e.due).toLowerCase()}'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Question', style: text.labelMedium),
                    SelectableText(e.question),
                    const SizedBox(height: 8),
                    Text('Ce que Smily a expliqué', style: text.labelMedium),
                    SelectableText(e.answer),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Je savais'),
                          onPressed: () => j.grade(e.id, true),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('À revoir'),
                          onPressed: () => j.grade(e.id, false),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Retirer'),
                          onPressed: () => j.remove(e.id),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
