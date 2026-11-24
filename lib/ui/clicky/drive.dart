import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/nav.dart';
import 'tutor.dart';
import 'win.dart';

/// Une action de « Nexo pilote ».
class DriveStep {
  const DriveStep(
    this.type, {
    this.at,
    this.screen = 1,
    this.text = '',
    this.label = '',
    this.right = false,
    this.double = false,
    this.amount = 0,
  });

  /// clic, ecrire, touches, defiler, attendre.
  final String type;

  /// Point visé (pixels de la capture).
  final Offset? at;
  final int screen;
  final String text;
  final String label;
  final bool right;
  final bool double;

  /// Crans de molette, ou millisecondes d'attente.
  final int amount;

  String get describe => switch (type) {
    'clic' =>
      '${double ? 'Double-clic' : (right ? 'Clic droit' : 'Clic')} sur ${label.isEmpty ? 'le point (${at?.dx.round()}, ${at?.dy.round()})' : '« $label »'}',
    'ecrire' => 'Écrire « ${text.length > 60 ? '${text.substring(0, 57)}…' : text} »',
    'touches' => 'Appuyer sur $text',
    'defiler' => amount > 0 ? 'Faire défiler vers le haut' : 'Faire défiler vers le bas',
    'attendre' => 'Attendre ${(amount / 1000).toStringAsFixed(1)} s',
    _ => type,
  };
}

/// Un plan d'actions proposé par l'IA, relu par toi avant de commencer.
class DrivePlan {
  DrivePlan(this.goal, this.steps, {DateTime? at}) : at = at ?? DateTime.now();
  final String goal;
  final List<DriveStep> steps;

  /// Moment de la capture : un plan trop vieux est refusé (l'écran a pu
  /// changer).
  final DateTime at;

  bool get expired => DateTime.now().difference(at) > const Duration(minutes: 2);

  static final tagRe = RegExp(r'\[ACTIONS\]([\s\S]*?)\[/ACTIONS\]', caseSensitive: false);

  /// Sépare le texte et le plan [ACTIONS]{json}[/ACTIONS].
  static (String, DrivePlan?) extract(String raw) {
    final m = tagRe.firstMatch(raw);
    if (m == null) return (raw, null);
    final text = raw.replaceAll(tagRe, '').trim();
    try {
      final j = jsonDecode(m.group(1)!.trim());
      if (j is! Map) return (text, null);
      final steps = <DriveStep>[];
      for (final s in (j['etapes'] as List?) ?? (j['steps'] as List?) ?? const []) {
        if (s is! Map) continue;
        final type = '${s['type'] ?? ''}'.toLowerCase();
        num? n(String k) => s[k] is num ? s[k] as num : num.tryParse('${s[k] ?? ''}');
        switch (type) {
          case 'clic' || 'click':
            final x = n('x'), y = n('y');
            if (x == null || y == null) continue;
            steps.add(
              DriveStep(
                'clic',
                at: Offset(x.toDouble(), y.toDouble()),
                screen: (n('ecran') ?? n('screen') ?? 1).toInt(),
                label: '${s['libelle'] ?? s['label'] ?? ''}',
                right: s['droit'] == true || s['right'] == true,
                double: s['double'] == true,
              ),
            );
          case 'ecrire' || 'type' || 'écrire':
            final t = '${s['texte'] ?? s['text'] ?? ''}';
            if (t.isNotEmpty) steps.add(DriveStep('ecrire', text: t));
          case 'touches' || 'keys' || 'key':
            final t = '${s['touches'] ?? s['keys'] ?? s['key'] ?? ''}';
            if (t.isNotEmpty) steps.add(DriveStep('touches', text: t));
          case 'defiler' || 'scroll' || 'défiler':
            steps.add(DriveStep('defiler', amount: (n('crans') ?? n('notches') ?? -3).toInt().clamp(-20, 20)));
          case 'attendre' || 'wait':
            steps.add(DriveStep('attendre', amount: (n('ms') ?? 500).toInt().clamp(100, 5000)));
        }
      }
      if (steps.isEmpty) return (text, null);
      return (text, DrivePlan('${j['but'] ?? j['goal'] ?? ''}', steps.take(25).toList()));
    } catch (_) {
      return (text, null);
    }
  }
}

