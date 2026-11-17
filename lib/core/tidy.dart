import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'hub_files.dart';

/// Un déplacement prévu : [from] → dossier [dest] (relatif au dossier
/// rangé), avec la raison (« Images », « Doublon »…).
class TidyMove {
  TidyMove(this.from, this.dest, this.reason);
  final String from;
  final String dest;
  final String reason;

  String get name => from.split(RegExp(r'[\\/]')).last;
}

class TidyPlan {
  TidyPlan(this.root, this.moves, {this.skipped = 0});
  final String root;
  final List<TidyMove> moves;

  /// Fichiers laissés en place (raccourcis, téléchargements en cours…).
  final int skipped;

  /// Les déplacements groupés par dossier de destination.
  Map<String, List<TidyMove>> get groups {
    final out = <String, List<TidyMove>>{};
    for (final m in moves) {
      out.putIfAbsent(m.dest, () => []).add(m);
    }
    return Map.fromEntries(out.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length)));
  }
}

/// Ranger un dossier du PC : chaque fichier en vrac va dans un sous-dossier
/// selon son type (Images, PDF, Programmes…) ou sa matière (Cours/Maths…),
/// les doublons sont mis de côté (jamais supprimés), et tout peut être
/// annulé.
class PcTidy {
  PcTidy._();

  static const categories = <String, List<String>>{
    'Images': ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg', 'tif', 'tiff', 'ico', 'raw', 'psd'],
    'Vidéos': ['mp4', 'mov', 'avi', 'mkv', 'webm', 'wmv', 'm4v', 'flv'],
    'Musique': ['mp3', 'wav', 'flac', 'm4a', 'aac', 'ogg', 'wma', 'opus'],
    'PDF': ['pdf'],
    'Documents': ['doc', 'docx', 'odt', 'rtf', 'txt', 'md', 'pages', 'epub'],
    'Tableurs': ['xls', 'xlsx', 'ods', 'csv', 'numbers'],
    'Présentations': ['ppt', 'pptx', 'odp', 'key'],
    'Archives': ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'],
    'Programmes': ['exe', 'msi', 'msix', 'msixbundle', 'appx', 'dmg', 'pkg', 'apk', 'iso'],
    'Code': ['py', 'js', 'ts', 'dart', 'java', 'c', 'cpp', 'h', 'cs', 'html', 'css', 'json', 'xml', 'yml', 'yaml', 'sql', 'sh', 'ps1', 'bat', 'ipynb', 'lua'],
    'Polices': ['ttf', 'otf', 'woff', 'woff2'],
    '3D': ['stl', 'obj', 'fbx', 'blend', '3mf', 'rbxl', 'rbxm', 'glb', 'gltf'],
  };

  /// Matières reconnues dans le nom d'un fichier.
  static const subjects = <String, List<String>>{
    'Maths': ['math', 'maths', 'mathematiques', 'algebre', 'geometrie', 'proba', 'probabilites', 'derivee', 'derivees'],
    'Histoire-Géo': ['histoire', 'hist', 'geo', 'geographie', 'hgg', 'hggsp', 'emc'],
    'SVT': ['svt', 'biologie', 'bio', 'genetique', 'ecologie'],
    'Physique-Chimie': ['physique', 'chimie', 'phys', 'physchim'],
    'Anglais': ['anglais', 'english', 'llcer'],
    'Espagnol': ['espagnol', 'spanish', 'espanol'],
    'Allemand': ['allemand', 'german', 'deutsch'],
    'Philosophie': ['philo', 'philosophie'],
    'SES': ['ses', 'economie', 'eco', 'socio'],
    'NSI': ['nsi', 'informatique', 'python', 'algo'],
    'SNT': ['snt'],
    // En dernier : « dissertation de philo » va en Philosophie.
    'Français': ['francais', 'dissertation', 'commentaire', 'litterature', 'poesie'],
  };

  /// Ce qu'on ne touche jamais.
  static bool _keep(String name) {
    final n = name.toLowerCase();
    return n.startsWith('.') ||
        n == 'desktop.ini' ||
        n == 'thumbs.db' ||
        n.endsWith('.lnk') ||
        n.endsWith('.url') ||
        n.endsWith('.crdownload') ||
        n.endsWith('.part') ||
        n.endsWith('.partial') ||
        n.endsWith('.tmp') ||
        n.endsWith('.download');
  }

