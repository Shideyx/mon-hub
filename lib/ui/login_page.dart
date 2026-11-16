import 'package:material_ui/material_ui.dart';

import '../core/session.dart';

/// Page d'accueil : se connecter à son compte Mon Hub ou en créer un.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _login = TextEditingController();
  final _name = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  late bool _create = AppSession.instance.accounts.isEmpty;
  bool _remember = true;
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_login, _name, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_create) {
        if (_pass.text != _pass2.text) throw 'Les deux mots de passe ne sont pas identiques';
        await AppSession.instance.register(_login.text, _name.text, _pass.text);
      } else {
        await AppSession.instance.signIn(_login.text, _pass.text, remember: _remember);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = AppSession.instance;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    cs.primaryContainer.withValues(alpha: 0.7),
                    cs.surface,
                    cs.tertiaryContainer.withValues(alpha: 0.6),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(child: ThemeModeButton(session: session)),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  elevation: 0,
                  color: cs.surfaceContainerLow,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Image.asset('assets/logo.png', width: 72, height: 72),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Mon Hub',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _create
                                ? 'Crée ton compte pour retrouver tes applis au même endroit'
                                : 'Connecte-toi à ton compte',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _login,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Identifiant',
                              prefixIcon: Icon(Icons.alternate_email_rounded),
                            ),
                          ),
                          if (_create) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Prénom (facultatif)',
                                prefixIcon: Icon(Icons.person_rounded),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            controller: _pass,
                            obscureText: _hide,
                            autofillHints: [
                              _create ? AutofillHints.newPassword : AutofillHints.password,
                            ],
                            textInputAction: _create ? TextInputAction.next : TextInputAction.done,
                            onSubmitted: (_) => _create ? null : _submit(),
                            decoration: InputDecoration(
                              labelText: 'Mot de passe',
                              prefixIcon: const Icon(Icons.lock_rounded),
                              suffixIcon: IconButton(
                                tooltip: _hide ? 'Afficher' : 'Masquer',
                                icon: Icon(
                                  _hide ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                ),
                                onPressed: () => setState(() => _hide = !_hide),
                              ),
                            ),
                          ),
                          if (_create) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _pass2,
                              obscureText: _hide,
                              onSubmitted: (_) => _submit(),
                              decoration: const InputDecoration(
                                labelText: 'Confirme le mot de passe',
                                prefixIcon: Icon(Icons.lock_outline_rounded),
                              ),
                            ),
                          ] else
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text('Rester connecté'),
                              value: _remember,
                              onChanged: (v) => setState(() => _remember = v ?? true),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_error!, style: TextStyle(color: cs.error)),
                            ),
                          const SizedBox(height: 20),
                          FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.5),
                                  )
                                : Text(_create ? 'Créer mon compte' : 'Se connecter'),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => setState(() {
                              _create = !_create;
                              _error = null;
                            }),
                            child: Text(
                              _create
                                  ? 'J\'ai déjà un compte : me connecter'
                                  : 'Nouveau ? Créer un compte',
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Ton compte et tes données restent sur cet appareil. '
                            'Pour les retrouver sur un autre : Réglages → Exporter.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bouton soleil / lune pour passer du mode clair au mode sombre.
class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({super.key, required this.session});
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? 'Mode clair' : 'Mode sombre',
      icon: Icon(dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
      onPressed: () => session.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
    );
  }
}
