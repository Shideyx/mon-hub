/// Lecteur iCalendar (.ics) minimal : suffisant pour l'export « adresse
/// secrète au format iCal » de Google Agenda, Outlook, etc.
library;

class CalEvent {
  CalEvent(this.title, this.start, this.end, {this.location = ''});
  final String title;
  final DateTime start;
  final DateTime end;
  final String location;
  bool get allDay =>
      start.hour == 0 && start.minute == 0 && end.difference(start).inHours >= 24;
}

DateTime? _parseDate(String value, Map<String, String> params) {
  final v = value.trim();
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$')
      .firstMatch(v);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  if (m.group(4) == null) return DateTime(g(1), g(2), g(3));
  if (m.group(7) == 'Z') {
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
  }
  // TZID=… : on considère l'heure comme locale (suffisant si l'agenda est
  // dans le même fuseau que l'appareil).
  return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
}

const _byDay = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// Renvoie les évènements entre [from] et [to], récurrences comprises
/// (FREQ=DAILY/WEEKLY avec INTERVAL, COUNT, UNTIL, BYDAY, EXDATE).
List<CalEvent> parseIcs(String ics, DateTime from, DateTime to) {
  final lines = ics.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n[ \t]'), '').split('\n');
  final out = <CalEvent>[];
  Map<String, (String, Map<String, String>)>? ev;
  final exdates = <DateTime>[];

  for (final line in lines) {
    if (line == 'BEGIN:VEVENT') {
      ev = {};
      exdates.clear();
      continue;
    }
    if (line == 'END:VEVENT' && ev != null) {
      out.addAll(_expand(ev, exdates, from, to));
      ev = null;
      continue;
    }
    if (ev == null) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final head = line.substring(0, colon).split(';');
    final params = <String, String>{
      for (final p in head.skip(1))
        if (p.contains('=')) p.split('=')[0]: p.split('=')[1],
    };
    final value = line.substring(colon + 1);
    if (head[0] == 'EXDATE') {
      for (final d in value.split(',')) {
        final p = _parseDate(d, params);
        if (p != null) exdates.add(p);
      }
    } else {
      ev[head[0]] = (value, params);
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

String _unescape(String s) =>
    s.replaceAll(r'\n', ' ').replaceAll(r'\,', ',').replaceAll(r'\;', ';');

Iterable<CalEvent> _expand(Map<String, (String, Map<String, String>)> ev,
    List<DateTime> exdates, DateTime from, DateTime to) sync* {
  final s = ev['DTSTART'];
  if (s == null) return;
  final start = _parseDate(s.$1, s.$2);
  if (start == null) return;
  final e = ev['DTEND'];
  final end = (e == null ? null : _parseDate(e.$1, e.$2)) ??
      start.add(Duration(days: s.$1.contains('T') ? 0 : 1, hours: s.$1.contains('T') ? 1 : 0));
  final duration = end.difference(start);
  final title = _unescape(ev['SUMMARY']?.$1 ?? '(sans titre)');
  final location = _unescape(ev['LOCATION']?.$1 ?? '');
  CalEvent make(DateTime st) => CalEvent(title, st, st.add(duration), location: location);

  final rule = ev['RRULE']?.$1;
  if (rule == null) {
    if (end.isAfter(from) && start.isBefore(to)) yield make(start);
    return;
  }
  final r = {
    for (final part in rule.split(';'))
      if (part.contains('=')) part.split('=')[0]: part.split('=')[1],
  };
  final freq = r['FREQ'];
  if (freq != 'DAILY' && freq != 'WEEKLY') {
    if (end.isAfter(from) && start.isBefore(to)) yield make(start);
    return;
  }
  final interval = int.tryParse(r['INTERVAL'] ?? '') ?? 1;
  final count = int.tryParse(r['COUNT'] ?? '');
  final until = r['UNTIL'] == null ? null : _parseDate(r['UNTIL']!, const {});
  final days = (r['BYDAY']?.split(',') ?? [])
      .map((d) => _byDay[d.replaceAll(RegExp(r'[^A-Z]'), '')])
      .whereType<int>()
      .toSet();
  if (freq == 'WEEKLY' && days.isEmpty) days.add(start.weekday);

  var n = 0;
  var day = DateTime(start.year, start.month, start.day);
  final weekStart = day.subtract(Duration(days: day.weekday - 1));
  for (var i = 0; i < 3660; i++, day = DateTime(day.year, day.month, day.day + 1)) {
    if (day.isAfter(to)) return;
    bool matches;
    if (freq == 'DAILY') {
      matches = DateTime(day.year, day.month, day.day).difference(DateTime(start.year, start.month, start.day)).inDays % interval == 0;
    } else {
      final weeks = day.difference(weekStart).inDays ~/ 7;
      matches = weeks % interval == 0 && days.contains(day.weekday);
    }
    if (!matches) continue;
    final occ = DateTime(day.year, day.month, day.day, start.hour, start.minute, start.second);
    if (occ.isBefore(start)) continue;
    if (until != null && occ.isAfter(until)) return;
    n++;
    if (count != null && n > count) return;
    if (exdates.any((x) => x.isAtSameMomentAs(occ))) continue;
    if (occ.add(duration).isAfter(from) && occ.isBefore(to)) yield make(occ);
  }
}
