import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/nav.dart';
import '../../core/browser_link.dart';
import 'background_tasks.dart';
import 'jarvis.dart';

/// La pastille « Concentration · 32 min » en haut de Mon Hub pendant une
/// séance (un clic pour l'arrêter).
class FocusPill extends StatefulWidget {
  const FocusPill({super.key});

  @override
  State<FocusPill> createState() => _FocusPillState();
}

class _FocusPillState extends State<FocusPill> {
  final f = FocusMode.instance;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    f.addListener(_changed);
    unawaited(f.sync());
    // Relit la séance (lancée peut-être par Clicky partout) et le temps
    // restant : un coup d'œil toutes les 20 s, rien de plus.
    _t = Timer.periodic(const Duration(seconds: 20), (_) async {
      await f.sync();
      if (mounted && f.active) setState(() {});
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _t?.cancel();
    f.removeListener(_changed);
    super.dispose();
  }

  Future<void> _stop() async {
    // La pastille est au-dessus des pages : la boîte s'ouvre dans les pages.
    final ctx = await hubDialogContext();
    if (ctx == null || !ctx.mounted) return;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Arrêter la séance de concentration ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continuer')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Arrêter')),
        ],
      ),
    );
    if (ok != true) return;
    final text = await f.stop();
    if (text != null && ctx.mounted) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (!f.active) return const SizedBox.shrink();
    final m = f.left.inMinutes + 1;
    return Material(
      color: const Color(0xFF10B981),
      borderRadius: BorderRadius.circular(20),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _stop,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.self_improvement_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                'Concentration · encore $m min',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La pastille « Clicky travaille… » pendant une tâche « fais-le à ma
/// place » (un clic : où il en est, et l'arrêter).
class TaskPill extends StatelessWidget {
  const TaskPill({super.key});

  Future<void> _details(BgTask t) async {
    final ctx = await hubDialogContext();
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => ListenableBuilder(
        listenable: BackgroundTasks.instance,
        builder: (c, _) => AlertDialog(
          icon: const Icon(Icons.engineering_rounded),
          title: const Text('Clicky travaille pour toi'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.goal, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (t.steps.isEmpty) const Text('Il réfléchit à comment s\'y prendre…'),
                for (final s in t.steps.reversed.take(8)) Text('• $s'),
                if (!t.running) ...[const Divider(), Text(t.result)],
              ],
            ),
          ),
          actions: [
            if (t.running)
              TextButton(
                onPressed: () {
                  BackgroundTasks.instance.cancel(t);
                  Navigator.pop(c);
                },
                child: const Text('Arrêter'),
              ),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([BackgroundTasks.instance, BrowserLink.instance.step]),
    builder: (context, _) {
      final t = BackgroundTasks.instance.current;
      if (t == null) return const SizedBox.shrink();
      final step = BrowserLink.instance.step.value;
      final goal = t.goal.length > 32 ? '${t.goal.substring(0, 32)}…' : t.goal;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: const Color(0xFF2B6CFF),
          borderRadius: BorderRadius.circular(20),
          elevation: 3,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _details(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 8),
                  Text(
                    'Clicky travaille : $goal${step.isEmpty ? '' : ' · $step'}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
