// Nexo a **sa vie à lui** (v1.57) : il garde son look de curseur, mais il
// vit à côté de toi et le montre avec des émojis. Il a sommeil le soir, il
// s'endort dans son coin quand tu pars (et se réveille en sursaut), il rêve
// et te raconte ses rêves, il porte de petits « accessoires » selon la vraie
// météo et les fêtes (🧣 quand il fait froid, ☂️ s'il pleut, 🎅 en décembre,
// ☕ le matin), il danse quand ta musique joue, il a la tête qui tourne si tu
// secoues la souris, il s'inquiète si tu cliques comme un fou, il s'assoit
// sur ta fenêtre et tombe quand tu la fermes, il réagit à tes notes…
//
// **Jamais saoulant** : presque tout est muet (un émoji, rien de plus), les
// bulles de texte sont rares (2 par heure, 8 par jour au plus, 10 min
// d'écart ; moitié moins en « discret »), jamais de voix de lui-même, et rien
// en plein écran, en mode jeu ou en mode concentration.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'tutor.dart' show normalize;

/// Ce que Nexo vit en ce moment (émoji, accessoire, sommeil, danse).
class ClickyLife extends ChangeNotifier {
  ClickyLife({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  static final instance = ClickyLife();

  final DateTime Function() _clock;

  // ------------------------------------------------------------ Réglages

  /// « discret » (moitié moins de tout) ou « normal ».
  String pace = 'normal';
  bool get discreet => pace == 'discret';

  // ------------------------------------------------------------- Émojis

  /// L'émoji de ce qu'il ressent (vide : rien), montré un moment.
  String emoji = '';
  Timer? _emojiEnd;

  /// Ce qu'il « porte » (🧣, ☂️, 🎅, ☕…) et pourquoi (pour répondre à
  /// « pourquoi t'as une écharpe ? »).
  String accessory = '';
  String accessoryWhy = '';

  /// Montre un émoji pendant [seconds] secondes.
  void show(String e, {double seconds = 3}) {
    emoji = e;
    _emojiEnd?.cancel();
    _emojiEnd = Timer(Duration(milliseconds: (seconds * 1000).round()), () {
      if (emoji == e) {
        emoji = '';
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// L'émoji à afficher à côté de lui (le sommeil passe avant tout).
  String get shown {
    if (asleep) return emoji == '🥱' ? emoji : '💤';
    if (emoji.isNotEmpty) return emoji;
    if (dancing && steadyDance) return '🎵';
    return '';
  }

  // ------------------------------------------------------------ Mouvements

  /// Un battement de la musique (il bouge en rythme).
  final beat = ValueNotifier<int>(0);

  /// La tête qui tourne (il tangue).
  final wobble = ValueNotifier<int>(0);

  // ------------------------------------------------------------- Sommeil

  bool asleep = false;
  DateTime? sleptAt;

  /// Durée de la dernière sieste, et le dernier rêve raconté.
  Duration lastSleep = Duration.zero;
  String lastDream = '';
  String dreamDay = '';

  void fallAsleep() {
    if (asleep) return;
    asleep = true;
    sleptAt = _clock();
    notifyListeners();
  }

  /// Réveillé : renvoie combien de temps il a dormi.
  Duration wake() {
    if (!asleep) return Duration.zero;
    asleep = false;
    final at = sleptAt;
    sleptAt = null;
    lastSleep = at == null ? Duration.zero : _clock().difference(at);
    notifyListeners();
    return lastSleep;
  }

  /// Un rêve à raconter ? (une fois par jour, après une vraie sieste).
  bool dreamDue(Duration slept, DateTime now) => slept >= const Duration(minutes: 45) && dreamDay != _day(now);

  void dreamt(String text, DateTime now) {
    lastDream = text;
    dreamDay = _day(now);
  }

  // ----------------------------------------------------------- Sur ta fenêtre

  bool perched = false;

  /// Le rectangle de la fenêtre où il est assis (il tombe si elle bouge).
  Object? perchedOn;

  void perch(Object window) {
    perched = true;
    perchedOn = window;
    notifyListeners();
  }

  void unperch() {
    if (!perched) return;
    perched = false;
    perchedOn = null;
    notifyListeners();
  }

  // --------------------------------------------------------------- Danse

  bool dancing = false;

  /// Il a trouvé le rythme (musique régulière, pas une vidéo qui parle).
  bool steadyDance = false;

  void setDancing(bool on) {
    if (dancing == on) return;
    dancing = on;
    if (!on) steadyDance = false;
    notifyListeners();
  }

  void onBeat({required bool steady}) {
    if (!dancing) return;
    if (steady != steadyDance) {
      steadyDance = steady;
      notifyListeners();
    }
    if (steady) beat.value++;
  }

  // -------------------------------------------------------------- Garde-fous

  final _talks = <DateTime>[];
  final _lastEmoji = <String, DateTime>{};
  final _once = <String>{};

  /// Peut-il dire une phrase de lui-même ? (2 par heure, 8 par jour, 10 min
  /// d'écart ; en « discret » : 1 par heure, 4 par jour, 30 min d'écart).
  bool mayTalk(DateTime now) {
    _talks.removeWhere((t) => now.difference(t) > const Duration(hours: 24));
    final perHour = discreet ? 1 : 2, perDay = discreet ? 4 : 8;
    final gap = Duration(minutes: discreet ? 30 : 10);
    if (_talks.length >= perDay) return false;
    if (_talks.where((t) => now.difference(t) < const Duration(hours: 1)).length >= perHour) return false;
    if (_talks.isNotEmpty && now.difference(_talks.last) < gap) return false;
    return true;
  }

  void talked(DateTime now) => _talks.add(now);

  /// Un émoji de ce genre ([kind]) peut-il revenir ? (pas plus d'une fois par
  /// [gap], doublé en « discret »).
  bool mayEmoji(String kind, DateTime now, Duration gap) {
    final last = _lastEmoji[kind];
    final g = discreet ? gap * 2 : gap;
    if (last != null && now.difference(last) < g) return false;
    _lastEmoji[kind] = now;
    return true;
  }

  /// Une seule fois (par clé : « nuit:2026-11-22 », « meteo:🧣:… »).
  bool once(String key) => _once.add(key);

  // ------------------------------------------------------------ Accessoire

  /// Recalcule l'accessoire (fête du jour, puis la météo, puis le café du
  /// matin). Renvoie la phrase à dire s'il vient d'en changer (ou null).
  String? refreshAccessory(DateTime now, {Map? weather, bool coffee = false, bool off = false}) {
    final season = off ? null : seasonAccessory(now);
    final w = off || weather == null ? null : weatherAccessory(weather);
    final (e, why) = coffee && !off
        ? ('☕', 'C\'est le matin : je bois mon café avant de commencer la journée.')
        : season ?? w ?? ('', '');
    if (e == accessory) return null;
    accessory = e;
    accessoryWhy = why;
    notifyListeners();
    // On ne commente pas le café ni la fin d'un accessoire.
    if (e.isEmpty || e == '☕') return null;
    return once('accessoire:$e:${_day(now)}') ? why : null;
  }

  // ------------------------------------------------------------------ État

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  Map<String, dynamic> toJson() => {'reve': lastDream, 'reveJour': dreamDay, 'sieste': lastSleep.inMinutes};

  void restore(Object? j) {
    if (j is! Map) return;
    lastDream = '${j['reve'] ?? ''}';
    dreamDay = '${j['reveJour'] ?? ''}';
    lastSleep = Duration(minutes: (j['sieste'] as num?)?.toInt() ?? 0);
  }

  // =================================================== Calculs (testables)

  /// Son énergie (0 à 1) selon l'heure : tout mou au réveil, en forme
  /// l'après-midi, fatigué après 22 h, épuisé la nuit.
  static double energyAt(DateTime t) => switch (t.hour) {
    < 5 => 0.15,
    5 || 6 => 0.35,
    7 => 0.5,
    >= 8 && < 12 => 0.8,
    12 || 13 => 0.65,
    >= 14 && < 19 => 0.9,
    >= 19 && < 22 => 0.7,
    22 => 0.45,
    _ => 0.3,
  };

  /// Il a sommeil (il bâille de temps en temps).
  static bool sleepyAt(DateTime t) => energyAt(t) <= 0.35;

  /// L'accessoire des fêtes (ou null).
  static (String, String)? seasonAccessory(DateTime d) {
    final (m, day) = (d.month, d.day);
    if (m == 12 && day <= 26) return ('🎅', 'C\'est bientôt Noël : j\'ai sorti mon bonnet de Père Noël.');
    if ((m == 12 && day == 31) || (m == 1 && day == 1)) {
      return ('🥳', 'C\'est le Nouvel An ! Je fais la fête moi aussi.');
    }
    if (m == 10 && day == 31) return ('🎃', 'C\'est Halloween : je me suis déguisé en citrouille. Bouh !');
    if (m == 4 && day == 1) return ('🐟', 'Poisson d\'avril ! Tu as vu ce que j\'ai dans le dos ?');
    if (m == 6 && day == 21) return ('🎸', 'C\'est la fête de la musique : j\'ai sorti ma guitare.');
    if (m == 7 && day == 14) return ('🎆', 'C\'est le 14 juillet : feu d\'artifice !');
    if (m == 2 && day == 14) return ('💘', 'C\'est la Saint-Valentin… moi je suis amoureux de ton curseur.');
    return null;
  }

  /// L'accessoire de la vraie météo (résultat de `carnet_meteo`), ou null.
  static (String, String)? weatherAccessory(Map w) {
    final t = (w['temperature'] as num?)?.toDouble();
    final now = normalize('${w['maintenant'] ?? ''}');
    final icon = '${w['icone'] ?? ''}';
    final deg = t == null ? '' : '${t.round()} °C';
    if (now.contains('neige') || icon.contains('❄') || icon.contains('🌨')) {
      return ('⛄', 'Il neige dehors ! Je me suis fait un petit bonhomme de neige.');
    }
    if (RegExp(r'pluie|averse|bruine|orage').hasMatch(now) ||
        icon.contains('🌧') ||
        icon.contains('⛈') ||
        icon.contains('🌦')) {
      return ('☂️', 'Il pleut dehors, alors j\'ai pris mon parapluie.');
    }
    if (t != null && t <= 4) return ('🧣', 'Brr, il fait $deg dehors : j\'ai sorti mon écharpe.');
    if (t != null && t >= 28) return ('😎', 'Il fait $deg dehors… lunettes de soleil obligatoires.');
    return null;
  }

  /// Ce qu'il ressent quand une notification arrive : (émoji, phrase ou
  /// null). Seules les notes méritent une phrase.
  static (String, String?)? feelingFor(String id, String title, String body) {
    if (id.startsWith('note:')) {
      final m = RegExp(r'(\d+(?:[.,]\d+)?)\s*/\s*(\d+(?:[.,]\d+)?)').firstMatch(body);
      final subject = title.replaceFirst(RegExp(r'^.*?Nouvelle note en\s*'), '').trim();
      if (m == null) return ('👀', null);
      final v = double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0;
      final out = double.tryParse(m[2]!.replaceAll(',', '.')) ?? 20;
      if (out <= 0) return ('👀', null);
      final r = v / out;
      final note = '${m[1]}/${m[2]}';
      if (r >= 0.75) return ('🤩', 'Trop fort : $note${subject.isEmpty ? '' : ' en $subject'} !');
      if (r >= 0.5) return ('🙂', null);
      return ('🫂', 'Pas grave pour ce $note${subject.isEmpty ? '' : ' en $subject'}. On se rattrape ensemble.');
    }
    if (id.startsWith('annule:')) return ('🥳', null);
    if (id.startsWith('arnaque:')) return ('🚨', null);
    if (id.startsWith('devoir:') && title.contains('Contrôle')) return ('😬', null);
    if (id.startsWith('msg:') || id.startsWith('discord') || id.startsWith('mail')) return ('👀', null);
    if (id.startsWith('jeu:')) return ('🎮', null);
    if (id.startsWith('temps:')) return ('⏳', null);
    if (id.contains('anniv')) return ('🎂', null);
    return null;
  }

  /// Un jeu (où l'on clique vite exprès) : pas d'inquiétude pour les clics.
  static bool gameLike(String exe, String title) {
    final e = exe.toLowerCase(), t = normalize(title);
    return RegExp(
          r'roblox|minecraft|javaw|fortnite|valorant|league|riot|steam|epic|rocketleague|gta|cs2|csgo|r5apex|overwatch|'
          r'genshin|osu|terraria|stardew|unity|unreal|dota|hearthstone|brawl',
        ).hasMatch(e) ||
        RegExp(r'\b(?:jeu|jeux|game|games|clicker|poki|crazygames|jeux gratuits|agar|slither|krunker)\b').hasMatch(t);
  }

  /// Les petites occupations quand il s'ennuie (émoji seulement).
  static const antics = ['🎶', '🫧', '🪐', '🤸', '🧐', '🎈'];

  /// Un rêve sans IA, avec ce qu'il a vécu hier (appli, musique, souvenir).
  static String dreamFrom({String app = '', String artist = '', String memory = '', math.Random? random}) {
    final r = random ?? math.Random();
    final ideas = <String>[
      if (app.isNotEmpty)
        'J\'ai rêvé que j\'étais coincé dans $app et que tous les boutons faisaient « clic » en même temps. Bizarre.',
      if (app.isNotEmpty)
        'J\'ai rêvé que $app avait un bouton « dormir encore 5 minutes ». Je l\'ai cherché partout en me réveillant.',
      if (artist.isNotEmpty)
        'Cette nuit, $artist faisait un concert sur ton bureau. J\'étais au premier rang, entre la corbeille et tes téléchargements.',
      if (memory.isNotEmpty)
        'J\'ai rêvé de ce que tu m\'avais dit : « $memory ». Sauf que dans mon rêve, c\'est moi qui m\'en occupais.',
      'J\'ai rêvé que ta souris s\'était transformée en vraie souris et qu\'elle me courait après. Je me suis réveillé en sursaut.',
      'J\'ai rêvé qu\'on faisait la course, ton curseur et moi. J\'ai gagné, évidemment.',
      'J\'ai rêvé que je devenais un fond d\'écran. C\'était reposant, mais on s\'ennuie vite.',
      'J\'ai rêvé qu\'il pleuvait des petits curseurs. Ils voulaient tous que je leur montre où cliquer.',
      'J\'ai rêvé que la touche Échap avait disparu du clavier. Personne ne pouvait plus s\'enfuir de rien.',
    ];
    return ideas[r.nextInt(ideas.length)];
  }

  /// La consigne pour que Gemini invente le rêve (court, drôle, absurde).
  static String dreamPrompt({String name = '', String app = '', String artist = '', String memory = ''}) {
    final who = name.trim().isEmpty ? 'la personne' : name.trim();
    final hints = [
      if (app.isNotEmpty) 'hier, $who a beaucoup utilisé $app',
      if (artist.isNotEmpty) 'il·elle écoutait $artist',
      if (memory.isNotEmpty) 'il·elle t\'a dit : « $memory »',
    ];
    return 'Tu es Nexo, un curseur lumineux vivant sur le PC de $who. Tu viens de te réveiller. '
        'Raconte en une ou deux phrases courtes (160 caractères au plus), à la première personne, au passé, un rêve '
        'drôle et un peu absurde que tu as fait${hints.isEmpty ? '' : ', inspiré de ceci : ${hints.join(' ; ')}'}. '
        'Commence par « J\'ai rêvé ». Pas d\'émoji, pas de guillemets autour, rien d\'autre que le rêve.';
  }

  /// Nettoie le rêve écrit par l'IA (null s'il ne convient pas).
  static String? cleanDream(String raw) {
    var t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'^["«»“”\s]+|["«»“”\s]+$'), '').trim();
    if (t.length < 20 || t.length > 240 || !normalize(t).startsWith('j ai reve')) return null;
    return t;
  }

  /// Ce qu'il dit de sa vie à lui (« tu dors ? », « t'as rêvé de quoi ? »),
  /// sans IA, ou null. [setPace]/[setDance] : ce qu'on lui demande de changer.
  String? answer(
    String said, {
    required DateTime now,
    Future<void> Function(String pace)? setPace,
    Future<void> Function(bool dance)? setDance,
  }) {
    var n = normalize(said)
        .replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|alors) )?(?:clicky|smily|smiley|nexo|nexos|nekso|nexou|simile) ?'), '')
        .trim();
    n = n.replaceFirst(RegExp(r' (?:clicky|smily|smiley|nexo|nexos|nekso|nexou|simile)$'), '').trim();
    if (RegExp(r'^(?:tu dors|tu dormais|t es reveille|tu es reveille|reveille toi|debout)$').hasMatch(n)) {
      return asleep || now.difference(_wokeHint ?? DateTime(2000)).inMinutes < 2
          ? 'Hein ? Non non… je reposais juste mes pixels. Je suis là !'
          : 'Moi ? Jamais quand tu es là. Je fais la sieste dans mon coin quand tu pars.';
    }
    if (RegExp(r'^(?:tu as|t as|as tu) bien dormi$|^bien dormi$').hasMatch(n)) {
      final h = lastSleep.inMinutes;
      if (h < 20) return 'Pas vraiment dormi : tu étais là tout le temps. Mais je ne me plains pas !';
      final d = h >= 60 ? '${h ~/ 60} h${h % 60 == 0 ? '' : ' ${(h % 60).toString().padLeft(2, '0')}'}' : '$h minutes';
      return 'Comme un bébé curseur : $d dans mon coin, en bas de l\'écran. Et toi ?';
    }
    if (RegExp(
      r'^(?:tu as|t as|as tu) reve(?: de quoi| cette nuit)?$|^(?:tu as reve|t as reve) de quoi$|^raconte(?: moi)? ton reve$|^c etait quoi ton reve$',
    ).hasMatch(n)) {
      return lastDream.isEmpty ? 'Je ne m\'en souviens plus… ça m\'arrive souvent, comme à toi je crois.' : lastDream;
    }
    const things =
        r'(?:echarpe|bonnet|parapluie|lunettes(?: de soleil)?|cafe|chapeau|citrouille|guitare|poisson|'
        r'bonhomme de neige|emoji|truc|accessoire)s?';
    if (RegExp(
      '^(?:tu as|t as|as tu) (?:froid|chaud)\$|'
      '^pourquoi (?:tu as|t as|tu portes|tu bois) (?:un|une|des|ton|ta|tes|ce|cette) $things(?: .*)?\$|'
      '^c est quoi (?:ton|ta|tes|ce|cet|cette) $things(?: a cote de toi)?\$',
    ).hasMatch(n)) {
      if (accessory.isEmpty) {
        return 'Non, ça va : il ne fait ni trop chaud ni trop froid. Rien de spécial sur moi aujourd\'hui.';
      }
      return '$accessory $accessoryWhy';
    }
    if (RegExp(r'^(?:tu es|t es) fatigue$|^(?:tu as|t as) sommeil$').hasMatch(n)) {
      final e = energyAt(now);
      if (e <= 0.35) {
        return 'Franchement, oui : à cette heure-ci je bâille toutes les deux minutes. Toi aussi tu devrais dormir, non ?';
      }
      if (e >= 0.8) return 'Pas du tout ! Je suis en pleine forme.';
      return 'Un peu, mais ça va. Je tiens le coup.';
    }
    if (RegExp(r'^(?:tu fais quoi|qu est ce que tu fais|tu fabriques quoi)$').hasMatch(n)) {
      if (dancing && steadyDance) return 'Je danse sur ta musique, ça ne se voit pas ?';
      if (sleepyAt(now)) return 'J\'essaie de ne pas m\'endormir. C\'est dur.';
      return const [
        'Je regarde passer tes fenêtres. C\'est mon émission préférée.',
        'Je t\'attends. Et je compte les pixels, pour passer le temps.',
        'Rien de spécial : je traîne à côté de ta souris.',
      ][now.second % 3];
    }
    if (RegExp(r'^(?:tu danses|tu sais danser|danse)$').hasMatch(n)) {
      return dancing && steadyDance
          ? 'Évidemment ! Ce morceau est trop bien.'
          : 'Mets de la musique et regarde-moi bien.';
    }
    if (RegExp(r'^(?:arrete|stop) de (?:danser|bouger)$|^ne danse plus$').hasMatch(n)) {
      if (setDance != null) unawaited(setDance(false));
      setDancing(false);
      return 'D\'accord, je reste sage. Dis « tu peux danser » si ça te manque.';
    }
    if (RegExp(r'^(?:tu peux|tu as le droit de) (?:danser|redanser)(?: a nouveau)?$|^remets toi a danser$')
        .hasMatch(n)) {
      if (setDance != null) unawaited(setDance(true));
      return 'Youpi ! La prochaine fois que ta musique passe, je danse.';
    }
    if (RegExp(
      r'^(?:sois|fais toi) (?:plus )?(?:discret|calme|petit)$|^calme toi$|^(?:tu es|t es) (?:saoulant|soulant|lourd|relou|insupportable)$|^arrete les emojis$',
    ).hasMatch(n)) {
      pace = 'discret';
      if (setPace != null) unawaited(setPace('discret'));
      return 'Compris, je me fais tout petit : beaucoup moins de bulles et d\'émojis. Dis « tu peux être plus bavard » pour revenir comme avant.';
    }
    if (RegExp(r'^(?:tu peux etre|sois) (?:plus )?(?:bavard|vivant|present)$|^reviens comme avant$').hasMatch(n)) {
      pace = 'normal';
      if (setPace != null) unawaited(setPace('normal'));
      return 'Super ! Je reprends ma petite vie normale à côté de ta souris.';
    }
    return null;
  }

  /// « J'habite à Lyon », « ma ville c'est Nantes » : la ville (sans
  /// accents, en minuscules), ou null.
  static String? cityFrom(String said) {
    var n = normalize(said)
        .replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|alors) )?(?:clicky|smily|smiley|nexo|nexos|nekso|nexou|simile) ?'), '')
        .trim();
    n = n.replaceFirst(RegExp(r' (?:clicky|smily|smiley|nexo|nexos|nekso|nexou|simile|stp|svp|merci)$'), '').trim();
    final m = RegExp(
      r'^(?:j habite|je vis|je reside|moi j habite) (?:a|au|aux|en|sur) (.{2,40})$|^ma ville (?:c est |est |s appelle )?(.{2,40})$',
    ).firstMatch(n);
    final c = (m?[1] ?? m?[2])?.trim();
    if (c == null || c.split(' ').length > 4) return null;
    if (RegExp(r'^(?:la maison|cote|chez|l etranger|la campagne|paris ou|quoi|ou)\b').hasMatch(c)) return null;
    return c;
  }

