import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/hub_module.dart';
import '../../ui/chat_history.dart';
import '../../ui/clicky/clicky.dart';
import '../../ui/clicky/mic_test.dart';
import '../../ui/clicky/claude_code.dart';
import '../../ui/clicky/journal.dart';
import '../../ui/clicky/routines.dart';
import '../../ui/clicky/clicky_desktop.dart';
import '../../ui/clicky/ollama.dart';
import '../../ui/clicky/settings.dart';
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
      future: ClickyController.instance.refreshReady(),
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
                      : 'Choisis le cerveau de Clicky (Claude, ou une IA gratuite sur ton PC) : le compagnon '
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
                        label: const Text('Configurer Clicky'),
                        onPressed: () => showSettings(context),
                      )
                    else
                      FilledButton.icon(
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('Parler à Clicky'),
                        onPressed: () {
                          final c = ClickyController.instance;
                          if (c.handledElsewhere) {
                            ClickyDesktop.launch().then((_) => ClickyDesktop.send('open'));
                          } else {
                            c.openPanel();
                          }
                        },
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

  /// Pose une question à Clicky (celui de l'appli, ou Clicky partout).
  static Future<void> askClicky(String q) async {
    final c = ClickyController.instance;
    if (c.handledElsewhere) {
      await ClickyDesktop.launch();
      await ClickyDesktop.ask(q);
    } else {
      c.openPanel();
      await c.ask(q);
    }
  }

  @override
  Widget buildPage(BuildContext context) => DefaultTabController(
    length: 5,
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
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(icon: Icon(Icons.chat_rounded), text: 'Discuter'),
            Tab(icon: Icon(Icons.history_rounded), text: 'Historique Clicky'),
            Tab(icon: Icon(Icons.psychology_rounded), text: 'Journal'),
            Tab(icon: Icon(Icons.event_repeat_rounded), text: 'Routines'),
            Tab(icon: Icon(Icons.public_rounded), text: 'claude.ai'),
          ],
        ),
      ),
      body: TabBarView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _ChatTab(module: this),
          ChatHistoryList(
            history: ChatHistory.clicky,
            color: color,
            otherName: ClickyController.instance.jarvis ? 'Jarvis' : 'Clicky',
            onOpen: (t) => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => _ClickyThreadPage(thread: t, color: color)),
            ),
          ),
          JournalView(
            color: color,
            onQuiz: (entries) {
              final c = ClickyController.instance;
              if (c.handledElsewhere) {
                askClicky('qu\'est-ce que je dois réviser');
              } else {
                c.openPanel();
                c.reviewQuiz(entries);
              }
            },
          ),
          RoutinesView(color: color),
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

  static Future<void> showSettings(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const _SettingsDialog()),
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

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final key = TextEditingController();
  late final ollamaUrl = TextEditingController(text: Ollama.url);
  late final ollamaModel = TextEditingController(text: Ollama.model);
  bool? hasKey;
  List<String>? installed;
  final c = ClickyController.instance;

  @override
  void initState() {
    super.initState();
    ClaudeApi.hasKey().then((v) => mounted ? setState(() => hasKey = v) : null);
    _checkOllama();
  }

  Future<void> _checkOllama() async {
    final l = await Ollama.installed();
    if (mounted) setState(() => installed = l);
  }

  Future<void> _save() async {
    if (key.text.trim().isNotEmpty) await ClaudeApi.setApiKey(key.text);
    await ClaudeApi.store.setJson('ollama.url', ollamaUrl.text.trim());
    await ClaudeApi.store.setJson('ollama.model', ollamaModel.text.trim());
    // Clicky vient d'avoir un cerveau : on le démarre (Windows : partout).
    // Nouveau cerveau / modèle : Clicky partout repart avec.
    if (await c.refreshReady()) unawaited(ClickyDesktop.restart());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_save());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.jarvis ? 'Jarvis, Claude et Clicky' : 'Claude et Clicky'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Enregistrer'),
              ),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                _body(context, text),
                const ClickyMoreSettings(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, TextTheme text) {
    return ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Cerveau de Clicky', style: text.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    if (ClaudeCode.supported)
                      const ButtonSegment(
                        value: 'claudecode',
                        icon: Icon(Icons.workspace_premium_rounded),
                        label: Text('Claude Pro'),
                      ),
                    const ButtonSegment(
                      value: 'claude',
                      icon: Icon(Icons.key_rounded),
                      label: Text('Clé API'),
                    ),
                    const ButtonSegment(
                      value: 'ollama',
                      icon: Icon(Icons.computer_rounded),
                      label: Text('Ollama'),
                    ),
                  ],
                  selected: {c.provider},
                  onSelectionChanged: (v) => c.setOption('provider', v.first),
                ),
                const SizedBox(height: 12),
                if (c.provider == 'claudecode')
                  const _ClaudeProSection()
                else if (c.provider == 'claude') ...[
                  const Text(
                    'Le plus malin : voit et comprend très bien l\'écran, utilise tes modules '
                    '(agenda, notes, messages…) et le mode agent. Clé API personnelle, payée à '
                    'l\'usage (quelques centimes par question), créée sur console.anthropic.com. '
                    'Elle reste chiffrée sur cet appareil.',
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
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('Créer une clé'),
                        onPressed: () =>
                            openLink(context, 'https://console.anthropic.com/settings/keys'),
                      ),
                      const Spacer(),
                      if (hasKey == true)
                        TextButton(
                          onPressed: () async {
                            await ClaudeApi.setApiKey(null);
                            setState(() => hasKey = false);
                          },
                          child: const Text('Supprimer la clé'),
                        ),
                    ],
                  ),
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
                ] else ...[
                  const Text(
                    'Sans clé ni compte : une IA tourne directement sur ton PC, rien ne sort sur '
                    'internet. 1. Installe Ollama (ollama.com). 2. Dans un terminal, tape '
                    '« ollama pull qwen2.5vl » (un modèle qui voit les images). Il faut un PC '
                    'assez puissant ; Clicky voit et répond, mais sans le mode agent.',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        installed == null
                            ? Icons.hourglass_empty_rounded
                            : installed!.isEmpty
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_rounded,
                        size: 18,
                        color: installed?.isNotEmpty == true ? Colors.green : null,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          installed == null
                              ? 'Recherche d\'Ollama…'
                              : installed!.isEmpty
                              ? 'Ollama introuvable sur ce PC (ou pas lancé).'
                              : 'Ollama trouvé : ${installed!.join(', ')}',
                        ),
                      ),
                      IconButton(
                        tooltip: 'Revérifier',
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: () {
                          setState(() => installed = null);
                          _checkOllama();
                        },
                      ),
                    ],
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Télécharger Ollama'),
                    onPressed: () => openLink(context, 'https://ollama.com/download'),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: ollamaModel,
                    decoration: InputDecoration(
                      labelText: 'Modèle (qui voit les images)',
                      helperText: 'Conseillés : ${Ollama.suggested.join(', ')}',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ollamaUrl,
                    decoration: const InputDecoration(
                      labelText: 'Adresse d\'Ollama',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activer Clicky'),
                  subtitle: const Text('Maintiens Ctrl + Alt pour parler, appui court pour écrire'),
                  value: c.enabled,
                  onChanged: (v) async {
                    await c.setOption('enabled', v);
                    v ? await ClickyDesktop.launch() : await ClickyDesktop.stop();
                  },
                ),
                if (ClickyController.everywhereSupported)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Clicky partout'),
                    subtitle: const Text(
                      'Clicky vit au-dessus de tout l\'écran : il voit toutes tes applis et '
                      'tous tes écrans, même quand Mon Hub est réduit.',
                    ),
                    value: c.everywhere,
                    onChanged: (v) async {
                      await c.setOption('everywhere', v);
                      v ? await ClickyDesktop.launch() : await ClickyDesktop.stop();
                    },
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Toujours afficher le curseur bleu'),
                  subtitle: const Text('Sinon, Clicky n\'apparaît que quand tu lui parles'),
                  value: c.alwaysShow,
                  onChanged: (v) => c.setOption('show', v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Voix de Clicky (réponses lues à voix haute)'),
                  subtitle: const Text('Désactivée : il répond seulement par écrit'),
                  value: c.voice,
                  onChanged: (v) async {
                    if (!v) await c.stopSpeaking();
                    await c.setOption('voice', v);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Parler à Clicky au micro'),
                  subtitle: const Text('Désactivé : Ctrl + Alt ouvre la zone pour écrire'),
                  value: c.mic,
                  onChanged: (v) => c.setOption('mic', v),
                ),
                if (c.mic)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                      label: const Text('Tester le micro'),
                      onPressed: () => MicTestDialog.show(context),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Le curseur de Clicky suit la souris'),
                  value: c.follow,
                  onChanged: (v) => c.setOption('follow', v),
                ),
                const SizedBox(height: 4),
                Text(
                  'Astuce : commence par « Agent, … » (ex. « Agent, fais-moi le résumé de mes '
                  'devoirs de la semaine ») pour une tâche de fond ; Clicky te prévient quand '
                  'c\'est fini.',
                  style: text.labelSmall,
                ),
              ],
            ),
    );
  }
}

