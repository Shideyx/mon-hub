import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../core/ai_text.dart';
import '../../core/claude_api.dart';
import '../../core/browser.dart';
import '../../core/error_log.dart';
import '../../core/hub_files.dart';
import '../../modules/docs/docs_module.dart';
import 'whisper.dart';

/// Un cours écouté par Smily : la transcription, puis le compte rendu.
class CourseNote {
  CourseNote({
    required this.id,
    required this.subject,
    required this.start,
    this.end,
    this.parts = const [],
    this.summary = '',
    this.gaps = 0,
    this.docId,
  });

  final String id;
  String subject;
  final DateTime start;
  DateTime? end;

  /// La transcription, morceau par morceau (4 minutes chacun).
  List<String> parts;

  /// Le compte rendu (Markdown), vide tant qu'il n'est pas fait.
  String summary;

  /// Morceaux qui n'ont pas pu être transcrits.
  int gaps;

  /// Le Google Doc où les notes s'écrivent en direct (s'il y en a un).
  String? docId;

  String get transcript => parts.where((p) => p.trim().isNotEmpty).join('\n\n');
  bool get done => summary.trim().isNotEmpty;

  /// Durée (un cours interrompu — Mon Hub fermé — compte ses morceaux).
  Duration get length =>
      (end ?? (parts.isEmpty ? DateTime.now() : start.add(CourseListener.segment * parts.length))).difference(start);
  String get title => subject.trim().isEmpty ? 'Cours' : subject.trim();

  Map<String, dynamic> toJson() => {
    'id': id,
    'matiere': subject,
    'debut': start.millisecondsSinceEpoch,
    'fin': end?.millisecondsSinceEpoch,
    'morceaux': parts,
    'compte_rendu': summary,
    'trous': gaps,
    'doc': ?docId,
  };

  factory CourseNote.fromJson(Map j) => CourseNote(
    id: '${j['id']}',
    subject: '${j['matiere'] ?? ''}',
    start: DateTime.fromMillisecondsSinceEpoch((j['debut'] as num?)?.toInt() ?? 0),
    end: j['fin'] is num ? DateTime.fromMillisecondsSinceEpoch((j['fin'] as num).toInt()) : null,
    parts: [for (final p in (j['morceaux'] is List ? j['morceaux'] as List : const [])) '$p'],
    summary: '${j['compte_rendu'] ?? ''}',
    gaps: (j['trous'] as num?)?.toInt() ?? 0,
    docId: j['doc'] as String?,
  );
}

/// Smily **écoute un cours en entier** puis en fait un compte rendu.
///
/// Le micro enregistre par morceaux de 4 minutes ; chaque morceau est
/// transcrit pendant que le cours continue (Whisper sur le PC s'il est
/// installé — rien ne sort du PC —, sinon Gemini avec ta clé gratuite). Le
/// texte est gardé au fur et à mesure (chiffré, sur l'appareil) : si Mon Hub
/// se ferme, rien n'est perdu. À la fin, l'IA rédige le compte rendu (idées
/// principales, définitions, dates, ce qu'il faut retenir, questions
/// possibles).
class CourseListener extends ChangeNotifier {
  CourseListener._();
  static final instance = CourseListener._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Longueur d'un morceau (un WAV de 4 min fait ~7,7 Mo : accepté par Gemini).
  static const segment = Duration(minutes: 4);

  /// Au-delà, on s'arrête tout seul (on a oublié d'arrêter).
  static const maxLength = Duration(hours: 4);

  final notes = JsonFile<List<CourseNote>>(
    'comptes-rendus.json',
    empty: () => [],
    decode: (j) => [
      for (final e in (j is List ? j : const []))
        if (e is Map) CourseNote.fromJson(e),
    ],
    encode: (v) => [for (final n in v) n.toJson()],
  );

  AudioRecorder? _rec;
  StreamSubscription<Amplitude>? _amp;
  Timer? _cut;
  Timer? _clock;
  Directory? _dir;
  String? _wav;
  int _index = 0;
  double _loudest = -160;

  /// Le cours en train d'être écouté.
  CourseNote? current;
  bool get recording => current != null && _rec != null;

