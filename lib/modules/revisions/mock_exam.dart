import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../ui/widgets.dart';
import 'fiche_view.dart';
import 'revisions_store.dart';

/// Une question du contrôle blanc.
class ExamQuestion {
  ExamQuestion({required this.text, this.choices = const [], this.answer = 0, this.expected = '', this.points = 2});

  final String text;

  /// QCM : les choix et le numéro de la bonne réponse. Vide : question à
  /// réponse rédigée.
  final List<String> choices;
  final int answer;

  /// Ce qu'on attend (pour la correction d'une réponse rédigée).
  final String expected;
  final double points;

  bool get isChoice => choices.length >= 2;
}

/// Ce qui a été corrigé, question par question.
class ExamMark {
  ExamMark(this.got, this.max, this.comment);
  final double got;
  final double max;
  final String comment;
}

/// **Contrôle blanc** : un vrai sujet chronométré fait par l'IA à partir de
/// tes fiches, cartes et comptes rendus de cours ; tu réponds, l'IA corrige
/// et note sur 20, puis te dit quoi revoir.
class MockExam {
  MockExam({required this.title, required this.minutes, required this.questions});

  final String title;
  final int minutes;
  final List<ExamQuestion> questions;

  double get total => questions.fold(0, (s, q) => s + q.points);

  static const system =
      'Tu es un professeur de lycée français qui prépare et corrige des contrôles. Tu réponds uniquement en JSON valide.';

  /// Ce qui sert à faire le sujet : la fiche, les cartes, le quiz du paquet.
  static String material(Deck d) {
    final b = StringBuffer();
    if ((d.sheet ?? '').trim().isNotEmpty) b.writeln('Fiche :\n${d.sheet}\n');
    if (d.cards.isNotEmpty) {
      b.writeln('Cartes :');
      for (final c in d.cards.take(80)) {
        b.writeln('- ${c.front} → ${c.back}');
      }
    }
    if (d.quiz.isNotEmpty) {
      b.writeln('\nQuiz :');
      for (final q in d.quiz.take(20)) {
        b.writeln('- ${q.question} → ${q.answer}');
      }
    }
    final t = b.toString();
    return t.length > 40000 ? t.substring(0, 40000) : t;
  }

  static String prompt(String subject, String material) =>
      'Prépare un contrôle blanc de niveau lycée (programme français) sur : $subject.\n'
      '${material.trim().isEmpty ? '' : 'Le cours à interroger :\n---\n$material\n---\n'}'
      'Comme un vrai contrôle : 4 questions à choix multiples (un seul bon choix, de vrais pièges) puis 3 ou 4 '
      'questions rédigées (définir, expliquer, appliquer, un petit exercice), du plus simple au plus difficile, '
      'barème total sur 20. N\'interroge que sur le cours donné.\n'
      'Réponds uniquement avec ce JSON :\n'
      '{"titre": "…", "minutes": 25, "questions": ['
      '{"type": "qcm", "question": "…", "choix": ["…", "…", "…", "…"], "bonne": 0, "points": 1}, '
      '{"type": "redigee", "question": "…", "attendu": "les éléments de réponse attendus", "points": 4}]}';

