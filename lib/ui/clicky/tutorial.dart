import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/module_store.dart';
import '../../modules/music/cd_case.dart';
import '../../modules/music/music_models.dart';
import 'board.dart';
import 'holo.dart';
import 'hud.dart';
import 'marks.dart';

/// Visite guidée de Clicky, montrée à la création du compte (et après une
/// grosse mise à jour) : chaque page présente une capacité en animation.
class ClickyTutorial extends StatefulWidget {
  const ClickyTutorial({super.key, this.onBrain});

  /// « Choisir son cerveau » (réglages de Claude et Clicky).
  final VoidCallback? onBrain;

  static const _seenKey = 'tutorial.v124';

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
}

class _ClickyTutorialState extends State<ClickyTutorial> {
  final pages = PageController();
  int page = 0;

  static const _count = 8;

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

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      const _Page(
        title: 'Salut, moi c\'est Clicky',
        text:
            'Ton assistant personnel, façon JARVIS. Je vis à côté de ta souris, je vois ton écran, '
            'je parle, je montre, j\'explique, et je m\'occupe de tes trucs.',
        visual: _BootVisual(),
      ),
      const _Page(
        title: 'Parle-moi',
        text:
            'Maintiens Ctrl + Alt et parle, relâche pour envoyer. Appui court : tu écris. '
            'Ou active le mot d\'activation et dis simplement « Clicky ».',
        visual: _KeysVisual(),
      ),
      const _Page(
        title: 'Je vois et je montre',
        text:
            'Je vois ton écran : mon curseur vole jusqu\'au bon bouton, et je dessine dessus '
            '(flèches, cercles) pour que tu comprennes. « Fais-le pour moi » : je clique à ta place, '
            'après ton accord.',
        visual: _PointVisual(),
      ),
      _Page(
        title: 'Je t\'explique comme un prof',
        text:
            'Tableaux visuels, schémas, étapes, quiz. Je note ce qu\'on apprend et je te fais réviser '
            'au bon moment.',
        visual: _BoardVisual(),
      ),
      const _Page(
        title: 'Hologrammes 3D',
        text: 'Molécules, planètes, solides… je les projette en 3D. Glisse pour les faire tourner.',
        visual: SizedBox(width: 420, child: HoloView(scene: HoloScene.demo)),
      ),
      const _Page(
        title: 'Ton carnet',
        text:
            '« Retiens que… », « note ça », « j\'ai dépensé 12 € », « 80 kg au squat », « protocole travail », '
            '« qu\'est-ce que je mets aujourd\'hui ? ». Je range tout dans ton Carnet.',
        visual: _CarnetVisual(),
      ),
      const _Page(
        title: 'Ta musique',
        text:
            'Ce que tu écoutes sur Spotify ou Deezer, la pochette qui tourne, la tracklist au dos. '
            '« Mets ma playlist chill », « monte le son ».',
        visual: SizedBox(width: 340, child: _MusicVisual()),
      ),
      _Page(
        title: 'Prêt ?',
        text:
            'Choisis mon cerveau (ton abonnement Claude Pro), puis maintiens Ctrl + Alt. '
            'Mon Hub se met à jour tout seul : tu auras toujours mes nouveautés.',
        visual: const _BootVisual(small: true),
        action: widget.onBrain == null
            ? null
            : (
                'Choisir mon cerveau',
                () {
                  Navigator.of(context).maybePop();
                  widget.onBrain!();
                },
              ),
      ),
    ];
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
                  Align(
                    alignment: Alignment.topRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Passer', style: TextStyle(color: Colors.white54)),
                    ),
                  ),
                  Expanded(
                    child: PageView(
                      controller: pages,
                      onPageChanged: (i) => setState(() => page = i),
                      children: children,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: Row(
                      children: [
                        for (var i = 0; i < _count; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.only(right: 6),
                            width: i == page ? 26 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == page ? hudCyan : Colors.white24,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        const Spacer(),
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
  const _Page({required this.title, required this.text, required this.visual, this.action});
  final String title;
  final String text;
  final Widget visual;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth > 820;
      final words = Column(
        crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            text,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: const TextStyle(color: Color(0xFFB7D9E6), fontSize: 16, height: 1.5),
          ),
          if (action != null) ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: hudCyan,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.key_rounded),
              label: Text(action!.$1),
              onPressed: action!.$2,
            ),
          ],
        ],
      );
      final art = Center(child: _Appear(child: visual));
      if (wide) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 56),
          child: Row(
            children: [
              Expanded(child: art),
              const SizedBox(width: 40),
              Expanded(child: words),
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

class _CarnetVisual extends StatelessWidget {
  const _CarnetVisual();

  static const items = [
    (Icons.psychology_alt_rounded, 'Mémoire'),
    (Icons.lightbulb_rounded, 'Idées'),
    (Icons.checklist_rounded, 'Tâches'),
    (Icons.savings_rounded, 'Budget'),
    (Icons.fitness_center_rounded, 'Sport'),
    (Icons.sports_esports_rounded, 'Jeux'),
    (Icons.wb_sunny_rounded, 'Météo'),
    (Icons.play_circle_rounded, 'Protocoles'),
    (Icons.edit_note_rounded, 'Poèmes'),
  ];

  @override
  Widget build(BuildContext context) => _Ticker(
    builder: (t) => SizedBox(
      width: 380,
      child: Wrap(
        spacing: 14,
        runSpacing: 14,
        alignment: WrapAlignment.center,
        children: [
          for (final (i, (icon, label)) in items.indexed)
            Transform.translate(
              offset: Offset(0, math.sin(t * 1.6 + i) * 4),
              child: Opacity(
                opacity: ((t * 2 - i * 0.25)).clamp(0.0, 1.0),
                child: Container(
                  width: 110,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E2236),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: hudCyan.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Icon(icon, color: hudCyan, size: 30),
                      const SizedBox(height: 6),
                      Text(label, style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _MusicVisual extends StatelessWidget {
  const _MusicVisual();

  @override
  Widget build(BuildContext context) => const SpinningCdCase(
    period: Duration(seconds: 8),
    front: CdCaseFront(color: musicRed),
    back: CdCaseBack(
      title: 'mon album',
      artist: 'artiste',
      current: 2,
      tracks: [
        MusicTrack(title: 'Intro'),
        MusicTrack(title: 'Le morceau que tu écoutes'),
        MusicTrack(title: 'Interlude'),
        MusicTrack(title: 'Outro'),
      ],
    ),
  );
}
