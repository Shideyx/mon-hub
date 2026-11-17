import 'package:material_ui/material_ui.dart';

import '../../core/google_auth.dart';
import '../../core/hub_module.dart';
import 'drive_tidy.dart';
import '../../ui/web_login.dart';
import '../../ui/widgets.dart';

class DriveFile {
  DriveFile(this.j);
  final Map<String, dynamic> j;

  String get id => '${j['id']}';
  String get name => '${j['name'] ?? 'Sans nom'}';
  String get mime => '${j['mimeType'] ?? ''}';
  bool get isFolder => mime == 'application/vnd.google-apps.folder';
  String? get thumbnail => j['thumbnailLink'] as String?;
  String get link => '${j['webViewLink'] ?? 'https://drive.google.com/open?id=$id'}';
  DateTime? get modified => DateTime.tryParse('${j['modifiedTime'] ?? ''}')?.toLocal();
  int? get size => int.tryParse('${j['size'] ?? ''}');
  bool get starred => j['starred'] == true;

  (IconData, Color) get look => switch (mime) {
    'application/vnd.google-apps.folder' => (Icons.folder_rounded, const Color(0xFF5F6368)),
    'application/vnd.google-apps.document' => (Icons.description_rounded, const Color(0xFF4285F4)),
    'application/vnd.google-apps.spreadsheet' => (Icons.table_chart_rounded, const Color(0xFF0F9D58)),
    'application/vnd.google-apps.presentation' => (Icons.slideshow_rounded, const Color(0xFFF4B400)),
    'application/vnd.google-apps.form' => (Icons.list_alt_rounded, const Color(0xFF7248B9)),
    'application/pdf' => (Icons.picture_as_pdf_rounded, const Color(0xFFDB4437)),
    _ when mime.startsWith('image/') => (Icons.image_rounded, const Color(0xFFDB4437)),
    _ when mime.startsWith('video/') => (Icons.movie_rounded, const Color(0xFFDB4437)),
    _ when mime.startsWith('audio/') => (Icons.audiotrack_rounded, const Color(0xFF7248B9)),
    _ => (Icons.insert_drive_file_rounded, const Color(0xFF5F6368)),
  };
}

enum DriveView {
  mine('Mon Drive', Icons.folder_open_rounded),
  recent('Récents', Icons.schedule_rounded),
  shared('Partagés avec moi', Icons.people_alt_rounded),
  starred('Suivis', Icons.star_rounded);

  const DriveView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Google Drive en vrai : tes dossiers et fichiers avec aperçus, comme sur
/// drive.google.com (lecture seule, via « Se connecter avec Google »).
class DriveModule extends HubModule {
  @override
  String get id => 'drive';
  @override
  String get name => 'Google Drive';
  @override
  String get description => 'Tes dossiers et fichiers Drive, avec aperçus';
  @override
  IconData get icon => Icons.add_to_drive_rounded;
  @override
  Color get color => const Color(0xFF1FA463);
  @override
  ApiAccess get access => GoogleAuth.available ? ApiAccess.official : ApiAccess.shortcutsOnly;

  String? get account {
    final saved = store.getJson<String>('account');
    final all = GoogleAuth.accounts;
    if (saved != null && all.contains(saved)) return saved;
    return all.firstOrNull;
  }

  static const _fields =
      'nextPageToken,files(id,name,mimeType,thumbnailLink,webViewLink,modifiedTime,size,starred)';

