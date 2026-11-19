import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/pwned.dart';
import '../core/safe_open.dart';
import '../core/security_check.dart';
import 'clicky/clicky.dart';
import 'widgets.dart';

/// Réglages → **Bilan de sécurité** : antivirus, pare-feu, mises à jour,
/// double authentification des comptes, et le bouclier anti-arnaque.
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SecurityPage()));

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  late Future<List<SecurityItem>> _items = _run();

  Future<List<SecurityItem>> _run() {
    final c = ClickyController.instance;
    return SecurityCheck.run(
      pcControl: c.pcControl,
      discord: () async {
        final t = c.hubTools.where((t) => t.name == 'discord_securite').firstOrNull;
        if (t == null) return null;
        final r = await t.run(const {}).timeout(const Duration(seconds: 10));
        return r is Map ? r['double_authentification'] == true : null;
      },
    );
  }

  Future<void> _fix(String target) async {
    if (target.startsWith('http')) {
      await Browser.open(target);
    } else if (!await SafeOpen.launch(target) && mounted) {
      showError(context, 'Impossible d\'ouvrir ce réglage sur ce PC');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bilan de sécurité'),
        actions: [
          IconButton(
            tooltip: 'Refaire le bilan',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() => _items = _run()),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: FutureBuilder<List<SecurityItem>>(
            future: _items,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Je vérifie ton PC…')],
                  ),
                );
              }
              final items = snap.data!;
              final bad = items.where((i) => i.ok == false).length;
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  Card(
                    color: (bad == 0 ? Colors.green : Colors.orange).withValues(alpha: 0.10),
                    child: ListTile(
                      leading: Icon(bad == 0 ? Icons.verified_user_rounded : Icons.gpp_maybe_rounded, color: bad == 0 ? Colors.green : Colors.orange, size: 34),
                      title: Text(bad == 0 ? 'Ton PC est bien protégé' : '$bad point${bad > 1 ? 's' : ''} à régler',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(SecurityCheck.say(items)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final i in items) _tile(theme, i),
                  const SizedBox(height: 16),
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.shield_rounded, color: Color(0xFF2B6CFF)),
                      title: Text('Bouclier anti-arnaque : toujours actif'),
                      subtitle: Text(
                        'Mon Hub vérifie les liens et fichiers reçus sur Discord et par mail (faux Nitro ou Robux gratuits, '
                        'sites sosies, espions d\'adresse IP, « teste mon jeu » avec un .exe) et te prévient. Un faux site ne '
                        's\'ouvre pas sans ton accord. Demande aussi à Clicky : « ce lien est sûr ? » (après l\'avoir copié).',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const PwnedCheckCard(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tile(ThemeData theme, SecurityItem i) {
    final (icon, color) = switch (i.ok) {
      true => (Icons.check_circle_rounded, Colors.green),
      false => (Icons.error_rounded, Colors.orange),
      null => (Icons.help_rounded, Colors.grey),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(i.title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(i.detail),
          trailing: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (i.fix != null && i.ok != true)
                TextButton(onPressed: () => _fix(i.fix!), child: Text(i.fixLabel)),
              if (i.manual)
                FilterChip(
                  label: const Text('C\'est fait'),
                  selected: i.ok == true,
                  onSelected: (v) async {
                    await SecurityCheck.setDone(i.id, v);
                    if (mounted) setState(() => _items = _run());
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « Mon mot de passe a-t-il fuité ? » : vérifié sans jamais l'envoyer
/// (seulement les 5 premiers caractères de son empreinte), et jamais gardé.
class PwnedCheckCard extends StatefulWidget {
  const PwnedCheckCard({super.key});

  @override
  State<PwnedCheckCard> createState() => _PwnedCheckCardState();
}

class _PwnedCheckCardState extends State<PwnedCheckCard> {
  final _c = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _result;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final p = _c.text;
    if (p.isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    String r;
    try {
      r = PwnedPasswords.advice(await PwnedPasswords.count(p));
    } catch (_) {
      r = 'Vérification impossible pour l\'instant (pas d\'internet ?).';
    }
    // Le mot de passe ne reste pas à l'écran.
    _c.clear();
    if (mounted) {
      setState(() {
        _busy = false;
        _result = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.key_rounded, color: Color(0xFF2B6CFF)),
                const SizedBox(width: 10),
                Expanded(child: Text('Mes mots de passe ont-ils fuité ?', style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Tape un mot de passe que tu utilises : je le compare aux milliards de mots de passe déjà volés, sans '
              'jamais l\'envoyer (seul un petit bout de son empreinte part, et il n\'est jamais enregistré).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _c,
                    obscureText: _hide,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => _check(),
                    decoration: InputDecoration(
                      hintText: 'Mot de passe à vérifier',
                      suffixIcon: IconButton(
                        tooltip: _hide ? 'Afficher' : 'Cacher',
                        icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _check,
                  child: _busy
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Vérifier'),
                ),
              ],
            ),
            if (_result != null) ...[const SizedBox(height: 10), Text(_result!)],
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => Browser.open('https://haveibeenpwned.com/'),
              icon: const Icon(Icons.alternate_email_rounded),
              label: const Text('Et mon adresse mail ? (vérifier sur haveibeenpwned.com)'),
            ),
          ],
        ),
      ),
    );
  }
}
