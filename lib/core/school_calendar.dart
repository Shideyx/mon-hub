import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'module_store.dart';

/// Une période sans cours : vacances, pont, congé vu dans École Directe.
@immutable
class SchoolBreak {
  const SchoolBreak(this.name, this.start, this.end, {this.source = 'integre', this.approxEnd = false});

  /// « Vacances de Noël », « Pont de l'Ascension »…
  final String name;

  /// Le premier jour sans cours (à minuit).
  final DateTime start;

  /// Le jour de la reprise des cours (exclu).
  final DateTime end;

  /// D'où vient l'info : `ecole` (École Directe), `officiel` (calendrier de
  /// l'Éducation nationale), `integre` (table rangée dans Mon Hub).
  final String source;

  /// La date de reprise n'est pas encore connue (l'été : « début septembre »).
  final bool approxEnd;

  bool covers(DateTime day) {
    final d = SchoolRules.dateOnly(day);
    return !d.isBefore(start) && d.isBefore(end);
  }

  /// Le dernier jour sans cours.
  DateTime get lastDay => SchoolRules.addDays(end, -1);

  /// De vraies vacances (pas un simple pont).
  bool get isHoliday => SchoolRules.norm(name).contains('vacances') || end.difference(start).inDays >= 5;

  Map<String, dynamic> toJson() => {
    'nom': name,
    'debut': SchoolRules.ymd(start),
    'reprise': SchoolRules.ymd(end),
    'source': source,
    if (approxEnd) 'reprise_approx': true,
  };

  static SchoolBreak? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = DateTime.tryParse('${j['debut'] ?? ''}');
    final e = DateTime.tryParse('${j['reprise'] ?? ''}');
    if (s == null || e == null || !e.isAfter(s)) return null;
    return SchoolBreak(
      '${j['nom'] ?? 'Vacances'}',
      SchoolRules.dateOnly(s),
      SchoolRules.dateOnly(e),
      source: '${j['source'] ?? 'integre'}',
      approxEnd: j['reprise_approx'] == true,
    );
  }

  @override
  String toString() => '$name ${SchoolRules.ymd(start)} → ${SchoolRules.ymd(end)}';
}

/// Le genre de journée.
enum SchoolDayKind {
  /// Au moins un cours qui a lieu.
  cours,

  /// Samedi ou dimanche, sans cours.
  weekend,

  /// Vacances ou pont (calendrier officiel ou École Directe).
  vacances,

  /// Jour férié.
  ferie,

  /// Des cours étaient prévus, mais tous sont annulés.
  annule,

  /// Un jour de semaine sans rien dans l'emploi du temps (alors que la
  /// semaine en a ailleurs).
  libre,

  /// On ne sait pas (pas d'emploi du temps).
  inconnu,
}

/// Ce que Mon Hub sait d'une journée d'école.
class SchoolDay {
  SchoolDay({
    required this.date,
    required this.kind,
    this.reason = '',
    this.lessons = const [],
    this.cancelled = const [],
    this.inBreak,
  });

  final DateTime date;
  final SchoolDayKind kind;

  /// Le nom des vacances ou du jour férié.
  final String reason;

  /// Les cours qui ont lieu (triés).
  final List<Map> lessons;

  /// Les cours annulés.
  final List<Map> cancelled;

  /// Les vacances en cours ce jour-là (s'il y en a).
  final SchoolBreak? inBreak;

  bool get hasClass => kind == SchoolDayKind.cours;

  /// Sûr qu'il n'y a pas cours (week-end, vacances, férié, tout annulé).
  bool get noClass =>
      kind == SchoolDayKind.weekend ||
      kind == SchoolDayKind.vacances ||
      kind == SchoolDayKind.ferie ||
      kind == SchoolDayKind.annule ||
      kind == SchoolDayKind.libre;

  DateTime? get first => lessons.isEmpty ? null : SchoolRules.start(lessons.first);
  DateTime? get last => lessons.isEmpty ? null : SchoolRules.end(lessons.last);

  /// L'heure à laquelle les cours auraient commencé sans les annulations.
  DateTime? get plannedFirst {
    final all = [...lessons, ...cancelled].map(SchoolRules.start).whereType<DateTime>().toList()..sort();
    return all.firstOrNull;
  }

  DateTime? get plannedLast {
    final all = [...lessons, ...cancelled].map(SchoolRules.end).whereType<DateTime>().toList()..sort();
    return all.lastOrNull;
  }

  /// Les premiers cours sont annulés : on commence plus tard.
  bool get lateStart => hasClass && plannedFirst != null && first != null && first!.isAfter(plannedFirst!);

  /// Les derniers cours sont annulés : on finit plus tôt.
  bool get earlyEnd => hasClass && plannedLast != null && last != null && last!.isBefore(plannedLast!);

  /// Les heures sans cours entre deux cours (au moins 30 min), avec le
  /// créneau du midi marqué.
  List<({DateTime from, DateTime to, bool lunch})> get gaps {
    final out = <({DateTime from, DateTime to, bool lunch})>[];
    var lunchSeen = false;
    for (var i = 1; i < lessons.length; i++) {
      final a = SchoolRules.end(lessons[i - 1]);
      final b = SchoolRules.start(lessons[i]);
      if (a == null || b == null) continue;
      final m = b.difference(a).inMinutes;
      if (m < 30) continue;
      final lunch = !lunchSeen && SchoolRules.isLunch(a, b);
      if (lunch) lunchSeen = true;
      out.add((from: a, to: b, lunch: lunch));
    }
    return out;
  }

  /// Les trous (heures de libre hors midi).
  List<({DateTime from, DateTime to, bool lunch})> get freePeriods => [
    for (final g in gaps)
      if (!g.lunch) g,
  ];

  Map<String, dynamic> toJson() => {
    'date': SchoolRules.ymd(date),
    'type': kind.name,
    'cours': hasClass,
    if (reason.isNotEmpty) 'raison': reason,
    if (first != null) 'debut': SchoolRules.hm(first!),
    if (last != null) 'fin': SchoolRules.hm(last!),
    if (lessons.isNotEmpty)
      'liste': [for (final l in lessons) '${SchoolRules.hm(SchoolRules.start(l)!)} ${l['titre'] ?? 'Cours'}'],
    if (cancelled.isNotEmpty)
      'annules': [for (final l in cancelled) '${SchoolRules.hm(SchoolRules.start(l)!)} ${l['titre'] ?? 'Cours'}'],
    if (lateStart) 'commence_plus_tard': true,
    if (earlyEnd) 'finit_plus_tot': true,
    if (freePeriods.isNotEmpty)
      'trous': [for (final g in freePeriods) '${SchoolRules.hm(g.from)} – ${SchoolRules.hm(g.to)}'],
  };
}

