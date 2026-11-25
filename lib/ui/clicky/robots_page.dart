import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'life_view.dart' show emojiFonts;
import 'robots.dart';

/// **Ses robots** : la liste des petites automatisations de Nexo (sans IA,
/// sans jetons), pour les allumer, les essayer, les supprimer, en créer une
/// en une phrase, ou ajouter un robot tout prêt.
class RobotsPage extends StatefulWidget {
  const RobotsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RobotsPage()));

  @override
  State<RobotsPage> createState() => _RobotsPageState();
}

class _RobotsPageState extends State<RobotsPage> {
  final _input = TextEditingController();
  String? _message;
  bool _error = false;

  static const _examples = [
    'Quand j\'ouvre Discord, coupe mon micro',
    'Tous les jours à 7 h, j\'ai quoi aujourd\'hui',
    'Le samedi à 10 h, mets de la musique',
    'Quand je reçois un message de Léa, préviens-moi',
    'Toutes les 45 minutes, dis-moi de m\'étirer',
  ];

  @override
  void initState() {
    super.initState();
    unawaited(Robots.instance.load());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final r = RobotRules.parse(_input.text);
    if (r == null) {
      setState(() {
        _error = true;
        _message =
            'Je n\'ai pas compris. Commence par « quand j\'ouvre… », « tous les jours à… », « quand je joue… », '
            '« quand je reçois un message… » ou « toutes les… ».';
      });
      return;
    }
    await Robots.instance.add(r);
    if (!mounted) return;
    setState(() {
      _error = false;
      _message = 'Robot créé : ${r.when}, ${r.what}.';
      _input.clear();
    });
  }

  Future<void> _try(Robot r) async {
    final said = await Robots.instance.runActions(r);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(said.isEmpty ? '${r.emoji} ${r.name} : c\'est fait.' : said.join(' '))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Ses robots')),
      body: ListenableBuilder(
        listenable: Robots.instance,
        builder: (context, _) {
          final robots = Robots.instance.list;
          final ready = [
            for (final t in RobotRules.templates)
              if (!robots.any((r) => r.template == t.id)) t,
          ];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: [
                  Text(
                    'De petites automatisations que Nexo fait tout seul, sans IA : elles ne coûtent aucun jeton. '
                    'Chacune part au plus quelques fois par jour, et rien de sensible ne se fait sans ton accord.',
                    style: text.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  // Créer un robot en une phrase.
                  TextField(
                    controller: _input,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _create(),
                    decoration: InputDecoration(
                      labelText: 'Nouveau robot, en une phrase',
                      hintText: _examples.first,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: 'Créer',
                        icon: const Icon(Icons.add_circle_rounded),
                        onPressed: _create,
                      ),
                    ),
                  ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _message!,
                        style: text.bodySmall?.copyWith(color: _error ? theme.colorScheme.error : theme.colorScheme.primary),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in _examples.skip(1))
                        ActionChip(
                          label: Text(e, style: text.labelSmall),
                          onPressed: () => setState(() => _input.text = e),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _Header('Allumés et éteints (${robots.length})'),
                  if (robots.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Aucun robot pour l\'instant : crée-en un au-dessus, ou ajoute un robot tout prêt.'),
                    ),
                  for (final r in robots)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                        child: Row(
                          children: [
                            Text(r.emoji, style: const TextStyle(fontSize: 24, fontFamilyFallback: emojiFonts)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          r.name,
                                          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (r.by == 'nexo') ...[
                                        const SizedBox(width: 6),
                                        _Pill('par Nexo', theme.colorScheme.primary),
                                      ],
                                      if (r.ask) ...[
                                        const SizedBox(width: 6),
                                        _Pill('demande avant', theme.colorScheme.tertiary),
                                      ],
                                    ],
                                  ),
                                  Text(r.when, style: text.bodySmall),
                                  Text(
                                    r.what,
                                    style: text.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                  ),
                                  if (r.total > 0)
                                    Text('Lancé ${r.total} fois', style: text.labelSmall),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Essayer maintenant',
                              icon: const Icon(Icons.play_arrow_rounded),
                              onPressed: () => _try(r),
                            ),
                            IconButton(
                              tooltip: 'Supprimer',
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => Robots.instance.remove(r.id),
                            ),
                            Switch(value: r.on, onChanged: (v) => Robots.instance.setOn(r.id, v)),
                          ],
                        ),
                      ),
                    ),
                  if (ready.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _Header('Robots tout prêts'),
                    for (final t in ready)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(t.emoji, style: const TextStyle(fontSize: 22, fontFamilyFallback: emojiFonts)),
                        title: Text(t.name),
                        subtitle: Text(t.description),
                        trailing: FilledButton.tonal(
                          onPressed: () => Robots.instance.add(t.build(by: 'nexo')),
                          child: const Text('Ajouter'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary, letterSpacing: 1.1),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
  );
}
