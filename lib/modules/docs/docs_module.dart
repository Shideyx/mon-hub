import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/browser.dart';
import '../../core/google_auth.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/google_setup.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';
import 'doc_format.dart';
import 'docs_store.dart';

/// Tes Google Docs, par l'API du Drive (liste, lecture, création, export)
/// et l'API Docs (ajout de texte à la fin).
class GoogleDocs {
  GoogleDocs._();

  static const docMime = 'application/vnd.google-apps.document';
  static const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

  /// L'accueil de Google Docs (tes documents, les modèles).
  static const home = 'https://docs.google.com/document/u/0/';

  /// Un nouveau document vierge.
  static const blank = 'https://docs.google.com/document/create';

  static String edit(String id) => 'https://docs.google.com/document/d/$id/edit';

  /// La connexion Google (API) est prête : Smily peut lire et écrire.
  static bool get connected => GoogleAuth.available && GoogleAuth.driveAccount != null;

  static String account() {
    final a = GoogleAuth.available ? GoogleAuth.driveAccount : null;
    if (a == null) {
      throw 'Pour que je lise et écrive dans tes Google Docs, connecte ton compte Google : Réglages → Connexion Google';
    }
    return a;
  }

  static String _q(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  /// Tes Google Docs, les plus récents d'abord.
  static Future<List<Map<String, dynamic>>> list({String search = '', int size = 40}) async {
    final q = [
      "mimeType='$docMime'",
      'trashed=false',
      if (search.trim().isNotEmpty) "name contains '${_q(search.trim())}'",
    ].join(' and ');
    final url = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': q,
      'orderBy': 'modifiedTime desc',
      'pageSize': '$size',
      'fields': 'files(id,name,modifiedTime,thumbnailLink)',
    });
    final j = await GoogleAuth.api(account(), 'GET', '$url');
    return [for (final f in (j['files'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
  }

  /// Retrouve un Google Doc par son id ou son titre.
  static Future<Map<String, dynamic>> find(String idOrTitle) async {
    final v = idOrTitle.trim();
    if (RegExp(r'^[A-Za-z0-9_-]{25,}$').hasMatch(v)) {
      final j = await GoogleAuth.api(account(), 'GET', 'https://www.googleapis.com/drive/v3/files/$v?fields=id,name');
      return j;
    }
    final found = await list(search: v, size: 5);
    if (found.isEmpty) throw 'Je ne trouve pas de Google Doc « $v »';
    return found.first;
  }

  /// Le texte d'un Google Doc (en Markdown si Google le permet).
  static Future<String> text(String id) async {
    for (final mime in const ['text/markdown', 'text/plain']) {
      try {
        final bytes = await GoogleAuth.bytes(
          account(),
          'https://www.googleapis.com/drive/v3/files/$id/export?mimeType=${Uri.encodeQueryComponent(mime)}',
        );
        return utf8.decode(bytes, allowMalformed: true);
      } catch (e) {
        if (mime == 'text/plain') rethrow;
      }
    }
    return '';
  }

  /// Crée un Google Doc à partir de texte Markdown (titres, gras, listes…).
  /// Renvoie son id.
  static Future<String> create(String title, String markdown) async {
    final j = await GoogleAuth.upload(
      account(),
      name: title,
      data: DocFormat.toDocx(DocFormat.fromMarkdown(markdown), title: title),
      mime: docxMime,
      convertTo: docMime,
    );
    return '${j['id']}';
  }

  /// Remplace tout le contenu.
  static Future<void> replace(String id, String markdown) async {
    await GoogleAuth.upload(
      account(),
      id: id,
      name: '',
      data: DocFormat.toDocx(DocFormat.fromMarkdown(markdown)),
      mime: docxMime,
    );
  }

  /// Ajoute du texte à la fin (API Docs ; sinon on réécrit le document).
  static Future<void> append(String id, String markdown) async {
    final plain = DocFormat.plain(DocFormat.fromMarkdown(markdown));
    final acc = account();
    try {
      await GoogleAuth.api(
        acc,
        'POST',
        'https://docs.googleapis.com/v1/documents/$id:batchUpdate',
        body: {
          'requests': [
            {
              'insertText': {'endOfSegmentLocation': <String, dynamic>{}, 'text': '\n$plain'},
            },
          ],
        },
      );
    } catch (_) {
      // L'API Docs n'est pas activée : on relit le document et on le
      // renvoie avec la suite.
      final before = DocFormat.fromDocx(await export(id, 'docx'));
      final ops = DocFormat.ops([...DocFormat.lines(before), ...DocFormat.lines(DocFormat.fromMarkdown(markdown))]);
      await GoogleAuth.upload(acc, id: id, name: '', data: DocFormat.toDocx(ops), mime: docxMime);
    }
  }

  /// Le document en fichier Word ou PDF.
  static Future<Uint8List> export(String id, String format) => GoogleAuth.bytes(
    account(),
    'https://www.googleapis.com/drive/v3/files/$id/export?mimeType=${Uri.encodeQueryComponent(format == 'pdf' ? 'application/pdf' : docxMime)}',
  );

  /// La miniature d'un document (lien de Google, valable quelques heures).
  static Future<Uint8List?> thumbnail(String? link) async {
    if (link == null || link.isEmpty) return null;
    try {
      final r = await http.get(Uri.parse(link)).timeout(const Duration(seconds: 10));
      return r.statusCode == 200 ? r.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }
}

/// Documents : **le vrai Google Docs**, avec ton Drive, dans Mon Hub (et
/// Smily qui peut créer, lire, compléter et exporter tes Google Docs).
class DocsModule extends HubModule {
  @override
  String get id => 'documents';
  @override
  String get name => 'Documents';
  @override
  String get description => 'Google Docs, avec ton Drive, dans Mon Hub';
  @override
  IconData get icon => Icons.description_rounded;
  @override
  Color get color => const Color(0xFF1A73E8);
  @override
  ApiAccess get access => ApiAccess.official;

  /// Google Docs s'ouvre dans sa propre fenêtre (Chrome ou Edge en mode
  /// appli) plutôt que dans Mon Hub : plus fluide, aucun souci de clic.
  bool get ownWindow => store.getJson<bool>('window') == true;
  Future<void> setOwnWindow(bool v) async {
    await store.setJson('window', v);
    store.changed();
  }

  /// Ouvre Google Docs (un document, l'accueil, un nouveau) dans Mon Hub.
  Future<void> open(BuildContext? context, String url) async {
    if (ownWindow && webLoginSupported && await Browser.openAppWindow(url)) return;
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    if (!webLoginSupported) {
      await Browser.open(url);
      return;
    }
    unawaited(
      Navigator.push(
        ctx,
        MaterialPageRoute<void>(
          builder: (_) => GoogleDocsPage(module: this, url: url),
        ),
      ),
    );
  }

  static Future<Directory> exportFolder() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}Mon Hub');
    await d.create(recursive: true);
    return d;
  }

  static String safeName(String t) {
    final s = t.replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ').trim();
    return s.isEmpty ? 'Document' : (s.length > 80 ? s.substring(0, 80) : s);
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'doc_nouveau',
      description: 'Ouvre un nouveau Google Doc vierge dans Mon Hub (ou l\'accueil de Google Docs avec accueil=true).',
      params: {'accueil': ('boolean', 'Ouvrir la liste des documents plutôt qu\'un document vierge')},
      run: (a) async {
        await open(null, a['accueil'] == true ? GoogleDocs.home : GoogleDocs.blank);
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'doc_lister',
      description: 'Liste tes Google Docs (id, titre, date), les plus récents d\'abord.',
      params: {'recherche': ('string', 'Mot du titre (facultatif)')},
      run: (a) async => [
        for (final f in await GoogleDocs.list(search: '${a['recherche'] ?? ''}', size: 25))
          {'id': f['id'], 'titre': f['name'], 'modifie': f['modifiedTime']},
      ],
    ),
    HubTool(
      name: 'doc_lire',
      description: 'Lit un Google Doc (texte).',
      params: {'id': ('string', 'id ou titre du Google Doc')},
      required: ['id'],
      run: (a) async {
        final f = await GoogleDocs.find('${a['id']}');
        final t = await GoogleDocs.text('${f['id']}');
        return {'titre': f['name'], 'contenu': t.length > 40000 ? '${t.substring(0, 40000)}…' : t};
      },
    ),
    HubTool(
      name: 'doc_creer',
      description:
          'Crée un Google Doc sur le Drive et l\'ouvre dans Mon Hub. Le contenu est en Markdown (# titres, **gras**, '
          '*italique*, listes - et 1., cases - [ ], > citation). Pour un exposé, une fiche, une lettre, un devoir…',
      params: {
        'titre': ('string', 'Titre du document'),
        'contenu': ('string', 'Texte en Markdown'),
        'ouvrir': ('boolean', 'Ouvrir le document à l\'écran (oui par défaut)'),
      },
      required: ['titre'],
      run: (a) async {
        final id = await GoogleDocs.create('${a['titre']}', '${a['contenu'] ?? ''}');
        if (a['ouvrir'] != false) await open(null, GoogleDocs.edit(id));
        return {'ok': true, 'id': id, 'lien': GoogleDocs.edit(id)};
      },
    ),
    HubTool(
      name: 'doc_ecrire',
      description: 'Ajoute du texte à la fin d\'un Google Doc, ou remplace tout son contenu (Markdown).',
      params: {
        'id': ('string', 'id ou titre du Google Doc'),
        'contenu': ('string', 'Texte en Markdown'),
        'mode': ('string', '« ajouter » (par défaut) ou « remplacer »'),
      },
      required: ['id', 'contenu'],
      run: (a) async {
        final f = await GoogleDocs.find('${a['id']}');
        if (a['mode'] == 'remplacer') {
          await GoogleDocs.replace('${f['id']}', '${a['contenu']}');
        } else {
          await GoogleDocs.append('${f['id']}', '${a['contenu']}');
        }
        return {'ok': true, 'titre': f['name']};
      },
    ),
    HubTool(
      name: 'doc_ouvrir',
      description: 'Ouvre un Google Doc dans Mon Hub.',
      params: {'id': ('string', 'id ou titre du Google Doc')},
      required: ['id'],
      run: (a) async {
        final f = await GoogleDocs.find('${a['id']}');
        await open(null, GoogleDocs.edit('${f['id']}'));
        return {'ok': true, 'titre': f['name']};
      },
    ),
    HubTool(
      name: 'doc_exporter',
      description: 'Enregistre un Google Doc en fichier Word (.docx) ou PDF dans Documents\\Mon Hub sur le PC.',
      params: {'id': ('string', 'id ou titre du Google Doc'), 'format': ('string', '« docx » ou « pdf »')},
      required: ['id'],
      run: (a) async {
        final f = await GoogleDocs.find('${a['id']}');
        final format = '${a['format'] ?? 'docx'}'.toLowerCase().contains('pdf') ? 'pdf' : 'docx';
        final dir = await exportFolder();
        final out = File('${dir.path}${Platform.pathSeparator}${safeName('${f['name']}')}.$format');
        await out.writeAsBytes(await GoogleDocs.export('${f['id']}', format));
        return {'ok': true, 'chemin': out.path};
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => _DocsSummary(module: this);

  @override
  Widget buildPage(BuildContext context) => GoogleDocsPage(module: this, url: GoogleDocs.home);
}

/// La carte de l'accueil : un nouveau document, et les Google Docs récents
/// en miniatures.
class _DocsSummary extends StatefulWidget {
  const _DocsSummary({required this.module});
  final DocsModule module;

  @override
  State<_DocsSummary> createState() => _DocsSummaryState();
}

class _DocsSummaryState extends State<_DocsSummary> {
  static Future<List<Map<String, dynamic>>>? _recent;
  static DateTime? _at;

  Future<List<Map<String, dynamic>>> _load() {
    if (!GoogleDocs.connected) return Future.value(const []);
    final fresh = _at != null && DateTime.now().difference(_at!).inMinutes < 3;
    if (_recent != null && fresh) return _recent!;
    _at = DateTime.now();
    return _recent = GoogleDocs.list(size: 10).catchError((Object _) => <Map<String, dynamic>>[]);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        final docs = snap.data ?? const [];
        return LayoutBuilder(
          builder: (context, box) {
            final h = box.maxHeight - 34;
            final w = (h * 0.75).clamp(70, 150).toDouble();
            Widget tile(String label, String sub, Widget child, VoidCallback onTap) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: SizedBox(
                  width: w,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: child),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
              ),
            );
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 2, 10),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  tile(
                    'Nouveau',
                    'document',
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: LinearGradient(
                          colors: [m.color, Color.lerp(m.color, const Color(0xFF7C5CFF), 0.5)!],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Center(child: Icon(Icons.add_rounded, color: Colors.white, size: 40)),
                    ),
                    () => m.open(context, GoogleDocs.blank),
                  ),
                  if (docs.isEmpty)
                    tile(
                      'Mes documents',
                      'Google Docs',
                      Container(
                        decoration: BoxDecoration(
                          color: m.color.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: m.color.withValues(alpha: 0.3)),
                        ),
                        child: Center(child: Icon(Icons.folder_open_rounded, color: m.color, size: 38)),
                      ),
                      () => m.open(context, GoogleDocs.home),
                    ),
                  for (final d in docs)
                    tile(
                      '${d['name']}',
                      timeAgo(DateTime.tryParse('${d['modifiedTime']}')?.toLocal() ?? DateTime.now()),
                      _Thumb(link: d['thumbnailLink'] as String?, color: m.color),
                      () => m.open(context, GoogleDocs.edit('${d['id']}')),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// La miniature d'un Google Doc (page blanche si elle n'arrive pas).
class _Thumb extends StatelessWidget {
  const _Thumb({required this.link, required this.color});
  final String? link;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final blank = Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
      child: Center(child: Icon(Icons.description_rounded, color: color.withValues(alpha: 0.5), size: 34)),
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x1F000000)),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 3))],
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder(
        future: GoogleDocs.thumbnail(link),
        builder: (context, snap) =>
            snap.data == null ? blank : Image.memory(snap.data!, fit: BoxFit.cover, alignment: Alignment.topCenter),
      ),
    );
  }
}

