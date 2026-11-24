import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../modules/carnet/carnet_store.dart';
import 'assistant.dart';
import 'school_bag.dart';

/// Les propositions de Smily, en bas à gauche de Mon Hub (au-dessus de
/// toutes les pages). Mon Hub en dessous n'est jamais reconstruit.
class AssistantLayer extends StatelessWidget {
  const AssistantLayer({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Stack(
      children: [
        Positioned.fill(key: const ValueKey('assistant-hub'), child: child),
        Positioned(
          key: const ValueKey('assistant-cards'),
          left: 16,
          bottom: 16,
          child: ListenableBuilder(
            listenable: Assistant.instance,
            builder: (context, _) {
              final list = Assistant.instance.proposals;
              if (list.isEmpty) return const SizedBox.shrink();
              final shown = list.take(3).toList();
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 380, maxHeight: MediaQuery.sizeOf(context).height - 120),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (list.length > shown.length)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6, left: 4),
                          child: Material(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              child: Text(
                                '+ ${list.length - shown.length} autre${list.length - shown.length > 1 ? 's' : ''}',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ),
                        ),
                      for (final p in shown) ProposalCard(key: ValueKey(p.id), proposal: p),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Une proposition : ce que Smily a remarqué, et deux boutons.
class ProposalCard extends StatefulWidget {
  const ProposalCard({super.key, required this.proposal});
  final Proposal proposal;

  @override
  State<ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<ProposalCard> {
  bool busy = false;

  Future<void> _answer(bool yes) async {
    setState(() => busy = true);
    final a = Assistant.instance;
    final r = await a.answer(widget.proposal, yes);
    if (r != null && r.isNotEmpty) a.notify?.call('Smily', r);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final theme = Theme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: child),
      ),
      child: Container(
        width: 360,
        margin: const EdgeInsets.only(top: 10),
        child: Material(
          elevation: 10,
          shadowColor: Colors.black38,
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [p.color.withValues(alpha: 0.16), p.color.withValues(alpha: 0.03)],
              ),
              border: Border(left: BorderSide(color: p.color, width: 4)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
                        child: Icon(p.icon, color: Colors.white, size: 19),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Smily',
                              style: theme.textTheme.labelSmall?.copyWith(color: p.color, fontWeight: FontWeight.w800),
                            ),
                            Text(p.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: busy ? null : () => _answer(false),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  if (p.body.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(p.body, style: theme.textTheme.bodyMedium),
                  ],
                  for (final d in p.details)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 7, right: 8),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
                            ),
                          ),
                          Expanded(child: Text(d, style: theme.textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      TextButton(onPressed: busy ? null : () => _answer(false), child: Text(p.decline)),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: p.color),
                        onPressed: busy ? null : () => _answer(true),
                        child: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(p.accept),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Réglages → Assistant personnel.
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AssistantPage()));

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final a = Assistant.instance;
  final goal = TextEditingController();
  bool briefing = false;

  @override
  void initState() {
    super.initState();
    unawaited(Carnet.instance.load());
  }

  @override
  void dispose() {
    goal.dispose();
    super.dispose();
  }

  Future<void> _briefingNow() async {
    setState(() => briefing = true);
    try {
      final text = await a.morningBriefing();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('☀️ Ton briefing'),
          content: SizedBox(width: 560, child: SingleChildScrollView(child: SelectableText(text))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
        ),
      );
    } finally {
      if (mounted) setState(() => briefing = false);
    }
  }

  Future<void> _addGoal() async {
    final t = goal.text.trim();
    if (t.isEmpty) return;
    goal.clear();
    await Carnet.instance.add('goals', {'text': t}, max: 100);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Assistant personnel')),
      body: ListenableBuilder(
        listenable: Listenable.merge([a, a.store, Carnet.instance]),
        builder: (context, _) {
          final goals = Carnet.instance.list('goals');
          final memory = [
            for (final m in Carnet.instance.list('memory'))
              if (m.data['kind'] == 'projet' || m.data['kind'] == 'décision') m,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
                  title: const Text('Smily prend les devants', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: const Text(
                    'Il surveille ton agenda, tes devoirs et tes messages et te propose des choses. Il ne fait rien '
                    'sans ton accord, et tout reste sur ton PC.',
                  ),
                  value: a.consent,
                  onChanged: (v) => a.setConsent(v),
                ),
              ),
              const SizedBox(height: 8),
              for (final f in AssistantFeature.all)
                SwitchListTile(
                  secondary: CircleAvatar(
                    backgroundColor: f.color.withValues(alpha: 0.15),
                    child: Icon(f.icon, color: f.color),
                  ),
                  title: Text(f.title),
                  subtitle: Text(f.text),
                  value: a.on(f.key),
                  onChanged: a.consent ? (v) => a.setOn(f.key, v) : null,
                ),
              SwitchListTile(
                secondary: const CircleAvatar(child: Icon(Icons.tips_and_updates_rounded)),
                title: const Text('Idées de Gemini'),
                subtitle: const Text(
                  'Une fois par jour, Gemini (gratuit, ta clé) cherche ce que les règles n\'ont pas vu.',
                ),
                value: a.store.getJson<bool>('initiativesAi') != false,
                onChanged: a.consent && a.on('initiatives') ? (v) => a.store.setJson('initiativesAi', v) : null,
              ),
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.backpack_rounded)),
                title: const Text('Mon sac'),
                subtitle: Text(
                  'Rappel à ${a.bagMinutes ~/ 60} h ${(a.bagMinutes % 60).toString().padLeft(2, '0')} · '
                  'les affaires de chaque matière se règlent ici',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: a.consent && a.on('sac'),
                onTap: () => _BagDialog.show(context, a),
              ),
              const Divider(height: 32),
              Text('Briefing du matin', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                'Chaque matin : ton emploi du temps, tes devoirs et échéances, tes rendez-vous, tes messages importants, '
                'tes tâches en retard, tes objectifs et mes conseils pour la journée.',
                style: theme.textTheme.bodySmall,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Briefing intelligent (préparé par Mon Hub)'),
                subtitle: const Text('Sinon, c\'est Claude qui le prépare (plus lent).'),
                value: a.briefingOn,
                onChanged: (v) => a.setOn('briefing', v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Rédigé joliment par Gemini'),
                subtitle: const Text('Avec ta clé Gemini gratuite. Sans elle : la version Mon Hub, déjà complète.'),
                value: a.store.getJson<bool>('briefingAi') != false,
                onChanged: (v) => a.store.setJson('briefingAi', v),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: briefing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wb_sunny_rounded),
                  label: const Text('Mon briefing maintenant'),
                  onPressed: briefing || !a.ready ? null : _briefingNow,
                ),
              ),
              const Divider(height: 32),
              Text('Mes objectifs', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: goal,
                      decoration: const InputDecoration(hintText: 'Ex. : avoir 14 de moyenne en maths', isDense: true),
                      onSubmitted: (_) => _addGoal(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(icon: const Icon(Icons.add_rounded), onPressed: _addGoal),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final g in goals)
                    InputChip(
                      avatar: Icon(g.done ? Icons.emoji_events_rounded : Icons.flag_rounded, size: 18),
                      label: Text(
                        g.text,
                        style: g.done ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                      ),
                      selected: g.done,
                      onPressed: () => Carnet.instance.change('goals', g.id, {'done': !g.done}),
                      onDeleted: () => Carnet.instance.remove('goals', g.id),
                    ),
                  if (goals.isEmpty)
                    Text(
                      'Dis-le à Smily (« mon objectif est de… ») ou écris-le ici.',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              const Divider(height: 32),
              Text(
                'Mes projets et décisions',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Smily les retient quand tu en parles (« j\'ai décidé de… », « mon projet… ») et s\'en sert pour t\'aider.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in memory)
                    InputChip(
                      avatar: Icon(
                        m.data['kind'] == 'projet' ? Icons.rocket_launch_rounded : Icons.gavel_rounded,
                        size: 18,
                      ),
                      label: Text(m.text),
                      onDeleted: () => Carnet.instance.remove('memory', m.id),
                    ),
                  if (memory.isEmpty) Text('Rien pour l\'instant.', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Les réglages du sac : l'heure du rappel et les affaires par matière.
class _BagDialog extends StatefulWidget {
  const _BagDialog({required this.a});
  final Assistant a;

  static Future<void> show(BuildContext context, Assistant a) => showDialog<void>(
    context: context,
    builder: (_) => _BagDialog(a: a),
  );

  @override
  State<_BagDialog> createState() => _BagDialogState();
}

class _BagDialogState extends State<_BagDialog> {
  late final text = TextEditingController(text: SchoolBag.customText(widget.a.bagItems));
  late int minutes = widget.a.bagMinutes;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.backpack_rounded),
    title: const Text('Mon sac'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule_rounded),
            label: Text('Rappel à ${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}'),
            onPressed: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
              );
              if (t != null) setState(() => minutes = t.hour * 60 + t.minute);
            },
          ),
          const SizedBox(height: 12),
          const Text(
            'Tes affaires par matière (une matière par ligne). Sans rien, Smily utilise les habituelles : '
            'tenue de sport pour l\'EPS, calculatrice pour les maths…',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: text,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'EPS : tenue, baskets, gourde\nMaths : calculatrice, compas\nAnglais : workbook',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
      FilledButton(
        onPressed: () async {
          await widget.a.setBagMinutes(minutes);
          await widget.a.setBagItems(SchoolBag.parseCustom(text.text));
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('Enregistrer'),
      ),
    ],
  );
}