/// Où on en est dans la journée.
enum SchoolPhase {
  /// Jour de cours, avant le premier.
  avant,

  /// Un cours est en train d'avoir lieu.
  enCours,

  /// Entre deux cours (récré, changement de salle).
  pause,

  /// Une heure de libre (trou, cours annulé).
  trou,

  /// La pause de midi.
  midi,

  /// Les cours sont finis pour aujourd'hui.
  fini,

  /// Pas cours aujourd'hui.
  pasCours,
}

class SchoolMoment {
  const SchoolMoment({
    required this.now,
    required this.today,
    required this.phase,
    this.current,
    this.next,
    this.until,
  });

  final DateTime now;
  final SchoolDay today;
  final SchoolPhase phase;

  /// Le cours en ce moment.
  final Map? current;

  /// Le prochain cours aujourd'hui.
  final Map? next;

  /// La fin du cours en cours, ou le début du prochain.
  final DateTime? until;

  /// La personne est sans doute en classe (pas le moment de parler fort).
  bool get inClass => phase == SchoolPhase.enCours;

  /// Du temps libre (week-end, vacances, après les cours, un trou…).
  bool get freeTime =>
      phase == SchoolPhase.pasCours ||
      phase == SchoolPhase.fini ||
      phase == SchoolPhase.trou ||
      phase == SchoolPhase.midi;
}

/// Les règles du calendrier scolaire, **sans IA ni réseau** : testables.
class SchoolRules {
  SchoolRules._();

  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
  static bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  static String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String hm(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static const weekdays = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
  static const months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];

  /// « lundi 4 janvier ».
  static String longDate(DateTime d) =>
      '${weekdays[d.weekday - 1]} ${d.day == 1 ? '1er' : d.day} ${months[d.month - 1]}';

  /// « aujourd'hui », « demain », « lundi », « lundi 4 janvier ».
  static String dayWord(DateTime d, DateTime now) {
    final n = dateOnly(d).difference(dateOnly(now)).inDays;
    return switch (n) {
      0 => 'aujourd\'hui',
      1 => 'demain',
      -1 => 'hier',
      _ => n > 1 && n < 7 ? weekdays[d.weekday - 1] : longDate(d),
    };
  }

