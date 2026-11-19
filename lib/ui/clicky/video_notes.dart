import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../core/claude_api.dart';
import '../../core/nav.dart';
import '../../modules/youtube/youtube_module.dart' show YouTubeModule, YouTubeMiniPlayer;
import 'clicky.dart';

/// Un chapitre de la vidéo.
class VideoChapter {
  const VideoChapter(this.seconds, this.title, this.points);
  final int seconds;
  final String title;
  final List<String> points;
}

/// Une question du quiz.
class QuizQuestion {
  const QuizQuestion(this.question, this.choices, this.answer, this.why);
  final String question;
  final List<String> choices;
  final int answer;
  final String why;
}

/// La fiche d'une vidéo de cours.
class VideoSheet {
  const VideoSheet({this.title = '', this.summary = '', this.chapters = const [], this.keyPoints = const [], this.quiz = const []});
  final String title;
  final String summary;
  final List<VideoChapter> chapters;
  final List<String> keyPoints;
  final List<QuizQuestion> quiz;

  /// En Markdown (pour le Google Doc ou les cartes de révision).
  String markdown(String url) => [
    '# ${title.isEmpty ? 'Fiche vidéo' : title}',
    url,
    '',
    '## Résumé',
    summary,
    '',
    '## Chapitres',
    for (final c in chapters) ...['### ${VideoNotes.clock(c.seconds)} — ${c.title}', for (final p in c.points) '- $p'],
    '',
    '## À retenir',
    for (final k in keyPoints) '- $k',
  ].join('\n');
}

/// **Vidéo de cours → fiche** : résumé, chapitres cliquables (on saute au
/// bon moment) et quiz. Gemini regarde la vidéo lui-même (vidéos publiques) ;
/// sinon on lit les sous-titres et le cerveau de Clicky résume.
class VideoNotes {
  VideoNotes._();