  DateTime? _wokeHint;

  /// Il vient d'être réveillé (pour « tu dormais ? »).
  void wokeNow(DateTime now) => _wokeHint = now;

  /// Sa vie à lui, pour les consignes de l'IA (une petite touche, pas plus).
  String promptBlock(DateTime now) {
    final bits = <String>[
      if (sleepyAt(now)) 'il est tard et tu as sommeil (tu bâilles)',
      if (energyAt(now) >= 0.8) 'tu es en pleine forme',
      if (accessory.isNotEmpty) 'tu portes $accessory (${accessoryWhy.toLowerCase()})',
      if (dancing && steadyDance) 'tu es en train de danser sur sa musique',
      if (lastDream.isNotEmpty && dreamDay == _day(now)) 'cette nuit tu as rêvé : « $lastDream »',
    ];
    if (bits.isEmpty) return '';
    return 'Ta vie à toi en ce moment (simulée, vis-la) : ${bits.join(' ; ')}. N\'en parle que si ça vient '
        'naturellement, en une petite touche, jamais plus d\'une phrase.\n';
  }
}

/// Repère un mouvement qui va et vient vite (souris secouée, caresse).
class WiggleDetector {
  WiggleDetector({
    required this.minStep,
    required this.reversals,
    required this.windowMs,
    required this.minPath,
    this.maxStep = double.infinity,
    this.cooldownMs = 8000,
  });

