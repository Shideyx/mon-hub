import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';

class DiscordServer {
  DiscordServer({required this.guildId, this.name = '', this.online, this.invite});
  final String guildId;
  String name;
  int? online;
  String? invite;
  String? error;
}

/// Discord n'autorise pas une appli tierce à lire tes messages privés avec
/// ton compte (les « self-bots » sont interdits par les conditions
/// d'utilisation et peuvent faire bannir le compte).
///
/// Ce module utilise donc ce qui est officiel et sans risque :
/// * le widget public de serveur (`/api/guilds/<id>/widget.json`), qui donne
///   le nombre de membres en ligne si le widget est activé sur le serveur ;
/// * des raccourcis qui ouvrent l'appli Discord.
///
/// Évolution possible : un bot Discord (API officielle) invité sur tes
/// serveurs pour afficher les derniers messages de certains salons.
class DiscordModule extends HubModule {
  @override
  String get id => 'discord';
  @override
  String get name => 'Discord';
  @override
  String get description => 'Tes serveurs Discord et un accès rapide';
  @override
  IconData get icon => Icons.forum_outlined;
  @override
  Color get color => const Color(0xFF5865F2);
  @override
  ApiAccess get access => ApiAccess.official;

  List<String> get guildIds =>
      (store.getJson<List<dynamic>>('guilds') ?? const []).cast<String>();

  Future<List<DiscordServer>> fetch() => Future.wait(guildIds.map((id) async {
        final s = DiscordServer(guildId: id);
        try {
          final r = await http
              .get(Uri.parse('https://discord.com/api/guilds/$id/widget.json'));
          if (r.statusCode != 200) {
            s.error = 'Widget désactivé sur ce serveur';
          } else {
            final j = jsonDecode(r.body) as Map<String, dynamic>;
            s.name = j['name'] as String? ?? id;
            s.online = j['presence_count'] as int?;
            s.invite = j['instant_invite'] as String?;
          }
        } catch (e) {
          s.error = '$e';
        }
        return s;
      }));

  void _openDiscord(BuildContext context, [String? guildId]) => openLink(
      context,
      guildId == null
          ? 'https://discord.com/channels/@me'
          : 'https://discord.com/channels/$guildId');

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: FutureBuilder(
                future: fetch(),
                builder: (context, snap) {
                  final list = snap.data ?? [];
                  if (guildIds.isEmpty) {
                    return const EmptyHint('Ajoute tes serveurs dans la page Discord');
                  }
                  return ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final s in list)
                        ListTile(
                          dense: true,
                          title: Text(s.name.isEmpty ? s.guildId : s.name),
                          trailing: s.online == null
                              ? null
                              : Text('● ${s.online} en ligne',
                                  style: const TextStyle(color: Colors.green)),
                        ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Mes messages privés'),
                onPressed: () => _openDiscord(context),
              ),
            ),
          ],
        ),
      );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name)),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Ajouter un serveur'),
            onPressed: () async {
              final r = await askFields(context,
                  title: 'ID du serveur Discord',
                  labels: ['ID (clic droit sur le serveur > Copier l\'identifiant)']);
              final v = r?.first.trim() ?? '';
              if (v.isEmpty) return;
              await store.setJson('guilds', {...guildIds, v}.toList());
            },
          ),
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => FutureBuilder(
            future: fetch(),
            builder: (context, snap) => ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: const Text('Ouvrir mes messages privés'),
                  onTap: () => _openDiscord(context),
                ),
                const Divider(),
                for (final s in snap.data ?? <DiscordServer>[])
                  ListTile(
                    leading: const Icon(Icons.groups_outlined),
                    title: Text(s.name.isEmpty ? s.guildId : s.name),
                    subtitle: Text(s.error ??
                        '${s.online ?? '?'} membres en ligne'),
                    onTap: () => _openDiscord(context, s.guildId),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => store.setJson(
                          'guilds', guildIds.where((g) => g != s.guildId).toList()),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Pour voir le nombre de membres en ligne, le widget doit être '
                    'activé : Paramètres du serveur > Widget > Activer le widget. '
                    'Pour copier un ID, active le mode développeur dans '
                    'Discord (Paramètres > Avancés).',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