  /// L'identifiant d'une vidéo (lien youtube.com, youtu.be, shorts…).
  static String? videoId(String input) {
    final t = input.trim();
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(t)) return t;
    final m = RegExp(r'(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})').firstMatch(t);
    return m?[1];
  }

  static String clock(int s) => s >= 3600
      ? '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'
      : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  /// « 12:34 », « 1:02:03 » ou un nombre de secondes.
  static int seconds(Object? v) {
    if (v is num) return v.toInt().clamp(0, 36000);
    final parts = '$v'.trim().split(':').map((p) => int.tryParse(p.trim()) ?? 0).toList();
    var s = 0;
    for (final p in parts) {
      s = s * 60 + p;
    }
    return s.clamp(0, 36000);
  }

  static const prompt =
      'Tu es un professeur qui prépare une fiche de révision à partir de cette vidéo de cours, pour un lycéen.\n'
      'Réponds UNIQUEMENT avec un objet JSON, en français :\n'
      '{"titre": "…", "resume": "6 à 10 phrases claires", "chapitres": [{"debut": "mm:ss", "titre": "…", '
      '"points": ["idée clé", "…"]}], "a_retenir": ["définitions, dates, formules, chiffres importants"], '
      '"quiz": [{"question": "…", "choix": ["A", "B", "C", "D"], "bonne": index de 0 à 3, "explication": "…"}]}\n'
      'Les chapitres suivent la vidéo dans l\'ordre, avec le vrai moment où chacun commence. 6 à 10 questions de quiz.';

  static VideoSheet? parse(String answer) {
    final a = answer.indexOf('{');
    final b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Map? d;
    try {
      final j = jsonDecode(answer.substring(a, b + 1));
      if (j is Map) d = j;
    } catch (_) {}
    if (d == null) return null;
    List<String> strs(Object? v, [int max = 12]) =>
        [for (final e in (v is List ? v : const [])) if ('$e'.trim().isNotEmpty) '$e'.trim()].take(max).toList();
    final chapters = <VideoChapter>[
      for (final c in (d['chapitres'] is List ? d['chapitres'] as List : const []))
        if (c is Map && '${c['titre'] ?? ''}'.trim().isNotEmpty) VideoChapter(seconds(c['debut']), '${c['titre']}'.trim(), strs(c['points'], 6)),
    ]..sort((x, y) => x.seconds.compareTo(y.seconds));
    final quiz = <QuizQuestion>[
      for (final q in (d['quiz'] is List ? d['quiz'] as List : const []))
        if (q is Map && q['choix'] is List && (q['choix'] as List).length >= 2 && q['bonne'] is num)
          if ((q['bonne'] as num).toInt() case final i when i >= 0 && i < (q['choix'] as List).length)
            QuizQuestion('${q['question'] ?? ''}'.trim(), strs(q['choix'], 5), i, '${q['explication'] ?? ''}'.trim()),
    ];
    final sheet = VideoSheet(
      title: '${d['titre'] ?? ''}'.trim(),
      summary: '${d['resume'] ?? ''}'.trim(),
      chapters: chapters.take(20).toList(),
      keyPoints: strs(d['a_retenir'], 15),
      quiz: quiz.take(12).toList(),
    );
    return sheet.summary.isEmpty && sheet.chapters.isEmpty ? null : sheet;
  }

  /// Gemini regarde la vidéo (lien YouTube public).
  static Future<String> _gemini(String id, String key, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      Object? last;
      for (final model in const ['gemini-2.5-flash', 'gemini-flash-latest']) {
        final r = await c
            .post(
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
              headers: {'content-type': 'application/json', 'x-goog-api-key': key},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {
                        'file_data': {'file_uri': 'https://www.youtube.com/watch?v=$id'},
                      },
                      {'text': prompt},
                    ],
                  },
                ],
              }),
            )
            .timeout(const Duration(minutes: 4));
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

  /// Les sous-titres de la vidéo (texte avec les minutes), si YouTube les donne.
  static Future<String?> captions(String id, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final page = await c
          .get(
            Uri.parse('https://www.youtube.com/watch?v=$id&hl=fr'),
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36',
              'Accept-Language': 'fr-FR,fr;q=0.9',
              'Cookie': 'SOCS=CAI',
            },
          )
          .timeout(const Duration(seconds: 20));
      final m = RegExp(r'"captionTracks":(\[.*?\])').firstMatch(page.body);
      if (m == null) return null;
      final tracks = jsonDecode(m[1]!) as List;
      Map? pick(bool Function(Map) ok) => tracks.whereType<Map>().where(ok).firstOrNull;
      final t = pick((t) => '${t['languageCode']}'.startsWith('fr') && t['kind'] != 'asr') ??
          pick((t) => '${t['languageCode']}'.startsWith('fr')) ??
          pick((t) => true);
      if (t == null) return null;
      final url = '${t['baseUrl']}'.replaceAll(r'&', '&');
      final r = await c.get(Uri.parse('$url&fmt=json3')).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.body.isEmpty) return null;
      final b = StringBuffer();
      var lastMinute = -1;
      for (final e in ((jsonDecode(r.body) as Map)['events'] as List?) ?? const []) {
        if (e is! Map || e['segs'] is! List) continue;
        final ms = (e['tStartMs'] as num?)?.toInt() ?? 0;
        final minute = ms ~/ 60000;
        if (minute != lastMinute) {
          b.write('\n[${clock(ms ~/ 1000)}] ');
          lastMinute = minute;
        }
        for (final s in e['segs'] as List) {
          if (s is Map) b.write('${s['utf8'] ?? ''}'.replaceAll('\n', ' '));
        }
      }
      final text = b.toString().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<VideoSheet> make(String id) async {
    final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    if (key.isNotEmpty) {
      try {
        final s = parse(await _gemini(id, key));
        if (s != null) return s;
      } catch (_) {}
    }
    final subs = await captions(id);
    if (subs == null) {
      throw key.isEmpty
          ? 'Cette vidéo n\'a pas de sous-titres que je peux lire. Avec ta clé Gemini gratuite (Réglages de Clicky → Voix), '
              'je regarde la vidéo moi-même.'
          : 'Je n\'arrive pas à lire cette vidéo (privée, trop longue ou sans sous-titres).';
    }
    final text = subs.length > 120000 ? subs.substring(0, 120000) : subs;
    final s = parse(await AiText.ask('$prompt\n\nSous-titres de la vidéo (avec les minutes) :\n$text'));
    if (s == null) throw 'Je n\'ai pas réussi à faire la fiche.';
    return s;
  }
}

/// La page : coller un lien, puis la fiche.
class VideoNotesPage extends StatefulWidget {
  const VideoNotesPage({super.key, this.url});
  final String? url;

  static Future<void> open({String? url}) async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(builder: (_) => VideoNotesPage(url: url)));
  }

  @override
  State<VideoNotesPage> createState() => _VideoNotesPageState();
}

class _VideoNotesPageState extends State<VideoNotesPage> {
  late final _link = TextEditingController(text: widget.url ?? '');
  VideoSheet? _sheet;
  String? _id;
  String? _error;
  bool _busy = false;
  final _picked = <int, int>{};

