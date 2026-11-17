import 'dart:convert';

import 'package:material_ui/material_ui.dart';

/// « Clicky agit » : Clicky prend vraiment la souris et le clavier pour faire
/// une tâche sur l'ordinateur, pas à pas, en regardant l'écran à chaque fois
/// (comme une personne) : il vole jusqu'à l'endroit, clique, fait défiler,
/// écrit, ouvre des applis, passe d'une fenêtre à l'autre…
///
/// À chaque tour, l'IA reçoit les captures d'écran, la liste des fenêtres
/// et ce qui a déjà été fait, et répond par **une** action en JSON.
/// Garde-fous : Échap arrête tout, bouger la souris aussi ; rien n'est tapé
/// dans une fenêtre sensible ; les commandes passent par la permission.
class ActStep {
  const ActStep(this.action, this.args, {this.thought = ''});

  /// clic, double_clic, clic_droit, deplacer, ecrire, touches, defiler,
  /// glisser, ouvrir, fenetre, commande, attendre, fini.
  final String action;
  final Map<String, dynamic> args;

  /// Ce que Clicky pense / va faire (montré à la personne).
  final String thought;

  num? n(String k) => args[k] is num ? args[k] as num : num.tryParse('${args[k] ?? ''}');
  String s(String k) => '${args[k] ?? ''}';

  /// Point visé sur la capture (x, y) et numéro d'écran.
  (Offset, int)? get point {
    final x = n('x'), y = n('y');
    if (x == null || y == null) return null;
    return (Offset(x.toDouble(), y.toDouble()), (n('ecran') ?? 1).toInt());
  }

  bool get done => action == 'fini' || action == 'termine' || action == 'stop';

  String get describe => switch (action) {
    'clic' => 'Clic${s('libelle').isEmpty ? '' : ' sur « ${s('libelle')} »'}',
    'double_clic' => 'Double-clic${s('libelle').isEmpty ? '' : ' sur « ${s('libelle')} »'}',
    'clic_droit' => 'Clic droit${s('libelle').isEmpty ? '' : ' sur « ${s('libelle')} »'}',
    'deplacer' => 'Je déplace la souris',
    'ecrire' => 'J\'écris « ${s('texte').length > 40 ? '${s('texte').substring(0, 37)}…' : s('texte')} »',
    'touches' => 'Touches ${s('touches')}',
    'defiler' => (n('crans') ?? -3) > 0 ? 'Je remonte' : 'Je fais défiler',
    'glisser' => 'Je fais glisser',
    'ouvrir' => 'J\'ouvre ${s('cible')}',
    'fenetre' => 'Fenêtre : ${s('faire').isEmpty ? 'activer' : s('faire')}',
    'commande' => 'Commande sur le PC',
    'attendre' => 'J\'attends',
    _ => action,
  };

  /// Lit la réponse de l'IA : le premier objet JSON trouvé.
  static ActStep? parse(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    // Cherche la fin de l'objet (accolades équilibrées, hors chaînes).
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < raw.length; i++) {
      final c = raw[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') inStr = true;
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) {
          try {
            final j = jsonDecode(raw.substring(start, i + 1));
            if (j is! Map) return null;
            final m = j.cast<String, dynamic>();
            final action = '${m['action'] ?? m['type'] ?? ''}'.toLowerCase().trim().replaceAll(' ', '_');
            if (action.isEmpty) return null;
            return ActStep(action, m, thought: '${m['pense'] ?? m['pensee'] ?? m['thought'] ?? ''}'.trim());
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  /// Consignes pour l'IA à chaque tour.
  static String guide({required int screens}) =>
      '''
Tu es Clicky et tu PILOTES l'ordinateur de la personne (Windows) pour atteindre un but, pas à pas, comme un humain : tu regardes l'écran, tu fais UNE action, puis tu regardes de nouveau.
Réponds UNIQUEMENT par un objet JSON (rien avant ni après) :
{"pense":"ce que je vois et ce que je fais (une phrase courte, en français)","action":"…", …}
Actions possibles :
- {"action":"clic","x":…,"y":…,"ecran":1,"libelle":"Rechercher"} (aussi "double_clic", "clic_droit", "deplacer")
- {"action":"ecrire","texte":"…"} (tape le texte là où le curseur est ; clique d'abord dans le champ)
- {"action":"touches","touches":"ctrl+l"} (raccourcis : enter, tab, esc, ctrl+c, alt+tab, win, ctrl+t, f5, haut, bas…)
- {"action":"defiler","crans":-5,"x":…,"y":…} (négatif = descendre, positif = monter ; x,y = où mettre la souris, facultatif ; "horizontal":true pour gauche/droite)
- {"action":"glisser","x":…,"y":…,"x2":…,"y2":…,"ecran":1}
- {"action":"ouvrir","cible":"https://… | notepad | spotify | C:\\\\chemin | ms-settings:display"} (ouvre un site, une appli, un fichier, un dossier ou un réglage : souvent le plus rapide)
- {"action":"fenetre","id":123,"faire":"activer|reduire|agrandir|restaurer|fermer"} (id de la liste des fenêtres)
- {"action":"commande","commande":"…","pourquoi":"…"} (commande PowerShell, seulement si c'est vraiment plus simple que la souris)
- {"action":"attendre","ms":1500} (une page qui charge)
- {"action":"fini","message":"ce qui a été fait, en une ou deux phrases à dire à voix haute"} (but atteint, ou impossible : explique pourquoi)
Règles :
- x,y en pixels sur la capture${screens > 1 ? ' de l\'écran indiqué par "ecran"' : ''}, au centre de l'élément visé. Vise précisément.
- Une seule action par réponse. Vérifie sur la nouvelle capture que l'action a marché avant de continuer.
- Jamais de mot de passe, de paiement, d'achat ou de suppression que la personne n'a pas demandés ; dans ce cas, termine avec "fini" et explique.
- Si une fenêtre de connexion ou une question personnelle bloque, termine avec "fini" et demande à la personne.
- Sois efficace : au plus 30 actions.''';
}

/// Ce qui a été fait (pour le prochain tour).
@immutable
class ActLog {
  const ActLog(this.step, this.result);
  final ActStep step;
  final String result;

  @override
  String toString() =>
      '${step.describe}${step.thought.isEmpty ? '' : ' (${step.thought})'} → $result';
}
