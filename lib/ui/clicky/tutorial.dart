import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/module_store.dart';
import 'board.dart';
import 'clicky.dart';
import 'hud.dart';
import 'life.dart';
import 'life_view.dart';
import 'marks.dart';
import 'senses_page.dart';
import 'skills.dart';

/// **La visite guidée** de Clicky : montrée à la création du compte et une
/// fois après une grosse mise à jour (nouvelle clé [_seenKey]). Chaque page
/// présente un thème en animation, avec des phrases qu'on peut **essayer
/// tout de suite** (Clicky répond par-dessus la visite).
class ClickyTutorial extends StatefulWidget {
  const ClickyTutorial({super.key, this.onBrain, this.onTry});

  /// « Choisir son cerveau » (réglages de Claude et Clicky).
  final VoidCallback? onBrain;

  /// Essayer une phrase (par défaut : Clicky la reçoit).
  final void Function(String phrase)? onTry;

  static const _seenKey = 'tutorial.v159';

  /// Déjà vue sur ce compte ?
  static bool get seen => ModuleStore.prefs.getBool(_seenKey) == true;

  static Future<void> show(BuildContext context, {VoidCallback? onBrain}) async {
    await ModuleStore.prefs.setBool(_seenKey, true);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, _, _) => ClickyTutorial(onBrain: onBrain),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  State<ClickyTutorial> createState() => _ClickyTutorialState();

  /// Le texte de chaque page (testable).
  static const tour = <TourPage>[
    TourPage(
      'Salut, moi c\'est Clicky',
      'Ton assistant personnel, façon JARVIS. Je vis à côté de ta souris, sur tout ton PC. Je vois, j\'entends, je parle, '
          'je montre, j\'explique… et je fais des trucs à ta place. Voilà tout ce que je sais faire.',
    ),
    TourPage(
      'Parle-moi',
      'Maintiens Ctrl + Alt et parle, relâche pour envoyer. Appui court : tu écris. Ou active le mot d\'activation et dis '
          'simplement « Clicky ». Après ma réponse, enchaîne : je t\'écoute encore un peu.',
      examples: ['Fais le point', 'Qu\'est-ce que j\'ai demain ?'],
    ),
    TourPage(
      'Je vois ton écran et je te montre',
      'Pose ta question : je regarde l\'écran, mon curseur vole jusqu\'au bon bouton et je dessine dessus (flèches, cercles). '
          'Je t\'explique avec des tableaux, des schémas et des quiz.',
      examples: ['Explique-moi ce qu\'il y a à mon écran', 'Où est le bouton pour mettre en gras ?'],
    ),
    TourPage(
      'Je le fais à ta place',
      '« Fais mes devoirs de maths » : je lis le cahier de texte et les fichiers du prof, je fais tout et je le range dans un '
          'Google Doc. « Prends la main » : je clique pour toi. Avec l\'extension Chrome, j\'utilise tes sites en arrière-plan. '
          'Je demande toujours avant d\'envoyer, publier ou supprimer.',
      examples: ['Qu\'est-ce que j\'ai comme devoirs ?'],
    ),
    TourPage(
      'Ton école',
      'Tes notes et ta moyenne, la note qu\'il te faut, le contrôle préparé tout seul (fiche, cartes, quiz), un contrôle blanc '
          'noté, ta copie corrigée sur la photo, un coach pour ton oral, et j\'écoute le cours pour toi.',
      examples: ['Il me faut combien en maths pour avoir 14 ?', 'Bilan de mes notes'],
    ),
    TourPage(
      'Mes yeux et mes oreilles',
      'Si tu veux, je vois ton écran et j\'entends le son du PC en continu — tout reste sur ton PC, jamais tes messages ni ta '
          'banque, jamais pendant un appel. Je me souviens de ce que tu as vu, et je remarque une erreur, une date limite, '
          'une vidéo en anglais…',
      examples: ['Tu te souviens du site sur les volcans que j\'ai vu hier ?'],
      badge: 'Nouveau',
    ),
    TourPage(
      'Je prends les devants',
      'Je te propose des choses utiles au bon moment, avec Oui / Non : réviser avant ta partie habituelle, ranger le cours que '
          'tu viens de télécharger, traduire ce que tu copies, te préparer une réponse sur Discord, te recadrer si tu '
          'procrastines. Jamais plus de quelques fois par jour.',
      examples: ['Mes habitudes', 'Briefing'],
      badge: 'Nouveau',
    ),
    TourPage(
      'Préviens-moi quand…',
      'Je surveille pour toi et je te préviens dès que ça arrive : ta note qui tombe, un message de quelqu\'un, un nouveau '
          'devoir, une page qui change, le prix d\'un jeu Steam qui baisse, internet qui revient.',
      examples: ['Préviens-moi quand j\'ai ma note de maths', 'Qu\'est-ce que tu surveilles ?'],
      badge: 'Nouveau',
    ),
    TourPage(
      'Toute ta vie, pas que l\'école',
      'Ta musique, tes abonnements et tes colis, ton téléphone relié au PC, une soirée où tes potes ajoutent leurs sons, les '
          'anniversaires, ton temps d\'écran, la sécurité de tes comptes, et une recherche qui trouve tout.',
      examples: ['Mes abonnements', 'Comment va mon PC ?'],
    ),
    TourPage(
      'Et je suis vivant',
      'Je garde mon look de curseur, mais je vis à côté de toi : je m\'endors quand tu pars 💤, je rêve, je porte une écharpe '
          'quand il fait froid 🧣, je danse sur ta musique 🎵, j\'ai la tête qui tourne si tu secoues la souris 😵‍💫. '
          'Trop présent ? Dis-moi « sois plus discret ».',
      examples: ['T\'as rêvé de quoi ?', 'Tu dors ?'],
      badge: 'Nouveau',
    ),
    TourPage(
      'Prêt ?',
      'Choisis mon cerveau (ton abonnement Claude Pro), puis maintiens Ctrl + Alt. Tout ce que je sais faire est dans ✨ sur '
          'l\'accueil. Mon Hub se met à jour tout seul : tu auras toujours mes nouveautés.',
    ),
  ];

}

