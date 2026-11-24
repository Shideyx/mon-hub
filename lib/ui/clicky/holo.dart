import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'hud.dart';

/// Un objet d'un hologramme 3D.
class HoloObject {
  const HoloObject({
    required this.shape,
    this.pos = const [0, 0, 0],
    this.size = 1,
    this.tilt = 0,
    this.label = '',
    this.color,
  });

  /// cube, sphere, cylindre, cone, pyramide, anneau, tore, helice, axes,
  /// fleche, point.
  final String shape;
  final List<double> pos;
  final double size;

  /// Inclinaison (degrés) autour de l'axe X (anneaux, cylindres…).
  final double tilt;
  final String label;
  final Color? color;
}

/// Un hologramme 3D (comme les modèles flottants de JARVIS dans Iron Man) :
/// des formes simples en fil de fer qui tournent, qu'on peut faire pivoter à
/// la souris.
class HoloScene {
  const HoloScene({required this.title, required this.objects, this.links = const []});
  final String title;
  final List<HoloObject> objects;

  /// Liaisons entre objets (molécules, réseaux…) : (de, à).
  final List<(int, int)> links;

  static final _re = RegExp(r'\[HOLO\]([\s\S]*?)\[/HOLO\]', caseSensitive: false);
  static final _open = RegExp(r'\[HOLO\][\s\S]*$', caseSensitive: false);

  /// Retire les hologrammes (même à moitié écrits) du texte.
  static String strip(String raw) => raw.replaceAll(_re, ' ').replaceFirst(_open, '').trim();

  static bool writing(String raw) => _open.hasMatch(raw.replaceAll(_re, ''));

  static (String, HoloScene?) extract(String raw) {
    final m = _re.allMatches(raw).lastOrNull;
    final text = strip(raw);
    if (m == null) return (text, null);
    return (text, parse(m.group(1)!));
  }

  static const _names = {
    'cube': 'cube',
    'boite': 'cube',
    'boîte': 'cube',
    'box': 'cube',
    'sphere': 'sphere',
    'sphère': 'sphere',
    'boule': 'sphere',
    'planete': 'sphere',
    'planète': 'sphere',
    'cylindre': 'cylindre',
    'cylinder': 'cylindre',
    'cone': 'cone',
    'cône': 'cone',
    'pyramide': 'pyramide',
    'pyramid': 'pyramide',
    'tetraedre': 'pyramide',
    'anneau': 'anneau',
    'ring': 'anneau',
    'orbite': 'anneau',
    'cercle': 'anneau',
    'tore': 'tore',
    'torus': 'tore',
    'donut': 'tore',
    'helice': 'helice',
    'hélice': 'helice',
    'adn': 'helice',
    'dna': 'helice',
    'ressort': 'helice',
    'axes': 'axes',
    'repere': 'axes',
    'repère': 'axes',
    'fleche': 'fleche',
    'flèche': 'fleche',
    'vecteur': 'fleche',
    'arrow': 'fleche',
    'point': 'point',
    'atome': 'sphere',
    'atom': 'sphere',
  };

  static Color? _color(Object? c) {
    final s = '${c ?? ''}'.trim().toLowerCase();
    if (s.isEmpty) return null;
    final hex = RegExp(r'^#?([0-9a-f]{6})$').firstMatch(s);
    if (hex != null) return Color(0xFF000000 | int.parse(hex.group(1)!, radix: 16));
    return switch (s) {
      'rouge' || 'red' => const Color(0xFFFF5252),
      'orange' => const Color(0xFFFFA726),
      'jaune' || 'yellow' || 'or' => const Color(0xFFFFEB3B),
      'vert' || 'green' => const Color(0xFF69F0AE),
      'bleu' || 'blue' => const Color(0xFF448AFF),
      'violet' || 'purple' => const Color(0xFFB388FF),
      'rose' || 'pink' => const Color(0xFFFF80AB),
      'blanc' || 'white' => Colors.white,
      _ => null,
    };
  }

  static double _num(Object? v, double d) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? d;

