import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'module_store.dart';
import 'version.dart';

/// Une nouvelle version publiée sur GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.number,
    required this.url,
    this.size = 0,
    this.sha256,
    this.notes = '',
  });

  /// « v1.23 ».
  final String tag;
  final int number;

  /// Adresse du fichier MonHub-Windows.zip.
  final String url;
  final int size;

  /// Empreinte annoncée par GitHub (vérifiée après le téléchargement).
  final String? sha256;
  final String notes;

  /// Lit la réponse de l'API GitHub (dernière release).
  static UpdateInfo? fromRelease(Map<String, dynamic> j, {String asset = 'MonHub-Windows.zip'}) {
    final tag = '${j['tag_name'] ?? ''}';
    final n = Updater.versionNumber(tag);
    if (n == null) return null;
    final a = ((j['assets'] as List?) ?? const [])
        .whereType<Map>()
        .where((x) => x['name'] == asset)
        .firstOrNull;
    if (a == null) return null;
    final digest = '${a['digest'] ?? ''}';
    return UpdateInfo(
      tag: tag,
      number: n,
      url: '${a['browser_download_url']}',
      size: (a['size'] as num?)?.toInt() ?? 0,
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
      notes: '${j['body'] ?? ''}'.trim(),
    );
  }
}

/// Mises à jour automatiques (Windows) : Mon Hub regarde régulièrement s'il
/// existe une version plus récente sur GitHub. Si oui, l'appli se met en
/// pause, un écran de téléchargement s'affiche, la nouvelle version est
/// téléchargée, vérifiée, installée par-dessus, et Mon Hub redémarre.
///
/// Le dépôt se change à la compilation (`--dart-define=UPDATE_REPO=compte/depot`)
/// pour distribuer l'appli sous un autre nom.
class Updater extends ChangeNotifier {
  Updater._();
  static final instance = Updater._();

