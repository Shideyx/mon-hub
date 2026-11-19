import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';

import '../../core/ai_text.dart';
import '../../core/claude_api.dart';
import '../../core/nav.dart';
import 'clicky.dart';
import 'course_listener.dart';

/// Ce que le coach pense d'une répétition.
class OralReport {
  const OralReport({
    this.grade,
    this.summary = '',
    this.transcript = '',
    this.fillers = 0,
    this.fillerWords = const {},
    this.wpm = 0,
    this.pauses = 0,
    this.good = const [],
    this.improve = const [],
    this.missing = const [],
    this.questions = const [],
  });

  final double? grade;
  final String summary;
  final String transcript;
  final int fillers;
  final Map<String, int> fillerWords;
  final int wpm;
  final int pauses;
  final List<String> good;
  final List<String> improve;

  /// Parties du plan oubliées.
  final List<String> missing;

  /// Les questions du jury.
  final List<String> questions;
}

/// **Coach d'oral** (exposés, Grand oral) : chrono, tics de langage, débit,
/// silences, plan respecté, puis le jury pose ses questions.
class OralCoach {
  OralCoach._();

  static const _fillers = ['euh', 'heu', 'hum', 'bah', 'ben', 'du coup', 'en fait', 'genre', 'voila', 'tu vois', 'en gros', 'quoi'];

  static String _fold(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString().replaceAll(RegExp(r"[^a-z0-9' ]+"), ' ').replaceAll("'", ' ');
  }

  /// Les tics de langage d'une transcription (« quoi » seulement en fin de phrase).
  static Map<String, int> fillers(String transcript) {
    final out = <String, int>{};
    final t = ' ${_fold(transcript).replaceAll(RegExp(r'\s+'), ' ')} ';
    for (final f in _fillers) {
      if (f == 'quoi') continue;
      final n = RegExp(' ${RegExp.escape(f)} ').allMatches(t).length;
      if (n > 0) out[f] = n;
    }
    final quoi = RegExp(r'\bquoi\s*[.!,]').allMatches(transcript.toLowerCase()).length;
    if (quoi > 0) out['quoi'] = quoi;
    return out;
  }

  static int words(String transcript) => RegExp(r"[\p{L}\p{N}]+", unicode: true).allMatches(transcript).length;

  /// Mots par minute (un bon oral : 120 à 160).
  static int wpm(String transcript, Duration d) => d.inSeconds < 5 ? 0 : (words(transcript) * 60 / d.inSeconds).round();

  static String paceAdvice(int wpm) => wpm == 0
      ? ''
      : wpm < 110
      ? 'Un peu lent ($wpm mots/min) : tu peux accélérer légèrement.'
      : wpm > 170
      ? 'Trop rapide ($wpm mots/min) : ralentis et respire entre les parties.'
      : 'Bon rythme ($wpm mots/min).';

