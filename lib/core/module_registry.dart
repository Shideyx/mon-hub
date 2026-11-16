import 'package:material_ui/material_ui.dart';

import '../modules/books/books_module.dart';
import '../modules/claude/claude_module.dart';
import '../modules/discord/discord_module.dart';
import '../modules/ecoledirecte/ecoledirecte_module.dart';
import '../modules/instagram/instagram_module.dart';
import '../modules/links/links_module.dart';
import '../modules/mail/mail_module.dart';
import '../modules/roblox/roblox_module.dart';
import '../modules/schedule/schedule_module.dart';
import 'hub_module.dart';

/// LA liste des modules du hub.
///
/// Ajouter / retirer / remplacer un module = modifier cette liste.
/// Rien d'autre dans l'appli ne connaît les modules individuellement.
List<HubModule> buildModules() {
  // L'Agenda reprend les cours d'École Directe : on partage le même module.
  final ecole = EcoleDirecteModule();
  return [
    ScheduleModule(ecole: ecole),
    ClaudeModule(),
    ecole,
    MailModule(),
    DiscordModule(),
    InstagramModule(),
    RobloxModule(),
    BooksModule(),
    LinksModule(
      id: 'drive',
      name: 'Google Drive',
      description: 'Raccourcis vers tes documents Drive',
      icon: Icons.folder_shared_outlined,
      color: const Color(0xFF1FA463),
      presets: const [LinkPreset('Mon Drive', 'https://drive.google.com/drive/my-drive')],
      hint: 'https://docs.google.com/…',
    ),
  ];
}
