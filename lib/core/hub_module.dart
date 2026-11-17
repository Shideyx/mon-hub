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

  /// Actions que Claude peut utiliser dans ce module (via l'extension
  /// « Mon Hub » de l'appli Claude sur PC). Par défaut : aucune.
  List<HubTool> get tools => const [];

  /// Le widget du bureau vit tout seul (vidéo, page web) : la fenêtre ne
  /// le recharge pas toutes les 3 minutes.
  bool get liveWidget => false;

  /// Appelé une fois au démarrage, après l'initialisation du stockage.
  void attach() => store.bind(id);
}

/// Une action que Claude peut déclencher dans l'appli.
class HubTool {
  const HubTool({
    required this.name,
    required this.description,
    required this.run,
    this.params = const {},
    this.required = const [],
  });

  /// Nom technique (lettres, chiffres, _), unique dans toute l'appli.
  final String name;

  /// Ce que fait l'action, en une phrase (lu par Claude).
  final String description;

  /// Paramètres : nom → (type JSON, description). Types : string, integer,
  /// number, boolean.
  final Map<String, (String, String)> params;
  final List<String> required;
  final Future<Object?> Function(Map<String, dynamic> args) run;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': {
      'type': 'object',
      'properties': {
        for (final e in params.entries) e.key: {'type': e.value.$1, 'description': e.value.$2},
      },
      'required': required,
    },
  };
}
