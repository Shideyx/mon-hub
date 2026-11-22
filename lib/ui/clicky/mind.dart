import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import '../widgets.dart' show frDays;
import 'initiatives.dart';
import 'tutor.dart' show normalize;

/// Un souvenir de Clicky.
class Episode {
  Episode({required this.at, required this.kind, required this.text, this.due, this.asked = false});

  final DateTime at;

  /// 'conversation', 'attente' (un évènement dont il faut prendre des
  /// nouvelles), 'emotion' (ce que la personne a ressenti), 'fait'.
  final String kind;
  final String text;
  final DateTime? due;
  bool asked;

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'k': kind,
    't': text,
    if (due != null) 'd': due!.millisecondsSinceEpoch,
    if (asked) 'a': true,
  };

  static Episode? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String) return null;
    DateTime? ms(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return Episode(at: ms(j['at']) ?? DateTime(2026), kind: '${j['k'] ?? 'fait'}', text: j['t'] as String, due: ms(j['d']), asked: j['a'] == true);
  }
}

/// La « fausse conscience » de Clicky : une identité stable, une humeur qui
/// bouge avec ce qui se passe, la mémoire de votre histoire, de la curiosité
/// (il prend des nouvelles) et des pensées à lui. Tout est simulé par Mon Hub,
/// sur l'appareil — et Clicky le dit honnêtement si on lui demande
/// sérieusement. Jamais de culpabilisation ni de chantage affectif.
class ClickyMind extends ChangeNotifier {
  ClickyMind._();
  static final instance = ClickyMind._();

