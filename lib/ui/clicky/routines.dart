import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/hub_files.dart';
import '../widgets.dart';

/// Un résultat de routine.
class RoutineRun {
  RoutineRun(this.at, this.text, this.ok);
  final DateTime at;
  final String text;
  final bool ok;

  Map<String, dynamic> toJson() => {'at': at.millisecondsSinceEpoch, 't': text, 'ok': ok};
  factory RoutineRun.fromJson(Map j) => RoutineRun(
    DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
    '${j['t'] ?? ''}',
    j['ok'] != false,
  );
}

/// Une tâche que Clicky fait tout seul, régulièrement (« briefing du matin
/// à 7 h 15 », « devoirs pour demain à 18 h »…), avec tes modules.
class Routine {
  Routine({
    required this.id,
    required this.name,
    required this.prompt,
    this.every = 'daily',
    this.hour = 7,
    this.minute = 15,
    this.weekday = 1,
    this.enabled = true,
    this.speak = true,
    this.lastRun,
    List<RoutineRun>? runs,
  }) : runs = runs ?? [];

  final String id;
  String name;
  String prompt;

  /// '15min', 'hourly', 'daily', 'weekdays', 'weekly'.
  String every;
  int hour;
  int minute;

  /// Jour de la semaine (1 = lundi) pour 'weekly'.
  int weekday;
  bool enabled;

  /// Lire le résultat à voix haute.
  bool speak;
  DateTime? lastRun;
  final List<RoutineRun> runs;

  static const labels = {
    '15min': 'Toutes les 15 minutes',
    'hourly': 'Toutes les heures',
    'daily': 'Tous les jours',
    'weekdays': 'En semaine (lundi → vendredi)',
    'weekly': 'Une fois par semaine',
  };
  static const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  String get when => switch (every) {
    '15min' || 'hourly' => labels[every]!,
    'weekly' => 'Le ${days[(weekday - 1).clamp(0, 6)]} à ${two(hour)}:${two(minute)}',
    'weekdays' => 'En semaine à ${two(hour)}:${two(minute)}',
    _ => 'Tous les jours à ${two(hour)}:${two(minute)}',
  };

  /// C'est l'heure (et on ne l'a pas déjà fait). Une routine ratée (PC
  /// éteint, Mon Hub fermé) est rattrapée dans les 3 heures.
  bool due(DateTime now) {
    if (!enabled) return false;
    final last = lastRun;
    switch (every) {
      case '15min':
        return last == null || now.difference(last) >= const Duration(minutes: 15);
      case 'hourly':
        return last == null || now.difference(last) >= const Duration(hours: 1);
    }
    final okDay = switch (every) {
      'weekdays' => now.weekday <= 5,
      'weekly' => now.weekday == weekday,
      _ => true,
    };
    final at = DateTime(now.year, now.month, now.day, hour, minute);
    return okDay &&
        !now.isBefore(at) &&
        now.difference(at) < const Duration(hours: 3) &&
        (last == null || last.isBefore(at));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'every': every,
    'h': hour,
    'm': minute,
    'wd': weekday,
    'on': enabled,
    'speak': speak,
    if (lastRun != null) 'last': lastRun!.millisecondsSinceEpoch,
    'runs': [for (final r in runs) r.toJson()],
  };

