import 'package:material_ui/material_ui.dart';

import '../core/module_store.dart';
import 'web_app.dart';

/// Point d'entrée de la **version web** (iPhone sans PC) :
/// `flutter build web -t lib/web/main.dart`. N'importe rien de Windows.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ModuleStore.init();
  runApp(const WebApp());
}
