import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/call_shield.dart';
import '../../core/camera_guard.dart';
import 'clicky.dart';
import 'long_memory.dart';
import 'ollama.dart';

/// **Sa mémoire** : tout ce que Smily sait de toi, rangé par sujets. Tu peux
/// tout lire, effacer un souvenir ou tout oublier, et choisir s'il rêve
/// (range sa mémoire quand tu n'es pas là) avec son IA locale.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MemoryPage()));

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final _mem = LongMemory.instance;
  List<String> _models = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _mem.load();
    final m = await Ollama.installed();
    if (!mounted) return;
    setState(() {
      _models = m;
      _loaded = true;
    });
  }

  Future<void> _add() async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lui apprendre quelque chose'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 300,
          decoration: const InputDecoration(hintText: 'Ex. : J\'écris des poèmes sur la mer'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Retenir')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _mem.remember(text.trim());
    if (mounted) setState(() {});
  }

  Future<void> _wipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tout oublier ?'),
        content: const Text('Smily oubliera tout ce qu\'il a retenu sur toi. On ne peut pas revenir en arrière.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tout oublier')),
        ],
      ),
    );
    if (ok != true) return;
    await _mem.forgetAll();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = ClickyController.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sa mémoire'),
        actions: [
          IconButton(tooltip: 'Lui apprendre quelque chose', icon: const Icon(Icons.add_rounded), onPressed: _add),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: Listenable.merge([_mem, c]),
              builder: (context, _) {
                final all = _mem.all;
                final byTopic = <String, List<Memory>>{};
                for (final m in all) {
                  (byTopic[m.topic] ??= []).add(m);
                }
                final last = _mem.lastDream;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      all.isEmpty
                          ? 'Il ne sait encore rien de toi. Dis-lui « retiens que… », ou parle-lui : il range ce qu\'il '
                                'apprend en rêvant.'
                          : 'Il se souvient de ${all.length} chose${all.length > 1 ? 's' : ''} sur toi. Tout reste sur '
                                'ton appareil.',
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: const Text('Il rêve quand tu n\'es pas là'),
                            subtitle: Text(
                              _models.isEmpty
                                  ? 'Absent 20 min : il relit sa journée et range ce qu\'il a appris (règles simples). '
                                        'Avec une IA locale (Ollama, gratuite, sur ton PC), il comprend beaucoup mieux.'
                                  : 'Absent 20 min : son IA locale (${Ollama.model}) relit sa journée et range ce qu\'il '
                                        'a appris. Rien ne sort du PC.',
                            ),
                            value: c.dreamsOn,
                            onChanged: (v) => c.setOption('dreams', v),
                          ),
                          if (last != null)
                            ListTile(
                              leading: const Icon(Icons.nights_stay_rounded),
                              title: Text(
                                'Dernier rêve : le ${last.day}/${last.month} à ${last.hour}h'
                                '${last.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                          if (_models.isEmpty)
                            const ListTile(
                              leading: Icon(Icons.download_rounded),
                              title: Text('Installer une IA locale'),
                              subtitle: Text(
                                'ollama.com → installer, puis dans un terminal : « ollama pull qwen2.5:3b » (petit et '
                                'rapide) ou « ollama pull gemma3 ». Smily la trouvera tout seul.',
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (CameraGuard.supported)
                      Card(
                        child: ListenableBuilder(
                          listenable: CallShield.instance,
                          builder: (context, _) => SwitchListTile(
                            title: const Text('Bouclier pendant les appels'),
                            subtitle: const Text(
                              'Pendant un appel, seule l\'appli de l\'appel peut filmer et écouter : si une autre allume '
                              'ta caméra ou ton micro, il te prévient et peut lui couper l\'accès.',
                            ),
                            value: CallShield.instance.on,
                            onChanged: CallShield.instance.setOn,
                          ),
                        ),
                      ),
                    for (final e in MemoryRules.topics.entries)
                      if (byTopic[e.key]?.isNotEmpty ?? false) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 18, bottom: 6),
                          child: Text(e.value, style: Theme.of(context).textTheme.titleMedium),
                        ),
                        for (final m in byTopic[e.key]!)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              m.pinned ? Icons.push_pin_rounded : Icons.circle,
                              size: m.pinned ? 18 : 8,
                            ),
                            title: Text(m.text),
                            subtitle: m.weight > 1 ? Text('entendu ${m.weight} fois') : null,
                            trailing: IconButton(
                              tooltip: 'Oublier',
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => _mem.forget(m.id),
                            ),
                          ),
                      ],
                    if (all.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: _wipe,
                        icon: const Icon(Icons.delete_forever_rounded),
                        label: const Text('Tout oublier'),
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}
