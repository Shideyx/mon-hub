import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../core/google_auth.dart';
import 'google_setup.dart';
import '../core/tidy.dart';
import '../modules/drive/drive_tidy.dart';
import 'widgets.dart';

/// Montre ce qui va être rangé, dossier par dossier, avant de toucher à
/// quoi que ce soit. Renvoie les dossiers choisis (ou null : annulé).
Future<Set<String>?> showTidyPreview(
  BuildContext context, {
  required String title,
  required Map<String, List<String>> groups,
  int skipped = 0,
}) {
  final keep = {...groups.keys};
  final total = groups.values.fold<int>(0, (a, l) => a + l.length);
  return showDialog<Set<String>>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        icon: const Icon(Icons.auto_fix_high_rounded, color: Color(0xFF7C5CFF)),
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                '$total fichier${total > 1 ? 's' : ''} en vrac → ${groups.length} dossier${groups.length > 1 ? 's' : ''}. '
                'Rien n\'est supprimé (les doublons vont dans « Doublons »), et tu peux tout annuler.'
                '${skipped > 0 ? ' $skipped fichier${skipped > 1 ? 's' : ''} laissé${skipped > 1 ? 's' : ''} en place (raccourcis, téléchargements en cours).' : ''}',
              ),
              const SizedBox(height: 10),
              for (final e in groups.entries)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ExpansionTile(
                    leading: Checkbox(
                      value: keep.contains(e.key),
                      onChanged: (v) => set(() => v == true ? keep.add(e.key) : keep.remove(e.key)),
                    ),
                    title: Text('📁 ${e.key}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${e.value.length} fichier${e.value.length > 1 ? 's' : ''}'),
                    children: [
                      for (final n in e.value.take(40))
                        ListTile(dense: true, title: Text(n, overflow: TextOverflow.ellipsis)),
                      if (e.value.length > 40) ListTile(dense: true, title: Text('… et ${e.value.length - 40} autres')),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton.icon(
            icon: const Icon(Icons.auto_fix_high_rounded),
            onPressed: keep.isEmpty ? null : () => Navigator.pop(c, keep),
            label: const Text('Ranger'),
          ),
        ],
      ),
    ),
  );
}

/// Range un dossier du PC (avec l'aperçu). Renvoie un compte rendu.
Future<String> tidyPcFolder(BuildContext context, Directory dir, {bool bySubject = true}) async {
  final plan = await PcTidy.analyze(dir, bySubject: bySubject);
  if (plan.moves.isEmpty) return 'Rien à ranger dans ${dir.path} : c\'est déjà propre ✨';
  if (!context.mounted) return '';
  final keep = await showTidyPreview(
    context,
    title: 'Ranger ${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    groups: {for (final e in plan.groups.entries) e.key: [for (final m in e.value) m.name]},
    skipped: plan.skipped,
  );
  if (keep == null) return 'Rangement annulé.';
  final (n, errors) = await PcTidy.apply(plan, only: keep);
  return '$n fichier${n > 1 ? 's' : ''} rangé${n > 1 ? 's' : ''}'
      '${errors.isEmpty ? '' : ' (${errors.length} impossible${errors.length > 1 ? 's' : ''} : ${errors.first})'}.';
}

/// Range le Drive (avec l'aperçu).
Future<String> tidyDrive(BuildContext context, {bool bySubject = true}) async {
  final moves = await DriveTidy.analyze(bySubject: bySubject);
  if (moves.isEmpty) return 'Ton Drive est déjà rangé ✨';
  final groups = <String, List<String>>{};
  for (final m in moves) {
    groups.putIfAbsent(m.dest, () => []).add(m.name);
  }
  if (!context.mounted) return '';
  final keep = await showTidyPreview(context, title: 'Ranger mon Google Drive', groups: groups);
  if (keep == null) return 'Rangement annulé.';
  final (n, errors) = await DriveTidy.apply(moves, only: keep);
  return '$n fichier${n > 1 ? 's' : ''} rangé${n > 1 ? 's' : ''} sur ton Drive'
      '${errors.isEmpty ? '' : ' (${errors.length} impossible${errors.length > 1 ? 's' : ''})'}.';
}

