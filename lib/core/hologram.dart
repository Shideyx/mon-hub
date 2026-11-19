import 'dart:convert';

import 'ai_text.dart';
import 'tool_router.dart';

/// Les hologrammes de la réalité augmentée : objets prêts (dessinés par le
/// code de la page 3D) et objets inventés par l'IA.
///
/// Un objet inventé est une **recette** (formes simples, couleurs,
/// positions) : uniquement des données, jamais du code. Elle est vérifiée
/// ici ([parse]) puis encore dans la page.
class Hologram {
  Hologram._();

  /// id → (nom affiché, mots qui l'appellent).
  static const objects = <String, (String, List<String>)>{
    'dino': ('le T-rex', ['t rex', 'trex', 'dino', 'dinosaure', 'tyrannosaure']),
    'clicky': ('Clicky', ['clicky', 'fleche', 'curseur']),
    'systeme': ('le système solaire', ['systeme solaire', 'soleil', 'planetes']),
    'planete': ('la planète', ['planete', 'saturne']),
    'coeur': ('le cœur', ['coeur']),
    'fusee': ('la fusée', ['fusee']),
    'diamant': ('le diamant', ['diamant', 'pierre precieuse']),
    'cube': ('le cube magique', ['cube', 'rubik']),
  };

  static const modes = ['air', 'main', 'table'];

  /// L'objet prêt qui correspond à [text] (« un dinosaure » → dino).
  static String? match(String text) {
    final n = ' ${ToolRouter.normalize(text.replaceAll(RegExp('[œŒ]'), 'oe')).replaceAll(RegExp(r"[^a-z0-9]+"), ' ')} ';
    for (final e in objects.entries) {
      if (e.value.$2.any((w) => n.contains(' $w ') || n.contains(' ${w}s '))) return e.key;
    }
    return null;
  }

  static String labelOf(String id) => objects[id]?.$1 ?? id;

  /// La consigne donnée à l'IA pour fabriquer [what].
  static String prompt(String what) =>
      'Fabrique un petit modèle 3D de « $what » avec des formes simples, pour un hologramme.\n'
      'Réponds UNIQUEMENT avec un objet JSON, sans texte autour :\n'
      '{"nom": "nom court en français", "pieces": [{"forme": "sphere|boite|cylindre|cone|tore|capsule", '
      '"couleur": "#rrggbb", "pos": [x, y, z], "taille": [largeur, hauteur, profondeur], "rot": [rx, ry, rz], '
      '"matiere": "mat|brillant|metal|verre|lumineux"}]}\n'
      'Règles : entre 8 et 45 pièces ; y vers le haut, l\'objet posé sur y = 0 ; son avant regarde vers +z ; '
      'unités libres (il sera remis à la bonne taille) ; rot en degrés ; taille = dimensions de la pièce '
      '(une sphere [1,1,1] fait 1 de diamètre, un cylindre [1,1,1] fait 1 de diamètre et 1 de haut). '
      'Assemble les pièces pour que l\'objet soit bien reconnaissable : bonnes proportions, détails '
      'caractéristiques, couleurs réalistes.';

  static const shapes = {'sphere', 'boite', 'cylindre', 'cone', 'tore', 'capsule'};
  static const materials = {'mat', 'brillant', 'metal', 'verre', 'lumineux'};
  static const maxPieces = 60;

  /// La recette nettoyée, ou null si la réponse n'en contient pas.
  static Map<String, dynamic>? parse(String answer) {
    final a = answer.indexOf('{');
    final b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Object? data;
    try {
      data = jsonDecode(answer.substring(a, b + 1));
    } catch (_) {
      return null;
    }
    if (data is! Map) return null;
    final raw = data['pieces'];
    if (raw is! List) return null;
    List<double> vec(Object? v, double def, double lo, double hi) => [
      for (var i = 0; i < 3; i++)
        (v is List && i < v.length && v[i] is num && (v[i] as num).isFinite)
            ? (v[i] as num).toDouble().clamp(lo, hi)
            : def,
    ];
    final pieces = <Map<String, dynamic>>[];
    for (final p in raw) {
      if (pieces.length >= maxPieces) break;
      if (p is! Map) continue;
      final forme = ToolRouter.normalize('${p['forme'] ?? ''}').trim();
      if (!shapes.contains(forme)) continue;
      final c = '${p['couleur'] ?? ''}'.trim();
      final m = ToolRouter.normalize('${p['matiere'] ?? ''}').trim();
      pieces.add({
        'forme': forme,
        'couleur': RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(c) ? c : '#cccccc',
        'pos': vec(p['pos'], 0, -10, 10),
        'taille': vec(p['taille'], 0.2, 0.005, 10),
        'rot': vec(p['rot'], 0, -360, 360),
        'matiere': materials.contains(m) ? m : 'mat',
      });
    }
    if (pieces.isEmpty) return null;
    var nom = '${data['nom'] ?? ''}'.replaceAll(RegExp(r'[<>\n\r]'), '').trim();
    if (nom.length > 40) nom = nom.substring(0, 40);
    return {'nom': nom, 'pieces': pieces};
  }

  /// Demande à l'IA (Gemini d'abord) de fabriquer [what].
  static Future<Map<String, dynamic>?> invent(String what) async {
    final w = what.trim();
    if (w.isEmpty || w.length > 80) return null;
    final answer = await AiText.ask(
      prompt(w),
      system: 'Tu es un modéliste 3D précis. Tu réponds seulement en JSON valide.',
    );
    return parse(answer);
  }
}
