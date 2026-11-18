import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/browser_link.dart';
import '../../core/error_log.dart';
import 'claude_code.dart';

/// Une tâche faite par Clicky en arrière-plan.
class BgTask {
  BgTask(this.goal) : started = DateTime.now();
  final String goal;
  final DateTime started;
  final steps = <String>[];

  /// 'en cours', 'fini', 'erreur' ou 'arrêté'.
  String status = 'en cours';
  String result = '';
  bool get running => status == 'en cours';
}

/// **« Fais-le à ma place »** : Clicky fait une tâche **en arrière-plan**
/// pendant que tu continues à utiliser ton PC — avec les modules de Mon Hub
/// (agenda, devoirs, mails, Google Docs, Drive…), le PC (commandes, fichiers,
/// sans prendre la souris) et ton navigateur grâce à l'extension (dans ses
/// propres onglets). Il demande ton accord avant d'envoyer, publier, payer ou
/// supprimer. Une pastille en haut de Mon Hub montre où il en est.
class BackgroundTasks extends ChangeNotifier {
  BackgroundTasks._();
  static final instance = BackgroundTasks._();

  final tasks = <BgTask>[];

  /// Fait le travail (l'agent de Clicky, avec tous ses outils).
  Future<String> Function(String prompt)? runner;

  /// Prévenir à la fin (notification + Clicky qui le dit).
  void Function(String title, String body)? onDone;

  BgTask? get current => tasks.where((t) => t.running).lastOrNull;

  /// Les consignes données à l'agent pour une tâche de fond.
  static String prompt(String goal) =>
      'Tâche à faire EN ARRIÈRE-PLAN pendant que la personne continue à utiliser son PC : ne prends jamais sa souris '
      'ni son clavier et ne touche pas à ses fenêtres. Fais la tâche jusqu\'au bout avec tes actions (modules de Mon '
      'Hub, Google Docs, fichiers du PC, et le navigateur avec nav_… dans tes propres onglets si l\'extension est '
      'branchée). Si une étape est impossible, contourne-la ou explique pourquoi. Termine par un compte rendu court '
      '(ce qui a été fait, les liens utiles).\n\nLa tâche : $goal';

  /// Commence une tâche (non bloquant). Renvoie le message à dire.
  String start(String goal) {
    final g = goal.trim();
    if (g.isEmpty) return 'Dis-moi ce que je dois faire à ta place.';
    final run = runner;
    if (run == null) return 'Ouvre Mon Hub : c\'est lui qui fait les tâches en arrière-plan.';
    final t = BgTask(g);
    tasks.add(t);
    if (tasks.length > 20) tasks.removeAt(0);
    final link = BrowserLink.instance
      ..stopped = false
      ..trustedUntil = DateTime.now().add(const Duration(minutes: 45));
    void step() {
      final s = link.step.value;
      if (s.isNotEmpty && t.running && (t.steps.isEmpty || t.steps.last != s)) {
        t.steps.add(s);
        notifyListeners();
      }
    }

    link.step.addListener(step);
    notifyListeners();
    unawaited(() async {
      try {
        final text = await run(prompt(g));
        if (t.running) {
          t
            ..status = 'fini'
            ..result = text;
          onDone?.call('Clicky a fini : ${_short(g)}', text);
        }
      } catch (e) {
        if (t.running) {
          t
            ..status = 'erreur'
            ..result = '$e';
          onDone?.call('Clicky n\'a pas pu finir', '$e');
          ErrorLog.record(e, null, where: 'Tâche en arrière-plan');
        }
      } finally {
        link.step.removeListener(step);
        link.step.value = '';
        if (current == null) link.trustedUntil = null;
        notifyListeners();
      }
    }());
    return 'C\'est parti, je m\'en occupe en arrière-plan : tu peux continuer ce que tu fais. Je te préviens quand c\'est fini.';
  }

  /// Arrête la tâche en cours.
  void cancel(BgTask t) {
    if (!t.running) return;
    t.status = 'arrêté';
    BrowserLink.instance
      ..stopped = true
      ..trustedUntil = null;
    ClaudeCode.cancelAll();
    notifyListeners();
  }

  static String _short(String s) => s.length > 50 ? '${s.substring(0, 50)}…' : s;
}