  /// L'objet JSON de la réponse de l'IA (même entouré de texte ou de ```).
  static Object? _object(String text) {
    final t = text.replaceAll(RegExp(r'```(?:json)?'), '');
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      return jsonDecode(t.substring(a, b + 1));
    } catch (_) {
      return null;
    }
  }

  static MockExam? parse(String text) {
    final j = _object(text);
    if (j is! Map) return null;
    final qs = <ExamQuestion>[];
    for (final q in (j['questions'] is List ? j['questions'] as List : const [])) {
      if (q is! Map) continue;
      final text = '${q['question'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final choices = [for (final c in (q['choix'] is List ? q['choix'] as List : const [])) '$c'];
      final points = ((q['points'] as num?)?.toDouble() ?? 2).clamp(0.5, 10).toDouble();
      final good = (q['bonne'] as num?)?.toInt() ?? 0;
      qs.add(
        ExamQuestion(
          text: text,
          choices: choices.length >= 2 ? choices : const [],
          answer: good.clamp(0, choices.isEmpty ? 0 : choices.length - 1),
          expected: '${q['attendu'] ?? ''}',
          points: points,
        ),
      );
    }
    if (qs.isEmpty) return null;
    return MockExam(
      title: '${j['titre'] ?? 'Contrôle blanc'}',
      minutes: ((j['minutes'] as num?)?.toInt() ?? 25).clamp(10, 60),
      questions: qs,
    );
  }

  /// La correction des réponses rédigées (les QCM se corrigent tout seuls).
  String gradePrompt(List<String> answers) {
    final b = StringBuffer()
      ..writeln(
        'Corrige cette copie de contrôle blanc ($title), avec bienveillance mais justement, comme un professeur.',
      )
      ..writeln(
        'Pour chaque question rédigée, donne les points obtenus (par demi-point) et un commentaire court qui dit '
        'ce qui manque ou ce qui est faux.',
      )
      ..writeln();
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      if (q.isChoice) continue;
      b
        ..writeln('Question ${i + 1} (${q.points} points) : ${q.text}')
        ..writeln('Attendu : ${q.expected}')
        ..writeln('Réponse de l\'élève : ${answers[i].trim().isEmpty ? '(pas de réponse)' : answers[i]}')
        ..writeln();
    }
    b.writeln(
      'Réponds uniquement avec ce JSON : {"questions": [{"numero": 5, "points": 2.5, "commentaire": "…"}], '
      '"conseil": "ce qu\'il faut revoir en priorité, en 2 ou 3 phrases"}',
    );
    return b.toString();
  }

  /// Les QCM corrigés tout de suite ; les réponses rédigées avec la
  /// correction de l'IA ([graded] : sa réponse, ou null sans IA).
  (List<ExamMark>, String) mark(List<String> answers, String? graded) {
    final j = graded == null ? null : _object(graded);
    final byNumber = <int, Map>{};
    if (j is Map && j['questions'] is List) {
      for (final q in j['questions'] as List) {
        if (q is Map && q['numero'] is num) byNumber[(q['numero'] as num).toInt()] = q;
      }
    }
    final marks = <ExamMark>[];
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      if (q.isChoice) {
        final ok = answers[i] == '${q.answer}';
        marks.add(
          ExamMark(
            ok ? q.points : 0,
            q.points,
            ok ? 'Bonne réponse.' : 'La bonne réponse était : ${q.choices[q.answer]}.',
          ),
        );
      } else {
        final g = byNumber[i + 1];
        final got = ((g?['points'] as num?)?.toDouble() ?? 0).clamp(0, q.points).toDouble();
        marks.add(
          ExamMark(
            got,
            q.points,
            '${g?['commentaire'] ?? (answers[i].trim().isEmpty ? 'Pas de réponse.' : 'Pas de correction disponible.')}',
          ),
        );
      }
    }
    final advice = j is Map ? '${j['conseil'] ?? ''}' : '';
    return (marks, advice);
  }

  /// La note sur 20.
  static double on20(List<ExamMark> marks) {
    final max = marks.fold<double>(0, (s, m) => s + m.max);
    if (max == 0) return 0;
    final got = marks.fold<double>(0, (s, m) => s + m.got);
    return (got / max * 20 * 2).round() / 2;
  }
}

/// Le contrôle blanc à l'écran : préparation, sujet chronométré, correction.
class MockExamPage extends StatefulWidget {
  const MockExamPage({super.key, required this.subject, this.material = '', this.color = const Color(0xFF7C5CFF)});
  final String subject;
  final String material;
  final Color color;

  @override
  State<MockExamPage> createState() => _MockExamPageState();
}

class _MockExamPageState extends State<MockExamPage> {
  MockExam? exam;
  String? error;
  List<String> answers = [];
  List<TextEditingController> _fields = [];
  DateTime? started;
  Timer? _clock;
  bool grading = false;
  List<ExamMark>? marks;
  String advice = '';

  @override
  void initState() {
    super.initState();
    unawaited(_make());
  }

