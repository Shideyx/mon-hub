import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../modules/links/links_module.dart';
import '../ui/web_login.dart';
import 'browser.dart';
import 'hub_module.dart';
import 'module_store.dart';
import 'nav.dart';

/// Un module ajouté par la personne elle-même (sans toucher au code) :
/// un site ouvert dans Mon Hub, ou une liste de liens.
class CustomModuleSpec {
  const CustomModuleSpec({
    required this.id,
    required this.name,
    required this.kind,
    this.url = '',
    this.icon = 'public',
    this.color = 0xFF7C5CFF,
    this.description = '',
  });

  /// Toujours « perso_… » (jamais le même nom qu'un module de Mon Hub).
  final String id;
  final String name;

  /// `web` (site dans Mon Hub) ou `liens` (liste de liens).
  final String kind;
  final String url;
  final String icon;
  final int color;
  final String description;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'url': url,
    'icon': icon,
    'color': color,
    if (description.isNotEmpty) 'description': description,
  };

  static CustomModuleSpec? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}';
    if (!id.startsWith('perso_')) return null;
    final kind = '${j['kind'] ?? 'web'}';
    final url = '${j['url'] ?? ''}';
    if (kind == 'web' && CustomModules.cleanUrl(url) == null) return null;
    return CustomModuleSpec(
      id: id,
      name: '${j['name'] ?? 'Module'}',
      kind: kind == 'liens' ? 'liens' : 'web',
      url: url,
      icon: '${j['icon'] ?? 'public'}',
      color: (j['color'] as num?)?.toInt() ?? 0xFF7C5CFF,
      description: '${j['description'] ?? ''}',
    );
  }

  HubModule build() => kind == 'liens'
      ? LinksModule(
          id: id,
          name: name,
          description: description.isEmpty ? 'Tes liens' : description,
          icon: CustomModules.icons[icon] ?? Icons.link_rounded,
          color: Color(color),
        )
      : CustomWebModule(this);
}

/// Les modules perso et le catalogue « prêt à l'emploi ».
class CustomModules {
  CustomModules._();

  static const _key = 'hub.custom';

  /// Icônes au choix (nom gardé → icône).
  static const icons = <String, IconData>{
    'public': Icons.public_rounded,
    'chat': Icons.chat_rounded,
    'video': Icons.smart_display_rounded,
    'music': Icons.music_note_rounded,
    'school': Icons.school_rounded,
    'book': Icons.menu_book_rounded,
    'game': Icons.sports_esports_rounded,
    'news': Icons.newspaper_rounded,
    'mail': Icons.mail_rounded,
    'calendar': Icons.calendar_month_rounded,
    'shopping': Icons.shopping_bag_rounded,
    'sport': Icons.fitness_center_rounded,
    'idea': Icons.lightbulb_rounded,
    'work': Icons.work_rounded,
    'photo': Icons.photo_camera_rounded,
    'link': Icons.link_rounded,
    'translate': Icons.translate_rounded,
    'map': Icons.map_rounded,
  };

  /// Couleurs au choix.
  static const colors = <int>[
    0xFF7C5CFF, 0xFFE0457B, 0xFF2E7DFF, 0xFF00A86B, 0xFFFF8A00, 0xFFE53935,
    0xFF00ACC1, 0xFF8E24AA, 0xFF5D4037, 0xFF455A64, 0xFF1DB954, 0xFFFFC107,
  ];

  /// Prêts à l'emploi : un clic et c'est ajouté.
  static const catalog = <({String name, String url, String icon, int color, String description})>[
    (name: 'WhatsApp', url: 'https://web.whatsapp.com/', icon: 'chat', color: 0xFF25D366, description: 'Tes discussions WhatsApp'),
    (name: 'Messenger', url: 'https://www.messenger.com/', icon: 'chat', color: 0xFF0084FF, description: 'Messages Facebook'),
    (name: 'Snapchat', url: 'https://web.snapchat.com/', icon: 'photo', color: 0xFFFFC107, description: 'Snapchat sur le PC'),
    (name: 'TikTok', url: 'https://www.tiktok.com/', icon: 'video', color: 0xFF111111, description: 'Vidéos TikTok'),
    (name: 'Twitch', url: 'https://www.twitch.tv/', icon: 'game', color: 0xFF9146FF, description: 'Lives Twitch'),
    (name: 'Netflix', url: 'https://www.netflix.com/', icon: 'video', color: 0xFFE50914, description: 'Films et séries'),
    (name: 'Deezer', url: 'https://www.deezer.com/', icon: 'music', color: 0xFFA238FF, description: 'Musique Deezer'),
    (name: 'Pronote', url: 'https://www.index-education.com/fr/pronote-info191-demo.php', icon: 'school', color: 0xFF2E7DFF, description: 'Remplace l\'adresse par celle de ton lycée'),
    (name: 'Google Classroom', url: 'https://classroom.google.com/', icon: 'school', color: 0xFF0F9D58, description: 'Tes cours en ligne'),
    (name: 'Google Agenda', url: 'https://calendar.google.com/', icon: 'calendar', color: 0xFF4285F4, description: 'Ton agenda Google'),
    (name: 'Gmail', url: 'https://mail.google.com/', icon: 'mail', color: 0xFFEA4335, description: 'Tes mails Google'),
    (name: 'Notion', url: 'https://www.notion.so/', icon: 'idea', color: 0xFF111111, description: 'Notes et projets'),
    (name: 'Canva', url: 'https://www.canva.com/', icon: 'photo', color: 0xFF00C4CC, description: 'Affiches, exposés, montages'),
    (name: 'Duolingo', url: 'https://www.duolingo.com/', icon: 'translate', color: 0xFF58CC02, description: 'Apprendre une langue'),
    (name: 'Khan Academy', url: 'https://fr.khanacademy.org/', icon: 'school', color: 0xFF14BF96, description: 'Cours et exercices gratuits'),
    (name: 'Wikipédia', url: 'https://fr.wikipedia.org/', icon: 'book', color: 0xFF455A64, description: 'L\'encyclopédie libre'),
    (name: 'Pinterest', url: 'https://fr.pinterest.com/', icon: 'idea', color: 0xFFE60023, description: 'Idées et inspirations'),
    (name: 'Reddit', url: 'https://www.reddit.com/', icon: 'news', color: 0xFFFF4500, description: 'Communautés'),
  ];

