import 'package:material_ui/material_ui.dart';

import 'core/hub_controller.dart';
import 'core/module_registry.dart';
import 'core/module_store.dart';
import 'core/notifications.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ModuleStore.init();
  final hub = HubController(buildModules());
  final notifications = NotificationCenter(hub);
  runApp(HubApp(controller: hub, notifications: notifications));
  await notifications.start();
}

class HubApp extends StatelessWidget {
  const HubApp({super.key, required this.controller, required this.notifications});

  final HubController controller;
  final NotificationCenter notifications;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mon Hub',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: HomePage(controller: controller, notifications: notifications),
    );
  }
}
