import 'senses_page.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../modules/claude/claude_module.dart';
import 'assistant_view.dart';
import 'clicky.dart';
import 'clicky_desktop.dart';
import 'browser_setup_page.dart';
import 'course_page.dart';
import 'skills.dart';
import 'tutorial.dart';
import 'mic_test.dart';
import 'mind_page.dart';
import 'settings.dart';

/// **Tous les réglages de Smily, au même endroit**, rangés par rubrique
/// (avant : éparpillés entre Réglages, le cerveau et une longue liste).
/// En haut : l'essentiel ; puis une rubrique par sujet ; et une recherche.
class ClickySettingsPage extends StatefulWidget {
  const ClickySettingsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ClickySettingsPage()));

  @override
  State<ClickySettingsPage> createState() => _ClickySettingsPageState();
}

/// Une rubrique qui ouvre sa page (ou un autre écran).
class _Entry {
  const _Entry(this.title, this.subtitle, this.icon, this.color, this.open);
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final void Function(BuildContext context) open;
}

class _ClickySettingsPageState extends State<ClickySettingsPage> {
  final search = TextEditingController();
  String q = '';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  /// Les rubriques, rangées par thème (titre du thème → rubriques).
  List<(String, List<_Entry>)> _groups(ClickyController c) {
    ClickySection sec(String id) => ClickySection.byId(id)!;
    _Entry page(String id) {
      final s = sec(id);
      return _Entry(s.title, s.subtitle, s.icon, s.color, (ctx) => _SectionPage.open(ctx, s));
    }

    return [
      (
        'Bien démarrer',
        [
          _Entry(
            'Ce que Smily sait faire',
            'Tout ce que tu peux lui demander, par thème, avec des phrases à essayer en un clic',
            Icons.auto_awesome_rounded,
            const Color(0xFF7C5CFF),
            (ctx) => ClickySkillsPage.open(ctx),
          ),
          _Entry(
            'Revoir la visite guidée',
            'La présentation animée de Smily, avec ses nouveautés',
            Icons.slideshow_rounded,
            const Color(0xFF0EA5E9),
            (ctx) => ClickyTutorial.show(ctx),
          ),
        ],
      ),
      (
        'Lui parler',
        [
          _Entry(
            'Cerveau',
            switch (c.provider) {
              'claudecode' => 'Ton abonnement Claude (Claude Pro)',
              'ollama' => 'Ollama, une IA sur ton PC',
              _ => 'Clé API Claude, modèle',
            },
            Icons.psychology_rounded,
            const Color(0xFFD97757),
            (ctx) => ClaudeModule.showBrain(ctx),
          ),
          page('voice'),
          page('listen'),
        ],
      ),
      (
        'Ce qu\'il fait pour toi',
        [
          _Entry(
            'Smily prend les devants',
            'Rappels de devoirs, plan de la journée, objectifs, idées (toujours avec ton accord)',
            Icons.lightbulb_rounded,
            const Color(0xFFF59E0B),
            (ctx) => AssistantPage.open(ctx),
          ),
          _Entry(
            'Ses yeux et ses oreilles',
            'Il voit ton écran et entend le son du PC (sur le PC), presse-papier malin, « préviens-moi quand… »',
            Icons.visibility_rounded,
            const Color(0xFF0EA5E9),
            (ctx) => SensesPage.open(ctx),
          ),
          page('topo'),
          page('teach'),
          _Entry(
            'Écouter un cours',
            'Il écoute tout le cours et te fait le compte rendu',
            Icons.mic_external_on_rounded,
            const Color(0xFFE5484D),
            (ctx) => CoursePage.open(ctx),
          ),
          _Entry(
            'Smily dans le navigateur',
            'L\'extension Chrome : il utilise tes sites dans ses onglets, pendant que tu fais autre chose',
            Icons.extension_rounded,
            const Color(0xFF10B981),
            (ctx) => BrowserSetupPage.open(ctx),
          ),
        ],
      ),
      (
        'Sa personnalité',
        [
          _Entry(
            'Personnalité et vie à lui',
            'Son humeur, ses souvenirs, sa vie (il dort, rêve, danse…), ta ville pour sa météo',
            Icons.pets_rounded,
            const Color(0xFF2B6CFF),
            (ctx) => MindPage.open(ctx),
          ),
          page('look'),
        ],
      ),
      ('Vie privée et avancé', [page('privacy'), page('tools')]),
    ];
  }

