import 'package:material_ui/material_ui.dart';

import '../../core/claude_bridge.dart';
import '../../core/hub_module.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

const extensionUrl =
    'https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Claude.mcpb';

/// Claude (claude.ai, ton compte habituel) directement dans Mon Hub.
///
/// Sur PC, l'extension « Mon Hub » pour l'appli Claude lui permet en plus de
/// lire et d'agir dans Mon Hub (voir core/claude_bridge.dart).
class ClaudeModule extends HubModule {
  @override
  String get id => 'claude';
  @override
  String get name => 'Claude';
  @override
  String get description => 'Ton assistant Claude, avec ton compte';
  @override
  IconData get icon => Icons.auto_awesome_rounded;
  @override
  Color get color => const Color(0xFFD97757);
  @override
  ApiAccess get access => ApiAccess.official;

  @override
  Widget buildSummary(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Text(
        'Pose une question, fais-toi aider pour tes devoirs, '
        'organise ta semaine…',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        icon: const Icon(Icons.chat_bubble_outline_rounded),
        label: const Text('Ouvrir Claude'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => buildPage(c))),
      ),
    ],
  );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name),
      actions: [
        if (ClaudeBridge.supported)
          TextButton.icon(
            icon: const Icon(Icons.extension_rounded),
            label: const Text('Brancher à Mon Hub'),
            onPressed: () => showBridgeHelp(context),
          ),
      ],
    ),
    body: webLoginSupported
        ? const HubWebView(url: 'https://claude.ai/new')
        : Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Ouvrir claude.ai'),
              onPressed: () => openLink(context, 'https://claude.ai/new'),
            ),
          ),
  );

  static Future<void> showBridgeHelp(BuildContext context) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Laisser Claude agir dans Mon Hub'),
      content: const SingleChildScrollView(
        child: Text(
          'Avec l\'appli Claude pour ordinateur, Claude peut lire ton agenda, tes '
          'notes, tes messages et agir (ajouter un évènement, répondre à un MP, '
          'noter un livre…). Il te demande la permission avant chaque action.\n\n'
          '1. Installe l\'appli Claude pour Windows (claude.ai/download) et '
          'connecte-toi.\n'
          '2. Télécharge l\'extension « MonHub-Claude.mcpb » et double-clique dessus : '
          'Claude s\'ouvre, clique sur « Installer ».\n'
          '3. Laisse Mon Hub ouvert. Dans Claude, demande par exemple : '
          '« Qu\'est-ce que j\'ai demain ? » ou « Ajoute foot mercredi 14h ».\n\n'
          'Tout reste sur ton PC : l\'extension parle à Mon Hub en local.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => openLink(c, 'https://claude.ai/download'),
          child: const Text('Appli Claude'),
        ),
        FilledButton(
          onPressed: () => openLink(c, extensionUrl),
          child: const Text('Télécharger l\'extension'),
        ),
      ],
    ),
  );
}
