import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/browser_link.dart';
import '../../core/claude_bridge.dart';
import '../widgets.dart';

/// Réglages de Nexo → **Nexo dans le navigateur** : installer
/// l'extension Chrome (ou Edge) de Mon Hub en 3 étapes.
class BrowserSetupPage extends StatefulWidget {
  const BrowserSetupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BrowserSetupPage()));

  /// Les fichiers de l'extension (dans les ressources de Mon Hub).
  static const files = ['manifest.json', 'background.js', 'icon.png'];

  /// Copie l'extension dans %APPDATA%\MonHub\extension-chrome (Chrome la
  /// charge depuis ce dossier). Renvoie le chemin du dossier.
  static Future<String> prepare() async {
    final base = ClaudeBridge.folder ?? Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}extension-chrome');
    await dir.create(recursive: true);
    for (final f in files) {
      final data = await rootBundle.load('assets/chrome-extension/$f');
      await File('${dir.path}${Platform.pathSeparator}$f').writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return dir.path;
  }

  @override
  State<BrowserSetupPage> createState() => _BrowserSetupPageState();
}

class _BrowserSetupPageState extends State<BrowserSetupPage> {
  String? folder;
  bool busy = false;

  Future<void> _prepare() async {
    setState(() => busy = true);
    try {
      final p = await BrowserSetupPage.prepare();
      await Clipboard.setData(ClipboardData(text: p));
      if (mounted) setState(() => folder = p);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Ouvre la page des extensions de Chrome (ou d'Edge).
  Future<void> _openExtensions() async {
    final chrome = Browser.chromePath(), edge = Browser.edgePath();
    try {
      if (chrome != null) {
        await Process.start(chrome, ['chrome://extensions'], mode: ProcessStartMode.detached);
      } else if (edge != null) {
        await Process.start(edge, ['edge://extensions'], mode: ProcessStartMode.detached);
      } else {
        throw 'Chrome ou Edge introuvable sur ce PC';
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = BrowserLink.instance;
    Widget step(int n, String title, String text, Widget? action) => Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              child: Text('$n', style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(text),
                  if (action != null) ...[const SizedBox(height: 8), action],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Nexo dans le navigateur')),
      body: ListenableBuilder(
        listenable: link,
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                Card(
                  color: (link.connected ? Colors.green : Colors.orange).withValues(alpha: 0.10),
                  child: ListTile(
                    leading: Icon(
                      link.connected ? Icons.check_circle_rounded : Icons.extension_off_rounded,
                      color: link.connected ? Colors.green : Colors.orange,
                    ),
                    title: Text(link.connected ? 'Extension branchée ✓' : 'Extension pas encore branchée'),
                    subtitle: Text(
                      link.connected
                          ? 'Dis par exemple : « Fais-le à ma place : crée un formulaire Google pour le sondage de la classe ».'
                          : 'Installe-la en 3 étapes ci-dessous (une seule fois).',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Avec l\'extension, Nexo peut utiliser tes sites (Google Classroom, Docs, Slides, Forms, Pronote…) dans '
                  'ses propres onglets, en arrière-plan, pendant que tu fais autre chose. Tout reste sur ton PC. Il ne va '
                  'jamais sur les pages de banque, de paiement ou de mots de passe, ne tape jamais de mot de passe, et te '
                  'demande avant d\'envoyer, publier, payer ou supprimer.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                step(
                  1,
                  'Préparer l\'extension',
                  folder == null
                      ? 'Mon Hub copie l\'extension dans un dossier de ton PC.'
                      : 'C\'est prêt dans :\n$folder\n(le chemin est copié : Ctrl + V à l\'étape 3).',
                  FilledButton.tonalIcon(
                    icon: busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_done_rounded),
                    label: Text(folder == null ? 'Préparer' : 'Recommencer'),
                    onPressed: busy ? null : _prepare,
                  ),
                ),
                step(
                  2,
                  'Ouvrir la page des extensions',
                  'Dans la page qui s\'ouvre, active le « Mode développeur » (interrupteur en haut à droite).',
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Ouvrir chrome://extensions'),
                    onPressed: _openExtensions,
                  ),
                ),
                step(
                  3,
                  'Charger l\'extension',
                  'Clique sur « Charger l\'extension non empaquetée », colle le chemin (Ctrl + V) dans la fenêtre qui '
                      's\'ouvre, puis « Sélectionner un dossier ». Le badge « ON » apparaît sur l\'icône : c\'est branché.',
                  null,
                ),
                const SizedBox(height: 8),
                Text(
                  'Bon à savoir : quand Nexo tape dans un éditeur comme Google Slides, Chrome affiche un bandeau jaune '
                  '« Mon Hub a commencé à déboguer ce navigateur » : c\'est normal, il disparaît tout seul après.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