  /// Souris secouée : la tête lui tourne.
  factory WiggleDetector.shake() => WiggleDetector(minStep: 25, reversals: 5, windowMs: 900, minPath: 500);

  /// Petits allers-retours tout près de lui : une caresse.
  factory WiggleDetector.pet() =>
      WiggleDetector(minStep: 4, maxStep: 70, reversals: 4, windowMs: 1600, minPath: 50, cooldownMs: 5000);

  final double minStep, maxStep, minPath;
  final int reversals, windowMs, cooldownMs;

  final _moves = <(int, double)>[];
  double? _lastX;
  int _last = -1 << 40;

  /// Une nouvelle position (horizontale) : vrai quand le geste est reconnu.
  bool add(int ms, double x) {
    final lx = _lastX;
    _lastX = x;
    if (lx == null) return false;
    final dx = x - lx;
    if (dx.abs() < 0.5) return false;
    _moves.add((ms, dx));
    _moves.removeWhere((m) => ms - m.$1 > windowMs);
    if (ms - _last < cooldownMs) return false;
    // Regroupe les petits mouvements dans le même sens en « traits ».
    final strokes = <double>[];
    for (final (_, d) in _moves) {
      if (strokes.isNotEmpty && strokes.last.sign == d.sign) {
        strokes[strokes.length - 1] += d;
      } else {
        strokes.add(d);
      }
    }
    final big = [
      for (final s in strokes)
        if (s.abs() >= minStep && s.abs() <= maxStep) s,
    ];
    final path = big.fold<double>(0, (a, s) => a + s.abs());
    var turns = 0;
    for (var i = 1; i < big.length; i++) {
      if (big[i].sign != big[i - 1].sign) turns++;
    }
    if (turns >= reversals && path >= minPath) {
      _last = ms;
      _moves.clear();
      return true;
    }
    return false;
  }
}

