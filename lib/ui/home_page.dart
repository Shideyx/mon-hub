import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/hub_module.dart';
import 'settings_page.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});

  final HubController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final modules = controller.enabled;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Mon Hub'),
            actions: [
              IconButton(
                tooltip: 'Modules',
                icon: const Icon(Icons.dashboard_customize_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SettingsPage(controller: controller)),
                ),
              ),
            ],
          ),
          body: modules.isEmpty
              ? const EmptyHint('Aucun module actif. Active-en dans les réglages.')
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 420,
                    mainAxisExtent: 250,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: modules.length,
                  itemBuilder: (context, i) => ModuleCard(module: modules[i]),
                ),
        );
      },
    );
  }
}

class ModuleCard extends StatelessWidget {
  const ModuleCard({super.key, required this.module});

  final HubModule module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (ctx) => module.buildPage(ctx)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: module.color.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(module.icon, color: module.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(module.name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
            Expanded(child: module.buildSummary(context)),
          ],
        ),
      ),
    );
  }
}
