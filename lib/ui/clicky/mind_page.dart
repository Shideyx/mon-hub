import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../modules/carnet/carnet_store.dart';
import 'clicky.dart';
import 'life_view.dart' show emojiFonts;
import 'mind.dart';

/// Réglages → Conscience de Nexo : son humeur, ses souvenirs, sa présence.
class MindPage extends StatefulWidget {
  const MindPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MindPage()));

  @override
  State<MindPage> createState() => _MindPageState();
}

class _MindPageState extends State<MindPage> {
  final m = ClickyMind.instance;
  final city = TextEditingController();
  String cityInfo = '';

  @override
  void initState() {
    super.initState();
    unawaited(m.load());
    unawaited(
      Carnet.instance.load().then((_) {
        if (mounted) setState(() => city.text = Carnet.instance.setting<String>('city', ''));
      }),
    );
  }

  @override
  void dispose() {
    city.dispose();
    super.dispose();
  }

  Future<void> _saveCity() async {
    final v = city.text.trim();
    await Carnet.instance.setSetting('city', v);
    if (v.isEmpty) {
      setState(() => cityInfo = '');
      return;
    }
    try {
      final w = await Weather.forCity(v);
      if (mounted) setState(() => cityInfo = '${w['icone']} ${w['ville']} : ${w['maintenant']}');
    } catch (e) {
      if (mounted) setState(() => cityInfo = '$e');
    }
  }

  static String _day(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Conscience de Nexo')),
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
                            'Nexo est ${m.moodLabel(now)}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Text('🐾', style: TextStyle(fontSize: 22, fontFamilyFallback: emojiFonts)),
                title: const Text('Sa vie à lui', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text(
                  'Il garde son look de curseur, mais il vit à côté de toi avec des émojis : il bâille le soir, '
                  's\'endort dans son coin quand tu pars (💤) et se réveille en sursaut, te raconte ses rêves, porte un '
                  'accessoire selon la vraie météo et les fêtes (🧣 ☂️ 😎 🎅, ☕ le matin), réagit à tes notes. Presque '
                  'tout est muet : quelques petites bulles par jour au plus, jamais sa voix de lui-même, et rien en plein '
                  'écran, en jeu ou en mode concentration.',
                ),
                value: m.life,
                onChanged: m.on ? (v) => m.set('life', v) : null,
              ),
              if (m.on && m.life) ...[
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'discret', label: Text('Discret')),
                    ButtonSegment(value: 'normal', label: Text('Normal')),
                  ],
                  selected: {m.lifePace},
                  onSelectionChanged: (v) => m.setLifePace(v.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: city,
                  decoration: InputDecoration(
                    labelText: 'Ta ville (pour la vraie météo et ses accessoires 🧣 ☂️ 😎)',
                    helperText: cityInfo.isEmpty ? 'Ou dis-lui : « j\'habite à Lyon ».' : cityInfo,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(icon: const Icon(Icons.check_rounded), onPressed: _saveCity),
                  ),
                  onSubmitted: (_) => _saveCity(),
                ),
                const SizedBox(height: 4),
                Text(
                  m.lifePace == 'discret'
                      ? 'Une petite bulle par heure (4 par jour) au plus, et deux fois moins d\'émojis.'
                      : 'Deux petites bulles par heure (8 par jour) au plus, 10 minutes d\'écart au minimum.',
                  style: theme.textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Text('🎵', style: TextStyle(fontSize: 20, fontFamilyFallback: emojiFonts)),
                  title: const Text('Il danse sur ta musique'),
                  subtitle: const Text(
                    'Quand ta musique joue, il écoute le son du PC (rien n\'est enregistré ni envoyé) et bouge en rythme. '
                    'Pas sur une vidéo qui parle : seulement sur un vrai rythme.',
                  ),
                  value: m.lifeDance,
                  onChanged: (v) => m.set('life.dance', v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Text('🪑', style: TextStyle(fontSize: 20, fontFamilyFallback: emojiFonts)),
                  title: const Text('Il s\'assoit sur tes fenêtres'),
                  subtitle: const Text(
                    'De temps en temps, il va s\'asseoir en haut de ta fenêtre… et tombe si tu la fermes ou en changes 😱. '
                    'Approche la souris pour qu\'il revienne, ou fais de petits allers-retours dessus pour le caresser 🥰.',
                  ),
                  value: m.lifePerch,
                  onChanged: (v) => m.set('life.perch', v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Text('😵‍💫', style: TextStyle(fontSize: 20, fontFamilyFallback: emojiFonts)),
                  title: const Text('Il réagit'),
                  subtitle: const Text(
                    'La tête qui tourne si tu secoues la souris, inquiet si tu cliques comme un fou (pas dans un jeu), '
                    'content pour une bonne note 🤩, là pour toi après une mauvaise 🫂.',
                  ),
                  value: m.lifeReact,
                  onChanged: (v) => m.set('life.react', v),
                ),
                Text(
                  'Demande-lui : « tu dors ? », « t\'as rêvé de quoi ? », « pourquoi t\'as une écharpe ? », « tu danses ? ». '
                  'Trop présent ? Dis-lui « sois plus discret ».',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const Divider(height: 32),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.bolt_rounded, color: Color(0xFFFFA000)),
                title: const Text('Nexo décide tout seul', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text(
                  'Il regarde ta journée, décide d\'une chose utile à faire (préparer un contrôle, organiser ta soirée, '
                  'lancer des révisions, chercher pour toi…) et te la propose. Il ne fait rien sans ton « oui », et ne '
                  'propose jamais d\'envoyer un message ni de supprimer. Il retient ce que tu acceptes ou refuses.',
                ),
                value: m.autonomy,
                onChanged: m.on ? (v) => m.set('autonomy', v) : null,
              ),
              if (m.autonomy && m.on) ...[
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'rarement', label: Text('Rarement')),
                    ButtonSegment(value: 'normal', label: Text('Normal')),
                    ButtonSegment(value: 'souvent', label: Text('Souvent')),
                  ],
                  selected: {m.pace},
                  onSelectionChanged: (v) => m.setPace(v.first),
                ),
                const SizedBox(height: 4),
                Text(switch (m.pace) {
                  'souvent' => 'Jusqu\'à 8 idées par jour, au moins 25 minutes entre deux.',
                  'rarement' => 'Jusqu\'à 3 idées par jour, au moins 1 h 30 entre deux.',
                  _ => 'Jusqu\'à 5 idées par jour, au moins 45 minutes entre deux.',
                }, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.lightbulb_rounded),
                    label: const Text('Propose-moi une idée maintenant'),
                    onPressed: () async {
                      final c = ClickyController.instance;
                      final i = await c.decideIdea(DateTime.now());
                      if (i != null) {
                        await c.proposeIdea(i);
                      } else if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Rien d\'utile à proposer pour l\'instant, d\'après Nexo.')),
                        );
                      }
                    },
                  ),
                ),
                if (m.likes.isNotEmpty || m.dislikes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      [
                        if (m.likes.isNotEmpty) 'Tu acceptes souvent : ${m.likes}.',
                        if (m.dislikes.isNotEmpty) 'Tu refuses souvent : ${m.dislikes}.',
                      ].join(' '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
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
                          content: const Text(
                            'Nexo oubliera vos conversations, son humeur et ce dont il voulait prendre des nouvelles.',
                          ),
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
