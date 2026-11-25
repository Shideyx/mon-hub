import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/online/online.dart';
import '../core/online/spaces.dart';
import '../ui/hud/hud.dart';
import '../ui/spaces/space_page.dart';
import '../ui/spaces/spaces_page.dart';
import '../ui/theme.dart';
import 'phone_actions.dart';
import 'phone_bridge.dart';
import 'web_smily.dart';

/// **Mon Hub sur le téléphone** (version web, à mettre sur l'écran d'accueil
/// de l'iPhone) : Nexo qui agit sur le téléphone, les espaces et messages du
/// compte en ligne, le même compte que le PC.
class WebApp extends StatelessWidget {
  const WebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mon Hub',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.dark,
    home: const WebRoot(),
  );
}

/// Ouvre un lien : appli (tel:, sms:, spotify:…) dans la même page, site web
/// dans un nouvel onglet.
Future<bool> openLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final web = uri.scheme == 'http' || uri.scheme == 'https';
  try {
    return await launchUrl(uri, webOnlyWindowName: web ? '_blank' : '_self');
  } catch (_) {
    return false;
  }
}

class WebRoot extends StatefulWidget {
  const WebRoot({super.key});

  @override
  State<WebRoot> createState() => _WebRootState();
}

class _WebRootState extends State<WebRoot> {
  final _smily = WebSmily.instance;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await _smily.load();
    await Online.instance.open();
    Spaces.instance.onMessage = _smily.onSpaceMessage;
    if (Online.instance.signedIn) unawaited(Spaces.instance.start());
    // Lien du QR code du PC (« #lien=… ») : lu puis effacé de l'adresse.
    final code = PhoneLinkCode.decode(PhoneBridge.hash);
    String? said;
    if (code != null) {
      PhoneBridge.clearHash();
      said = await _smily.applyLink(code);
    }
    if (!mounted) return;
    setState(() => _ready = true);
    if (said != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(said)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: Text('🙂', style: TextStyle(fontSize: 64))));
    return ListenableBuilder(
      listenable: _smily,
      builder: (context, _) => _smily.setUp ? const WebShell() : const WelcomePage(),
    );
  }
}

// ------------------------------------------------------------------ bienvenue

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _name = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Scaffold(
      body: HudBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            children: [
              const Center(child: Text('🙂', style: TextStyle(fontSize: 72))),
              const SizedBox(height: 8),
              Text(
                'Salut ! Je suis Nexo.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Je vis aussi sur ton téléphone. Pour que je sois le même que sur ton PC, choisis une façon de me '
                'retrouver :',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, height: 1.4),
              ),
              const SizedBox(height: 20),
              HudPanel(
                hot: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('1 · RELIER MON PC', style: hudLabel(context, color: c.accent)),
                    const SizedBox(height: 8),
                    const Text(
                      'Sur ton PC : Réglages → Mes appareils → Ajouter mon iPhone → « Version web ». Vise le QR code '
                      'avec l\'appareil photo de l\'iPhone : je m\'ouvre avec ton prénom, mon cerveau et mes souvenirs.',
                    ),
                    const SizedBox(height: 10),
                    HudButton(label: 'Coller le code de mon PC', icon: Icons.content_paste_rounded, onPressed: _paste),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              HudPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('2 · MON COMPTE EN LIGNE', style: hudLabel(context, color: c.accent)),
                    const SizedBox(height: 8),
                    const Text(
                      'Même adresse et même mot de passe que Mon Hub en ligne sur ton PC : tout ton compte, tes '
                      'espaces et tes messages.',
                    ),
                    const SizedBox(height: 10),
                    HudButton(
                      label: 'Me connecter',
                      icon: Icons.login_rounded,
                      onPressed: () => OnlineSignInSheet.open(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              HudPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('3 · SANS COMPTE', style: hudLabel(context, color: c.accent)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Ton prénom'),
                    ),
                    const SizedBox(height: 10),
                    HudButton(
                      label: 'Commencer',
                      onPressed: () => WebSmily.instance.finishSetup(name: _name.text),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _paste() async {
    final said = await pasteLinkCode(context);
    if (said != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(said)));
    }
  }
}

/// Colle le code du PC (MONHUB-TEL: ou le lien). Renvoie ce qu'a dit Nexo.
Future<String?> pasteLinkCode(BuildContext context) async {
  final ctl = TextEditingController();
  try {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (PhoneLinkCode.decode(clip?.text ?? '') != null) ctl.text = clip!.text!;
  } catch (_) {}
  if (!context.mounted) return null;
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Code de mon PC'),
      content: TextField(
        controller: ctl,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'MONHUB-TEL:… ou le lien'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Relier')),
      ],
    ),
  );
  if (text == null) return null;
  final code = PhoneLinkCode.decode(text);
  if (code == null) return 'Ce n\'est pas un code de Mon Hub.';
  return WebSmily.instance.applyLink(code);
}

