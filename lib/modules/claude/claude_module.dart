import 'package:material_ui/material_ui.dart';

import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/hub_module.dart';
import '../../ui/clicky/clicky.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

const extensionUrl =
    'https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-Claude.mcpb';

/// Claude dans Mon Hub :
/// * **Clicky** : compagnon à côté du curseur (Ctrl + Alt), qui voit l'écran,
///   parle et montre les boutons (voir ui/clicky/clicky.dart) ;
/// * **Discuter** : conversation directe avec Claude (clé API) ;
/// * **claude.ai** : le site habituel, intégré.
class ClaudeModule extends HubModule {
  @override
  String get id => 'claude';
  @override
  String get name => 'Claude';
  @override
  String get description => 'Ton assistant Claude et Clicky, le compagnon qui voit ton écran';
  @override
  IconData get icon => Icons.auto_awesome_rounded;
  @override
  Color get color => const Color(0xFFD97757);
  @override
  ApiAccess get access => ApiAccess.official;

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: ClaudeApi.store,
    builder: (context, _) => FutureBuilder(
      future: ClaudeApi.hasKey(),
      builder: (context, snap) {
        final ready = snap.data == true;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ready
                      ? 'Maintiens Ctrl + Alt et parle à Clicky, ou touche la bulle bleue. '
                            'Il voit ton écran et te montre où cliquer.'
                      : 'Ajoute ta clé API Claude pour activer Clicky, le compagnon '
                            'qui voit ton écran, parle et te montre où cliquer.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!ready)
                      FilledButton.icon(
                        icon: const Icon(Icons.key_rounded),
                        label: const Text('Ajouter ma clé'),
                        onPressed: () => showSettings(context),
                      )
                    else
                      FilledButton.icon(
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('Parler à Clicky'),
                        onPressed: ClickyController.instance.openPanel,
                      ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('Ouvrir Claude'),
                      onPressed: () =>
                          Navigator.push(context, MaterialPageRoute(builder: (c) => buildPage(c))),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  @override
  Widget buildPage(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            tooltip: 'Réglages de Claude et Clicky',
            icon: const Icon(Icons.key_rounded),
            onPressed: () => showSettings(context),
          ),
          if (ClaudeBridge.supported)
            IconButton(
              tooltip: 'Brancher l\'appli Claude à Mon Hub',
              icon: const Icon(Icons.extension_rounded),
              onPressed: () => showBridgeHelp(context),
            ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Discuter'),
            Tab(text: 'claude.ai'),
          ],
        ),
      ),
      body: TabBarView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _ChatTab(module: this),
          webLoginSupported
              ? const HubWebView(url: 'https://claude.ai/new', desktopUserAgent: true)
              : Center(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Ouvrir claude.ai'),
                    onPressed: () => openLink(context, 'https://claude.ai/new'),
                  ),
                ),
        ],
      ),
    ),
  );

  static Future<void> showSettings(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _SettingsDialog());

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

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final key = TextEditingController();
  bool? hasKey;
  final c = ClickyController.instance;

  @override
  void initState() {
    super.initState();
    ClaudeApi.hasKey().then((v) => mounted ? setState(() => hasKey = v) : null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Claude et Clicky'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Clicky et la discussion utilisent l\'API de Claude avec ta propre clé '
                  '(payée à l\'usage, quelques centimes par question). Crée-la sur '
                  'console.anthropic.com → API keys. Elle reste chiffrée sur cet appareil.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: hasKey == true
                        ? 'Clé enregistrée (remplacer…)'
                        : 'Clé API (sk-ant-…)',
                    border: const OutlineInputBorder(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Créer une clé'),
                    onPressed: () =>
                        openLink(context, 'https://console.anthropic.com/settings/keys'),
                  ),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: ClaudeApi.model,
                  decoration: const InputDecoration(
                    labelText: 'Modèle',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final e in ClaudeApi.models.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => v == null ? null : ClaudeApi.setModel(v),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activer Clicky'),
                  subtitle: const Text('Maintiens Ctrl + Alt pour parler, appui court pour écrire'),
                  value: c.enabled,
                  onChanged: (v) => c.setOption('enabled', v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Réponses à voix haute'),
                  value: c.voice,
                  onChanged: (v) => c.setOption('voice', v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Le curseur de Clicky suit la souris'),
                  value: c.follow,
                  onChanged: (v) => c.setOption('follow', v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (hasKey == true)
          TextButton(
            onPressed: () async {
              await ClaudeApi.setApiKey(null);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Supprimer la clé'),
          ),
        FilledButton(
          onPressed: () async {
            if (key.text.trim().isNotEmpty) await ClaudeApi.setApiKey(key.text);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

/// Discussion directe avec Claude (sans passer par claude.ai).
class _ChatTab extends StatefulWidget {
  const _ChatTab({required this.module});
  final ClaudeModule module;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> with AutomaticKeepAliveClientMixin {
  /// (question, réponse) affichés ; la conversation envoyée à l'API.
  final shown = <(bool, String, DateTime)>[];
  final history = <Map<String, dynamic>>[];
  bool busy = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _send(String text) async {
    if (!await ClaudeApi.hasKey()) {
      if (mounted) await ClaudeModule.showSettings(context);
      if (!await ClaudeApi.hasKey()) return;
    }
    setState(() {
      shown.add((true, text, DateTime.now()));
      busy = true;
    });
    history.add({'role': 'user', 'content': text});
    try {
      final r = await ClaudeApi.chat(
        system:
            'Tu es Claude, intégré à Mon Hub, l\'appli personnelle d\'un·e élève. '
            'Réponds en français, clairement. Pour les devoirs, explique et guide '
            'plutôt que de donner directement la réponse.',
        history: history,
        effort: 'medium',
      );
      if (mounted) setState(() => shown.add((false, r, DateTime.now())));
    } catch (e) {
      // On retire la question pour pouvoir la renvoyer.
      while (history.isNotEmpty && history.last['role'] != 'user') {
        history.removeLast();
      }
      if (history.isNotEmpty) history.removeLast();
      if (mounted) setState(() => shown.add((false, '⚠️ $e', DateTime.now())));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final color = widget.module.color;
    return Column(
      children: [
        Expanded(
          child: shown.isEmpty
              ? const EmptyHint(
                  'Pose une question, fais-toi expliquer un exercice, organise ta semaine…',
                  icon: Icons.auto_awesome_rounded,
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: shown.length + (busy ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (busy && i == 0) return const LoadingHint();
                    final (mine, text, at) = shown[shown.length - 1 - (i - (busy ? 1 : 0))];
                    return ChatBubble(
                      text: text,
                      time: hhmm(at),
                      mine: mine,
                      color: color,
                      author: mine ? null : 'Claude',
                    );
                  },
                ),
        ),
        ChatComposer(color: color, hint: 'Écrire à Claude', onSend: _send),
      ],
    );
  }
}