  static const repo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'Shideyx/mon-hub');

  /// Seulement l'appli Windows compilée par GitHub (pas les versions de
  /// développement).
  static bool get supported => !kIsWeb && Platform.isWindows && current != null;

  /// Numéro de la version installée (v1.22 → 22), ou null.
  static int? get current => versionNumber(appVersion);

  static int? versionNumber(String tag) {
    final m = RegExp(r'^v?\d+\.(\d+)$').firstMatch(tag.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Nouvelle version trouvée (l'écran de mise à jour s'affiche).
  UpdateInfo? available;

  /// « Plus tard » : on ne repropose pas avant le prochain démarrage.
  bool postponed = false;

  /// 0..1 pendant le téléchargement.
  double? progress;
  int received = 0;
  String status = '';
  String? error;
  bool busy = false;

  /// Appelé juste avant de quitter pour installer (arrêter Clicky partout…).
  Future<void> Function()? beforeInstall;

  Timer? _timer;
  http.Client? _client;

  bool get showing => available != null && !postponed;

  void start() {
    if (!supported || _timer != null) return;
    // La version installée a bien été mise à jour : on oublie l'essai.
    final tried = _tried;
    if (tried != null && (versionNumber(tried) ?? 0) <= (current ?? 0)) _tried = null;
    unawaited(check());
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => check());
  }

  /// iPhone : Apple interdit qu'une appli se mette à jour toute seule hors
  /// App Store. On regarde seulement s'il y a une nouvelle version iPhone
  /// (pour prévenir) : renvoie son numéro (« v1.60 »), ou null.
  static Future<String?> phoneUpdate() async {
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid) || current == null) return null;
    final file = Platform.isIOS ? 'MonHub-iOS.ipa' : 'MonHub-Android.apk';
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
            headers: {'accept': 'application/vnd.github+json', 'user-agent': 'MonHub-Updater'},
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map) return null;
      final tag = '${j['tag_name'] ?? ''}';
      final n = versionNumber(tag);
      final ready = (j['assets'] as List? ?? const []).any((a) => a is Map && a['name'] == file);
      return n != null && n > current! && ready ? tag : null;
    } catch (_) {
      return null;
    }
  }

  /// Regarde sur GitHub. Renvoie la nouvelle version, ou null.
  Future<UpdateInfo?> check({bool manual = false}) async {
    if (!supported) return null;
    if (busy || (postponed && !manual)) return available;
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
            headers: {'accept': 'application/vnd.github+json', 'user-agent': 'MonHub-Updater'},
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final info = UpdateInfo.fromRelease(
        jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>,
      );
      if (info == null || info.number <= (current ?? 1 << 30)) return null;
      available = info;
      if (manual) postponed = false;
      notifyListeners();
      // Directement : l'appli se met en pause et télécharge.
      // Déjà essayée et toujours pas installée : pas de boucle, on explique.
      final tried = _tried;
      if (tried == info.tag) {
        _set(
          status: '',
          progress: null,
          error:
              'La mise à jour vers ${info.tag} n\'a pas pu s\'installer toute seule. Télécharge-la à la main '
              '(bouton ci-dessous), décompresse-la par-dessus ton dossier Mon Hub : les suivantes se feront '
              'toutes seules.',
        );
        return info;
      }
      if (!postponed) unawaited(install());
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Dernière version dont l'installation a été lancée (anti-boucle).
  static String? get _tried {
    try {
      return ModuleStore.global.getString('app.updateTried');
    } catch (_) {
      return null;
    }
  }

  static set _tried(String? v) {
    try {
      if (v == null) {
        unawaited(ModuleStore.global.remove('app.updateTried'));
      } else {
        unawaited(ModuleStore.global.setString('app.updateTried', v));
      }
    } catch (_) {}
  }

  /// Le fichier vient bien des versions publiées de ce dépôt GitHub.
  static bool trustedUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null &&
        u.scheme == 'https' &&
        u.host == 'github.com' &&
        u.path.startsWith('/$repo/releases/download/') &&
        !u.path.contains('..');
  }

  /// Page des versions (téléchargement à la main).
  static String get releasesUrl => 'https://github.com/$repo/releases/latest';

  void later() {
    postponed = true;
    _client?.close();
    _client = null;
    busy = false;
    notifyListeners();
  }

  void _set({String? status, double? progress, String? error}) {
    if (status != null) this.status = status;
    this.progress = progress;
    this.error = error;
    notifyListeners();
  }

  /// Télécharge, vérifie, prépare et lance l'installation.
  Future<void> install() async {
    final info = available;
    if (info == null || busy) return;
    if (!trustedUrl(info.url)) {
      _set(status: '', progress: null, error: 'Adresse de mise à jour inattendue : installation annulée par sécurité.');
      return;
    }
    busy = true;
    error = null;
    received = 0;
    final sep = Platform.pathSeparator;
    final work = Directory('${Directory.systemTemp.path}${sep}MonHub-maj$sep${info.tag}');
    try {
      await work.create(recursive: true);
      final zip = File('${work.path}${sep}MonHub-Windows.zip');

      // 1. Téléchargement (avec la progression).
      _set(status: 'Téléchargement de ${info.tag}…', progress: 0);
      final client = _client = http.Client();
      final res = await client.send(
        http.Request('GET', Uri.parse(info.url))..headers['user-agent'] = 'MonHub-Updater',
      );
      if (res.statusCode != 200) throw 'Téléchargement refusé par GitHub (code ${res.statusCode})';
      final total = res.contentLength ?? info.size;
      final sink = zip.openWrite();
      try {
        await for (final chunk in res.stream) {
          if (postponed) throw 'Mise à jour reportée';
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) _set(progress: (received / total).clamp(0, 1).toDouble());
        }
      } finally {
        await sink.close();
        client.close();
        _client = null;
      }

      // 2. Vérification : le fichier est exactement celui publié (sans
      // empreinte annoncée par GitHub, on n'installe rien).
      _set(status: 'Vérification du fichier…', progress: null);
      final expected = info.sha256;
      if (expected == null) throw 'GitHub n\'a pas donné l\'empreinte du fichier : installation annulée par sécurité';
      final digest = sha256.convert(await zip.readAsBytes()).toString();
      if (digest != expected) {
        throw 'Le fichier téléchargé est abîmé (empreinte différente) : réessaie';
      }

      // 3. Décompression.
      _set(status: 'Préparation de la nouvelle version…', progress: null);
      final out = Directory('${work.path}${sep}app');
      if (await out.exists()) await out.delete(recursive: true);
      await extractFileToDisk(zip.path, out.path);
      final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
      var src = out.path;
      if (!await File('$src$sep$exeName').exists()) {
        // Zip avec un dossier à l'intérieur.
        final sub = (await out.list().toList())
            .where((e) => e is Directory && File('${e.path}$sep$exeName').existsSync())
            .firstOrNull;
        if (sub == null) throw 'La nouvelle version est incomplète ($exeName introuvable)';
        src = sub.path;
      }

      // 4. Installation, sans aucun script (certains PC bloquent PowerShell :
      // l'ancienne méthode ne faisait alors rien, et la mise à jour revenait
      // en boucle). Windows interdit d'écraser un programme lancé, mais
      // permet de le renommer : on met les anciens fichiers de côté, on
      // copie les nouveaux, puis on relance.
      _set(status: 'Installation…', progress: null);
      final dst = File(Platform.resolvedExecutable).parent.path;
      await beforeInstall?.call();
      // Laisse Clicky partout se fermer (il utilise les mêmes fichiers).
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await replaceInPlace(src, dst);
      _set(status: 'C\'est installé : Mon Hub redémarre…', progress: null);
      _tried = info.tag;
      await Process.start(
        '$dst${Platform.pathSeparator}$exeName',
        const ['--updated'],
        workingDirectory: dst,
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      exit(0);
    } catch (e) {
      busy = false;
      if (postponed) return;
      _set(status: '', progress: null, error: '$e');
    }
  }

  /// Suffixe des anciens fichiers mis de côté (supprimés au démarrage
  /// suivant).
  static const oldSuffix = '.ancien-monhub';

  /// Copie la nouvelle version ([src]) par-dessus l'installée ([dst]). Un
  /// fichier en cours d'utilisation est renommé au lieu d'être écrasé. En cas
  /// d'échec, tout est remis comme avant.
  static Future<void> replaceInPlace(String src, String dst) async {
    final sep = Platform.pathSeparator;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    // (fichier installé, nom de l'ancien mis de côté ou null s'il est nouveau)
    final done = <(File, String?)>[];
    try {
      final files = [
        for (final e in await Directory(src).list(recursive: true).toList())
          if (e is File) e,
      ];
      if (files.isEmpty) throw 'La nouvelle version est vide';
      for (final f in files) {
        final rel = f.path.substring(src.length).replaceFirst(RegExp(r'^[\\/]+'), '');
        final target = File('$dst$sep$rel');
        await target.parent.create(recursive: true);
        String? aside;
        if (await target.exists()) {
          // Jamais supprimé : renommé (marche même s'il est en cours
          // d'utilisation), pour pouvoir tout remettre en cas d'échec.
          aside = '${target.path}$oldSuffix$stamp';
          await target.rename(aside);
        }
        done.add((target, aside));
        await f.copy(target.path);
      }
    } catch (e) {
      // Retour en arrière : tout redevient comme avant.
      for (final (target, aside) in done.reversed) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
        if (aside != null) {
          try {
            await File(aside).rename(target.path);
          } catch (_) {}
        }
      }
      final low = '$e'.toLowerCase();
      final denied = low.contains('denied') || low.contains('refusé') || low.contains('errno = 5');
      throw denied
          ? 'Windows refuse de modifier le dossier de Mon Hub ($dst). Installe la nouvelle version à la main '
                'dans un dossier à toi (Documents par exemple) : les suivantes se feront toutes seules.'
          : 'Installation impossible : $e';
    }
  }

  /// Au démarrage : supprime les anciens fichiers mis de côté.
  static Future<void> cleanup() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      await for (final e in dir.list(recursive: true)) {
        if (e is File && e.path.contains(oldSuffix)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