/// Repère les clics énervés (6 clics en 2 s au même endroit).
class RageClickDetector {
  RageClickDetector({this.clicks = 6, this.windowMs = 2000, this.radius = 60, this.cooldownMs = 60000});
  final int clicks, windowMs, cooldownMs;
  final double radius;
  final _at = <(int, double, double)>[];
  int _last = -1 << 40;

  bool add(int ms, double x, double y) {
    _at.add((ms, x, y));
    _at.removeWhere((c) => ms - c.$1 > windowMs);
    if (ms - _last < cooldownMs || _at.length < clicks) return false;
    final (_, x0, y0) = _at.last;
    final near = _at.where((c) => (c.$2 - x0).abs() <= radius && (c.$3 - y0).abs() <= radius).length;
    if (near < clicks) return false;
    _last = ms;
    _at.clear();
    return true;
  }
}

/// Trouve les temps forts d'une musique (son du PC, PCM 16 bits mono
/// 16 kHz) et dit si le rythme est régulier (une vraie musique, pas une
/// vidéo qui parle).
class BeatDetector {
  BeatDetector({this.rate = 16000});
  final int rate;

  static const _frame = 512; // 32 ms
  final _energies = <double>[];
  final _beats = <int>[];
  int _samples = 0;
  final _pending = <int>[];