  static String _quote(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Future<String> token() => GoogleAuth.accessToken(account!);

  Future<List<DriveFile>> list({
    DriveView view = DriveView.mine,
    String folder = 'root',
    String search = '',
    int pageSize = 100,
  }) async {
    final acc = account;
    if (acc == null) throw 'Connecte ton compte Google';
    final q = search.trim().isNotEmpty
        ? "name contains '${_quote(search.trim())}' and trashed=false"
        : switch (view) {
            DriveView.mine => "'${_quote(folder)}' in parents and trashed=false",
            DriveView.recent =>
              "trashed=false and mimeType!='application/vnd.google-apps.folder'",
            DriveView.shared => 'sharedWithMe and trashed=false',
            DriveView.starred => 'starred and trashed=false',
          };
    final order = view == DriveView.recent && search.isEmpty
        ? 'viewedByMeTime desc'
        : 'folder,modifiedTime desc';
    final url = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': q,
      'fields': _fields,
      'orderBy': order,
      'pageSize': '$pageSize',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    final j = await GoogleAuth.api(acc, 'GET', '$url');
    return [for (final f in (j['files'] as List? ?? const [])) DriveFile((f as Map).cast())];
  }

  Future<List<DriveFile>>? _recent;
  DateTime? _recentAt;
  String? _recentFor;

  /// Fichiers récents pour la tuile (gardés 2 minutes).
  Future<List<DriveFile>> recent() {
    final fresh = _recentAt != null && DateTime.now().difference(_recentAt!).inMinutes < 2;
    if (_recent != null && fresh && _recentFor == account) return _recent!;
    _recentAt = DateTime.now();
    _recentFor = account;
    return _recent = list(view: DriveView.recent, pageSize: 12).catchError((Object e) {
      _recentAt = null;
      throw e;
    });
  }

  Future<(int, int?)> quota() async {
    final j = await GoogleAuth.api(
      account!,
      'GET',
      'https://www.googleapis.com/drive/v3/about?fields=storageQuota',
    );
    final q = j['storageQuota'] as Map? ?? const {};
    return (int.tryParse('${q['usage']}') ?? 0, int.tryParse('${q['limit']}'));
  }

  static bool needsReconnect(Object e) =>
      '$e'.contains('insufficient') || '$e'.contains('scope') || '$e'.contains('Reconnecte');

  Future<void> connect(BuildContext context) async {
    try {
      final email = await GoogleAuth.signIn();
      await store.setJson('account', email);
      _recent = null;
      store.changed();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'drive_ranger_apercu',
      description: 'Prépare le rangement du Google Drive : où irait chaque fichier en vrac à la racine '
          '(Documents, PDF, Photos, Cours/Maths…), sans rien toucher.',
      params: {'par_matiere': ('boolean', 'Ranger les cours par matière, oui par défaut')},
      run: (a) async {
        final moves = await DriveTidy.analyze(bySubject: a['par_matiere'] != false);
        final groups = <String, List<String>>{};
        for (final m in moves) {
          groups.putIfAbsent(m.dest, () => []).add(m.name);
        }
        return {
          'fichiers': moves.length,
          'rangement': {
            for (final e in groups.entries) e.key: {'nombre': e.value.length, 'exemples': e.value.take(4).toList()},
          },
        };
      },
    ),
    HubTool(
      name: 'drive_ranger',
      description: 'Range pour de vrai le Google Drive (après drive_ranger_apercu). Rien n\'est supprimé ; annulable.',
      params: {'par_matiere': ('boolean', 'Ranger les cours par matière, oui par défaut')},
      run: (a) async {
        final (n, errors) = await DriveTidy.apply(await DriveTidy.analyze(bySubject: a['par_matiere'] != false));
        _recent = null;
        return {'ranges': n, if (errors.isNotEmpty) 'erreurs': errors.take(5).toList()};
      },
    ),
    HubTool(
      name: 'drive_ranger_annuler',
      description: 'Annule le dernier rangement du Google Drive.',
      run: (_) async => {'remis_en_place': await DriveTidy.undoLast()},
    ),
    HubTool(
      name: 'drive_chercher',
      description: 'Cherche des fichiers dans Google Drive par leur nom (ou liste les récents).',
      params: {'nom': ('string', 'Texte à chercher dans le nom (vide = fichiers récents)')},
      run: (a) async => [
        for (final f in await list(
          view: DriveView.recent,
          search: '${a['nom'] ?? ''}',
          pageSize: 25,
        ))
          {'nom': f.name, 'type': f.mime, 'modifie': f.modified, 'lien': f.link},
      ],
    ),
  ];

  // ---------- Interface ----------

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (!GoogleAuth.available) {
        return const EmptyHint('Ouvre la tuile pour voir ton Drive', icon: Icons.add_to_drive_rounded);
      }
      if (account == null) {
        return EmptyHint(
          'Connecte ton compte Google pour voir ton Drive',
          icon: Icons.login_rounded,
          action: ('Se connecter', () => connect(context)),
        );
      }
      return FutureBuilder(
        future: recent(),
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyHint(
              needsReconnect(snap.error!)
                  ? 'Autorise Mon Hub à lire ton Drive'
                  : '${snap.error}',
              action: needsReconnect(snap.error!) ? ('Autoriser', () => connect(context)) : null,
            );
          }
          if (!snap.hasData) return const LoadingHint();
          final files = snap.data!;
          if (files.isEmpty) return const EmptyHint('Aucun fichier récent');
          return LayoutBuilder(
            builder: (context, box) {
              final cols = (box.maxWidth / 110).floor().clamp(2, 6);
              return GridView.count(
                crossAxisCount: cols,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 1.1,
                padding: const EdgeInsets.all(6),
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final f in files.take(cols * 2))
                    _FileCard(module: this, file: f, compact: true),
                ],
              );
            },
          );
        },
      );
    },
  );

  @override
  Widget buildPage(BuildContext context) => _DrivePage(module: this);
}

