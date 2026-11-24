import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/nav.dart';
import '../../modules/docs/docs_module.dart';
import '../../modules/revisions/fiche_view.dart';
import '../widgets.dart';
import 'clicky.dart';
import 'course_listener.dart';
import 'jarvis_view.dart';

const _red = Color(0xFFE5484D);
const _violet = Color(0xFF7C5CFF);

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Le cours en ce moment (d'après l'agenda : École Directe, Google Agenda…),
/// pour remplir la matière et l'heure de fin toute seules.
Future<(String, DateTime)?> currentLesson() async {
  try {
    final t = ClickyController.instance.hubTools.where((t) => t.name == 'agenda_lire').firstOrNull;
    if (t == null) return null;
    final items = await t.run({'jours': 1});
    final now = DateTime.now();
    for (final e in (items is List ? items : const [])) {
      if (e is! Map || e['annule'] == true) continue;
      final a = e['debut'] is DateTime ? e['debut'] as DateTime : DateTime.tryParse('${e['debut']}');
      final b = e['fin'] is DateTime ? e['fin'] as DateTime : DateTime.tryParse('${e['fin']}');
      if (a == null || b == null) continue;
      // Le cours en cours, ou celui qui commence dans 10 minutes.
      if (!now.isBefore(a.subtract(const Duration(minutes: 10))) && now.isBefore(b)) return ('${e['titre']}', b);
    }
  } catch (_) {}
  return null;
}

/// « Nexo, écoute le cours » : l'écoute en direct, puis les comptes rendus.
class CoursePage extends StatefulWidget {
  const CoursePage({super.key, this.autoStart = false});

  /// Commencer tout de suite (demandé à Nexo).
  final bool autoStart;