  List<_Entry> _entries(ClickyController c) => [for (final (_, list) in _groups(c)) ...list];

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final k = from.indexOf(ch);
      b.write(k < 0 ? ch : to[k]);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final c = ClickyController.instance;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages de Smily')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              final entries = _entries(c);
              final words = _plain(q).trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
              final shown = words.isEmpty
                  ? entries
                  : entries.where((e) => words.every((w) => _plain('${e.title} ${e.subtitle}').contains(w))).toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  TextField(
                    controller: search,
                    onChanged: (v) => setState(() => q = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Chercher un réglage (voix, micro, quiz, Whisper…)',
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                      suffixIcon: q.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() {
                                search.clear();
                                q = '';
                              }),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (words.isEmpty) ...[_Essentials(c: c), const SizedBox(height: 4)],
                  if (words.isEmpty)
                    for (final (title, list) in _groups(c)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                        child: Text(
                          title.toUpperCase(),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                      for (final e in list) _EntryTile(entry: e),
                    ]
                  else
                    for (final e in shown) _EntryTile(entry: e),
                  if (words.isNotEmpty) ClickyMoreSettings(query: q),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// L'essentiel : ce qu'on change le plus souvent.
class _Essentials extends StatelessWidget {
  const _Essentials({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('L\'essentiel', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.power_settings_new_rounded),
              title: const Text('Smily activé'),
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
                secondary: const Icon(Icons.desktop_windows_rounded),
                title: const Text('Smily partout'),
                subtitle: const Text('Au-dessus de toutes tes applis, même quand Mon Hub est réduit'),
                value: c.everywhere,
                onChanged: (v) async {
                  await c.setOption('everywhere', v);
                  v ? await ClickyDesktop.launch() : await ClickyDesktop.stop();
                },
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(c.voice ? Icons.volume_up_rounded : Icons.volume_off_rounded),
              title: const Text('Il parle'),
              subtitle: const Text('Sinon, il répond seulement par écrit'),
              value: c.voice,
              onChanged: (v) async {
                if (!v) await c.stopSpeaking();
                await c.setOption('voice', v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(c.mic ? Icons.mic_rounded : Icons.mic_off_rounded),
              title: const Text('Je lui parle au micro'),
              subtitle: const Text('Sinon, Ctrl + Alt ouvre la zone pour écrire'),
              value: c.mic,
              onChanged: (v) => c.setOption('mic', v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.bolt_rounded),
              title: const Text('Réponses instantanées sans IA'),
              subtitle: const Text(
                'L\'heure, un calcul, la musique, tes devoirs, la météo… tout de suite, sans Claude',
              ),
              value: c.quick,
              onChanged: (v) => c.setOption('quick', v),
            ),
            if (c.mic)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                  label: const Text('Tester le micro (et régler le souci)'),
                  onPressed: () => unawaited(MicTestDialog.show(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: ListTile(
      leading: CircleAvatar(
        backgroundColor: entry.color.withValues(alpha: 0.14),
        child: Icon(entry.icon, color: entry.color),
      ),
      title: Text(entry.title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(entry.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => entry.open(context),
    ),
  );
}

/// Une rubrique, sur sa propre page.
class _SectionPage extends StatelessWidget {
  const _SectionPage({required this.section});
  final ClickySection section;

  static Future<void> open(BuildContext context, ClickySection s) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _SectionPage(section: s)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(section.title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Text(section.subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            ClickyMoreSettings(section: section.id),
          ],
        ),
      ),
    ),
  );
}
