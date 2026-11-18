import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/account_sync.dart';
import '../core/google_auth.dart';
import '../core/module_store.dart';
import 'google_setup.dart';
import 'widgets.dart';

/// « à l'instant », « il y a 3 min », « il y a 2 h », « le 12/11 ».
String syncAgo(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'à l\'instant';
  if (d.inHours < 1) return 'il y a ${d.inMinutes} min';
  if (d.inDays < 1) return 'il y a ${d.inHours} h';
  return 'le ${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';
}

/// Connexion Google avec l'accès au dossier caché de Mon Hub (où vit la
/// copie du compte). Renvoie l'adresse, ou null si on a annulé.
Future<String?> connectGoogleForSync(BuildContext context) async {
  String? email;
  if (!GoogleAuth.available) {
    // Connexion Google pas encore activée sur cet appareil : l'écran qui
    // explique (il connecte le compte à la fin).
    final before = GoogleAuth.accounts.toSet();
    await GoogleSetupPage.open(context);
    final now = GoogleAuth.accounts;
    email = now.where((a) => !before.contains(a)).firstOrNull ?? now.where(GoogleAuth.canSync).firstOrNull;
    if (email == null) return null;
  } else {
    email = await GoogleAuth.signIn();
  }
  final drive = ModuleStore()..bind('drive');
  if (drive.getJson<String>('account') == null) await drive.setJson('account', email);
  if (!GoogleAuth.canSync(email)) {
    throw 'Google n\'a pas donné l\'accès au dossier de Mon Hub : recommence et laisse cochée '
        'la case « données de configuration dans Google Drive ».';
  }
  return email;
}

/// Le compte Google qui garde la copie : un compte déjà connecté (s'il a
/// l'accès au dossier caché), sinon une connexion.
Future<String?> pickSyncGoogle(BuildContext context) async {
  final all = GoogleAuth.accounts;
  if (all.isNotEmpty) {
    final choice = all.length == 1 && GoogleAuth.canSync(all.first)
        ? all.first
        : await showDialog<String>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('Quel compte Google garde ton compte Mon Hub ?'),
              children: [
                for (final a in all)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, a),
                    child: ListTile(
                      leading: const Icon(Icons.account_circle_rounded),
                      title: Text(a),
                      subtitle: GoogleAuth.canSync(a)
                          ? null
                          : const Text('Google va te redemander ton accord une fois'),
                    ),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, ''),
                  child: const ListTile(
                    leading: Icon(Icons.add_rounded),
                    title: Text('Un autre compte Google'),
                  ),
                ),
              ],
            ),
          );
    if (choice == null) return null;
    if (choice.isNotEmpty && GoogleAuth.canSync(choice)) return choice;
  }
  if (!context.mounted) return null;
  return connectGoogleForSync(context);
}

/// Demande le mot de passe Mon Hub.
Future<String?> askMonHubPassword(BuildContext context, {required String message}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.lock_rounded),
      title: const Text('Ton mot de passe Mon Hub'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Mot de passe'),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('OK')),
      ],
    ),
  );
}

const _spinner = SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5));

/// Réglages → Mes appareils : activer la synchro, son état, l'arrêter.
class AccountSyncSection extends StatelessWidget {
  const AccountSyncSection({super.key});