/// Connexion au compte en ligne (et, si besoin, le code du serveur).
class OnlineSignInSheet extends StatefulWidget {
  const OnlineSignInSheet({super.key});

  static Future<void> open(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const OnlineSignInSheet(),
  );

  @override
  State<OnlineSignInSheet> createState() => _OnlineSignInSheetState();
}

class _OnlineSignInSheetState extends State<OnlineSignInSheet> {
  final _server = TextEditingController();
  final _mail = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!Online.instance.configured) {
        final s = OnlineServer.fromCode(_server.text);
        if (s == null) throw 'Colle le code du serveur (MONHUB-SERVEUR:…), donné par ton PC.';
        await Online.instance.setServer(s);
      }
      final said = await WebSmily.instance.signInOnline(_mail.text, _pass.text);
      if (!mounted) return;
      final m = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      m?.showSnackBar(SnackBar(content: Text(said)));
    } catch (e) {
      if (mounted) setState(() => _error = Online.explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mon compte en ligne', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (!Online.instance.configured) ...[
              const Text(
                'D\'abord le serveur : sur ton PC, Réglages → Compte en ligne et espaces → « Copier le code du '
                'serveur », puis colle-le ici.',
              ),
              TextField(
                controller: _server,
                decoration: const InputDecoration(labelText: 'Code du serveur (MONHUB-SERVEUR:…)'),
              ),
            ],
            TextField(
              controller: _mail,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Adresse mail'),
            ),
            TextField(
              controller: _pass,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Mot de passe de Mon Hub'),
              onSubmitted: (_) => _go(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: HudColors.of(context).bad)),
            ],
            const SizedBox(height: 14),
            HudButton(label: _busy ? 'Connexion…' : 'Me connecter', primary: true, onPressed: _busy ? null : _go),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ l'appli

