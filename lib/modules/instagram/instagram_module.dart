import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/cam_blur.dart';
import '../../core/desktop_widgets.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/web_login.dart';
import 'instagram_watch.dart';

/// Instagram = le vrai instagram.com dans Mon Hub, exactement comme dans un
/// navigateur : fil, reels, stories, messages, vocaux, appels.
///
/// ⚠️ Mon Hub ne fait AUCUNE requête à Instagram tout seul : pas de lecture
/// des messages en arrière-plan, pas d'envoi automatique, pas d'API privée.
/// Jusqu'à la v1.41, il utilisait l'API privée d'Instagram (en se faisant
/// passer pour l'appli Android avec ta session, et en relisant tes messages
/// toutes les 2 minutes) : Instagram l'a pris pour un programme malveillant
/// et a bloqué le compte. Ne jamais remettre ça.
class InstagramModule extends HubModule {
  @override
  String get id => 'instagram';
  @override
  String get name => 'Instagram';
  @override
  String get description => 'Le vrai Instagram : fil, reels, stories, messages et vocaux';
  @override
  IconData get icon => Icons.camera_alt_rounded;
  @override
  Color get color => const Color(0xFFE1306C);
  @override
  ApiAccess get access => ApiAccess.shortcutsOnly;

  static const home = 'https://www.instagram.com/';

  /// Les endroits d'Instagram (nom, icône, adresse).
  static const places = [
    ('Fil', Icons.home_rounded, home),
    ('Reels', Icons.movie_rounded, 'https://www.instagram.com/reels/'),
    ('Messages', Icons.send_rounded, 'https://www.instagram.com/direct/inbox/'),
    ('Explorer', Icons.explore_rounded, 'https://www.instagram.com/explore/'),
  ];

  /// L'adresse d'une page : fil, reels, messages, explorer, ou un profil.
  static String urlFor(String page, {String name = ''}) {
    final who = name.trim().replaceFirst('@', '');
    if (who.isNotEmpty) return 'https://www.instagram.com/${Uri.encodeComponent(who)}/';
    final p = page.toLowerCase();
    if (p.startsWith('reel')) return places[1].$3;
    if (p.startsWith('mess') || p.startsWith('dm') || p.startsWith('conv')) return places[2].$3;
    if (p.startsWith('expl') || p.startsWith('rech')) return places[3].$3;
    return home;
  }

  /// Les messages non lus, d'après le titre de la page (« (3) Instagram ») :
  /// rien n'est demandé à Instagram pour ça.
  static int? unreadFromTitle(String? title) {
    final m = RegExp(r'^\((\d+)\)').firstMatch(title?.trim() ?? '');
    return m == null ? null : int.parse(m[1]!);
  }

  @override
  bool get liveWidget => true;

  @override
  void attach() {
    super.attach();
    unawaited(forgetOldSession());
  }

  /// Efface la session que l'ancienne version gardait pour l'API privée.
  @visibleForTesting
  Future<void> forgetOldSession() async {
    try {
      if (await store.readSecret('sessionid') != null) await store.writeSecret('sessionid', null);
      if (store.getJson<bool>('connected') != null) await store.setJson('connected', null);
    } catch (_) {}
  }

  void open(BuildContext context, String url) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => InstagramPage(module: this, url: url),
    ),
  );

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'instagram_ouvrir',
      description:
          'Ouvre le vrai Instagram dans Mon Hub : page = fil, reels, messages ou explorer, ou le profil de quelqu\'un '
          '(nom). Nexo ne lit et n\'envoie jamais de messages Instagram lui-même (Instagram l\'interdit) : la '
          'personne le fait dans la page.',
      params: {
        'page': ('string', 'fil, reels, messages ou explorer'),
        'nom': ('string', 'nom d\'utilisateur pour ouvrir un profil (facultatif)'),
      },
      run: (a) async {
        final ctx = await hubDialogContext();
        if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
        final url = urlFor('${a['page'] ?? ''}', name: '${a['nom'] ?? ''}');
        open(ctx, url);
        return {'ok': true, 'ouvert': url};
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) =>
      DesktopWidgets.inWidgetWindow ? InstagramMini(module: this) : _InstagramSummary(module: this);

  @override
  Widget buildPage(BuildContext context) => InstagramPage(module: this, url: home);
}

