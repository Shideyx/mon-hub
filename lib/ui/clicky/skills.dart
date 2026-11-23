import 'package:material_ui/material_ui.dart';

import 'clicky.dart';
import 'life_view.dart' show emojiFonts;

/// Une chose que Clicky sait faire. [tryIt] : la phrase à lui dire pour
/// essayer (null : pas d'essai direct, par exemple un raccourci clavier).
class Skill {
  const Skill(this.text, {this.tryIt});
  final String text;
  final String? tryIt;
}

/// Un thème du catalogue.
class SkillGroup {
  const SkillGroup(this.emoji, this.title, this.color, this.items, {this.isNew = false});
  final String emoji;
  final String title;
  final Color color;
  final List<Skill> items;

  /// Nouveauté (pastille « Nouveau »).
  final bool isNew;
}

/// **Tout ce que Clicky sait faire**, par thème, avec des phrases à essayer.
class ClickySkills {
  ClickySkills._();

  static const groups = <SkillGroup>[
    SkillGroup('🗣️', 'Lui parler', Color(0xFF2B6CFF), [
      Skill('Maintiens Ctrl + Alt et parle, relâche pour envoyer. Appui court : tu écris.'),
      Skill('Dis « Clicky » (mot d\'activation, dans Réglages de Clicky → Écoute et micro) : mains libres.'),
      Skill('Après sa réponse, enchaîne directement : il t\'écoute encore quelques secondes.'),
      Skill('« Réfléchis bien : pourquoi le ciel est bleu ? » pour un problème difficile', tryIt: 'Réfléchis bien : pourquoi le ciel est bleu ?'),
      Skill('« Fais le point » : l\'heure, ton prochain cours, tes devoirs, l\'état du PC', tryIt: 'Fais le point'),
    ]),
    SkillGroup('🌐', 'Espaces partagés et discussions', Color(0xFF7C5CFF), isNew: true, [
      Skill('Crée un espace (exposé, classe, équipe, entreprise) et invite tes amis avec un code : tableau de tâches et discussion en direct.'),
      Skill('Épingle tes espaces : ils restent en haut du menu, sur tous tes appareils.'),
      Skill('Écris « @clicky résume la discussion » dans un espace : ton Clicky répond pour tout le monde.'),
      Skill('Allume « Mon Clicky peut parler avec les Clicky des autres » (Réglages → Compte en ligne) : vos Clicky se répondent.'),
      Skill('Même compte partout : sur un autre PC, un Android ou un iPhone, « Mon compte en ligne » et tout revient.'),
    ]),
    SkillGroup('🚀', 'Toutes tes applis', Color(0xFF0EA5E9), isNew: true, [
      Skill('Tape le nom d\'une appli dans la console de l\'accueil (ou Ctrl + K) : Entrée l\'ouvre, plus besoin de la touche Windows.'),
      Skill('Partout sur le PC : Ctrl + Alt + Espace, puis le nom de l\'appli.'),
      Skill('« Mes applis » dans le menu : tout le menu Démarrer ; clic droit pour épingler sur l\'accueil.'),
      Skill('Accueil à ta façon : « Personnaliser » pour déplacer les blocs, changer leur taille, en ajouter.'),
    ]),
    SkillGroup('👀', 'Ses yeux et ses oreilles', Color(0xFF0EA5E9), isNew: true, [
      Skill('Il voit ton écran et entend le son du PC en continu, sur le PC (à allumer une fois dans ses réglages).'),
      Skill('« Tu te souviens du site sur les volcans que j\'ai vu hier ? »', tryIt: 'Tu te souviens du site sur les volcans que j\'ai vu hier ?'),
      Skill('« Qu\'est-ce que je faisais mardi vers 16 h ? »', tryIt: 'Qu\'est-ce que je faisais mardi vers 16 h ?'),
      Skill('« Qu\'est-ce qu\'il a dit ? » (dans ta vidéo)', tryIt: 'Qu\'est-ce qu\'il a dit ?'),
      Skill('Il remarque une erreur à l\'écran, une date limite, une vidéo en anglais, les « à retenir » d\'un cours.'),
      Skill('« Ferme les yeux pendant 1 h », « Oublie les 10 dernières minutes »', tryIt: 'Ferme les yeux pendant 1 h'),
    ]),
    SkillGroup('🔔', 'Préviens-moi quand…', Color(0xFFF59E0B), isNew: true, [
      Skill('« Préviens-moi quand j\'ai ma note de maths »', tryIt: 'Préviens-moi quand j\'ai ma note de maths'),
      Skill('« Dis-moi quand Lucas m\'écrit », « …quand je reçois un mail de Pronote »'),
      Skill('« Préviens-moi quand internet revient », « …quand mon téléchargement est fini »'),
      Skill('« Préviens-moi quand cette page change » (lien copié), « …quand le prix de ce jeu Steam baisse »'),
      Skill('« Qu\'est-ce que tu surveilles ? »', tryIt: 'Qu\'est-ce que tu surveilles ?'),
    ]),
    SkillGroup('💡', 'Il prend les devants', Color(0xFF7C5CFF), isNew: true, [
      Skill('Il te propose des idées utiles (préparer un contrôle, organiser ta soirée…) avec Oui / Non.'),
      Skill('Le soir, devoir pour demain et 40 min de YouTube : « on fait 25 minutes ? »'),
      Skill('Tu copies un lien d\'arnaque, un calcul, une date, de l\'anglais, un colis : il propose la bonne action.'),
      Skill('Un cours téléchargé → « je le range dans Cours/Maths ? », une capture → « je copie son texte ? »'),
      Skill('Une question sur Discord → « je te prépare une réponse ? » (copiée, jamais envoyée seule).'),
      Skill('« Mes habitudes » : ce qu\'il a remarqué sur toi', tryIt: 'Mes habitudes'),
      Skill('« Briefing » : le topo du matin, quand tu veux', tryIt: 'Briefing'),
    ]),
    SkillGroup('🎒', 'École', Color(0xFFE5484D), [
      Skill('« Qu\'est-ce que j\'ai comme devoirs ? »', tryIt: 'Qu\'est-ce que j\'ai comme devoirs ?'),
      Skill('« Fais mes devoirs de maths » : il lit le cahier de texte et les fichiers du prof, et fait tout dans un Google Doc'),
      Skill('« Fais cet exercice » (à l\'écran) : la solution détaillée, avec « comment j\'ai fait »'),
      Skill('« Écoute le cours » : notes en direct dans un Google Doc, puis le compte rendu'),
      Skill('« Il me faut combien en maths pour avoir 14 ? »', tryIt: 'Il me faut combien en maths pour avoir 14 ?'),
      Skill('« Bilan de mes notes »', tryIt: 'Bilan de mes notes'),
      Skill('« Qu\'est-ce que je dois prendre demain ? »', tryIt: 'Qu\'est-ce que je dois prendre demain ?'),
      Skill('« Fais-moi un contrôle blanc de SVT » : chronométré, noté sur 20'),
      Skill('« Fais-moi des cartes sur la photosynthèse », « Interroge-moi »'),
      Skill('« Corrige ma copie » (photo), « Coach d\'oral », vidéo YouTube → fiche, carte mentale'),
    ]),
    SkillGroup('📅', 'Ta journée', Color(0xFF7C5CFF), [
      Skill('« Qu\'est-ce que j\'ai demain ? »', tryIt: 'Qu\'est-ce que j\'ai demain ?'),
      Skill('« C\'est quoi mon prochain cours ? »', tryIt: 'C\'est quoi mon prochain cours ?'),
      Skill('« Organise mes révisions avant le contrôle de maths »'),
      Skill('« Quel temps il fait demain ? »', tryIt: 'Quel temps il fait demain ?'),
    ]),
    SkillGroup('🛠️', 'Fais-le à ma place', Color(0xFF2B6CFF), [
      Skill('« Fais-le à ma place : mets mes devoirs de la semaine dans un Google Doc » : en arrière-plan'),
      Skill('« Prends la main et ouvre mes mails » : il clique pour toi (après ton accord)'),
      Skill('Avec l\'extension Chrome : il utilise tes sites (Classroom, Forms…) dans ses propres onglets.'),
      Skill('Il demande toujours avant d\'envoyer, publier, payer ou supprimer.'),
    ]),
    SkillGroup('🖱️', 'À l\'écran', Color(0xFF0EA5E9), [
      Skill('« Où est le bouton pour mettre en gras ? » : il vole dessus et te montre', tryIt: 'Où est le bouton pour mettre en gras ?'),
      Skill('« Explique-moi ce qu\'il y a à l\'écran » : avec un tableau ou des dessins', tryIt: 'Explique-moi ce qu\'il y a à mon écran'),
    ]),
    SkillGroup('💬', 'Ce que tu as raté', Color(0xFF7C5CFF), [
      Skill('« Qu\'est-ce que j\'ai raté ? » : Discord, mails importants (sans les pubs), École Directe', tryIt: 'Qu\'est-ce que j\'ai raté ?'),
      Skill('Quand tu reviens devant le PC, il te le dit tout seul.'),
    ]),
    SkillGroup('🔎', 'Retrouver n\'importe quoi', Color(0xFF0EA5E9), [
      Skill('Ctrl + Espace dans Mon Hub (Ctrl + Alt + Espace partout) : PC, Drive, Docs, mails, Discord, cours…'),
      Skill('« Cherche mon exposé sur la Révolution partout »', tryIt: 'Cherche mon exposé sur la Révolution partout'),
    ]),
    SkillGroup('✍️', 'Écrire et traduire', Color(0xFF0EA5E9), [
      Skill('Surligne un texte n\'importe où, puis Ctrl + Alt + C : il le corrige à sa place.'),
      Skill('« Traduis la sélection en anglais », « Reformule mon texte »'),
      Skill('« Interprète anglais » : il traduit à voix haute dans les deux sens'),
      Skill('« Mets les sous-titres » : tout ce qui passe sur ton PC, traduit en bas de l\'écran', tryIt: 'Mets les sous-titres'),
    ]),
    SkillGroup('⏰', 'Rappels', Color(0xFFF59E0B), [
      Skill('« Rappelle-moi dans 20 minutes de sortir le linge »', tryIt: 'Rappelle-moi dans 20 minutes de sortir le linge'),
      Skill('« Rappelle-moi de répondre à Léo quand j\'ouvre Discord »'),
      Skill('« Retiens que mon oral d\'anglais est jeudi » : il prendra des nouvelles après'),
    ]),
    SkillGroup('🎯', 'Concentration', Color(0xFF10B981), [
      Skill('« Mode concentration 45 minutes »', tryIt: 'Mode concentration 45 minutes'),
      Skill('Il ne te dérange plus et garde les notifications pour la fin, puis te donne le bilan.'),
    ]),
    SkillGroup('🌙', 'Bien-être', Color(0xFF5B5BD6), [
      Skill('« Mon temps d\'écran », « Combien de temps sur Roblox cette semaine ? »', tryIt: 'Mon temps d\'écran'),
      Skill('« Limite YouTube à 1 h par jour » : il te prévient (rien n\'est bloqué)'),
      Skill('« À quelle heure je dois me coucher ? »', tryIt: 'À quelle heure je dois me coucher ?'),
      Skill('Mode jeu : un jeu en plein écran, et Mon Hub se fait oublier jusqu\'à la fin de la partie.'),
    ]),
    SkillGroup('🎵', 'Musique', Color(0xFF1DB954), [
      Skill('« Mets ma playlist chill », « Monte le son », « Suivant »'),
      Skill('« C\'est quoi ce son ? »', tryIt: 'C\'est quoi ce son ?'),
      Skill('Un artiste de tes titres likés sort un nouveau son : tu es prévenu.'),
      Skill('« Lance une soirée » : tes amis ajoutent leurs sons par QR code et votent.'),
    ]),
    SkillGroup('🛡️', 'Sécurité', Color(0xFF16A34A), [
      Skill('Bouclier anti-arnaque : faux Nitro/Robux, faux sites, « teste mon jeu » avec un .exe'),
      Skill('« Ce lien est sûr ? » (après l\'avoir copié)', tryIt: 'Ce lien est sûr ?'),
      Skill('« Bilan de sécurité » : antivirus, pare-feu, mises à jour, double authentification', tryIt: 'Bilan de sécurité'),
      Skill('« Répare-toi » : il relit son journal d\'erreurs et corrige ce qu\'il peut', tryIt: 'Répare-toi'),
      Skill('« Coupe ma caméra » : plus aucune appli ne peut filmer, même une appli piratée', tryIt: 'Coupe ma caméra'),
      Skill('« Qui utilise ma caméra ? » — et il te prévient dès qu\'une appli l\'allume', tryIt: 'Qui utilise ma caméra ?'),
    ]),
    SkillGroup('💻', 'Ton PC', Color(0xFFEA580C), [
      Skill('« Comment va mon PC ? »', tryIt: 'Comment va mon PC ?'),
      Skill('« Pourquoi mon PC rame ? »', tryIt: 'Pourquoi mon PC rame ?'),
      Skill('« Montre le bureau », « Mets Chrome à gauche », « Range mes téléchargements »'),
    ]),
    SkillGroup('📱', 'Ton téléphone', Color(0xFF0EA5E9), [
      Skill('Réglages → Mes appareils → Mon téléphone : un QR code à scanner une fois.'),
      Skill('Photos vers le PC sans câble, fichiers, presse-papier partagé, télécommande du PC depuis ton lit.'),
      Skill('« Envoie le PDF de mon exposé sur mon téléphone »'),
    ]),
    SkillGroup('💰', 'Ton argent', Color(0xFF16A34A), [
      Skill('« Mes abonnements » : trouvés dans tes mails, rappel la veille du prélèvement', tryIt: 'Mes abonnements'),
      Skill('« Où est mon colis ? »', tryIt: 'Où est mon colis ?'),
      Skill('« Jeux gratuits » (Epic) et les promos de ta liste Steam', tryIt: 'Jeux gratuits'),
    ]),
    SkillGroup('🎂', 'Tes proches', Color(0xFFE5487B), [
      Skill('« L\'anniversaire de Léa c\'est le 12 mars » : rappel la veille et le jour même, avec un message prêt'),
      Skill('« Les prochains anniversaires »', tryIt: 'Les prochains anniversaires'),
    ]),
    SkillGroup('🐾', 'Clicky vivant', Color(0xFF7C5CFF), isNew: true, [
      Skill('Il garde son look de curseur et vit avec des émojis : 💤 il dort quand tu pars, 🥱 il bâille le soir.'),
      Skill('Il porte un accessoire selon la vraie météo et les fêtes : 🧣 ☂️ 😎 🎅 ☕'),
      Skill('🎵 Il danse sur ta musique, 😵‍💫 la tête lui tourne si tu secoues la souris, 🪑 il s\'assoit sur ta fenêtre.'),
      Skill('« T\'as rêvé de quoi ? »', tryIt: 'T\'as rêvé de quoi ?'),
      Skill('« Pourquoi t\'as une écharpe ? », « Tu dors ? »', tryIt: 'Tu dors ?'),
      Skill('« J\'habite à Lyon » : pour sa vraie météo'),
      Skill('Trop présent ? « Sois plus discret »', tryIt: 'Sois plus discret'),
    ]),
  ];

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  /// Les thèmes (et leurs lignes) qui parlent de [q].
  static List<SkillGroup> search(String q) {
    final words = _plain(q).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length >= 2).toList();
    if (words.isEmpty) return groups;
    final out = <SkillGroup>[];
    for (final g in groups) {
      if (words.every((w) => _plain(g.title).contains(w))) {
        out.add(g);
        continue;
      }
      final items = [for (final i in g.items) if (words.every((w) => _plain('${g.title} ${i.text}').contains(w))) i];
      if (items.isNotEmpty) out.add(SkillGroup(g.emoji, g.title, g.color, items, isNew: g.isNew));
    }
    return out;
  }

  /// Le nombre de choses (pour « plus de 100 choses »).
  static int get count => groups.fold<int>(0, (a, g) => a + g.items.length);
}

