import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import 'tutor.dart' show normalize;

/// **Les robots de Nexo** : de petites automatisations **sans IA** (donc
/// sans jetons) qui le rendent proactif toute la journée.
///
/// Un robot = un **déclencheur** (une heure, une appli qui s'ouvre, un jeu
/// lancé, un message reçu, ton retour au PC, le temps passé devant l'écran,
/// le démarrage) → des **actions** que Nexo sait faire sans IA : une phrase
/// qu'il comprend tout seul (« mets de la musique », « j'ai quoi demain »,
/// « coupe mon micro », « mode concentration 25 min », « coach-moi »…), une
/// bulle, une notification, un protocole du Carnet.
///
/// On les crée en une phrase (« quand j'ouvre Discord, coupe mon micro »,
/// « tous les jours à 19 h, j'ai quoi à faire demain »), ou c'est Nexo qui
/// en propose (toujours avec ton accord). Garde-fous : au plus [Robot.perDay]
/// fois par jour chacun, les actions sensibles redemandent la permission, et
/// une phrase que Nexo ne comprend pas sans IA passe par Gemini (gratuit),
/// jamais par Claude.
class Robot {
  Robot({
    required this.id,
    required this.name,
    required this.trigger,
    this.value = '',
    this.days = const [],
    this.school = '',
    required this.actions,
    this.emoji = '🤖',
    this.on = true,
    this.ask = false,
    this.by = 'toi',
    this.perDay = 3,
    this.template = '',
    this.runsDay = '',
    this.runs = 0,
    this.total = 0,
  });

  final String id;
  final String name;
  final String emoji;

  /// heure | appli | jeu | retour | message | note | demarrage | usage
  final String trigger;

  /// « 19:00 », « discord », « léa », « 30 » (minutes)…
  final String value;

  /// Jours (1 = lundi … 7 = dimanche) ; vide = tous les jours.
  final List<int> days;

  /// L'école : '' (toujours), 'ecole' (les jours de cours), 'veille' (la
  /// veille d'un jour de cours : pas pendant les vacances), 'libre' (les
  /// jours sans cours : week-end, vacances, fériés).
  final String school;

  /// « phrase:… », « dire:… », « notifier:… », « protocole:… ».
  final List<String> actions;

  bool on;

  /// Demander avant (« Je lance ta playlist ? Oui / Non »).
  final bool ask;

  /// Qui l'a créé : « toi » ou « nexo ».
  final String by;

  /// Au plus tant de fois par jour.
  final int perDay;

  /// Le modèle d'où il vient (robots tout prêts).
  final String template;

  // Compteurs (gardés dans le fichier).
  String runsDay;
  int runs;
  int total;

  static const triggers = ['heure', 'appli', 'jeu', 'retour', 'message', 'note', 'demarrage', 'usage'];

  Map<String, dynamic> toJson() => {
    'id': id,
    'nom': name,
    'emoji': emoji,
    'declencheur': trigger,
    'valeur': value,
    if (days.isNotEmpty) 'jours': days,
    if (school.isNotEmpty) 'ecole': school,
    'actions': actions,
    'actif': on,
    if (ask) 'demander': true,
    'par': by,
    'parJour': perDay,
    if (template.isNotEmpty) 'modele': template,
    'jourCompte': runsDay,
    'fois': runs,
    'total': total,
  };