  static String prompt({required String subject, required String plan, required Duration length, required Duration target, required String transcript}) =>
      'Tu es un jury bienveillant du Grand oral du bac (et un coach d\'oral). Un lycéen vient de répéter sa présentation.\n'
      'Sujet : ${subject.isEmpty ? '(non précisé)' : subject}\n'
      '${plan.trim().isEmpty ? '' : 'Son plan prévu :\n$plan\n'}'
      'Durée : ${length.inMinutes} min ${length.inSeconds % 60} s (visée : ${target.inMinutes} min).\n'
      '${transcript.isEmpty ? 'Écoute l\'enregistrement joint.' : 'Ce qu\'il a dit :\n$transcript'}\n\n'
      'Réponds UNIQUEMENT avec un objet JSON :\n'
      '{"note_sur_20": nombre, "resume": "2 phrases", "transcription": "ce qui a été dit, en gardant les euh/hésitations"'
      '${transcript.isEmpty ? '' : ' (laisse vide)'}, "points_forts": ["…"], "a_ameliorer": ["conseils précis et concrets"], '
      '"oublis_du_plan": ["parties du plan non abordées"], "questions_du_jury": ["5 questions que poserait le jury, de la plus '
      'simple à la plus exigeante"]}\n'
      'Juge : clarté, structure (introduction, problématique, annonce du plan, conclusion), maîtrise du sujet, '
      'vocabulaire, respect du temps, aisance (hésitations, tics). Sois honnête mais encourageant.';

  static OralReport? parse(String answer, {required String transcript, required Duration length, required int pauses}) {
    final a = answer.indexOf('{');
    final b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Map? d;
    try {
      final j = jsonDecode(answer.substring(a, b + 1));
      if (j is Map) d = j;
    } catch (_) {}
    if (d == null) return null;
    List<String> strs(Object? v, [int max = 8]) =>
        [for (final e in (v is List ? v : const [])) if ('$e'.trim().isNotEmpty) '$e'.trim()].take(max).toList();
    final said = transcript.isNotEmpty ? transcript : '${d['transcription'] ?? ''}'.trim();
    final f = fillers(said);
    final g = d['note_sur_20'];
    return OralReport(
      grade: g is num && g >= 0 && g <= 20 ? g.toDouble() : null,
      summary: '${d['resume'] ?? ''}'.trim(),
      transcript: said,
      fillers: f.values.fold(0, (s, n) => s + n),
      fillerWords: f,
      wpm: wpm(said, length),
      pauses: pauses,
      good: strs(d['points_forts']),
      improve: strs(d['a_ameliorer']),
      missing: strs(d['oublis_du_plan']),
      questions: strs(d['questions_du_jury'], 6),
    );
  }

  static Future<String> _geminiKey() async => (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();

  /// Gemini écoute l'enregistrement lui-même (il entend les hésitations).
  static Future<String> listen(String wav, String prompt, String key, {http.Client? client}) async {
    final audio = base64Encode(await File(wav).readAsBytes());
    final c = client ?? http.Client();
    try {
      Object? last;
      for (final model in const ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash']) {
        final r = await c
            .post(
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
              headers: {'content-type': 'application/json', 'x-goog-api-key': key},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {
                        'inline_data': {'mime_type': 'audio/wav', 'data': audio},
                      },
                      {'text': prompt},
                    ],
                  },
                ],
              }),
            )
            .timeout(const Duration(minutes: 3));
        if (r.statusCode == 404) {
          last = 'modèle $model introuvable';
          continue;
        }
        if (r.statusCode != 200) throw 'Gemini : erreur ${r.statusCode}';
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        final parts = ((((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?) ?? const [];
        return [for (final p in parts) if (p is Map && p['text'] != null && p['thought'] != true) '${p['text']}'].join();
      }
      throw last ?? 'Gemini indisponible';
    } finally {
      if (client == null) c.close();
    }
  }

  /// Analyse une répétition : Gemini écoute l'audio (meilleur), sinon
  /// transcription (Whisper) puis le cerveau de Clicky lit le texte.
  static Future<OralReport> analyze({
    required String wav,
    required String subject,
    required String plan,
    required Duration length,
    required Duration target,
    required int pauses,
  }) async {
    final key = await _geminiKey();
    if (key.isNotEmpty && await File(wav).length() < 19 * 1024 * 1024) {
      try {
        final answer = await listen(wav, prompt(subject: subject, plan: plan, length: length, target: target, transcript: ''), key);
        final r = parse(answer, transcript: '', length: length, pauses: pauses);
        if (r != null) return r;
      } catch (_) {}
    }
    final text = await CourseListener.toText(wav);
    final answer = await AiText.ask(
      prompt(subject: subject, plan: plan, length: length, target: target, transcript: text),
      system: 'Tu es un jury d\'oral exigeant et bienveillant. Tu réponds seulement en JSON valide.',
    );
    final r = parse(answer, transcript: text, length: length, pauses: pauses);
    if (r == null) throw 'Je n\'ai pas réussi à analyser la répétition.';
    return r;
  }

  /// L'avis du jury sur une réponse.
  static Future<String> judgeAnswer(String subject, String question, String answer) => AiText.ask(
    'Grand oral, sujet : $subject.\nQuestion du jury : $question\nRéponse du lycéen (à l\'oral) : $answer\n\n'
    'En 3 phrases maximum : ce qui est bien, ce qui manque, et une meilleure réponse possible en une phrase.',
  );
}

/// La page du coach d'oral.
class OralCoachPage extends StatefulWidget {
  const OralCoachPage({super.key});

  static Future<void> open() async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(builder: (_) => const OralCoachPage()));
  }

  @override
  State<OralCoachPage> createState() => _OralCoachPageState();
}

class _OralCoachPageState extends State<OralCoachPage> {
  final _subject = TextEditingController();
  final _plan = TextEditingController();
  int _minutes = 5;
  AudioRecorder? _rec;
  Directory? _dir;
  String? _wav;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  Timer? _clock;
  StreamSubscription<Amplitude>? _amp;
  double _level = 0;
  int _pauses = 0;
  DateTime? _quietSince;
  bool _busy = false;
  String? _error;
  OralReport? _report;
  int _question = -1;
  String? _answerFeedback;