  static Future<void> _enable(BuildContext context) async {
    try {
      final mail = await pickSyncGoogle(context);
      if (mail == null || !context.mounted) return;
      final pass = await askMonHubPassword(
        context,
        message: 'Il chiffre la copie de ton compte. Sur ton autre appareil, tu le taperas pour la retrouver.',
      );
      if (pass == null || !context.mounted) return;
      await AccountSync.instance.enable(mail: mail, password: pass);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ton compte est synchronisé avec $mail ✅')),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> _unlock(BuildContext context) async {
    final pass = await askMonHubPassword(
      context,
      message: 'La copie de ton compte a été chiffrée avec ton mot de passe sur un autre appareil : '
          'tape-le pour reprendre la synchro.',
    );
    if (pass == null || !context.mounted) return;
    try {
      await AccountSync.instance.unlock(pass);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> _reconnect(BuildContext context) async {
    try {
      final mail = await connectGoogleForSync(context);
      if (mail != null) await AccountSync.instance.syncNow();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  static Future<void> _disable(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.cloud_off_rounded),
        title: const Text('Arrêter la synchronisation ?'),
        content: const Text(
          'Ce PC garde ton compte tel qu\'il est, mais ne reçoit plus les changements de tes autres '
          'appareils (et ne leur envoie plus les siens).\n\n'
          'Tu peux aussi supprimer la copie gardée dans ton Google Drive : tes autres appareils '
          'gardent leur compte, mais pour en retrouver un nouveau il faudra réactiver la synchro.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Arrêter et supprimer la copie')),
          FilledButton(onPressed: () => Navigator.pop(c, 'stop'), child: const Text('Arrêter')),
        ],
      ),
    );
    if (choice == null) return;
    try {
      await AccountSync.instance.disable(deleteCopy: choice == 'delete');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AccountSync.instance,
    builder: (context, _) {
      final s = AccountSync.instance;
      final cs = Theme.of(context).colorScheme;
      if (!s.enabled) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ListTile(
              leading: Icon(Icons.devices_rounded),
              title: Text('Mon compte sur tous mes appareils'),
              subtitle: Text(
                'Connecte-toi sur un autre PC et retrouve tout (modules, connexions, historiques, '
                'carnet, révisions…) sans rien exporter, et les changements suivent tout seuls. '
                'Ton compte est gardé dans ton Google Drive, dans un dossier caché réservé à Mon Hub, '
                'chiffré avec ton mot de passe Mon Hub : ni Google ni personne d\'autre ne peut le lire.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: FilledButton.icon(
                icon: s.busy ? _spinner : const Icon(Icons.cloud_sync_rounded),
                label: const Text('Activer la synchronisation'),
                onPressed: s.busy ? null : () => _enable(context),
              ),
            ),
          ],
        );
      }
      final last = s.lastSync;
      final problem = s.error != null || s.needsPassword;
      final status = s.busy
          ? 'Synchronisation…'
          : s.needsPassword
          ? 'En pause : retape ton mot de passe Mon Hub'
          : s.error ?? (last == null ? 'Pas encore synchronisé' : 'À jour · ${syncAgo(last)}');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              problem ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
              color: problem ? cs.error : cs.primary,
            ),
            title: Text('Synchronisé avec ${s.email}'),
            subtitle: Text(status, style: s.error != null ? TextStyle(color: cs.error) : null),
            onTap: s.needsPassword ? () => _unlock(context) : null,
            trailing: s.busy
                ? _spinner
                : IconButton(
                    tooltip: 'Synchroniser maintenant',
                    icon: const Icon(Icons.sync_rounded),
                    onPressed: s.needsPassword ? () => _unlock(context) : () => unawaited(s.syncNow()),
                  ),
          ),
          if (s.error != null && !s.busy)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: TextButton.icon(
                icon: const Icon(Icons.login_rounded),
                label: const Text('Reconnecter Google'),
                onPressed: () => _reconnect(context),
              ),
            ),
          const ListTile(
            leading: Icon(Icons.add_to_queue_rounded),
            title: Text('Sur ton autre appareil'),
            subtitle: Text(
              'Installe Mon Hub, puis sur la page de connexion : « Retrouver mon compte » → le même '
              'compte Google → ton mot de passe Mon Hub. Tout arrive tout seul.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: TextButton.icon(
              icon: const Icon(Icons.cloud_off_rounded),
              label: const Text('Arrêter la synchronisation'),
              onPressed: s.busy ? null : () => _disable(context),
            ),
          ),
        ],
      );
    },
  );
}