/// Fait les actions, avec des garde-fous :
/// * Échap arrête tout de suite ;
/// * si tu bouges la souris pendant l'exécution, Nexo s'arrête ;
/// * pas de saisie dans une fenêtre sensible (mots de passe, banque…) ;
/// * aucune commande système n'est lancée, seulement des clics et des
///   touches.
class DriveRunner {
  DriveRunner._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// [toScreen] : point de la capture → pixels physiques de l'écran.
  static Future<String> run(
    DrivePlan plan,
    Offset Function(Offset p, int screen) toScreen, {
    void Function(String status)? onStatus,
  }) async {
    if (!supported) return 'Le pilotage n\'est possible que sur Windows.';
    if (plan.expired) return 'Ce plan est trop ancien (l\'écran a pu changer) : redemande-le.';
    Win.releaseModifiers();
    (int, int)? expected;
    var i = 0;
    for (final s in plan.steps) {
      i++;
      if (Win.down(0x1B)) return 'Arrêté (Échap) avant l\'étape $i.';
      final now = Win.cursor();
      if (expected != null && now != null) {
        final dx = (now.$1 - expected.$1).abs(), dy = (now.$2 - expected.$2).abs();
        if (dx > 8 || dy > 8) return 'Tu as bougé la souris : je me suis arrêté à l\'étape $i.';
      }
      onStatus?.call('Étape $i/${plan.steps.length} : ${s.describe}');
      switch (s.type) {
        case 'clic':
          final p = toScreen(s.at!, s.screen);
          Win.click(p.dx.round(), p.dy.round(), right: s.right, double: s.double);
          expected = (p.dx.round(), p.dy.round());
        case 'ecrire':
          if (isSensitiveTitle(Win.foregroundTitle())) {
            return 'Je n\'écris pas dans cette fenêtre (elle a l\'air sensible).';
          }
          Win.typeText(s.text);
        case 'touches':
          if (!Win.pressCombo(s.text)) return 'Touche inconnue : ${s.text}.';
        case 'defiler':
          Win.scroll(s.amount);
        case 'attendre':
          await Future<void>.delayed(Duration(milliseconds: s.amount));
      }
      expected ??= Win.cursor();
      // Laisse l'appli réagir entre deux actions.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return 'C\'est fait (${plan.steps.length} action${plan.steps.length > 1 ? 's' : ''}).';
  }

  /// Montre le plan et demande la permission.
  static Future<bool> review(DrivePlan plan) async {
    final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
    if (ctx == null || !ctx.mounted) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.mouse_rounded),
        title: const Text('Nexo veut piloter l\'ordinateur'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (plan.goal.isNotEmpty) Text(plan.goal, style: Theme.of(c).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final (i, s) in plan.steps.indexed) Text('${i + 1}. ${s.describe}'),
                const SizedBox(height: 12),
                const Text(
                  'Ne touche pas à la souris pendant ce temps. Échap arrête tout à n\'importe quel moment.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Refuser')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Vas-y')),
        ],
      ),
    );
    return ok == true;
  }

  /// Comment l'IA doit proposer un plan.
  static const guide = '''
Piloter l'ordinateur : si la personne te demande explicitement de faire une action à l'écran pour elle (« clique sur… pour moi », « écris… dans… », « fais-le pour moi »), propose à la fin un plan entre [ACTIONS] et [/ACTIONS], en JSON :
[ACTIONS]{"but":"…","etapes":[{"type":"clic","x":120,"y":340,"ecran":1,"libelle":"Enregistrer"},{"type":"ecrire","texte":"…"},{"type":"touches","touches":"ctrl+s"},{"type":"defiler","crans":-3},{"type":"attendre","ms":800}]}[/ACTIONS]
x,y en pixels sur la capture (centre de l'élément). Au plus 15 étapes, jamais de mot de passe ni de paiement. La personne relit le plan avant qu'il démarre ; ta réponse orale dit en une phrase ce que tu vas faire.''';
}