  static String ext(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  static String? category(String name) {
    final e = ext(name);
    for (final c in categories.entries) {
      if (c.value.contains(e)) return c.key;
    }
    return null;
  }

  /// La matière d'après le nom (« DM_maths_ch3.pdf » → Maths).
  static String? subject(String name) {
    final words = _plain(name).split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toSet();
    for (final s in subjects.entries) {
      if (s.value.any(words.contains)) return s.key;
    }
    return null;
  }

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return '$b';
  }

  /// Les dossiers habituels de Windows (Téléchargements, Bureau…), même
  /// déplacés dans OneDrive.
  static Directory? folder(String what) {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null) return null;
    final sep = Platform.pathSeparator;
    final names = switch (_plain(what).trim()) {
      'telechargements' || 'telechargement' || 'downloads' => ['Downloads', 'Téléchargements'],
      'bureau' || 'desktop' => ['Desktop', 'Bureau', 'OneDrive${sep}Bureau', 'OneDrive${sep}Desktop'],
      'documents' || 'mes documents' => ['Documents', 'OneDrive${sep}Documents'],
      'images' || 'photos' || 'pictures' => ['Pictures', 'Images', 'OneDrive${sep}Images', 'OneDrive${sep}Pictures'],
      'videos' => ['Videos', 'Vidéos'],
      'musique' || 'music' => ['Music', 'Musique'],
      _ => <String>[],
    };
    if (names.isEmpty) {
      final d = Directory(what);
      return d.existsSync() ? d : null;
    }
    // OneDrive d'abord pour le Bureau et les Documents (souvent déplacés).
    for (final n in names.reversed.where((n) => n.contains('OneDrive')).followedBy(names.where((n) => !n.contains('OneDrive')))) {
      final d = Directory('$home$sep$n');
      if (d.existsSync()) return d;
    }
    return null;
  }

  /// Prépare le rangement de [dir] (seulement les fichiers en vrac, pas les
  /// dossiers déjà là). [bySubject] : les cours vont dans « Cours/matière ».
  static Future<TidyPlan> analyze(Directory dir, {bool bySubject = true, bool duplicates = true, DateTime? now}) async {
    final n = now ?? DateTime.now();
    final moves = <TidyMove>[];
    var skipped = 0;
    final files = <File>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (_keep(name)) {
        skipped++;
        continue;
      }
      try {
        // Un fichier en cours d'écriture (téléchargement) : on attend.
        if (n.difference((await e.stat()).modified).inMinutes < 2) {
          skipped++;
          continue;
        }
      } catch (_) {
        skipped++;
        continue;
      }
      files.add(e);
    }

    // Doublons : même taille, puis même contenu ; on garde le plus ancien.
    final dup = <String>{};
    if (duplicates) {
      final bySize = <int, List<File>>{};
      for (final f in files) {
        try {
          final len = await f.length();
          if (len > 0 && len < 300 * 1024 * 1024) bySize.putIfAbsent(len, () => []).add(f);
        } catch (_) {}
      }
      for (final same in bySize.values.where((l) => l.length > 1)) {
        final byHash = <String, List<File>>{};
        for (final f in same) {
          try {
            final h = (await sha1.bind(f.openRead()).first).toString();
            byHash.putIfAbsent(h, () => []).add(f);
          } catch (_) {}
        }
        for (final group in byHash.values.where((l) => l.length > 1)) {
          final dated = [
            for (final f in group) (f, (await f.stat()).modified),
          ]..sort((a, b) => a.$2.compareTo(b.$2));
          for (final (f, _) in dated.skip(1)) {
            dup.add(f.path);
            moves.add(TidyMove(f.path, 'Doublons', 'Copie de ${dated.first.$1.uri.pathSegments.last}'));
          }
        }
      }
    }

    for (final f in files) {
      if (dup.contains(f.path)) continue;
      final name = f.uri.pathSegments.last;
      final cat = category(name);
      final subj = bySubject ? subject(name) : null;
      final school = cat == null || {'PDF', 'Documents', 'Présentations', 'Tableurs', 'Images'}.contains(cat);
      if (subj != null && school) {
        moves.add(TidyMove(f.path, 'Cours${Platform.pathSeparator}$subj', 'Cours de $subj'));
      } else if (cat != null) {
        moves.add(TidyMove(f.path, cat, cat));
      } else {
        moves.add(TidyMove(f.path, 'Autres', 'Type « ${ext(name).isEmpty ? 'sans extension' : ext(name)} »'));
      }
    }
    return TidyPlan(dir.path, moves, skipped: skipped);
  }

  /// Un nom libre dans [dir] (« photo (2).jpg » si « photo.jpg » existe).
  static String freeName(Directory dir, String name) {
    final sep = Platform.pathSeparator;
    if (!File('${dir.path}$sep$name').existsSync() && !Directory('${dir.path}$sep$name').existsSync()) return name;
    final i = name.lastIndexOf('.');
    final base = i > 0 ? name.substring(0, i) : name;
    final e = i > 0 ? name.substring(i) : '';
    for (var k = 2; ; k++) {
      final c = '$base ($k)$e';
      if (!File('${dir.path}$sep$c').existsSync()) return c;
    }
  }

  static Future<File> _move(File f, String to) async {
    try {
      return await f.rename(to);
    } on FileSystemException {
      // Autre disque : copie puis suppression de l'original.
      final c = await f.copy(to);
      await f.delete();
      return c;
    }
  }

  /// Range pour de vrai. Renvoie (nombre rangé, erreurs). Un journal permet
  /// d'annuler ([undoLast]).
  static Future<(int, List<String>)> apply(TidyPlan plan, {Set<String>? only}) async {
    final sep = Platform.pathSeparator;
    final done = <Map<String, String>>[];
    final errors = <String>[];
    for (final m in plan.moves) {
      if (only != null && !only.contains(m.dest)) continue;
      final src = File(m.from);
      if (!src.existsSync()) continue;
      try {
        final dir = Directory('${plan.root}$sep${m.dest}');
        await dir.create(recursive: true);
        final target = '${dir.path}$sep${freeName(dir, m.name)}';
        await _move(src, target);
        done.add({'de': m.from, 'vers': target});
      } catch (e) {
        errors.add('${m.name} : $e');
      }
    }
    if (done.isNotEmpty) {
      final f = await HubFiles.file('rangement-${DateTime.now().millisecondsSinceEpoch}.json');
      await f?.writeAsString(jsonEncode({'type': 'pc', 'racine': plan.root, 'fait': done}));
    }
    return (done.length, errors);
  }

  /// Le dernier rangement (PC ou Drive) enregistré.
  static Future<(File, Map<String, dynamic>)?> lastJournal({String type = 'pc'}) async {
    final d = await HubFiles.dir();
    if (d == null) return null;
    final list = d.listSync().whereType<File>().where((f) => f.uri.pathSegments.last.startsWith('rangement-')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in list) {
      try {
        final j = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
        if ((j['type'] ?? 'pc') == type) return (f, j);
      } catch (_) {}
    }
    return null;
  }

  /// Remet les fichiers du dernier rangement du PC à leur place.
  static Future<int> undoLast() async {
    final last = await lastJournal();
    if (last == null) return 0;
    final (file, j) = last;
    var n = 0;
    final dirs = <String>{};
    for (final m in ((j['fait'] as List?) ?? const []).reversed) {
      final to = File('${m['vers']}');
      final from = '${m['de']}';
      if (!to.existsSync() || File(from).existsSync()) continue;
      try {
        await _move(to, from);
        dirs.add(to.parent.path);
        n++;
      } catch (_) {}
    }
    // Les dossiers créés pour le rangement, s'ils sont vides.
    for (final p in dirs.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      try {
        final d = Directory(p);
        if (d.existsSync() && d.listSync().isEmpty) await d.delete();
        final parent = d.parent;
        if (parent.path != '${j['racine']}' && parent.existsSync() && parent.listSync().isEmpty) await parent.delete();
      } catch (_) {}
    }
    await file.delete();
    return n;
  }
}