/// Une page de la visite.
class TourPage {
  const TourPage(this.title, this.text, {this.examples = const [], this.badge = ''});
  final String title;
  final String text;

  /// Des phrases à essayer.
  final List<String> examples;

  /// « Nouveau » sur les nouveautés.
  final String badge;
}

class _ClickyTutorialState extends State<ClickyTutorial> {
  final pages = PageController();
  int page = 0;

  static int get _count => ClickyTutorial.tour.length;
  static List<TourPage> get tour => ClickyTutorial.tour;

  void _go(int i) {
    if (i >= _count) {
      Navigator.of(context).maybePop();
      return;
    }
    pages.animateToPage(
      i.clamp(0, _count - 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  void _try(String phrase) {
    final f = widget.onTry;
    if (f != null) {
      f(phrase);
    } else {
      ClickyController.instance.askAnywhere(phrase);
    }
  }

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  Widget _visual(int i) => switch (i) {
    0 => const _BootVisual(),
    1 => const _KeysVisual(),
    2 => const _PointVisual(),
    3 => const _TaskVisual(),
    4 => _BoardVisual(),
    5 => const _SensesVisual(),
    6 => const _IdeaVisual(),
    7 => const _WatchVisual(),
    8 => const _LifeGridVisual(),
    9 => const _AliveVisual(),
    _ => const _BootVisual(small: true),
  };

  List<(String, IconData, VoidCallback)> _actions(int i) => switch (i) {
    5 => [
      (
        'Allumer mes yeux et mes oreilles',
        Icons.visibility_rounded,
        () => SensesPage.open(context),
      ),
    ],
    10 => [
      if (widget.onBrain != null)
        (
          'Choisir mon cerveau',
          Icons.key_rounded,
          () {
            Navigator.of(context).maybePop();
            widget.onBrain!();
          },
        ),
      (
        'Voir tout ce que je sais faire',
        Icons.auto_awesome_rounded,
        () {
          final nav = Navigator.of(context);
          nav.pop();
          unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const ClickySkillsPage())));
        },
      ),
    ],
    _ => const [],
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060D16),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(page + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(page - 1),
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        },
        child: Focus(
          autofocus: true,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.3),
                radius: 1.2,
                colors: [Color(0xFF0E2236), Color(0xFF060D16)],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: Text(
                          '${page + 1} / $_count',
                          style: const TextStyle(color: Colors.white38, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Passer', style: TextStyle(color: Colors.white54)),
                      ),
                    ],
                  ),
                  Expanded(
                    child: PageView(
                      controller: pages,
                      onPageChanged: (i) => setState(() => page = i),
                      children: [
                        for (var i = 0; i < _count; i++)
                          _Page(page: tour[i], visual: _visual(i), actions: _actions(i), onTry: _try),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < _count; i++)
                                GestureDetector(
                                  onTap: () => _go(i),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    width: i == page ? 26 : 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: i == page ? hudCyan : Colors.white24,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (page > 0)
                          TextButton(
                            onPressed: () => _go(page - 1),
                            child: const Text('Retour', style: TextStyle(color: Colors.white70)),
                          ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: hudCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () => _go(page + 1),
                          child: Text(page == _count - 1 ? 'C\'est parti' : 'Suivant'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.page, required this.visual, this.actions = const [], required this.onTry});
  final TourPage page;
  final Widget visual;
  final List<(String, IconData, VoidCallback)> actions;
  final void Function(String) onTry;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth > 820;
      final align = wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
      final words = Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (page.badge.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFE5487B), borderRadius: BorderRadius.circular(10)),
              child: Text(page.badge, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          Text(
            page.title,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, height: 1.1),
          ),
          const SizedBox(height: 14),
          Text(
            page.text,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: const TextStyle(color: Color(0xFFB7D9E6), fontSize: 16, height: 1.5, fontFamilyFallback: emojiFonts),
          ),
          if (page.examples.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Essaie, maintenant :', style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: wide ? WrapAlignment.start : WrapAlignment.center,
              children: [
                for (final e in page.examples)
                  ActionChip(
                    avatar: const Icon(Icons.play_arrow_rounded, size: 18, color: hudCyan),
                    backgroundColor: const Color(0xFF12263A),
                    side: BorderSide(color: hudCyan.withValues(alpha: 0.5)),
                    label: Text('« $e »', style: const TextStyle(color: Colors.white)),
                    onPressed: () => onTry(e),
                  ),
              ],
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: wide ? WrapAlignment.start : WrapAlignment.center,
              children: [
                for (final (label, icon, onTap) in actions)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: hudCyan, foregroundColor: Colors.black),
                    icon: Icon(icon),
                    label: Text(label),
                    onPressed: onTap,
                  ),
              ],
            ),
          ],
        ],
      );
      // Sur un petit écran, l'animation se réduit au lieu de déborder.
      final art = Center(child: FittedBox(fit: BoxFit.scaleDown, child: _Appear(child: visual)));
      if (wide) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 56),
          child: Row(
            children: [
              Expanded(child: art),
              const SizedBox(width: 40),
              Expanded(child: SingleChildScrollView(child: words)),
            ],
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SizedBox(height: 320, child: art),
          const SizedBox(height: 20),
          words,
        ],
      );
    },
  );
}

