import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'clicky.dart';
import 'ears.dart';

/// « Tester le micro » : on parle, on voit tout de suite ce que Clicky
/// entend, et sinon ce qui bloque (avec le bon réglage à ouvrir).
class MicTestDialog extends StatefulWidget {
  const MicTestDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const MicTestDialog());

  @override
  State<MicTestDialog> createState() => _MicTestDialogState();
}

class _MicTestDialogState extends State<MicTestDialog> {
  final ears = ClickyController.instance.ears;
  bool starting = false;
  bool listening = false;
  String heard = '';
  double level = 0;
  EarsProblem? problem;
  bool done = false;

  @override
  void dispose() {
    if (listening) unawaited(ears.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      starting = true;
      problem = null;
      heard = '';
      done = false;
    });
    final p = await ears.start(
      onText: (t) => mounted ? setState(() => heard = t) : null,
      onLevel: (l) => mounted ? setState(() => level = l) : null,
      onProblem: (p) => mounted
          ? setState(() {
              problem = p;
              listening = false;
            })
          : null,
      onFinalPhrase: () {},
    );
    if (!mounted) return;
    setState(() {
      starting = false;
      problem = p;
      listening = p == null;
    });
  }

  Future<void> _stop() async {
    final t = await ears.stop();
    if (!mounted) return;
    setState(() {
      listening = false;
      done = true;
      if (t.isNotEmpty) heard = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final p = problem;
    return AlertDialog(
      icon: Icon(
        p != null
            ? Icons.mic_off_rounded
            : done && heard.isNotEmpty
            ? Icons.check_circle_rounded
            : Icons.mic_rounded,
        color: p != null
            ? Colors.redAccent
            : done && heard.isNotEmpty
            ? Colors.green
            : clickyBlue,
      ),
      title: const Text('Tester le micro'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              listening
                  ? 'Parle : dis par exemple « Bonjour Clicky, quel temps fait-il ? »'
                  : 'Appuie sur « Commencer », puis parle normalement.',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: listening ? level : 0,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              color: clickyBlue,
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(minHeight: 60),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                heard.isEmpty ? (listening ? 'J\'écoute…' : (done ? 'Rien entendu.' : '')) : heard,
                style: text.titleMedium?.copyWith(
                  color: heard.isEmpty ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
            if (done && heard.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Le micro marche ! Maintiens Ctrl + Alt et parle à Clicky.',
                  style: text.bodyMedium?.copyWith(color: Colors.green),
                ),
              ),
            if (done && heard.isEmpty && p == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Rien entendu : vérifie que le bon micro est choisi par défaut et que son '
                  'volume n\'est pas à zéro.',
                  style: text.bodyMedium,
                ),
              ),
            if (p != null) ...[
              const SizedBox(height: 10),
              Text(p.message, style: text.bodyMedium?.copyWith(color: Colors.redAccent)),
              if (p.code.isNotEmpty) Text('Code : ${p.code}', style: text.bodySmall),
              if (p.fixUri != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.settings_rounded, size: 16),
                    label: Text(p.fixLabel ?? 'Ouvrir les réglages'),
                    onPressed: () => launchUrl(Uri.parse(p.fixUri!)),
                  ),
                ),
            ],
            if (ears.language != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Langue : ${ears.language}', style: text.bodySmall),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        if (listening)
          FilledButton.icon(
            icon: const Icon(Icons.stop_rounded),
            label: const Text('J\'ai fini'),
            onPressed: _stop,
          )
        else
          FilledButton.icon(
            icon: starting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.mic_rounded),
            label: Text(done || p != null ? 'Recommencer' : 'Commencer'),
            onPressed: starting ? null : _start,
          ),
      ],
    );
  }
}
