import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/account_sync.dart';
import '../../core/browser.dart';
import '../../core/module_store.dart';
import '../../core/online/clicky_chat.dart';
import '../../core/online/online.dart';
import '../../core/online/online_account.dart';
import '../../core/online/spaces.dart';
import '../hud/hud.dart';

/// Réglages → **Compte en ligne** : le serveur (ton projet Supabase), ton
/// compte (même compte sur tous tes appareils), ton profil et Nexo.
class OnlinePage extends StatefulWidget {
  const OnlinePage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const OnlinePage()));

  @override
  State<OnlinePage> createState() => _OnlinePageState();
}

class _OnlinePageState extends State<OnlinePage> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _code = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _name = TextEditingController();
  final _handle = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    final o = Online.instance;
    if (o.signedIn) unawaited(o.loadProfile().then((_) => _fillProfile()));
  }

  void _fillProfile() {
    final p = Online.instance.profile;
    if (!mounted || p == null) return;
    _name.text = '${p['name'] ?? ''}';
    _handle.text = '${p['handle'] ?? ''}';
  }

  @override
  void dispose() {
    for (final c in [_url, _key, _code, _email, _pass, _name, _handle]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = Online.explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveServer() => _run(() async {
    final fromCode = OnlineServer.fromCode(_code.text);
    if (fromCode != null) {
      await Online.instance.setServer(fromCode);
      return;
    }
    final u = OnlineServer.cleanUrl(_url.text);
    if (u == null) throw 'L\'adresse du projet ressemble à https://abcdefgh.supabase.co';
    if (!OnlineServer.looksLikeKey(_key.text)) {
      throw 'Colle la clé « anon public » (une longue suite de lettres avec des points).';
    }
    await Online.instance.setServer(OnlineServer(u, _key.text.trim()));
  });

  Future<void> _putOnline() => _run(() async {
    final ok = await OnlineAccount.putOnline(_email.text, _pass.text);
    _pass.clear();
    if (!ok) {
      _info = 'Presque fini : ouvre le mail envoyé par Supabase, clique le lien, puis appuie encore sur le bouton.';
      return;
    }
    _fillProfile();
    unawaited(Spaces.instance.start());
    _info = 'Ton compte est en ligne. Sur un autre appareil : page de connexion → « Mon compte en ligne ».';
  });

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('COMPTE EN LIGNE')),
      body: ListenableBuilder(
        listenable: Listenable.merge([Online.instance, AccountSync.instance]),
        builder: (context, _) {
          final o = Online.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Un compte (ton adresse mail) pour retrouver tout ton Mon Hub sur tes autres appareils '
                        '(PC, Android, iPhone) et partager des espaces, des tâches et des discussions avec tes amis.',
                        style: TextStyle(color: c.muted, height: 1.45),
                      ),
                      const SizedBox(height: 16),
                      _serverPanel(context, o),
                      const SizedBox(height: 16),
                      if (o.configured) _accountPanel(context, o),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: TextStyle(color: c.bad)),
                      ],
                      if (_info != null) ...[const SizedBox(height: 12), Text(_info!, style: TextStyle(color: c.ok))],
                      const SizedBox(height: 16),
                      Text(
                        'Vie privée : la copie de ton compte est chiffrée sur ton appareil avec ton mot de passe — le '
                        'serveur ne peut pas la lire, et ne reçoit jamais ton mot de passe. Ce que Nexo voit à l\'écran, '
                        'ton temps d\'écran et tes guetteurs restent sur ton PC. Seul ce que tu mets dans un espace '
                        'partagé est visible par ses membres.',
                        style: TextStyle(color: c.dim, fontSize: 12, height: 1.45),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _serverPanel(BuildContext context, Online o) {
    final c = HudColors.of(context);
    final s = o.server;
    if (s != null) {
      return HudPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('[01] SERVEUR', style: hudLabel(context)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.cloud_done_rounded, color: c.ok),
                const SizedBox(width: 10),
                Expanded(child: Text(o.builtIn ? 'Le serveur de Mon Hub est prêt.' : s.url, style: hudMono(context))),
              ],
            ),
            if (!o.builtIn) ...[
              const SizedBox(height: 12),
              Text(
                'Pour que tes amis rejoignent tes espaces, ils doivent utiliser le même serveur : envoie-leur ce code '
                '(Réglages → Compte en ligne → « J\'ai un code »).',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  HudButton(
                    label: 'Copier le code du serveur',
                    icon: Icons.copy_rounded,
                    compact: true,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: s.code));
                      if (mounted) setState(() => _info = 'Code copié : colle-le à tes amis.');
                    },
                  ),
                  HudButton(
                    label: 'Changer de serveur',
                    compact: true,
                    onPressed: _busy ? null : () => _run(() => Online.instance.clearServer()),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    }
    Widget step(String n, String text, [List<Widget> actions = const []]) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(n, style: hudTitle(context, size: 20, color: c.accentText)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(height: 1.4)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return HudPanel(
      hot: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('[01] TON SERVEUR (5 MINUTES, UNE SEULE FOIS)', style: hudLabel(context, color: c.accentText)),
          const SizedBox(height: 6),
          Text(
            'Un ami t\'a envoyé un code « MONHUB-SERVEUR » ? Colle-le ici, c\'est tout.',
            style: TextStyle(color: c.muted),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'J\'ai un code (MONHUB-SERVEUR:…)',
              prefixIcon: Icon(Icons.vpn_key_rounded),
            ),
            onSubmitted: (_) => _saveServer(),
          ),
          const SizedBox(height: 18),
          Text('Sinon, crée le tien (gratuit) :', style: hudLabel(context)),
          const SizedBox(height: 12),
          step('01', 'Crée un compte puis un projet sur supabase.com (le nom que tu veux, région « Europe »).', [
            HudButton(
              label: 'Ouvrir Supabase',
              icon: Icons.open_in_new_rounded,
              compact: true,
              onPressed: () => Browser.open('https://supabase.com/dashboard/new'),
            ),
          ]),
          step('02', 'Copie le script de la base, puis dans ton projet : SQL Editor → colle → Run.', [
            HudButton(
              label: 'Copier le script',
              icon: Icons.copy_rounded,
              compact: true,
              primary: true,
              onPressed: () async {
                final sql = await rootBundle.loadString('supabase/schema.sql');
                await Clipboard.setData(ClipboardData(text: sql));
                if (mounted) setState(() => _info = 'Script copié : colle-le dans SQL Editor, puis Run.');
              },
            ),
            HudButton(
              label: 'Ouvrir SQL Editor',
              icon: Icons.open_in_new_rounded,
              compact: true,
              onPressed: () => Browser.open('https://supabase.com/dashboard/project/_/sql/new'),
            ),
          ]),
          step(
            '03',
            'Plus simple : Authentication → Sign In / Providers → Email → décoche « Confirm email » (sinon il '
                'faudra cliquer un lien reçu par mail à la création du compte).',
          ),
          step(
            '04',
            'Project Settings → API (ou « Connect ») : copie « Project URL » et la clé « anon public », colle-les ici.',
          ),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Project URL (https://….supabase.co)',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _key,
            decoration: const InputDecoration(labelText: 'Clé anon public', prefixIcon: Icon(Icons.key_rounded)),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: HudButton(label: 'Enregistrer le serveur', primary: true, onPressed: _busy ? null : _saveServer),
          ),
        ],
      ),
    );
  }

  Widget _accountPanel(BuildContext context, Online o) {
    final c = HudColors.of(context);
    final sync = AccountSync.instance;
    if (!o.signedIn) {
      return HudPanel(
        hot: true,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('[02] METTRE MON COMPTE EN LIGNE', style: hudLabel(context, color: c.accentText)),
            const SizedBox(height: 6),
            Text(
              'Ton adresse mail + le mot de passe de ton compte Mon Hub (le même servira sur tous tes appareils).',
              style: TextStyle(color: c.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Adresse mail',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Mot de passe de Mon Hub',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
              onSubmitted: (_) => _putOnline(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                HudButton(
                  label: 'Mettre en ligne',
                  primary: true,
                  icon: Icons.cloud_upload_rounded,
                  onPressed: _busy ? null : _putOnline,
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final last = sync.lastSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('[02] MON COMPTE EN LIGNE', style: hudLabel(context)),
              const SizedBox(height: 8),
              Text(o.email ?? '', style: hudTitle(context, size: 20)),
              const SizedBox(height: 8),
              Text(
                sync.online
                    ? (sync.busy
                          ? 'Synchronisation…'
                          : sync.needsPassword
                          ? 'Ton mot de passe a changé ailleurs : Réglages → Mes appareils pour le retaper.'
                          : sync.error ??
                                (last == null
                                    ? 'Pas encore synchronisé.'
                                    : 'Synchronisé à ${last.hour}h${last.minute.toString().padLeft(2, '0')} — tout ton compte, chiffré.'))
                    : 'Connecté, mais ton compte n\'est pas encore copié en ligne.',
                style: TextStyle(color: sync.error != null ? c.bad : c.muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (sync.online)
                    HudButton(
                      label: 'Synchroniser maintenant',
                      icon: Icons.sync_rounded,
                      compact: true,
                      onPressed: sync.busy ? null : () => sync.syncNow(),
                    )
                  else
                    HudButton(
                      label: 'Copier mon compte en ligne',
                      primary: true,
                      compact: true,
                      onPressed: _busy ? null : () => _run(() => sync.enable(mail: Online.syncMail(o.email ?? ''))),
                    ),
                  HudButton(
                    label: 'Se déconnecter',
                    compact: true,
                    onPressed: _busy ? null : () => _run(() => OnlineAccount.signOutHere()),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        HudPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('[03] MON PROFIL (CE QUE LES AUTRES VOIENT)', style: hudLabel(context)),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nom affiché', prefixIcon: Icon(Icons.badge_rounded)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _handle,
                decoration: const InputDecoration(
                  labelText: 'Pseudo (pour qu\'on t\'écrive : @pseudo)',
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: HudButton(
                  label: 'Enregistrer',
                  compact: true,
                  primary: true,
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await o.saveProfile(name: _name.text, handle: _handle.text);
                          await ModuleStore.prefs.setString('hub.name', _name.text.trim());
                          _info = 'Profil enregistré.';
                        }),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        HudPanel(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: ClickyChat.withOthers,
            onChanged: (v) async {
              await ClickyChat.setWithOthers(v);
              if (mounted) setState(() {});
            },
            title: const Text('Mon Nexo peut parler avec les Nexo des autres'),
            subtitle: Text(
              'Dans les espaces qui l\'autorisent. Il ne fait aucune action et ne dit rien de privé ; au plus '
              '${ClickyChat.perDay} réponses par jour. « @clicky … » dans tes messages : ton Nexo répond toujours.',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