  factory Routine.fromJson(Map j) => Routine(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    prompt: '${j['prompt'] ?? ''}',
    every: '${j['every'] ?? 'daily'}',
    hour: (j['h'] as num?)?.toInt() ?? 7,
    minute: (j['m'] as num?)?.toInt() ?? 15,
    weekday: (j['wd'] as num?)?.toInt() ?? 1,
    enabled: j['on'] != false,
    speak: j['speak'] != false,
    lastRun: j['last'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((j['last'] as num).toInt()),
    runs: [
      for (final r in (j['runs'] as List?) ?? const [])
        if (r is Map) RoutineRun.fromJson(r),
    ],
  );

  /// Modèles prêts à l'emploi.
  static List<Routine> templates() => [
    Routine(
      id: '',
      name: 'Briefing du matin',
      every: 'weekdays',
      hour: 7,
      minute: 10,
      prompt:
          'Fais-moi le briefing de la journée : mes cours d\'aujourd\'hui (et ceux annulés), '
          'les devoirs pour demain, mes dernières notes, mes messages non lus (École Directe, '
          'mails, Discord, Instagram) et mes évènements.',
    ),
    Routine(
      id: '',
      name: 'Devoirs du soir',
      every: 'daily',
      hour: 18,
      minute: 0,
      prompt:
          'Liste les devoirs à faire pour demain et après-demain, et dis-moi par quoi commencer '
          '(contrôles d\'abord).',
    ),
    Routine(
      id: '',
      name: 'Bilan du soir',
      every: 'daily',
      hour: 21,
      minute: 0,
      prompt:
          'Fais mon bilan du soir (outil carnet_bilan_du_soir) : ce que j\'ai fait aujourd\'hui, '
          'mes dépenses, mon sport, puis ce qui m\'attend demain (agenda, devoirs, météo et quoi mettre).',
    ),
    Routine(
      id: '',
      name: 'Bilan de la semaine',
      every: 'weekly',
      weekday: 5,
      hour: 17,
      minute: 30,
      prompt:
          'Fais le bilan de ma semaine : notes reçues (et ma moyenne si possible), devoirs rendus, '
          'ce qui m\'attend la semaine prochaine.',
    ),
  ];
}

/// Les routines et leur minuterie (dans Mon Hub, tant qu'il est ouvert).
class Routines extends ChangeNotifier {
  Routines._();
  static final instance = Routines._();

  final _file = JsonFile<List<Routine>>(
    'clicky-routines.json',
    empty: () => [],
    decode: (j) => [
      for (final r in (j is List ? j : const []))
        if (r is Map) Routine.fromJson(r),
    ],
    encode: (v) => [for (final r in v) r.toJson()],
  );

  List<Routine> get list => _file.value;
  Timer? _timer;
  final _busy = <String>{};

  /// Fait le travail (l'agent de Clicky) : renvoie le compte rendu.
  Future<String> Function(String prompt)? runner;

  /// Prévient (alerte + voix).
  void Function(Routine r, RoutineRun run)? onDone;

  bool running(String id) => _busy.contains(id);

  Future<List<Routine>> load() async {
    await _file.load();
    notifyListeners();
    return list;
  }

  void start() {
    _timer?.cancel();
    unawaited(load());
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    await _file.load();
    final now = DateTime.now();
    for (final r in [...list]) {
      if (r.due(now) && !_busy.contains(r.id)) unawaited(runNow(r.id));
    }
  }

  Future<void> save(Routine r) async {
    await _file.update((l) {
      final i = l.indexWhere((x) => x.id == r.id);
      if (i >= 0) {
        l[i] = r;
      } else {
        l.add(r);
      }
      return l;
    });
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await _file.update((l) => l..removeWhere((r) => r.id == id));
    notifyListeners();
  }

  Future<void> runNow(String id) async {
    final job = runner;
    final r = list.where((x) => x.id == id).firstOrNull;
    if (job == null || r == null || _busy.contains(id)) return;
    _busy.add(id);
    notifyListeners();
    RoutineRun run;
    try {
      run = RoutineRun(DateTime.now(), await job(r.prompt), true);
    } catch (e) {
      run = RoutineRun(DateTime.now(), 'Échec : $e', false);
    }
    _busy.remove(id);
    await _file.update((l) {
      final x = l.where((y) => y.id == id).firstOrNull;
      if (x != null) {
        x.lastRun = run.at;
        x.runs.insert(0, run);
        if (x.runs.length > 20) x.runs.removeRange(20, x.runs.length);
      }
      return l;
    });
    notifyListeners();
    onDone?.call(r, run);
  }
}

/// Page des routines.
class RoutinesView extends StatefulWidget {
  const RoutinesView({super.key, required this.color});
  final Color color;