  static HoloScene? parse(String src) {
    var s = src.trim();
    s = s.replaceFirst(RegExp(r'^```(?:json)?'), '').replaceFirst(RegExp(r'```$'), '').trim();
    try {
      final j = jsonDecode(s);
      if (j is! Map) return null;
      final objs = <HoloObject>[];
      for (final o in (j['objets'] as List?) ?? (j['objects'] as List?) ?? const []) {
        if (o is! Map) continue;
        final shape = _names['${o['forme'] ?? o['shape'] ?? ''}'.toLowerCase().trim()];
        if (shape == null) continue;
        final p = o['pos'] ?? o['position'];
        objs.add(
          HoloObject(
            shape: shape,
            pos: p is List && p.length >= 3
                ? [for (final x in p.take(3)) _num(x, 0).clamp(-4, 4).toDouble()]
                : const [0, 0, 0],
            size: _num(o['taille'] ?? o['size'], 1).clamp(0.05, 4).toDouble(),
            tilt: _num(o['inclinaison'] ?? o['tilt'], 0),
            label: '${o['label'] ?? o['nom'] ?? ''}',
            color: _color(o['couleur'] ?? o['color']),
          ),
        );
        if (objs.length >= 40) break;
      }
      if (objs.isEmpty) return null;
      final links = <(int, int)>[];
      for (final l in (j['liens'] as List?) ?? (j['links'] as List?) ?? const []) {
        if (l is List && l.length >= 2) {
          final a = _num(l[0], -1).toInt(), b = _num(l[1], -1).toInt();
          if (a >= 0 && b >= 0 && a < objs.length && b < objs.length) links.add((a, b));
        }
      }
      return HoloScene(title: '${j['titre'] ?? j['title'] ?? ''}', objects: objs, links: links);
    } catch (_) {
      return null;
    }
  }

  /// Exemple (tutoriel) : un atome.
  static const demo = HoloScene(
    title: 'Atome',
    objects: [
      HoloObject(shape: 'sphere', size: 0.45, label: 'Noyau', color: Color(0xFFFFA726)),
      HoloObject(shape: 'anneau', size: 1.5, tilt: 70),
      HoloObject(shape: 'anneau', size: 1.5, tilt: -55),
      HoloObject(shape: 'anneau', size: 1.5, tilt: 10),
      HoloObject(shape: 'point', pos: [1.5, 0, 0], size: 0.12, label: 'électron'),
    ],
  );

  /// Comment l'IA écrit un hologramme.
  static const guide = '''
Hologramme 3D (comme JARVIS) : quand un objet se comprend mieux en 3D (molécule, atome, planète et orbites, solide géométrique, ADN, structure, vecteurs), ajoute [HOLO]{json}[/HOLO] :
[HOLO]{"titre":"Molécule d'eau","objets":[{"forme":"sphere","pos":[0,0,0],"taille":0.5,"label":"O","couleur":"rouge"},{"forme":"sphere","pos":[0.9,0.6,0],"taille":0.3,"label":"H"},{"forme":"sphere","pos":[-0.9,0.6,0],"taille":0.3,"label":"H"}],"liens":[[0,1],[0,2]]}[/HOLO]
Formes : cube, sphere, cylindre, cone, pyramide, anneau (inclinaison en degrés), tore, helice, axes, fleche, point. pos = [x,y,z] entre -3 et 3, taille entre 0.1 et 3, couleur facultative. Au plus 25 objets. Il tourne tout seul ; ta réponse orale le présente en une phrase.''';
}

