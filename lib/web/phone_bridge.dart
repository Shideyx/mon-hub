/// Ce que le navigateur du téléphone sait faire (notifications, partage,
/// vibration, fichier d'agenda…). Version web : `phone_bridge_web.dart` ;
/// ailleurs (tests) : rien.
library;

export 'phone_bridge_stub.dart' if (dart.library.js_interop) 'phone_bridge_web.dart';