class _DrivePage extends StatefulWidget {
  const _DrivePage({required this.module});
  final DriveModule module;

  @override
  State<_DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<_DrivePage> {
  DriveModule get m => widget.module;
  DriveView view = DriveView.mine;

  /// Dossiers ouverts (id, nom) depuis la racine.
  final path = <(String, String)>[];
  final search = TextEditingController();
  String query = '';
  bool grid = true;
  Future<List<DriveFile>>? files;
  Future<(int, int?)>? quota;

  void _reload() {
    if (m.account == null) return;
    setState(() {
      files = m.list(view: view, folder: path.isEmpty ? 'root' : path.last.$1, search: query);
      quota ??= m.quota();
    });
  }

  @override
  void initState() {
    super.initState();
    grid = m.store.getJson<bool>('grid') ?? true;
    _reload();
  }

  void openFolder(DriveFile f) {
    if (view != DriveView.mine || query.isNotEmpty) {
      view = DriveView.mine;
      path.clear();
      query = '';
      search.clear();
    }
    path.add((f.id, f.name));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (!GoogleAuth.available) {
      // Version sans « Se connecter avec Google » : le vrai site, intégré.
      return Scaffold(
        appBar: AppBar(title: Text(m.name)),
        body: webLoginSupported
            ? const HubWebView(url: 'https://drive.google.com/drive/my-drive', desktopUserAgent: true)
            : Center(
                child: FilledButton(
                  onPressed: () => openLink(context, 'https://drive.google.com'),
                  child: const Text('Ouvrir Google Drive'),
                ),
              ),
      );
    }
    return ListenableBuilder(
      listenable: m.store,
      builder: (context, _) {
        final acc = m.account;
        return Scaffold(
          appBar: AppBar(
            title: Text(m.name),
            actions: [
              IconButton(
                tooltip: grid ? 'Liste' : 'Grille',
                icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
                onPressed: () {
                  setState(() => grid = !grid);
                  m.store.setJson('grid', grid);
                },
              ),
              IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _reload),
              IconButton(
                tooltip: 'Ouvrir drive.google.com',
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: () => openLink(context, 'https://drive.google.com'),
              ),
            ],
          ),
          body: acc == null
              ? EmptyHint(
                  'Connecte ton compte Google pour voir tes dossiers et fichiers ici.',
                  icon: Icons.add_to_drive_rounded,
                  action: ('Se connecter avec Google', () async {
                    await m.connect(context);
                    _reload();
                  }),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context, acc),
                    _breadcrumbs(context),
                    Expanded(child: _content(context)),
                  ],
                ),
        );
      },
    );
  }

  Widget _header(BuildContext context, String acc) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Rechercher dans Drive',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        search.clear();
                        query = '';
                        _reload();
                      },
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              isDense: true,
            ),
            onSubmitted: (v) {
              query = v;
              _reload();
            },
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final v in DriveView.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: Icon(v.icon, size: 18),
                      label: Text(v.label),
                      selected: view == v && query.isEmpty,
                      onSelected: (_) {
                        view = v;
                        path.clear();
                        query = '';
                        search.clear();
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          FutureBuilder(
            future: quota,
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) return const SizedBox(height: 4);
              final (used, limit) = d;
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: limit == null || limit == 0 ? null : used / limit,
                          minHeight: 6,
                          color: m.color,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${_size(used)}${limit == null ? '' : ' sur ${_size(limit)}'} · $acc',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _breadcrumbs(BuildContext context) {
    final title = query.isNotEmpty ? 'Résultats pour « $query »' : view.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            TextButton(
              onPressed: path.isEmpty
                  ? null
                  : () {
                      path.clear();
                      _reload();
                    },
              child: Text(title, style: const TextStyle(fontSize: 16)),
            ),
            for (var i = 0; i < path.length; i++) ...[
              const Icon(Icons.chevron_right_rounded, size: 18),
              TextButton(
                onPressed: i == path.length - 1
                    ? null
                    : () {
                        path.removeRange(i + 1, path.length);
                        _reload();
                      },
                child: Text(path[i].$2, style: const TextStyle(fontSize: 16)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) => FutureBuilder(
    future: files,
    builder: (context, snap) {
      if (snap.hasError) {
        final reconnect = DriveModule.needsReconnect(snap.error!);
        return EmptyHint(
          reconnect
              ? 'Mon Hub doit avoir la permission de lire ton Drive. Reconnecte ton '
                    'compte Google et coche l\'accès à Drive.'
              : '${snap.error}',
          action: reconnect
              ? ('Autoriser l\'accès', () async {
                  await m.connect(context);
                  quota = null;
                  _reload();
                })
              : ('Réessayer', _reload),
        );
      }
      if (!snap.hasData) return const LoadingHint();
      final all = snap.data!;
      if (all.isEmpty) return const EmptyHint('Ce dossier est vide', icon: Icons.folder_open_rounded);
      final folders = all.where((f) => f.isFolder).toList();
      final docs = all.where((f) => !f.isFolder).toList();
      if (!grid) {
        return ListView(
          children: [
            for (final f in [...folders, ...docs])
              ListTile(
                leading: _Thumb(module: m, file: f, size: 40),
                title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (f.modified != null) 'Modifié ${timeAgo(f.modified!)}',
                  if (f.size != null) _size(f.size!),
                ].join(' · ')),
                trailing: f.starred ? const Icon(Icons.star_rounded, size: 18) : null,
                onTap: () => f.isFolder ? openFolder(f) : _open(context, m, f),
              ),
          ],
        );
      }
      return LayoutBuilder(
        builder: (context, box) {
          final cols = (box.maxWidth / 190).floor().clamp(2, 8);
          return CustomScrollView(
            slivers: [
              if (folders.isNotEmpty) ...[
                _sectionTitle(context, 'Dossiers'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverGrid.count(
                    crossAxisCount: cols,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3.4,
                    children: [
                      for (final f in folders)
                        Card(
                          margin: EdgeInsets.zero,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => openFolder(f),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                children: [
                                  Icon(Icons.folder_rounded, color: f.look.$2),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (docs.isNotEmpty) ...[
                _sectionTitle(context, 'Fichiers'),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                  sliver: SliverGrid.count(
                    crossAxisCount: cols,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.95,
                    children: [for (final f in docs) _FileCard(module: m, file: f)],
                  ),
                ),
              ],
            ],
          );
        },
      );
    },
  );

  Widget _sectionTitle(BuildContext context, String t) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(t, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

String _size(int b) {
  const u = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 && i > 0 ? v.toStringAsFixed(1) : v.round()} ${u[i]}';
}

void _open(BuildContext context, DriveModule m, DriveFile f) {
  if (!webLoginSupported) {
    openLink(context, f.link);
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (c) => Scaffold(
        appBar: AppBar(
          title: Text(f.name),
          actions: [
            IconButton(
              tooltip: 'Ouvrir dans le navigateur',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => openLink(c, f.link),
            ),
          ],
        ),
        body: HubWebView(url: f.link, desktopUserAgent: true),
      ),
    ),
  );
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.module, required this.file, this.compact = false});
  final DriveModule module;
  final DriveFile file;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (ic, col) = file.look;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context, module, file),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _Thumb(module: module, file: file)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 4 : 8),
              child: Row(
                children: [
                  Icon(ic, size: compact ? 14 : 18, color: col),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: compact ? Theme.of(context).textTheme.labelSmall : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Aperçu du fichier (miniature Google) ou grande icône colorée.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.module, required this.file, this.size});
  final DriveModule module;
  final DriveFile file;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final (ic, col) = file.look;
    final fallback = Container(
      width: size,
      height: size,
      color: col.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Icon(ic, color: col, size: size == null ? 42 : size! * 0.6),
    );
    final t = file.thumbnail;
    if (t == null) return fallback;
    return FutureBuilder(
      future: module.token(),
      builder: (context, snap) {
        if (!snap.hasData) return fallback;
        return Image.network(
          // Miniature plus nette que celle proposée par défaut.
          t.replaceFirst(RegExp(r'=s\d+$'), '=s400'),
          headers: {'Authorization': 'Bearer ${snap.data}'},
          width: size,
          height: size,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }
}
