import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';

/// Activer / désactiver / réordonner les modules.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final HubController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modules')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final modules = controller.ordered;
          return ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            header: const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Glisse pour changer l\'ordre, '
                  'décoche pour masquer un module.'),
            ),
            itemCount: modules.length,
            onReorderItem: controller.reorder,
            itemBuilder: (context, i) {
              final m = modules[i];
              return SwitchListTile(
                key: ValueKey(m.id),
                secondary: Icon(m.icon, color: m.color),
                title: Text(m.name),
                subtitle: Text('${m.description}\n${m.access.label}'),
                isThreeLine: true,
                value: controller.isEnabled(m),
                onChanged: (v) => controller.setEnabled(m, v),
              );
            },
          );
        },
      ),
    );
  }
}

/// Badge discret indiquant le type d'accès au service.
class AccessBadge extends StatelessWidget {
  const AccessBadge(this.access, {super.key});

  final ApiAccess access;

  @override
  Widget build(BuildContext context) {
    final color = switch (access) {
      ApiAccess.official || ApiAccess.local => Colors.green,
      ApiAccess.unofficial => Colors.orange,
      ApiAccess.shortcutsOnly => Colors.blueGrey,
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(access.label),
      side: BorderSide(color: color),
    );
  }
}
