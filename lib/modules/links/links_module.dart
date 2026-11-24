import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';

class LinkPreset {
  const LinkPreset(this.label, this.url);
  final String label;
  final String url;
}

/// Module générique « liste de raccourcis ».
///
/// Sert pour Instagram (aucune API publique pour les comptes perso depuis
/// la fermeture de l'API Basic Display en décembre 2024) et pour Google Drive.
/// Réutilisable pour n'importe quel autre service : il suffit d'en créer une
/// nouvelle instance dans `module_registry.dart`.
class LinksModule extends HubModule {
  LinksModule({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    this.presets = const [],
    this.hint = 'https://…',
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final IconData icon;
  @override
  final Color color;
  @override
  ApiAccess get access => ApiAccess.shortcutsOnly;

  final List<LinkPreset> presets;
  final String hint;

  List<LinkPreset> get links {
    final saved = store.getJson<List<dynamic>>('links');
    if (saved == null) return presets;
    return saved.map((e) => LinkPreset(e['label'] as String, e['url'] as String)).toList();
  }

  Future<void> _save(List<LinkPreset> l) =>
      store.setJson('links', l.map((e) => {'label': e.label, 'url': e.url}).toList());

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final l in links)
              ActionChip(
                avatar: Icon(Icons.open_in_new, size: 16, color: color),
                label: Text(l.label),
                onPressed: () => openLink(context, l.url),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(name)),
    floatingActionButton: FloatingActionButton(onPressed: () => _edit(context, null), child: const Icon(Icons.add)),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final l = links;
        if (l.isEmpty) return const EmptyHint('Aucun raccourci');
        return ReorderableListView.builder(
          itemCount: l.length,
          onReorderItem: (a, b) {
            final list = [...l];
            list.insert(b, list.removeAt(a));
            _save(list);
          },
          itemBuilder: (context, i) => ListTile(
            key: ValueKey('${l[i].label}$i'),
            leading: Icon(icon, color: color),
            title: Text(l[i].label),
            subtitle: Text(l[i].url, overflow: TextOverflow.ellipsis),
            onTap: () => openLink(context, l[i].url),
            trailing: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, i)),
          ),
        );
      },
    ),
  );

  Future<void> _edit(BuildContext context, int? index) async {
    final list = [...links];
    final current = index == null ? null : list[index];
    final r = await askFields(
      context,
      title: index == null ? 'Nouveau raccourci' : 'Modifier (vide = supprimer)',
      labels: ['Nom', 'Lien ($hint)'],
      initial: current == null ? null : [current.label, current.url],
    );
    if (r == null) return;
    if (r[0].isEmpty || r[1].isEmpty) {
      if (index != null) list.removeAt(index);
    } else if (index == null) {
      list.add(LinkPreset(r[0], r[1]));
    } else {
      list[index] = LinkPreset(r[0], r[1]);
    }
    await _save(list);
  }
}