/// La page « Ranger mon PC et mon Drive ».
class TidyPage extends StatefulWidget {
  const TidyPage({super.key});

  @override
  State<TidyPage> createState() => _TidyPageState();
}

class _TidyPageState extends State<TidyPage> {
  bool bySubject = true;
  bool busy = false;
  String? result;

  Future<void> _run(Future<String> Function() job) async {
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final r = await job();
      if (mounted) setState(() => result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pc(String what) => _run(() async {
    Directory? dir;
    if (what == 'autre') {
      final p = await getDirectoryPath(confirmButtonText: 'Ranger ce dossier');
      if (p == null) return 'Aucun dossier choisi.';
      dir = Directory(p);
    } else {
      dir = PcTidy.folder(what);
    }
    if (dir == null) throw 'Je ne trouve pas ce dossier sur ton PC';
    if (!mounted) return '';
    return tidyPcFolder(context, dir, bySubject: bySubject);
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final google = GoogleAuth.driveAccount;
    Widget folder(String key, IconData icon, String label) => ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: busy ? null : () => _pc(key),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Ranger mon PC et mon Drive')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(colors: [Color(0xFF6D4AFF), Color(0xFFE0457B)]),
            ),
            child: const Row(
              children: [
                Icon(Icons.auto_fix_high_rounded, color: Colors.white, size: 40),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Clicky range tes fichiers en vrac dans des dossiers (Images, PDF, Programmes, Cours/Maths…). '
                    'Tu vois tout avant, rien n\'est supprimé, et tu peux annuler. Tu peux aussi lui dire : '
                    '« Clicky, range mes téléchargements ».',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Ranger les cours par matière'),
            subtitle: const Text('« DM_maths.pdf » → Cours/Maths, « dissertation_philo.docx » → Cours/Philosophie'),
            value: bySubject,
            onChanged: (v) => setState(() => bySubject = v),
          ),
          const SizedBox(height: 8),
          Text('Mon PC', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              folder('telechargements', Icons.download_rounded, 'Téléchargements'),
              folder('bureau', Icons.desktop_windows_rounded, 'Bureau'),
              folder('documents', Icons.folder_rounded, 'Documents'),
              folder('images', Icons.image_rounded, 'Images'),
              folder('autre', Icons.create_new_folder_rounded, 'Autre dossier…'),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.undo_rounded),
              label: const Text('Annuler le dernier rangement du PC'),
              onPressed: busy
                  ? null
                  : () => _run(() async {
                      final n = await PcTidy.undoLast();
                      return n == 0 ? 'Rien à annuler.' : '$n fichier${n > 1 ? 's' : ''} remis à leur place.';
                    }),
            ),
          ),
          const Divider(height: 32),
          Text('Mon Google Drive', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (google == null)
            Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Connecte ton compte Google pour que Clicky range ton Drive.'),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.login_rounded),
                  label: Text(GoogleAuth.available ? 'Connecter Google' : 'Activer la connexion Google'),
                  onPressed: () => GoogleSetupPage.open(context).then((_) => setState(() {})),
                ),
              ],
            )
          else ...[
            Text('Compte : $google', style: theme.textTheme.bodySmall),
            if (!GoogleAuth.canWriteDrive(google))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('Autoriser Mon Hub à ranger mon Drive'),
                  onPressed: () => _run(() async {
                    final email = await GoogleAuth.signIn();
                    setState(() {});
                    return 'Compte $email autorisé ✅';
                  }),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.auto_fix_high_rounded),
                  label: const Text('Ranger mon Drive'),
                  onPressed: busy ? null : () => _run(() => tidyDrive(context, bySubject: bySubject)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Annuler le dernier rangement'),
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          final n = await DriveTidy.undoLast();
                          return n == 0 ? 'Rien à annuler.' : '$n fichier${n > 1 ? 's' : ''} remis à la racine du Drive.';
                        }),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          if (busy) const LinearProgressIndicator(),
          if (result != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: const Color(0xFF23A55A).withValues(alpha: 0.12),
              ),
              child: Text(result!, style: theme.textTheme.titleSmall),
            ),
        ],
      ),
    );
  }
}