  @override
  void initState() {
    super.initState();
    if (widget.url != null) unawaited(_go());
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final id = VideoNotes.videoId(_link.text);
    if (id == null) {
      setState(() => _error = 'Colle le lien d\'une vidéo YouTube.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _sheet = null;
      _id = id;
      _picked.clear();
    });
    try {
      final s = await VideoNotes.make(id);
      if (mounted) setState(() => _sheet = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _jump(int seconds) async {
    final id = _id;
    if (id == null) return;
    final yt = ClickyController.instance.hub?.available.whereType<YouTubeModule>().firstOrNull;
    if (yt == null) return;
    await yt.open(context, YouTubeMiniPlayer.watchUrl(id, seconds));
  }

  Future<void> _tool(String name, Map<String, dynamic> args, String done) async {
    try {
      final t = ClickyController.instance.hubTools.where((t) => t.name == name).firstOrNull;
      if (t == null) throw 'Active le module concerné (Réglages → Modules)';
      await t.run(args);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sheet;
    final url = _id == null ? '' : 'https://www.youtube.com/watch?v=$_id';
    return Scaffold(
      appBar: AppBar(title: const Text('Vidéo → fiche')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _link,
                      decoration: const InputDecoration(hintText: 'Lien de la vidéo YouTube', prefixIcon: Icon(Icons.smart_display_rounded)),
                      onSubmitted: (_) => _go(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _busy ? null : _go, child: const Text('Faire la fiche')),
                ],
              ),
              if (_busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Je regarde la vidéo et je prends des notes… ⏳'))),
              if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
              if (s != null) ...[
                const SizedBox(height: 12),
                Text(s.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(s.summary),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _tool('doc_creer', {'titre': 'Fiche — ${s.title}', 'contenu': s.markdown(url)}, 'Google Doc créé ✓'),
                      icon: const Icon(Icons.description_rounded),
                      label: const Text('En faire un Google Doc'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _tool('revision_generer', {'paquet': '🎬 ${s.title}', 'texte': s.markdown(url), 'nombre': 15}, 'Cartes ajoutées dans Révisions ✓'),
                      icon: const Icon(Icons.style_rounded),
                      label: const Text('Faire des cartes'),
                    ),
                  ],
                ),
                if (s.chapters.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Chapitres', style: theme.textTheme.titleMedium),
                  for (final c in s.chapters)
                    Card(
                      child: ListTile(
                        leading: ActionChip(label: Text(VideoNotes.clock(c.seconds)), onPressed: () => _jump(c.seconds)),
                        title: Text(c.title),
                        subtitle: c.points.isEmpty ? null : Text(c.points.map((p) => '• $p').join('\n')),
                        onTap: () => _jump(c.seconds),
                      ),
                    ),
                ],
                if (s.keyPoints.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('À retenir', style: theme.textTheme.titleMedium),
                  for (final k in s.keyPoints) Text('• $k'),
                ],
                if (s.quiz.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Quiz (${_picked.length}/${s.quiz.length})', style: theme.textTheme.titleMedium),
                  for (var i = 0; i < s.quiz.length; i++)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${i + 1}. ${s.quiz[i].question}', style: theme.textTheme.titleSmall),
                            const SizedBox(height: 6),
                            for (var j = 0; j < s.quiz[i].choices.length; j++)
                              ListTile(
                                dense: true,
                                leading: Icon(
                                  !_picked.containsKey(i)
                                      ? Icons.radio_button_unchecked_rounded
                                      : j == s.quiz[i].answer
                                      ? Icons.check_circle_rounded
                                      : (j == _picked[i] ? Icons.cancel_rounded : Icons.radio_button_unchecked_rounded),
                                  color: !_picked.containsKey(i)
                                      ? null
                                      : j == s.quiz[i].answer
                                      ? Colors.green
                                      : (j == _picked[i] ? Colors.red : null),
                                ),
                                title: Text(
                                  s.quiz[i].choices[j],
                                  style: TextStyle(
                                    fontWeight: _picked.containsKey(i) && j == s.quiz[i].answer ? FontWeight.w700 : null,
                                  ),
                                ),
                                onTap: _picked.containsKey(i) ? null : () => setState(() => _picked[i] = j),
                              ),
                            if (_picked.containsKey(i) && s.quiz[i].why.isNotEmpty)
                              Text(
                                '${_picked[i] == s.quiz[i].answer ? '✅' : '❌'} ${s.quiz[i].why}',
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_picked.length == s.quiz.length)
                    Text(
                      'Score : ${[for (final e in _picked.entries) if (e.value == s.quiz[e.key].answer) 1].length} / ${s.quiz.length}',
                      style: theme.textTheme.titleLarge,
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
