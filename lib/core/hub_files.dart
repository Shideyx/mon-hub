import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'claude_bridge.dart';
import 'module_store.dart';
import 'vault.dart';

/// Fichiers de données du compte Mon Hub connecté (historiques des chats,
/// journal de Clicky, routines…), chiffrés sur le disque (voir [Vault]).
///
/// Sur PC, ils vivent dans le dossier de Mon Hub (`%APPDATA%\MonHub\data`),
/// que « Clicky partout » lit et écrit aussi : les deux programmes voient
/// le même historique. Sur téléphone : le dossier privé de l'appli.
class HubFiles {
  HubFiles._();

  /// Dossier imposé (tests).
  @visibleForTesting
  static String? overrideRoot;

  static String? _support;

  static Future<String?> _root() async {
    if (overrideRoot != null) return overrideRoot;
    if (kIsWeb) return null;
    final d = ClaudeBridge.folder;
    if (d != null && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return '$d${Platform.pathSeparator}data';
    }
    try {
      return _support ??= (await getApplicationSupportDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  /// Nom de dossier sûr pour le compte connecté.
  static String get profileFolder {
    final p = ModuleStore.profile.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    return p.isEmpty || p == '_' ? 'default' : p;
  }

  /// Dossier du compte connecté (créé au besoin).
  static Future<Directory?> dir() async {
    final r = await _root();
    if (r == null) return null;
    final d = Directory('$r${Platform.pathSeparator}$profileFolder');
    try {
      await d.create(recursive: true);
    } catch (_) {
      return null;
    }
    return d;
  }

  static Future<File?> file(String name) async {
    final d = await dir();
    return d == null ? null : File('${d.path}${Platform.pathSeparator}$name');
  }
}

/// Un fichier JSON partagé (relu s'il a changé, écrit sans risque de le
/// laisser à moitié écrit). Si le disque n'est pas disponible, les données
/// restent simplement en mémoire.
class JsonFile<T> extends ChangeNotifier {
  JsonFile(this.name, {required this.empty, required this.decode, required this.encode});

  final String name;
  final T Function() empty;
  final T Function(Object? json) decode;
  final Object? Function(T value) encode;

  T? _value;
  DateTime? _stamp;
  String? _profile;

  T get value => _value ??= empty();

  /// Relit le fichier s'il a été modifié (par l'autre programme).
  Future<T> load() async {
    if (_profile != HubFiles.profileFolder) {
      _profile = HubFiles.profileFolder;
      _value = null;
      _stamp = null;
    }
    final f = await HubFiles.file(name);
    if (f == null) return value;
    try {
      if (!await f.exists()) return value;
      final stamp = (await f.stat()).modified;
      if (stamp == _stamp && _value != null) return value;
      final stored = await f.readAsString();
      String raw;
      try {
        // Chiffré sur le disque (coffre local), ou ancien fichier en clair.
        raw = await Vault.open(stored);
      } catch (_) {
        // Clé perdue ou fichier abîmé : on garde une copie au lieu de
        // l'écraser à la prochaine sauvegarde.
        await f.copy('${f.path}.illisible-${DateTime.now().millisecondsSinceEpoch}');
        _stamp = stamp;
        return value;
      }
      _value = raw.trim().isEmpty ? empty() : decode(jsonDecode(raw));
      _stamp = stamp;
    } catch (_) {
      // Fichier abîmé : on repart de ce qu'on a en mémoire.
    }
    return value;
  }

  Future<void> save([T? v]) async {
    if (v != null) _value = v;
    notifyListeners();
    final f = await HubFiles.file(name);
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(await Vault.seal(jsonEncode(encode(value))), flush: true);
      await tmp.rename(f.path);
      _stamp = (await f.stat()).modified;
    } catch (_) {}
  }

  /// Relit, modifie, réenregistre (évite d'écraser ce que l'autre programme
  /// vient d'écrire).
  Future<T> update(T Function(T v) change) async {
    await load();
    final next = change(value);
    await save(next);
    return next;
  }
}