  /// Arrêt automatique (fin du cours d'après l'emploi du temps).
  DateTime? until;

  /// Volume du micro (0 à 1), pour l'affichage.
  double level = 0;

  /// Morceaux en attente de transcription.
  int pending = 0;

  /// Le compte rendu est en cours de rédaction.
  bool summarizing = false;
  String? problem;

  Future<void>? _queue;

  /// Passage d'un morceau au suivant (l'arrêt l'attend : rien n'est perdu).
  Future<void>? _rotation;
  bool _stopping = false;

  Duration get elapsed => current == null ? Duration.zero : DateTime.now().difference(current!.start);

  Future<List<CourseNote>> list() async {
    final l = await notes.load();
    return [...l]..sort((a, b) => b.start.compareTo(a.start));
  }

  /// Comment le texte sera obtenu (ou pourquoi c'est impossible).
  static Future<String?> engine() async {
    if (await Whisper.ready) return 'whisper';
    final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    return key.isEmpty ? null : 'gemini';
  }

  static const noEngine =
      'Pour écouter un cours, il me faut Whisper (sur ton PC, gratuit, rien ne sort : Réglages de Smily → '
      'Écoute → Installer Whisper) ou ta clé Gemini gratuite (Réglages de Smily → Voix).';

  /// Commence l'écoute. Renvoie un message d'erreur, ou null si c'est parti.
  /// [liveDoc] : les notes s'écrivent en direct dans un nouveau Google Doc
  /// (ouvert à l'écran), pendant que le cours continue.
  Future<String?> start({String subject = '', DateTime? stopAt, bool liveDoc = false}) async {
    if (!supported) return 'L\'écoute d\'un cours marche sur le PC (Windows).';
    if (recording) return null;
    if (await engine() == null) return noEngine;
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        await rec.dispose();
        return 'Windows empêche Mon Hub d\'utiliser le micro (Paramètres → Confidentialité → Microphone).';
      }
    } catch (e) {
      await rec.dispose();
      return 'Micro indisponible ($e)';
    }
    _rec = rec;
    _dir = await Directory.systemTemp.createTemp('clicky-cours');
    _index = 0;
    problem = null;
    until = stopAt;
    final now = DateTime.now();
    current = CourseNote(id: '${now.millisecondsSinceEpoch}', subject: subject, start: now, parts: []);
    await _put(current!);
    if (liveDoc && GoogleDocs.connected) unawaited(_openLiveDoc(current!));
    final err = await _startSegment();
    if (err != null) {
      await _cleanup();
      final c = current;
      current = null;
      if (c != null) await notes.update((l) => l..removeWhere((n) => n.id == c.id));
      notifyListeners();
      return err;
    }
    _amp = rec.onAmplitudeChanged(const Duration(milliseconds: 250)).listen((a) {
      level = ((a.current + 55) / 45).clamp(0.0, 1.0);
      if (a.current > _loudest) _loudest = a.current;
      notifyListeners();
    });
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      final u = until;
      if ((u != null && DateTime.now().isAfter(u)) || elapsed > maxLength) unawaited(stop());
    });
    notifyListeners();
    return null;
  }

  Future<String?> _startSegment() async {
    final rec = _rec;
    final dir = _dir;
    if (rec == null || dir == null) return 'Micro fermé';
    _index++;
    _wav = '${dir.path}${Platform.pathSeparator}morceau-$_index.wav';
    _loudest = -160;
    try {
      await rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: _wav!);
    } catch (e) {
      return 'Je n\'arrive pas à ouvrir le micro ($e)';
    }
    _cut?.cancel();
    _cut = Timer(segment, () => _rotation = _nextSegment());
    return null;
  }

  /// Fin d'un morceau : on enchaîne tout de suite sur le suivant et on
  /// transcrit celui-ci pendant ce temps.
  Future<void> _nextSegment() async {
    final rec = _rec;
    if (rec == null || _stopping) return;
    final loud = _loudest;
    String? path;
    try {
      path = await rec.stop();
    } catch (_) {}
    path ??= _wav;
    final err = await _startSegment();
    if (err != null) {
      problem = err;
      notifyListeners();
    }
    if (path != null) _enqueue(path, silent: loud < -50);
  }

  void _enqueue(String path, {required bool silent}) {
    final note = current;
    if (note == null) return;
    final slot = note.parts.length;
    note.parts = [...note.parts, ''];
    pending++;
    notifyListeners();
    final previous = _queue ?? Future<void>.value();
    _queue = previous.then((_) => _transcribe(note, slot, path, silent: silent));
  }

  Future<void> _transcribe(CourseNote note, int slot, String path, {required bool silent}) async {
    try {
      if (!silent && await File(path).exists()) {
        final text = await toText(path);
        note.parts = [...note.parts]..[slot] = text;
        // Notes en direct : ce morceau, mis au propre, dans le Google Doc.
        if (note.docId != null && text.trim().length > 40) await _writeLive(note, text);
      }
    } catch (e) {
      note.gaps++;
      problem = 'Un morceau n\'a pas pu être transcrit ($e)';
      ErrorLog.record(e, null, where: 'Écoute de cours');
    } finally {
      pending--;
      try {
        await File(path).delete();
      } catch (_) {}
      // Gardé au fur et à mesure : rien n'est perdu si Mon Hub se ferme.
      await _put(note);
      notifyListeners();
    }
  }

  static Future<String> toText(String wav) async {
    final how = await engine();
    if (how == 'whisper') {
      try {
        return await Whisper.transcribe(wav, timeout: const Duration(minutes: 8));
      } catch (_) {
        final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
        if (key.isEmpty) rethrow;
      }
    }
    final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    if (key.isEmpty) throw noEngine;
    return GeminiTranscriber.transcribe(wav, key, timeout: const Duration(minutes: 3));
  }

  /// Arrête l'écoute, finit de transcrire, puis rédige le compte rendu.
  Future<CourseNote?> stop() async {
    if (current == null || _rec == null || _stopping) return null;
    _stopping = true;
    _cut?.cancel();
    _clock?.cancel();
    await _rotation;
    final note = current;
    final rec = _rec;
    if (note == null || rec == null) {
      _stopping = false;
      return null;
    }
    await _amp?.cancel();
    _amp = null;
    final loud = _loudest;
    String? path;
    try {
      path = await rec.stop();
    } catch (_) {}
    path ??= _wav;
    _rec = null;
    try {
      await rec.dispose();
    } catch (_) {}
    level = 0;
    note.end = DateTime.now();
    if (path != null) _enqueue(path, silent: loud < -50);
    notifyListeners();
    await _queue;
    await _cleanup();
    current = null;
    _stopping = false;
    await _put(note);
    notifyListeners();
    await summarize(note);
    // Le compte rendu complet à la fin du Google Doc.
    final doc = note.docId;
    if (doc != null && note.done) {
      try {
        await GoogleDocs.append(doc, '\n━━━━━━━━━━  COMPTE RENDU  ━━━━━━━━━━\n\n${note.summary}');
      } catch (e) {
        ErrorLog.record(e, null, where: 'Notes en direct');
      }
    }
    return note;
  }

  /// Crée le Google Doc des notes et l'ouvre à l'écran (dans sa fenêtre).
  Future<void> _openLiveDoc(CourseNote note) async {
    try {
      final d = note.start;
      final title = 'Notes — ${note.title} — ${d.day}/${d.month}/${d.year}';
      final id = await GoogleDocs.create(
        title,
        '# ${note.title} — ${d.day}/${d.month}/${d.year}\n\n*Notes prises en direct par Smily pendant le cours.*\n',
      );
      note.docId = id;
      await _put(note);
      notifyListeners();
      if (!await Browser.openAppWindow(GoogleDocs.edit(id))) await Browser.open(GoogleDocs.edit(id));
    } catch (e) {
      problem = 'Le Google Doc des notes n\'a pas pu être créé ($e). J\'écoute quand même le cours.';
      notifyListeners();
    }
  }

  static String livePrompt(String subject, String part) =>
      'Voici la transcription automatique de quelques minutes d\'un cours${subject.isEmpty ? '' : ' de $subject'} '
      '(lycée). Transforme-la en notes de cours propres, comme un très bon élève, en texte simple (pas de Markdown) :\n'
      '- une ligne en MAJUSCULES quand un nouveau thème commence ;\n'
      '- des lignes qui commencent par « • » pour les idées, courtes ;\n'
      '- « Définition : » pour les définitions, « À retenir : » pour ce que le prof souligne ;\n'
      '- les dates, chiffres, formules et exemples importants.\n'
      'Ignore les bavardages, la discipline et les erreurs de transcription. N\'invente rien. S\'il n\'y a rien '
      'du cours dans cet extrait, réponds juste « - ».\n\n---\n$part';

  Future<void> _writeLive(CourseNote note, String part) async {
    final doc = note.docId;
    if (doc == null) return;
    try {
      final notes = (await AiText.ask(livePrompt(note.subject, part))).trim();
      if (notes.isEmpty || notes == '-' || notes == '« - »') return;
      await GoogleDocs.append(doc, '\n$notes');
    } catch (e) {
      ErrorLog.record(e, null, where: 'Notes en direct');
    }
  }

  /// Abandonne l'écoute (rien n'est gardé).
  Future<void> discard() async {
    _cut?.cancel();
    _clock?.cancel();
    await _rotation;
    final note = current;
    await _amp?.cancel();
    _amp = null;
    try {
      await _rec?.cancel();
      await _rec?.dispose();
    } catch (_) {}
    _rec = null;
    await _cleanup();
    current = null;
    level = 0;
    if (note != null) await notes.update((l) => l..removeWhere((n) => n.id == note.id));
    notifyListeners();
  }

  Future<void> _cleanup() async {
    final d = _dir;
    _dir = null;
    if (d == null) return;
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Enregistre ce compte rendu (par son id : le fichier a pu être relu
  /// entre-temps, par la synchro du compte par exemple).
  Future<void> _put(CourseNote note) => notes.update((l) => [...l.where((n) => n.id != note.id), note]);

  Future<void> delete(CourseNote note) async {
    await notes.update((l) => l..removeWhere((n) => n.id == note.id));
    notifyListeners();
  }

  Future<void> rename(CourseNote note, String subject) async {
    note.subject = subject.trim();
    await _put(note);
    notifyListeners();
  }

  static String prompt(CourseNote n) {
    final t = n.transcript;
    final cut = t.length > 120000 ? '${t.substring(0, 120000)}\n[…]' : t;
    final mins = n.length.inMinutes;
    return 'Voici la transcription automatique d\'un cours${n.subject.isEmpty ? '' : ' de ${n.subject}'} '
        '($mins min, au lycée). Elle peut contenir des erreurs de transcription et des bavardages : ignore-les.\n\n'
        'Rédige un **compte rendu** clair, en Markdown, en français :\n'
        '# Titre du cours (le thème)\n'
        '## L\'essentiel en 3 lignes\n'
        '## Le cours (les idées principales, dans l\'ordre, avec des sous-titres)\n'
        '## Définitions et mots-clés\n'
        '## Dates, chiffres, formules, exemples (seulement s\'il y en a)\n'
        '## À retenir pour le contrôle\n'
        '## Questions pour vérifier que j\'ai compris (5, avec la réponse)\n'
        '## Devoirs ou consignes donnés par le prof (seulement s\'il y en a)\n\n'
        'N\'invente rien qui ne soit pas dans la transcription.\n\n---\n$cut';
  }

  /// Rédige (ou refait) le compte rendu.
  Future<void> summarize(CourseNote note) async {
    if (note.transcript.trim().isEmpty) {
      problem = 'Je n\'ai rien entendu de clair : pas de compte rendu.';
      notifyListeners();
      return;
    }
    summarizing = true;
    problem = null;
    notifyListeners();
    try {
      note.summary = await AiText.ask(
        prompt(note),
        system: 'Tu es Smily, un assistant qui aide un lycéen à réviser. Réponds en français.',
      );
      await _put(note);
    } catch (e) {
      problem = 'Le compte rendu n\'a pas pu être rédigé ($e). La transcription est gardée : réessaie plus tard.';
    } finally {
      summarizing = false;
      notifyListeners();
    }
  }
}