/// Page de connexion → « Retrouver mon compte » : le compte d'un autre
/// appareil, gardé dans le Google Drive.
class JoinAccountView extends StatefulWidget {
  const JoinAccountView({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<JoinAccountView> createState() => _JoinAccountViewState();
}

class _JoinAccountViewState extends State<JoinAccountView> {
  final _pass = TextEditingController();
  String? _mail;
  List<CloudCopy>? _copies;
  CloudCopy? _chosen;
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // La connexion Google faite ici se range dans le compte qui arrive.
    AccountSync.instance.beginJoin();
  }

  @override
  void dispose() {
    _pass.dispose();
    // Retour (ou fermeture) sans avoir fini : on efface ce qui a été préparé.
    unawaited(AccountSync.instance.cancelJoin());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() => _run(() async {
    final mail = await connectGoogleForSync(context);
    if (mail == null) return;
    _mail = mail;
    _chosen = null;
    await _find();
  });

  Future<void> _find() async {
    final list = await AccountSync.copies(_mail!);
    if (!mounted) return;
    setState(() {
      _copies = list;
      if (list.length == 1) _chosen = list.first;
    });
  }

  Future<void> _join() => _run(() async {
    final copy = _chosen;
    if (copy == null || _mail == null) return;
    if (_pass.text.isEmpty) throw 'Tape ton mot de passe Mon Hub';
    await AccountSync.instance.join(mail: _mail!, copy: copy, password: _pass.text);
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(color: cs.onSurfaceVariant);
    final copies = _copies;
    final chosen = _chosen;
    final children = <Widget>[];
    if (_mail == null) {
      children.addAll([
        Text(
          'Sur ton autre appareil, active d\'abord Réglages → Mes appareils → « Activer la '
          'synchronisation ». Ensuite, connecte ici le même compte Google.',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: _busy ? _spinner : const Icon(Icons.account_circle_rounded),
          label: const Text('Se connecter avec Google'),
          onPressed: _busy ? null : _google,
        ),
      ]);
    } else if (copies == null || copies.isEmpty) {
      children.addAll([
        Text(
          copies == null
              ? 'Recherche dans le Drive de $_mail…'
              : 'Aucun compte Mon Hub dans le Drive de $_mail. Sur ton autre appareil : Réglages → '
                    'Mes appareils → « Activer la synchronisation » (avec ce compte Google), puis réessaie.',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          icon: _busy ? _spinner : const Icon(Icons.refresh_rounded),
          label: const Text('Réessayer'),
          onPressed: _busy ? null : () => _run(_find),
        ),
        TextButton(onPressed: _busy ? null : _google, child: const Text('Un autre compte Google')),
      ]);
    } else if (chosen == null) {
      children.addAll([
        Text('Quel compte ?', textAlign: TextAlign.center, style: muted),
        const SizedBox(height: 8),
        for (final c in copies)
          ListTile(
            leading: const Icon(Icons.person_rounded),
            title: Text(c.login ?? c.name),
            subtitle: c.modified == null ? null : Text('Mis à jour ${syncAgo(c.modified!.toLocal())}'),
            onTap: () => setState(() => _chosen = c),
          ),
      ]);
    } else {
      children.addAll([
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_rounded),
          title: Text(chosen.login ?? chosen.name),
          subtitle: Text('Gardé dans le Drive de $_mail'),
          trailing: copies.length > 1
              ? TextButton(onPressed: () => setState(() => _chosen = null), child: const Text('Changer'))
              : null,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pass,
          obscureText: _hide,
          autofocus: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _busy ? null : _join(),
          decoration: InputDecoration(
            labelText: 'Mot de passe Mon Hub',
            prefixIcon: const Icon(Icons.lock_rounded),
            suffixIcon: IconButton(
              tooltip: _hide ? 'Afficher' : 'Masquer',
              icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _join,
          child: _busy ? _spinner : const Text('Retrouver mon compte'),
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Récupération de ton compte…', textAlign: TextAlign.center, style: muted),
          ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: _busy ? null : widget.onBack, child: const Text('Retour')),
      ],
    );
  }
}