/// Apparition : l'élément se matérialise (fondu + zoom).
class _Appear extends StatelessWidget {
  const _Appear({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 700),
    curve: Curves.easeOutBack,
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
    ),
    child: child,
  );
}

/// Le réacteur en grand, avec ses anneaux qui s'allument.
class _BootVisual extends StatelessWidget {
  const _BootVisual({this.small = false});
  final bool small;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    height: 280,
    child: Stack(
      alignment: Alignment.center,
      children: [
        _Ticker(
          builder: (t) => CustomPaint(size: const Size(280, 280), painter: _RingsPainter(t)),
        ),
        HudReactor(mode: small ? HudMode.speaking : HudMode.thinking, size: 120),
      ],
    ),
  );
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    for (var i = 0; i < 4; i++) {
      final p = (t * 0.5 + i / 4) % 1;
      canvas.drawCircle(
        c,
        60 + p * 80,
        Paint()
          ..color = hudCyan.withValues(alpha: (1 - p) * 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final tick = Paint()
      ..color = hudCyan.withValues(alpha: 0.6)
      ..strokeWidth = 2;
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30 + t * 0.4;
      final r1 = 128.0, r2 = i % 5 == 0 ? 116.0 : 122.0;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r1,
        c + Offset(math.cos(a), math.sin(a)) * r2,
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter o) => true;
}

/// Temps qui passe (secondes) pour les petites animations.
class _Ticker extends StatefulWidget {
  const _Ticker({required this.builder});
  final Widget Function(double seconds) builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 60),
  )..repeat();
  final _start = DateTime.now();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    builder: (context, _) =>
        widget.builder(DateTime.now().difference(_start).inMilliseconds / 1000),
  );
}