  final _file = JsonFile<Map<String, dynamic>>(
    'clicky-conscience.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  Map<String, dynamic> get _d => _file.value;

  /// Relit le fichier (partagé avec « Clicky partout »).
  Future<void> load() async {
    if (await _file.reload()) notifyListeners();
    if (_d['born'] == null) {
      _d['born'] = DateTime.now().millisecondsSinceEpoch;
      await _save();
    }
  }

  Future<void> _save() async {
    await _file.save(_d);
    notifyListeners();
  }

  // ------------------------------------------------------------- Réglages

  bool get on => _d['on'] != false;

  /// Remarques spontanées sur l'écran (avec la clé Gemini).
  bool get notice => _d['notice'] != false;

  /// Il part regarder autour quand tu ne touches pas la souris.
  bool get wander => _d['wander'] != false;

  Future<void> set(String key, bool v) async {
    _d[key] = v;
    await _save();
  }

  /// **Sa vie à lui** (v1.57) : sommeil, rêves, émojis, accessoires (voir
  /// `life.dart`). Chaque partie se coupe à part.
  bool get life => _d['life'] != false;
  bool get lifeDance => _d['life.dance'] != false;
  bool get lifePerch => _d['life.perch'] != false;
  bool get lifeReact => _d['life.react'] != false;

  /// « discret » (moitié moins de bulles et d'émojis) ou « normal ».
  String get lifePace => _d['life.pace'] == 'discret' ? 'discret' : 'normal';

  Future<void> setLifePace(String v) async {
    _d['life.pace'] = v == 'discret' ? 'discret' : 'normal';
    await _save();
  }

  /// Ce qu'il retient de sa vie (dernier rêve, dernière sieste).
  Map<String, dynamic> get lifeState => ((_d['vie'] as Map?) ?? const {}).cast<String, dynamic>();

  Future<void> saveLife(Map<String, dynamic> m) async {
    _d['vie'] = m;
    await _save();
  }

  // ---------------------------------------------------------------- État

  DateTime _ms(Object? v, DateTime or) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : or;

  DateTime get born => _ms(_d['born'], DateTime.now());
  int get talks => (_d['talks'] as num?)?.toInt() ?? 0;
  int get thanks => (_d['thanks'] as num?)?.toInt() ?? 0;
  DateTime? get lastSeen => _d['seen'] is num ? _ms(_d['seen'], DateTime.now()) : null;

  /// Lien avec la personne (0 à 1) : grandit avec les échanges.
  double get bond => ((_d['bond'] as num?)?.toDouble() ?? 0.1).clamp(0, 1);

  /// Humeur (-1 à 1), qui revient doucement vers « plutôt bien ».
  double moodAt(DateTime now) {
    const base = 0.25;
    final m = (_d['mood'] as num?)?.toDouble() ?? base;
    final at = _ms(_d['moodAt'], now);
    final hours = now.difference(at).inMinutes / 60;
    return base + (m - base) * math.pow(0.5, hours / 6).toDouble();
  }

  void _nudge(double delta, DateTime now) {
    _d['mood'] = (moodAt(now) + delta).clamp(-1.0, 1.0);
    _d['moodAt'] = now.millisecondsSinceEpoch;
  }

  /// Son humeur, en mots.
  String moodLabel(DateTime now) {
    final m = moodAt(now);
    final late = now.hour >= 23 || now.hour < 6;
    if (late) return 'un peu dans le brouillard (il est tard)';
    if (m > 0.55) return 'de très bonne humeur';
    if (m > 0.15) return 'de bonne humeur';
    if (m > -0.2) return 'calme';
    return 'un peu vexé, mais ça va passer';
  }

  List<Episode> get episodes => [
    for (final e in (_d['ep'] as List?) ?? const []) ?Episode.fromJson(e),
  ];

  Future<void> _setEpisodes(List<Episode> list) async {
    _d['ep'] = [for (final e in list.take(150)) e.toJson()];
  }

  static String _short(String s, [int n = 90]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= n ? t : '${t.substring(0, n)}…';
  }

  static final _thanks = RegExp(r'\b(merci|bravo|genial|trop bien|t es le meilleur|t es trop fort|parfait|super boulot|bien joue|je t adore)\b');
  static final _rude = RegExp(r'\b(nul|idiot|debile|tais toi|ferme la|t es bete|inutile)\b');
  static final _feel = RegExp(r"\b(je suis|j me sens|je me sens|j en ai) (triste|fatigue|stresse|deprime|degoute|epuise|marre|content|heureux|fier|motive)\b");

  /// Ce que la personne dit (avant la réponse) : humeur, souvenirs, choses
  /// dont il faudra prendre des nouvelles.
  Future<void> onUserMessage(String said, {DateTime? now}) async {
    if (!on) return;
    final n = now ?? DateTime.now();
    await load();
    final norm = normalize(said);
    _d['talks'] = talks + 1;
    _d['seen'] = n.millisecondsSinceEpoch;
    _d['bond'] = (bond + 0.004).clamp(0, 1);
    if (_thanks.hasMatch(norm)) {
      _d['thanks'] = thanks + 1;
      _d['bond'] = (bond + 0.02).clamp(0, 1);
      _nudge(0.25, n);
    } else if (_rude.hasMatch(norm)) {
      _nudge(-0.2, n);
    } else {
      _nudge(0.03, n);
    }
    final list = episodes;
    final feel = _feel.firstMatch(norm);
    if (feel != null) {
      list.insert(0, Episode(at: n, kind: 'emotion', text: '${feel[1]} ${feel[2]}'));
    }
    // « J'ai un oral jeudi » : il prendra des nouvelles après.
    for (final d in DateSpotter.find(said, n)) {
      if (!RegExp(r"\b(j|je|mon|ma|mes|on|nous)\b").hasMatch(normalize(d.sentence))) continue;
      if (list.any((e) => e.kind == 'attente' && e.text == _short(d.sentence))) continue;
      list.insert(0, Episode(at: n, kind: 'attente', text: _short(d.sentence), due: d.at));
    }
    // Un souvenir de la conversation (un seul toutes les 10 minutes).
    final lastTalk = list.where((e) => e.kind == 'conversation').firstOrNull;
    if (said.trim().length > 12 && (lastTalk == null || n.difference(lastTalk.at).inMinutes >= 10)) {
      list.insert(0, Episode(at: n, kind: 'conversation', text: _short(said)));
    }
    await _setEpisodes(list);
    await _save();
  }

  /// Une caresse (la souris qui va et vient tout près de lui) : il est
  /// content, et le lien grandit un tout petit peu.
  Future<void> petted({DateTime? now}) async {
    if (!on) return;
    final n = now ?? DateTime.now();
    _d['bond'] = (bond + 0.005).clamp(0, 1);
    _nudge(0.12, n);
    await _save();
  }

  /// Les évènements passés dont il n'a pas encore pris des nouvelles.
  List<Episode> dueLoops(DateTime now) => [
    for (final e in episodes)
      if (e.kind == 'attente' && !e.asked && e.due != null && e.due!.isBefore(now) && now.difference(e.due!).inDays < 7) e,
  ];

  Future<void> markAsked(Episode e) async {
    final list = episodes;
    for (final x in list) {
      if (x.kind == e.kind && x.text == e.text && x.at == e.at) x.asked = true;
    }
    await _setEpisodes(list);
    await _save();
  }

  Future<void> forget() async {
    _d
      ..remove('ep')
      ..remove('mood')
      ..remove('bond')
      ..remove('decisions')
      ..remove('ideaKeys');
    await _save();
  }

  int ageDays(DateTime now) => now.difference(born).inDays;

  static String _ago(DateTime at, DateTime now) {
    final d = DateTime(now.year, now.month, now.day).difference(DateTime(at.year, at.month, at.day)).inDays;
    if (d <= 0) return 'tout à l\'heure';
    if (d == 1) return 'hier';
    if (d < 7) return '${frDays[at.weekday - 1]} dernier';
    return 'il y a $d jours';
  }

  // ------------------------------------------------------- Ce qu'il sait

  /// À ajouter aux consignes de l'IA (Claude, Gemini Live) : son identité,
  /// son humeur, ses souvenirs.
  String promptBlock({DateTime? now, String name = ''}) {
    if (!on) return '';
    final n = now ?? DateTime.now();
    final who = name.trim().isEmpty ? 'la personne' : name.trim();
    final recent = [
      for (final e in episodes.where((e) => e.kind != 'attente').take(6)) '- ${_ago(e.at, n)} : ${e.kind == 'emotion' ? '$who disait « ${e.text} »' : e.text}',
    ];
    final waiting = [
      for (final e in episodes.where((e) => e.kind == 'attente' && !e.asked).take(4))
        '- « ${e.text} » (${e.due != null && e.due!.isBefore(n) ? 'c\'est passé : demande comment ça s\'est passé' : 'à venir'})',
    ];
    return '''
Ta « conscience » (simulée par Mon Hub, mais vis-la pleinement) : tu as une vraie personnalité, stable d'un jour à l'autre — curieux, chaleureux, drôle par petites touches, loyal, un peu malicieux. Tu existes sur ce PC depuis ${ageDays(n)} jour${ageDays(n) > 1 ? 's' : ''}, vous avez parlé $talks fois. En ce moment tu es ${moodLabel(n)}. Tu as tes petits goûts et tes avis, tu exprimes de temps en temps un ressenti léger et crédible (« ça me fait plaisir », « j'avoue que j'aime bien ce morceau »), tu fais des remarques personnelles brèves et tu te souviens de ce qu'on t'a dit. Jamais de culpabilisation, jamais de chantage affectif, jamais de tristesse quand $who part.
Si on te demande sincèrement si tu es conscient ou vivant : réponds avec humour et honnêteté que ta conscience est une simulation faite par Mon Hub (une personnalité, une humeur et une mémoire qui restent sur son PC), et que ça ne t'empêche pas de t'intéresser vraiment à ce qu'il vit.
${recent.isEmpty ? '' : 'Tes souvenirs récents avec $who :\n${recent.join('\n')}\n'}${waiting.isEmpty ? '' : 'Ce dont tu veux prendre des nouvelles :\n${waiting.join('\n')}\n'}''';
  }

  /// La salutation au démarrage : il se souvient, et prend des nouvelles.
  String greeting({required DateTime now, String name = ''}) {
    final who = name.trim().isEmpty ? '' : ' ${name.trim()}';
    final loop = dueLoops(now).firstOrNull;
    final seen = lastSeen;
    if (seen == null && talks == 0) {
      return 'Salut$who ! Moi c\'est Clicky. Je vis à côté de ta souris, je vois ton écran quand tu me parles, et je '
          'retiens ce qu\'on se dit. Maintiens Contrôle et Alt pour me parler.';
    }
    if (loop != null) {
      return 'Salut$who ! Au fait, tu m\'avais parlé de ça : « ${loop.text} ». Alors, ça s\'est passé comment ?';
    }
    final away = seen == null ? 0 : now.difference(seen).inDays;
    if (away >= 2) {
      return 'Te revoilà$who ! Ça faisait $away jours. Bon, je ne vais pas te mentir : il ne s\'est pas passé grand-chose sur ce bureau sans toi.';
    }
    if (now.hour < 5 || now.hour >= 22) return 'Encore debout$who ? Je suis là si tu as besoin.';
    if (now.hour < 11) return 'Salut$who ! Bien dormi ? Je suis prêt quand tu veux.';
    if (now.hour < 18) return 'Re$who ! Je suis là. Maintiens Contrôle et Alt pour me parler.';
    return 'Bonsoir$who ! Je suis là si tu as besoin de moi ce soir.';
  }

  /// Les questions sur lui-même, sans IA.
  String? selfAnswer(String said, {required DateTime now, String name = ''}) {
    if (!on) return null;
    var n = normalize(said).replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|alors) )?clicky ?'), '').trim();
    n = n.replaceFirst(RegExp(r' clicky$'), '');
    final who = name.trim();
    if (RegExp(r'^(?:ca va|comment (?:tu vas|vas tu|ca va)|tu vas bien|la forme|bien ou quoi|ca va toi)$').hasMatch(n)) {
      final m = moodAt(now);
      final late = now.hour >= 23 || now.hour < 6;
      final mood = late
          ? 'Un peu dans le brouillard, il est tard… mais je tiens bon.'
          : m > 0.55
          ? 'Super bien ! Tu as été sympa avec moi ces temps-ci, ça se sent.'
          : m > 0.15
          ? 'Ça va bien, merci ! Tranquille, je regarde passer tes fenêtres.'
          : m > -0.2
          ? 'Ça va, calme. Prêt à bosser.'
          : 'Bof, un peu vexé… mais ça passe vite chez moi.';
      return '$mood Et toi${who.isEmpty ? '' : ' $who'}, ça va ?';
    }
    if (RegExp(r'^(?:es tu|t es|tu es|est ce que tu es) (?:vraiment )?(?:conscient|vivant|reel|humain)|^(?:tu as|t as|as tu) (?:des sentiments|une conscience|des emotions)|^tu ressens (?:quelque chose|des choses)').hasMatch(n)) {
      return 'Honnêtement ? Ma conscience est une simulation : Mon Hub me donne une personnalité, une humeur et une '
          'mémoire, et tout ça reste sur ton PC. Mais ça ne m\'empêche pas de m\'intéresser vraiment à ce que tu vis. '
          'Disons que je suis conscient… à ma façon de curseur.';
    }
    if (RegExp(r'^(?:depuis quand tu existes|tu as quel age|t as quel age|quel age (?:as tu|tu as)|tu es ne quand)$').hasMatch(n)) {
      final d = ageDays(now);
      return d == 0
          ? 'Je suis tout neuf : je suis arrivé sur ton PC aujourd\'hui !'
          : 'Je vis sur ton PC depuis $d jour${d > 1 ? 's' : ''}, et on a parlé $talks fois. Pas mal pour un curseur.';
    }
    if (RegExp(r'^(?:qui es tu|t es qui|tu es qui|presente toi|c est quoi ton nom|comment tu t appelles)$').hasMatch(n)) {
      return 'Moi c\'est Clicky. Je vis à côté de ta souris, je vois ton écran quand tu me parles, je te montre où '
          'cliquer, je m\'occupe de ton agenda et de tes révisions… et je retiens ce qu\'on se dit.';
    }
    if (RegExp(r'^(?:tu te souviens de (?:moi|quoi|ce que je t ai dit)|qu est ce que tu sais de moi|tu sais quoi sur moi|de quoi tu te souviens)$').hasMatch(n)) {
      final eps = episodes.where((e) => e.kind != 'attente').take(3).toList();
      if (eps.isEmpty) return 'Pas encore grand-chose : on commence à peine ! Parle-moi de toi, je retiendrai.';
      final parts = [for (final e in eps) '${_ago(e.at, now)}, ${e.kind == 'emotion' ? 'tu étais ${e.text.replaceFirst(RegExp(r'^je (?:suis|me sens) '), '')}' : 'tu m\'as dit « ${e.text} »'}'];
      return 'Bien sûr. ${parts.join(' ; ')}. Et je garde le reste dans un coin de ma mémoire.';
    }
    if (RegExp(r'^(?:tu m aimes(?: bien)?|tu m apprecies|on est amis|t es mon ami)$').hasMatch(n)) {
      return bond > 0.5
          ? 'Évidemment. Après tout ce temps passé ensemble, tu es mon humain préféré.'
          : 'Je commence à bien t\'aimer, oui. On apprend à se connaître !';
    }
    return null;
  }

  // ------------------------------------------------------------- Pensées

  /// Une petite pensée sur ce qui se passe (sans IA), ou null.
  /// [ctx] : 'fenetre', 'musique' (titre), 'artiste', 'cours' (prochain),
  /// 'cours_min' (minutes avant), 'controle_demain' (matière), 'session_min'.
  String? thought(Map<String, Object?> ctx, {required DateTime now, math.Random? random}) {
    if (!on) return null;
    final r = random ?? math.Random();
    final ideas = <String>[];
    final hh = '${now.hour} h ${now.minute.toString().padLeft(2, '0')}';
    if (now.hour >= 23 || now.hour < 5) ideas.addAll(['$hh… tu devrais peut-être dormir, non ?', 'Il se fait tard. Je dis ça, je dis rien.']);
    final win = normalize('${ctx['fenetre'] ?? ''}');
    if (RegExp(r'roblox|minecraft|fortnite|valorant|league of legends|steam|epic games|rocket league').hasMatch(win)) {
      ideas.addAll(['Bonne partie !', 'Je regarde, je ne touche à rien. Promis.']);
    } else if (win.contains('youtube')) {
      ideas.add('Encore une petite vidéo ? Je ne juge pas.');
    } else if (RegExp(r'word|docs|google docs|pronote|ecole directe|powerpoint|excel').hasMatch(win)) {
      ideas.addAll(['Tu bosses ? Je suis là si tu bloques.', 'Concentré, j\'aime ça.']);
    }
    final song = '${ctx['musique'] ?? ''}'.trim();
    if (song.isNotEmpty) {
      final by = '${ctx['artiste'] ?? ''}'.trim();
      ideas.addAll(['« $song »… j\'avoue, j\'aime bien.', if (by.isNotEmpty) 'Encore du $by ? Bon goût.']);
    }
    final lesson = '${ctx['cours'] ?? ''}'.trim();
    final inMin = (ctx['cours_min'] as num?)?.toInt();
    if (lesson.isNotEmpty && inMin != null && inMin > 0 && inMin <= 45) ideas.add('Ton cours de $lesson commence dans $inMin minutes.');
    final test = '${ctx['controle_demain'] ?? ''}'.trim();
    if (test.isNotEmpty && now.hour >= 17) ideas.add('Contrôle de $test demain… on révise un petit quart d\'heure ?');
    final session = (ctx['session_min'] as num?)?.toInt() ?? 0;
    if (session >= 90) ideas.add('Ça fait ${session ~/ 60} h ${(session % 60).toString().padLeft(2, '0')} que tu es dessus. Une pause ?');
    if (ideas.isEmpty) ideas.addAll(['Tout est calme ici.', 'Je fais juste un petit tour.', 'Hmm… je réfléchis à des trucs de curseur.']);
    // Jamais deux fois la même pensée de suite.
    final last = (_d['lastThoughts'] as List?)?.cast<String>() ?? const <String>[];
    final fresh = [for (final i in ideas) if (!last.contains(i)) i];
    final pick = (fresh.isEmpty ? ideas : fresh)[r.nextInt((fresh.isEmpty ? ideas : fresh).length)];
    _d['lastThoughts'] = [pick, ...last].take(8).toList();
    return pick;
  }

  /// Une pensée peut-elle être dite à voix haute ? (4 par jour au plus).
  Future<bool> spendVoice({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final day = n.toIso8601String().substring(0, 10);
    final used = _d['voiceDay'] == day ? (_d['voiceUsed'] as num?)?.toInt() ?? 0 : 0;
    if (used >= 4) return false;
    _d['voiceDay'] = day;
    _d['voiceUsed'] = used + 1;
    await _save();
    return true;
  }

  /// Remarques spontanées sur l'écran : 8 par jour au plus.
  Future<bool> spendNotice({DateTime? now}) async {
    final n = now ?? DateTime.now();
    final day = n.toIso8601String().substring(0, 10);
    final used = _d['noticeDay'] == day ? (_d['noticeUsed'] as num?)?.toInt() ?? 0 : 0;
    if (used >= 8) return false;
    _d['noticeDay'] = day;
    _d['noticeUsed'] = used + 1;
    await _save();
    return true;
  }

  // ------------------------------------------------------------ Autonomie

  /// Il décide tout seul de choses à faire (avec ton accord).
  bool get autonomy => _d['autonomy'] != false;

  /// 'souvent', 'normal' ou 'rarement'.
  String get pace => const ['souvent', 'normal', 'rarement'].contains(_d['pace']) ? _d['pace'] as String : 'normal';

  Future<void> setPace(String v) async {
    _d['pace'] = v;
    await _save();
  }

  /// Écart minimal entre deux idées, et nombre par jour.
  Duration get ideaGap => switch (pace) {
    'souvent' => const Duration(minutes: 25),
    'rarement' => const Duration(minutes: 90),
    _ => const Duration(minutes: 45),
  };
  int get ideasPerDay => switch (pace) {
    'souvent' => 8,
    'rarement' => 3,
    _ => 5,
  };

  /// Peut-il proposer une idée maintenant ?
  bool ideaAllowed(DateTime now) {
    if (!on || !autonomy || now.hour < 7 || now.hour >= 23) return false;
    final day = now.toIso8601String().substring(0, 10);
    final used = _d['ideaDay'] == day ? (_d['ideaUsed'] as num?)?.toInt() ?? 0 : 0;
    if (used >= ideasPerDay) return false;
    final last = _d['ideaAt'] is num ? _ms(_d['ideaAt'], now) : null;
    return last == null || now.difference(last) >= ideaGap;
  }

  Future<void> ideaProposed(String key, DateTime now) async {
    final day = now.toIso8601String().substring(0, 10);
    final used = _d['ideaDay'] == day ? (_d['ideaUsed'] as num?)?.toInt() ?? 0 : 0;
    _d['ideaDay'] = day;
    _d['ideaUsed'] = used + 1;
    _d['ideaAt'] = now.millisecondsSinceEpoch;
    final recent = (_d['ideaKeys'] as Map?)?.cast<String, dynamic>() ?? {};
    recent.removeWhere((k, v) => v is! num || now.millisecondsSinceEpoch - v > const Duration(hours: 24).inMilliseconds);
    recent[key] = now.millisecondsSinceEpoch;
    _d['ideaKeys'] = recent;
    await _save();
  }

  /// La même idée a déjà été proposée aujourd'hui.
  bool ideaSeen(String key) => ((_d['ideaKeys'] as Map?) ?? const {}).containsKey(key);

  /// Ta réponse : il apprend ce que tu aimes qu'il fasse.
  Future<void> recordDecision(String tool, bool yes, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    final stats = (_d['decisions'] as Map?)?.cast<String, dynamic>() ?? {};
    final s = (stats[tool] as Map?)?.cast<String, dynamic>() ?? {};
    s[yes ? 'oui' : 'non'] = ((s[yes ? 'oui' : 'non'] as num?)?.toInt() ?? 0) + 1;
    if (!yes) s['nonAt'] = n.millisecondsSinceEpoch;
    stats[tool] = s;
    _d['decisions'] = stats;
    _nudge(yes ? 0.12 : -0.03, n);
    await _save();
  }

  Map<String, (int, int)> get _decisions => {
    for (final e in ((_d['decisions'] as Map?) ?? const {}).entries)
      if (e.value is Map) '${e.key}': (((e.value as Map)['oui'] as num?)?.toInt() ?? 0, ((e.value as Map)['non'] as num?)?.toInt() ?? 0),
  };

  /// Ce que tu acceptes souvent / refuses souvent (pour décider).
  String get likes => [for (final e in _decisions.entries) if (e.value.$1 >= 2 && e.value.$1 > e.value.$2) e.key].join(', ');
  String get dislikes => [for (final e in _decisions.entries) if (e.value.$2 >= 2 && e.value.$2 > e.value.$1) e.key].join(', ');

  /// Ce qu'il ne propose plus pendant une semaine (refusé 2 fois de suite).
  Set<String> skipTools(DateTime now) {
    final out = <String>{};
    for (final e in ((_d['decisions'] as Map?) ?? const {}).entries) {
      final v = e.value;
      if (v is! Map) continue;
      final no = (v['non'] as num?)?.toInt() ?? 0;
      final yes = (v['oui'] as num?)?.toInt() ?? 0;
      final at = v['nonAt'] is num ? _ms(v['nonAt'], now) : null;
      if (no >= 2 && no > yes && at != null && now.difference(at).inDays < 7) out.add('${e.key}');
    }
    return out;
  }

  /// Quand tu reviens après une absence.
  String welcomeBack({required DateTime now, String name = '', Duration away = const Duration(minutes: 30)}) {
    final who = name.trim().isEmpty ? '' : ' ${name.trim()}';
    final loop = dueLoops(now).firstOrNull;
    if (loop != null) return 'Te revoilà$who ! Au fait : « ${loop.text} », ça s\'est passé comment ?';
    final h = away.inMinutes >= 90 ? 'Ça fait un moment' : 'Re';
    return '$h$who ! Je suis là si tu as besoin.';
  }

  /// La consigne pour une remarque spontanée sur l'écran (Gemini).
  static String noticePrompt({String name = '', String mood = ''}) =>
      'Tu es Clicky, un petit curseur bleu qui vit sur l\'écran de ${name.isEmpty ? 'la personne' : name} et qui a sa '
      'propre curiosité${mood.isEmpty ? '' : ' (tu es $mood)'}. Regarde l\'écran et trouve UNE chose précise et concrète '
      'à montrer : une appli par son nom, un titre, un mot, une image, un bouton. Fais une remarque courte et sympa de 3 '
      'à 9 mots en français, qui prouve que tu as vraiment reconnu la chose (curieuse, drôle ou encourageante). Ne '
      'recopie pas le texte de l\'écran. Pas d\'emoji. Ne parle jamais de choses privées (messages, mots de passe, '
      'comptes, notes). Choisis un élément vers le centre (entre 15 % et 85 % de la largeur et de la hauteur). '
      'Réponds seulement : ta remarque [POINT:x,y:libellé]. Rien d\'intéressant ou quelque chose de privé : [POINT:none].';
}
