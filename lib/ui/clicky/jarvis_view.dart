import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/nav.dart';
import 'jarvis.dart';

/// La pastille « Concentration · 32 min » en haut de Mon Hub pendant une
/// séance (un clic pour l'arrêter).
class FocusPill extends StatefulWidget {
  const FocusPill({super.key});

  @override
  State<FocusPill> createState() => _FocusPillState();
}

class _FocusPillState extends State<FocusPill> {
  final f = FocusMode.instance;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    f.addListener(_changed);
    unawaited(f.sync());
    // Relit la séance (lancée peut-être par Clicky partout) et le temps
    // restant : un coup d'œil toutes les 20 s, rien de plus.
    _t = Timer.periodic(const Duration(seconds: 20), (_) async {
      await f.sync();
      if (mounted && f.active) setState(() {});
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _t?.cancel();
    f.removeListener(_changed);
    super.dispose();
  }

  Future<void> _stop() async {
    // La pastille est au-dessus des pages : la boîte s'ouvre dans les pages.
    final ctx = await hubDialogContext();
    if (ctx == null || !ctx.mounted) return;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Arrêter la séance de concentration ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuer')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Arrêter')),
        ],
      ),
    );
    if (ok != true) return;
    final text = await f.stop();
    if (text != null && ctx.mounted) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (!f.active) return const SizedBox.shrink();
    final m = f.left.inMinutes + 1;
    return Material(
      color: const Color(0xFF10B981),
      borderRadius: BorderRadius.circular(20),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _stop,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.self_improvement_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                'Concentration · encore $m min',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « Ce que Clicky sait faire » : des exemples de phrases, par thème, pour
/// découvrir tout ce qu'il peut faire.
class ClickySkillsPage extends StatelessWidget {
  const ClickySkillsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ClickySkillsPage()));

  static const groups = <(String, IconData, Color, List<String>)>[
    ('Converser comme avec JARVIS', Icons.forum_rounded, Color(0xFF2B6CFF), [
      'Maintiens Ctrl + Alt et parle, ou dis « Clicky » (mains libres)',
      'Après sa réponse, enchaîne directement : il t\'écoute encore quelques secondes',
      '« Réfléchis bien : … » pour qu\'il prenne le temps sur un problème difficile',
      '« Agent, résume mes devoirs de la semaine » : il travaille en fond et te prévient',
    ]),
    ('Ta journée', Icons.today_rounded, Color(0xFF7C5CFF), [
      '« Fais le point » : l\'heure, ton prochain cours, tes devoirs, l\'état du PC',
      '« Qu\'est-ce que j\'ai demain ? », « J\'ai quoi comme devoirs ? »',
      '« Briefing » : le topo du matin, quand tu veux',
      '« Organise mes révisions avant le contrôle de maths »',
    ]),
    ('Concentration', Icons.self_improvement_rounded, Color(0xFF10B981), [
      '« Mode concentration 45 minutes » (ou « je dois travailler une heure »)',
      'Il ne te dérange plus et garde les notifications pour la fin',
      '« Arrête le mode concentration » : il te donne le bilan',
    ]),
    ('Ton PC', Icons.computer_rounded, Color(0xFFEA580C), [
      '« Comment va mon PC ? », « Il me reste combien de batterie ? »',
      '« Pourquoi mon PC rame ? » : il te dit quelles applis prennent la mémoire',
      '« Montre le bureau », « Mets Chrome à gauche », « Reviens sur Discord »',
      '« Range mes téléchargements », « Mets le son à 30 % », « Installe VLC »',
    ]),
    ('Rappels', Icons.notifications_active_rounded, Color(0xFFF59E0B), [
      '« Rappelle-moi de répondre à Léo quand j\'ouvre Discord »',
      '« Rappelle-moi dans 20 minutes de sortir le linge »',
      '« Retiens que mon oral d\'anglais est jeudi »',
    ]),
    ('École', Icons.school_rounded, Color(0xFFE5484D), [
      '« Écoute le cours » puis « arrête le cours » : le compte rendu complet',
      '« Qu\'est-ce qu\'il y a dans le PDF du devoir de maths ? »',
      '« Fais-moi des cartes sur la photosynthèse », « Interroge-moi »',
      '« Écris-moi une fiche sur la Révolution française » : un vrai Google Doc',
    ]),
    ('À l\'écran', Icons.ads_click_rounded, Color(0xFF0EA5E9), [
      '« Où est le bouton pour… ? » : il te montre',
      '« Prends la main et ouvre mes mails » : il clique pour toi',
      '« Explique-moi ce schéma » : avec un tableau ou un dessin à l\'écran',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ce que Clicky sait faire')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              Text(
                'Des exemples : dis-les comme tu veux, Clicky comprend les phrases naturelles.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final (title, icon, color, items) in groups)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: color.withValues(alpha: 0.14),
                              child: Icon(icon, color: color, size: 18),
                            ),
                            const SizedBox(width: 10),
                            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final i in items)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 7, right: 10),
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                                  ),
                                ),
                                Expanded(child: Text(i)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