/// Segments 3D d'une forme (repère local, taille 1).
List<(List<double>, List<double>)> holoSegments(HoloObject o) {
  final out = <(List<double>, List<double>)>[];
  void seg(List<double> a, List<double> b) => out.add((a, b));
  List<List<double>> circle(double r, double y, int n, {double tilt = 0}) {
    final t = tilt * math.pi / 180;
    return [
      for (var i = 0; i <= n; i++)
        () {
          final a = i * 2 * math.pi / n;
          final x = r * math.cos(a), z = r * math.sin(a);
          // Inclinaison autour de X.
          return [x, y * math.cos(t) - z * math.sin(t), y * math.sin(t) + z * math.cos(t)];
        }(),
    ];
  }

  void poly(List<List<double>> pts) {
    for (var i = 0; i + 1 < pts.length; i++) {
      seg(pts[i], pts[i + 1]);
    }
  }

  switch (o.shape) {
    case 'cube':
      const v = [
        [-.5, -.5, -.5],
        [.5, -.5, -.5],
        [.5, .5, -.5],
        [-.5, .5, -.5],
        [-.5, -.5, .5],
        [.5, -.5, .5],
        [.5, .5, .5],
        [-.5, .5, .5],
      ];
      for (final (a, b) in const [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
      ]) {
        seg(v[a], v[b]);
      }
    case 'sphere':
      for (var k = 1; k < 6; k++) {
        final y = -0.5 + k / 6;
        poly(circle(math.sqrt(0.25 - y * y), y, 24));
      }
      for (var k = 0; k < 6; k++) {
        final a = k * math.pi / 6;
        poly([
          for (var i = 0; i <= 24; i++)
            () {
              final b = i * 2 * math.pi / 24;
              return [0.5 * math.sin(b) * math.cos(a), 0.5 * math.cos(b), 0.5 * math.sin(b) * math.sin(a)];
            }(),
        ]);
      }
    case 'cylindre':
      final top = circle(0.5, 0.5, 24, tilt: o.tilt), bottom = circle(0.5, -0.5, 24, tilt: o.tilt);
      poly(top);
      poly(bottom);
      for (var i = 0; i < 24; i += 3) {
        seg(top[i], bottom[i]);
      }
    case 'cone':
      final base = circle(0.5, -0.5, 24, tilt: o.tilt);
      final t = o.tilt * math.pi / 180;
      final apex = [0.0, 0.5 * math.cos(t), 0.5 * math.sin(t)];
      poly(base);
      for (var i = 0; i < 24; i += 3) {
        seg(base[i], apex);
      }
    case 'pyramide':
      const b = [
        [-.5, -.5, -.5],
        [.5, -.5, -.5],
        [.5, -.5, .5],
        [-.5, -.5, .5],
      ];
      const apex = [0.0, 0.5, 0.0];
      for (var i = 0; i < 4; i++) {
        seg(b[i], b[(i + 1) % 4]);
        seg(b[i], apex);
      }
    case 'anneau':
      poly(circle(0.5, 0, 48, tilt: o.tilt));
    case 'tore':
      for (var k = 0; k < 12; k++) {
        final a = k * 2 * math.pi / 12;
        poly([
          for (var i = 0; i <= 16; i++)
            () {
              final b = i * 2 * math.pi / 16;
              final r = 0.38 + 0.12 * math.cos(b);
              return [r * math.cos(a), 0.12 * math.sin(b), r * math.sin(a)];
            }(),
        ]);
      }
      poly(circle(0.5, 0, 36));
      poly(circle(0.26, 0, 36));
    case 'helice':
      List<List<double>> strand(double phase) => [
        for (var i = 0; i <= 80; i++)
          [0.3 * math.cos(i / 80 * 6 * math.pi + phase), -0.5 + i / 80, 0.3 * math.sin(i / 80 * 6 * math.pi + phase)],
      ];
      final s1 = strand(0), s2 = strand(math.pi);
      poly(s1);
      poly(s2);
      for (var i = 0; i <= 80; i += 6) {
        seg(s1[i], s2[i]);
      }
    case 'axes':
      seg(const [-.5, 0, 0], const [.5, 0, 0]);
      seg(const [0, -.5, 0], const [0, .5, 0]);
      seg(const [0, 0, -.5], const [0, 0, .5]);
    case 'fleche':
      seg(const [0, -.5, 0], const [0, .5, 0]);
      seg(const [0, .5, 0], const [.12, .32, 0]);
      seg(const [0, .5, 0], const [-.12, .32, 0]);
      seg(const [0, .5, 0], const [0, .32, .12]);
      seg(const [0, .5, 0], const [0, .32, -.12]);
    case 'point':
      for (final c in [circle(0.5, 0, 12), circle(0.5, 0, 12, tilt: 90)]) {
        poly(c);
      }
  }
  return out;
}

/// L'hologramme qui flotte : fil de fer lumineux, rotation, apparition
/// progressive, grille au sol, lignes de balayage. On le fait pivoter à la
/// souris.
class HoloView extends StatefulWidget {
  const HoloView({super.key, required this.scene, this.onClose, this.compact = false});
  final HoloScene scene;
  final VoidCallback? onClose;
  final bool compact;

  @override
  State<HoloView> createState() => _HoloViewState();
}

