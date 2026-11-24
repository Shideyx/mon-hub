import 'package:flutter/foundation.dart';

import 'hub_files.dart';

/// Un anniversaire (sans année : on ne connaît pas toujours l'âge).
class Birthday {
  const Birthday(this.name, this.month, this.day, {this.year, this.fromAgenda = false});

  final String name;
  final int month;
  final int day;
  final int? year;

  /// Vu dans Google Agenda (pas ajouté à la main).
  final bool fromAgenda;

  Map<String, dynamic> toJson() => {'nom': name, 'mois': month, 'jour': day, 'annee': ?year};

  static Birthday? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = (j['mois'] as num?)?.toInt(), d = (j['jour'] as num?)?.toInt();
    final name = '${j['nom'] ?? ''}'.trim();
    if (name.isEmpty || m == null || d == null || m < 1 || m > 12 || d < 1 || d > 31) return null;
    return Birthday(name, m, d, year: (j['annee'] as num?)?.toInt());
  }
}

/// **Anniversaires des proches** : ceux de Google Agenda (le calendrier
/// « Anniversaires » de tes contacts) et ceux que tu ajoutes (« l'anniversaire
/// de Léa c'est le 12 mars »). Rappel la veille au soir et le jour même, avec
/// un petit message tout prêt. Gardés dans `anniversaires.json` (synchronisé
/// sur tes appareils, dans ton Drive).
class Birthdays extends ChangeNotifier {
  Birthdays._();
  static final instance = Birthdays._();

  final _file = JsonFile<Map<String, dynamic>>(
    'anniversaires.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  Future<void> load() async {
    if (await _file.reload()) notifyListeners();
  }

  /// Ceux ajoutés à la main.
  List<Birthday> get saved =>
      [for (final j in (_file.value['liste'] as List? ?? const [])) ?Birthday.fromJson(j)]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> add(Birthday b) async {
    await _file.update((m) {
      final l = [
        for (final j in (m['liste'] as List? ?? const []))
          if (Birthday.fromJson(j) case final x? when key(x.name) != key(b.name)) x.toJson(),
        b.toJson(),
      ];
      return {...m, 'liste': l};
    });
    notifyListeners();
  }

  Future<bool> remove(String name) async {
    var found = false;
    final k = key(name);
    await _file.update((m) {
      final l = <Map<String, dynamic>>[];
      for (final j in (m['liste'] as List? ?? const [])) {
        final x = Birthday.fromJson(j);
        if (x == null) continue;
        if (key(x.name) == k || key(x.name).startsWith('$k ')) {
          found = true;
          continue;
        }
        l.add(x.toJson());
      }
      return {...m, 'liste': l};
    });
    notifyListeners();
    return found;
  }

  // ------------------------------------------------------------ Sans IA

  static String key(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().trim().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString().replaceAll(RegExp(r'\s+'), ' ');
  }

