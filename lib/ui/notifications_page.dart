import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/notifications.dart';
import 'widgets.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key, required this.notifications, required this.controller});

  final NotificationCenter notifications;
  final HubController controller;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final m in controller.available) m.id: m};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Vérifier maintenant',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: notifications.pollNow,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: notifications,
        builder: (context, _) {
          final list = notifications.history;
          if (list.isEmpty) {
            return const EmptyHint(
              'Les nouveaux messages, mails, notes et rappels de cours apparaîtront ici.',
              icon: Icons.notifications_none_rounded,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final n = list[i];
              final m = byId[n.moduleId];
              return ListTile(
                leading: HubAvatar(label: m?.name ?? '?', color: m?.color ?? Colors.grey, size: 38),
                title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text(timeAgo(n.at), style: Theme.of(context).textTheme.labelSmall),
                onTap: m == null
                    ? null
                    : () => Navigator.push(context, MaterialPageRoute(builder: (ctx) => m.buildPage(ctx))),
              );
            },
          );
        },
      ),
    );
  }
}
