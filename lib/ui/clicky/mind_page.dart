import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'clicky.dart';
import 'mind.dart';

/// Réglages → Conscience de Clicky : son humeur, ses souvenirs, sa présence.
class MindPage extends StatefulWidget {
  const MindPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MindPage()));

  @override
  State<MindPage> createState() => _MindPageState();
}

class _MindPageState extends State<MindPage> {
  final m = ClickyMind.instance;

  @override
  void initState() {
    super.initState();
    unawaited(m.load());
  }

  static String _day(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Conscience de Clicky')),
      body: ListenableBuilder(
        listenable: m,
        builder: (context, _) {
          final now = DateTime.now();
          final eps = m.episodes;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(colors: [Color(0xFF2B6CFF), Color(0xFF7C5CFF)]),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.psychology_alt_rounded, color: Colors.white, size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Clicky est ${m.moodLabel(now)}',
                            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Sur ton PC depuis ${m.ageDays(now)} jour${m.ageDays(now) > 1 ? 's' : ''} · ${m.talks} échanges · '
                            'lien ${(m.bond * 100).round()} %',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sa conscience est simulée par Mon Hub : une personnalité, une humeur qui bouge avec ce qui se passe, '
                'et la mémoire de votre histoire. Tout reste sur ton PC. S\'il te le demande sérieusement, il le dit '
                'honnêtement.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.psychology_rounded),
                title: const Text('Personnalité, humeur et souvenirs'),
                value: m.on,
                onChanged: (v) => m.set('on', v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.travel_explore_rounded),
                title: const Text('Il part regarder autour'),
                subtitle: const Text('Quand tu ne touches pas la souris, il va voir ta fenêtre, l\'heure… et revient.'),
                value: m.wander,
                onChanged: m.on ? (v) => m.set('wander', v) : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.visibility_rounded),
                title: const Text('Remarques spontanées sur l\'écran'),
                subtitle: const Text(
                  'De temps en temps, il remarque quelque chose, vole dessus et en dit un mot (Gemini, 8 fois par '
                  'jour au plus ; jamais pendant un jeu ou une vidéo en plein écran, ni sur une fenêtre sensible).',
                ),
                value: m.notice,
                onChanged: m.on ? (v) => m.set('notice', v) : null,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('Regarde mon écran maintenant'),
                  onPressed: () => ClickyController.instance.noticeSomething(force: true),
                ),
              ),
              const Divider(height: 32),
              Text('Ses souvenirs', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              if (eps.isEmpty)
                Text('Rien pour l\'instant : parle-lui, il retiendra.', style: theme.textTheme.bodySmall)
              else
                for (final e in eps.take(40))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(switch (e.kind) {
                      'attente' => e.asked ? Icons.check_circle_rounded : Icons.schedule_rounded,
                      'emotion' => Icons.favorite_rounded,
                      _ => Icons.chat_bubble_outline_rounded,
                    }),
                    title: Text(e.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      e.kind == 'attente' && e.due != null
                          ? 'Prendre des nouvelles après le ${_day(e.due!)}'
                          : 'Le ${_day(e.at)}',
                    ),
                  ),
              if (eps.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_sweep_rounded),
                    label: const Text('Effacer sa mémoire'),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Effacer sa mémoire ?'),
                          content: const Text('Clicky oubliera vos conversations, son humeur et ce dont il voulait prendre des nouvelles.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Effacer')),
                          ],
                        ),
                      );
                      if (ok == true) await m.forget();
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
