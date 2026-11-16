import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';
import 'ics_parser.dart';

/// Agenda à partir d'un ou plusieurs liens iCal (.ics).
///
/// Google Agenda : Paramètres > [ton agenda] > Intégrer l'agenda >
/// « Adresse secrète au format iCal ». Pas besoin de compte développeur.
class ScheduleModule extends HubModule {
  List<CalEvent> _cache = [];
  Future<List<CalEvent>>? _loading;

  @override
  String get id => 'schedule';
  @override
  String get name => 'Agenda';
  @override
  String get description => 'Google Agenda (ou tout agenda iCal)';
  @override
  IconData get icon => Icons.event_note_outlined;
  @override
  Color get color => const Color(0xFF4285F4);
  @override
  ApiAccess get access => ApiAccess.official;

  List<String> get urls =>
      (store.getJson<List<dynamic>>('urls') ?? const []).cast<String>();

  Future<List<CalEvent>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      final now = DateTime.now();
      final from = DateTime(now.year, now.month, now.day);
      final to = from.add(const Duration(days: 14));
      final all = <CalEvent>[];
      for (final u in urls) {
        final res = await http.get(Uri.parse(u.replaceFirst('webcal://', 'https://')));
        all.addAll(parseIcs(res.body, from, to));
      }
      all.sort((a, b) => a.start.compareTo(b.start));
      return _cache = all;
    }();
  }

  Widget _eventTile(CalEvent e, {bool dense = false}) => ListTile(
        dense: dense,
        leading: SizedBox(
          width: 56,
          child: Text(e.allDay ? 'Journée' : hhmm(e.start),
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        title: Text(e.title),
        subtitle: dense
            ? null
            : Text([
                if (!e.allDay) '${hhmm(e.start)} – ${hhmm(e.end)}',
                if (e.location.isNotEmpty) e.location,
              ].join(' · ')),
      );

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (urls.isEmpty) {
            return const EmptyHint('Ajoute ton lien Google Agenda', icon: Icons.add_link);
          }
          return FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) {
              if (snap.hasError) return EmptyHint('${snap.error}');
              final now = DateTime.now();
              final upcoming = (snap.data ?? []).where((e) => e.end.isAfter(now)).take(5).toList();
              if (upcoming.isEmpty) return const EmptyHint('Rien de prévu');
              return ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final e in upcoming)
                    ListTile(
                      dense: true,
                      title: Text(e.title),
                      subtitle: Text('${dayLabel(e.start)}'
                          '${e.allDay ? '' : ' · ${hhmm(e.start)}'}'),
                    ),
                ],
              );
            },
          );
        },
      );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name), actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => load(force: true).then((_) => store.changed()),
          ),
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Agendas',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => _manage(context),
            ),
          ),
        ]),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) {
              if (urls.isEmpty) {
                return Center(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add_link),
                    label: const Text('Ajouter un agenda'),
                    onPressed: () => _manage(context),
                  ),
                );
              }
              final events = snap.data ?? [];
              final children = <Widget>[];
              String? lastDay;
              for (final e in events) {
                final d = dayLabel(e.start);
                if (d != lastDay) {
                  children.add(Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(d, style: Theme.of(context).textTheme.titleMedium),
                  ));
                  lastDay = d;
                }
                children.add(_eventTile(e));
              }
              if (snap.hasError) children.insert(0, EmptyHint('${snap.error}'));
              if (children.isEmpty) {
                children.add(const EmptyHint('Rien sur les 14 prochains jours'));
              }
              children.addAll([
                const Divider(height: 32),
                for (final u in urls)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.link),
                    title: Text(u, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await store.setJson(
                            'urls', urls.where((x) => x != u).toList());
                        await load(force: true);
                        store.changed();
                      },
                    ),
                  ),
              ]);
              return ListView(children: children);
            },
          ),
        ),
      );

  Future<void> _manage(BuildContext context) async {
    final r = await askFields(context,
        title: 'Ajouter un agenda',
        labels: ['Adresse secrète iCal (…/basic.ics)']);
    final u = r?.first ?? '';
    if (u.isEmpty) return;
    await store.setJson('urls', {...urls, u}.toList());
    await load(force: true);
    store.changed();
  }
}
