import 'dart:io' show Platform;
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'clicky.dart';
import 'ears.dart';
import 'whisper.dart';

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
  bool repairing = false;
  List<String> repairSteps = const [];

  /// « Clicky répare » : relance le micro de toutes les façons possibles.
  Future<void> _repair() async {
    setState(() {
      repairing = true;
      repairSteps = const [];
    });
    final r = await ears.repair();
    ClickyController.instance.lastRepair = r;
    if (!mounted) return;
    setState(() {
      repairing = false;
      repairSteps = r.steps;
      problem = r.problem;
      done = false;
      heard = '';
    });
    if (r.ok) await _start();
  }

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
              Wrap(
                spacing: 6,
                children: [
                  TextButton.icon(
                    icon: repairing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: Text(repairing ? 'Clicky répare…' : 'Clicky répare'),
                    onPressed: repairing || starting ? null : _repair,
                  ),
                  if (p.fixUri != null)
                    TextButton.icon(
                      icon: const Icon(Icons.settings_rounded, size: 16),
                      label: Text(p.fixLabel ?? 'Ouvrir les réglages'),
                      onPressed: () => openMicFix(context, p.fixUri!),
                    ),
                ],
              ),
            ],
            if (repairSteps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  repairSteps.map((s) => '• $s').join('\n'),
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
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
            onPressed: starting || repairing ? null : _start,
          ),
      ],
    );
  }
}

/// Ouvre la « solution » d'un souci de micro : une page des réglages de
/// Windows, ou l'installation de Whisper.
Future<void> openMicFix(BuildContext context, String uri) async {
  if (uri == whisperInstallUri) {
    await WhisperInstallDialog.show(context);
    return;
  }
  await launchUrl(Uri.parse(uri));
}

/// Installe Whisper (reconnaissance vocale sur le PC) avec une barre de
/// progression.
class WhisperInstallDialog extends StatefulWidget {
  const WhisperInstallDialog({super.key});

  static Future<bool?> show(BuildContext context) =>
      showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => const WhisperInstallDialog());

  @override
  State<WhisperInstallDialog> createState() => _WhisperInstallDialogState();
}

class _WhisperInstallDialogState extends State<WhisperInstallDialog> {
  String model = 'base';
  bool running = false;
  String step = '';
  double progress = 0;
  String? error;
  bool done = false;

  Future<void> _install() async {
    setState(() {
      running = true;
      error = null;
    });
    try {
      await Whisper.install(
        model: model,
        onProgress: (s, p) {
          if (mounted) {
            setState(() {
              step = s;
              progress = p;
            });
          }
        },
      );
      // Clicky passe sur Whisper (réglage « Automatique » ou « Whisper »).
      final c = ClickyController.instance;
      if (c.micEngine == 'windows') await c.setOption('micEngine', 'auto');
      c.micProblem = null;
      if (mounted) setState(() => done = true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      icon: Icon(done ? Icons.check_circle_rounded : Icons.graphic_eq_rounded, color: done ? Colors.green : clickyBlue),
      title: Text(done ? 'Whisper est installé' : 'Installer Whisper'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (done)
              const Text(
                'Clicky t\'entend maintenant avec Whisper, directement sur ton PC : rien ne part sur '
                'internet. Maintiens Ctrl + Alt et parle.',
              )
            else ...[
              const Text(
                'Whisper est la reconnaissance vocale d\'OpenAI, en version libre (whisper.cpp). Elle '
                'marche sans internet et sans les réglages de Windows, et comprend très bien le français. '
                'Tout se passe sur ton PC.',
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  for (final e in Whisper.models.entries)
                    ButtonSegment(value: e.key, label: Text('${e.value.$1} (${e.value.$2} Mo)')),
                ],
                selected: {model},
                onSelectionChanged: running ? null : (v) => setState(() => model = v.first),
              ),
              const SizedBox(height: 6),
              Text(
                model == 'base'
                    ? 'Rapide : la phrase s\'écrit en 1 à 2 secondes. Bien pour parler à Clicky.'
                    : 'Précis : se trompe moins (noms propres, phrases longues), mais met 2 à 3 fois plus de temps.',
                style: text.bodySmall,
              ),
              if (running) ...[
                const SizedBox(height: 14),
                Text(step, style: text.bodyMedium),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress <= 0 ? null : progress, minHeight: 6),
              ],
              if (error != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SelectableText(error!, style: text.bodyMedium?.copyWith(color: Colors.redAccent)),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    if (Whisper.folder != null)
                      TextButton.icon(
                        icon: const Icon(Icons.description_rounded, size: 16),
                        label: const Text('Voir le détail'),
                        onPressed: () => launchUrl(Uri.file('${Whisper.folder}${Platform.pathSeparator}installation.log')),
                      ),
                    if (ClickyController.instance.voiceOut.geminiKey.trim().isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.cloud_rounded, size: 16),
                        label: const Text('Utiliser Gemini à la place'),
                        onPressed: () async {
                          await ClickyController.instance.setOption('micEngine', 'gemini');
                          ClickyController.instance.micProblem = null;
                          if (context.mounted) Navigator.pop(context, true);
                        },
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (!running)
          TextButton(onPressed: () => Navigator.pop(context, done), child: Text(done ? 'Fermer' : 'Annuler')),
        if (!done)
          FilledButton.icon(
            icon: const Icon(Icons.download_rounded),
            label: const Text('Installer'),
            onPressed: running ? null : _install,
          ),
      ],
    );
  }
}
