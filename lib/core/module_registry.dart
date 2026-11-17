import '../modules/books/books_module.dart';
import '../modules/carnet/carnet_module.dart';
import '../modules/claude/claude_module.dart';
import '../modules/discord/discord_module.dart';
import '../modules/docs/docs_module.dart';
import '../modules/ecoledirecte/ecoledirecte_module.dart';
import '../modules/instagram/instagram_module.dart';
import '../modules/drive/drive_module.dart';
import '../modules/mail/mail_module.dart';
import '../modules/music/music_module.dart';
import '../modules/revisions/revisions_module.dart';
import '../modules/roblox/roblox_module.dart';
import '../modules/schedule/schedule_module.dart';
import '../modules/youtube/youtube_module.dart';
import 'hub_module.dart';

/// LA liste des modules du hub.
///
/// Ajouter / retirer / remplacer un module = modifier cette liste.
/// Rien d'autre dans l'appli ne connaît les modules individuellement.
List<HubModule> buildModules() {
  // L'Agenda reprend les cours d'École Directe : on partage le même module.
  final ecole = EcoleDirecteModule();
  final schedule = ScheduleModule(ecole: ecole);
  return [
    schedule,
    ClaudeModule(),
    CarnetModule(),
    DocsModule(),
    RevisionsModule(ecole: ecole, schedule: schedule),
    ecole,
    MailModule(),
    DiscordModule(),
    InstagramModule(),
    MusicModule(),
    YouTubeModule(),
    RobloxModule(),
    BooksModule(),
    DriveModule(),
  ];
}