  void reset() {
    _energies.clear();
    _beats.clear();
    _pending.clear();
    _samples = 0;
  }

  int get _ms => _samples * 1000 ~/ rate;

  /// Le rythme est-il régulier ? (6 derniers écarts proches les uns des
  /// autres, entre 60 et 200 battements par minute).
  bool get steady {
    if (_beats.length < 7) return false;
    final last = _beats.sublist(_beats.length - 7);
    final gaps = [for (var i = 1; i < last.length; i++) (last[i] - last[i - 1]).toDouble()];
    final mean = gaps.reduce((a, b) => a + b) / gaps.length;
    if (mean < 300 || mean > 1000) return false;
    final sd = math.sqrt(gaps.map((g) => (g - mean) * (g - mean)).reduce((a, b) => a + b) / gaps.length);
    return sd / mean < 0.3;
  }

  /// Battements par minute (0 si pas encore trouvé).
  int get bpm {
    if (_beats.length < 4) return 0;
    final last = _beats.sublist(math.max(0, _beats.length - 8));
    final mean = (last.last - last.first) / (last.length - 1);
    return mean <= 0 ? 0 : (60000 / mean).round();
  }

  /// Un morceau de son : renvoie le nombre de battements trouvés dedans.
  int push(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      _pending.add(data.getInt16(i, Endian.little));
    }
    var found = 0;
    while (_pending.length >= _frame) {
      var e = 0.0;
      for (var i = 0; i < _frame; i++) {
        final s = _pending[i] / 32768;
        e += s * s;
      }
      _pending.removeRange(0, _frame);
      e /= _frame;
      _samples += _frame;
      final avg = _energies.isEmpty ? 0.0 : _energies.reduce((a, b) => a + b) / _energies.length;
      final since = _beats.isEmpty ? 1 << 30 : _ms - _beats.last;
      if (_energies.length >= 8 && e > avg * 1.6 && e > 0.002 && since >= 280) {
        _beats.add(_ms);
        if (_beats.length > 32) _beats.removeAt(0);
        found++;
      }
      _energies.add(e);
      if (_energies.length > 32) _energies.removeAt(0);
    }
    return found;
  }
}