  /// Adresse propre (https seulement), ou null si elle n'est pas valable.
  static String? cleanUrl(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'https://$t';
    final u = Uri.tryParse(t);
    if (u == null || !u.hasAuthority || u.host.isEmpty || !u.host.contains('.')) return null;
    // Seulement des sites web (pas de fichier, pas de lien qui lance un
    // programme) ; http devient https.
    if (u.scheme != 'https' && u.scheme != 'http') return null;
    return u.replace(scheme: 'https').toString();
  }

  static List<CustomModuleSpec> load() {
    try {
      final raw = ModuleStore.prefs.getString(_key);
      if (raw == null) return const [];
      return [
        for (final j in jsonDecode(raw) as List) ?CustomModuleSpec.fromJson(j),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<CustomModuleSpec> l) =>
      ModuleStore.prefs.setString(_key, jsonEncode([for (final s in l) s.toJson()]));

  /// Les modules perso (à ajouter à ceux de Mon Hub).
  static List<HubModule> build() => [for (final s in load()) s.build()];

  /// Un nouvel identifiant (« perso_whatsapp_3f2a »).
  static String newId(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final r = Random.secure().nextInt(1 << 16).toRadixString(16);
    return 'perso_${base.isEmpty ? 'module' : base.substring(0, min(base.length, 20))}_$r';
  }

  static Future<CustomModuleSpec> add(CustomModuleSpec s) async {
    await _save([...load().where((x) => x.id != s.id), s]);
    return s;
  }

  static Future<void> remove(String id) => _save(load().where((x) => x.id != id).toList());

  static bool isCustom(String id) => id.startsWith('perso_');
}

/// Un site ouvert dans Mon Hub, comme un vrai module (carte à l'accueil,
/// widget du bureau, session gardée).
class CustomWebModule extends HubModule {
  CustomWebModule(this.spec);
  final CustomModuleSpec spec;

  @override
  String get id => spec.id;
  @override
  String get name => spec.name;
  @override
  String get description => spec.description.isEmpty ? Uri.tryParse(spec.url)?.host ?? spec.url : spec.description;
  @override
  IconData get icon => CustomModules.icons[spec.icon] ?? Icons.public_rounded;
  @override
  Color get color => Color(spec.color);
  @override
  ApiAccess get access => ApiAccess.shortcutsOnly;
  @override
  bool get liveWidget => true;

  String get host => Uri.tryParse(spec.url)?.host.replaceFirst('www.', '') ?? spec.url;

  @override
  Widget buildSummary(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)]),
                ),
                child: Icon(icon, size: 46, color: color),
              ),
            ),
          ),
          Text(host, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(
            'Ouvre-le ici, ta connexion est gardée.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name),
      actions: [
        IconButton(
          tooltip: 'Ouvrir dans le navigateur',
          icon: const Icon(Icons.open_in_new_rounded),
          onPressed: () => Browser.open(spec.url),
        ),
      ],
    ),
    body: webLoginSupported
        ? HubWebView(url: spec.url, desktopUserAgent: true)
        : Center(
            child: FilledButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text('Ouvrir $host'),
              onPressed: () => Browser.open(spec.url),
            ),
          ),
  );

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'perso_ouvrir_${id.substring(6).replaceAll(RegExp(r'[^a-z0-9_]'), '_')}',
      description: 'Ouvre le module perso « $name » ($host) dans Mon Hub.',
      run: (_) async {
        final ctx = hubNavigatorKey.currentContext;
        if (ctx == null) return 'Mon Hub n\'est pas ouvert.';
        await Navigator.push(ctx, MaterialPageRoute(builder: buildPage));
        return 'Ouvert : $name';
      },
    ),
  ];
}