  bool get _recording => _rec != null;

  @override
  void dispose() {
    _clock?.cancel();
    unawaited(_amp?.cancel());
    unawaited(_rec?.dispose());
    _subject.dispose();
    _plan.dispose();
    final d = _dir;
    if (d != null) unawaited(d.delete(recursive: true).catchError((_) => d));
    super.dispose();
  }

  Future<String?> _startRec() async {
    if (!CourseListener.supported) return 'Le coach d\'oral marche sur le PC (Windows).';
    if (await CourseListener.engine() == null) return CourseListener.noEngine;
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        await rec.dispose();
        return 'Windows empêche Mon Hub d\'utiliser le micro (Paramètres → Confidentialité → Microphone).';
      }
      _dir ??= await Directory.systemTemp.createTemp('clicky-oral');
      _wav = '${_dir!.path}${Platform.pathSeparator}oral-${DateTime.now().millisecondsSinceEpoch}.wav';
      await rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: _wav!);
    } catch (e) {
      await rec.dispose();
      return 'Je n\'arrive pas à ouvrir le micro ($e)';
    }
    _rec = rec;
    _startedAt = DateTime.now();
    _elapsed = Duration.zero;
    _pauses = 0;
    _quietSince = null;
    _amp = rec.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((a) {
      final quiet = a.current < -42;
      final now = DateTime.now();
      if (quiet) {
        _quietSince ??= now;
      } else {
        // Un silence de plus de 3 s pendant l'oral.
        if (_quietSince != null && now.difference(_quietSince!) > const Duration(seconds: 3)) _pauses++;
        _quietSince = null;
      }
      if (mounted) setState(() => _level = ((a.current + 55) / 45).clamp(0.0, 1.0));
    });
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _elapsed = DateTime.now().difference(_startedAt!));
    });
    return null;
  }

  Future<String?> _stopRec() async {
    _clock?.cancel();
    await _amp?.cancel();
    _amp = null;
    final rec = _rec;
    _rec = null;
    String? path;
    try {
      path = await rec?.stop();
    } catch (_) {}
    await rec?.dispose();
    return path ?? _wav;
  }

  Future<void> _toggle() async {
    if (_recording) {
      final length = DateTime.now().difference(_startedAt!);
      final path = await _stopRec();
      if (path == null || length.inSeconds < 10) {
        setState(() => _error = 'Trop court : parle au moins 10 secondes.');
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final r = await OralCoach.analyze(
          wav: path,
          subject: _subject.text.trim(),
          plan: _plan.text,
          length: length,
          target: Duration(minutes: _minutes),
          pauses: _pauses,
        );
        if (mounted) setState(() => _report = r);
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final err = await _startRec();
    setState(() {
      _error = err;
      _report = err == null ? null : _report;
      _question = -1;
      _answerFeedback = null;
    });
  }

  Future<void> _ask(int i) async {
    final r = _report;
    if (r == null || i >= r.questions.length) return;
    setState(() {
      _question = i;
      _answerFeedback = null;
    });
    await ClickyController.instance.speak(r.questions[i], force: true);
  }

  Future<void> _answer() async {
    final r = _report;
    if (r == null || _question < 0) return;
    if (!_recording) {
      final err = await _startRec();
      if (err != null) setState(() => _error = err);
      setState(() {});
      return;
    }
    final path = await _stopRec();
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final said = await CourseListener.toText(path);
      final fb = await OralCoach.judgeAnswer(_subject.text.trim(), r.questions[_question], said);
      if (mounted) setState(() => _answerFeedback = '🗣️ « ${said.trim()} »\n\n$fb');
    } catch (e) {
      if (mounted) setState(() => _answerFeedback = 'Je n\'ai pas pu écouter ta réponse ($e).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clockText(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = Duration(minutes: _minutes);
    final over = _elapsed > target;
    final r = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Coach d\'oral')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Ton sujet (ex. « Pourquoi le ciel est bleu ? »)')),
              const SizedBox(height: 8),
              TextField(
                controller: _plan,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'Ton plan (facultatif) : une partie par ligne'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Durée visée :'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _minutes,
                    items: [for (final m in const [2, 3, 5, 8, 10]) DropdownMenuItem(value: m, child: Text('$m min'))],
                    onChanged: _recording ? null : (v) => setState(() => _minutes = v ?? 5),
                  ),
                  const SizedBox(width: 8),
                  Text('(Grand oral : 5 min)', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 16),
              Center(
                child: Column(
                  children: [
                    Text(
                      _clockText(_elapsed),
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: over ? Colors.orange : null,
                      ),
                    ),
                    if (_recording) ...[
                      const SizedBox(height: 6),
                      SizedBox(width: 220, child: LinearProgressIndicator(value: _level, minHeight: 6)),
                      const SizedBox(height: 4),
                      Text(over ? 'Temps dépassé : conclus !' : 'Je t\'écoute… (${_pauses > 0 ? '$_pauses blanc${_pauses > 1 ? 's' : ''}' : 'parle normalement'})'),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                        backgroundColor: _recording && _question < 0 ? Colors.red : null,
                      ),
                      onPressed: _busy || (_recording && _question >= 0) ? null : _toggle,
                      icon: Icon(_recording && _question < 0 ? Icons.stop_rounded : Icons.mic_rounded),
                      label: Text(_recording && _question < 0 ? 'J\'ai fini' : (r == null ? 'Commencer la répétition' : 'Recommencer')),
                    ),
                  ],
                ),
              ),
              if (_busy) const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('Le jury délibère… ⏳'))),
              if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
              if (r != null) ...[
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: CircleAvatar(radius: 26, child: Text(r.grade == null ? '?' : r.grade!.toStringAsFixed(r.grade! % 1 == 0 ? 0 : 1))),
                    title: Text(r.grade == null ? 'Ton bilan' : 'Note estimée : ${r.grade!.toStringAsFixed(1).replaceAll('.0', '')} / 20'),
                    subtitle: Text(r.summary),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(avatar: const Icon(Icons.timer_rounded, size: 18), label: Text('Durée ${_clockText(_elapsed)} / $_minutes min')),
                    Chip(avatar: const Icon(Icons.speed_rounded, size: 18), label: Text(r.wpm == 0 ? 'Débit ?' : '${r.wpm} mots/min')),
                    Chip(
                      avatar: const Icon(Icons.record_voice_over_rounded, size: 18),
                      label: Text('${r.fillers} tic${r.fillers > 1 ? 's' : ''} de langage'),
                    ),
                    Chip(avatar: const Icon(Icons.pause_circle_rounded, size: 18), label: Text('${r.pauses} blanc${r.pauses > 1 ? 's' : ''} > 3 s')),
                  ],
                ),
                if (r.fillerWords.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Tics : ${r.fillerWords.entries.map((e) => '« ${e.key} » ×${e.value}').join(', ')}'),
                  ),
                if (OralCoach.paceAdvice(r.wpm).isNotEmpty) Text(OralCoach.paceAdvice(r.wpm)),
                const SizedBox(height: 10),
                if (r.good.isNotEmpty) Text('👍 Points forts', style: theme.textTheme.titleSmall),
                for (final g in r.good) Text('• $g'),
                if (r.improve.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('🎯 À améliorer', style: theme.textTheme.titleSmall),
                  for (final g in r.improve) Text('• $g'),
                ],
                if (r.missing.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('📋 Oublié dans ton plan', style: theme.textTheme.titleSmall),
                  for (final g in r.missing) Text('• $g'),
                ],
                if (r.questions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('🧑‍⚖️ Les questions du jury', style: theme.textTheme.titleMedium),
                  const Text('Clicky lit la question, tu réponds à voix haute, il te dit ce qu\'il en pense.'),
                  for (var i = 0; i < r.questions.length; i++)
                    Card(
                      color: _question == i ? theme.colorScheme.primaryContainer : null,
                      child: ListTile(
                        title: Text('${i + 1}. ${r.questions[i]}'),
                        trailing: _question == i
                            ? FilledButton.icon(
                                onPressed: _busy ? null : _answer,
                                icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
                                label: Text(_recording ? 'J\'ai répondu' : 'Répondre'),
                              )
                            : TextButton(onPressed: _busy || _recording ? null : () => _ask(i), child: const Text('Poser')),
                      ),
                    ),
                  if (_answerFeedback != null) Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(_answerFeedback!))),
                ],
                if (r.transcript.isNotEmpty)
                  ExpansionTile(
                    title: const Text('Ce que tu as dit'),
                    children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(r.transcript))],
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
