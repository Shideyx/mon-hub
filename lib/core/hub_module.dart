import 'package:material_ui/material_ui.dart';

import 'module_store.dart';
import 'notifications.dart';

export 'notifications.dart' show HubNotification;

/// Niveau d'accès officiel au service derrière un module.
enum ApiAccess {
  /// API officielle et documentée (fiable).
  official('API officielle'),

  /// API non documentée, peut casser à tout moment.
  unofficial('API non officielle'),

  /// Pas d'API : le module ouvre l'appli / le site.
  shortcutsOnly('Raccourcis uniquement'),

  /// Données stockées uniquement sur l'appareil.
  local('Local');

  const ApiAccess(this.label);
  final String label;
}

/// Contrat que chaque module du hub doit respecter.
///
/// Pour ajouter un module : créer une classe qui étend [HubModule] dans
/// `lib/modules/<nom>/`, puis l'ajouter à la liste de `module_registry.dart`.
/// Pour en retirer un : le supprimer de cette liste (ou le désactiver dans
/// les réglages de l'appli).
abstract class HubModule {
  HubModule() : store = ModuleStore();

  /// Identifiant unique et stable (sert de clé de stockage).
  String get id;
  String get name;
  String get description;
  IconData get icon;
  Color get color;
  ApiAccess get access;

  /// Stockage propre au module (préférences + secrets).
  final ModuleStore store;

  /// Contenu compact affiché sur la tuile du tableau de bord.
  Widget buildSummary(BuildContext context);

  /// Page complète ouverte quand on touche la tuile.
  Widget buildPage(BuildContext context);

  /// Nombre affiché en pastille sur la tuile (non lus, etc.).
  final badge = ValueNotifier<int>(0);

  /// Renvoie l'état actuel des choses « alertables » (mails non lus,
  /// derniers messages…). Le centre de notifications compare avec ce qu'il a
  /// déjà vu et n'alerte que pour les nouveautés. Par défaut : rien.
  Future<List<HubNotification>> poll() async => const [];

  /// Appelé une fois au démarrage, après l'initialisation du stockage.
  void attach() => store.bind(id);
}
