import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/claude_api.dart';
import '../core/module_store.dart';
import '../core/online/online.dart';
import '../core/session.dart';
import '../core/updater.dart';
import '../web/phone_actions.dart';
import 'clicky/long_memory.dart';
import 'phone_link_page.dart' show QrView;

/// Réglages → Mes appareils → Ajouter mon iPhone : **la version web** (sans
/// PC ni App Store). Le QR code ouvre Mon Hub dans Safari avec ton prénom,
/// le cerveau de Smily (clé Gemini), ton serveur Mon Hub en ligne et ses
/// souvenirs. Ces données sont dans la partie « # » du lien : le site ne
/// les reçoit jamais, elles restent dans le téléphone.
class WebVersionCard extends StatefulWidget {
  const WebVersionCard({super.key});

  static String get site => PhoneLinkCode.siteFor(Updater.repo);

  @override
  State<WebVersionCard> createState() => _WebVersionCardState();
}

class _WebVersionCardState extends State<WebVersionCard> {
  String? _link;
  bool _show = false;

  Future<void> _make() async {
    final gemini = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    final mem = LongMemory.instance;
    await mem.load();
    final all = [...mem.all]
      ..sort((a, b) => (b.pinned ? 100 : 0) + b.weight - (a.pinned ? 100 : 0) - a.weight);
    final server = Online.instance.server;
    final code = PhoneLinkCode(
      name: ModuleStore.prefs.getString('hub.name') ?? AppSession.instance.current?.name ?? '',
      gemini: gemini,
      serverUrl: server?.url,
      serverKey: server?.key,
      memories: [for (final m in all.take(30)) (m.topic, m.text)],
    );
    if (!mounted) return;
    setState(() {
      _link = code.link(WebVersionCard.site);
      _show = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = _link;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('🙂', style: TextStyle(fontSize: 24)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Version web : sans PC, sans App Store',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Le plus simple. Vise ce QR code avec l\'appareil photo de l\'iPhone : Mon Hub s\'ouvre dans Safari, '
              'déjà relié (ton prénom, le cerveau de Smily, ses souvenirs). Puis Partager → « Sur l\'écran '
              'd\'accueil ». Smily y appelle, prépare tes SMS, lance tes itinéraires, tes rappels, ta musique et tes '
              'Raccourcis. Avec ton compte en ligne, tu y retrouves aussi tes espaces et tes messages.',
            ),
            const SizedBox(height: 12),
            if (!_show)
              FilledButton.icon(
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('Afficher le QR code'),
                onPressed: _make,
              )
            else if (link != null) ...[
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: SizedBox.square(dimension: 240, child: QrView(link)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Ce QR code contient la clé de Smily : ne le montre qu\'à ton propre téléphone.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copier le lien'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lien copié.')));
                      }
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Voir le site'),
                    onPressed: () => Browser.open(WebVersionCard.site),
                  ),
                  TextButton(onPressed: () => setState(() => _show = false), child: const Text('Cacher')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
