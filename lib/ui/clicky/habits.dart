// **Clicky te connaît** (v1.58) : il apprend tes habitudes avec le temps
// d'écran par heure (sur ce PC seulement, jamais envoyé) — « le mercredi
// vers 14 h, c'est Roblox (4 semaines sur 4) », ton heure la plus active,
// l'heure où tu quittes le PC le soir, ton appli n° 1 — et s'en sert pour
// t'aider au bon moment (« d'habitude, à 14 h c'est Roblox… mais contrôle de
// SVT demain : 20 minutes de révisions avant ? »).

import '../../core/screen_time.dart';

/// Une habitude : tel jour, vers telle heure, telle appli.
class Habit {
  const Habit(this.weekday, this.hour, this.app, this.weeks, this.minutes);

  /// 1 = lundi.
  final int weekday;
  final int hour;
  final String app;

  /// Sur les 4 dernières semaines.
  final int weeks;

  /// Minutes en moyenne ce jour-là à cette heure.
  final int minutes;

  static const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  String get say => 'le ${days[weekday - 1]} vers $hour h : $app ($weeks semaines sur 4)';

  Map<String, dynamic> toJson() => {'jour': days[weekday - 1], 'heure': hour, 'appli': app, 'semaines': weeks, 'minutes': minutes};
}

class Habits {
  Habits._();

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  static Map<String, int> _at(Map raw, DateTime day, int hour) {
    final d = raw[_day(day)];
    final h = d is Map ? d['$hour'] : null;
    if (h is! Map) return const {};
    return {for (final e in h.entries) '${e.key}': (e.value as num).toInt()};
  }

  /// Les habitudes (au moins 10 min, 3 semaines sur les 4 dernières), les
  /// plus sûres d'abord. [raw] = `ScreenTime.hours`.
  static List<Habit> find(Map raw, DateTime now) {
    final out = <Habit>[];
    final today = DateTime(now.year, now.month, now.day);
    for (var wd = 1; wd <= 7; wd++) {
      // Les 4 derniers jours de la semaine [wd] (avant aujourd'hui).
      var back = (now.weekday - wd) % 7;
      if (back == 0) back = 7;
      final dates = [for (var k = 0; k < 4; k++) today.subtract(Duration(days: back + 7 * k))];
      for (var hour = 0; hour < 24; hour++) {
        final count = <String, int>{}, secs = <String, int>{};
        for (final d in dates) {
          for (final e in _at(raw, d, hour).entries) {
            if (e.key == 'Mon Hub' || e.key == 'Explorateur' || e.key == 'Autre') continue;
            if (e.value >= 600) {
              count[e.key] = (count[e.key] ?? 0) + 1;
              secs[e.key] = (secs[e.key] ?? 0) + e.value;
            }
          }
        }
        for (final e in count.entries) {
          if (e.value >= 3) out.add(Habit(wd, hour, e.key, e.value, secs[e.key]! ~/ e.value ~/ 60));
        }
      }
    }
    out.sort((a, b) => b.weeks != a.weeks ? b.weeks.compareTo(a.weeks) : b.minutes.compareTo(a.minutes));
    return out;
  }

  /// Une habitude de distraction qui commence dans moins de 15 minutes.
  static Habit? upcoming(List<Habit> habits, DateTime now, Set<String> distractions) {
    if (now.minute < 45) return null;
    final next = now.add(const Duration(minutes: 20));
    for (final h in habits) {
      if (h.weekday == next.weekday && h.hour == next.hour && distractions.contains(h.app)) return h;
    }
    return null;
  }

  /// Ce que Clicky a remarqué (des phrases), sur les 4 dernières semaines.
  static List<String> insights(Map raw, Map<String, int> week, DateTime now) {
    final out = <String>[];
    final habits = find(raw, now);
    for (final h in habits.take(3)) {
      out.add('${h.say[0].toUpperCase()}${h.say.substring(1)}.');
    }
    // L'heure la plus active.
    final byHour = List<int>.filled(24, 0);
    final nights = <double>[];
    final today = DateTime(now.year, now.month, now.day);
    for (var k = 1; k <= 28; k++) {
      final d = today.subtract(Duration(days: k));
      for (var h = 0; h < 24; h++) {
        byHour[h] += _at(raw, d, h).values.fold<int>(0, (a, b) => a + b);
      }
      // Le soir : la dernière heure où tu étais sur le PC (après 18 h, ou
      // après minuit jusqu'à 4 h).
      double? last;
      for (var h = 18; h < 24; h++) {
        if (_at(raw, d, h).values.fold<int>(0, (a, b) => a + b) >= 120) last = h + 0.5;
      }
      final next = d.add(const Duration(days: 1));
      for (var h = 0; h < 5; h++) {
        if (_at(raw, next, h).values.fold<int>(0, (a, b) => a + b) >= 120) last = 24 + h + 0.5;
      }
      if (last != null) nights.add(last);
    }
    final total = byHour.fold<int>(0, (a, b) => a + b);
    if (total > 3600) {
      var best = 0;
      for (var h = 1; h < 24; h++) {
        if (byHour[h] > byHour[best]) best = h;
      }
      out.add('Ton heure la plus active sur le PC : $best h.');
    }
    if (nights.length >= 5) {
      final avg = nights.reduce((a, b) => a + b) / nights.length;
      final h = avg.floor() % 24, m = ((avg - avg.floor()) * 60).round();
      out.add('Le soir, tu quittes le PC vers ${h == 0 ? 'minuit' : '$h h'}${m >= 15 ? ' ${(m ~/ 15 * 15).toString().padLeft(2, '0')}' : ''} en moyenne.');
    }
    final top = ScreenTime.sorted(week).where((e) => e.key != 'Mon Hub').firstOrNull;
    if (top != null && top.value >= 3600) {
      out.add('Ton appli n° 1 cette semaine : ${top.key}, ${ScreenTime.say(top.value ~/ 7)} par jour en moyenne.');
    }
    return out;
  }

  /// Le coup de pouce avant une habitude (« d'habitude à 14 h c'est
  /// Roblox… »), s'il y a un contrôle ou un devoir demain. Null sinon.
  static String? nudge(Habit h, List<Map> homework, DateTime now) {
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    Map? due;
    for (final x in homework) {
      final d = x['pour_le'] is DateTime ? x['pour_le'] as DateTime : DateTime.tryParse('${x['pour_le']}');
      if (x['fait'] == true || d == null || d.year != tomorrow.year || d.month != tomorrow.month || d.day != tomorrow.day) continue;
      if (due == null || x['controle'] == true) due = x;
    }
    if (due == null) return null;
    final s = '${due['matiere'] ?? ''}'.trim();
    // « MATHEMATIQUES » → « Mathematiques », mais « SVT » reste « SVT ».
    final subject = s.length <= 4 || s != s.toUpperCase() ? s : s[0] + s.substring(1).toLowerCase();
    final what = due['controle'] == true ? 'un contrôle de $subject' : 'le devoir de $subject';
    return 'D\'habitude, le ${Habit.days[h.weekday - 1]} vers ${h.hour} h, c\'est ${h.app}. Mais t\'as $what demain : '
        '20 minutes de boulot avant, et tu joues l\'esprit tranquille ?';
  }
}