class _HoloViewState extends State<HoloView> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 14))
    ..repeat();
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();
  double _yaw = 0, _pitch = -0.35;

  @override
  void dispose() {
    _spin.dispose();
    _appear.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = GestureDetector(
      onPanUpdate: (d) => setState(() {
        _yaw += d.delta.dx * 0.01;
        _pitch = (_pitch + d.delta.dy * 0.01).clamp(-1.4, 1.4);
      }),
      child: AnimatedBuilder(
        animation: Listenable.merge([_spin, _appear]),
        builder: (context, _) => CustomPaint(
          painter: _HoloPainter(
            widget.scene,
            yaw: _yaw + _spin.value * 2 * math.pi,
            pitch: _pitch,
            appear: Curves.easeOutCubic.transform(_appear.value),
            scan: _spin.value,
          ),
          size: Size.infinite,
        ),
      ),
    );
    return HudFrame(
      child: SizedBox(
        height: widget.compact ? 220 : 300,
        child: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              left: 14,
              top: 10,
              right: 40,
              child: Text(
                'HOLOGRAMME · ${widget.scene.title.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: hudCyan, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w700),
              ),
            ),
            if (widget.onClose != null)
              Positioned(
                right: 4,
                top: 0,
                child: IconButton(
                  tooltip: 'Fermer',
                  icon: const Icon(Icons.close_rounded, color: hudCyan, size: 18),
                  onPressed: widget.onClose,
                ),
              ),
            const Positioned(
              left: 14,
              bottom: 8,
              child: Text(
                'glisse pour tourner',
                style: TextStyle(color: Color(0x8829E6FF), fontSize: 10, letterSpacing: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoloPainter extends CustomPainter {
  _HoloPainter(this.scene, {required this.yaw, required this.pitch, required this.appear, required this.scan});
  final HoloScene scene;
  final double yaw, pitch, appear, scan;

  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height * 0.54);
    final scale = math.min(s.width, s.height) * 0.26;
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    (Offset, double) project(List<double> p) {
      // Rotation Y puis X, puis perspective.
      final x1 = p[0] * cy + p[2] * sy, z1 = -p[0] * sy + p[2] * cy;
      final y2 = p[1] * cp - z1 * sp, z2 = p[1] * sp + z1 * cp;
      final f = 4 / (4 + z2);
      return (c + Offset(x1 * scale * f, -y2 * scale * f), z2);
    }

    // Grille au sol (disque) et faisceau.
    final floor = Paint()
      ..color = hudCyan.withValues(alpha: 0.18 * appear)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var r = 0.6; r <= 2.4; r += 0.6) {
      final pts = [
        for (var i = 0; i <= 40; i++)
          project([r * math.cos(i * math.pi / 20), -1.6, r * math.sin(i * math.pi / 20)]).$1,
      ];
      canvas.drawPath(Path()..addPolygon(pts, false), floor);
    }
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - 6, s.height)
        ..lineTo(c.dx - scale * 1.6, c.dy + scale * 1.4)
        ..lineTo(c.dx + scale * 1.6, c.dy + scale * 1.4)
        ..lineTo(c.dx + 6, s.height)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            hudCyan.withValues(alpha: 0.18 * appear),
            hudCyan.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, c.dy, s.width, s.height - c.dy)),
    );

    // Objets.
    final total = scene.objects.length;
    for (var k = 0; k < total; k++) {
      final o = scene.objects[k];
      final show = ((appear * (total + 1)) - k).clamp(0.0, 1.0);
      if (show <= 0) continue;
      final color = o.color ?? hudCyan;
      final segs = holoSegments(o);
      final n = (segs.length * show).ceil();
      final glow = Paint()
        ..color = color.withValues(alpha: 0.18)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      final line = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      List<double> world(List<double> p) => [
        p[0] * o.size + o.pos[0],
        p[1] * o.size + o.pos[1],
        p[2] * o.size + o.pos[2],
      ];
      for (var i = 0; i < n; i++) {
        final (a, b) = segs[i];
        final (pa, za) = project(world(a));
        final (pb, _) = project(world(b));
        final depth = (1 - (za + 2) / 6).clamp(0.35, 1.0);
        canvas.drawLine(pa, pb, glow..color = color.withValues(alpha: 0.16 * depth));
        canvas.drawLine(pa, pb, line..color = color.withValues(alpha: 0.95 * depth));
      }
      if (o.label.isNotEmpty && show >= 1) {
        final (p, _) = project([o.pos[0], o.pos[1] + o.size * 0.6, o.pos[2]]);
        final tp = TextPainter(
          text: TextSpan(
            text: o.label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 140);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height + 2));
      }
    }
    // Liaisons.
    final bond = Paint()
      ..color = Colors.white.withValues(alpha: 0.7 * appear)
      ..strokeWidth = 2;
    for (final (a, b) in scene.links) {
      final pa = project(scene.objects[a].pos).$1, pb = project(scene.objects[b].pos).$1;
      canvas.drawLine(pa, Offset.lerp(pa, pb, appear)!, bond);
    }
    // Ligne de balayage.
    final y = s.height * ((scan * 3) % 1);
    canvas.drawRect(Rect.fromLTWH(0, y, s.width, 2), Paint()..color = hudCyan.withValues(alpha: 0.12));
  }

  @override
  bool shouldRepaint(_HoloPainter o) => true;
}

/// Petit minuteur qui fait apparaître l'hologramme quelques secondes (aperçu
/// des tutoriels).
class HoloPreview extends StatelessWidget {
  const HoloPreview({super.key, this.scene = HoloScene.demo});
  final HoloScene scene;

  @override
  Widget build(BuildContext context) => HoloView(scene: scene, compact: true);
}