/// Les touches Ctrl + Alt qui s'enfoncent, puis l'onde de la voix.
class _KeysVisual extends StatelessWidget {
  const _KeysVisual();

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) {
      final down = (t % 3) < 1.8;
      Widget key(String k) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        transform: Matrix4.translationValues(0, down ? 4 : 0, 0),
        decoration: BoxDecoration(
          color: down ? hudCyan.withValues(alpha: 0.25) : const Color(0xFF12263A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hudCyan.withValues(alpha: down ? 1 : 0.4)),
          boxShadow: down
              ? [BoxShadow(color: hudCyan.withValues(alpha: 0.5), blurRadius: 18)]
              : null,
        ),
        child: Text(
          k,
          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
        ),
      );
      final levels = [
        for (var i = 0; i < 9; i++) down ? 0.3 + 0.7 * (0.5 + 0.5 * math.sin(t * 9 + i)) : 0.08,
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              key('Ctrl'),
              const Text('+', style: TextStyle(color: Colors.white54, fontSize: 22)),
              key('Alt'),
            ],
          ),
          const SizedBox(height: 24),
          HudReactor(mode: down ? HudMode.listening : HudMode.idle, levels: levels, size: 90),
          const SizedBox(height: 16),
          Text(
            down ? '« Clicky, explique-moi cet exercice »' : '…',
            style: const TextStyle(color: hudCyan, fontSize: 16, fontStyle: FontStyle.italic),
          ),
        ],
      );
    },
  );
}

/// Un faux écran : le curseur vole vers le bouton, Clicky entoure et fléche.
class _PointVisual extends StatelessWidget {
  const _PointVisual();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 440,
    height: 280,
    child: _Ticker(
      builder: (t) {
        final cycle = t % 6;
        final fly = Curves.easeInOutCubic.transform((cycle / 1.6).clamp(0.0, 1.0));
        const from = Offset(60, 220), to = Offset(330, 80);
        final mid = Offset((from.dx + to.dx) / 2, 20);
        final u = 1 - fly;
        final pos = from * (u * u) + mid * (2 * u * fly) + to * (fly * fly);
        return Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF3F7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
            Positioned(
              left: 20,
              top: 16,
              child: Container(width: 160, height: 12, color: const Color(0xFFCBD5E1)),
            ),
            Positioned(
              left: 20,
              top: 44,
              child: Container(width: 240, height: 10, color: const Color(0xFFE2E8F0)),
            ),
            Positioned(
              left: 20,
              top: 62,
              child: Container(width: 200, height: 10, color: const Color(0xFFE2E8F0)),
            ),
            Positioned(
              left: 290,
              top: 64,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Exporter',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (cycle > 1.7 && cycle < 5.6)
              Positioned.fill(
                child: ClickyMarksView(
                  key: ValueKey((t / 6).floor()),
                  marks: const [
                    ClickyMark(MarkKind.circle, Offset(336, 81), size: 52, text: 'ici'),
                    ClickyMark(MarkKind.arrow, Offset(120, 200), b: Offset(282, 96)),
                  ],
                  color: hudCyan,
                  hold: const Duration(seconds: 3),
                ),
              ),
            Positioned(
              left: pos.dx - 17,
              top: pos.dy - 17,
              child: HudReactor(mode: fly >= 1 ? HudMode.pointing : HudMode.thinking, size: 34),
            ),
          ],
        );
      },
    ),
  );
}

class _BoardVisual extends StatelessWidget {
  _BoardVisual();

  final board = ClickyBoard.parse(
    '{"titre":"Le cycle de l\'eau","blocs":['
    '{"type":"schema","forme":"cycle","noeuds":["Évaporation","Nuages","Pluie","Rivières"],"liens":[[0,1,""],[1,2,""],[2,3,""],[3,0,""]]},'
    '{"type":"quiz","question":"Qu\'est-ce qui forme les nuages ?","choix":["La vapeur d\'eau","Le vent","Le sable"],"reponse":0,"explication":"La vapeur d\'eau se refroidit en altitude."}'
    ']}',
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 440,
    height: 420,
    child: board == null
        ? const SizedBox.shrink()
        : ClickyBoardView(board: board!, onClose: () {}, onAsk: (_) {}),
  );
}