  /// Sans accents, en minuscules.
  static String norm(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i < 0 ? c : to[i]);
    }
    return '$b';
  }

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  static DateTime? start(Map e) => _date(e['debut']);
  static DateTime? end(Map e) => _date(e['fin']) ?? start(e)?.add(const Duration(hours: 1));

  // ------------------------------------------------------------ Jours fériés

  /// Le dimanche de Pâques (calcul de Meeus / Jones / Butcher).
  static DateTime easter(int y) {
    final a = y % 19, b = y ~/ 100, c = y % 100, d = b ~/ 4, e = b % 4;
    final f = (b + 8) ~/ 25, g = (b - f + 1) ~/ 3, h = (19 * a + b - d - g + 15) % 30;
    final i = c ~/ 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7;
    final m = (a + 11 * h + 22 * l) ~/ 451;
    final month = (h + l - 7 * m + 114) ~/ 31, day = ((h + l - 7 * m + 114) % 31) + 1;
    return DateTime(y, month, day);
  }

  /// Les jours fériés de France métropolitaine (pas d'école ces jours-là ;
  /// le lundi de Pentecôte aussi).
  static Map<DateTime, String> publicHolidays(int y) {
    final p = easter(y);
    return {
      DateTime(y, 1, 1): 'Jour de l\'an',
      addDays(p, 1): 'Lundi de Pâques',
      DateTime(y, 5, 1): 'Fête du travail',
      DateTime(y, 5, 8): 'Victoire 1945',
      addDays(p, 39): 'Ascension',
      addDays(p, 50): 'Lundi de Pentecôte',
      DateTime(y, 7, 14): 'Fête nationale',
      DateTime(y, 8, 15): 'Assomption',
      DateTime(y, 11, 1): 'Toussaint',
      DateTime(y, 11, 11): 'Armistice',
      DateTime(y, 12, 25): 'Noël',
    };
  }

  /// Le nom du jour férié, ou null.
  static String? publicHoliday(DateTime day) => publicHolidays(day.year)[dateOnly(day)];

  /// Le prochain jour férié à partir de [from] (compris).
  static (DateTime, String) nextPublicHoliday(DateTime from) {
    final d = dateOnly(from);
    final all = [
      ...publicHolidays(d.year).entries,
      ...publicHolidays(d.year + 1).entries,
    ].where((e) => !e.key.isBefore(d)).toList()..sort((a, b) => a.key.compareTo(b.key));
    return (all.first.key, all.first.value);
  }

  // ------------------------------------------------------------ Zones

  /// Département → zone (réforme de 2016 : les zones suivent les régions).
  static const _zoneA = {
    '01', '03', '07', '15', '16', '17', '19', '21', '23', '24', '25', '26', '33', '38', '39', '40', '42', '43', //
    '47', '58', '63', '64', '69', '70', '71', '73', '74', '79', '86', '87', '89', '90',
  };
  static const _zoneB = {
    '02', '04', '05', '06', '08', '10', '13', '14', '18', '22', '27', '28', '29', '35', '36', '37', '41', '44', //
    '45', '49', '50', '51', '52', '53', '54', '55', '56', '57', '59', '60', '61', '62', '67', '68', '72', '76', //
    '80', '83', '84', '85', '88',
  };
  static const _zoneC = {
    '09', '11', '12', '30', '31', '32', '34', '46', '48', '65', '66', '75', '77', '78', '81', //
    '82', '91', '92', '93', '94', '95',
  };

  static const _dom = {'971': 'Guadeloupe', '972': 'Martinique', '973': 'Guyane', '974': 'Réunion', '976': 'Mayotte'};

  /// La zone d'un code postal (« 69003 » → A).
  static String? zoneFromPostcode(String pc) {
    final p = pc.trim();
    if (!RegExp(r'^\d{5}$').hasMatch(p) && !RegExp(r'^2[AB]\d{3}$', caseSensitive: false).hasMatch(p)) return null;
    if (p.startsWith('97')) return _dom[p.substring(0, 3)];
    if (p.startsWith('20') || p.toUpperCase().startsWith('2A') || p.toUpperCase().startsWith('2B')) return 'Corse';
    final d = p.substring(0, 2);
    if (_zoneA.contains(d)) return 'A';
    if (_zoneB.contains(d)) return 'B';
    if (_zoneC.contains(d)) return 'C';
    return null;
  }

  /// La zone d'une région (les zones suivent les régions depuis 2016).
  static String? zoneFromRegion(String region) {
    final r = norm(region);
    if (r.isEmpty) return null;
    if (RegExp(r'auvergne|rhone|aquitaine|bourgogne|franche').hasMatch(r)) return 'A';
    if (RegExp(r'ile de france|ile-de-france|occitanie').hasMatch(r)) return 'C';
    if (RegExp(r'corse').hasMatch(r)) return 'Corse';
    if (RegExp(r'hauts|grand est|normandie|bretagne|pays de la loire|centre|provence|azur|paca').hasMatch(r)) {
      return 'B';
    }
    for (final d in _dom.values) {
      if (r.contains(norm(d))) return d;
    }
    return null;
  }

  /// « zone b », « B », « je suis en zone C », « corse » → la zone.
  static String? zoneFromText(String text) {
    final t = norm(text).trim();
    final m = RegExp(r'(?:^|\bzone\s+|^la\s+)([abc])$|\bzone\s+([abc])\b').firstMatch(t);
    if (m != null) return (m[1] ?? m[2])!.toUpperCase();
    if (RegExp(r'\bcorse\b').hasMatch(t)) return 'Corse';
    for (final d in _dom.values) {
      if (RegExp('\\b${norm(d)}\\b').hasMatch(t)) return d;
    }
    return null;
  }

  /// Le nom à dire : « zone A », « Corse ».
  static String zoneLabel(String? z) => z == null
      ? 'zone inconnue'
      : z.length == 1
      ? 'zone $z'
      : z;

  /// Le nom de la zone dans le calendrier officiel.
  static String officialZone(String z) => z.length == 1 ? 'Zone $z' : z;

  /// La zone d'un lieu trouvé par le géocodage d'Open-Meteo (déjà utilisé
  /// pour la météo) : code postal, sinon région.
  static String? zoneFromPlace(Map place) {
    if ('${place['country_code'] ?? 'FR'}'.toUpperCase() != 'FR') return null;
    for (final p in (place['postcodes'] as List? ?? const [])) {
      final z = zoneFromPostcode('$p');
      if (z != null) return z;
    }
    return zoneFromRegion('${place['admin1'] ?? ''}');
  }

  // ------------------------------------------------------------ Vacances

  /// Le calendrier 2026-2027 (arrêté du 22 octobre 2025), rangé dans Mon Hub
  /// pour marcher sans internet. Le calendrier officiel en ligne prend le
  /// relais dès qu'il est lu (il couvre aussi les années suivantes).
  static List<SchoolBreak> builtIn(String? zone) {
    SchoolBreak b(String n, DateTime s, DateTime e, {bool approx = false}) =>
        SchoolBreak(n, s, e, source: 'integre', approxEnd: approx);
    final common = [
      b('Vacances de la Toussaint', DateTime(2026, 10, 17), DateTime(2026, 11, 2)),
      b('Vacances de Noël', DateTime(2026, 12, 19), DateTime(2027, 1, 4)),
      b('Pont de l\'Ascension', DateTime(2027, 5, 6), DateTime(2027, 5, 10)),
      b('Vacances d\'été', DateTime(2027, 7, 3), DateTime(2027, 9, 1), approx: true),
    ];
    final zoned = switch (zone) {
      'A' => [
        b('Vacances d\'hiver', DateTime(2027, 2, 13), DateTime(2027, 3, 1)),
        b('Vacances de printemps', DateTime(2027, 4, 10), DateTime(2027, 4, 26)),
      ],
      'B' => [
        b('Vacances d\'hiver', DateTime(2027, 2, 20), DateTime(2027, 3, 8)),
        b('Vacances de printemps', DateTime(2027, 4, 17), DateTime(2027, 5, 3)),
      ],
      'C' => [
        b('Vacances d\'hiver', DateTime(2027, 2, 6), DateTime(2027, 2, 22)),
        b('Vacances de printemps', DateTime(2027, 4, 3), DateTime(2027, 4, 19)),
      ],
      _ => const <SchoolBreak>[],
    };
    // Corse et outre-mer ont leur propre calendrier : seulement l'officiel.
    if (zone != null && zone.length > 1) return const [];
    return [...common, ...zoned]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Une date du calendrier officiel (« 2026-12-18T23:00:00+00:00 » = minuit
  /// à Paris le 19) → le jour, quel que soit le fuseau du PC.
  static DateTime? _officialDay(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    if (d == null) return null;
    // Heure de Paris ≈ UTC + 1 ou + 2 : on vise le milieu de la nuit.
    final p = d.isUtc || '$v'.contains('+') || '$v'.endsWith('Z') ? d.toUtc().add(const Duration(hours: 3)) : d;
    return DateTime(p.year, p.month, p.day);
  }

  /// Le calendrier officiel (data.education.gouv.fr, jeu
  /// « fr-en-calendrier-scolaire ») → les vacances, sans doublons.
  static List<SchoolBreak> parseOfficial(Object? json) {
    final rows = json is Map ? (json['results'] as List? ?? const []) : (json is List ? json : const []);
    final out = <SchoolBreak>[];
    for (final r in rows) {
      if (r is! Map) continue;
      final pop = norm('${r['population'] ?? '-'}');
      if (pop.contains('enseignant')) continue;
      final name = '${r['description'] ?? ''}'.trim();
      if (name.isEmpty || norm(name).contains('rentree')) continue;
      final s = _officialDay(r['start_date']);
      var e = _officialDay(r['end_date']);
      if (s == null) continue;
      var approx = false;
      // Le début de l'été sans date de fin : jusqu'à début septembre.
      if (e == null || !e.isAfter(s)) {
        if (!norm(name).contains('ete')) continue;
        e = DateTime(s.year, 9, 1);
        approx = true;
      }
      final clean = name.replaceFirst(RegExp(r'^D[ée]but des\s+', caseSensitive: false), '').trim();
      final label = clean.isEmpty ? name : clean[0].toUpperCase() + clean.substring(1);
      if (out.any((b) => b.start == s && b.end == e)) continue;
      out.add(SchoolBreak(label, s, e, source: 'officiel', approxEnd: approx));
    }
    return out..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Une ligne d'École Directe (« CONGÉS », « Vacances ») ?
  static final breakTitle = RegExp(
    r'^(?:cong[ée]s?|vacances|f[ée]ri[ée]|jour f[ée]ri[ée]|pont)\b|\bvacances\b|\bcong[ée]s\b',
    caseSensitive: false,
  );

  /// Les congés vus dans l'emploi du temps d'École Directe.
  static List<SchoolBreak> fromAgenda(List<Map> events) {
    final days = <DateTime, String>{};
    for (final e in events) {
      if (!isBreakItem(e)) continue;
      final s = start(e), f = end(e);
      if (s == null) continue;
      // Une fin à minuit pile appartient au jour d'avant.
      final last = f == null ? s : f.subtract(const Duration(minutes: 1));
      for (var d = dateOnly(s); !d.isAfter(dateOnly(last)); d = addDays(d, 1)) {
        days[d] = _breakName('${e['titre'] ?? ''}');
      }
    }
    final sorted = days.keys.toList()..sort();
    final out = <SchoolBreak>[];
    for (final d in sorted) {
      final last = out.lastOrNull;
      // Jours qui se suivent (ou séparés d'un week-end) = mêmes vacances.
      if (last != null && last.name == days[d] && !d.isAfter(addDays(last.end, 2))) {
        out[out.length - 1] = SchoolBreak(last.name, last.start, addDays(d, 1), source: 'ecole');
      } else {
        out.add(SchoolBreak(days[d]!, d, addDays(d, 1), source: 'ecole'));
      }
    }
    return out;
  }

  static String _breakName(String t) {
    final n = norm(t);
    final x = t.trim();
    if (n.contains('vacances') && x.length > 8) {
      // « VACANCES DE NOEL » → « Vacances de noel » ; sinon tel quel.
      final rest = x == x.toUpperCase() ? x.substring(1).toLowerCase() : x.substring(1);
      return x[0].toUpperCase() + rest;
    }
    if (n.contains('feri')) return 'Jour férié';
    return 'Vacances';
  }

  /// Toutes les vacances connues, les plus sûres d'abord (École Directe,
  /// puis l'officiel, puis la table de Mon Hub) ; pas de doublon.
  static List<SchoolBreak> merge(List<SchoolBreak> ecole, List<SchoolBreak> official, List<SchoolBreak> builtIn) {
    final out = <SchoolBreak>[...ecole];
    bool overlaps(SchoolBreak a, SchoolBreak b) => a.start.isBefore(b.end) && b.start.isBefore(a.end);
    for (final b in [...official, ...(official.isEmpty ? builtIn : const <SchoolBreak>[])]) {
      final same = out.indexWhere((x) => overlaps(x, b));
      if (same < 0) {
        out.add(b);
      } else if (out[same].source == 'ecole' && b.end.difference(b.start) > out[same].end.difference(out[same].start)) {
        // École Directe ne montre souvent que les premiers jours : l'officiel
        // donne le vrai nom et la vraie reprise.
        out[same] = b;
      }
    }
    return out..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Les vacances qui couvrent [day].
  static SchoolBreak? breakOn(DateTime day, List<SchoolBreak> breaks) {
    final hits = breaks.where((b) => b.covers(day)).toList()
      ..sort((a, b) => b.end.difference(b.start).compareTo(a.end.difference(a.start)));
    return hits.firstOrNull;
  }

  /// Les prochaines vacances après [day] (pas celles en cours). [holidayOnly] :
  /// de vraies vacances, pas un pont.
  static SchoolBreak? nextBreak(DateTime day, List<SchoolBreak> breaks, {bool holidayOnly = true}) {
    final d = dateOnly(day);
    final next = breaks.where((b) => b.start.isAfter(d) && (!holidayOnly || b.isHoliday)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return next.firstOrNull;
  }

  /// Les jours de classe (lundi–vendredi, hors fériés et vacances) d'ici
  /// [to] (exclu).
  static int schoolDaysBetween(DateTime from, DateTime to, List<SchoolBreak> breaks) {
    var n = 0;
    for (var d = dateOnly(from); d.isBefore(dateOnly(to)); d = addDays(d, 1)) {
      if (d.weekday <= 5 && publicHoliday(d) == null && breakOn(d, breaks) == null) n++;
    }
    return n;
  }

  // ------------------------------------------------------------ Agenda

  /// Un créneau d'École Directe (cours, annulé ou congé).
  static bool isSchoolItem(Map e) => norm('${e['source'] ?? ''}').contains('cole');

  /// Un congé / des vacances dans l'emploi du temps.
  static bool isBreakItem(Map e) =>
      e['vacances'] == true || (isSchoolItem(e) && breakTitle.hasMatch('${e['titre'] ?? ''}'));

  /// Un vrai cours qui a lieu.
  static bool isLesson(Map e) => isSchoolItem(e) && e['annule'] != true && !isBreakItem(e) && e['dispense'] != true;

  /// Le midi : un creux qui touche 11 h 30 – 14 h.
  static bool isLunch(DateTime a, DateTime b) {
    final from = DateTime(a.year, a.month, a.day, 11, 30), to = DateTime(a.year, a.month, a.day, 14);
    final m = b.difference(a).inMinutes;
    return a.isBefore(to) && b.isAfter(from) && m <= 150;
  }

  /// La journée [day] d'après l'agenda ([events] = `agenda_lire`) et les
  /// vacances connues. [known] : l'emploi du temps d'École Directe est lu
  /// (sinon un jour vide reste « inconnu »).
  static SchoolDay classify(
    DateTime day, {
    required List<Map> events,
    List<SchoolBreak> breaks = const [],
    bool known = true,
  }) {
    final d = dateOnly(day);
    bool on(Map e) {
      final s = start(e);
      return s != null && sameDay(s, d);
    }

    final school = [
      for (final e in events)
        if (isSchoolItem(e) && on(e)) e,
    ];
    final lessons = [
      for (final e in school)
        if (isLesson(e)) e,
    ]..sort((a, b) => start(a)!.compareTo(start(b)!));
    final cancelled = [
      for (final e in school)
        if (e['annule'] == true && !isBreakItem(e)) e,
    ]..sort((a, b) => start(a)!.compareTo(start(b)!));
    final edBreak = school.where(isBreakItem).firstOrNull;
    final b = breakOn(d, breaks);
    final ferie = publicHoliday(d);
    if (lessons.isNotEmpty) {
      return SchoolDay(date: d, kind: SchoolDayKind.cours, lessons: lessons, cancelled: cancelled, inBreak: b);
    }
    if (cancelled.isNotEmpty) {
      return SchoolDay(date: d, kind: SchoolDayKind.annule, cancelled: cancelled, inBreak: b);
    }
    if (b != null || edBreak != null) {
      return SchoolDay(
        date: d,
        kind: SchoolDayKind.vacances,
        reason: b?.name ?? _breakName('${edBreak!['titre'] ?? ''}'),
        inBreak: b,
      );
    }
    if (ferie != null) return SchoolDay(date: d, kind: SchoolDayKind.ferie, reason: ferie);
    if (d.weekday >= 6) return SchoolDay(date: d, kind: SchoolDayKind.weekend);
    // Un jour de semaine vide : « libre » seulement si la semaine a des cours
    // (sinon l'emploi du temps n'est peut-être pas encore lu).
    final monday = addDays(d, 1 - d.weekday), sunday = addDays(monday, 7);
    final weekHasSchool = events.any((e) {
      final s = start(e);
      return isSchoolItem(e) && s != null && !s.isBefore(monday) && s.isBefore(sunday);
    });
    return SchoolDay(date: d, kind: known && weekHasSchool ? SchoolDayKind.libre : SchoolDayKind.inconnu);
  }

  /// Où on en est maintenant.
  static SchoolMoment moment(DateTime now, SchoolDay today) {
    if (!today.hasClass) return SchoolMoment(now: now, today: today, phase: SchoolPhase.pasCours);
    final ls = today.lessons;
    for (final l in ls) {
      final s = start(l)!, e = end(l)!;
      if (!now.isBefore(s) && now.isBefore(e)) {
        return SchoolMoment(now: now, today: today, phase: SchoolPhase.enCours, current: l, until: e);
      }
    }
    final next = ls.where((l) => start(l)!.isAfter(now)).firstOrNull;
    if (next == null) return SchoolMoment(now: now, today: today, phase: SchoolPhase.fini);
    final first = start(ls.first)!;
    if (!now.isAfter(first) && identical(next, ls.first)) {
      return SchoolMoment(now: now, today: today, phase: SchoolPhase.avant, next: next, until: start(next));
    }
    final before = ls.lastWhere((l) => !start(l)!.isAfter(now));
    final from = end(before)!, to = start(next)!;
    final gap = to.difference(from).inMinutes;
    final phase = gap < 30
        ? SchoolPhase.pause
        : today.gaps.any((g) => g.lunch && g.from == from)
        ? SchoolPhase.midi
        : SchoolPhase.trou;
    return SchoolMoment(now: now, today: today, phase: phase, next: next, until: to);
  }

  /// Le prochain jour avec cours après [from] : (jour, sa journée). Au-delà de
  /// l'emploi du temps connu, un jour de semaine hors vacances et fériés.
  static (DateTime, SchoolDay)? nextSchoolDay(
    DateTime from, {
    required List<Map> events,
    List<SchoolBreak> breaks = const [],
    bool known = true,
    int maxDays = 120,
  }) {
    final lastKnown = events
        .where(isSchoolItem)
        .map(start)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    for (var i = 1; i <= maxDays; i++) {
      final d = addDays(from, i);
      final day = classify(d, events: events, breaks: breaks, known: known);
      if (day.hasClass) return (d, day);
      final beyond = lastKnown == null || dateOnly(d).isAfter(dateOnly(lastKnown));
      if (day.kind == SchoolDayKind.inconnu && (beyond || !known)) return (d, day);
    }
    return null;
  }

  // ------------------------------------------------------------ Phrases

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _lesson(Map l) => '${l['titre'] ?? 'cours'}'.trim();

  /// Ce qu'une journée donne, en une ou deux phrases (« Demain : cours de 8 h à
  /// 17 h. Ton cours de SVT de 10 h est annulé. »).
  static String sayDay(SchoolDay d, DateTime now) {
    final w = dayWord(d.date, now);
    final cap = _cap(w);
    final be = sameDay(d.date, now) ? 'c\'est' : (dateOnly(d.date).isBefore(dateOnly(now)) ? 'c\'était' : 'ce sera');
    switch (d.kind) {
      case SchoolDayKind.cours:
        final parts = <String>['$cap : cours de ${hm(d.first!)} à ${hm(d.last!)} (${d.lessons.length} cours).'];
        if (d.cancelled.isNotEmpty) {
          parts.add(
            d.cancelled.length == 1
                ? 'Ton cours de ${_lesson(d.cancelled.first)} de ${hm(start(d.cancelled.first)!)} est annulé.'
                : '${d.cancelled.length} cours annulés (${d.cancelled.map(_lesson).toSet().join(', ')}).',
          );
        }
        if (d.lateStart) parts.add('Tu commences à ${hm(d.first!)} au lieu de ${hm(d.plannedFirst!)}.');
        if (d.earlyEnd) parts.add('Tu finis à ${hm(d.last!)} au lieu de ${hm(d.plannedLast!)}.');
        final free = d.freePeriods;
        if (free.isNotEmpty && !d.lateStart) {
          parts.add(
            free.length == 1
                ? 'Une heure de libre de ${hm(free.first.from)} à ${hm(free.first.to)}.'
                : '${free.length} trous dans la journée.',
          );
        }
        return parts.join(' ');
      case SchoolDayKind.annule:
        return 'Pas de cours $w : tous tes cours sont annulés (${d.cancelled.map(_lesson).toSet().take(4).join(', ')}) 🎉';
      case SchoolDayKind.vacances:
        final b = d.inBreak;
        final name = _lower(b?.name ?? d.reason);
        if (b == null) return 'Pas de cours $w : $name.';
        final back = b.approxEnd ? 'rentrée début septembre' : 'reprise le ${longDate(b.end)}';
        return 'Pas de cours $w : $name, $back.';
      case SchoolDayKind.ferie:
        return 'Pas de cours $w : $be férié (${d.reason}).';
      case SchoolDayKind.weekend:
        return 'Pas de cours $w : $be le week-end.';
      case SchoolDayKind.libre:
        return 'Pas de cours $w : rien dans ton emploi du temps.';
      case SchoolDayKind.inconnu:
        return d.date.weekday <= 5
            ? '$cap, normalement tu as cours, mais je n\'ai pas ton emploi du temps.'
            : 'Pas de cours $w a priori.';
    }
  }

  /// « Vacances de Noël » → « vacances de Noël ».
  static String _lower(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  /// « les vacances de Noël », « le pont de l'Ascension ».
  static String _article(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'les vacances';
    final l = n[0].toLowerCase() + n.substring(1);
    if (norm(l).startsWith('vacances')) return 'les $l';
    if (norm(l).startsWith('pont')) return 'le $l';
    if (norm(l).startsWith('jour')) return 'un $l';
    return 'les vacances ($n)';
  }

  /// « les vacances de Noël » (pour une phrase).
  static String breakPhrase(SchoolBreak b) => _article(b.name);

  /// Le moment, en une phrase.
  static String sayMoment(SchoolMoment m) {
    final n = m.next, c = m.current, u = m.until;
    return switch (m.phase) {
      SchoolPhase.avant => 'Les cours n\'ont pas commencé : ${_lesson(n!)} à ${hm(u!)}.',
      SchoolPhase.enCours => 'En ce moment : ${_lesson(c!)} jusqu\'à ${hm(u!)}.',
      SchoolPhase.pause => 'Pause entre deux cours : ${_lesson(n!)} à ${hm(u!)}.',
      SchoolPhase.trou => 'Heure de libre jusqu\'à ${hm(u!)} (puis ${_lesson(n!)}).',
      SchoolPhase.midi => 'Pause de midi jusqu\'à ${hm(u!)} (puis ${_lesson(n!)}).',
      SchoolPhase.fini => 'Les cours sont finis pour aujourd\'hui (fini à ${hm(m.today.last!)}).',
      SchoolPhase.pasCours => sayDay(m.today, m.now),
    };
  }

  /// Ce qu'un cours annulé change à la journée (« Tu commences à 9 h au lieu
  /// de 8 h », « Plus aucun cours ce jour-là 🎉 », « 1 h de libre »).
  static String cancelImpact(SchoolDay d, Map cancelled) {
    final s = start(cancelled), e = end(cancelled);
    if (s == null) return '';
    if (!d.hasClass) return 'Plus aucun cours ce jour-là 🎉';
    if (e != null && !e.isAfter(d.first!)) return 'Tu commences à ${hm(d.first!)} au lieu de ${hm(s)}.';
    if (!s.isBefore(d.last!)) return 'Tu finis à ${hm(d.last!)} au lieu de ${hm(e ?? s)}.';
    final gap = d.gaps.where((g) => !g.from.isAfter(s) && !g.to.isBefore(e ?? s)).firstOrNull;
    if (gap == null) return '';
    final mins = gap.to.difference(gap.from).inMinutes;
    final h = mins >= 60
        ? '${mins ~/ 60} h${mins % 60 == 0 ? '' : ' ${(mins % 60).toString().padLeft(2, '0')}'}'
        : '$mins min';
    return '$h de libre (${hm(gap.from)} – ${hm(gap.to)}).';
  }

  /// Le point « école » complet : aujourd'hui, maintenant, demain, la
  /// reprise, les prochaines vacances.
  static SchoolReport report(
    DateTime now, {
    required List<Map> events,
    List<SchoolBreak> breaks = const [],
    bool known = true,
    String? zone,
  }) {
    final today = classify(now, events: events, breaks: breaks, known: known);
    final tomorrow = classify(addDays(now, 1), events: events, breaks: breaks, known: known);
    final m = moment(now, today);
    final next = nextSchoolDay(now, events: events, breaks: breaks, known: known);
    final current = breakOn(now, breaks);
    final upcoming = nextBreak(now, breaks);
    return SchoolReport(
      now: now,
      today: today,
      tomorrow: tomorrow,
      moment: m,
      nextDay: next?.$1,
      nextDayInfo: next?.$2,
      currentBreak: current,
      nextBreak: upcoming,
      breaks: breaks,
      zone: zone,
    );
  }
}

/// Tout ce que Mon Hub sait de l'école en ce moment (calculé sans IA).
class SchoolReport {
  const SchoolReport({
    required this.now,
    required this.today,
    required this.tomorrow,
    required this.moment,
    this.nextDay,
    this.nextDayInfo,
    this.currentBreak,
    this.nextBreak,
    this.breaks = const [],
    this.zone,
  });

  final DateTime now;
  final SchoolDay today;
  final SchoolDay tomorrow;
  final SchoolMoment moment;

  /// Le prochain jour avec cours (après aujourd'hui).
  final DateTime? nextDay;
  final SchoolDay? nextDayInfo;
  final SchoolBreak? currentBreak;
  final SchoolBreak? nextBreak;
  final List<SchoolBreak> breaks;
  final String? zone;

  /// En vacances (ou en pont) en ce moment.
  bool get onBreak => currentBreak != null && !today.hasClass;

  /// Le premier jour des vacances (pour « Bonnes vacances ! »).
  bool get breakStarts {
    final b = currentBreak;
    if (b == null || today.hasClass) return false;
    // Le samedi, ou le premier jour de semaine (week-end compris).
    return SchoolRules.dateOnly(now).difference(b.start).inDays <= 2;
  }

  /// Demain, c'est la reprise après des vacances (ou un long week-end).
  bool get backTomorrow {
    final n = nextDay;
    if (n == null || !tomorrow.hasClass || !SchoolRules.sameDay(n, SchoolRules.addDays(now, 1))) return false;
    return currentBreak != null || today.kind == SchoolDayKind.vacances;
  }

  /// Les jours de classe avant les prochaines vacances.
  int? get schoolDaysToBreak {
    final b = nextBreak;
    if (b == null) return null;
    return SchoolRules.schoolDaysBetween(SchoolRules.addDays(now, 1), b.start, breaks);
  }

  /// « La reprise : lundi 4 janvier à 8 h (Maths). »
  String sayNextDay() {
    final n = nextDay;
    if (n == null) return 'Je ne vois pas quand tu reprends les cours.';
    final info = nextDayInfo;
    final first = info?.lessons.firstOrNull;
    final at = first == null ? '' : ' à ${SchoolRules.hm(SchoolRules.start(first)!)} (${first['titre'] ?? 'cours'})';
    return '${SchoolRules.dayWord(n, now) == 'demain' ? 'Demain' : 'Le ${SchoolRules.longDate(n)}'}$at.';
  }

  /// La phrase des prochaines vacances.
  String sayNextBreak() {
    final b = nextBreak;
    if (b == null) return 'Je ne connais pas encore tes prochaines vacances.';
    final days = SchoolRules.dateOnly(b.start).difference(SchoolRules.dateOnly(now)).inDays;
    final school = schoolDaysToBreak ?? 0;
    final when = days <= 1 ? (days == 1 ? 'demain' : 'aujourd\'hui') : 'dans $days jours';
    final left = school > 0 && school <= 15 ? ' Plus que $school jour${school > 1 ? 's' : ''} de cours.' : '';
    final back = b.approxEnd ? 'rentrée début septembre' : 'reprise le ${SchoolRules.longDate(b.end)}';
    return '${SchoolRules._cap(SchoolRules.breakPhrase(b))} commencent $when, le ${SchoolRules.longDate(b.start)} '
            '($back).$left'
        .replaceFirst('Le pont de l\'Ascension commencent', 'Le pont de l\'Ascension commence');
  }

  /// La réponse à « j'ai cours ? » pour aujourd'hui.
  String sayToday() {
    final m = moment;
    if (!today.hasClass) {
      final back = nextDay == null ? '' : ' Reprise : ${sayNextDay()}';
      return '${SchoolRules.sayDay(today, now)}$back';
    }
    return switch (m.phase) {
      SchoolPhase.fini => '${SchoolRules.sayMoment(m)} ${SchoolRules.sayDay(tomorrow, now)}',
      SchoolPhase.avant => SchoolRules.sayDay(today, now),
      _ => '${SchoolRules.sayMoment(m)} Tu finis à ${SchoolRules.hm(today.last!)}.',
    };
  }

  /// Les lignes ajoutées aux consignes de Nexo (Claude, Gemini, Gemini Live).
  String promptBlock() {
    final b = StringBuffer(
      'École (calculé par Mon Hub d\'après École Directe et le calendrier officiel, sans IA : '
      'fie-toi à ça plutôt qu\'à une supposition) :\n',
    );
    b.writeln('- ${sayToday()}');
    if (today.hasClass && moment.phase != SchoolPhase.fini) b.writeln('- ${SchoolRules.sayDay(tomorrow, now)}');
    if (onBreak && nextDay != null) b.writeln('- Rentrée : ${sayNextDay()}');
    if (nextBreak != null) b.writeln('- Prochaines vacances : ${sayNextBreak()}');
    if (zone != null) b.writeln('- Vacances de la ${SchoolRules.zoneLabel(zone)}.');
    b.write(
      '- Adapte-toi : ${switch (moment.phase) {
        SchoolPhase.enCours => 'la personne est sans doute en classe : réponds court et par écrit, ne propose rien de bruyant',
        SchoolPhase.pasCours => 'pas de cours aujourd\'hui : ne parle pas des cours du jour comme s\'ils avaient lieu, pense temps libre (repos, loisirs, avance tranquille des devoirs pour la reprise)',
        SchoolPhase.fini => 'les cours sont finis : c\'est le moment des devoirs pour demain et du temps libre',
        SchoolPhase.trou || SchoolPhase.midi => 'elle a du temps libre avant son prochain cours : propose de l\'utiliser si c\'est utile',
        _ => 'elle a cours aujourd\'hui',
      }}.',
    );
    return '$b';
  }

  Map<String, dynamic> toJson() => {
    'resume': sayToday(),
    'contexte': promptBlock(),
    if (backTomorrow) 'reprise_demain': true,
    if (breakStarts) 'debut_vacances': true,
    if (schoolDaysToBreak != null) 'jours_de_cours_avant_vacances': schoolDaysToBreak,
    'aujourdhui': today.toJson(),
    'demain': tomorrow.toJson(),
    'maintenant': moment.phase.name,
    if (moment.current != null) 'cours_en_cours': '${moment.current!['titre'] ?? ''}',
    if (moment.until != null) 'jusqua': SchoolRules.hm(moment.until!),
    if (moment.until != null) 'jusqua_iso': moment.until!.toIso8601String(),
    if (nextDay != null) 'prochain_jour_de_cours': {'date': SchoolRules.ymd(nextDay!), 'texte': sayNextDay()},
    if (currentBreak != null) 'vacances_en_cours': currentBreak!.toJson(),
    if (nextBreak != null) 'prochaines_vacances': {...nextBreak!.toJson(), 'texte': sayNextBreak()},
    'zone': SchoolRules.zoneLabel(zone),
  };
}

/// **Le calendrier scolaire de la personne** : sa zone (réglée, ou devinée
/// d'après sa ville), les vacances officielles (data.education.gouv.fr,
/// données publiques, relues une fois par semaine ; seule la zone est
/// envoyée) et le dernier point calculé, gardé pour ceux qui ont besoin d'une
/// réponse tout de suite (robots, Nexo discret pendant un cours).
class SchoolCalendar extends ChangeNotifier {
  SchoolCalendar._();
  static final instance = SchoolCalendar._();

  /// La zone choisie (préférence du compte : suit la personne sur ses appareils).
  static const kZone = 'hub.ecole.zone';

  /// Le calendrier officiel lu (propre au PC, jamais synchronisé).
  static const _kCache = 'app.vacances';

  /// Remplace internet (tests).
  @visibleForTesting
  static Future<Object?> Function(Uri url)? fetchOverride;

  String? _zoneMem;

  String? get zone {
    try {
      final z = ModuleStore.prefs.getString(kZone);
      return z == null || z.isEmpty ? _zoneMem : z;
    } catch (_) {
      return _zoneMem;
    }
  }

  /// Règle la zone (null = l'effacer). [guessed] : devinée d'après la ville.
  Future<void> setZone(String? z, {bool guessed = false}) async {
    _zoneMem = z;
    try {
      if (z == null) {
        await ModuleStore.prefs.remove(kZone);
        await ModuleStore.prefs.remove('$kZone.devinee');
      } else {
        await ModuleStore.prefs.setString(kZone, z);
        await ModuleStore.prefs.setBool('$kZone.devinee', guessed);
      }
    } catch (_) {}
    _official = null;
    notifyListeners();
    unawaited(refresh(force: true));
  }

  /// La zone a été devinée (pas choisie par la personne).
  bool get zoneGuessed {
    try {
      return ModuleStore.prefs.getBool('$kZone.devinee') ?? false;
    } catch (_) {
      return false;
    }
  }

  List<SchoolBreak>? _official;

  /// Les vacances officielles de la zone (lues dans le cache).
  List<SchoolBreak> get official {
    final z = zone;
    if (z == null) return const [];
    if (_official case final o?) return o;
    try {
      final j = jsonDecode(ModuleStore.global.getString('$_kCache.$z') ?? '');
      if (j is Map) {
        return _official = [for (final b in (j['vacances'] as List? ?? const [])) ?SchoolBreak.fromJson(b)];
      }
    } catch (_) {}
    return const [];
  }

  DateTime? _readAt() {
    try {
      final j = jsonDecode(ModuleStore.global.getString('$_kCache.${zone ?? ''}') ?? '');
      return j is Map ? DateTime.tryParse('${j['lu'] ?? ''}') : null;
    } catch (_) {
      return null;
    }
  }

  bool _busy = false;

  /// Relit le calendrier officiel (au plus une fois par semaine).
  Future<void> refresh({bool force = false}) async {
    final z = zone;
    if (z == null || _busy) return;
    final at = _readAt();
    if (!force && at != null && DateTime.now().difference(at) < const Duration(days: 7)) return;
    _busy = true;
    try {
      final now = DateTime.now();
      final y = now.month >= 8 ? now.year : now.year - 1;
      final years = ['$y-${y + 1}', '${y + 1}-${y + 2}'];
      final where =
          'zones="${SchoolRules.officialZone(z)}" and (${years.map((x) => 'annee_scolaire="$x"').join(' or ')})';
      final url = Uri.https(
        'data.education.gouv.fr',
        '/api/explore/v2.1/catalog/datasets/fr-en-calendrier-scolaire/records',
        {'where': where, 'limit': '100', 'select': 'description,population,start_date,end_date,zones,annee_scolaire'},
      );
      final Object? j;
      if (fetchOverride != null) {
        j = await fetchOverride!(url);
      } else {
        final r = await http.get(url, headers: {'user-agent': 'MonHub'}).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return;
        j = jsonDecode(utf8.decode(r.bodyBytes));
      }
      final list = SchoolRules.parseOfficial(j);
      if (list.isEmpty) return;
      _official = list;
      await ModuleStore.global.setString(
        '$_kCache.$z',
        jsonEncode({
          'lu': DateTime.now().toIso8601String(),
          'vacances': [for (final b in list) b.toJson()],
        }),
      );
      notifyListeners();
    } catch (_) {
      // Sans internet : la table rangée dans Mon Hub suffit.
    } finally {
      _busy = false;
    }
  }

  /// Devine la zone d'après la ville (géocodage Open-Meteo, déjà utilisé
  /// pour la météo). Ne remplace jamais une zone choisie par la personne.
  Future<String?> guessFromCity(String city) async {
    final c = city.trim();
    if (c.isEmpty) return null;
    if (zone != null && !zoneGuessed) return zone;
    try {
      final url = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': c,
        'count': '1',
        'language': 'fr',
        'format': 'json',
        'countryCode': 'FR',
      });
      final Object? j;
      if (fetchOverride != null) {
        j = await fetchOverride!(url);
      } else {
        final r = await http.get(url).timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) return null;
        j = jsonDecode(utf8.decode(r.bodyBytes));
      }
      final place = (j is Map ? j['results'] as List? : null)?.whereType<Map>().firstOrNull;
      final z = place == null ? null : SchoolRules.zoneFromPlace(place);
      if (z != null && z != zone) await setZone(z, guessed: true);
      return z;
    } catch (_) {
      return null;
    }
  }

  /// Toutes les vacances connues (avec celles vues dans [events]).
  List<SchoolBreak> breaks({List<Map> events = const []}) =>
      SchoolRules.merge(SchoolRules.fromAgenda(events), official, SchoolRules.builtIn(zone));

  /// Le dernier point calculé (pour une réponse immédiate).
  SchoolReport? last;

  /// Calcule le point et le garde.
  SchoolReport build(DateTime now, {required List<Map> events, bool known = true}) {
    final r = SchoolRules.report(
      now,
      events: events,
      breaks: breaks(events: events),
      known: known,
      zone: zone,
    );
    last = r;
    return r;
  }

  /// Y a-t-il cours ce jour-là ? (d'après le dernier point ; null = on ne
  /// sait pas). Sert aux robots (« la veille d'un jour de cours »).
  bool? hasClassOn(DateTime day) {
    final r = last;
    if (r == null || DateTime.now().difference(r.now) > const Duration(hours: 6)) {
      // Sans point récent : le calendrier seul (vacances, fériés, week-end).
      final d = SchoolRules.dateOnly(day);
      if (d.weekday >= 6 || SchoolRules.publicHoliday(d) != null) return false;
      if (SchoolRules.breakOn(d, breaks()) != null) return false;
      return null;
    }
    for (final x in [r.today, r.tomorrow, ?r.nextDayInfo]) {
      if (SchoolRules.sameDay(x.date, day)) {
        if (x.hasClass) return true;
        if (x.noClass) return false;
        return x.date.weekday <= 5 ? null : false;
      }
    }
    final d = SchoolRules.dateOnly(day);
    if (d.weekday >= 6 || SchoolRules.publicHoliday(d) != null || SchoolRules.breakOn(d, r.breaks) != null) {
      return false;
    }
    return null;
  }

  /// La personne est sans doute en classe en ce moment.
  bool get inClassNow {
    final r = last;
    if (r == null) return false;
    final now = DateTime.now();
    if (!SchoolRules.sameDay(r.now, now)) return false;
    return SchoolRules.moment(now, r.today).inClass;
  }

  /// Remis à zéro (tests).
  @visibleForTesting
  void reset() {
    last = null;
    _official = null;
    _zoneMem = null;
  }
}
