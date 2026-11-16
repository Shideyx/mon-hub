import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Navigateur principal de l'appli : permet d'afficher une fenêtre (question
/// de sécurité École Directe…) même quand la demande vient d'un traitement en
/// arrière-plan, sans dépendre d'une tuile précise affichée à l'écran.
final hubNavigatorKey = GlobalKey<NavigatorState>();

/// Contexte utilisable pour `showDialog`, en attendant (au plus [timeout])
/// que l'interface soit prête.
Future<BuildContext?> hubDialogContext({Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final ctx = hubNavigatorKey.currentState?.overlay?.context;
    if (ctx != null && ctx.mounted) return ctx;
    if (DateTime.now().isAfter(end)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