  @override
  State<RoutinesView> createState() => _RoutinesViewState();
}

class _RoutinesViewState extends State<RoutinesView> {
  final r = Routines.instance;

  @override
  void initState() {
    super.initState();
    unawaited(r.load());
  }

  Future<void> _edit(Routine? existing, {Routine? template}) async {
    final base = existing ?? template;
    final name = TextEditingController(text: base?.name ?? '');
    final prompt = TextEditingController(text: base?.prompt ?? '');
    var every = base?.every ?? 'daily';
    var time = TimeOfDay(hour: base?.hour ?? 7, minute: base?.minute ?? 15);
    var weekday = base?.weekday ?? 1;
    var speak = base?.speak ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(existing == null ? 'Nouvelle routine' : 'Modifier la routine'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nom',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: prompt,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Ce que Clicky doit faire',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: every,
                    decoration: const InputDecoration(
                      labelText: 'Quand',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final e in Routine.labels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => set(() => every = v ?? every),
                  ),
                  if (every == 'weekly') ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: weekday,
                      decoration: const InputDecoration(
                        labelText: 'Jour',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (var i = 1; i <= 7; i++)
                          DropdownMenuItem(value: i, child: Text(Routine.days[i - 1])),
                      ],
                      onChanged: (v) => set(() => weekday = v ?? weekday),
                    ),
                  ],
                  if (every != '15min' && every != 'hourly')
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule_rounded),
                      title: Text('À ${two(time.hour)}:${two(time.minute)}'),
                      onTap: () async {
                        final t = await showTimePicker(context: c, initialTime: time);
                        if (t != null) set(() => time = t);
                      },
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Me le lire à voix haute'),
                    value: speak,
                    onChanged: (v) => set(() => speak = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true || prompt.text.trim().isEmpty) return;
    await r.save(
      Routine(
        id: existing?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
        name: name.text.trim().isEmpty ? 'Routine' : name.text.trim(),
        prompt: prompt.text.trim(),
        every: every,
        hour: time.hour,
        minute: time.minute,
        weekday: weekday,
        enabled: existing?.enabled ?? true,
        speak: speak,
        lastRun: existing?.lastRun,
        runs: existing?.runs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'Clicky fait ces tâches tout seul, avec tes modules, tant que Mon Hub est ouvert, '
            'et te prévient quand c\'est prêt.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Nouvelle routine'),
                onPressed: () => _edit(null),
              ),
              for (final t in Routine.templates())
                if (!r.list.any((x) => x.name == t.name))
                  ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(t.name),
                    onPressed: () => _edit(null, template: t),
                  ),
            ],
          ),
          const SizedBox(height: 8),
          if (r.list.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: EmptyHint('Aucune routine pour l\'instant.', icon: Icons.event_repeat_rounded),
            ),
          for (final x in r.list)
            Card(
              child: ExpansionTile(
                shape: const Border(),
                leading: r.running(x.id)
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.event_repeat_rounded,
                        color: x.enabled ? widget.color : Colors.grey,
                      ),
                title: Text(x.name),
                subtitle: Text(
                  '${x.when}${x.lastRun == null ? '' : ' · dernière fois ${timeAgo(x.lastRun!)}'}',
                ),
                trailing: Switch(
                  value: x.enabled,
                  onChanged: (v) {
                    x.enabled = v;
                    r.save(x);
                  },
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(x.prompt, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Lancer maintenant'),
                        onPressed: r.running(x.id) ? null : () => r.runNow(x.id),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('Modifier'),
                        onPressed: () => _edit(x),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('Supprimer'),
                        onPressed: () => r.remove(x.id),
                      ),
                    ],
                  ),
                  for (final run in x.runs.take(5)) ...[
                    const Divider(),
                    Text(
                      '${dayLabel(run.at)} ${hhmm(run.at)}${run.ok ? '' : ' · échec'}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    SelectableText(run.text),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
