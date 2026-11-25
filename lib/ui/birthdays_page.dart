import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/birthdays.dart';
import 'clicky/assistant.dart';

/// Réglages → **Anniversaires des proches** : ceux de Google Agenda et ceux
/// ajoutés ici, les prochains en tête, et le rappel de l'assistant.
class BirthdaysPage extends StatefulWidget {
  const BirthdaysPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BirthdaysPage()));

  @override
  State<BirthdaysPage> createState() => _BirthdaysPageState();
}

class _BirthdaysPageState extends State<BirthdaysPage> {
  final b = Birthdays.instance;
  late Future<List<Birthday>> _all = Assistant.instance.allBirthdays(days: 366);

  void _refresh() => setState(() => _all = Assistant.instance.allBirthdays(days: 366));

  Future<void> _add() async {
    final name = TextEditingController();
    final date = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Ajouter un anniversaire'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Prénom'),
              ),
              TextField(
                controller: date,
                decoration: InputDecoration(labelText: 'Date (12 mars, ou 12/03/2011 pour l\'âge)', errorText: error),
                onSubmitted: (_) => Navigator.pop(context, true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty || Birthdays.parseDate(date.text) == null) {
                  set(() => error = 'Écris par exemple « 12 mars » ou « 12/03/2011 »');
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
    final d = Birthdays.parseDate(date.text);
    final n = name.text.trim();
    name.dispose();
    date.dispose();
    if (ok != true || d == null || n.isEmpty) return;
    final (m, day, y) = d;
    await b.add(Birthday(n[0].toUpperCase() + n.substring(1), m, day, year: y));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assistant = Assistant.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Anniversaires des proches')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.cake_rounded),
        label: const Text('Ajouter'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: FutureBuilder<List<Birthday>>(
            future: _all,
            builder: (context, snap) {
              final now = DateTime.now();
              final up = Birthdays.upcoming(snap.data ?? b.saved, now, days: 366);
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                children: [
                  ListenableBuilder(
                    listenable: assistant,
                    builder: (context, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Me prévenir'),
                      subtitle: Text(
                        assistant.consent
                            ? 'La veille au soir (19 h) et le jour même, avec un petit message tout prêt.'
                            : 'Il faut d\'abord accepter l\'assistant personnel (Réglages de Nexo).',
                      ),
                      value: assistant.on('anniversaires'),
                      onChanged: assistant.consent ? (v) => assistant.setOn('anniversaires', v) : null,
                    ),
                  ),
                  Text(
                    'Ceux de Google Agenda (calendrier « Anniversaires » de tes contacts) arrivent tout seuls. '
                    'Tu peux aussi dire à Nexo : « l\'anniversaire de Léa c\'est le 12 mars ». Ta liste est '
                    'synchronisée sur tes appareils.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (snap.connectionState != ConnectionState.done) const LinearProgressIndicator(),
                  if (up.isEmpty && snap.connectionState == ConnectionState.done)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Aucun anniversaire pour l\'instant.', textAlign: TextAlign.center),
                    ),
                  for (final (x, d) in up)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0x22E5487B),
                          child: Text(
                            x.name.characters.first.toUpperCase(),
                            style: const TextStyle(color: Color(0xFFE5487B), fontWeight: FontWeight.w800),
                          ),
                        ),
                        title: Text(x.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          [
                            Birthdays.dateText(Birthday(x.name, x.month, x.day)),
                            _left(d, now),
                            if (Birthdays.age(x, d) case final a?) '$a ans',
                            if (x.fromAgenda) 'Google Agenda',
                          ].join(' · '),
                        ),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Copier un message d\'anniversaire',
                              icon: const Icon(Icons.content_copy_rounded),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: Birthdays.wish(x, d)));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(const SnackBar(content: Text('Message copié : colle-le où tu veux.')));
                                }
                              },
                            ),
                            if (!x.fromAgenda)
                              IconButton(
                                tooltip: 'Oublier',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  await b.remove(x.name);
                                  _refresh();
                                },
                              ),
                          ],
                        ),
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

  static String _left(DateTime d, DateTime now) {
    final n = d.difference(DateTime(now.year, now.month, now.day)).inDays;
    return switch (n) {
      0 => 'aujourd\'hui 🎂',
      1 => 'demain',
      _ => 'dans $n jours',
    };
  }
}