/// Cerveau « Claude Pro » : ton abonnement Claude, via ton Claude Code.
class _ClaudeProSection extends StatefulWidget {
  const _ClaudeProSection();

  @override
  State<_ClaudeProSection> createState() => _ClaudeProSectionState();
}

class _ClaudeProSectionState extends State<_ClaudeProSection> {
  Future<(bool, String)>? _status;
  bool _installed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  void _check() {
    setState(() {
      _status = ClaudeCode.status().then((s) async {
        final path = await ClaudeCode.find();
        if (mounted) setState(() => _installed = path != null);
        return s;
      });
    });
    unawaited(ClickyController.instance.refreshReady());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Clicky utilise ton abonnement Claude (Pro, Max…) au lieu d\'une clé payante : '
          'il passe par Claude Code, l\'outil officiel d\'Anthropic. Tu te connectes '
          'toi-même sur la page d\'Anthropic ; Mon Hub ne voit jamais ta connexion. '
          'Les questions comptent dans les limites de ton abonnement.',
        ),
        const SizedBox(height: 10),
        FutureBuilder(
          future: _status,
          builder: (context, snap) {
            final s = snap.data;
            final ok = s?.$1 == true;
            return Row(
              children: [
                Icon(
                  s == null
                      ? Icons.hourglass_empty_rounded
                      : ok
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: s == null ? null : (ok ? Colors.green : Colors.orange),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(s?.$2 ?? 'Recherche de Claude Code…')),
                IconButton(
                  tooltip: 'Revérifier',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _check,
                ),
              ],
            );
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!_installed)
              FilledButton.icon(
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Installer Claude Code'),
                onPressed: () async {
                  if (!await ClaudeCode.install() && context.mounted) {
                    await openLink(context, 'https://code.claude.com/docs/en/setup');
                  }
                },
              ),
            if (_installed)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('Se connecter'),
                onPressed: ClaudeCode.openLogin,
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          !_installed
              ? '1. « Installer Claude Code » (une fenêtre s\'ouvre et installe le programme '
                    'officiel). 2. Reviens ici et appuie sur ↻. 3. « Se connecter » : ta page '
                    'Claude s\'ouvre, connecte-toi avec ton compte Pro.'
              : 'Pas encore connecté ? « Se connecter » ouvre la connexion officielle '
                    'd\'Anthropic dans ton navigateur. Ensuite, appuie sur ↻.',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: ClaudeCode.model,
          decoration: const InputDecoration(labelText: 'Modèle', border: OutlineInputBorder()),
          items: [
            for (final e in ClaudeCode.models.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => v == null ? null : ClaudeCode.setModel(v),
        ),
      ],
    );
  }
}