  @override
  void dispose() {
    _clock?.cancel();
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _make() async {
    setState(() {
      exam = null;
      error = null;
      marks = null;
      advice = '';
    });
    try {
      if (!await AiText.available()) throw 'Il faut une IA : ta clé Gemini gratuite ou Claude (Réglages de Nexo).';
      final e = MockExam.parse(
        await AiText.ask(MockExam.prompt(widget.subject, widget.material), system: MockExam.system),
      );
      if (e == null) throw 'L\'IA n\'a pas réussi à faire le sujet : réessaie.';
      if (!mounted) return;
      for (final f in _fields) {
        f.dispose();
      }
      setState(() {
        exam = e;
        answers = List.filled(e.questions.length, '');
        _fields = [for (final _ in e.questions) TextEditingController()];
        started = DateTime.now();
      });
      // L'horloge du contrôle (seulement pendant le contrôle).
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || marks != null || grading) return;
        if (_left <= Duration.zero) {
          unawaited(_submit());
        } else {
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Duration get _left {
    final e = exam, s = started;
    if (e == null || s == null) return Duration.zero;
    return Duration(minutes: e.minutes) - DateTime.now().difference(s);
  }

  Future<void> _submit() async {
    final e = exam;
    if (e == null || grading || marks != null) return;
    _clock?.cancel();
    setState(() => grading = true);
    String? graded;
    if (e.questions.any((q) => !q.isChoice)) {
      try {
        graded = await AiText.ask(e.gradePrompt(answers), system: MockExam.system);
      } catch (_) {}
    }
    final (m, a) = e.mark(answers, graded);
    if (!mounted) return;
    setState(() {
      grading = false;
      marks = m;
      advice = a;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = exam;
    final left = _left;
    return Scaffold(
      appBar: AppBar(
        title: Text(e?.title ?? 'Contrôle blanc · ${widget.subject}'),
        actions: [
          if (e != null && marks == null && !grading)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '⏱ ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: left.inMinutes < 3 ? Colors.red : null,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: error != null
              ? EmptyHint(error!, icon: Icons.error_outline_rounded, action: ('Réessayer', _make))
              : e == null
              ? const _Preparing()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                  children: [
                    if (marks != null) _result(theme, e),
                    for (var i = 0; i < e.questions.length; i++) _question(theme, e, i),
                    const SizedBox(height: 16),
                    if (marks == null)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: widget.color,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: grading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.assignment_turned_in_rounded),
                        label: Text(grading ? 'Correction en cours…' : 'Rendre ma copie'),
                        onPressed: grading ? null : _submit,
                      )
                    else
                      OutlinedButton.icon(
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Un autre sujet'),
                        onPressed: _make,
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _result(ThemeData theme, MockExam e) {
    final m = marks!;
    final note = MockExam.on20(m);
    String fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1).replaceAll('.', ',');
    return Card(
      color: widget.color.withValues(alpha: 0.08),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${fmt(note)}/20',
              style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: widget.color),
            ),
            Text(
              note >= 16
                  ? 'Excellent, tu es prêt·e 🎉'
                  : note >= 12
                  ? 'Bien ! Revois juste les points ci-dessous.'
                  : note >= 8
                  ? 'Pas mal, mais il reste des choses à revoir.'
                  : 'Courage : revois le cours, puis refais un sujet.',
              style: theme.textTheme.titleMedium,
            ),
            if (advice.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              FicheView(markdown: advice, color: widget.color),
            ],
          ],
        ),
      ),
    );
  }

  Widget _question(ThemeData theme, MockExam e, int i) {
    final q = e.questions[i];
    final mk = marks?[i];
    final done = marks != null;
    String fmt(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1).replaceAll('.', ',');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${q.text}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  mk == null ? '${fmt(q.points)} pt${q.points > 1 ? 's' : ''}' : '${fmt(mk.got)}/${fmt(mk.max)}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: mk == null
                        ? null
                        : (mk.got >= mk.max ? Colors.green : (mk.got == 0 ? Colors.red : Colors.orange)),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (q.isChoice)
              RadioGroup<String>(
                groupValue: answers[i],
                onChanged: (v) {
                  if (!done && v != null) setState(() => answers[i] = v);
                },
                child: Column(
                  children: [
                    for (var k = 0; k < q.choices.length; k++)
                      RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: '$k',
                        enabled: !done,
                        title: Text(
                          q.choices[k],
                          style: TextStyle(
                            color: done && k == q.answer ? Colors.green : null,
                            fontWeight: done && k == q.answer ? FontWeight.w700 : null,
                          ),
                        ),
                      ),
                  ],
                ),
              )
            else
              TextField(
                enabled: !done,
                minLines: 3,
                maxLines: 12,
                onChanged: (v) => answers[i] = v,
                controller: _fields[i],
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Ta réponse…'),
              ),
            if (mk != null) ...[
              const SizedBox(height: 8),
              Text(mk.comment, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Preparing extends StatelessWidget {
  const _Preparing();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
      SizedBox(height: 14),
      Text('Je prépare ton sujet…'),
    ],
  );
}
