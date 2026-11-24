import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/screen_time.dart';
import 'clicky/assistant.dart';
import 'clicky/habits.dart';

/// Réglages → **Temps d'écran et sommeil** : le temps passé par appli
/// (aujourd'hui et la semaine), les limites douces, l'heure du coucher et le
/// mode jeu. Tout reste sur ce PC.
class ScreenTimePage extends StatefulWidget {
  const ScreenTimePage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ScreenTimePage()));

  @override
  State<ScreenTimePage> createState() => _ScreenTimePageState();
}

class _ScreenTimePageState extends State<ScreenTimePage> {
  final st = ScreenTime.instance;
  bool _week = false;

  @override
  void initState() {
    super.initState();
    unawaited(st.load());
  }

  static const _days = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];

  Future<void> _addLimit(List<String> apps, [String? app]) async {
    var chosen = app ?? (apps.isEmpty ? '' : apps.first);
    var minutes = (app == null ? null : st.limits[app]) ?? 60;
    final name = TextEditingController(text: chosen);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Limite par jour'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (app == null && apps.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in apps.take(10))
                      ChoiceChip(label: Text(a), selected: name.text == a, onSelected: (_) => set(() => name.text = a)),
                  ],
                ),
              if (app == null)
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Appli ou site (Roblox, YouTube…)'),
                  onChanged: (_) => set(() {}),
                ),
              const SizedBox(height: 12),
              Text('${ScreenTime.say(minutes * 60)} par jour', style: const TextStyle(fontWeight: FontWeight.w700)),
              Slider(
                value: minutes.toDouble(),
                min: 15,
                max: 300,
                divisions: 19,
                label: ScreenTime.say(minutes * 60),
                onChanged: (v) => set(() => minutes = v.round()),
              ),
              const Text('Rien n\'est bloqué : tu es juste prévenu quand tu y arrives.'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    chosen = name.text.trim();
    name.dispose();
    if (ok == true && chosen.isNotEmpty) {
      await st.setLimit(ScreenTime.matchApp(chosen, {...apps, ...ScreenTime.knownApps}) ?? chosen, minutes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assistant = Assistant.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Temps d\'écran et sommeil')),
      body: ListenableBuilder(
        listenable: Listenable.merge([st, assistant, GameMode.instance]),
        builder: (context, _) {
          final now = DateTime.now();
          final m = _week ? st.week(now) : st.day(now);
          final total = m.values.fold<int>(0, (a, b) => a + b);
          final top = ScreenTime.sorted(m).take(8).toList();
          final most = top.isEmpty ? 1 : top.first.value;
          final limits = st.limits;
          final perDay = [for (var i = 6; i >= 0; i--) now.subtract(Duration(days: i))];
          final dayTotals = [for (final d in perDay) st.day(d).values.fold<int>(0, (a, b) => a + b)];
          final maxDay = dayTotals.fold<int>(1, (a, b) => b > a ? b : a);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Compter mon temps d\'écran'),
                    subtitle: const Text(
                      'Seulement quand tu es devant le PC, et seulement sur ce PC : rien n\'est envoyé nulle part.',
                    ),
                    value: st.on,
                    onChanged: st.setOn,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Aujourd\'hui')),
                      ButtonSegment(value: true, label: Text('7 jours')),
                    ],
                    selected: {_week},
                    onSelectionChanged: (s) => setState(() => _week = s.first),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ScreenTime.say(total),
                    style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text(_week ? 'sur l\'écran ces 7 derniers jours' : 'sur l\'écran aujourd\'hui'),
                  if (_week) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 110,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < 7; i++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(ScreenTime.say(dayTotals[i]), style: theme.textTheme.labelSmall),
                                    const SizedBox(height: 2),
                                    Container(
                                      height: 70 * dayTotals[i] / maxDay + 2,
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary.withValues(alpha: i == 6 ? 1 : 0.55),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(_days[perDay[i].weekday - 1], style: theme.textTheme.labelSmall),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (top.isEmpty)
                    const Text('Pas encore de temps compté.')
                  else
                    for (final e in top)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _addLimit(const [], e.key),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  ),
                                  if (limits[e.key] case final l?)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Text(
                                        'limite ${ScreenTime.say(l * 60)}',
                                        style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
                                      ),
                                    ),
                                  Text(ScreenTime.say(e.value)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: e.value / most,
                                  minHeight: 8,
                                  color: !_week && limits[e.key] != null && e.value >= limits[e.key]! * 60
                                      ? Colors.orange
                                      : theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  const SizedBox(height: 20),
                  Text('Limites douces', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const Text('Nexo te prévient une fois par jour quand tu arrives à la limite. Rien n\'est bloqué.'),
                  for (final e in limits.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hourglass_bottom_rounded),
                      title: Text(e.key),
                      subtitle: Text(
                        '${ScreenTime.say(e.value * 60)} par jour · aujourd\'hui : ${ScreenTime.say(st.day(now)[e.key] ?? 0)}',
                      ),
                      onTap: () => _addLimit(const [], e.key),
                      trailing: IconButton(
                        tooltip: 'Enlever',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => st.setLimit(e.key, null),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _addLimit([for (final e in ScreenTime.sorted(st.week(now))) e.key]),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Ajouter une limite'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Sommeil', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Me dire l\'heure de me coucher'),
                    subtitle: Text(
                      assistant.consent
                          ? 'Le soir, d\'après ton premier cours du lendemain (École Directe).'
                          : 'Il faut d\'abord accepter l\'assistant personnel (Réglages de Nexo).',
                    ),
                    value: assistant.on('sommeil'),
                    onChanged: assistant.consent ? (v) => assistant.setOn('sommeil', v) : null,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Heures de sommeil : ${_h(assistant.sleepHours)}'),
                    subtitle: Slider(
                      value: assistant.sleepHours.clamp(7, 10.5),
                      min: 7,
                      max: 10.5,
                      divisions: 7,
                      label: _h(assistant.sleepHours),
                      onChanged: (v) => assistant.setSleep(hours: v),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Réveil ${assistant.sleepPrep} min avant le premier cours'),
                    subtitle: Slider(
                      value: assistant.sleepPrep.clamp(20, 120).toDouble(),
                      min: 20,
                      max: 120,
                      divisions: 10,
                      label: '${assistant.sleepPrep} min',
                      onChanged: (v) => assistant.setSleep(prep: v.round()),
                    ),
                  ),
                  FutureBuilder<String?>(
                    future: _bedtime,
                    builder: (context, snap) => snap.data == null
                        ? const SizedBox.shrink()
                        : Card(
                            child: ListTile(
                              leading: const Icon(Icons.bedtime_rounded, color: Color(0xFF5B5BD6)),
                              title: Text(snap.data!),
                            ),
                          ),
                  ),
                  Builder(
                    builder: (context) {
                      final seen = Habits.insights(st.hours, st.week(now), now);
                      if (seen.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ce que Nexo a remarqué',
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            for (final s in seen)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Text('🔎', style: TextStyle(fontSize: 18)),
                                title: Text(s),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Text('Mode jeu', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mode jeu automatique'),
                    subtitle: Text(
                      GameMode.instance.active
                          ? 'En ce moment : ${GameMode.instance.game}. Les notifications t\'attendent.'
                          : 'Quand un jeu est en plein écran : notifications gardées pour la fin, sauvegarde et synchro '
                                'en pause, Nexo se cache. Bilan de la partie à la fin.',
                    ),
                    value: GameMode.enabled,
                    onChanged: (v) => GameMode.setEnabled(v).then((_) => setState(() {})),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Une seule lecture de l'agenda par ouverture de la page (pas à chaque redessin).
  late final Future<String?> _bedtime = Assistant.instance.bedtimeTonight().catchError((_) => null);

  static String _h(double h) => h == h.roundToDouble() ? '${h.round()} h' : '${h.floor()} h 30';
}