const _instaGradient = LinearGradient(
  begin: Alignment.bottomLeft,
  end: Alignment.topRight,
  colors: [Color(0xFFFEDA75), Color(0xFFFA7E1E), Color(0xFFD62976), Color(0xFF962FBF), Color(0xFF4F5BD5)],
);

/// La carte de l'accueil : quatre portes vers le vrai Instagram.
class _InstagramSummary extends StatelessWidget {
  const _InstagramSummary({required this.module});
  final InstagramModule module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: LayoutBuilder(
        builder: (context, box) {
          final size = (box.maxWidth / 4 - 14).clamp(44, 68).toDouble();
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final (label, icon, url) in InstagramModule.places)
                    InkWell(
                      borderRadius: BorderRadius.circular(size),
                      onTap: () => module.open(context, url),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: size,
                            height: size,
                            padding: const EdgeInsets.all(2.5),
                            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: _instaGradient),
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.surface),
                              child: Icon(icon, color: module.color, size: size * 0.42),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(label, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                ],
              ),
              if (box.maxHeight > 150) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified_user_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Le vrai Instagram, sans risque pour ton compte',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Le vrai instagram.com en grand.
class InstagramPage extends StatefulWidget {
  const InstagramPage({super.key, required this.module, required this.url});
  final InstagramModule module;
  final String url;

  @override
  State<InstagramPage> createState() => _InstagramPageState();
}

class _InstagramPageState extends State<InstagramPage> {
  InAppWebViewController? _c;

  void _go(String url) => _c?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  @override
  void dispose() {
    // Tu viens peut-être de te connecter ici : la veille des messages (page
    // cachée) se recharge pour en profiter.
    final w = InstagramWatch.instance;
    if (w.active && w.loggedOut) unawaited(w.reload());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(m.icon, color: m.color),
            const SizedBox(width: 10),
            const Text('Instagram'),
          ],
        ),
        actions: [
          // Le flou de la caméra pour les appels Instagram (choisi avant
          // l'appel, ou changé en plein appel).
          ListenableBuilder(
            listenable: CamBlur.instance,
            builder: (context, _) => PopupMenuButton<String>(
              tooltip: 'Flou de la caméra : ${CamBlur.label(CamBlur.instance.mode)}',
              icon: Icon(CamBlur.instance.mode == 'non' ? Icons.blur_off_rounded : Icons.blur_on_rounded),
              initialValue: CamBlur.instance.mode,
              onSelected: (m) async {
                await CamBlur.instance.setMode(m);
                await _c?.evaluateJavascript(source: CamBlur.liveScript(m));
              },
              itemBuilder: (_) => [for (final m in CamBlur.modes) PopupMenuItem(value: m, child: Text(CamBlur.label(m)))],
            ),
          ),
          for (final (label, icon, url) in InstagramModule.places)
            IconButton(tooltip: label, icon: Icon(icon), onPressed: () => _go(url)),
          IconButton(
            tooltip: 'Ouvrir dans le navigateur',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () async => Browser.open('${await _c?.getUrl() ?? widget.url}'),
          ),
        ],
      ),
      body: HubWebView(
        url: widget.url,
        onController: (c) => _c = c,
        // Le flou de la caméra, mis avant Instagram (dans la page et dans la
        // fenêtre d'appel), comme pour le Discord intégré.
        userScripts: () => [
          UserScript(
            source: CamBlur.script(CamBlur.instance.mode),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ],
        onTitleChanged: (t) {
          final n = InstagramModule.unreadFromTitle(t);
          if (n != null || (t ?? '').trim() == 'Instagram') m.badge.value = n ?? 0;
        },
      ),
    );
  }
}

/// Le vrai Instagram dans le widget du bureau (on y regarde ses reels).
class InstagramMini extends StatefulWidget {
  const InstagramMini({super.key, required this.module});
  final InstagramModule module;

  @override
  State<InstagramMini> createState() => _InstagramMiniState();
}

class _InstagramMiniState extends State<InstagramMini> {
  InAppWebViewController? _c;

  void _go(String url) => _c?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Retour',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                onPressed: () async {
                  if (await _c?.canGoBack() ?? false) await _c?.goBack();
                },
              ),
              const Spacer(),
              for (final (label, icon, url) in InstagramModule.places)
                IconButton(
                  tooltip: label,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(icon, size: 18, color: m.color),
                  onPressed: () => _go(url),
                ),
            ],
          ),
        ),
        Expanded(
          child: HubWebView(url: InstagramModule.places[1].$3, onController: (c) => _c = c),
        ),
      ],
    );
  }
}
