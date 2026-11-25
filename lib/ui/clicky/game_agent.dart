import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/game_pal.dart';
import '../../core/hub_module.dart';
import '../../core/token_budget.dart';
import 'game_input.dart';
import 'shot_encode.dart';
import 'tutor.dart' show normalize;
import 'win.dart';

/// Une action dans le jeu.
@immutable
class GameAction {
  const GameAction(this.type, this.args);

  /// touche, maintenir, regarder, clic, glisser, maintenir_clic, molette,
  /// commande, attendre, fini.
  final String type;
  final Map<String, dynamic> args;

  num? n(String k) => args[k] is num ? args[k] as num : num.tryParse('${args[k] ?? ''}');
  String s(String k) => '${args[k] ?? ''}'.trim();
  bool b(String k) => args[k] == true || '${args[k]}' == 'true';
  bool get right => s('bouton').toLowerCase().startsWith('d') || s('bouton').toLowerCase() == 'right';

  /// Ce que Nexo fait, en mots simples (bulle).
  String get describe => switch (type) {
    'touche' => 'Touche ${s('touche').toUpperCase()}',
    'maintenir' => 'Je ${_moves(args['touches'])}',
    'regarder' => 'Je tourne la caméra',
    'clic' => b('maj') ? 'Maj + clic' : (right ? 'Clic droit' : 'Clic'),
    'glisser' => 'Je déplace un objet',
    'maintenir_clic' => right ? 'J\'utilise' : 'Je mine / je frappe',
    'molette' => 'Je change d\'objet',
    'commande' => 'Commande ${s('texte')}',
    'attendre' => 'J\'attends',
    _ => type,
  };

  static String _moves(Object? keys) {
    final l = [
      for (final k in (keys is List ? keys : [keys])) '$k',
    ];
    if (l.contains('avancer')) return l.contains('courir') ? 'cours' : 'avance';
    if (l.contains('reculer')) return 'recule';
    if (l.contains('gauche') || l.contains('droite')) return 'me décale';
    if (l.contains('saut') || l.contains('espace')) return 'saute';
    return 'maintiens ${l.join(' + ')}';
  }
}

/// Un tour : ce que Nexo voit et les actions qu'il fait.
@immutable
class GamePlan {
  const GamePlan(this.thought, this.actions);
  final String thought;
  final List<GameAction> actions;

  GameAction? get done => actions.where((a) => a.type == 'fini').firstOrNull;
}

/// Les règles de l'agent de jeu, **sans Windows ni réseau** (testables).
class GameAgentRules {
  GameAgentRules._();

  /// Au plus tant de tours (chacun : une capture + 1 à 4 actions).
  static const maxSteps = 25;

  /// Jeux en ligne avec anti-triche : jouer à ta place pourrait faire
  /// **bannir ton compte**. Là, Nexo coache seulement.
  static final blocked = RegExp(
    r'valorant|fortnite|counter.?strike|\bcs ?2\b|\bcsgo\b|apex|rainbow ?six|\br6\b|league of legends|\blol\b|'
    r'overwatch|call of duty|warzone|rocket league|pubg|dota|roblox|\brust\b|tarkov|the finals|marvel rivals|'
    r'genshin|honkai|lost ark|world of warcraft|\bwow\b|final fantasy xiv|ffxiv|destiny|battlefield|'
    r'rainbow|league|hearthstone|clash|brawl stars|fifa|ea sports fc|\bfc ?2[4-9]\b|deadlock|naraka',
    caseSensitive: false,
  );

  static bool isBlocked(String game) => blocked.hasMatch(game);

  static String blockedText(String game) =>
      'Dans $game, je ne joue pas à ta place : c\'est un jeu en ligne avec un anti-triche, ton compte pourrait '
      'être banni. Je peux te coacher par contre (« coach-moi »).';

  static bool isMinecraft(String game) => RegExp(r'minecraft|\bmc\b', caseSensitive: false).hasMatch(game);

  static final _context = RegExp(
    r'\b(?:dans|sur|en) (?:le jeu|mon jeu|ma partie|minecraft|mc|mon monde|le monde)\b|\bjoue a ma place\b|'
    r'\bfais le (?:pour moi|a ma place) dans le jeu\b',
  );