/// **Ce que Clicky sait faire** : tout le catalogue, par thème, avec une
/// recherche ; une phrase avec ▶ se touche pour l'essayer tout de suite.
class ClickySkillsPage extends StatefulWidget {
  const ClickySkillsPage({super.key, this.onTry});

  /// Essayer une phrase (par défaut : Clicky la reçoit).
  final void Function(String phrase)? onTry;

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ClickySkillsPage()));

  @override
  State<ClickySkillsPage> createState() => _ClickySkillsPageState();
}

class _ClickySkillsPageState extends State<ClickySkillsPage> {
  final search = TextEditingController();
  String q = '';
  String? only;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void _try(String phrase) {
    final f = widget.onTry;
    if (f != null) {
      f(phrase);
    } else {
      ClickyController.instance.askAnywhere(phrase);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('C\'est demandé à Clicky : « $phrase »'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = ClickySkills.search(q).where((g) => only == null || g.title == only).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Ce que Clicky sait faire')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(colors: [Color(0xFF7C5CFF), Color(0xFF2B6CFF)]),
                ),
                child: Row(
                  children: [
                    const Text('✨', style: TextStyle(fontSize: 38, fontFamilyFallback: emojiFonts)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Plus de ${ClickySkills.count ~/ 10 * 10} choses à lui demander',
                            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Dis-les comme tu veux : il comprend les phrases normales. Touche une phrase avec ▶ pour l\'essayer.',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: search,
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Chercher (« devoirs », « musique », « arnaque »…)',
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
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(label: const Text('Tout'), selected: only == null, onSelected: (_) => setState(() => only = null)),
                    ),
                    for (final g in ClickySkills.groups)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('${g.emoji} ${g.title}', style: const TextStyle(fontFamilyFallback: emojiFonts)),
                          selected: only == g.title,
                          onSelected: (v) => setState(() => only = v ? g.title : null),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              if (found.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Rien trouvé : essaie un autre mot.'))),
              for (final g in found) _GroupCard(group: g, onTry: _try),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTry});
  final SkillGroup group;
  final void Function(String) onTry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = group;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: g.color.withValues(alpha: 0.14),
                  child: Text(g.emoji, style: const TextStyle(fontSize: 18, fontFamilyFallback: emojiFonts)),
                ),
                const SizedBox(width: 10),
                Text(g.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                if (g.isNew) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: g.color, borderRadius: BorderRadius.circular(10)),
                    child: const Text('Nouveau', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            for (final i in g.items)
              i.tryIt == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 7, right: 10, left: 4),
                            child: Container(width: 6, height: 6, decoration: BoxDecoration(color: g.color, shape: BoxShape.circle)),
                          ),
                          Expanded(child: Text(i.text, style: const TextStyle(fontFamilyFallback: emojiFonts))),
                        ],
                      ),
                    )
                  : InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onTry(i.tryIt!),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.play_circle_fill_rounded, size: 20, color: g.color),
                            const SizedBox(width: 6),
                            Expanded(child: Text(i.text, style: TextStyle(fontWeight: FontWeight.w600, fontFamilyFallback: emojiFonts))),
                          ],
                        ),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}