  static Future<void> open(BuildContext context, {bool autoStart = false}) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CoursePage(autoStart: autoStart)));

  /// Ouvre la page depuis n'importe où (Nexo, raccourci).
  static Future<void> show({bool autoStart = false}) async {
    final ctx = await hubDialogContext();
    if (ctx != null && ctx.mounted) unawaited(open(ctx, autoStart: autoStart));
  }

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  final l = CourseListener.instance;
  final subject = TextEditingController();
  DateTime? _lessonEnd;
  bool _autoStop = true;

  /// Les notes s'écrivent en direct dans un Google Doc.
  bool _liveDoc = GoogleDocs.connected;
  bool _starting = false;
  late Future<List<CourseNote>> _list = l.list();
  String? _engine;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    l.addListener(_changed);
    unawaited(_prepare());
    // L'horloge de l'écoute (une fois par seconde, seulement pendant l'écoute).
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && l.recording) setState(() {});
    });
  }

  Future<void> _prepare() async {
    final e = await CourseListener.engine();
    final lesson = await currentLesson();
    if (!mounted) return;
    setState(() {
      _engine = e ?? '';
      if (lesson != null && subject.text.isEmpty) {
        subject.text = lesson.$1;
        _lessonEnd = lesson.$2;
      }
    });
    if (widget.autoStart && !l.recording) await _start();
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _list = l.list());
  }

  @override
  void dispose() {
    _tick?.cancel();
    l.removeListener(_changed);
    subject.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    final err = await l.start(subject: subject.text, stopAt: _autoStop ? _lessonEnd : null, liveDoc: _liveDoc);
    if (!mounted) return;
    setState(() => _starting = false);
    if (err != null) showError(context, err);
  }

  Future<void> _stop() async {
    final note = await l.stop();
    if (!mounted || note == null) return;
    if (note.done) unawaited(CourseNotePage.open(context, note));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Écouter un cours')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              if (l.recording) _live(theme) else if (l.summarizing) _writing(theme) else _setup(theme),
              if (l.problem != null) ...[const SizedBox(height: 10), ErrorBanner(l.problem!)],
              const SizedBox(height: 24),
              Text('Mes comptes rendus', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              FutureBuilder(
                future: _list,
                builder: (context, snap) {
                  final notes = (snap.data ?? const <CourseNote>[]).where((n) => n.id != l.current?.id).toList();
                  if (notes.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text('Aucun pour l\'instant.', style: theme.textTheme.bodySmall),
                    );
                  }
                  return Column(
                    children: [
                      for (final n in notes)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: (n.done ? _violet : Colors.orange).withValues(alpha: 0.15),
                              child: Icon(
                                n.done ? Icons.article_rounded : Icons.pending_actions_rounded,
                                color: n.done ? _violet : Colors.orange,
                              ),
                            ),
                            title: Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              '${dayLabel(n.start)} à ${hhmm(n.start)} · ${n.length.inMinutes} min'
                              '${n.done ? '' : ' · compte rendu à faire'}',
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => CourseNotePage.open(context, n),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _setup(ThemeData theme) {
    final noEngine = _engine == '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0x22E5484D),
                  child: Icon(Icons.mic_rounded, color: _red),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nexo écoute tout le cours, puis te fait le compte rendu',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Pose le PC (ou son micro) près du prof et laisse Mon Hub ouvert. Le son est transcrit au fur et à mesure '
              '${_engine == 'whisper' ? 'sur ton PC (Whisper : rien ne sort)' : 'par Gemini (ta clé gratuite)'} puis '
              'effacé ; seul le texte est gardé, chiffré sur ton appareil. Demande d\'abord au prof s\'il est d\'accord.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: subject,
              decoration: const InputDecoration(
                labelText: 'Matière ou thème (facultatif)',
                hintText: 'Histoire, SVT, chapitre 4…',
                border: OutlineInputBorder(),
              ),
            ),
            if (_lessonEnd != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoStop,
                onChanged: (v) => setState(() => _autoStop = v ?? true),
                title: Text('M\'arrêter tout seul à la fin du cours (${hhmm(_lessonEnd!)})'),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _liveDoc && GoogleDocs.connected,
              onChanged: GoogleDocs.connected ? (v) => setState(() => _liveDoc = v ?? true) : null,
              title: const Text('Écrire mes notes en direct dans un Google Doc'),
              subtitle: Text(
                GoogleDocs.connected
                    ? 'Le document s\'ouvre et se remplit pendant le cours : tu peux le lire (ou l\'annoter) en direct.'
                    : 'Connecte ton compte Google (Réglages → Connexion Google) pour ça.',
              ),
            ),
            const SizedBox(height: 10),
            if (noEngine)
              ErrorBanner(CourseListener.noEngine)
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _red, padding: const EdgeInsets.symmetric(vertical: 14)),
                icon: _starting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.fiber_manual_record_rounded),
                label: const Text('Commencer l\'écoute'),
                onPressed: _starting || _engine == null ? null : _start,
              ),
          ],
        ),
      ),
    );
  }

  Widget _live(ThemeData theme) {
    final n = l.current!;
    final last = n.parts.lastWhere((p) => p.trim().isNotEmpty, orElse: () => '');
    return Card(
      color: _red.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(color: _red, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'J\'écoute ${n.subject.isEmpty ? 'le cours' : n.subject}',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  _clock(l.elapsed),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: l.level,
                minHeight: 8,
                color: _red,
                backgroundColor: _red.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (l.until != null) 'Arrêt automatique à ${hhmm(l.until!)}',
                if (l.pending > 0) '${l.pending} morceau${l.pending > 1 ? 'x' : ''} en cours de transcription',
                '${n.parts.where((p) => p.trim().isNotEmpty).length} morceau(x) transcrit(s)',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (n.docId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.description_rounded),
                  label: const Text('Voir mes notes en direct (Google Doc)'),
                  onPressed: () => Browser.openAppWindow(GoogleDocs.edit(n.docId!)),
                ),
              ),
            if (last.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  '« …${last.length > 280 ? last.substring(last.length - 280) : last} »',
                  style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Terminer et faire le compte rendu'),
                    onPressed: _stop,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    final ok = await _confirm(context, 'Abandonner l\'écoute ?', 'Rien ne sera gardé.');
                    if (ok) await l.discard();
                  },
                  child: const Text('Abandonner'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _writing(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l.pending > 0 ? 'Je finis de transcrire la fin du cours…' : 'Je rédige ton compte rendu…',
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Oui')),
        ],
      ),
    ) ==
    true;

/// Un compte rendu : à lire, copier, envoyer sur Google Docs, transformer en
/// cartes de révision.
class CourseNotePage extends StatefulWidget {
  const CourseNotePage({super.key, required this.note});
  final CourseNote note;

  static Future<void> open(BuildContext context, CourseNote note) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CourseNotePage(note: note)));

  @override
  State<CourseNotePage> createState() => _CourseNotePageState();
}

class _CourseNotePageState extends State<CourseNotePage> {
  final l = CourseListener.instance;
  String? _busy;

  CourseNote get n => widget.note;

  @override
  void initState() {
    super.initState();
    l.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    l.removeListener(_changed);
    super.dispose();
  }

