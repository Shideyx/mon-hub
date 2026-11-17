import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/ai_text.dart';
import '../../core/browser.dart';
import '../../core/google_auth.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'doc_format.dart';
import 'doc_pdf.dart';
import 'docs_store.dart';

/// Google Docs, par le Drive : ouvrir un Google Doc dans le Word de Mon Hub
/// (il arrive en .docx) et l'y renvoyer.
class GoogleDocs {
  GoogleDocs._();

  static const docMime = 'application/vnd.google-apps.document';
  static const docxMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

  static String get account {
    final a = GoogleAuth.driveAccount;
    if (a == null) throw 'Connecte ton compte Google (module Drive, ou Clicky te le propose au démarrage)';
    return a;
  }

  /// Tes Google Docs, les plus récents d'abord.
  static Future<List<Map<String, dynamic>>> list({String search = ''}) async {
    final q = [
      "mimeType='$docMime'",
      'trashed=false',
      if (search.trim().isNotEmpty) "name contains '${search.trim().replaceAll("'", r"\'")}'",
    ].join(' and ');
    final url = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': q,
      'orderBy': 'modifiedTime desc',
      'pageSize': '40',
      'fields': 'files(id,name,modifiedTime,webViewLink)',
    });
    final j = await GoogleAuth.api(account, 'GET', '$url');
    return [for (final f in (j['files'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
  }

  static Future<List<dynamic>> download(String id) async {
    final bytes = await GoogleAuth.bytes(
      account,
      'https://www.googleapis.com/drive/v3/files/$id/export?mimeType=${Uri.encodeQueryComponent(docxMime)}',
    );
    return DocFormat.fromDocx(bytes);
  }

  /// Envoie le document sur Google Docs (le met à jour s'il y est déjà).
  /// Renvoie (id, lien).
  static Future<(String, String)> upload(String title, List<dynamic> ops, {String? id}) async {
    final data = DocFormat.toDocx(ops, title: title);
    Map<String, dynamic> j;
    try {
      j = await GoogleAuth.upload(account, name: title, data: data, mime: docxMime, id: id, convertTo: docMime);
    } catch (e) {
      // Le Google Doc d'origine a été supprimé ou n'est plus accessible : on
      // en crée un nouveau.
      if (id == null) rethrow;
      j = await GoogleAuth.upload(account, name: title, data: data, mime: docxMime, convertTo: docMime);
    }
    final newId = '${j['id']}';
    return (newId, '${j['webViewLink'] ?? 'https://docs.google.com/document/d/$newId/edit'}');
  }
}

/// Des modèles prêts à remplir.
class DocTemplate {
  const DocTemplate(this.name, this.icon, this.color, this.markdown);
  final String name;
  final IconData icon;
  final Color color;
  final String markdown;

  static const all = [
    DocTemplate('Vierge', Icons.note_add_rounded, Color(0xFF2B579A), ''),
    DocTemplate(
      'Fiche de révision',
      Icons.style_rounded,
      Color(0xFF7C5CFF),
      '# Chapitre : \n\n## L\'essentiel en 3 phrases\n- \n- \n- \n\n## Définitions\n- **Mot** : définition\n\n'
          '## À retenir par cœur\n- [ ] \n- [ ] \n\n## Exemples\n1. \n\n## Questions pour me tester\n1. \n2. \n',
    ),
    DocTemplate(
      'Exposé',
      Icons.co_present_rounded,
      Color(0xFFE67E22),
      '# Titre de l\'exposé\n\n*Prénom Nom — Classe — Date*\n\n## Introduction\nAccroche, présentation du sujet, problématique, annonce du plan.\n\n'
          '## I. Première partie\n\n## II. Deuxième partie\n\n## III. Troisième partie\n\n## Conclusion\nRéponse à la problématique, ouverture.\n\n## Sources\n- \n',
    ),
    DocTemplate(
      'Dissertation',
      Icons.history_edu_rounded,
      Color(0xFF8E44AD),
      '# Sujet : \n\n## Introduction\n**Accroche** : \n\n**Définition des termes** : \n\n**Problématique** : \n\n**Annonce du plan** : \n\n'
          '## I. Thèse\n### A. \n### B. \n\n## II. Antithèse\n### A. \n### B. \n\n## III. Synthèse / dépassement\n### A. \n### B. \n\n'
          '## Conclusion\nBilan, réponse, ouverture.\n',
    ),
    DocTemplate(
      'Compte rendu de TP',
      Icons.science_rounded,
      Color(0xFF16A085),
      '# Compte rendu de TP : \n\n## Objectif\n\n## Matériel\n- \n\n## Protocole\n1. \n2. \n\n## Résultats\n\n## Interprétation\n\n## Conclusion\n',
    ),
    DocTemplate(
      'Lettre',
      Icons.mail_rounded,
      Color(0xFFC0392B),
      'Prénom Nom\nAdresse\n\nÀ l\'attention de \n\nObjet : \n\nMadame, Monsieur,\n\n\n\nVeuillez agréer, Madame, Monsieur, l\'expression de mes salutations distinguées.\n\nSignature\n',
    ),
  ];
}

/// Documents : un **Word complet dans Mon Hub** (mise en page, styles,
/// listes, images…), Word (.docx) et PDF, tes Google Docs, et Clicky qui
/// écrit, corrige et résume avec toi. Les documents restent chiffrés sur
/// l'appareil.
class DocsModule extends HubModule {
  @override
  String get id => 'documents';
  @override
  String get name => 'Documents';
  @override
  String get description => 'Ton Word : écris, mets en page, exporte, avec Clicky';
  @override
  IconData get icon => Icons.description_rounded;
  @override
  Color get color => const Color(0xFF2B579A);
  @override
  ApiAccess get access => ApiAccess.local;

  final docs = DocStore.instance;

  /// Ouvre un document dans le Word de Mon Hub.
  Future<void> open(BuildContext? context, String docId) async {
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    unawaited(
      Navigator.push(
        ctx,
        MaterialPageRoute<void>(builder: (_) => DocEditorPage(module: this, docId: docId)),
      ),
    );
  }

  Future<HubDoc> newDoc(BuildContext? context, {DocTemplate? template, String? title}) async {
    final d = await docs.create(
      title: title ?? (template == null || template.markdown.isEmpty ? 'Sans titre' : template.name),
      ops: template == null || template.markdown.isEmpty ? null : DocFormat.fromMarkdown(template.markdown),
    );
    if (context != null && context.mounted) await open(context, d.id);
    return d;
  }

  /// Ouvre un fichier Word (.docx) du PC.
  Future<void> importDocx(BuildContext context) async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Documents Word', extensions: ['docx']),
      ],
    );
    if (f == null) return;
    try {
      final ops = DocFormat.fromDocx(await f.readAsBytes());
      final d = await docs.create(title: f.name.replaceAll(RegExp(r'\.docx$', caseSensitive: false), ''), ops: ops);
      if (context.mounted) await open(context, d.id);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  /// Dossier où Clicky range les fichiers exportés : Documents\Mon Hub.
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

  /// Fabrique le fichier (Word ou PDF) d'un document.
  static Future<Uint8List> fileFor(HubDoc d, List<dynamic> ops, String format) async =>
      format == 'pdf' ? await DocPdf.build(ops, title: d.title) : DocFormat.toDocx(ops, title: d.title);

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'doc_lister',
      description: 'Liste les documents du Word de Mon Hub (id, titre, nombre de mots, date).',
      run: (_) async => [
        for (final d in await docs.load())
          {'id': d.id, 'titre': d.title, 'mots': d.words, 'modifie': d.updated, if (d.googleId != null) 'google_docs': true},
      ],
    ),
    HubTool(
      name: 'doc_lire',
      description: 'Lit un document du Word de Mon Hub (en Markdown).',
      params: {'id': ('string', 'id ou titre du document')},
      required: ['id'],
      run: (a) async {
        await docs.load();
        final d = docs.find('${a['id']}');
        if (d == null) throw 'Document introuvable';
        return {'titre': d.title, 'contenu': DocFormat.toMarkdown(await docs.read(d.id))};
      },
    ),
    HubTool(
      name: 'doc_creer',
      description:
          'Crée un document dans le Word de Mon Hub et l\'ouvre à l\'écran. Le contenu est en Markdown '
          '(# titres, **gras**, *italique*, listes - et 1., cases - [ ], > citation). Pour un exposé, une fiche, '
          'une lettre, un devoir à rédiger…',
      params: {
        'titre': ('string', 'Titre du document'),
        'contenu': ('string', 'Texte en Markdown'),
        'ouvrir': ('boolean', 'Ouvrir le document à l\'écran (oui par défaut)'),
      },
      required: ['titre'],
      run: (a) async {
        final d = await docs.create(
          title: '${a['titre']}',
          ops: DocFormat.fromMarkdown('${a['contenu'] ?? ''}'),
        );
        if (a['ouvrir'] != false) await open(null, d.id);
        return {'ok': true, 'id': d.id};
      },
    ),
    HubTool(
      name: 'doc_ecrire',
      description: 'Ajoute du texte à la fin d\'un document, ou remplace tout son contenu (Markdown).',
      params: {
        'id': ('string', 'id ou titre du document'),
        'contenu': ('string', 'Texte en Markdown'),
        'mode': ('string', '« ajouter » (par défaut) ou « remplacer »'),
      },
      required: ['id', 'contenu'],
      run: (a) async {
        await docs.load();
        final d = docs.find('${a['id']}');
        if (d == null) throw 'Document introuvable';
        final add = DocFormat.fromMarkdown('${a['contenu']}');
        final ops = a['mode'] == 'remplacer'
            ? add
            : DocFormat.ops([...DocFormat.lines(await docs.read(d.id)), ...DocFormat.lines(add)]);
        await docs.write(d.id, ops);
        DocEditorPage.reload(d.id);
        return {'ok': true, 'mots': DocFormat.words(ops)};
      },
    ),
    HubTool(
      name: 'doc_ouvrir',
      description: 'Ouvre un document du Word de Mon Hub à l\'écran.',
      params: {'id': ('string', 'id ou titre du document')},
      required: ['id'],
      run: (a) async {
        await docs.load();
        final d = docs.find('${a['id']}');
        if (d == null) throw 'Document introuvable';
        await open(null, d.id);
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'doc_exporter',
      description: 'Enregistre un document en fichier Word (.docx) ou PDF dans Documents\\Mon Hub sur le PC.',
      params: {
        'id': ('string', 'id ou titre du document'),
        'format': ('string', '« docx » ou « pdf »'),
      },
      required: ['id'],
      run: (a) async {
        await docs.load();
        final d = docs.find('${a['id']}');
        if (d == null) throw 'Document introuvable';
        final format = '${a['format'] ?? 'docx'}'.toLowerCase().contains('pdf') ? 'pdf' : 'docx';
        final dir = await exportFolder();
        final f = File('${dir.path}${Platform.pathSeparator}${safeName(d.title)}.$format');
        await f.writeAsBytes(await fileFor(d, await docs.read(d.id), format));
        return {'ok': true, 'chemin': f.path};
      },
    ),
    HubTool(
      name: 'doc_google_docs',
      description: 'Envoie un document du Word de Mon Hub sur Google Docs (ou le met à jour) et donne le lien.',
      params: {'id': ('string', 'id ou titre du document')},
      required: ['id'],
      run: (a) async {
        await docs.load();
        final d = docs.find('${a['id']}');
        if (d == null) throw 'Document introuvable';
        final (gid, link) = await GoogleDocs.upload(d.title, await docs.read(d.id), id: d.googleId);
        await docs.linkGoogle(d.id, gid);
        return {'ok': true, 'lien': link};
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => _DocsSummary(module: this);

  @override
  Widget buildPage(BuildContext context) => DocsHomePage(module: this);
}

/// Une petite page blanche avec le début du texte (comme les aperçus de
/// Word).
class _MiniPage extends StatelessWidget {
  const _MiniPage({required this.doc, this.width = 110});
  final HubDoc doc;
  final double width;

  @override
  Widget build(BuildContext context) {
    final lines = doc.preview.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return Container(
      width: width,
      padding: EdgeInsets.all(width * 0.09),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x1F000000)),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lines.isNotEmpty)
              Text(
                lines.first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: width * 0.07,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2F5496),
                  height: 1.2,
                ),
              ),
            SizedBox(height: width * 0.04),
            Expanded(
              child: Text(
                lines.skip(1).join('\n'),
                overflow: TextOverflow.fade,
                style: TextStyle(fontSize: width * 0.05, color: const Color(0xFF404040), height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocsSummary extends StatelessWidget {
  const _DocsSummary({required this.module});
  final DocsModule module;

  @override
  Widget build(BuildContext context) {
    final store = module.docs;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => FutureBuilder(
        future: store.load(),
        initialData: store.docs,
        builder: (context, snap) {
          final list = snap.data ?? const <HubDoc>[];
          return LayoutBuilder(
            builder: (context, box) {
              final h = box.maxHeight - 34;
              final w = (h * 0.72).clamp(70, 140).toDouble();
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _NewTile(width: w, color: module.color, onTap: () => module.newDoc(context)),
                    for (final d in list.take(10))
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => module.open(context, d.id),
                          child: SizedBox(
                            width: w,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: _MiniPage(doc: d, width: w)),
                                const SizedBox(height: 6),
                                Text(
                                  d.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(timeAgo(d.updated), style: Theme.of(context).textTheme.labelSmall),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _NewTile extends StatelessWidget {
  const _NewTile({required this.width, required this.color, required this.onTap});
  final double width;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: width,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(
                  colors: [color, Color.lerp(color, const Color(0xFF7C5CFF), 0.5)!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(Icons.add_rounded, color: Colors.white, size: 38),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Nouveau',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text('document', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    ),
  );
}

/// La page du module : modèles, documents, Word et Google Docs.
class DocsHomePage extends StatefulWidget {
  const DocsHomePage({super.key, required this.module});
  final DocsModule module;

  @override
  State<DocsHomePage> createState() => _DocsHomePageState();
}

class _DocsHomePageState extends State<DocsHomePage> {
  String query = '';

  DocsModule get m => widget.module;

  Future<void> _menu(HubDoc d, String v) async {
    switch (v) {
      case 'rename':
        final r = await askFields(context, title: 'Renommer', labels: ['Titre'], initial: [d.title]);
        final t = r?.first.trim() ?? '';
        if (t.isNotEmpty) await m.docs.rename(d.id, t);
      case 'copy':
        await m.docs.duplicate(d.id);
      case 'docx' || 'pdf':
        await exportDoc(context, d, v);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Supprimer « ${d.title} » ?'),
            content: const Text('Le document sera effacé de Mon Hub.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Supprimer')),
            ],
          ),
        );
        if (ok == true) await m.docs.delete(d.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Documents'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.file_open_rounded),
            label: const Text('Ouvrir un Word'),
            onPressed: () => m.importDocx(context),
          ),
          TextButton.icon(
            icon: const Icon(Icons.cloud_rounded),
            label: const Text('Google Docs'),
            onPressed: () => showGoogleDocs(context, m),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: m.docs,
        builder: (context, _) => FutureBuilder(
          future: m.docs.load(),
          initialData: m.docs.docs,
          builder: (context, snap) {
            final q = query.toLowerCase();
            final list = (snap.data ?? const <HubDoc>[])
                .where((d) => q.isEmpty || d.title.toLowerCase().contains(q) || d.preview.toLowerCase().contains(q))
                .toList();
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text('Commencer', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 150,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      scrollDirection: Axis.horizontal,
                      itemCount: DocTemplate.all.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, i) {
                        final t = DocTemplate.all[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => m.newDoc(context, template: t),
                          child: Container(
                            width: 130,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              gradient: LinearGradient(
                                colors: [t.color.withValues(alpha: 0.22), t.color.withValues(alpha: 0.06)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              border: Border.all(color: t.color.withValues(alpha: 0.3)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(color: t.color, borderRadius: BorderRadius.circular(12)),
                                  child: Icon(t.icon, color: Colors.white),
                                ),
                                const Spacer(),
                                Text(t.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Row(
                      children: [
                        Text('Mes documents', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                        const Spacer(),
                        SizedBox(
                          width: 260,
                          child: TextField(
                            decoration: const InputDecoration(
                              isDense: true,
                              prefixIcon: Icon(Icons.search_rounded),
                              hintText: 'Chercher',
                            ),
                            onChanged: (v) => setState(() => query = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (list.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyHint(
                      'Aucun document pour l\'instant. Choisis un modèle au-dessus, ou dis à Clicky : '
                      '« écris-moi un exposé sur… ».',
                      icon: Icons.description_outlined,
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 190,
                        mainAxisExtent: 280,
                        crossAxisSpacing: 18,
                        mainAxisSpacing: 18,
                      ),
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final d = list[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => m.open(context, d.id),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _MiniPage(doc: d, width: 190)),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    d.googleId != null ? Icons.cloud_done_rounded : Icons.description_rounded,
                                    size: 16,
                                    color: m.color,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      d.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    padding: EdgeInsets.zero,
                                    iconSize: 18,
                                    onSelected: (v) => _menu(d, v),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'rename', child: Text('Renommer')),
                                      PopupMenuItem(value: 'copy', child: Text('Dupliquer')),
                                      PopupMenuItem(value: 'docx', child: Text('Enregistrer en Word (.docx)')),
                                      PopupMenuItem(value: 'pdf', child: Text('Enregistrer en PDF')),
                                      PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                                    ],
                                  ),
                                ],
                              ),
                              Text(
                                '${timeAgo(d.updated)} · ${d.words} mot${d.words > 1 ? 's' : ''}',
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Enregistre un document en Word ou PDF, là où tu veux sur le PC.
Future<void> exportDoc(BuildContext context, HubDoc d, String format, [List<dynamic>? ops]) async {
  final loc = await getSaveLocation(
    suggestedName: '${DocsModule.safeName(d.title)}.$format',
    acceptedTypeGroups: [
      format == 'pdf'
          ? const XTypeGroup(label: 'PDF', extensions: ['pdf'])
          : const XTypeGroup(label: 'Document Word', extensions: ['docx']),
    ],
  );
  if (loc == null) return;
  try {
    final data = await DocsModule.fileFor(d, ops ?? await DocStore.instance.read(d.id), format);
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.$format')) path = '$path.$format';
    await File(path).writeAsBytes(data);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enregistré : $path'),
          action: SnackBarAction(label: 'Ouvrir', onPressed: () => Browser.open(Uri.file(path).toString())),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Choisir un Google Doc à ouvrir dans le Word de Mon Hub.
Future<void> showGoogleDocs(BuildContext context, DocsModule m) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SizedBox(
      height: MediaQuery.of(c).size.height * 0.7,
      child: FutureBuilder(
        future: GoogleDocs.list(),
        builder: (c, snap) {
          if (snap.hasError) {
            return EmptyHint('${snap.error}', icon: Icons.cloud_off_rounded);
          }
          if (!snap.hasData) return const LoadingHint();
          final list = snap.data!;
          if (list.isEmpty) return const EmptyHint('Aucun Google Doc sur ton Drive');
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Ouvre un Google Doc dans le Word de Mon Hub. « Enregistrer sur Google Docs » le met à jour.'),
              ),
              for (final f in list)
                ListTile(
                  leading: const Icon(Icons.article_rounded, color: Color(0xFF4285F4)),
                  title: Text('${f['name']}'),
                  subtitle: Text(timeAgo(DateTime.tryParse('${f['modifiedTime']}')?.toLocal() ?? DateTime.now())),
                  onTap: () async {
                    Navigator.pop(c);
                    try {
                      final ops = await GoogleDocs.download('${f['id']}');
                      final d = await m.docs.create(title: '${f['name']}', ops: ops, googleId: '${f['id']}');
                      if (context.mounted) await m.open(context, d.id);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}

/// Les images du document (gardées dans le document lui-même).
class _ImageEmbed extends EmbedBuilder {
  const _ImageEmbed();

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final src = '${embedContext.node.value.data}';
    final m = RegExp(r'^data:image/[a-z+]+;base64,(.*)$', dotAll: true).firstMatch(src);
    final Widget image;
    if (m != null) {
      image = Image.memory(base64Decode(m.group(1)!.trim()), fit: BoxFit.contain);
    } else if (src.startsWith('http')) {
      image = Image.network(src, fit: BoxFit.contain);
    } else {
      image = Image.file(File(src), fit: BoxFit.contain);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 480), child: image),
    );
  }
}

/// Le Word de Mon Hub : une page blanche au centre, la barre d'outils
/// complète, Clicky pour écrire avec toi, et l'enregistrement automatique.
class DocEditorPage extends StatefulWidget {
  const DocEditorPage({super.key, required this.module, required this.docId});
  final DocsModule module;
  final String docId;

  static final _open = <String, _DocEditorPageState>{};

  /// Le document a changé ailleurs (Clicky) : on recharge la page ouverte.
  static void reload(String id) => _open[id]?._reload();

  @override
  State<DocEditorPage> createState() => _DocEditorPageState();
}

class _DocEditorPageState extends State<DocEditorPage> {
  QuillController? _c;
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _title = TextEditingController();
  StreamSubscription<dynamic>? _changes;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _saving = false;
  bool _busy = false;
  double _zoom = 1;
  int _words = 0;

  HubDoc? get doc => DocStore.instance.byId(widget.docId);

  static const _fonts = {
    'Calibri': 'Calibri',
    'Arial': 'Arial',
    'Times New Roman': 'Times New Roman',
    'Georgia': 'Georgia',
    'Verdana': 'Verdana',
    'Segoe UI': 'Segoe UI',
    'Comic Sans MS': 'Comic Sans MS',
    'Courier New': 'Courier New',
    'Par défaut': 'Clear',
  };

  static const _sizes = {
    '8': '8',
    '9': '9',
    '10': '10',
    '11': '11',
    '12': '12',
    '14': '14',
    '16': '16',
    '18': '18',
    '20': '20',
    '24': '24',
    '28': '28',
    '32': '32',
    '36': '36',
    '48': '48',
    '72': '72',
    'Par défaut': '0',
  };

  @override
  void initState() {
    super.initState();
    DocEditorPage._open[widget.docId] = this;
    _load();
  }

  Future<void> _load() async {
    await DocStore.instance.load();
    final ops = await DocStore.instance.read(widget.docId);
    if (!mounted) return;
    _title.text = doc?.title ?? 'Sans titre';
    final c = QuillController(
      document: _document(ops),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _changes = c.document.changes.listen((_) => _changed());
    setState(() {
      _c = c;
      _words = DocFormat.words(ops);
    });
  }

  static Document _document(List<dynamic> ops) {
    try {
      return Document.fromJson(ops);
    } catch (_) {
      return Document()..insert(0, DocFormat.plain(ops));
    }
  }

  Future<void> _reload() async {
    final c = _c;
    if (c == null) return;
    final ops = await DocStore.instance.read(widget.docId);
    await _changes?.cancel();
    c.document = _document(ops);
    _changes = c.document.changes.listen((_) => _changed());
    if (mounted) setState(() => _words = DocFormat.words(ops));
  }

  void _changed() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
    if (mounted) setState(() {});
  }

  List<dynamic> get _ops => _c?.document.toDelta().toJson() ?? const [];

  Future<void> _save() async {
    final c = _c;
    if (c == null || (!_dirty && _title.text == doc?.title)) return;
    _saving = true;
    final ops = _ops;
    _dirty = false;
    await DocStore.instance.write(widget.docId, ops, title: _title.text);
    _saving = false;
    if (mounted) setState(() => _words = DocFormat.words(ops));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty || _title.text != doc?.title) unawaited(_save());
    if (DocEditorPage._open[widget.docId] == this) DocEditorPage._open.remove(widget.docId);
    unawaited(_changes?.cancel());
    _c?.dispose();
    _focus.dispose();
    _scroll.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _insertImage() async {
    final c = _c;
    if (c == null) return;
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']),
      ],
    );
    if (f == null) return;
    var bytes = await f.readAsBytes();
    // Image réduite (1600 px au plus) pour garder des documents légers.
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded != null && (decoded.width > 1600 || bytes.length > 600000)) {
        final small = decoded.width > 1600 ? img.copyResize(decoded, width: 1600) : decoded;
        bytes = Uint8List.fromList(img.encodeJpg(small, quality: 85));
      }
    } catch (_) {}
    final mime = bytes.length > 3 && bytes[0] == 0x89 ? 'image/png' : 'image/jpeg';
    final at = c.selection.baseOffset < 0 ? c.document.length - 1 : c.selection.baseOffset;
    c.replaceText(at, 0, BlockEmbed.image('data:$mime;base64,${base64Encode(bytes)}'), null);
  }

  void _insertDate() {
    final c = _c;
    if (c == null) return;
    final now = DateTime.now();
    final text = '${frDays[now.weekday - 1]} ${now.day} ${frMonths[now.month - 1]} ${now.year}';
    final at = c.selection.baseOffset < 0 ? 0 : c.selection.baseOffset;
    c.replaceText(at, c.selection.end - c.selection.start, text, TextSelection.collapsed(offset: at + text.length));
  }

  /// Le texte sélectionné (ou tout le document).
  (int, int, String) _target() {
    final c = _c!;
    final s = c.selection;
    if (s.isValid && !s.isCollapsed) {
      return (s.start, s.end - s.start, c.document.getPlainText(s.start, s.end - s.start));
    }
    return (0, c.document.length - 1, DocFormat.toMarkdown(_ops));
  }

  /// Clicky au travail sur le document.
  Future<void> _clicky(String action, {String? custom}) async {
    final c = _c;
    if (c == null || _busy) return;
    final (start, len, text) = _target();
    final whole = start == 0 && len >= c.document.length - 1;
    final prompt = switch (action) {
      'fautes' =>
        'Corrige l\'orthographe, la grammaire, la conjugaison et la ponctuation de ce texte, sans changer son sens ni son style. '
            'Renvoie seulement le texte corrigé (garde la mise en forme Markdown).',
      'style' =>
        'Améliore le style de ce texte (plus clair, plus fluide, vocabulaire plus riche, niveau lycée), sans changer le sens. '
            'Renvoie seulement le texte amélioré (Markdown).',
      'resume' => 'Résume ce texte en quelques points clés (liste Markdown). Renvoie seulement le résumé.',
      'suite' =>
        'Continue ce texte de façon naturelle (un ou deux paragraphes), dans le même style. Renvoie seulement la suite.',
      'plan' =>
        'Propose un plan détaillé (introduction, parties I/II/III avec sous-parties A/B, conclusion) pour ce sujet ou ce texte. '
            'Renvoie seulement le plan en Markdown.',
      'anglais' => 'Traduis ce texte en anglais. Renvoie seulement la traduction (garde le Markdown).',
      'fiche' =>
        'Transforme ce cours en fiche de révision claire : titre, l\'essentiel, définitions en gras, points à retenir, '
            'exemples, et 5 questions pour se tester. Markdown seulement.',
      _ => '${custom ?? ''}\nRenvoie seulement le texte demandé, en Markdown.',
    };
    setState(() => _busy = true);
    try {
      if (!await AiText.available()) {
        throw 'Clicky a besoin d\'un cerveau : clé Gemini gratuite ou Claude (module Claude → Réglages).';
      }
      final out = await AiText.ask(
        '$prompt\n\n---\n$text\n---',
        system: 'Tu es Clicky, assistant d\'écriture d\'un lycéen français. Réponds uniquement avec le texte demandé, '
            'en Markdown simple (# titres, **gras**, *italique*, listes), sans commentaire avant ou après.',
      );
      if (!mounted) return;
      final clean = out.replaceAll(RegExp(r'^```(?:markdown|md)?\s*|\s*```$'), '').trim();
      final choice = await _preview(action, clean, replace: !{'suite', 'resume', 'plan', 'fiche'}.contains(action));
      if (choice == null) return;
      final delta = Delta.fromJson(DocFormat.fromMarkdown(clean));
      if (choice == 'remplacer') {
        if (whole) {
          await _changes?.cancel();
          c.document = Document.fromDelta(delta);
          _changes = c.document.changes.listen((_) => _changed());
          _changed();
        } else {
          c.replaceText(start, len, '', null);
          c.compose(Delta()..retain(start)..concat(delta), TextSelection.collapsed(offset: start), ChangeSource.local);
        }
      } else if (choice == 'nouveau') {
        final d = await DocStore.instance.create(title: '${_title.text} — fiche', ops: delta.toJson());
        if (mounted) await widget.module.open(context, d.id);
      } else {
        final at = whole ? c.document.length - 1 : start + len;
        c.compose(Delta()..retain(at)..insert('\n')..concat(delta), TextSelection.collapsed(offset: at), ChangeSource.local);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Montre la proposition de Clicky avant de toucher au document.
  Future<String?> _preview(String action, String text, {required bool replace}) => showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
          SizedBox(width: 10),
          Text('Proposition de Clicky'),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(child: SelectableText(text)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            Navigator.pop(c);
          },
          child: const Text('Copier'),
        ),
        if (action == 'fiche') TextButton(onPressed: () => Navigator.pop(c, 'nouveau'), child: const Text('Nouveau document')),
        if (replace)
          FilledButton(onPressed: () => Navigator.pop(c, 'remplacer'), child: const Text('Remplacer'))
        else
          FilledButton(onPressed: () => Navigator.pop(c, 'inserer'), child: const Text('Insérer')),
      ],
    ),
  );

  Future<void> _askCustom() async {
    final r = await askFields(
      context,
      title: 'Demander à Clicky',
      message: 'Sur la sélection, ou tout le document si rien n\'est sélectionné.',
      labels: ['Ex. : « fais une conclusion », « ajoute des exemples », « rends-le plus court »'],
    );
    final q = r?.first.trim() ?? '';
    if (q.isNotEmpty) await _clicky('autre', custom: q);
  }

  Future<void> _google() async {
    final d = doc;
    if (d == null) return;
    await _save();
    setState(() => _busy = true);
    try {
      final (gid, link) = await GoogleDocs.upload(_title.text, _ops, id: d.googleId);
      await DocStore.instance.linkGoogle(d.id, gid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Enregistré sur Google Docs'),
            action: SnackBarAction(label: 'Ouvrir', onPressed: () => Browser.open(link)),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final status = _saving || _dirty ? 'Enregistrement…' : 'Enregistré sur l\'appareil';
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF1B1C22) : const Color(0xFFE9E9EF),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: widget.module.color, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.description_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _title,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  filled: false,
                  hintText: 'Titre du document',
                ),
                onChanged: (_) => _changed(),
              ),
            ),
          ],
        ),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          PopupMenuButton<String>(
            tooltip: 'Clicky écrit avec toi',
            icon: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
            onSelected: (v) => v == 'autre' ? _askCustom() : _clicky(v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'fautes', child: Text('✏️  Corriger les fautes')),
              PopupMenuItem(value: 'style', child: Text('✨  Améliorer le style')),
              PopupMenuItem(value: 'suite', child: Text('➡️  Continuer le texte')),
              PopupMenuItem(value: 'plan', child: Text('🧭  Faire un plan')),
              PopupMenuItem(value: 'resume', child: Text('📌  Résumer')),
              PopupMenuItem(value: 'fiche', child: Text('🗂️  En faire une fiche de révision')),
              PopupMenuItem(value: 'anglais', child: Text('🇬🇧  Traduire en anglais')),
              PopupMenuItem(value: 'autre', child: Text('💬  Demander autre chose…')),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Enregistrer, exporter',
            icon: const Icon(Icons.ios_share_rounded),
            onSelected: (v) async {
              final d = doc;
              if (d == null) return;
              await _save();
              if (!context.mounted) return;
              if (v == 'google') return _google();
              await exportDoc(context, d, v, _ops);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'docx', child: Text('Enregistrer en Word (.docx)')),
              PopupMenuItem(value: 'pdf', child: Text('Enregistrer en PDF')),
              PopupMenuItem(value: 'google', child: Text('Enregistrer sur Google Docs')),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: c == null
          ? const LoadingHint()
          : Column(
              children: [
                Material(
                  color: theme.colorScheme.surface,
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: QuillSimpleToolbar(
                      controller: c,
                      config: QuillSimpleToolbarConfig(
                        multiRowsDisplay: true,
                        showSubscript: true,
                        showSuperscript: true,
                        showAlignmentButtons: true,
                        showDirection: false,
                        showSearchButton: true,
                        customButtons: [
                          QuillToolbarCustomButtonOptions(
                            icon: const Icon(Icons.image_rounded),
                            tooltip: 'Insérer une image',
                            onPressed: _insertImage,
                          ),
                          QuillToolbarCustomButtonOptions(
                            icon: const Icon(Icons.today_rounded),
                            tooltip: 'Insérer la date',
                            onPressed: _insertDate,
                          ),
                        ],
                        buttonOptions: const QuillSimpleToolbarButtonOptions(
                          fontFamily: QuillToolbarFontFamilyButtonOptions(items: _fonts, defaultDisplayText: 'Police'),
                          fontSize: QuillToolbarFontSizeButtonOptions(items: _sizes, defaultDisplayText: 'Taille'),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                      child: Center(
                        child: Transform.scale(
                          scale: _zoom,
                          alignment: Alignment.topCenter,
                          child: GestureDetector(
                            onTap: () => _focus.requestFocus(),
                            child: Container(
                              width: 794,
                              constraints: const BoxConstraints(minHeight: 1123),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: const [
                                  BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6)),
                                ],
                              ),
                              // La page reste blanche, même en mode sombre
                              // (comme dans Word).
                              child: Theme(
                                data: buildTheme(Brightness.light),
                                child: DefaultTextStyle(
                                  style: const TextStyle(
                                    fontFamily: 'Calibri',
                                    fontFamilyFallback: ['Segoe UI', 'Arial', 'Roboto'],
                                    color: Color(0xFF1A1A1A),
                                    fontSize: 15,
                                  ),
                                  child: QuillEditor(
                                    controller: c,
                                    focusNode: _focus,
                                    scrollController: ScrollController(),
                                    config: const QuillEditorConfig(
                                      scrollable: false,
                                      padding: EdgeInsets.fromLTRB(84, 80, 84, 96),
                                      placeholder: 'Commence à écrire… (ou demande à Clicky ✨)',
                                      embedBuilders: [_ImageEmbed()],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Material(
                  color: widget.module.color,
                  child: SizedBox(
                    height: 30,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: DefaultTextStyle(
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        child: Row(
                          children: [
                            Text('Page ${(_words / 450).ceil().clamp(1, 999)} · $_words mot${_words > 1 ? 's' : ''}'),
                            const SizedBox(width: 16),
                            Text(status),
                            if (doc?.googleId != null) ...[
                              const SizedBox(width: 16),
                              const Icon(Icons.cloud_done_rounded, color: Colors.white, size: 14),
                              const SizedBox(width: 4),
                              const Text('Lié à Google Docs'),
                            ],
                            const Spacer(),
                            InkWell(
                              onTap: () => setState(() => _zoom = (_zoom - 0.1).clamp(0.5, 2.0)),
                              child: const Icon(Icons.remove_rounded, color: Colors.white, size: 18),
                            ),
                            SizedBox(
                              width: 120,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white38,
                                  thumbColor: Colors.white,
                                  overlayShape: SliderComponentShape.noOverlay,
                                ),
                                child: Slider(
                                  value: _zoom,
                                  min: 0.5,
                                  max: 2,
                                  onChanged: (v) => setState(() => _zoom = v),
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: () => setState(() => _zoom = (_zoom + 0.1).clamp(0.5, 2.0)),
                              child: const Icon(Icons.add_rounded, color: Colors.white, size: 18),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(width: 40, child: Text('${(_zoom * 100).round()} %')),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
