import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'error_log.dart';
import 'google_auth.dart';
import 'hub_files.dart';
import 'screen_time.dart';

/// **Sauvegarde de tes travaux** : tes exposés, devoirs, présentations…
/// (Documents et Bureau, ou les dossiers que tu choisis) sont copiés tout
/// seuls dans **ton** Google Drive, dossier « Mon Hub - Sauvegardes ».
/// Seuls les fichiers nouveaux ou modifiés partent ; rien n'est jamais
/// supprimé du Drive. Si le PC plante la veille d'un rendu, rien n'est perdu.
class WorkBackup extends ChangeNotifier {
  WorkBackup._();
  static final instance = WorkBackup._();

  static const driveFolder = 'Mon Hub - Sauvegardes';
  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _files = 'https://www.googleapis.com/drive/v3/files';

  /// Les types de fichiers sauvegardés (documents, présentations, tableurs,
  /// code, projets Scratch…). Pas les photos ni les vidéos (trop lourdes).
  static const extensions = {
    'doc',
    'docx',
    'odt',
    'rtf',
    'txt',
    'md',
    'pdf',
    'ppt',
    'pptx',
    'odp',
    'xls',
    'xlsx',
    'ods',
    'csv',
    'pages',
    'key',
    'numbers',
    'tex',
    'py',
    'java',
    'c',
    'cpp',
    'h',
    'js',
    'ts',
    'html',
    'css',
    'json',
    'sb3',
    'ipynb',
    'lua',
    'rbxl',
    'rbxm',
    'ggb',
    'drawio',
    'xcf',
    'kra',
    'mscz',
  };

  static const maxBytes = 50 * 1024 * 1024;

  /// Dossiers jamais parcourus.
  static final _skipDir = RegExp(
    r'^(?:\.|node_modules$|__pycache__$|AppData$|venv$|\.venv$|build$|dist$|target$|My Games$|Mes jeux$|'
    r'Zoom$|Rockstar Games$|Battlefield|Steam|EA Games$|Ubisoft|WindowsPowerShell$|Fichiers Outlook$|Outlook Files$)',
    caseSensitive: false,
  );

  final _state = JsonFile<Map<String, dynamic>>(
    'sauvegarde.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  Timer? _timer;
  bool running = false;
  String? lastError;
  int lastCount = 0;
  String progress = '';

  Map<String, dynamic> get _s => _state.value;
  bool get on => _s['on'] == true;
  DateTime? get lastRun => _s['last'] is num ? DateTime.fromMillisecondsSinceEpoch((_s['last'] as num).toInt()) : null;
  int get savedCount => (_s['fichiers'] as Map?)?.length ?? 0;
  String? get folderLink => _s['lien'] as String?;

  static String? get _home => Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];

  /// Les dossiers par défaut : Documents et Bureau.
  static List<String> defaultFolders() {
    final h = _home;
    if (h == null) return const [];
    final sep = Platform.pathSeparator;
    return [
      for (final name in const ['Documents', 'Desktop', 'Bureau', 'OneDrive${'\\'}Documents', 'OneDrive${'\\'}Bureau'])
        if (Directory('$h$sep$name').existsSync()) '$h$sep$name',
    ];
  }

  List<String> get folders {
    final l = _s['dossiers'];
    if (l is List && l.isNotEmpty) return [for (final f in l) '$f'];
    return defaultFolders();
  }

  Future<void> load() async {
    await _state.load();
    notifyListeners();
  }

  Future<void> setOn(bool v) async {
    await _state.update((m) => {...m, 'on': v});
    notifyListeners();
    if (v) {
      start();
      unawaited(runNow());
    } else {
      _timer?.cancel();
    }
  }

  Future<void> setFolders(List<String> f) async {
    await _state.update((m) => {...m, 'dossiers': f});
    notifyListeners();
  }

  /// Toutes les 30 minutes (5 min après l'ouverture).
  void start() {
    if (kIsWeb || !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => unawaited(runNow()));
    unawaited(
      _state.load().then((_) {
        if (on) Timer(const Duration(minutes: 5), () => unawaited(runNow()));
      }),
    );
  }

  void stop() => _timer?.cancel();

  /// Le fichier vaut-il d'être sauvegardé ?
  static bool wanted(String path, int size) {
    final name = path.split(RegExp(r'[\\/]')).last;
    if (name.startsWith('~\$') || name.startsWith('.') || name.endsWith('.tmp')) return false;
    if (size <= 0 || size > maxBytes) return false;
    final dot = name.lastIndexOf('.');
    return dot > 0 && extensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Le chemin rangé dans le Drive : « Documents/Maths/DM 3.docx ».
  static String relative(String root, String path) {
    final top = root.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).last;
    var rest = path.substring(root.length).replaceAll('\\', '/');
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    return '$top/$rest';
  }

  /// Le fichier a-t-il changé depuis la dernière sauvegarde ?
  static bool changed(Map<String, dynamic> saved, String rel, int size, DateTime modified) {
    final e = saved[rel];
    if (e is! Map) return true;
    return e['taille'] != size || e['modif'] != modified.millisecondsSinceEpoch;
  }