  static Robot? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = '${j['declencheur'] ?? ''}';
    final acts = [for (final a in (j['actions'] as List? ?? const [])) '$a'];
    if (!triggers.contains(t) || acts.isEmpty) return null;
    return Robot(
      id: '${j['id'] ?? ''}',
      name: '${j['nom'] ?? 'Robot'}',
      emoji: '${j['emoji'] ?? '🤖'}',
      trigger: t,
      value: '${j['valeur'] ?? ''}',
      days: [for (final d in (j['jours'] as List? ?? const [])) (d as num).toInt()],
      // Les robots tout prêts d'avant gardent la nouvelle règle de leur modèle.
      school: '${j['ecole'] ?? RobotRules.template('${j['modele'] ?? ''}')?.school ?? ''}',
      actions: acts,
      on: j['actif'] != false,
      ask: j['demander'] == true,
      by: '${j['par'] ?? 'toi'}',
      perDay: (j['parJour'] as num?)?.toInt() ?? 3,
      template: '${j['modele'] ?? ''}',
      runsDay: '${j['jourCompte'] ?? ''}',
      runs: (j['fois'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// « Tous les jours à 19 h », « Quand tu ouvres Discord »…
  String get when => RobotRules.describeTrigger(this);

  /// « mets de la musique, puis coupe mon micro ».
  String get what => RobotRules.describeActions(actions);
}

/// Ce qui se passe sur le PC, vu par les robots (un tour toutes les 15 s).
class RobotTick {
  const RobotTick({
    required this.now,
    this.app = '',
    this.idleSeconds = 0,
    this.game = '',
    this.started = false,
    this.schoolToday,
    this.schoolTomorrow,
  });
  final DateTime now;

  /// Cours aujourd'hui / demain (null : on ne sait pas).
  final bool? schoolToday;
  final bool? schoolTomorrow;

  /// L'appli au premier plan (nom de programme + titre, en minuscules).
  final String app;
  final int idleSeconds;

  /// Le jeu en cours ('' sinon).
  final String game;

  /// Premier tour après le démarrage de Mon Hub.
  final bool started;
}

/// Les règles, **sans IA ni Windows** : testables.
class RobotRules {
  RobotRules._();

  static String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// Encore le droit de tourner aujourd'hui ?
  static bool budgetLeft(Robot r, DateTime now) => r.runsDay != dayKey(now) || r.runs < r.perDay;

  static bool dayOk(Robot r, DateTime now) => r.days.isEmpty || r.days.contains(now.weekday);

  /// La règle « école » du robot (on ne bloque pas quand on ne sait pas).
  static bool schoolOk(Robot r, {bool? today, bool? tomorrow}) => switch (r.school) {
    'ecole' => today != false,
    'veille' => tomorrow != false,
    'libre' => today != true,
    _ => true,
  };

  /// Les façons de dire la règle « école » : (motif, règle, ce qui reste).
  static final _schoolWords = <(RegExp, String, String)>[
    (
      RegExp(r'\b(?:tous les|chaque) (?:jours?|matins?) (?:de cours|d ecole|ou j ai cours)\b'),
      'ecole',
      'tous les jours',
    ),
    (
      RegExp(r'\b(?:tous les|chaque|les) soirs? (?:avant|ou j ai) (?:les |un jour de |des )?cours(?: le lendemain)?\b'),
      'veille',
      'tous les jours',
    ),
    (
      RegExp(r'\b(?:tous les|chaque) (?:jours?|matins?) (?:de vacances|sans cours|ou j ai pas cours)\b'),
      'libre',
      'tous les jours',
    ),
    (
      RegExp(r'\b(?:la veille (?:des|d un jour de) cours|quand j ai cours le lendemain|si j ai cours demain)\b'),
      'veille',
      '',
    ),
    (
      RegExp(
        r'\b(?:pendant les vacances|en vacances|les jours sans cours|quand j ai pas cours|quand je n ai pas cours|les jours de repos)\b',
      ),
      'libre',
      '',
    ),
    (RegExp(r'\b(?:les jours (?:de cours|d ecole)|quand j ai cours|les jours ou j ai cours)\b'), 'ecole', ''),
  ];

  /// Les mots d'une phrase → la règle « école » (« les jours de cours »,
  /// « la veille des cours », « pendant les vacances »…).
  static String schoolFrom(String n) {
    for (final (re, kind, _) in _schoolWords) {
      if (re.hasMatch(n)) return kind;
    }
    return '';
  }

  /// Retire ces mots de la phrase (pour comprendre le reste).
  static String withoutSchool(String n) {
    for (final (re, _, keep) in _schoolWords) {
      if (re.hasMatch(n)) {
        return n
            .replaceFirst(re, keep)
            .replaceAll(RegExp(r'^\s*,\s*|\s*,\s*(?=,)'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .replaceFirst(RegExp(r'^,\s*'), '')
            .trim();
      }
    }
    return n;
  }

  /// « 19:00 » → (19, 0).
  static (int, int)? hm(String v) {
    final m = RegExp(r'^(\d{1,2})[:h](\d{2})?$').firstMatch(v.trim());
    if (m == null) return null;
    final h = int.parse(m[1]!), min = int.tryParse(m[2] ?? '') ?? 0;
    if (h > 23 || min > 59) return null;
    return (h, min);
  }

  /// Le texte cherché est-il dans [hay] (sans accents, en mots) ?
  static bool mentions(String hay, String what) {
    final w = normalize(what).trim();
    if (w.isEmpty) return false;
    return ' ${normalize(hay)} '.contains(' $w ') || normalize(hay).contains(w);
  }

  // ------------------------------------------------------------ Création

  /// La phrase (nettoyée) demande-t-elle un robot ? (« crée un robot… »,
  /// « tous les jours à… », « quand j'ouvre… », « chaque fois que… »).
  static bool looksLikeRobot(String n) => RegExp(
    r'^(?:(?:cree|creer|cre|fais|fait|ajoute|nouveau)(?: moi)? (?:un )?robot|robot\b|tous les (?:jours|matins|soirs)|'
    r'chaque (?:jour|matin|soir|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|fois que)|toutes les \d* ?(?:heures?|minutes?)|'
    r'(?:le |les )?(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|week end)s? a \d|'
    r'(?:quand|des que) (?:j ouvre|je lance|je joue|je reviens|je recois|j ai une)|au demarrage)',
  ).hasMatch(n);

  static const _days = {
    'lundi': 1,
    'mardi': 2,
    'mercredi': 3,
    'jeudi': 4,
    'vendredi': 5,
    'samedi': 6,
    'dimanche': 7,
  };

  /// Une phrase → un robot, **sans IA** (null : pas compris, l'IA ou les
  /// réglages prennent le relais).
  ///
  /// « crée un robot : quand j'ouvre Discord, coupe mon micro »
  /// « tous les jours à 19 h, j'ai quoi à faire demain »
  /// « le samedi à 10 h 30, mets de la musique »
  /// « quand je lance un jeu, coach-moi »
  /// « quand je reçois un message de Léa, préviens-moi »
  /// « quand je reviens, qu'est-ce que j'ai raté »
  /// « toutes les heures, dis-moi de boire de l'eau »
  static Robot? parse(String sentence, {String id = '', String by = 'toi'}) {
    var s = sentence.trim();
    s = s.replaceFirst(
      RegExp(r"^(?:(?:hey|ok|dis|eh)\s+)?(?:nexo[\s,]+)?(?:cr[ée]+e?s?(?:-moi| moi)?|fais(?:-moi| moi)?|ajoute|nouveau)\s+(?:un\s+)?robot\s*(?:qui\s+|pour\s+|:\s*|,\s*)?", caseSensitive: false),
      '',
    );
    s = s.replaceFirst(RegExp(r'^robot\s*:\s*', caseSensitive: false), '');
    final school = schoolFrom(normalize(s));
    final n = school.isEmpty ? normalize(s) : withoutSchool(normalize(s));
    String? trigger, value;
    var days = <int>[];
    String? rest;

    RegExpMatch? m;
    // Une heure : « tous les jours à 19 h », « le lundi à 7 h 30 », « à 22h ».
    m = RegExp(
      r'^(?:(?:tous les|chaque) (?:jours?|matins?|soirs?)|(?:le |les |chaque )?(lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|week end|semaine)s?)?\s*(?:a |vers )?(\d{1,2}) ?h ?(\d{2})?\s+(.+)$',
    ).firstMatch(n);
    if (m != null) {
      trigger = 'heure';
      value = '${int.parse(m[2]!)}:${(m[3] ?? '00').padLeft(2, '0')}';
      final d = m[1];
      if (d == 'week end') {
        days = [6, 7];
      } else if (d == 'semaine') {
        days = [1, 2, 3, 4, 5];
      } else if (d != null && _days[d] != null) {
        days = [_days[d]!];
      }
      rest = m[4];
    }
    // « quand j'ouvre Discord, … »
    m ??= RegExp(r'^(?:quand|des que|a chaque fois que|chaque fois que) (?:j ouvre|je lance|j allume|je vais sur) (?!un jeu|une partie)(.+?)(?: alors)?\s+(?:dis|mets|coupe|lance|ouvre|fais|active|rappelle|previens|previens moi|propose|joue|arrete|baisse|monte|montre|j ai|qu est|c est|mode|coach)(.*)$')
        .firstMatch(n);
    if (trigger == null && m != null) {
      trigger = 'appli';
      value = m[1]!.trim();
      rest = n.substring(n.indexOf(m[1]!) + m[1]!.length).trim();
    }
    if (trigger == null) {
      final pats = <(String, RegExp)>[
        ('jeu', RegExp(r'^(?:quand|des que|chaque fois que) (?:je (?:lance|commence) (?:un jeu|une partie)|je joue)\s+(.+)$')),
        ('retour', RegExp(r'^(?:quand|des que) je (?:reviens|rentre|suis de retour)(?: sur le pc)?\s+(.+)$')),
        ('demarrage', RegExp(r'^(?:au demarrage|quand j allume (?:le|mon) pc|quand mon hub demarre|quand mon hub s ouvre)\s+(.+)$')),
        ('note', RegExp(r'^(?:quand|des que) j (?:ai|ai une|recois une|ai une nouvelle) (?:nouvelle )?note\s+(.+)$')),
      ];
      for (final (t, re) in pats) {
        final x = re.firstMatch(n);
        if (x != null) {
          trigger = t;
          value = '';
          rest = x[1];
          break;
        }
      }
    }
    if (trigger == null) {
      // « quand je reçois un message (de Léa) (sur Discord), … »
      final x = RegExp(
        r'^(?:quand|des que) (?:je recois|j ai|il y a|on m envoie) (?:un )?(?:nouveau )?message(?: (?:de|d) (\w+))?(?: sur (discord|instagram|insta))?\s+(.+)$',
      ).firstMatch(n);
      if (x != null) {
        trigger = 'message';
        value = [x[1] ?? '', x[2] ?? ''].where((e) => e.isNotEmpty).join(' ');
        rest = x[3];
      }
    }
    if (trigger == null) {
      // « toutes les heures / toutes les 45 minutes / après 1 h d'écran, … »
      final x = RegExp(
        r'^(?:toutes les (?:(\d+) )?(heures?|minutes?|h|min)|apres (\d+) ?(h|heures?|min|minutes?) (?:d ecran|sur le pc|de pc))\s+(.+)$',
      ).firstMatch(n);
      if (x != null) {
        final num = int.tryParse(x[1] ?? x[3] ?? '') ?? 1;
        final unit = x[2] ?? x[4] ?? 'h';
        final minutes = unit.startsWith('h') ? num * 60 : num;
        if (minutes >= 10) {
          trigger = 'usage';
          value = '$minutes';
          rest = x[5];
        }
      }
    }
    if (trigger == null || rest == null) return null;
    final acts = actionsFrom(rest.replaceFirst(RegExp(r'^(?:alors |, ?)'), '').trim(), original: sentence);
    if (acts.isEmpty) return null;
    final rid = id.isEmpty ? 'r${DateTime.now().microsecondsSinceEpoch}' : id;
    return Robot(
      id: rid,
      name: _nameFor(trigger, value ?? ''),
      emoji: emojiFor(trigger),
      trigger: trigger,
      value: value ?? '',
      days: days,
      school: school,
      actions: acts,
      by: by,
      perDay: trigger == 'usage' ? 6 : 3,
    );
  }

  /// « dis-moi de boire de l'eau » → dire ; « préviens-moi » → notifier ;
  /// « lance le protocole travail » → protocole ; le reste = une phrase pour
  /// Nexo (plusieurs avec « puis »).
  static List<String> actionsFrom(String rest, {String original = ''}) {
    final out = <String>[];
    for (var part in rest.split(RegExp(r'\s+(?:puis|ensuite|et puis|et apres)\s+|\s*;\s*'))) {
      part = part.trim().replaceFirst(RegExp(r'[.!]+$'), '');
      if (part.isEmpty) continue;
      final say = RegExp(r'^(?:dis moi|dis|rappelle moi|rappelle)\s+(?:de |d |que |qu )?(.+)$').firstMatch(part);
      if (say != null) {
        out.add('dire:${_cap(say[1]!)}');
        continue;
      }
      if (RegExp(r'^(?:previens moi|previens|notifie moi|envoie moi une notification)$').hasMatch(part)) {
        out.add('notifier:');
        continue;
      }
      final proto = RegExp(r'^(?:lance|active|demarre) (?:le )?protocole (.+)$').firstMatch(part);
      if (proto != null) {
        out.add('protocole:${proto[1]}');
        continue;
      }
      out.add('phrase:$part');
    }
    return out;
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _nameFor(String t, String v) => switch (t) {
    'heure' => 'À $v',
    'appli' => 'Quand j\'ouvre ${_cap(v)}',
    'jeu' => 'Quand je joue',
    'retour' => 'Quand je reviens',
    'message' => v.isEmpty ? 'Nouveau message' : 'Message ($v)',
    'note' => 'Nouvelle note',
    'demarrage' => 'Au démarrage',
    'usage' => 'Toutes les ${_mins(v)}',
    _ => 'Robot',
  };

  static String emojiFor(String t) => switch (t) {
    'heure' => '⏰',
    'appli' => '🪟',
    'jeu' => '🎮',
    'retour' => '👋',
    'message' => '💬',
    'note' => '📝',
    'demarrage' => '🚀',
    'usage' => '⏳',
    _ => '🤖',
  };

  static String _mins(String v) {
    final m = int.tryParse(v) ?? 60;
    if (m % 60 == 0) return m == 60 ? 'heures' : '${m ~/ 60} h';
    return '$m min';
  }

  static String describeTrigger(Robot r) {
    final d = r.days.isEmpty
        ? 'Tous les jours'
        : r.days.length == 5 && !r.days.contains(6) && !r.days.contains(7)
        ? 'En semaine'
        : r.days.length == 2 && r.days.contains(6) && r.days.contains(7)
        ? 'Le week-end'
        : 'Le ${[for (final x in r.days) _days.entries.firstWhere((e) => e.value == x).key].join(', ')}';
    final base = switch (r.trigger) {
      'heure' => '$d à ${r.value.replaceFirst(':', ' h ').replaceFirst(' h 00', ' h')}',
      'appli' => 'Quand tu ouvres ${_cap(r.value)}',
      'jeu' => 'Quand tu lances un jeu',
      'retour' => 'Quand tu reviens au PC',
      'message' => r.value.isEmpty ? 'Quand tu reçois un message' : 'Quand tu reçois un message (${r.value})',
      'note' => 'Quand tu as une nouvelle note',
      'demarrage' => 'Au démarrage de Mon Hub',
      'usage' => 'Après ${_mins(r.value)} devant l\'écran',
      _ => r.trigger,
    };
    return switch (r.school) {
      'ecole' => '$base, les jours de cours',
      'veille' => '$base, la veille d\'un jour de cours',
      'libre' => '$base, les jours sans cours',
      _ => base,
    };
  }

  static String describeActions(List<String> actions) => [
    for (final a in actions)
      switch (a.split(':').first) {
        'dire' => 'dire « ${a.substring(5)} »',
        'notifier' => 'te prévenir',
        'protocole' => 'lancer le protocole ${a.substring(10)}',
        _ => '« ${a.substring(a.indexOf(':') + 1)} »',
      },
  ].join(', puis ');

  // ------------------------------------------------------------ Déclenchement

  /// Ce robot part-il à ce tour ? [prev] : le tour d'avant (transitions :
  /// une appli qui **arrive**, un jeu qui **commence**, un retour).
  static bool firesOnTick(Robot r, RobotTick t, RobotTick? prev, {int activeMinutes = 0, DateTime? lastRun}) {
    if (!r.on || !dayOk(r, t.now) || !budgetLeft(r, t.now)) return false;
    if (!schoolOk(r, today: t.schoolToday, tomorrow: t.schoolTomorrow)) return false;
    switch (r.trigger) {
      case 'heure':
        final x = hm(r.value);
        if (x == null) return false;
        final at = DateTime(t.now.year, t.now.month, t.now.day, x.$1, x.$2);
        final late = t.now.difference(at);
        // Dans les 3 minutes après l'heure, une fois par jour.
        final done = lastRun != null && dayKey(lastRun) == dayKey(t.now) && !lastRun.isBefore(at);
        return !late.isNegative && late < const Duration(minutes: 3) && !done;
      case 'appli':
        final now = mentions(t.app, r.value);
        final before = prev != null && mentions(prev.app, r.value);
        return now && !before;
      case 'jeu':
        return t.game.isNotEmpty && (prev == null || prev.game.isEmpty);
      case 'retour':
        // Absent au moins [value] minutes (20 par défaut), puis de retour.
        final away = (int.tryParse(r.value) ?? 20) * 60;
        return prev != null && prev.idleSeconds >= away && t.idleSeconds < 60;
      case 'demarrage':
        return t.started;
      case 'usage':
        final every = int.tryParse(r.value) ?? 60;
        if (t.idleSeconds > 120 || activeMinutes < every) return false;
        return lastRun == null || t.now.difference(lastRun).inMinutes >= every;
      default:
        return false;
    }
  }

  /// Ce robot part-il pour cette notification ?
  static bool firesOnNote(Robot r, HubNotification n, DateTime now, {bool? schoolToday, bool? schoolTomorrow}) {
    if (!r.on || !dayOk(r, now) || !budgetLeft(r, now)) return false;
    if (!schoolOk(r, today: schoolToday, tomorrow: schoolTomorrow)) return false;
    if (r.trigger == 'note') return n.id.startsWith('note:');
    if (r.trigger != 'message') return false;
    final isMsg =
        (n.moduleId == 'discord' && n.title.startsWith('Discord · ')) ||
        n.id.startsWith('insta:') ||
        n.id.startsWith('espace:') ||
        n.id.startsWith('msg:');
    if (!isMsg) return false;
    final want = normalize(r.value).trim();
    if (want.isEmpty) return true;
    final hay = '${n.title} ${n.moduleId} ${n.id.startsWith('insta:') ? 'instagram insta' : ''}';
    return want.split(' ').every((w) => mentions(hay, w));
  }

  /// Le texte d'une bulle, avec les petits mots remplacés : {heure}, {jeu},
  /// {appli}, {message}.
  static String fill(String text, {DateTime? now, String game = '', String app = '', String message = ''}) {
    final d = now ?? DateTime.now();
    return text
        .replaceAll('{heure}', '${d.hour} h ${d.minute.toString().padLeft(2, '0')}')
        .replaceAll('{jeu}', game.isEmpty ? 'ton jeu' : game)
        .replaceAll('{appli}', app)
        .replaceAll('{message}', message);
  }

  // ------------------------------------------------------------ Tout prêts

  /// Les robots tout prêts : Nexo les propose un par un (avec ton accord),
  /// ceux marqués [RobotTemplate.byDefault] sont allumés d'office.
  static const templates = <RobotTemplate>[
    RobotTemplate(
      'devoirs_soir',
      '📚',
      'Les devoirs du lendemain',
      'Chaque soir avant un jour de cours, à 19 h, il te dit ce que tu as à faire pour demain (rien pendant les vacances).',
      'heure',
      '19:00',
      ['phrase:j ai quoi a faire pour demain'],
      days: [7, 1, 2, 3, 4],
      school: 'veille',
      byDefault: true,
    ),
    RobotTemplate(
      'demain_cours',
      '🗓️',
      'Le programme de demain',
      'À 21 h, la veille d\'un jour de cours : le premier cours de demain (pour ne pas te lever trop tard).',
      'heure',
      '21:00',
      ['phrase:j ai quoi demain'],
      days: [7, 1, 2, 3, 4],
      school: 'veille',
      byDefault: true,
    ),
    RobotTemplate(
      'coach_jeu',
      '🎮',
      'Le coach quand tu joues',
      'Quand tu lances un jeu, il te propose de te coacher en direct (gratuit, par Gemini).',
      'jeu',
      '',
      ['phrase:coach moi'],
      ask: true,
      perDay: 2,
      byDefault: true,
    ),
    RobotTemplate(
      'pause_yeux',
      '👀',
      'La pause des yeux',
      'Après 1 h d\'écran sans pause : regarde au loin 20 secondes.',
      'usage',
      '60',
      ['dire:Pause des yeux : regarde au loin pendant 20 secondes 👀'],
      perDay: 4,
      byDefault: true,
    ),
    RobotTemplate(
      'eau',
      '💧',
      'Boire de l\'eau',
      'Toutes les 2 h devant le PC : un verre d\'eau.',
      'usage',
      '120',
      ['dire:Petit verre d\'eau ? 💧'],
      perDay: 3,
    ),
    RobotTemplate(
      'retour_rattrapage',
      '👋',
      'Ce que tu as raté',
      'Quand tu reviens après une heure, il te dit ce que tu as raté.',
      'retour',
      '60',
      ['phrase:qu est ce que j ai rate'],
      perDay: 2,
    ),
    RobotTemplate(
      'musique_devoirs',
      '🎧',
      'De la musique pour travailler',
      'Quand tu ouvres Google Docs ou Word, il te propose ta musique.',
      'appli',
      'docs',
      ['phrase:mets de la musique'],
      ask: true,
      perDay: 2,
    ),
    RobotTemplate(
      'bonne_note',
      '🎉',
      'Bravo pour les notes',
      'Quand une note tombe, il te donne ta moyenne à jour.',
      'note',
      '',
      ['phrase:c est quoi ma moyenne'],
      perDay: 3,
    ),
    RobotTemplate(
      'coucher',
      '🌙',
      'L\'heure de dormir',
      'À 23 h, la veille d\'un jour de cours : il est temps d\'aller dormir.',
      'heure',
      '23:00',
      ['dire:Il est 23 h et tu as cours demain : bonne nuit 🌙'],
      days: [7, 1, 2, 3, 4],
      school: 'veille',
    ),
    RobotTemplate(
      'demarrage_point',
      '🚀',
      'Le point au démarrage',
      'Quand Mon Hub démarre, il te dit ton prochain cours.',
      'demarrage',
      '',
      ['phrase:c est quoi mon prochain cours'],
      perDay: 1,
    ),
  ];

  static RobotTemplate? template(String id) => templates.where((t) => t.id == id).firstOrNull;
}

/// Un robot tout prêt.
class RobotTemplate {
  const RobotTemplate(
    this.id,
    this.emoji,
    this.name,
    this.description,
    this.trigger,
    this.value,
    this.actions, {
    this.days = const [],
    this.ask = false,
    this.perDay = 3,
    this.byDefault = false,
    this.school = '',
  });

  final String id;
  final String emoji;
  final String name;
  final String description;
  final String trigger;
  final String value;
  final List<String> actions;
  final List<int> days;
  final bool ask;
  final int perDay;
  final bool byDefault;

  /// La règle « école » (voir [Robot.school]).
  final String school;

  Robot build({String by = 'nexo'}) => Robot(
    id: 'modele_$id',
    name: name,
    emoji: emoji,
    trigger: trigger,
    value: value,
    days: days,
    school: school,
    actions: actions,
    ask: ask,
    by: by,
    perDay: perDay,
    template: id,
  );
}

/// **Le moteur** : garde les robots (`robots.json`, synchronisé avec ton
/// compte), les fait tourner (tour de 15 s de Mon Hub, notifications) et
/// propose de temps en temps un robot tout prêt.
class Robots extends ChangeNotifier {
  Robots._();
  static final instance = Robots._();

  final _file = JsonFile<Map<String, dynamic>>(
    'robots.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  List<Robot> list = [];
  bool _loaded = false;

  // Branché par Mon Hub (voir main.dart).
  /// Une bulle de Nexo.
  void Function(String text)? say;

  /// Une phrase que Nexo exécute sans IA (sinon Gemini) ; renvoie sa réponse.
  Future<String?> Function(String phrase)? quick;

  /// Une notification.
  void Function(String title, String body)? notify;

  /// Lancer un protocole du Carnet.
  Future<void> Function(String name)? protocol;

  /// Demander d'abord (« Je lance ta musique ? ») : la boîte de Nexo avec
  /// Oui / Non, qui lance l'outil `robot_lancer`.
  Future<void> Function(Robot r, String text)? propose;

  /// Cours ce jour-là ? (calendrier scolaire ; null = on ne sait pas).
  bool? Function(DateTime day)? schoolDay;

  bool? _school(DateTime d) {
    try {
      return schoolDay?.call(d);
    } catch (_) {
      return null;
    }
  }

  RobotTick? _prev;
  DateTime? _activeSince;
  final _lastRun = <String, DateTime>{};
  bool _startedSent = false;
  String _suggestedDay = '';

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      await _file.load();
      final raw = _file.value['robots'];
      list = [
        for (final j in (raw is List ? raw : const [])) ?Robot.fromJson(j),
      ];
      // La première fois : les robots tout prêts « d'office ».
      if (_file.value['defauts'] != true) {
        for (final t in RobotRules.templates.where((t) => t.byDefault)) {
          if (!list.any((r) => r.template == t.id)) list.add(t.build());
        }
        await _save(extra: {'defauts': true});
      }
      _loaded = true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save({Map<String, dynamic> extra = const {}}) async {
    try {
      await _file.update((v) => {...v, ...extra, 'robots': [for (final r in list) r.toJson()]});
    } catch (_) {}
  }

  Map<String, dynamic> get _meta => _file.value;

  Future<Robot> add(Robot r) async {
    if (!_loaded) await load();
    list.removeWhere((x) => x.id == r.id);
    list.add(r);
    await _save();
    notifyListeners();
    return r;
  }

  Future<bool> remove(String id) async {
    final before = list.length;
    list.removeWhere((r) => r.id == id || r.template == id);
    if (list.length == before) return false;
    await _save();
    notifyListeners();
    return true;
  }

  Future<void> setOn(String id, bool on) async {
    for (final r in list) {
      if (r.id == id) r.on = on;
    }
    await _save();
    notifyListeners();
  }

  Robot? byId(String id) => list.where((r) => r.id == id || r.template == id).firstOrNull;

  /// Un tour (toutes les 15 s, dans Mon Hub).
  Future<void> tick({required String app, required int idleSeconds, String game = '', DateTime? now}) async {
    if (!_loaded) await load();
    final n = now ?? DateTime.now();
    // Temps passé devant l'écran sans vraie pause (5 min sans rien toucher = pause).
    if (idleSeconds > 300) {
      _activeSince = null;
    } else {
      _activeSince ??= n;
    }
    final active = _activeSince == null ? 0 : n.difference(_activeSince!).inMinutes;
    final t = RobotTick(
      now: n,
      app: app.toLowerCase(),
      idleSeconds: idleSeconds,
      game: game,
      started: !_startedSent,
      schoolToday: _school(n),
      schoolTomorrow: _school(DateTime(n.year, n.month, n.day + 1)),
    );
    _startedSent = true;
    final prev = _prev;
    _prev = t;
    for (final r in [...list]) {
      if (RobotRules.firesOnTick(r, t, prev, activeMinutes: active, lastRun: _lastRun[r.id])) {
        await fire(r, game: game, app: app);
      }
    }
    await _maybeSuggest(n, idleSeconds);
  }

  /// Une notification arrive (message, note…).
  Future<void> onNotification(HubNotification note) async {
    if (!_loaded) await load();
    final n = DateTime.now();
    for (final r in [...list]) {
      if (RobotRules.firesOnNote(
        r,
        note,
        n,
        schoolToday: _school(n),
        schoolTomorrow: _school(DateTime(n.year, n.month, n.day + 1)),
      )) {
        await fire(r, message: '${note.title} : ${note.body}');
      }
    }
  }

  /// Fait partir un robot (en demandant d'abord s'il le faut).
  Future<void> fire(Robot r, {String game = '', String app = '', String message = '', bool asked = false}) async {
    final n = DateTime.now();
    if (r.runsDay != RobotRules.dayKey(n)) {
      r.runsDay = RobotRules.dayKey(n);
      r.runs = 0;
    }
    r.runs++;
    r.total++;
    _lastRun[r.id] = n;
    unawaited(_save());
    if (r.ask && !asked) {
      final p = propose;
      if (p != null) {
        await p(r, '${r.emoji} ${r.name} : je m\'en occupe ? (${r.what})');
        return;
      }
    }
    await runActions(r, game: game, app: app, message: message);
  }

  /// Les actions, l'une après l'autre.
  Future<List<String>> runActions(Robot r, {String game = '', String app = '', String message = ''}) async {
    final said = <String>[];
    for (final a in r.actions) {
      final i = a.indexOf(':');
      final kind = i < 0 ? 'phrase' : a.substring(0, i);
      final arg = RobotRules.fill(i < 0 ? a : a.substring(i + 1), game: game, app: app, message: message);
      try {
        switch (kind) {
          case 'dire':
            say?.call(arg);
            said.add(arg);
          case 'notifier':
            notify?.call('${r.emoji} ${r.name}', arg.isEmpty ? (message.isEmpty ? r.when : message) : arg);
          case 'protocole':
            await protocol?.call(arg);
          default:
            final reply = await quick?.call(arg);
            if (reply != null && reply.trim().isNotEmpty) {
              say?.call(reply);
              said.add(reply);
            }
        }
      } catch (e) {
        debugPrint('robot ${r.name} : $e');
      }
    }
    return said;
  }

  /// Une fois par jour au plus : Nexo propose un robot tout prêt (s'il te
  /// voit au PC et qu'il n'est pas déjà là).
  Future<void> _maybeSuggest(DateTime n, int idle) async {
    final day = RobotRules.dayKey(n);
    if (_suggestedDay == day || idle > 60 || n.hour < 10 || n.hour > 21) return;
    final refused = {for (final x in (_meta['refuses'] as List? ?? const [])) '$x'};
    if (_meta['propose'] == day) {
      _suggestedDay = day;
      return;
    }
    final t = RobotRules.templates
        .where((t) => !list.any((r) => r.template == t.id) && !refused.contains(t.id))
        .firstOrNull;
    _suggestedDay = day;
    if (t == null || propose == null) return;
    await _save(extra: {'propose': day});
    // Le robot n'est créé que si tu dis oui (outil robot_installer).
    await propose!(
      Robot(id: 'installer:${t.id}', name: t.name, emoji: t.emoji, trigger: t.trigger, value: t.value, actions: t.actions),
      '${t.emoji} Je peux ajouter un petit robot : « ${t.name} ». ${t.description} Ça ne coûte aucun jeton. Je l\'ajoute ?',
    );
  }

  /// Retient qu'un modèle a été refusé (il n'est plus proposé).
  Future<void> refuse(String template) async {
    final refused = {for (final x in (_meta['refuses'] as List? ?? const [])) '$x', template};
    await _save(extra: {'refuses': refused.toList()});
  }

  // ------------------------------------------------------------ Outils

  List<HubTool> tools() => [
    HubTool(
      name: 'robot_creer',
      description:
          'Crée un petit robot de Nexo (automatisation SANS IA, sans jetons) : un déclencheur → des actions. '
          'declencheur = heure (valeur « 19:00 »), appli (valeur = nom de l\'appli ou du site), jeu, retour (valeur = '
          'minutes d\'absence), message (valeur = prénom et/ou discord/instagram), note, demarrage, usage (valeur = '
          'minutes d\'écran). actions = phrases que Nexo comprend sans IA, séparées par « | » (ex. « mets de la musique | '
          'coupe mon micro »), ou « dire:texte », « notifier: », « protocole:nom ». Utiliser pour « crée un robot… », '
          '« chaque fois que… fais… », « tous les jours à… ».',
      params: {
        'nom': ('string', 'Nom court du robot'),
        'declencheur': ('string', 'heure, appli, jeu, retour, message, note, demarrage ou usage'),
        'valeur': ('string', 'Selon le déclencheur (heure « 19:00 », appli, prénom, minutes)'),
        'jours': ('string', 'Jours de 1 (lundi) à 7, séparés par des virgules (vide = tous)'),
        'actions': ('string', 'Actions séparées par « | »'),
        'demander': ('boolean', 'Demander avant de faire (oui pour ce qui dérange : musique, applis)'),
      },
      required: const ['declencheur', 'actions'],
      run: (a) async {
        final t = '${a['declencheur'] ?? ''}'.toLowerCase().trim();
        if (!Robot.triggers.contains(t)) return {'erreur': 'Déclencheur inconnu : $t'};
        final acts = [
          for (final x in '${a['actions'] ?? ''}'.split('|'))
            if (x.trim().isNotEmpty) x.trim().contains(':') ? x.trim() : 'phrase:${x.trim()}',
        ];
        if (acts.isEmpty) return {'erreur': 'Aucune action'};
        final r = await add(
          Robot(
            id: 'r${DateTime.now().microsecondsSinceEpoch}',
            name: '${a['nom'] ?? ''}'.trim().isEmpty ? 'Robot' : '${a['nom']}'.trim(),
            emoji: RobotRules.emojiFor(t),
            trigger: t,
            value: '${a['valeur'] ?? ''}'.trim(),
            days: [
              for (final d in '${a['jours'] ?? ''}'.split(RegExp(r'[,\s]+')))
                if (int.tryParse(d) case final x? when x >= 1 && x <= 7) x,
            ],
            actions: acts,
            ask: a['demander'] == true || '${a['demander']}' == 'oui',
          ),
        );
        return {'resume': 'Robot créé : ${r.when}, ${r.what}.', 'id': r.id};
      },
    ),
    HubTool(
      name: 'robot_liste',
      description: 'Les robots de Nexo (automatisations sans IA) : ce qu\'ils font, s\'ils sont allumés.',
      run: (_) async {
        if (!_loaded) await load();
        return {
          'robots': [
            for (final r in list)
              {'id': r.id, 'nom': r.name, 'quand': r.when, 'quoi': r.what, 'allume': r.on, 'par': r.by},
          ],
          'tout_prets': [
            for (final t in RobotRules.templates)
              if (!list.any((r) => r.template == t.id)) {'modele': t.id, 'nom': t.name, 'quoi': t.description},
          ],
        };
      },
    ),
    HubTool(
      name: 'robot_supprimer',
      description: 'Supprime un robot de Nexo (id ou modèle, voir robot_liste).',
      params: {'id': ('string', 'id du robot')},
      required: const ['id'],
      run: (a) async => {'fait': await remove('${a['id'] ?? ''}')},
    ),
    HubTool(
      name: 'robot_activer',
      description: 'Allume ou éteint un robot de Nexo.',
      params: {'id': ('string', 'id du robot'), 'allume': ('boolean', 'true pour allumer, false pour éteindre')},
      required: const ['id'],
      run: (a) async {
        await setOn('${a['id'] ?? ''}', a['allume'] != false && '${a['allume']}' != 'non');
        return {'fait': true};
      },
    ),
    HubTool(
      name: 'robot_installer',
      description: 'Ajoute un robot tout prêt de Nexo (modele, voir robot_liste).',
      params: {'modele': ('string', 'id du modèle')},
      required: const ['modele'],
      run: (a) async {
        final t = RobotRules.template('${a['modele'] ?? ''}');
        if (t == null) return {'erreur': 'Modèle inconnu'};
        final r = await add(t.build());
        return {'resume': '${t.emoji} Robot « ${t.name} » ajouté : ${r.when}.'};
      },
    ),
    HubTool(
      name: 'robot_lancer',
      description: 'Fait tourner un robot de Nexo tout de suite (après « oui »).',
      params: {'id': ('string', 'id du robot')},
      required: const ['id'],
      run: (a) async {
        final id = '${a['id'] ?? ''}';
        final r = byId(id);
        if (r == null) return {'erreur': 'Robot introuvable'};
        final said = await runActions(r);
        return {'fait': true, if (said.isNotEmpty) 'resume': said.join(' ')};
      },
    ),
  ];
}