  static final _gameVerbs = RegExp(
    r'^(?:(?:est ce que )?(?:tu peux |peux tu |tu pourrais )?)?(?:me )?'
    r'(?:crafte|craft|crafter|fabrique|fabriquer|construis|construire|mine|miner|casse|pose|place|equipe|mange|'
    r'saute|avance|recule|tourne toi|retourne toi|va (?:devant|a gauche|a droite|en avant|tout droit)|prends|range|'
    r'jette|selectionne|recharge|ouvre (?:mon |l |le |la )?(?:inventaire|coffre|four|table|sac|carte|map)|'
    r'ferme (?:mon |l |le |la )?(?:inventaire|coffre|menu)|tape la commande|fais (?:moi )?(?:une|un|des) (?:pioche|hache|epee|pelle|table|torche|four|coffre|lit|porte|planches|batons)|'
    r'mets (?:le jour|la nuit|la pluie|le beau temps)|passe en (?:creatif|survie))\b',
  );

  /// La phrase demande-t-elle d'agir dans le jeu ? [gameInFront] : un jeu est
  /// au premier plan (alors un simple « craft-moi une pioche » suffit).
  static bool isRequest(String sentence, {bool gameInFront = false}) {
    final n = normalize(sentence)
        .replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh) )?(?:nexo|nexos|nekso|nexou)\s?'), '')
        .replaceFirst(RegExp(r'^(?:s il te plait|stp) '), '')
        .trim();
    if (n.isEmpty ||
        n.endsWith('?') ||
        RegExp(r'^(?:comment|pourquoi|c est quoi|qu est ce|quel|quelle)\b').hasMatch(n)) {
      return false;
    }
    if (_context.hasMatch(n) && _gameVerbs.hasMatch(n.replaceFirst(_context, '').trim())) return true;
    if (_context.hasMatch(n) && RegExp(r'\b(?:craft|fabrique|construis|mine|ouvre|pose|fais moi)\b').hasMatch(n)) {
      return true;
    }
    return gameInFront && _gameVerbs.hasMatch(n);
  }

  /// Ce que Nexo sait du jeu (touches, menus, recettes).
  static String playbook(String game) {
    if (isMinecraft(game)) return minecraft;
    return '''Jeu : $game. Observe les menus et les touches affichées à l'écran. Contrôles PC habituels : avancer/reculer/gauche/droite (ZQSD ou WASD), espace pour sauter, E, I ou Tab pour l'inventaire, Échap pour le menu, clic gauche pour frapper/utiliser.''';
  }

  static const minecraft = '''MINECRAFT (Java, touches par défaut) :
- E = ouvrir / fermer l'inventaire ; Échap = fermer un menu ; 1 à 9 = barre d'objets ; clic gauche = miner / frapper ; clic droit = utiliser, poser, ouvrir (table de craft, coffre, four) ; maj = s'accroupir ; courir = ctrl ; T = chat.
- Inventaire (E) : la grille de craft 2×2 est en haut à droite, le résultat juste à sa droite ; en bas, 27 cases de stock puis la barre de 9.
- Table de craft (clic droit dessus) : grille 3×3 à gauche, résultat à droite.
- Déplacer des objets : clic gauche sur un tas = le prendre en main ; clic droit sur une case = y poser UN seul objet ; clic gauche sur une case vide = poser tout le tas ; quand tu tiens quelque chose, repose le reste dans une case vide avant de fermer. Maj + clic sur le résultat = fabriquer le maximum et le ranger.
- Recettes (grille 3×3, haut / milieu / bas ; « M » = matériau : planches, pierre (cobblestone), fer, or, diamant) :
  planches = 1 bûche n'importe où (→ 4) ; bâtons = 2 planches l'une au-dessus de l'autre (→ 4) ; table de craft = 4 planches en carré 2×2 ;
  PIOCHE = M M M en haut, bâton au centre, bâton en bas au centre ; HACHE = M en haut à gauche, M en haut au centre, M au milieu à gauche, bâton au centre, bâton en bas au centre ;
  PELLE = M en haut au centre, bâton au centre, bâton en bas au centre ; ÉPÉE = M en haut au centre, M au centre, bâton en bas au centre ; HOUE = M en haut à gauche et au centre, bâtons au centre et en bas au centre ;
  torche = charbon au-dessus d'un bâton (→ 4) ; four = 8 pierres en anneau (centre vide) ; coffre = 8 planches en anneau ; lit = 3 laines au milieu + 3 planches en bas ; porte = 6 planches sur 2 colonnes ; seau = fer au milieu à gauche, au milieu à droite et en bas au centre.
- Les recettes 2×2 (planches, bâtons, table, torche) se font dans l'inventaire ; les autres demandent une table de craft : s'il n'y en a pas devant toi, fabrique-la, mets-la dans la barre, regarde le sol devant toi (regarder dy positif), clic droit pour la poser, puis clic droit dessus.
- S'il manque des matériaux : fabrique d'abord les planches et les bâtons à partir des bûches ; s'il manque vraiment quelque chose, termine avec « fini » et dis ce qu'il faut aller chercher. En Créatif ou avec les triches, une commande marche aussi : /give @s iron_pickaxe (noms anglais : wooden/stone/iron/golden/diamond_pickaxe…), /time set day, /weather clear.
- Sur un serveur multijoueur, les commandes /give ne marchent pas sans les droits : fais-le à la main.''';

  /// Les consignes du tour.
  static String guide({required String game, required String goal, required bool azerty}) =>
      '''Tu es Nexo et tu JOUES à la place de la personne dans « $game » pour faire ce qu'elle demande : « $goal ».
À chaque tour tu reçois une capture du jeu. Réponds UNIQUEMENT en JSON : {"pense":"ce que je vois et ce que je fais (une phrase courte)","actions":[ … ]} avec 1 à 4 actions ; ensuite tu reçois une nouvelle capture.
Coordonnées x,y sur la capture, de 0 à 1000 (0,0 = en haut à gauche ; 1000,1000 = en bas à droite), au CENTRE de la case ou du bouton visé. Vise précisément les cases d'inventaire.
Actions :
- {"type":"touche","touche":"e"} (une pression ; "ms":300 pour la garder)
- {"type":"maintenir","touches":["avancer","courir"],"ms":1500} (se déplacer : avancer, reculer, gauche, droite, saut, courir, maj = s'accroupir)
- {"type":"regarder","dx":300,"dy":0} (tourner la caméra : dx > 0 vers la droite, dy > 0 vers le bas ; environ 600 = un quart de tour, selon la sensibilité)
- {"type":"clic","x":…,"y":…,"bouton":"gauche","maj":false} (menus et inventaire ; "bouton":"droit" ; "maj":true = Maj + clic)
- {"type":"glisser","x":…,"y":…,"x2":…,"y2":…,"bouton":"gauche"}
- {"type":"maintenir_clic","bouton":"gauche","ms":1200} (miner, frapper, utiliser, dans le jeu)
- {"type":"molette","crans":-1} (objet suivant dans la barre)
- {"type":"commande","texte":"/time set day"} (une commande du jeu, qui commence par « / » ; jamais de message à d'autres joueurs)
- {"type":"attendre","ms":800}
- {"type":"fini","message":"ce que j'ai fait, en une phrase à dire à voix haute"} (but atteint — ou impossible : dis pourquoi et ce qu'il manque)
Règles : regarde bien la capture avant d'agir ; quand un menu s'ouvre, attends de le voir sur la capture suivante avant de cliquer dedans ; vérifie à chaque tour que l'action a marché ; n'appuie sur Échap que pour fermer un menu ; rien d'irréversible que la personne n'a pas demandé (ne jette rien, ne casse pas ses constructions) ; au plus $maxSteps tours.
Clavier de la personne : ${azerty ? 'AZERTY (français)' : 'QWERTY'}.
${playbook(game)}''';

  static double _clampN(num? v, double lo, double hi, double d) => (v?.toDouble() ?? d).clamp(lo, hi);

  /// La réponse de Gemini → un tour (null si illisible). Les valeurs sont
  /// bornées ; une « commande » qui ne commence pas par « / » est refusée
  /// (pas de message à d'autres joueurs).
  static GamePlan? parse(String raw) {
    final start = raw.indexOf('{'), end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    Object? j;
    try {
      j = jsonDecode(raw.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final list = j['actions'] is List ? j['actions'] as List : (j['action'] is Map ? [j['action']] : const []);
    final out = <GameAction>[];
    for (final a in list) {
      if (out.length >= 4) break;
      if (a is! Map) continue;
      final m = a.cast<String, dynamic>();
      final type = '${m['type'] ?? m['action'] ?? ''}'.trim().toLowerCase();
      switch (type) {
        case 'touche':
          if ('${m['touche'] ?? ''}'.trim().isEmpty) continue;
          out.add(GameAction(type, {...m, 'ms': _clampN(m['ms'] as num?, 30, 3000, 60).round()}));
        case 'maintenir':
          final keys = m['touches'] is List ? [for (final k in m['touches'] as List) '$k'] : ['${m['touches'] ?? ''}'];
          if (keys.every((k) => k.trim().isEmpty)) continue;
          out.add(GameAction(type, {...m, 'touches': keys, 'ms': _clampN(m['ms'] as num?, 50, 6000, 800).round()}));
        case 'regarder':
          out.add(
            GameAction(type, {
              'dx': _clampN(m['dx'] as num?, -3000, 3000, 0).round(),
              'dy': _clampN(m['dy'] as num?, -1500, 1500, 0).round(),
            }),
          );
        case 'clic' || 'glisser':
          if (m['x'] == null || m['y'] == null) continue;
          if (type == 'glisser' && (m['x2'] == null || m['y2'] == null)) continue;
          out.add(
            GameAction(type, {
              ...m,
              'x': _clampN(m['x'] as num?, 0, 1000, 500),
              'y': _clampN(m['y'] as num?, 0, 1000, 500),
              if (type == 'glisser') 'x2': _clampN(m['x2'] as num?, 0, 1000, 500),
              if (type == 'glisser') 'y2': _clampN(m['y2'] as num?, 0, 1000, 500),
            }),
          );
        case 'maintenir_clic':
          out.add(GameAction(type, {...m, 'ms': _clampN(m['ms'] as num?, 50, 6000, 800).round()}));
        case 'molette':
          out.add(GameAction(type, {'crans': _clampN(m['crans'] as num?, -9, 9, -1).round()}));
        case 'commande':
          final t = '${m['texte'] ?? ''}'.trim();
          if (!t.startsWith('/') || t.length > 200 || t.contains('\n')) continue;
          out.add(GameAction(type, {'texte': t}));
        case 'attendre':
          out.add(GameAction(type, {'ms': _clampN(m['ms'] as num?, 100, 4000, 600).round()}));
        case 'fini':
          out.add(GameAction(type, {'message': '${m['message'] ?? ''}'.trim()}));
      }
    }
    if (out.isEmpty) return null;
    return GamePlan('${j['pense'] ?? j['pensee'] ?? ''}'.trim(), out);
  }

  /// Un point de la capture (0–1000) → l'écran.
  static (int, int) toScreen(num x, num y, (int, int, int, int) rect) {
    final (left, top, w, h) = rect;
    return ((left + x / 1000 * w).round(), (top + y / 1000 * h).round());
  }

  /// La taille de l'image envoyée (assez grande pour voir les cases).
  static (int, int) shotSize(int w, int h, {int max = 1280}) {
    if (w <= max) return (w, h);
    return (max, (h * max / w).round());
  }
}

/// **Nexo joue à ta place** : « craft-moi une pioche », « ouvre mon
/// inventaire », « mets le jour ». Il regarde le jeu (capture envoyée à
/// Gemini Flash, gratuit — pas de jetons Claude), décide 1 à 4 actions, les
/// fait avec de vraies touches de jeu ([GameInput]), puis regarde de nouveau.
///
/// Garde-fous : seulement le jeu au premier plan (tu changes de fenêtre = il
/// s'arrête) ; Échap (maintenu) l'arrête ; jamais dans un jeu en ligne avec
/// anti-triche ([GameAgentRules.blocked]) ; jamais de message dans le chat
/// (seulement des commandes « / ») ; au plus 25 tours.
class GameAgent extends ChangeNotifier {
  GameAgent._();
  static final instance = GameAgent._();

  /// Remplace Gemini (tests).
  @visibleForTesting
  static Future<String> Function(String system, String prompt, String jpeg64)? askOverride;

  bool active = false;
  String game = '';
  String status = '';
  int _run = 0;

  /// La bulle de Nexo pendant qu'il joue.
  void Function(String text)? onStatus;

  static bool get supported => GameInput.supported;

  /// Le jeu au premier plan (ou null).
  static String? foregroundGame() {
    try {
      return GamePal.instance.detect(
        exe: Win.foregroundExe(),
        path: Win.foregroundPath(),
        title: Win.foregroundTitle(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Met le jeu devant s'il tourne derrière (« sur mc, craft… » depuis Mon Hub).
  static Future<String?> bringGameToFront(String hint) async {
    final g = foregroundGame();
    if (g != null) return g;
    final want = GameAgentRules.isMinecraft(hint) ? 'minecraft' : normalize(hint);
    for (final (id, title, _) in Win.windowList()) {
      final t = normalize(title);
      if (want.isNotEmpty && t.contains(want.split(' ').first)) {
        Win.windowAction(id, 'activer');
        await Future<void>.delayed(const Duration(milliseconds: 900));
        return foregroundGame() ?? title;
      }
    }
    return null;
  }

  void cancel() => _run++;

  void _say(String s) {
    status = s;
    onStatus?.call(s);
    notifyListeners();
  }

  /// Fait la tâche ; renvoie ce que Nexo dit à la fin.
  Future<String> run(String goal, {required String key, String? forGame}) async {
    if (!supported) return 'Je ne peux jouer à ta place que sur le PC (Windows).';
    if (active) return 'Je suis déjà en train de jouer : Échap pour m\'arrêter.';
    if (key.trim().isEmpty && askOverride == null) {
      return 'Pour jouer à ta place gratuitement, il me faut ta clé Gemini (Réglages de Nexo → Voix).';
    }
    final g = (forGame ?? await bringGameToFront(goal) ?? '').trim();
    if (g.isEmpty) return 'Je ne vois pas de jeu au premier plan : ouvre ton jeu, puis redemande-moi.';
    if (GameAgentRules.isBlocked(g)) return GameAgentRules.blockedText(g);
    final title = Win.foregroundTitle();
    final id = ++_run;
    active = true;
    game = g;
    final history = <String>[];
    var result = '';
    try {
      _say('Je m\'en occupe dans $g… (Échap pour m\'arrêter)');
      final system = GameAgentRules.guide(game: g, goal: goal, azerty: GameInput.azerty);
      for (var step = 1; step <= GameAgentRules.maxSteps; step++) {
        if (id != _run) return result = 'Arrêté.';
        if (Win.down(0x1B) || (Win.down(0x11) && Win.down(0x12))) return result = 'D\'accord, je te rends la main.';
        if (Win.foregroundTitle() != title) return result = 'Tu as changé de fenêtre : je m\'arrête.';
        final rect = Win.foregroundRect();
        if (rect == null) return result = 'Je ne vois plus le jeu.';
        final (x, y, w, h) = rect;
        final (tw, th) = GameAgentRules.shotSize(w, h);
        final px = Win.captureScaled(x, y, w, h, tw, th);
        final jpeg = await Isolate.run(() => encodeShot(px, tw, th, quality: 70));
        final prompt = [
          if (history.isNotEmpty) 'Déjà fait :\n${history.join('\n')}',
          'Tour $step sur ${GameAgentRules.maxSteps}. Capture : $tw × $th. Que fais-tu maintenant ? (JSON seul)',
        ].join('\n\n');
        String raw;
        try {
          raw = await _ask(system, prompt, base64Encode(jpeg), key);
        } catch (e) {
          return result = 'Gemini ne répond pas ($e).';
        }
        if (id != _run) return result = 'Arrêté.';
        final plan = GameAgentRules.parse(raw);
        if (plan == null) {
          history.add('$step. (réponse illisible)');
          if (history.where((h) => h.contains('illisible')).length >= 3) {
            return result = 'Je n\'arrive pas à décider quoi faire.';
          }
          continue;
        }
        if (plan.thought.isNotEmpty) _say(plan.thought);
        final done = <String>[];
        for (final a in plan.actions) {
          if (id != _run) return result = 'Arrêté.';
          if (a.type == 'fini') {
            return result = a.s('message').isEmpty ? 'C\'est fait.' : a.s('message');
          }
          await _do(a, rect);
          done.add(a.describe);
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        history.add('$step. ${plan.thought} → ${done.join(', ')}');
        if (history.length > 12) history.removeAt(0);
        // Le jeu réagit (menu qui s'ouvre, déplacement).
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
      return result = 'J\'ai fait ${GameAgentRules.maxSteps} tours sans finir : je te rends la main.';
    } catch (e) {
      return result = 'Je me suis arrêté : $e';
    } finally {
      GameInput.releaseAll();
      active = false;
      status = result;
      notifyListeners();
    }
  }

  Future<void> _do(GameAction a, (int, int, int, int) rect) async {
    switch (a.type) {
      case 'touche':
        await GameInput.hold([a.s('touche')], (a.n('ms') ?? 60).toInt());
      case 'maintenir':
        await GameInput.hold([for (final k in a.args['touches'] as List) '$k'], (a.n('ms') ?? 800).toInt());
      case 'regarder':
        await GameInput.look((a.n('dx') ?? 0).toInt(), (a.n('dy') ?? 0).toInt());
      case 'clic':
        final (x, y) = GameAgentRules.toScreen(a.n('x')!, a.n('y')!, rect);
        await GameInput.clickAt(x, y, right: a.right, shift: a.b('maj'), double: a.b('double'));
      case 'glisser':
        final (x1, y1) = GameAgentRules.toScreen(a.n('x')!, a.n('y')!, rect);
        final (x2, y2) = GameAgentRules.toScreen(a.n('x2')!, a.n('y2')!, rect);
        await GameInput.drag(x1, y1, x2, y2, right: a.right);
      case 'maintenir_clic':
        await GameInput.holdButton(right: a.right, ms: (a.n('ms') ?? 800).toInt());
      case 'molette':
        Win.scroll((a.n('crans') ?? -1).toInt());
      case 'commande':
        // Le chat s'ouvre avec « / » déjà tapé : on tape le reste, puis Entrée.
        await GameInput.hold(['/'], 60);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        Win.typeText(a.s('texte').substring(1));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await GameInput.hold(['entree'], 60);
      case 'attendre':
        await Future<void>.delayed(Duration(milliseconds: (a.n('ms') ?? 600).toInt()));
    }
  }

  static const _models = ['gemini-2.5-flash', 'gemini-flash-latest', 'gemini-2.0-flash'];
  static String? _model;

  /// Gemini Flash regarde la capture (gratuit avec ta clé) et répond en JSON.
  Future<String> _ask(String system, String prompt, String jpeg64, String key) async {
    if (askOverride != null) return askOverride!(system, prompt, jpeg64);
    Object? last;
    for (final model in [?_model, ..._models.where((m) => m != _model)]) {
      final body = {
        'system_instruction': {
          'parts': [
            {'text': system},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
              {
                'inline_data': {'mime_type': 'image/jpeg', 'data': jpeg64},
              },
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'temperature': 0.2,
          if (model == 'gemini-2.5-flash') 'thinkingConfig': {'thinkingBudget': 512},
        },
      };
      try {
        final r = await http
            .post(
              Uri.https('generativelanguage.googleapis.com', '/v1beta/models/$model:generateContent'),
              headers: {'content-type': 'application/json', 'x-goog-api-key': key.trim()},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 40));
        if (r.statusCode == 429) throw 'quota gratuit atteint pour le moment';
        if (r.statusCode != 200) {
          last = 'erreur ${r.statusCode}';
          continue;
        }
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        final um = j['usageMetadata'];
        if (um is Map) {
          final total = (um['totalTokenCount'] as num? ?? 0).toInt();
          final p = (um['promptTokenCount'] as num? ?? 0).toInt();
          unawaited(TokenBudget.instance.recordGemini(p, total - p).catchError((Object _) {}));
        }
        final parts = (((j['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
        final text = [
          for (final p in parts ?? const [])
            if (p is Map && p['thought'] != true && p['text'] is String) p['text'] as String,
        ].join();
        if (text.trim().isEmpty) {
          last = 'réponse vide';
          continue;
        }
        _model = model;
        return text;
      } catch (e) {
        if ('$e'.contains('quota')) rethrow;
        last = e;
      }
    }
    throw '$last';
  }

  /// L'action pour les cerveaux de Nexo (Claude, Gemini, Gemini Live, le coach).
  HubTool tool(Future<String> Function() key) => HubTool(
    name: 'jeu_agir',
    description:
        'Nexo JOUE à la place de la personne dans le jeu ouvert (Minecraft…) : il regarde l\'écran et appuie lui-même '
        'sur les touches et la souris (« ouvre mon inventaire », « craft-moi une pioche », « mets le jour », « avance »). '
        'Gratuit (Gemini). Jamais dans un jeu en ligne avec anti-triche. Échap l\'arrête.',
    params: {
      'but': ('string', 'Ce qu\'il faut faire dans le jeu, en une phrase'),
      'jeu': ('string', 'Le jeu (facultatif : celui au premier plan)'),
    },
    required: ['but'],
    run: (a) async {
      final goal = '${a['but'] ?? ''}'.trim();
      if (goal.isEmpty) return 'Que faut-il faire dans le jeu ?';
      final want = '${a['jeu'] ?? ''}'.trim();
      return run(goal, key: await key(), forGame: want.isEmpty ? null : await bringGameToFront(want) ?? want);
    },
  );
}
