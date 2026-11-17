import 'dart:convert';

import '../../core/google_auth.dart';
import '../../core/hub_files.dart';
import '../../core/tidy.dart';

/// Un fichier du Drive à ranger.
class DriveMove {
  DriveMove(this.id, this.name, this.dest, this.reason);
  final String id;
  final String name;

  /// Dossier de destination (« Documents », « Cours/Maths »…).
  final String dest;
  final String reason;
}

/// Ranger ton Google Drive : les fichiers en vrac à la racine vont dans
/// des dossiers (Documents, PDF, Photos, Cours/Maths…). Rien n'est supprimé,
/// et tout peut être annulé.
class DriveTidy {
  DriveTidy._();

  static const _folderMime = 'application/vnd.google-apps.folder';

  static String categoryOf(String mime, String name) {
    if (mime == 'application/vnd.google-apps.document') return 'Documents';
    if (mime == 'application/vnd.google-apps.spreadsheet') return 'Tableurs';
    if (mime == 'application/vnd.google-apps.presentation') return 'Présentations';
    if (mime == 'application/vnd.google-apps.form') return 'Formulaires';
    if (mime == 'application/pdf') return 'PDF';
    if (mime.startsWith('image/')) return 'Photos';
    if (mime.startsWith('video/')) return 'Vidéos';
    if (mime.startsWith('audio/')) return 'Audio';
    return PcTidy.category(name) ?? 'Autres';
  }

  static String _account() {
    final a = GoogleAuth.driveAccount;
    if (a == null) throw 'Connecte ton compte Google pour que je range ton Drive';
    if (!GoogleAuth.canWriteDrive(a)) {
      throw 'Reconnecte ton compte Google ($a) pour autoriser Mon Hub à ranger ton Drive';
    }
    return a;
  }

  static String _q(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  /// Les fichiers en vrac à la racine du Drive, et où les ranger.
  static Future<List<DriveMove>> analyze({bool bySubject = true}) async {
    final acc = _account();
    final files = <Map>[];
    String? page;
    do {
      final url = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'q': "'root' in parents and trashed=false and mimeType!='$_folderMime' and 'me' in owners",
        'fields': 'nextPageToken,files(id,name,mimeType)',
        'pageSize': '200',
        'pageToken': ?page,
      });
      final j = await GoogleAuth.api(acc, 'GET', '$url');
      files.addAll([for (final f in (j['files'] as List? ?? const [])) f as Map]);
      page = j['nextPageToken'] as String?;
    } while (page != null && files.length < 1000);
    return [
      for (final f in files)
        () {
          final name = '${f['name']}';
          final cat = categoryOf('${f['mimeType']}', name);
          final subj = bySubject ? PcTidy.subject(name) : null;
          final school = {'Documents', 'PDF', 'Présentations', 'Tableurs', 'Photos'}.contains(cat);
          return subj != null && school
              ? DriveMove('${f['id']}', name, 'Cours/$subj', 'Cours de $subj')
              : DriveMove('${f['id']}', name, cat, cat);
        }(),
    ];
  }

  /// Retrouve (ou crée) un dossier dans [parent].
  static Future<String> _folder(String acc, String name, String parent) async {
    final url = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': "name='${_q(name)}' and mimeType='$_folderMime' and '${_q(parent)}' in parents and trashed=false",
      'fields': 'files(id)',
    });
    final j = await GoogleAuth.api(acc, 'GET', '$url');
    final found = (j['files'] as List?)?.firstOrNull;
    if (found is Map) return '${found['id']}';
    final c = await GoogleAuth.api(
      acc,
      'POST',
      'https://www.googleapis.com/drive/v3/files?fields=id',
      body: {
        'name': name,
        'mimeType': _folderMime,
        'parents': [parent],
      },
    );
    return '${c['id']}';
  }

  /// Range pour de vrai. Renvoie (nombre rangé, erreurs).
  static Future<(int, List<String>)> apply(List<DriveMove> moves, {Set<String>? only}) async {
    final acc = _account();
    final folders = <String, String>{};
    final done = <Map<String, String>>[];
    final errors = <String>[];
    for (final m in moves) {
      if (only != null && !only.contains(m.dest)) continue;
      try {
        var parent = 'root';
        var path = '';
        for (final part in m.dest.split('/')) {
          path = path.isEmpty ? part : '$path/$part';
          parent = folders[path] ??= await _folder(acc, part, parent);
        }
        await GoogleAuth.api(
          acc,
          'PATCH',
          'https://www.googleapis.com/drive/v3/files/${m.id}?addParents=$parent&removeParents=root&fields=id',
          body: const {},
        );
        done.add({'id': m.id, 'de': 'root', 'vers': parent});
      } catch (e) {
        errors.add('${m.name} : $e');
      }
    }
    if (done.isNotEmpty) {
      final f = await HubFiles.file('rangement-${DateTime.now().millisecondsSinceEpoch}.json');
      await f?.writeAsString(jsonEncode({'type': 'drive', 'compte': acc, 'fait': done}));
    }
    return (done.length, errors);
  }

  /// Remet les fichiers du dernier rangement du Drive à la racine.
  static Future<int> undoLast() async {
    final last = await PcTidy.lastJournal(type: 'drive');
    if (last == null) return 0;
    final (file, j) = last;
    final acc = '${j['compte']}';
    var n = 0;
    for (final m in (j['fait'] as List?) ?? const []) {
      try {
        await GoogleAuth.api(
          acc,
          'PATCH',
          'https://www.googleapis.com/drive/v3/files/${m['id']}?addParents=${m['de']}&removeParents=${m['vers']}&fields=id',
          body: const {},
        );
        n++;
      } catch (_) {}
    }
    await file.delete();
    return n;
  }
}
