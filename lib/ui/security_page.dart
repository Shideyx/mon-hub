import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
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
