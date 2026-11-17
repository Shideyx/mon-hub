import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/google_auth.dart';
import '../../core/hub_module.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import '../ecoledirecte/ecoledirecte_module.dart';
import 'ics_parser.dart';

/// D'où vient un créneau de l'agenda.
enum AgendaSource {
  ecole('École Directe', Icons.school_rounded),
  google('Google Agenda', Icons.event_rounded),
  perso('Mes évènements', Icons.person_rounded);

  const AgendaSource(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Un créneau affiché dans l'agenda, quelle que soit sa source.
class AgendaItem {
  AgendaItem({
    required this.title,
    required this.start,
    required this.end,
    required this.source,
    required this.color,
    this.place = '',
    this.detail = '',
    this.cancelled = false,
    this.allDay = false,
    this.personal,
  });
  final String title;
  final DateTime start;
  final DateTime end;
  final AgendaSource source;
  final Color color;
  final String place;
  final String detail;
  final bool cancelled;
  final bool allDay;

  /// Évènement perso d'origine (modifiable).
  final PersonalEvent? personal;
}

/// Évènement ajouté dans Mon Hub (stocké sur l'appareil).
class PersonalEvent {
  PersonalEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.place = '',
    this.note = '',
    this.color = 0,
    this.weekly = false,
  });
  final String id;
  String title;
  DateTime start;
  DateTime end;
  String place;
  String note;
  int color;

  /// Se répète chaque semaine (sport, cours particulier…).
  bool weekly;

  /// À créer dans Google Agenda plutôt que dans Mon Hub (non enregistré).
  bool toGoogle = false;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'place': place,
    'note': note,
    'color': color,
    'weekly': weekly,
  };

  factory PersonalEvent.fromJson(Map<String, dynamic> j) => PersonalEvent(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    start: DateTime.parse(j['start'] as String),
    end: DateTime.parse(j['end'] as String),
    place: j['place'] as String? ?? '',
    note: j['note'] as String? ?? '',
    color: j['color'] as int? ?? 0,
    weekly: j['weekly'] == true,
  );

  /// Occurrences entre [from] et [to].
  Iterable<(DateTime, DateTime)> occurrences(DateTime from, DateTime to) sync* {
    if (!weekly) {
      if (end.isAfter(from) && start.isBefore(to)) yield (start, end);
      return;
    }
    final len = end.difference(start);
    var s = start;
    if (s.isBefore(from)) {
      final weeks = from.difference(s).inDays ~/ 7;
      s = DateTime(s.year, s.month, s.day + weeks * 7, s.hour, s.minute);
    }
    while (s.isBefore(to)) {
      final e = s.add(len);
      if (e.isAfter(from)) yield (s, e);
      s = DateTime(s.year, s.month, s.day + 7, s.hour, s.minute);
    }
  }
}

/// Couleurs proposées pour les évènements perso.
const personalColors = [
  Color(0xFF7E57C2),
  Color(0xFF26A69A),
  Color(0xFFEF6C00),
  Color(0xFFE53935),
  Color(0xFF43A047),
  Color(0xFF1E88E5),
  Color(0xFFD81B60),
  Color(0xFF6D4C41),
];

const _edPalette = [
  Color(0xFF1E88E5),
  Color(0xFF43A047),
  Color(0xFFF4511E),
  Color(0xFF8E24AA),
  Color(0xFF00897B),
  Color(0xFFC0CA33),
  Color(0xFF6D4C41),
  Color(0xFFD81B60),
  Color(0xFF3949AB),
  Color(0xFFFFB300),
];