/// Le vrai Google Docs dans Mon Hub (ton compte Google, tes documents,
/// tous les outils de Google : mise en page, commentaires, partage…), ou
/// dans sa propre fenêtre si tu préfères (plus fluide).
class GoogleDocsPage extends StatefulWidget {
  const GoogleDocsPage({super.key, required this.module, required this.url});
  final DocsModule module;
  final String url;

  @override
  State<GoogleDocsPage> createState() => _GoogleDocsPageState();
}

class _GoogleDocsPageState extends State<GoogleDocsPage> {
  InAppWebViewController? _c;
  late bool _window = widget.module.ownWindow && webLoginSupported;
  bool _tipClosed = false;

  DocsModule get m => widget.module;

  @override
  void initState() {
    super.initState();
    if (_window) unawaited(Browser.openAppWindow(widget.url));
  }

  Future<void> _go(String url) async {
    if (_window) {
      await Browser.openAppWindow(url);
      return;
    }
    await _c?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// Passe le document ouvert dans sa propre fenêtre.
  Future<void> _popOut({bool always = false}) async {
    final url = '${await _c?.getUrl() ?? widget.url}';
    if (always) await m.setOwnWindow(true);
    final ok = await Browser.openAppWindow(url);
    if (!mounted) return;
    if (!ok) {
      showError(context, 'Impossible d\'ouvrir une fenêtre Chrome ou Edge');
      return;
    }
    if (always) {
      setState(() => _window = true);
    } else {
      Navigator.maybePop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.description_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            const Text('Google Docs'),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nouveau'),
            onPressed: () => _go(GoogleDocs.blank),
          ),
          IconButton(
            tooltip: 'Mes documents',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: () => _go(GoogleDocs.home),
          ),
          if (!_window) ...[
            IconButton(tooltip: 'Recharger', icon: const Icon(Icons.refresh_rounded), onPressed: () => _c?.reload()),
            IconButton(
              tooltip: 'Ouvrir dans sa propre fenêtre (plus fluide)',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: _popOut,
            ),
          ],
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          const _OldDocsBanner(),
          if (!_window && !_tipClosed && webLoginSupported)
            Material(
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                child: Row(
                  children: [
                    const Icon(Icons.speed_rounded, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Ça rame ou les clics ne répondent pas bien ? Google Docs marche mieux dans sa propre fenêtre.',
                      ),
                    ),
                    TextButton(onPressed: () => _popOut(always: true), child: const Text('Toujours en fenêtre')),
                    IconButton(
                      tooltip: 'Fermer',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(() => _tipClosed = true),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: !webLoginSupported
                ? EmptyHint(
                    'Google Docs s\'ouvre dans ton navigateur sur cet appareil.',
                    icon: Icons.description_rounded,
                    action: ('Ouvrir Google Docs', () => Browser.open(widget.url)),
                  )
                : _window
                ? _WindowMode(
                    onReopen: () => Browser.openAppWindow(widget.url),
                    onInside: () async {
                      await m.setOwnWindow(false);
                      if (mounted) setState(() => _window = false);
                    },
                  )
                : HubWebView(
                    url: widget.url,
                    desktopUserAgent: true,
                    // Le bouton flottant cachait « Partager » de Google
                    // Docs : « Recharger » est dans la barre du haut.
                    reloadButton: false,
                    sameSiteInPlace: true,
                    onController: (c) => _c = c,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Google Docs est ouvert dans sa propre fenêtre.
class _WindowMode extends StatelessWidget {
  const _WindowMode({required this.onReopen, required this.onInside});
  final VoidCallback onReopen;
  final VoidCallback onInside;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new_rounded, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('Google Docs est ouvert dans sa propre fenêtre', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'C\'est le vrai Google Docs, dans Chrome (ou Edge) : rapide, et tous les clics marchent.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.description_rounded),
                  label: const Text('Rouvrir la fenêtre'),
                  onPressed: onReopen,
                ),
                OutlinedButton(onPressed: onInside, child: const Text('Plutôt dans Mon Hub')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Les documents de l'ancien Word de Mon Hub (v1.37) : on propose de les
/// envoyer sur Google Docs, ou de les enregistrer en .docx.
class _OldDocsBanner extends StatefulWidget {
  const _OldDocsBanner();

  @override
  State<_OldDocsBanner> createState() => _OldDocsBannerState();
}

class _OldDocsBannerState extends State<_OldDocsBanner> {
  bool busy = false;

  Future<void> _move({required bool google}) async {
    final store = DocStore.instance;
    setState(() => busy = true);
    var n = 0;
    try {
      final dir = google
          ? null
          : Directory('${(await DocsModule.exportFolder()).path}${Platform.pathSeparator}Anciens documents');
      await dir?.create(recursive: true);
      for (final d in [...store.docs]) {
        final ops = await store.read(d.id);
        if (google) {
          await GoogleDocs.create(d.title, DocFormat.toMarkdown(ops));
        } else {
          await File('${dir!.path}${Platform.pathSeparator}${DocsModule.safeName(d.title)}.docx')
              .writeAsBytes(DocFormat.toDocx(ops, title: d.title));
        }
        await store.delete(d.id);
        n++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              google
                  ? '$n document${n > 1 ? 's' : ''} envoyé${n > 1 ? 's' : ''} sur Google Docs'
                  : '$n document${n > 1 ? 's' : ''} enregistré${n > 1 ? 's' : ''} dans ${dir!.path}',
            ),
            action: dir == null
                ? null
                : SnackBarAction(label: 'Ouvrir', onPressed: () => Browser.open(dir.uri.toString())),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    // Lu une seule fois (avant : relu à chaque redessin de la page).
    unawaited(DocStore.instance.load());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: DocStore.instance,
    builder: (context, _) {
      final n = DocStore.instance.docs.length;
      if (n == 0) return const SizedBox.shrink();
      return MaterialBanner(
        leading: const Icon(Icons.history_edu_rounded),
        content: Text('Tu as $n document${n > 1 ? 's' : ''} de l\'ancien Word de Mon Hub.'),
        actions: [
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          TextButton(
            onPressed: busy ? null : () => _move(google: false),
            child: const Text('Les enregistrer en .docx'),
          ),
          if (GoogleDocs.connected)
            FilledButton(
              onPressed: busy ? null : () => _move(google: true),
              child: const Text('Les envoyer sur Google Docs'),
            )
          else
            TextButton(onPressed: () => GoogleSetupPage.open(context), child: const Text('Connecter Google')),
        ],
      );
    },
  );
}
