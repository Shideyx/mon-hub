import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../modules/claude/claude_module.dart';
import 'assistant_view.dart';
import 'clicky.dart';
import 'clicky_desktop.dart';
import 'browser_setup_page.dart';
import 'course_page.dart';
import 'jarvis_view.dart';
import 'mic_test.dart';
import 'mind_page.dart';
import 'settings.dart';

/// **Tous les réglages de Clicky, au même endroit**, rangés par rubrique
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

  List<_Entry> _entries(ClickyController c) {
    ClickySection sec(String id) => ClickySection.byId(id)!;
    _Entry page(String id) {
      final s = sec(id);
      return _Entry(s.title, s.subtitle, s.icon, s.color, (ctx) => _SectionPage.open(ctx, s));
    }

    return [
      _Entry(
        'Ce que Clicky sait faire',
        'Des exemples de phrases : concentration, état du PC, rappels, cours, écran…',
        Icons.tips_and_updates_rounded,
        const Color(0xFF0EA5E9),
        (ctx) => ClickySkillsPage.open(ctx),
      ),
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
      page('look'),
      _Entry(
        'Personnalité et conscience',
        'Son humeur, ses souvenirs, sa façon de vivre sur ton écran',
        Icons.psychology_alt_rounded,
        const Color(0xFF2B6CFF),
        (ctx) => MindPage.open(ctx),
      ),
      _Entry(
        'Clicky prend les devants',
        'Rappels de devoirs, plan de la journée, objectifs, idées (toujours avec ton accord)',
        Icons.auto_awesome_rounded,
        const Color(0xFF7C5CFF),
        (ctx) => AssistantPage.open(ctx),
      ),
      page('topo'),
      page('teach'),
      _Entry(
        'Clicky dans le navigateur',
        'L\'extension Chrome : il utilise tes sites dans ses onglets, pendant que tu fais autre chose',
        Icons.extension_rounded,
        const Color(0xFF10B981),
        (ctx) => BrowserSetupPage.open(ctx),
      ),
      _Entry(
        'Écouter un cours',
        'Il écoute tout le cours et te fait le compte rendu',
        Icons.mic_external_on_rounded,
        const Color(0xFFE5484D),
        (ctx) => CoursePage.open(ctx),
      ),
      page('privacy'),
      page('tools'),
    ];
  }

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
      appBar: AppBar(title: const Text('Réglages de Clicky')),
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
                  if (words.isEmpty) ...[
                    _Essentials(c: c),
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text(
                        'RUBRIQUES',
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.1),
                      ),
                    ),
                  ],
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
              title: const Text('Clicky activé'),
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
                title: const Text('Clicky partout'),
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
              subtitle: const Text('L\'heure, un calcul, la musique, tes devoirs, la météo… tout de suite, sans Claude'),
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