  Future<void> _tool(String id, String name, Map<String, dynamic> args, String done) async {
    setState(() => _busy = id);
    try {
      final t = ClickyController.instance.hubTools.where((t) => t.name == name).firstOrNull;
      if (t == null) throw 'Active le module concerné (Réglages → Modules)';
      await t.run(args);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String get _docTitle => 'Compte rendu — ${n.title} — ${n.start.day}/${n.start.month}';

  Widget _busyIcon(String id, IconData icon) => _busy == id
      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
      : Icon(icon);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = n.done ? n.summary : n.transcript;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(n.title),
          actions: [
            IconButton(
              tooltip: 'Copier',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: text)));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copié')));
              },
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'rename') {
                  final c = TextEditingController(text: n.subject);
                  final name = await showDialog<String>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Matière ou thème'),
                      content: TextField(controller: c, autofocus: true),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Annuler')),
                        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('OK')),
                      ],
                    ),
                  );
                  if (name != null) await l.rename(n, name);
                } else if (v == 'redo') {
                  await l.summarize(n);
                } else if (v == 'delete') {
                  if (!context.mounted) return;
                  if (await _confirm(context, 'Supprimer ce compte rendu ?', 'La transcription sera aussi effacée.')) {
                    await l.delete(n);
                    if (context.mounted) Navigator.pop(context);
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                const PopupMenuItem(value: 'redo', child: Text('Refaire le compte rendu')),
                const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Compte rendu'),
              Tab(text: 'Transcription'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (n.done) ...[
                      FilledButton.tonalIcon(
                        icon: _busyIcon('doc', Icons.description_rounded),
                        label: const Text('En faire un Google Doc'),
                        onPressed: _busy != null
                            ? null
                            : () => _tool('doc', 'doc_creer', {
                                'titre': _docTitle,
                                'contenu': n.summary,
                              }, 'Google Doc créé ✓'),
                      ),
                      FilledButton.tonalIcon(
                        icon: _busyIcon('cards', Icons.style_rounded),
                        label: const Text('Faire des cartes de révision'),
                        onPressed: _busy != null
                            ? null
                            : () => _tool('cards', 'revision_generer', {
                                'paquet': '🎧 ${n.title}',
                                'texte': n.summary,
                                'nombre': 15,
                              }, 'Cartes ajoutées dans Révisions ✓'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                if (l.summarizing)
                  const Padding(padding: EdgeInsets.all(24), child: LoadingHint())
                else if (n.done)
                  SelectionArea(
                    child: FicheView(markdown: n.summary, color: _violet),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        n.transcript.trim().isEmpty
                            ? 'Rien n\'a été transcrit pour ce cours.'
                            : 'Le compte rendu n\'est pas encore fait.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 10),
                      if (n.transcript.trim().isNotEmpty)
                        FilledButton.icon(
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: const Text('Faire le compte rendu'),
                          onPressed: () => l.summarize(n),
                        ),
                    ],
                  ),
                if (l.problem != null && !l.recording) ...[const SizedBox(height: 10), ErrorBanner(l.problem!)],
              ],
            ),
            ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              children: [
                Text(
                  '${dayLabel(n.start)} à ${hhmm(n.start)} · ${n.length.inMinutes} min'
                  '${n.gaps > 0 ? ' · ${n.gaps} passage(s) non transcrit(s)' : ''}',
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 12),
                SelectableText(n.transcript.isEmpty ? '(vide)' : n.transcript, style: const TextStyle(height: 1.6)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// La pastille rouge « J'écoute le cours » en haut de Mon Hub, sur toutes
/// les pages, tant que Nexo écoute : on voit qu'on enregistre, et un clic
/// ramène à l'écoute.
class CourseRecLayer extends StatelessWidget {
  const CourseRecLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(key: const ValueKey('course-hub'), child: child),
      Positioned(
        key: const ValueKey('course-pill'),
        top: 6,
        left: 0,
        right: 0,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Une tâche « fais-le à ma place » en cours.
              const TaskPill(),
              // Séance de concentration en cours (à côté de l'écoute de cours).
              const FocusPill(),
              ListenableBuilder(
                listenable: CourseListener.instance,
                builder: (context, _) {
                  final l = CourseListener.instance;
                  if (!l.recording && !l.summarizing) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Material(
                      color: l.recording ? _red : _violet,
                      borderRadius: BorderRadius.circular(20),
                      elevation: 3,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => CoursePage.show(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                l.recording ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l.recording ? 'Nexo écoute le cours' : 'Compte rendu en cours…',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
