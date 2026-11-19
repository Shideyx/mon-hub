import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/nav.dart';
import '../../core/browser_link.dart';
import 'background_tasks.dart';
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
    ('Fais-le à ma place', Icons.engineering_rounded, Color(0xFF2B6CFF), [
      '« Fais-le à ma place : mets mes devoirs de la semaine dans un Google Doc » : en arrière-plan, tu continues',
      'Avec l\'extension Chrome : il utilise tes sites (Classroom, Forms, Slides…) dans ses propres onglets',
      'Il demande toujours avant d\'envoyer, publier, payer ou supprimer ; la pastille bleue montre où il en est',
    ]),
    ('Ta journée', Icons.today_rounded, Color(0xFF7C5CFF), [
      '« Fais le point » : l\'heure, ton prochain cours, tes devoirs, l\'état du PC',
      '« Qu\'est-ce que j\'ai demain ? », « J\'ai quoi comme devoirs ? »',
      '« Briefing » : le topo du matin, quand tu veux',
      '« Organise mes révisions avant le contrôle de maths »',
    ]),
    ('Ce que tu as raté', Icons.mark_chat_unread_rounded, Color(0xFF7C5CFF), [
      '« Qu\'est-ce que j\'ai raté ? » : messages Discord, mentions, mails importants (sans les pubs), École Directe',
      'Quand tu reviens devant le PC, il te le dit tout seul (et qui attend ta réponse)',
    ]),
    ('Retrouver n\'importe quoi', Icons.search_rounded, Color(0xFF0EA5E9), [
      'Ctrl + Espace dans Mon Hub (Ctrl + Alt + Espace partout) : PC, Drive, Google Docs, mails, Discord, cours…',
      '« Cherche mon exposé sur la Révolution partout », « Retrouve le fichier de maths »',
    ]),
    ('Sécurité', Icons.shield_rounded, Color(0xFF16A34A), [
      'Bouclier anti-arnaque : faux Nitro/Robux, faux sites, espions d\'IP, « teste mon jeu » avec un .exe',
      '« Ce lien est sûr ? » (après l\'avoir copié)',
      '« Bilan de sécurité » : antivirus, pare-feu, mises à jour, double authentification',
    ]),
    ('Bien-être', Icons.hourglass_bottom_rounded, Color(0xFF5B5BD6), [
      '« Mon temps d\'écran », « Combien de temps j\'ai passé sur Roblox cette semaine ? »',
      '« Limite YouTube à 1 h par jour » : il te prévient (rien n\'est bloqué)',
      '« À quelle heure je dois me coucher ? » : d\'après ton premier cours de demain',
      'Mode jeu : un jeu en plein écran, et Mon Hub se fait oublier jusqu\'à la fin de la partie',
    ]),
    ('Tes proches', Icons.cake_rounded, Color(0xFFE5487B), [
      '« L\'anniversaire de Léa c\'est le 12 mars » : rappel la veille et le jour même, avec un message tout prêt',
      '« Les prochains anniversaires », « C\'est quand l\'anniversaire de Tom ? »',
    ]),
    ('Concentration', Icons.self_improvement_rounded, Color(0xFF10B981), [
      '« Mode concentration 45 minutes » (ou « je dois travailler une heure »)',
      'Il ne te dérange plus et garde les notifications pour la fin',
      '« Arrête le mode concentration » : il te donne le bilan',
    ]),
    ('Ton téléphone', Icons.devices_rounded, Color(0xFF0EA5E9), [
      'Réglages → Mes appareils → Mon téléphone : un QR code à scanner une fois',
      'Envoie tes photos au PC sans câble, récupère des fichiers du PC, partage le presse-papier',
      'Télécommande : son, musique, diapos, souris, verrouiller, veille, éteindre… depuis ton lit',
      '« Envoie le PDF de mon exposé sur mon téléphone »',
      '« Lance une soirée » : tes amis scannent un QR code, ajoutent leurs sons et votent ; le PC enchaîne',
    ]),
    ('Ton argent', Icons.savings_rounded, Color(0xFF16A34A), [
      'Carte « Mon argent » : tes abonnements et essais gratuits trouvés dans tes mails, rappel la veille du prélèvement',
      '« Mes abonnements », « Combien je dépense en abonnements ? »',
      '« Où est mon colis ? » : il suit tes colis d\'après les mails et te prévient quand ils sont à retirer',
      '« Jeux gratuits » (Epic) et les promos de ta liste de souhaits Steam',
      'Bilan de sécurité : « mes mots de passe ont-ils fuité ? » (sans jamais les envoyer)',
    ]),
    ('Ton PC', Icons.computer_rounded, Color(0xFFEA580C), [
      '« Comment va mon PC ? », « Il me reste combien de batterie ? »',
      '« Pourquoi mon PC rame ? » : il te dit quelles applis prennent la mémoire',
      '« Montre le bureau », « Mets Chrome à gauche », « Reviens sur Discord »',
      '« Range mes téléchargements », « Mets le son à 30 % », « Installe VLC »',
    ]),
    ('Écrire', Icons.spellcheck_rounded, Color(0xFF0EA5E9), [
      'Surligne un texte n\'importe où et appuie sur Ctrl + Alt + C : il le corrige à sa place',
      '« Traduis la sélection en anglais », « Reformule mon texte »',
    ]),
    ('Langues', Icons.translate_rounded, Color(0xFF0EA5E9), [
      '« Interprète anglais » : tu parles avec quelqu\'un, Clicky traduit à voix haute dans les deux sens',
      '« Mets les sous-titres » : tout ce qui passe sur ton PC (vidéo, série, jeu) traduit en français en bas de l\'écran',
    ]),
    ('Rappels', Icons.notifications_active_rounded, Color(0xFFF59E0B), [
      '« Rappelle-moi de répondre à Léo quand j\'ouvre Discord »',
      '« Rappelle-moi dans 20 minutes de sortir le linge »',
      '« Retiens que mon oral d\'anglais est jeudi »',
    ]),
    ('École', Icons.school_rounded, Color(0xFFE5484D), [
      '« Fais mes devoirs de maths » : il lit le cahier de texte et les fichiers du prof, fait tout et le range dans un Google Doc',
      '« Fais cet exercice » (à l\'écran) : la solution détaillée, avec « comment j\'ai fait »',
      '« Écoute le cours » : il prend tes notes en direct dans un Google Doc, puis fait le compte rendu',
      '« Il me faut combien en maths pour avoir 14 ? », « Bilan de mes notes »',
      '« Qu\'est-ce que je dois prendre demain ? » (et le rappel du sac le soir)',
      '« Fais-moi un contrôle blanc de SVT » : chronométré, noté sur 20',
      '« Qu\'est-ce qu\'il y a dans le PDF du devoir de maths ? »',
      '« Fais-moi des cartes sur la photosynthèse », « Interroge-moi »',
      '« Écris-moi une fiche sur la Révolution française » : un vrai Google Doc',
      '« Corrige ma copie » : prends-la en photo, chaque faute est entourée à sa place, avec la règle',
      '« Coach d\'oral » : répète ton exposé, il compte tes « euh », mesure ton débit, puis le jury te pose ses questions',
      'Vidéo YouTube → fiche : résumé, chapitres cliquables et quiz (Révisions → ✨)',
      '« Fais une carte mentale sur la photosynthèse » : les branches se déplient, Clicky explique',
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

/// La pastille « Clicky travaille… » pendant une tâche « fais-le à ma
/// place » (un clic : où il en est, et l'arrêter).
class TaskPill extends StatelessWidget {
  const TaskPill({super.key});

  Future<void> _details(BgTask t) async {
    final ctx = await hubDialogContext();
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => ListenableBuilder(
        listenable: BackgroundTasks.instance,
        builder: (c, _) => AlertDialog(
          icon: const Icon(Icons.engineering_rounded),
          title: const Text('Clicky travaille pour toi'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.goal, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (t.steps.isEmpty) const Text('Il réfléchit à comment s\'y prendre…'),
                for (final s in t.steps.reversed.take(8)) Text('• $s'),
                if (!t.running) ...[const Divider(), Text(t.result)],
              ],
            ),
          ),
          actions: [
            if (t.running)
              TextButton(
                onPressed: () {
                  BackgroundTasks.instance.cancel(t);
                  Navigator.pop(c);
                },
                child: const Text('Arrêter'),
              ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([BackgroundTasks.instance, BrowserLink.instance.step]),
    builder: (context, _) {
      final t = BackgroundTasks.instance.current;
      if (t == null) return const SizedBox.shrink();
      final step = BrowserLink.instance.step.value;
      final goal = t.goal.length > 32 ? '${t.goal.substring(0, 32)}…' : t.goal;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: const Color(0xFF2B6CFF),
          borderRadius: BorderRadius.circular(20),
          elevation: 3,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _details(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 8),
                  Text(
                    'Clicky travaille : $goal${step.isEmpty ? '' : ' · $step'}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