/// Une carte sombre façon fenêtre (pour les nouvelles animations).
class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child, this.width = 420, this.title = ''});
  final Widget child;
  final double width;
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    decoration: BoxDecoration(
      color: const Color(0xFF0B1A2A),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: hudCyan.withValues(alpha: 0.35)),
      boxShadow: [BoxShadow(color: hudCyan.withValues(alpha: 0.15), blurRadius: 24)],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF12263A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        Padding(padding: const EdgeInsets.all(14), child: child),
      ],
    ),
  );
}

/// Une ligne de texte grise (faux contenu).
class _Line extends StatelessWidget {
  const _Line(this.width, {this.color = const Color(0xFF1E3A52)});
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 9,
    margin: const EdgeInsets.symmetric(vertical: 4),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
  );
}

/// « Fais-le à ma place » : la pastille de tâche et le document qui se remplit.
class _TaskVisual extends StatelessWidget {
  const _TaskVisual();

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) {
      final steps = ['Je lis le cahier de texte…', 'J\'ouvre le PDF du prof…', 'Je fais les exercices…', 'Je range tout dans un Google Doc…', 'Fini ! ✅'];
      final k = ((t % 10) / 2).floor().clamp(0, steps.length - 1);
      final lines = ((t % 10) * 1.4).floor().clamp(0, 12);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 380),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: const Color(0xFF2B6CFF), borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (k < steps.length - 1)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    steps[k],
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontFamilyFallback: emojiFonts),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Panel(
            width: 360,
            title: '📄 Devoirs de maths — Google Docs',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Exercice 3 p. 112', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                for (var i = 0; i < lines; i++) _Line(120.0 + (i * 37) % 180, color: i % 4 == 3 ? hudCyan.withValues(alpha: 0.5) : const Color(0xFF1E3A52)),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// Ses yeux : une fenêtre lue ligne par ligne, puis « tu te souviens ? ».
class _SensesVisual extends StatelessWidget {
  const _SensesVisual();

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) {
      final scan = (t % 4) / 4;
      final remember = (t % 8) > 4;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 400,
            height: 210,
            child: Stack(
              children: [
                const _Panel(
                  width: 400,
                  title: 'Volcan — Wikipédia',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Volcan', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                      _Line(320),
                      _Line(280),
                      _Line(340),
                      _Line(250),
                      _Line(300),
                    ],
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  top: 40 + scan * 150,
                  child: Container(height: 2, color: hudCyan, child: const SizedBox.shrink()),
                ),
                const Positioned(right: 14, top: 8, child: Text('👀', style: TextStyle(fontSize: 22, fontFamilyFallback: emojiFonts))),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AnimatedOpacity(
            opacity: remember ? 1 : 0,
            duration: const Duration(milliseconds: 400),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: hudGlass, borderRadius: BorderRadius.circular(8), border: Border.all(color: hudCyan)),
              child: const Text(
                '« Oui ! Hier vers 16 h 10, dans Chrome : Volcan — Wikipédia. »',
                style: TextStyle(color: hudCyan, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Il prend les devants : une idée avec Oui / Non, et le presse-papier malin.
class _IdeaVisual extends StatelessWidget {
  const _IdeaVisual();

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) {
      final ideas = [
        ('💡', 'Ça fait 45 min de YouTube et t\'as SVT demain. On fait 25 minutes ?'),
        ('📥', 'Tu viens de télécharger « DM_maths.pdf ». Je le range dans Cours/Maths ?'),
        ('📋', 'C\'est en anglais : je te le traduis ?'),
        ('💬', 'Lucas t\'a écrit « tu viens ce soir ? ». Je te prépare une réponse ?'),
      ];
      final (emoji, text) = ideas[((t / 3.5).floor()) % ideas.length];
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        child: _Panel(
          key: ValueKey(text),
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 26, fontFamilyFallback: emojiFonts)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4))),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (label, fill) in const [('Plus tard', false), ('Non', false), ('Oui', true)])
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: fill ? hudCyan : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: hudCyan),
                        ),
                        child: Text(label, style: TextStyle(color: fill ? Colors.black : hudCyan, fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// « Préviens-moi quand… » : les alertes qui arrivent.
class _WatchVisual extends StatelessWidget {
  const _WatchVisual();

  static const alerts = [
    ('🔔', 'Ta note de maths est tombée', '15/20 · Contrôle de géométrie'),
    ('💬', 'Lucas t\'a écrit', '« tu viens ce soir ? »'),
    ('💸', 'Hades est en promo', 'de 24,99 € à 12,49 €'),
    ('📶', 'Internet est revenu !', 'Tu peux reprendre ta partie'),
  ];

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) {
      final shown = ((t % 10) / 2).floor().clamp(0, alerts.length);
      return SizedBox(
        width: 380,
        height: 300,
        child: Column(
          children: [
            for (var i = 0; i < shown; i++)
              TweenAnimationBuilder<double>(
                key: ValueKey('$i-${(t / 10).floor()}'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutBack,
                builder: (context, v, child) => Opacity(
                  opacity: v.clamp(0.0, 1.0),
                  child: Transform.translate(offset: Offset(40 * (1 - v), 0), child: child),
                ),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF12263A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: [
                      Text(alerts[i].$1, style: const TextStyle(fontSize: 24, fontFamilyFallback: emojiFonts)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(alerts[i].$2, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                            Text(alerts[i].$3, style: const TextStyle(color: Colors.white60)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Toute ta vie : les tuiles qui apparaissent en cascade.
class _LifeGridVisual extends StatelessWidget {
  const _LifeGridVisual();

  static const tiles = [
    ('🎵', 'Musique'),
    ('💰', 'Abonnements'),
    ('📦', 'Colis'),
    ('📱', 'Téléphone'),
    ('🎉', 'Soirée'),
    ('🎂', 'Anniversaires'),
    ('🌙', 'Sommeil'),
    ('🛡️', 'Sécurité'),
    ('🔎', 'Recherche'),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < tiles.length; i++)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Duration(milliseconds: 350 + 110 * i),
            curve: Curves.easeOutBack,
            builder: (context, v, child) => Transform.scale(scale: v, child: child),
            child: Container(
              width: 104,
              height: 92,
              decoration: BoxDecoration(
                color: const Color(0xFF12263A),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: hudCyan.withValues(alpha: 0.3)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(tiles[i].$1, style: const TextStyle(fontSize: 30, fontFamilyFallback: emojiFonts)),
                  const SizedBox(height: 6),
                  Text(tiles[i].$2, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// Clicky vivant : le vrai curseur avec ses émojis qui changent.
class _AliveVisual extends StatefulWidget {
  const _AliveVisual();

  @override
  State<_AliveVisual> createState() => _AliveVisualState();
}

class _AliveVisualState extends State<_AliveVisual> {
  final life = ClickyLife();
  Timer? _t;
  int _k = 0;

  static const moods = ['💤', '🥱', '🎵', '😵‍💫', '🥰', '🤩'];
  static const says = [
    'Il fait la sieste quand tu pars…',
    'Il bâille le soir.',
    'Il danse sur ta musique.',
    'Tu as secoué la souris !',
    'Une caresse : il adore.',
    'Bonne note : il saute de joie.',
  ];

  @override
  void initState() {
    super.initState();
    life.refreshAccessory(DateTime(2026, 1, 15), weather: const {'temperature': 1.0, 'maintenant': '1 °C'});
    _apply();
    _t = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (mounted) setState(_apply);
    });
  }

  void _apply() {
    final m = moods[_k % moods.length];
    life
      ..wake()
      ..setDancing(m == '🎵');
    if (m == '💤') {
      life.fallAsleep();
    } else if (m == '🎵') {
      for (var i = 0; i < 4; i++) {
        Timer(Duration(milliseconds: 420 * i), () {
          if (mounted) life.onBeat(steady: true);
        });
      }
    } else {
      if (m == '😵‍💫') life.wobble.value++;
      life.show(m, seconds: 1.6);
    }
    _k++;
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 260,
        height: 220,
        child: Center(
          child: Transform.scale(
            scale: 3.2,
            child: SizedBox(
              width: 60,
              height: 50,
              child: Align(
                alignment: Alignment.topLeft,
                child: ClickyLifeBody(
                  life: life,
                  child: CustomPaint(size: const Size(22, 22), painter: _CursorPainter()),
                ),
              ),
            ),
          ),
        ),
      ),
      Text(says[(_k - 1) % says.length], style: const TextStyle(color: hudCyan, fontSize: 16, fontStyle: FontStyle.italic)),
    ],
  );
}

/// Le curseur bleu de Clicky.
class _CursorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, s.height * 0.42)
      ..lineTo(s.width * 0.45, s.height * 0.55)
      ..lineTo(s.width * 0.32, s.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF3B82F6));
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