class WebShell extends StatefulWidget {
  const WebShell({super.key});

  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    SpaceActions.openAccount = OnlineSignInSheet.open;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: HudBackground(
        child: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _tab,
            children: [
              const ChatTab(),
              SpacesPage(onOpen: (s) => _openSpace(context, s)),
              PhoneTab(onTry: _try),
              const SettingsTab(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: Spaces.instance,
        builder: (context, _) {
          final unread = Spaces.instance.totalUnread;
          return NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(icon: Text('🙂', style: TextStyle(fontSize: 22)), label: 'Nexo'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.forum_rounded),
                ),
                label: 'Espaces',
              ),
              const NavigationDestination(icon: Icon(Icons.phone_iphone_rounded), label: 'Téléphone'),
              const NavigationDestination(icon: Icon(Icons.tune_rounded), label: 'Réglages'),
            ],
          );
        },
      ),
    );
  }

  void _try(String phrase) {
    setState(() => _tab = 0);
    unawaited(WebSmily.instance.ask(phrase));
  }

  static void _openSpace(BuildContext context, Space s) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text(s.name)),
        body: HudBackground(
          child: SafeArea(
            top: false,
            child: SpacePage(spaceId: s.id, onClosed: () => Navigator.maybePop(ctx)),
          ),
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ Nexo

class ChatTab extends StatefulWidget {
  const ChatTab({super.key});

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _smily = WebSmily.instance;

  static const examples = [
    'Appelle maman',
    'Envoie un message à Léo pour lui dire que j\'arrive',
    'Itinéraire vers la gare',
    'Minuteur 10 min pour les pâtes',
    'Rappelle-moi de réviser demain à 18 h',
    'Mets du Jul',
    'Ouvre Snapchat',
  ];

  void _send([String? text]) {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    _input.clear();
    unawaited(_smily.ask(t));
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  Future<void> _run(PhoneAction a) async {
    if (a.kind == 'copier') await Clipboard.setData(ClipboardData(text: a.copy ?? ''));
    final said = await _smily.run(a, open: openLink);
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    if (said != null) m?.showSnackBar(SnackBar(content: Text(said)));
    if (a.kind == 'copier') m?.showSnackBar(const SnackBar(content: Text('Copié.')));
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: _smily,
      builder: (context, _) {
        _toBottom();
        final msgs = _smily.messages;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text(_smily.thinking ? '🤔' : '🙂', style: const TextStyle(fontSize: 30)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _smily.name.isEmpty ? 'Nexo' : 'Salut ${_smily.name} !',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
            ),
            for (final t in _smily.timers) _TimerTile(t),
            Expanded(
              child: msgs.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text('Demande-moi par exemple :', style: TextStyle(color: c.muted)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [for (final e in examples) ActionChip(label: Text(e), onPressed: () => _send(e))],
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: msgs.length + (_smily.thinking ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == msgs.length) return const _Bubble(mine: false, text: '…');
                        final m = msgs[i];
                        return Column(
                          crossAxisAlignment: m.mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            _Bubble(mine: m.mine, text: m.text),
                            if (m.actions.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final a in m.actions)
                                      if (!a.immediate)
                                        HudButton(label: a.label, primary: true, compact: true, onPressed: () => _run(a)),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Demande à Nexo…',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(onPressed: _send, icon: const Icon(Icons.arrow_upward_rounded)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.text});
  final bool mine;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: mine ? c.accent : c.panel,
            border: mine ? null : Border.all(color: c.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectableText(text, style: TextStyle(color: mine ? Colors.white : c.text, height: 1.35)),
        ),
      ),
    );
  }
}

class _TimerTile extends StatelessWidget {
  const _TimerTile(this.t);
  final WebTimer t;

  @override
  Widget build(BuildContext context) {
    final left = t.left.isNegative ? Duration.zero : t.left;
    final mm = left.inMinutes.toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: HudPanel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Text('⏱️'),
            const SizedBox(width: 8),
            Text('${left.inHours > 0 ? '${left.inHours}:' : ''}$mm:$ss', style: hudLabel(context, size: 15)),
            const SizedBox(width: 8),
            Expanded(child: Text(t.what, overflow: TextOverflow.ellipsis)),
            IconButton(
              tooltip: 'Arrêter',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => WebSmily.instance.cancelTimer(t),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ téléphone

class PhoneTab extends StatefulWidget {
  const PhoneTab({super.key, required this.onTry});
  final ValueChanged<String> onTry;

  @override
  State<PhoneTab> createState() => _PhoneTabState();
}

class _PhoneTabState extends State<PhoneTab> {
  static const can = [
    ('📞', 'Appeler', 'Appelle maman'),
    ('💬', 'Préparer un SMS', 'Envoie un message à maman pour lui dire que je rentre'),
    ('🧭', 'Itinéraire', 'Itinéraire vers le collège'),
    ('⏱️', 'Minuteur', 'Minuteur 25 min pour réviser'),
    ('📅', 'Rappel dans l\'agenda', 'Rappelle-moi de prendre mon sac demain à 7 h'),
    ('🎵', 'Musique', 'Mets de la musique'),
    ('📱', 'Ouvrir une appli', 'Ouvre Spotify'),
    ('⚡', 'Lancer un raccourci', 'Lance le raccourci Nexo alarme'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final notif = PhoneBridge.notifyState;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('Sur ton téléphone', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (!PhoneBridge.standalone) ...[
          HudPanel(
            hot: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('INSTALLER MON HUB', style: hudLabel(context, color: c.accent)),
                const SizedBox(height: 8),
                const Text(
                  'Dans Safari : touche le bouton Partager (le carré avec une flèche), puis « Sur l\'écran '
                  'd\'accueil » → Ajouter. Mon Hub s\'ouvre alors comme une vraie appli, sans PC, et peut t\'envoyer '
                  'des notifications.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NOTIFICATIONS', style: hudLabel(context, color: c.accent)),
              const SizedBox(height: 8),
              Text(switch (notif) {
                'granted' => 'Activées : minuteurs et messages de tes espaces quand Mon Hub est en arrière-plan.',
                'denied' => 'Refusées. Pour changer : Réglages de l\'iPhone → Notifications → Mon Hub.',
                'absent' when PhoneBridge.ios && !PhoneBridge.standalone =>
                  'Sur iPhone, ajoute d\'abord Mon Hub à l\'écran d\'accueil (au-dessus), puis reviens ici.',
                'absent' => 'Ce navigateur ne sait pas afficher de notifications.',
                _ => 'Pour savoir quand un minuteur sonne ou quand on t\'écrit.',
              }),
              if (notif == 'default') ...[
                const SizedBox(height: 10),
                HudButton(
                  label: 'Activer les notifications',
                  icon: Icons.notifications_active_rounded,
                  onPressed: () async {
                    await PhoneBridge.askNotify();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        HudSectionLabel('CE QUE NEXO FAIT ICI'),
        const SizedBox(height: 6),
        for (final e in can)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Text(e.$1, style: const TextStyle(fontSize: 24)),
            title: Text(e.$2),
            subtitle: Text('« ${e.$3} »'),
            trailing: const Icon(Icons.play_arrow_rounded),
            onTap: () => widget.onTry(e.$3),
          ),
        const SizedBox(height: 12),
        HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ALLER PLUS LOIN : LES RACCOURCIS', style: hudLabel(context, color: c.accent)),
              const SizedBox(height: 8),
              const Text(
                'Apple ne laisse pas une page web régler une alarme, le mode concentration ou la luminosité. '
                'L\'appli Raccourcis, si : crée un raccourci une fois, et Nexo le lance quand tu le demandes.\n\n'
                'Exemple « Nexo alarme » : Raccourcis → + → Ajouter une action → « Créer une alarme » → touche '
                'l\'heure → « Entrée du raccourci ». Renomme-le « Nexo alarme ». Ensuite : « lance le raccourci '
                'Nexo alarme ».\n\n'
                'Ça marche avec n\'importe quel raccourci : « Mode nuit », « Je rentre », « Lampe »…',
              ),
              const SizedBox(height: 10),
              HudButton(
                label: 'Ouvrir Raccourcis',
                icon: Icons.bolt_rounded,
                onPressed: () => openLink('shortcuts://'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ réglages

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _smily = WebSmily.instance;

  void _snack(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  Future<void> _editName() async {
    final ctl = TextEditingController(text: _smily.name);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ton prénom'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK'))],
      ),
    );
    if (v != null) await _smily.finishSetup(name: v);
  }

  Future<void> _editKey() async {
    final ctl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clé Gemini'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Gratuite sur aistudio.google.com (« Get API key »). Elle reste sur ce téléphone.'),
            TextField(controller: ctl, decoration: const InputDecoration(hintText: 'AIza…')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Garder')),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty) await _smily.setGemini(v);
  }

  Future<void> _wipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tout effacer de ce téléphone ?'),
        content: const Text(
          'La discussion, les contacts, les souvenirs et la clé partent de ce téléphone. Ton PC et ton compte en '
          'ligne ne changent pas.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tout effacer')),
        ],
      ),
    );
    if (ok == true) await _smily.forgetAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_smily, Online.instance]),
      builder: (context, _) {
        final o = Online.instance;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text('Réglages', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: const Text('Ton prénom'),
              subtitle: Text(_smily.name.isEmpty ? 'Pas encore' : _smily.name),
              onTap: _editName,
            ),
            ListTile(
              leading: const Icon(Icons.psychology_rounded),
              title: const Text('Le cerveau de Nexo'),
              subtitle: Text(
                _smily.hasBrain ? 'Prêt (Gemini)' : 'Pas encore : relie ton PC ou mets une clé Gemini',
              ),
              onTap: _editKey,
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_rounded),
              title: const Text('Relier mon PC'),
              subtitle: const Text('Vise le QR code du PC, ou colle son code'),
              onTap: () async {
                final said = await pasteLinkCode(context);
                if (said != null) _snack(said);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_rounded),
              title: const Text('Mon compte en ligne'),
              subtitle: Text(
                o.signedIn ? 'Connecté : ${o.email}' : 'Pas connecté (espaces, messages, même compte que le PC)',
              ),
              trailing: o.signedIn
                  ? TextButton(
                      onPressed: () async {
                        Spaces.instance.stop();
                        await o.signOut();
                      },
                      child: const Text('Se déconnecter'),
                    )
                  : null,
              onTap: o.signedIn ? null : () => OnlineSignInSheet.open(context),
            ),
            const SizedBox(height: 12),
            HudSectionLabel('TES CONTACTS (${_smily.contacts.length})'),
            if (_smily.contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Dis à Nexo « le numéro de maman c\'est 06… » : il s\'en souviendra pour appeler ou écrire.',
                  style: TextStyle(color: c.muted),
                ),
              ),
            for (final e in _smily.contacts.entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(e.key),
                subtitle: Text(e.value),
                trailing: IconButton(
                  tooltip: 'Oublier',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _smily.removeContact(e.key),
                ),
              ),
            const SizedBox(height: 12),
            HudSectionLabel('CE QUE NEXO SAIT DE TOI (${_smily.memories.length})'),
            for (var i = 0; i < _smily.memories.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.circle, size: 8),
                title: Text(_smily.memories[i].$2),
                trailing: IconButton(
                  tooltip: 'Oublier',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _smily.removeMemory(i),
                ),
              ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _wipe,
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Tout effacer de ce téléphone'),
            ),
          ],
        );
      },
    );
  }
}