Color _edColor(String? hex, String subject) {
  final h = (hex ?? '').replaceAll('#', '');
  if (h.length == 6) {
    final v = int.tryParse(h, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return _edPalette[subject.hashCode.abs() % _edPalette.length];
}

DateTime _monday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Agenda unique : cours École Directe + Google Agenda (lien iCal) + tes
/// propres évènements, présentés comme l'emploi du temps d'École Directe.
///
/// Google Agenda : Paramètres > [ton agenda] > Intégrer l'agenda >
/// « Adresse secrète au format iCal ». Pas besoin de compte développeur.
class ScheduleModule extends HubModule {
  ScheduleModule({this.ecole});

  /// Module École Directe dont on reprend les cours (facultatif).
  final EcoleDirecteModule? ecole;

  @override
  String get id => 'schedule';
  @override
  String get name => 'Agenda';
  @override
  String get description => 'Cours École Directe, Google Agenda et tes évènements';
  @override
  IconData get icon => Icons.calendar_month_rounded;
  @override
  Color get color => const Color(0xFF4285F4);
  @override
  ApiAccess get access => ApiAccess.official;

  List<String> get urls => (store.getJson<List<dynamic>>('urls') ?? const []).cast<String>();

  List<PersonalEvent> get personal => [
    for (final e in store.getJson<List<dynamic>>('events') ?? const [])
      PersonalEvent.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  Set<AgendaSource> get hidden => {
    for (final n in store.getJson<List<dynamic>>('hidden') ?? const [])
      ...AgendaSource.values.where((s) => s.name == n),
  };

  Future<void> toggleSource(AgendaSource s) async {
    final h = hidden;
    h.contains(s) ? h.remove(s) : h.add(s);
    await store.setJson('hidden', [for (final x in h) x.name]);
    store.changed();
  }

  Future<void> savePersonal(PersonalEvent e) async {
    final list = personal.where((x) => x.id != e.id).toList()..add(e);
    await store.setJson('events', [for (final x in list) x.toJson()]);
    store.changed();
  }

  Future<void> deletePersonal(String id) async {
    await store.setJson('events', [
      for (final x in personal)
        if (x.id != id) x.toJson(),
    ]);
    store.changed();
  }

  // ---- Google (connexion officielle) ------------------------------------

  final Map<String, (DateTime, List<AgendaItem>)> _gCache = {};
  String? googleError;

  Future<List<AgendaItem>> _googleBetween(DateTime from, DateTime to) async {
    final key = '${from.toIso8601String()}|${to.toIso8601String()}';
    final c = _gCache[key];
    if (c != null && DateTime.now().difference(c.$1).inMinutes < 5) return c.$2;
    googleError = null;
    final out = <AgendaItem>[];
    const base = 'https://www.googleapis.com/calendar/v3';
    for (final email in GoogleAuth.accounts) {
      try {
        final cals = await GoogleAuth.api(email, 'GET', '$base/users/me/calendarList');
        for (final cal in (cals['items'] as List? ?? [])) {
          if (cal['selected'] == false || cal['hidden'] == true) continue;
          final hex = '${cal['backgroundColor'] ?? '#4285F4'}'.replaceAll('#', '');
          final color = Color(0xFF000000 | (int.tryParse(hex, radix: 16) ?? 0x4285F4));
          final q = Uri(queryParameters: {
            'timeMin': from.toUtc().toIso8601String(),
            'timeMax': to.toUtc().toIso8601String(),
            'singleEvents': 'true',
            'orderBy': 'startTime',
            'maxResults': '250',
          }).query;
          final ev = await GoogleAuth.api(email, 'GET',
              '$base/calendars/${Uri.encodeComponent(cal['id'] as String)}/events?$q');
          for (final e in (ev['items'] as List? ?? [])) {
            if (e['status'] == 'cancelled') continue;
            final s = e['start'] as Map? ?? {};
            final en = e['end'] as Map? ?? {};
            final allDay = s['date'] != null;
            final start = DateTime.tryParse('${s['dateTime'] ?? s['date']}')?.toLocal();
            final end = DateTime.tryParse('${en['dateTime'] ?? en['date']}')?.toLocal();
            if (start == null || end == null) continue;
            out.add(AgendaItem(
              title: e['summary'] as String? ?? '(sans titre)',
              start: start,
              end: end,
              source: AgendaSource.google,
              color: color,
              place: e['location'] as String? ?? '',
              detail: cal['summary'] as String? ?? '',
              allDay: allDay,
            ));
          }
        }
      } catch (e) {
        googleError = '$e';
      }
    }
    _gCache[key] = (DateTime.now(), out);
    return out;
  }

  /// Crée l'évènement dans l'agenda principal Google.
  Future<void> addToGoogle(PersonalEvent e) async {
    final email = GoogleAuth.accounts.first;
    String t(DateTime d) => d.toIso8601String().substring(0, 19);
    await GoogleAuth.api(email, 'POST',
        'https://www.googleapis.com/calendar/v3/calendars/primary/events',
        body: {
          'summary': e.title,
          if (e.place.isNotEmpty) 'location': e.place,
          if (e.note.isNotEmpty) 'description': e.note,
          'start': {'dateTime': t(e.start), 'timeZone': _tz},
          'end': {'dateTime': t(e.end), 'timeZone': _tz},
          if (e.weekly) 'recurrence': ['RRULE:FREQ=WEEKLY'],
        });
    _gCache.clear();
    store.changed();
  }

  static String get _tz => 'Europe/Paris';

  Future<void> connectGoogle(BuildContext context) async {
    try {
      await GoogleAuth.signIn();
      _gCache.clear();
      store.changed();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  // ---- Google / iCal -----------------------------------------------------

  List<String> _icsTexts = [];
  Future<void>? _icsLoading;
  DateTime? _icsAt;
  String? icsError;

  Future<void> _loadIcs({bool force = false}) {
    if (_icsLoading != null && !force) return _icsLoading!;
    return _icsLoading = () async {
      icsError = null;
      final out = <String>[];
      for (final u in urls) {
        try {
          final res = await http
              .get(Uri.parse(u.trim().replaceFirst('webcal://', 'https://')))
              .timeout(const Duration(seconds: 25));
          if (res.statusCode >= 400 || !res.body.contains('BEGIN:VCALENDAR')) {
            icsError =
                'Lien Google Agenda refusé (code ${res.statusCode}) : '
                'vérifie que c\'est bien l\'« adresse secrète au format iCal »';
            continue;
          }
          out.add(res.body);
        } catch (e) {
          icsError = 'Google Agenda injoignable : $e';
        }
      }
      _icsTexts = out;
      _icsAt = DateTime.now();
    }();
  }

  /// Tous les créneaux entre [from] et [to].
  Future<List<AgendaItem>> itemsBetween(DateTime from, DateTime to) async {
    final hide = hidden;
    final out = <AgendaItem>[];
    if (!hide.contains(AgendaSource.ecole) && ecole != null && ecole!.configured) {
      for (final l in await ecole!.lessonsBetween(from, to)) {
        if (!l.end.isAfter(from) || !l.start.isBefore(to)) continue;
        out.add(
          AgendaItem(
            title: l.subject,
            start: l.start,
            end: l.end,
            source: AgendaSource.ecole,
            color: _edColor(l.color, l.subject),
            place: l.room,
            detail: l.teacher,
            cancelled: l.cancelled,
          ),
        );
      }
    }
    if (!hide.contains(AgendaSource.google) && GoogleAuth.accounts.isNotEmpty) {
      out.addAll(await _googleBetween(from, to));
    }
    if (!hide.contains(AgendaSource.google) && urls.isNotEmpty) {
      await _loadIcs();
      for (final t in _icsTexts) {
        for (final e in parseIcs(t, from, to)) {
          out.add(
            AgendaItem(
              title: e.title,
              start: e.start,
              end: e.end,
              source: AgendaSource.google,
              color: const Color(0xFF4285F4),
              place: e.location,
              allDay: e.allDay,
            ),
          );
        }
      }
    }
    if (!hide.contains(AgendaSource.perso)) {
      for (final p in personal) {
        for (final (s, e) in p.occurrences(from, to)) {
          out.add(
            AgendaItem(
              title: p.title,
              start: s,
              end: e,
              source: AgendaSource.perso,
              color: personalColors[p.color % personalColors.length],
              place: p.place,
              detail: p.note,
              personal: p,
            ),
          );
        }
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<List<AgendaItem>> upcoming() async {
    final now = DateTime.now();
    return _upcoming = await itemsBetween(now, now.add(const Duration(days: 14)));
  }

  /// Le dernier résultat (affiché tout de suite pendant qu'on relit).
  List<AgendaItem>? _upcoming;

  /// Rappel 15 minutes avant chaque évènement (hors cours, déjà signalés par
  /// École Directe s'ils sont annulés).
  @override
  Future<List<HubNotification>> poll() async {
    final now = DateTime.now();
    final stale = _icsAt == null || now.difference(_icsAt!).inMinutes >= 10;
    if (urls.isNotEmpty && stale) await _loadIcs(force: true);
    final items = await itemsBetween(now, now.add(const Duration(minutes: 16)));
    store.changed();
    return [
      for (final e in items)
        if (!e.allDay && !e.cancelled && e.start.isAfter(now))
          HubNotification(
            id: 'agenda:${e.title}@${e.start.toIso8601String()}',
            title: '⏰ ${e.title} à ${hhmm(e.start)}',
            body: e.place.isEmpty ? 'Dans ${e.start.difference(now).inMinutes} min' : e.place,
          ),
    ];
  }

  @override
  List<HubTool> get tools => [
        HubTool(
          name: 'agenda_lire',
          description: 'Liste les cours (École Directe), évènements Google Agenda et '
              'évènements perso, entre deux dates.',
          params: {
            'debut': ('string', 'Date de début AAAA-MM-JJ (défaut : aujourd\'hui)'),
            'jours': ('integer', 'Nombre de jours (défaut 7)'),
          },
          run: (a) async {
            final now = DateTime.now();
            final from = DateTime.tryParse('${a['debut'] ?? ''}') ??
                DateTime(now.year, now.month, now.day);
            final days = (a['jours'] as num?)?.toInt() ?? 7;
            final items = await itemsBetween(from, from.add(Duration(days: days)));
            return [
              for (final e in items)
                {
                  'titre': e.title,
                  'debut': e.start,
                  'fin': e.end,
                  'source': e.source.label,
                  if (e.place.isNotEmpty) 'lieu': e.place,
                  if (e.detail.isNotEmpty) 'detail': e.detail,
                  if (e.cancelled) 'annule': true,
                  if (e.personal != null) 'id': e.personal!.id,
                },
            ];
          },
        ),
        HubTool(
          name: 'agenda_ajouter',
          description: 'Ajoute un évènement perso dans l\'agenda de Mon Hub.',
          params: {
            'titre': ('string', 'Titre'),
            'debut': ('string', 'Date et heure de début, ex. 2026-11-20T17:00'),
            'fin': ('string', 'Date et heure de fin (défaut : 1 h après)'),
            'lieu': ('string', 'Lieu (facultatif)'),
            'note': ('string', 'Note (facultatif)'),
            'chaque_semaine': ('boolean', 'Répéter chaque semaine'),
          },
          required: ['titre', 'debut'],
          run: (a) async {
            final start = DateTime.parse(a['debut'] as String);
            final end = DateTime.tryParse('${a['fin'] ?? ''}') ?? start.add(const Duration(hours: 1));
            final e = PersonalEvent(
              id: '${DateTime.now().microsecondsSinceEpoch}',
              title: a['titre'] as String,
              start: start,
              end: end.isAfter(start) ? end : start.add(const Duration(hours: 1)),
              place: a['lieu'] as String? ?? '',
              note: a['note'] as String? ?? '',
              weekly: a['chaque_semaine'] == true,
            );
            await savePersonal(e);
            return {'ok': true, 'id': e.id};
          },
        ),
        HubTool(
          name: 'agenda_creneaux_libres',
          description: 'Secrétaire : les créneaux libres (sans cours ni évènement) jour par jour, '
              'pour placer des révisions, devoirs, sport, rendez-vous…',
          params: {
            'debut': ('string', 'Date de début AAAA-MM-JJ (défaut : aujourd\'hui)'),
            'jours': ('integer', 'Nombre de jours (défaut 7)'),
            'de': ('integer', 'Heure de début de journée (défaut 8)'),
            'a': ('integer', 'Heure de fin de journée (défaut 21)'),
            'minimum': ('integer', 'Durée minimale d\'un créneau en minutes (défaut 30)'),
          },
          run: (a) async {
            final now = DateTime.now();
            final from = DateTime.tryParse('${a['debut'] ?? ''}') ?? DateTime(now.year, now.month, now.day);
            final days = ((a['jours'] as num?)?.toInt() ?? 7).clamp(1, 31);
            final items = await itemsBetween(from, from.add(Duration(days: days)));
            return freeSlots(
              items.where((e) => !e.cancelled).map((e) => (e.start, e.end)).toList(),
              from: from,
              days: days,
              dayStart: ((a['de'] as num?)?.toInt() ?? 8).clamp(0, 23),
              dayEnd: ((a['a'] as num?)?.toInt() ?? 21).clamp(1, 24),
              minimum: Duration(minutes: ((a['minimum'] as num?)?.toInt() ?? 30).clamp(10, 600)),
              notBefore: now,
            );
          },
        ),
        HubTool(
          name: 'agenda_ajouter_plan',
          description: 'Secrétaire : enregistre tout un emploi du temps d\'un coup (révisions, devoirs, '
              'activités…) dans l\'agenda de Mon Hub. Propose d\'abord le planning à la personne.',
          params: {
            'plan': (
              'string',
              'Liste JSON d\'évènements : [{"titre":"Révision maths","debut":"2026-11-20T17:00",'
                  '"fin":"2026-11-20T18:00","lieu":"","note":"","chaque_semaine":false}]',
            ),
          },
          required: ['plan'],
          run: (a) async {
            final raw = a['plan'];
            final list = raw is List ? raw : jsonDecode('$raw') as List;
            final ids = <String>[];
            var n = 0;
            for (final x in list) {
              if (x is! Map) continue;
              final start = DateTime.tryParse('${x['debut'] ?? ''}');
              if (start == null || '${x['titre'] ?? ''}'.trim().isEmpty) continue;
              final end = DateTime.tryParse('${x['fin'] ?? ''}') ?? start.add(const Duration(hours: 1));
              final e = PersonalEvent(
                id: '${DateTime.now().microsecondsSinceEpoch}${n++}',
                title: '${x['titre']}'.trim(),
                start: start,
                end: end.isAfter(start) ? end : start.add(const Duration(hours: 1)),
                place: '${x['lieu'] ?? ''}',
                note: '${x['note'] ?? ''}',
                weekly: x['chaque_semaine'] == true,
              );
              await savePersonal(e);
              ids.add(e.id);
            }
            return {'ajoutes': ids.length, 'ids': ids};
          },
        ),
        HubTool(
          name: 'agenda_supprimer',
          description: 'Supprime un évènement perso (id donné par agenda_lire).',
          params: {'id': ('string', 'Identifiant de l\'évènement')},
          required: ['id'],
          run: (a) async {
            await deletePersonal(a['id'] as String);
            return {'ok': true};
          },
        ),
      ];

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, if (ecole != null) ecole!.store]),
    builder: (context, _) => FutureBuilder(
      future: upcoming(),
      initialData: _upcoming,
      builder: (context, snap) {
        final items = (snap.data ?? []).where((e) => !e.cancelled).take(7).toList();
        if (snap.connectionState == ConnectionState.waiting && items.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          return const EmptyHint(
            'Rien de prévu. Touche pour ajouter un évènement',
            icon: Icons.add_rounded,
          );
        }
        return NextUpSummary(
          items: [
            for (final e in items)
              NextItem(
                title: e.title,
                start: e.start,
                end: e.end,
                color: e.color,
                place: e.place,
                allDay: e.allDay,
              ),
          ],
        );
      },
    ),
  );

  @override
  Widget buildPage(BuildContext context) => AgendaPage(module: this);

  Future<void> manageGoogle(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => ListenableBuilder(
        listenable: store,
        builder: (c, _) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('Agendas Google', style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (GoogleAuth.available) ...[
              for (final a in GoogleAuth.accounts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_rounded),
                  title: Text(a),
                  subtitle: const Text('Connecté avec Google : lecture et ajout'),
                  trailing: IconButton(
                    tooltip: 'Déconnecter',
                    icon: const Icon(Icons.logout_rounded),
                    onPressed: () async {
                      await GoogleAuth.signOut(a);
                      _gCache.clear();
                      store.changed();
                    },
                  ),
                ),
              FilledButton.icon(
                icon: const Icon(Icons.login_rounded),
                label: const Text('Se connecter avec Google'),
                onPressed: () => connectGoogle(c),
              ),
              const SizedBox(height: 16),
              const Text('Ou bien, sans connexion, un lien iCal (lecture seule) :'),
              const SizedBox(height: 8),
            ],
            const Text(
              'Sur un ordinateur : Google Agenda → ⚙️ Paramètres → ton agenda → '
              '« Intégrer l\'agenda » → copie l\'« Adresse secrète au format iCal ».',
            ),
            const SizedBox(height: 8),
            for (final u in urls)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded),
                title: Text(u, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Retirer',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    await store.setJson('urls', urls.where((x) => x != u).toList());
                    _icsAt = null;
                    await _loadIcs(force: true);
                    store.changed();
                  },
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('Ajouter un lien'),
                  onPressed: () async {
                    final r = await askFields(
                      c,
                      title: 'Ajouter Google Agenda',
                      labels: ['Adresse secrète iCal (…/basic.ics)'],
                    );
                    final u = r?.first.trim() ?? '';
                    if (u.isEmpty) return;
                    await store.setJson('urls', {...urls, u}.toList());
                    _icsAt = null;
                    await _loadIcs(force: true);
                    store.changed();
                  },
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => openLink(c, 'https://calendar.google.com/calendar/r/settings'),
                  child: const Text('Ouvrir Google Agenda'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Page Agenda (présentation façon École Directe) -------------------------

class AgendaPage extends StatefulWidget {
  const AgendaPage({super.key, required this.module});
  final ScheduleModule module;

  @override
  State<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends State<AgendaPage> {
  late DateTime _day = () {
    final n = DateTime.now();
    final d = DateTime(n.year, n.month, n.day);
    // Le week-end, on montre directement lundi.
    return d.weekday >= 6 ? d.add(Duration(days: 8 - d.weekday)) : d;
  }();
  ScheduleModule get m => widget.module;

  DateTime get _week => _monday(_day);

  void _shift(int days) => setState(() => _day = _day.add(Duration(days: days)));

  Future<void> _refresh() async {
    m._icsAt = null;
    m._gCache.clear();
    await Future.wait([m._loadIcs(force: true), if (m.ecole != null) m.ecole!.load(force: true, manual: true)]);
    m.store.changed();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final week = _week;
    final sameMonth = week.month == week.add(const Duration(days: 6)).month;
    final title = wide
        ? 'Semaine du ${week.day}${sameMonth ? '' : ' ${frMonths[week.month - 1]}'} '
              'au ${week.add(const Duration(days: 6)).day} '
              '${frMonths[week.add(const Duration(days: 6)).month - 1]}'
        : '${frMonths[_day.month - 1][0].toUpperCase()}${frMonths[_day.month - 1].substring(1)} '
              '${_day.year}';
    return Scaffold(
      appBar: AppBar(
        title: Text(m.name),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'Google Agenda',
            icon: const Icon(Icons.add_link_rounded),
            onPressed: () => m.manageGoogle(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editPersonalEvent(context, m, day: _day),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Ajouter'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([m.store, if (m.ecole != null) m.ecole!.store]),
        builder: (context, _) {
          final hide = m.hidden;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Précédent',
                      icon: const Icon(Icons.chevron_left_rounded),
                      onPressed: () => _shift(-7),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        final n = DateTime.now();
                        _day = DateTime(n.year, n.month, n.day);
                      }),
                      child: const Text("Aujourd'hui"),
                    ),
                    IconButton(
                      tooltip: 'Suivant',
                      icon: const Icon(Icons.chevron_right_rounded),
                      onPressed: () => _shift(7),
                    ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final s in AgendaSource.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          avatar: Icon(s.icon, size: 16),
                          label: Text(s.label),
                          selected: !hide.contains(s),
                          showCheckmark: false,
                          onSelected: (_) => m.toggleSource(s),
                        ),
                      ),
                  ],
                ),
              ),
              if (!wide)
                _DayStrip(week: week, selected: _day, onPick: (d) => setState(() => _day = d)),
              const SizedBox(height: 4),
              Expanded(
                child: FutureBuilder(
                  future: m.itemsBetween(week, week.add(const Duration(days: 7))),
                  builder: (context, snap) {
                    final items = snap.data ?? const <AgendaItem>[];
                    final errors = [
                      if (m.ecole?.lastError case final e? when !hide.contains(AgendaSource.ecole))
                        'École Directe : $e',
                      if (m.icsError case final e? when !hide.contains(AgendaSource.google)) e,
                      if (m.googleError case final e? when !hide.contains(AgendaSource.google))
                        e,
                    ];
                    final days = wide
                        ? [for (var i = 0; i < 7; i++) week.add(Duration(days: i))]
                              .where(
                                (d) => d.weekday <= 5 || items.any((e) => _sameDay(e.start, d)),
                              )
                              .toList()
                        : [_day];
                    return Column(
                      children: [
                        for (final e in errors) ErrorBanner(e),
                        if (snap.connectionState == ConnectionState.waiting)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: _Timeline(
                            days: days,
                            items: items,
                            showHeaders: wide,
                            onTap: (e) => _details(context, e),
                            onEmptyTap: (start) =>
                                editPersonalEvent(context, m, day: start, startTime: start),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _details(BuildContext context, AgendaItem e) {
    if (e.personal != null) {
      editPersonalEvent(context, m, existing: e.personal);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 28,
                  decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    e.title,
                    style: Theme.of(c).textTheme.titleLarge
                        ?.copyWith(decoration: e.cancelled ? TextDecoration.lineThrough : null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (e.cancelled)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Chip(label: Text('Cours annulé')),
              ),
            _line(
              Icons.schedule_rounded,
              '${dayLabel(e.start)}${e.allDay ? ' (journée)' : ' · ${hhmm(e.start)} – ${hhmm(e.end)}'}',
            ),
            if (e.place.isNotEmpty) _line(Icons.place_outlined, e.place),
            if (e.detail.isNotEmpty) _line(Icons.person_outline_rounded, e.detail),
            _line(e.source.icon, e.source.label),
          ],
        ),
      ),
    );
  }

  Widget _line(IconData i, String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(i, size: 18),
        const SizedBox(width: 12),
        Expanded(child: Text(t)),
      ],
    ),
  );
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.week, required this.selected, required this.onPick});
  final DateTime week;
  final DateTime selected;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final today = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Builder(
                builder: (context) {
                  final d = week.add(Duration(days: i));
                  final sel = _sameDay(d, selected);
                  final isToday = _sameDay(d, today);
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onPick(d),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: sel ? cs.primary : null,
                        borderRadius: BorderRadius.circular(14),
                        border: isToday && !sel ? Border.all(color: cs.primary) : null,
                      ),
                      child: Column(
                        children: [
                          Text(
                            frDays[i].substring(0, 3),
                            style: TextStyle(
                              fontSize: 12,
                              color: sel ? cs.onPrimary : cs.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '${d.day}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: sel ? cs.onPrimary : cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Grille horaire avec des blocs colorés, comme l'emploi du temps d'École
/// Directe. Une colonne par jour.
class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.days,
    required this.items,
    required this.showHeaders,
    required this.onTap,
    required this.onEmptyTap,
  });
  final List<DateTime> days;
  final List<AgendaItem> items;
  final bool showHeaders;
  final ValueChanged<AgendaItem> onTap;
  final ValueChanged<DateTime> onEmptyTap;

  static const _hourH = 64.0;
  static const _gutter = 48.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final timed = items.where((e) => !e.allDay).toList();
    final allDay = items.where((e) => e.allDay).toList();
    var first = 8, last = 18;
    for (final e in timed) {
      if (!days.any((d) => _sameDay(d, e.start))) continue;
      first = math.min(first, e.start.hour);
      last = math.max(last, e.end.hour + (e.end.minute > 0 ? 1 : 0));
    }
    first = math.max(0, first);
    last = math.min(24, math.max(last, first + 1));
    final height = (last - first) * _hourH;
    final now = DateTime.now();

    return Column(
      children: [
        if (showHeaders)
          Padding(
            padding: const EdgeInsets.only(left: _gutter),
            child: Row(
              children: [
                for (final d in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${frDays[d.weekday - 1].substring(0, 3)}. ${d.day}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _sameDay(d, now) ? cs.primary : cs.onSurface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (days.any((d) => allDay.any((e) => _coversDay(e, d))))
          Padding(
            padding: const EdgeInsets.only(left: _gutter, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in days)
                  Expanded(
                    child: Column(
                      children: [
                        for (final e in allDay.where((e) => _coversDay(e, d)))
                          _Block(item: e, compact: true, onTap: () => onTap(e)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 10, bottom: 96),
            child: SizedBox(
              height: height + 8,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _gutter,
                    height: height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var h = first; h <= last; h++)
                          Positioned(
                            top: (h - first) * _hourH - 7,
                            right: 8,
                            child: Text(
                              '${two(h)}h',
                              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                  for (final d in days)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final dayItems = timed.where((e) => _sameDay(e.start, d)).toList();
                          final cols = _columns(dayItems);
                          return GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapUp: (t) {
                              final hour = first + t.localPosition.dy / _hourH;
                              final h = hour.floor();
                              final min = ((hour - h) * 60 / 30).floor() * 30;
                              onEmptyTap(DateTime(d.year, d.month, d.day, h, min));
                            },
                            child: Container(
                              height: height,
                              decoration: BoxDecoration(
                                border: Border(left: BorderSide(color: cs.outlineVariant)),
                                color: _sameDay(d, now)
                                    ? cs.primaryContainer.withValues(alpha: 0.18)
                                    : null,
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  for (var h = first; h <= last; h++)
                                    Positioned(
                                      top: (h - first) * _hourH,
                                      left: 0,
                                      right: 0,
                                      child: Divider(height: 1, color: cs.outlineVariant),
                                    ),
                                  for (final e in dayItems)
                                    Positioned(
                                      top: _y(e.start, first),
                                      height: math.max(22, _y(e.end, first) - _y(e.start, first)),
                                      left: box.maxWidth * cols[e]!.$1 / cols[e]!.$2 + 2,
                                      width: box.maxWidth / cols[e]!.$2 - 4,
                                      child: _Block(item: e, onTap: () => onTap(e)),
                                    ),
                                  if (_sameDay(d, now) && now.hour >= first && now.hour < last)
                                    Positioned(
                                      top: _y(now, first),
                                      left: 0,
                                      right: 0,
                                      child: Container(height: 2, color: cs.error),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static bool _coversDay(AgendaItem e, DateTime d) =>
      !e.start.isAfter(DateTime(d.year, d.month, d.day, 23, 59)) &&
      e.end.isAfter(DateTime(d.year, d.month, d.day));

  static double _y(DateTime t, int first) => (t.hour - first + t.minute / 60) * _hourH;

  /// Place les créneaux qui se chevauchent côte à côte : (colonne, nb colonnes).
  static Map<AgendaItem, (int, int)> _columns(List<AgendaItem> list) {
    final out = <AgendaItem, (int, int)>{};
    final sorted = [...list]..sort((a, b) => a.start.compareTo(b.start));
    var group = <AgendaItem>[];
    var colEnds = <DateTime>[];
    var groupEnd = DateTime(0);
    final colOf = <AgendaItem, int>{};
    void flush() {
      for (final g in group) {
        out[g] = (colOf[g]!, colEnds.length);
      }
      group = [];
      colEnds = [];
    }

    for (final e in sorted) {
      if (group.isNotEmpty && !e.start.isBefore(groupEnd)) flush();
      var c = colEnds.indexWhere((end) => !e.start.isBefore(end));
      if (c == -1) {
        colEnds.add(e.end);
        c = colEnds.length - 1;
      } else {
        colEnds[c] = e.end;
      }
      colOf[e] = c;
      group.add(e);
      if (group.length == 1 || e.end.isAfter(groupEnd)) groupEnd = e.end;
    }
    flush();
    return out;
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.item, required this.onTap, this.compact = false});
  final AgendaItem item;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final e = item;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = Color.alphaBlend(
      e.color.withValues(alpha: dark ? 0.32 : 0.16),
      Theme.of(context).colorScheme.surface,
    );
    final strike = e.cancelled ? TextDecoration.lineThrough : null;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: compact ? const EdgeInsets.symmetric(horizontal: 2, vertical: 1) : null,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: e.color, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(6, 3, 4, 3),
          child: LayoutBuilder(
            builder: (context, box) {
              final roomy = box.maxHeight > 44 || compact;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (e.source == AgendaSource.perso)
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Icon(Icons.person_rounded, size: 12, color: e.color),
                        ),
                      Expanded(
                        child: Text(
                          e.cancelled ? 'ANNULÉ · ${e.title}' : e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            decoration: strike,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (roomy && !compact)
                    Flexible(
                      child: Text(
                        [
                          '${hhmm(e.start)}–${hhmm(e.end)}',
                          if (e.place.isNotEmpty) e.place,
                          if (e.detail.isNotEmpty && e.source == AgendaSource.ecole) e.detail,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---- Ajout / modification d'un évènement perso ------------------------------

Future<void> editPersonalEvent(
  BuildContext context,
  ScheduleModule m, {
  PersonalEvent? existing,
  DateTime? day,
  DateTime? startTime,
}) async {
  final now = DateTime.now();
  final baseDay = day ?? DateTime(now.year, now.month, now.day);
  final s0 =
      existing?.start ??
      startTime ??
      DateTime(baseDay.year, baseDay.month, baseDay.day, math.max(8, math.min(now.hour + 1, 20)));
  final e = PersonalEvent(
    id: existing?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
    title: existing?.title ?? '',
    start: s0,
    end: existing?.end ?? s0.add(const Duration(hours: 1)),
    place: existing?.place ?? '',
    note: existing?.note ?? '',
    color: existing?.color ?? 0,
    weekly: existing?.weekly ?? false,
  );
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _EventEditor(event: e, isNew: existing == null, module: m),
  );
  if (saved != true) return;
  if (e.toGoogle) {
    try {
      await m.addToGoogle(e);
    } catch (err) {
      if (context.mounted) showError(context, err);
    }
  } else {
    await m.savePersonal(e);
  }
}

class _EventEditor extends StatefulWidget {
  const _EventEditor({required this.event, required this.isNew, required this.module});
  final PersonalEvent event;
  final bool isNew;
  final ScheduleModule module;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  PersonalEvent get e => widget.event;
  late final _title = TextEditingController(text: e.title);
  late final _place = TextEditingController(text: e.place);
  late final _note = TextEditingController(text: e.note);

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: e.start,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    final len = e.end.difference(e.start);
    setState(() {
      e.start = DateTime(d.year, d.month, d.day, e.start.hour, e.start.minute);
      e.end = e.start.add(len);
    });
  }

  Future<void> _pickTime(bool start) async {
    final cur = start ? e.start : e.end;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
      builder: (c, child) =>
          MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t == null) return;
    setState(() {
      if (start) {
        final len = e.end.difference(e.start);
        e.start = DateTime(e.start.year, e.start.month, e.start.day, t.hour, t.minute);
        e.end = e.start.add(len);
      } else {
        e.end = DateTime(e.start.year, e.start.month, e.start.day, t.hour, t.minute);
        if (!e.end.isAfter(e.start)) e.end = e.start.add(const Duration(minutes: 30));
      }
    });
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Donne un titre à l\'évènement')));
      return;
    }
    e
      ..title = _title.text.trim()
      ..place = _place.text.trim()
      ..note = _note.text.trim();
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isNew ? 'Nouvel évènement' : 'Modifier l\'évènement',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: widget.isNew,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Titre',
                hintText: 'Ex. Entraînement de foot, révisions…',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.today_rounded, size: 18),
                  label: Text(dayLabel(e.start)),
                  onPressed: _pickDay,
                ),
                ActionChip(
                  avatar: const Icon(Icons.schedule_rounded, size: 18),
                  label: Text('De ${hhmm(e.start)}'),
                  onPressed: () => _pickTime(true),
                ),
                ActionChip(label: Text('à ${hhmm(e.end)}'), onPressed: () => _pickTime(false)),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Toutes les semaines (le ${frDays[e.start.weekday - 1]})'),
              value: e.weekly,
              onChanged: (v) => setState(() => e.weekly = v),
            ),
            if (widget.isNew && GoogleAuth.accounts.isNotEmpty)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ajouter dans Google Agenda'),
                subtitle: const Text('Visible aussi sur ton téléphone et sur Google'),
                value: e.toGoogle,
                onChanged: (v) => setState(() => e.toGoogle = v),
              ),
            TextField(
              controller: _place,
              decoration: const InputDecoration(
                labelText: 'Lieu (facultatif)',
                prefixIcon: Icon(Icons.place_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Note (facultatif)',
                prefixIcon: Icon(Icons.notes_rounded),
              ),
            ),
            const SizedBox(height: 16),
            Text('Couleur', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < personalColors.length; i++)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => e.color = i),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: personalColors[i],
                      child: e.color == i
                          ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (!widget.isNew)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: cs.error),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Supprimer'),
                    onPressed: () async {
                      await widget.module.deletePersonal(e.id);
                      if (context.mounted) Navigator.pop(context, false);
                    },
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Enregistrer')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


/// Créneaux libres jour par jour entre [dayStart] h et [dayEnd] h, en
/// retirant les moments occupés [busy] (cours, évènements).
List<Map<String, Object>> freeSlots(
  List<(DateTime, DateTime)> busy, {
  required DateTime from,
  required int days,
  int dayStart = 8,
  int dayEnd = 21,
  Duration minimum = const Duration(minutes: 30),
  DateTime? notBefore,
}) {
  String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final out = <Map<String, Object>>[];
  for (var i = 0; i < days; i++) {
    final day = DateTime(from.year, from.month, from.day + i);
    var cursor = day.add(Duration(hours: dayStart));
    final end = day.add(Duration(hours: dayEnd));
    if (notBefore != null && notBefore.isAfter(cursor)) cursor = notBefore;
    final today = [
      for (final (a, b) in busy)
        if (b.isAfter(cursor) && a.isBefore(end)) (a, b),
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    final slots = <String>[];
    for (final (a, b) in today) {
      if (a.difference(cursor) >= minimum) slots.add('${hm(cursor)}-${hm(a)}');
      if (b.isAfter(cursor)) cursor = b;
    }
    if (end.difference(cursor) >= minimum) slots.add('${hm(cursor)}-${hm(end)}');
    out.add({'jour': day.toIso8601String().substring(0, 10), 'libre': slots});
  }
  return out;
}