  static const months = [
    'janvier',
    'fevrier',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'aout',
    'septembre',
    'octobre',
    'novembre',
    'decembre',
  ];
  static const _monthsFr = [
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

  /// Le nom dans un titre d'agenda (« Anniversaire de Léa », « Tom's
  /// birthday », « 🎂 Mamie »), sinon null.
  static String? nameInTitle(String title, {String calendar = ''}) {
    final t = title.trim();
    final m =
        RegExp(
          r"^(?:🎂\s*)?(?:joyeux |bon )?anniversaire (?:de |d['’]\s?|à |a )(.+?)\s*(?:🎂|🎉)?$",
          caseSensitive: false,
        ).firstMatch(t) ??
        RegExp(r"^(.+?)['’]s birthday$", caseSensitive: false).firstMatch(t) ??
        RegExp(r'^🎂\s*(.+)$').firstMatch(t) ??
        RegExp(r'^anniv(?:ersaire)?\s*[:\-–]\s*(.+)$', caseSensitive: false).firstMatch(t);
    if (m != null) return m[1]!.trim();
    // Le calendrier « Anniversaires » des contacts : le titre est le nom.
    if (RegExp(r'anniversaires|birthdays', caseSensitive: false).hasMatch(calendar) && t.isNotEmpty && t.length < 60) {
      return t;
    }
    return null;
  }

  /// Les anniversaires vus dans l'agenda (sortie de `agenda_lire`).
  static List<Birthday> fromEvents(List<Map> events) {
    final out = <Birthday>[];
    for (final e in events) {
      final name = nameInTitle('${e['titre'] ?? ''}', calendar: '${e['detail'] ?? ''}');
      final d = e['debut'] is DateTime ? e['debut'] as DateTime : DateTime.tryParse('${e['debut'] ?? ''}');
      if (name == null || d == null) continue;
      out.add(Birthday(name, d.month, d.day, fromAgenda: true));
    }
    return out;
  }

  /// « Léa le 12 mars », « 12/03/2010 », « le 3 avril 2011 » → (mois, jour, année).
  static (int, int, int?)? parseDate(String text) {
    final t = key(text).replaceAll(RegExp(r'\b1er\b'), '1');
    final m = RegExp(
      r'\b(\d{1,2})\s*(?:er)?\s+(' + months.join('|') + r'|fevr?|janv?|avr|juil|sept?|oct|nov|dec)\.?(?:\s+(\d{4}))?\b',
    ).firstMatch(t);
    if (m != null) {
      final day = int.parse(m[1]!);
      final word = m[2]!;
      final month = months.indexWhere((x) => x.startsWith(word.substring(0, word.length.clamp(3, 4)))) + 1;
      final year = m[3] == null ? null : int.parse(m[3]!);
      return _valid(month, day) ? (month, day, year) : null;
    }
    final n = RegExp(r'\b(\d{1,2})[/.\-](\d{1,2})(?:[/.\-](\d{2,4}))?\b').firstMatch(t);
    if (n != null) {
      final day = int.parse(n[1]!), month = int.parse(n[2]!);
      var year = n[3] == null ? null : int.parse(n[3]!);
      if (year != null && year < 100) year += year > 30 ? 1900 : 2000;
      return _valid(month, day) ? (month, day, year) : null;
    }
    return null;
  }

  static bool _valid(int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    const max = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return day <= max[month - 1];
  }

  /// La prochaine fois (aujourd'hui compris). Le 29 février fêté le 28.
  static DateTime next(Birthday b, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    DateTime on(int y) {
      final leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
      return DateTime(y, b.month, b.month == 2 && b.day == 29 && !leap ? 28 : b.day);
    }

    final d = on(now.year);
    return d.isBefore(today) ? on(now.year + 1) : d;
  }

  /// L'âge atteint ce jour-là (si on connaît l'année).
  static int? age(Birthday b, DateTime on) => b.year == null || b.year! < 1900 ? null : on.year - b.year!;

  /// Ceux des [days] prochains jours, les plus proches d'abord (sans doublon).
  static List<(Birthday, DateTime)> upcoming(Iterable<Birthday> all, DateTime now, {int days = 30}) {
    final today = DateTime(now.year, now.month, now.day);
    final seen = <String>{};
    final out = <(Birthday, DateTime)>[];
    // Ceux ajoutés à la main d'abord (ils ont souvent l'année).
    final list = [...all]..sort((a, b) => (a.fromAgenda ? 1 : 0) - (b.fromAgenda ? 1 : 0));
    for (final b in list) {
      final k = key(b.name);
      if (!seen.add(k) || seen.any((s) => s != k && (s.startsWith('$k ') || k.startsWith('$s ')))) continue;
      final d = next(b, now);
      if (d.difference(today).inDays <= days) out.add((b, d));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  static String _when(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final n = d.difference(today).inDays;
    if (n == 0) return 'aujourd\'hui';
    if (n == 1) return 'demain';
    const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
    if (n < 7) return days[d.weekday - 1];
    return 'le ${d.day == 1 ? '1er' : d.day} ${_monthsFr[d.month - 1]}';
  }

  static String dateText(Birthday b) =>
      '${b.day == 1 ? '1er' : b.day} ${_monthsFr[b.month - 1]}${b.year == null ? '' : ' ${b.year}'}';

  /// « Aujourd'hui : Léa (15 ans) 🎂 ; demain : Tom ; le 3 décembre : Mamie. »
  static String say(List<(Birthday, DateTime)> up, DateTime now) {
    if (up.isEmpty) return 'Pas d\'anniversaire dans les jours qui viennent.';
    final parts = [
      for (final (b, d) in up.take(6))
        '${_when(d, now)} : ${b.name}${_ageText(b, d)}${d.month == now.month && d.day == now.day ? ' 🎂' : ''}',
    ];
    final text = parts.join(' ; ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }

  static String _ageText(Birthday b, DateTime d) {
    final a = age(b, d);
    return a == null ? '' : ' ($a ans)';
  }

  /// Un petit message tout prêt.
  static String wish(Birthday b, DateTime on) {
    final first = b.name.split(' ').first;
    final a = age(b, on);
    return a != null && a <= 25
        ? 'Joyeux anniversaire $first ! 🎉 $a ans, ça se fête ! Passe une super journée 🎂'
        : 'Joyeux anniversaire $first ! 🎉 Passe une super journée 🎂';
  }
}
