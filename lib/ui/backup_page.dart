import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/google_auth.dart';
import '../core/work_backup.dart';
import 'google_setup.dart';
import 'widgets.dart';

/// Réglages → Sauvegarde de mes travaux.
class WorkBackupPage extends StatefulWidget {
  const WorkBackupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const WorkBackupPage()));

  @override
  State<WorkBackupPage> createState() => _WorkBackupPageState();
}

class _WorkBackupPageState extends State<WorkBackupPage> {
  final b = WorkBackup.instance;

  @override
  void initState() {
    super.initState();
    unawaited(b.load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = GoogleAuth.available ? GoogleAuth.driveAccount : null;
    final ready = account != null && GoogleAuth.canWriteDrive(account);
    return Scaffold(
      appBar: AppBar(title: const Text('Sauvegarde de mes travaux')),
      body: ListenableBuilder(
        listenable: b,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                Text(
                  'Tes exposés, devoirs, présentations et tableurs sont copiés tout seuls dans ton Google Drive '
                  '(dossier « ${WorkBackup.driveFolder} »), toutes les 30 minutes. Seuls les fichiers nouveaux ou '
                  'modifiés partent, et rien n\'est jamais supprimé du Drive. Les photos et vidéos ne sont pas copiées.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (!ready)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.g_mobiledata_rounded, size: 32),
                      title: const Text('Connecte ton compte Google'),
                      subtitle: const Text('La sauvegarde va dans ton propre Drive.'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => GoogleSetupPage.open(context).then((_) => setState(() {})),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sauvegarder mes travaux dans mon Drive'),
                  subtitle: Text(
                    b.lastRun == null
                        ? 'Pas encore de sauvegarde'
                        : 'Dernière sauvegarde : ${dayLabel(b.lastRun!)} à ${hhmm(b.lastRun!)} · ${b.savedCount} fichiers',
                  ),
                  value: b.on,
                  onChanged: ready ? b.setOn : null,
                ),
                if (b.running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Expanded(child: Text(b.progress, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                if (b.lastError != null) ErrorBanner(b.lastError!),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.cloud_upload_rounded),
                      label: const Text('Sauvegarder maintenant'),
                      onPressed: !b.on || b.running
                          ? null
                          : () async {
                              final n = await b.runNow();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(n == 0 ? 'Tout est déjà à jour ✓' : '$n fichier${n > 1 ? 's' : ''} sauvegardé${n > 1 ? 's' : ''} ✓')),
                                );
                              }
                            },
                    ),
                    if (b.folderLink != null)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Voir dans le Drive'),
                        onPressed: () => Browser.open(b.folderLink!),
                      ),
                  ],
                ),
                const Divider(height: 32),
                Text('Dossiers sauvegardés', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                for (final f in b.folders)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_rounded),
                    title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: 'Retirer',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => b.setFolders([for (final x in b.folders) if (x != f) x]),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.create_new_folder_rounded),
                    label: const Text('Ajouter un dossier'),
                    onPressed: () async {
                      final d = await getDirectoryPath();
                      if (d != null && !b.folders.contains(d)) await b.setFolders([...b.folders, d]);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