/// Discussion directe avec Claude (sans passer par claude.ai), avec
/// l'historique de toutes tes conversations.
class _ChatTab extends StatefulWidget {
  const _ChatTab({required this.module});
  final ClaudeModule module;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> with AutomaticKeepAliveClientMixin {
  final history = ChatHistory.claude;

  /// Conversation ouverte (null = nouvelle, pas encore enregistrée).
  String? threadId;
  bool busy = false;
  String streaming = '';
  String status = '';

  /// Message d'erreur (pas enregistré dans l'historique).
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    history.addListener(_changed);
    unawaited(history.load());
  }

  @override
  void dispose() {
    history.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  ChatThread? get thread => history.byId(threadId);
  List<ChatMsg> get messages => thread?.messages ?? const [];

  static const _system =
      'Tu es Claude, intégré à Mon Hub, l\'appli personnelle d\'un·e élève. '
      'Réponds en français, clairement. Pour les devoirs, explique et guide '
      'plutôt que de donner directement la réponse.';

  /// Abonnement Claude Pro (via Claude Code) si c'est le cerveau choisi et
  /// qu'il est installé ; sinon la clé API.
  Future<bool> _usePro() async =>
      ClickyController.instance.provider == 'claudecode' && await ClaudeCode.find() != null;

  void _newChat() {
    if (busy) return;
    setState(() {
      threadId = null;
      error = null;
    });
  }

  void _open(ChatThread t) {
    if (busy) return;
    setState(() {
      threadId = t.id;
      error = null;
    });
  }

  Future<void> _send(String text) async {
    final pro = await _usePro();
    if (!pro && !await ClaudeApi.hasKey()) {
      if (mounted) await ClaudeModule.showSettings(context);
      if (!await _usePro() && !await ClaudeApi.hasKey()) return;
    }
    final id = threadId ?? ChatThread.newId();
    final past = [...messages];
    setState(() {
      threadId = id;
      busy = true;
      streaming = '';
      status = '';
      error = null;
    });
    await history.add(id, ChatMsg(mine: true, text: text));
    try {
      final String r;
      if (await _usePro()) {
        // Claude Code ne garde pas la conversation : on la lui redonne.
        final lines = [
          for (final m in past.skip(math.max(0, past.length - 30)))
            '${m.mine ? 'Moi' : 'Claude'} : ${m.text}',
        ];
        r = await ClaudeCode.ask(
          system: _system,
          question: lines.isEmpty ? text : '${lines.join('\n\n')}\n\nMoi : $text',
          web: ClickyController.instance.webSearch,
          onText: (t) => mounted ? setState(() => streaming = t) : null,
          onStatus: (s) => mounted ? setState(() => status = s) : null,
        );
      } else {
        final h = <Map<String, dynamic>>[
          for (final m in past.skip(math.max(0, past.length - 40)))
            {'role': m.mine ? 'user' : 'assistant', 'content': m.text},
          {'role': 'user', 'content': text},
        ];
        r = await ClaudeApi.chat(
          system: _system,
          history: h,
          effort: 'medium',
          onText: (t) => mounted ? setState(() => streaming = t) : null,
          onStatus: (s) => mounted ? setState(() => status = s) : null,
        );
      }
      await history.add(id, ChatMsg(mine: false, text: r));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          streaming = '';
          status = '';
        });
      }
    }
  }

  Widget _chat(BuildContext context, {required bool wide}) {
    final color = widget.module.color;
    final msgs = messages;
    final extra = (busy ? 1 : 0) + (error != null ? 1 : 0);
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Row(
            children: [
              if (!wide)
                IconButton(
                  tooltip: 'Historique des conversations',
                  icon: const Icon(Icons.history_rounded),
                  onPressed: () => _showHistorySheet(context),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  thread?.label ?? 'Nouvelle conversation',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Nouvelle conversation',
                icon: const Icon(Icons.add_comment_rounded),
                onPressed: busy ? null : _newChat,
              ),
            ],
          ),
        ),
        Expanded(
          child: msgs.isEmpty && extra == 0
              ? const EmptyHint(
                  'Pose une question, fais-toi expliquer un exercice, organise ta semaine… '
                  'Tes conversations sont enregistrées dans l\'historique.',
                  icon: Icons.auto_awesome_rounded,
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length + extra,
                  itemBuilder: (context, i) {
                    if (error != null && i == 0) return ErrorBanner(error!);
                    final j = i - (error != null ? 1 : 0);
                    if (busy && j == 0) {
                      return streaming.isEmpty
                          ? Column(
                              children: [
                                const LoadingHint(),
                                if (status.isNotEmpty)
                                  Text(status, style: Theme.of(context).textTheme.labelSmall),
                              ],
                            )
                          : ChatBubble(
                              text: streaming,
                              time: status.isEmpty ? '…' : status,
                              mine: false,
                              color: color,
                              author: 'Claude',
                            );
                    }
                    final m = msgs[msgs.length - 1 - (j - (busy ? 1 : 0))];
                    return ChatBubble(
                      text: m.text,
                      time: '${dayLabel(m.at)} ${hhmm(m.at)}',
                      mine: m.mine,
                      color: color,
                      author: m.mine ? null : 'Claude',
                    );
                  },
                ),
        ),
        ChatComposer(color: color, hint: 'Écrire à Claude', onSend: _send),
      ],
    );
  }

  Future<void> _showHistorySheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => SizedBox(
      height: MediaQuery.sizeOf(c).height * 0.8,
      child: ChatHistoryList(
        history: history,
        selectedId: threadId,
        color: widget.module.color,
        onNew: () {
          Navigator.pop(c);
          _newChat();
        },
        onOpen: (t) {
          Navigator.pop(c);
          _open(t);
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 820;
        if (!wide) return _chat(context, wide: false);
        return Row(
          children: [
            SizedBox(
              width: 300,
              child: ChatHistoryList(
                history: history,
                selectedId: threadId,
                color: widget.module.color,
                onNew: _newChat,
                onOpen: _open,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _chat(context, wide: true)),
          ],
        );
      },
    );
  }
}

/// Une conversation de Clicky enregistrée, avec « Continuer ».
class _ClickyThreadPage extends StatelessWidget {
  const _ClickyThreadPage({required this.thread, required this.color});
  final ChatThread thread;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = ClickyController.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(thread.label, overflow: TextOverflow.ellipsis),
        actions: [
          if (!c.handledElsewhere)
            TextButton.icon(
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Continuer'),
              onPressed: () {
                Navigator.pop(context);
                c.continueThread(thread);
              },
            ),
        ],
      ),
      body: ChatThreadView(thread: thread, color: color, otherName: c.jarvis ? 'Jarvis' : 'Clicky'),
    );
  }
}
