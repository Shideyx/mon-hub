import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/online/online.dart';
import '../../core/online/online_account.dart';
import '../../core/session.dart';
import '../hud/hud.dart';

/// Page de connexion → **« Mon compte en ligne »** : ton adresse + ton mot
/// de passe, et ton Mon Hub arrive avec tout (modules, réglages, connexions,
/// historiques). Pas encore de compte relié à cette adresse : il est créé ici
/// et mis en ligne.
class OnlineSignInView extends StatefulWidget {
  const OnlineSignInView({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<OnlineSignInView> createState() => _OnlineSignInViewState();
}

class _OnlineSignInViewState extends State<OnlineSignInView> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  bool _canCreate = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on NoOnlineCopy catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _canCreate = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = Online.explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _server() => _run(() async {
    final s = OnlineServer.fromCode(_code.text);
    if (s == null) throw 'Colle le code « MONHUB-SERVEUR:… » reçu (ou règle le serveur depuis ton autre appareil : Réglages → Compte en ligne).';
    await Online.instance.setServer(s);
  });

  Future<void> _join() => _run(() => OnlineAccount.join(_email.text, _pass.text));

  /// Nouveau compte Mon Hub ici, avec cette adresse, puis en ligne.
  Future<void> _create() => _run(() async {
    final email = _email.text.trim();
    final password = _pass.text;
    if (password.length < 6) throw 'Le mot de passe doit faire au moins 6 caractères.';
    var login = Online.suggestHandle(email);
    final taken = AppSession.instance.accounts.keys.toSet();
    var i = 2;
    while (taken.contains(login)) {
      login = '${Online.suggestHandle(email)}$i';
      i++;
    }
    await AppSession.instance.register(login, '', password);
    // La page de connexion disparaît : la mise en ligne continue en fond
    // (son état est dans Réglages → Compte en ligne).
    unawaited(OnlineAccount.putOnline(email, password).catchError((Object _) => false));
  });

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Online.instance,
      builder: (context, _) {
        final o = Online.instance;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!o.configured) ...[
              Text(
                'D\'abord le serveur : colle le code « MONHUB-SERVEUR » (sur ton autre appareil : Réglages → Compte en '
                'ligne → Copier le code du serveur).',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _code,
                decoration: const InputDecoration(labelText: 'Code du serveur', prefixIcon: Icon(Icons.vpn_key_rounded)),
                onSubmitted: (_) => _server(),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy ? null : _server, child: const Text('Utiliser ce serveur')),
            ] else ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Adresse mail', prefixIcon: Icon(Icons.alternate_email_rounded)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: _hide,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _join(),
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
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _busy ? null : _join,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Text('Retrouver mon Mon Hub'),
              ),
              if (_canCreate) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _busy ? null : _create, child: const Text('Créer mon compte avec cette adresse')),
              ],
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: c.bad))),
            const SizedBox(height: 8),
            TextButton(onPressed: _busy ? null : widget.onBack, child: const Text('Retour')),
            Text(
              'Le serveur ne reçoit jamais ton mot de passe, et ta copie est chiffrée avec : il ne peut pas la lire.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.dim),
            ),
          ],
        );
      },
    );
  }
}