  /// Cherche les fichiers à sauvegarder (nouveaux ou modifiés).
  Future<List<(String, String, int, DateTime)>> _scan(Map<String, dynamic> saved) async {
    final out = <(String, String, int, DateTime)>[];
    var seen = 0;
    for (final root in folders) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      Future<void> walk(Directory d, int depth) async {
        if (depth > 7 || seen > 20000 || out.length >= 300) return;
        List<FileSystemEntity> items;
        try {
          items = await d.list(followLinks: false).toList();
        } catch (_) {
          return;
        }
        for (final e in items) {
          seen++;
          final name = e.uri.pathSegments.where((p) => p.isNotEmpty).lastOrNull ?? '';
          if (e is Directory) {
            if (!_skipDir.hasMatch(name)) await walk(e, depth + 1);
          } else if (e is File) {
            try {
              final st = await e.stat();
              if (!wanted(e.path, st.size)) continue;
              final rel = relative(root, e.path);
              if (changed(saved, rel, st.size, st.modified)) out.add((e.path, rel, st.size, st.modified));
            } catch (_) {}
          }
        }
      }

      await walk(dir, 0);
    }
    return out;
  }

  /// Le dossier du Drive pour [path] (« Documents/Maths ») : créé s'il
  /// manque, gardé en mémoire.
  Future<String> _folder(String account, String path, Map<String, dynamic> ids) async {
    final known = ids[path];
    if (known is String) return known;
    final parts = path.split('/');
    final parent = parts.length == 1 ? null : await _folder(account, parts.sublist(0, parts.length - 1).join('/'), ids);
    final name = parts.last;
    final esc = name.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final q =
        "mimeType='$_folderMime' and name='$esc' and trashed=false and "
        "${parent == null ? "'root' in parents" : "'$parent' in parents"}";
    final found = await GoogleAuth.api(
      account,
      'GET',
      Uri.parse(_files)
          .replace(queryParameters: {'q': q, 'fields': 'files(id,webViewLink)', 'pageSize': '1'})
          .toString(),
    );
    final list = found['files'];
    String id;
    if (list is List && list.isNotEmpty) {
      id = '${(list.first as Map)['id']}';
      if (parent == null) ids['@lien'] = (list.first as Map)['webViewLink'];
    } else {
      final made = await GoogleAuth.api(
        account,
        'POST',
        '$_files?fields=id,webViewLink',
        body: {
          'name': name,
          'mimeType': _folderMime,
          'parents': ?parent == null ? null : [parent],
        },
      );
      id = '${made['id']}';
      if (parent == null) ids['@lien'] = made['webViewLink'];
    }
    ids[path] = id;
    return id;
  }

  /// Sauvegarde maintenant (fichiers nouveaux ou modifiés).
  Future<int> runNow() async {
    // Pendant une partie (mode jeu), rien de lourd en fond.
    if (running || GameMode.instance.active) return 0;
    await _state.load();
    if (!on) return 0;
    final account = GoogleAuth.available ? GoogleAuth.driveAccount : null;
    if (account == null || !GoogleAuth.canWriteDrive(account)) {
      lastError = 'Connecte ton compte Google (Réglages → Connexion Google) pour sauvegarder dans ton Drive.';
      notifyListeners();
      return 0;
    }
    running = true;
    lastError = null;
    progress = 'Je cherche ce qui a changé…';
    notifyListeners();
    var count = 0;
    try {
      final saved = Map<String, dynamic>.from((_s['fichiers'] as Map?) ?? const {});
      final ids = Map<String, dynamic>.from((_s['ids'] as Map?) ?? const {});
      final todo = await _scan(saved);
      for (final (path, rel, size, modified) in todo) {
        progress = 'Sauvegarde : ${rel.split('/').last} (${count + 1}/${todo.length})';
        notifyListeners();
        try {
          final dir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
          final parent = await _folder(account, '$driveFolder${dir.isEmpty ? '' : '/$dir'}', ids);
          final data = Uint8List.fromList(await File(path).readAsBytes());
          final before = saved[rel];
          final id = before is Map ? before['id'] as String? : null;
          Map<String, dynamic> r;
          try {
            r = await GoogleAuth.upload(
              account,
              name: rel.split('/').last,
              data: data,
              mime: 'application/octet-stream',
              id: id,
              parent: id == null ? parent : null,
            );
          } catch (_) {
            if (id == null) rethrow;
            // Fichier supprimé du Drive entre-temps : on le recrée.
            r = await GoogleAuth.upload(
              account,
              name: rel.split('/').last,
              data: data,
              mime: 'application/octet-stream',
              parent: parent,
            );
          }
          saved[rel] = {'id': r['id'], 'taille': size, 'modif': modified.millisecondsSinceEpoch};
          count++;
        } catch (e) {
          lastError = '${rel.split('/').last} : $e';
        }
        // Gardé au fur et à mesure (une coupure ne fait rien perdre).
        if (count % 10 == 0) await _save(saved, ids);
      }
      await _save(saved, ids, done: true);
      lastCount = count;
    } catch (e) {
      lastError = '$e';
      ErrorLog.record(e, null, where: 'Sauvegarde des travaux');
    } finally {
      running = false;
      progress = '';
      notifyListeners();
    }
    return count;
  }

  Future<void> _save(Map<String, dynamic> saved, Map<String, dynamic> ids, {bool done = false}) => _state.update(
    (m) => {
      ...m,
      'fichiers': saved,
      'ids': ids,
      if (ids['@lien'] != null) 'lien': ids['@lien'],
      if (done) 'last': DateTime.now().millisecondsSinceEpoch,
    },
  );
}
