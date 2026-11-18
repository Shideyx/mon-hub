import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stockage clé/valeur isolé par module.
///
/// * [getJson] / [setJson] : données ordinaires (SharedPreferences).
/// * [readSecret] / [writeSecret] : mots de passe et jetons, chiffrés par le
///   système (Keychain, Keystore Android, Credential Manager Windows…).
class ModuleStore extends ChangeNotifier {
  static SharedPreferences? _prefs;
  static FlutterSecureStorage secure = const FlutterSecureStorage();

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Préférences communes à tous les comptes (thème, comptes, session).
  static SharedPreferences get global {
    final p = _prefs;
    if (p == null) throw StateError('ModuleStore.init() non appelé');
    return p;
  }

  /// Espace du compte Mon Hub connecté ('' = données d'avant les comptes).
  static String profile = '';

  /// Préférences du compte connecté.
  static ProfilePrefs get prefs => ProfilePrefs(global, profile);

  /// Tous les secrets du compte connecté (clés sans préfixe de compte).
  static Future<Map<String, String>> readAllSecrets() async {
    final all = await secure.readAll();
    return {
      for (final e in all.entries)
        if (_owns(e.key)) e.key.substring(profile.length): e.value,
    };
  }

  static Future<void> writeSecretRaw(String key, String value) =>
      secure.write(key: '$profile$key', value: value);

  static Future<void> deleteSecretRaw(String key) => secure.delete(key: '$profile$key');

  static bool _owns(String fullKey) =>
      profile.isEmpty ? !fullKey.startsWith('p.') : fullKey.startsWith(profile);

  String _moduleId = '';
  void bind(String moduleId) => _moduleId = moduleId;

  /// Force le rafraîchissement des widgets qui écoutent ce module.
  void changed() => notifyListeners();

  String _k(String key) => 'mod.$_moduleId.$key';
  String _sk(String key) => '$profile${_k(key)}';

  T? getJson<T>(String key) {
    final raw = prefs.getString(_k(key));
    if (raw == null) return null;
    return jsonDecode(raw) as T;
  }

  Future<void> setJson(String key, Object? value) async {
    if (value == null) {
      await prefs.remove(_k(key));
    } else {
      await prefs.setString(_k(key), jsonEncode(value));
    }
    notifyListeners();
  }

  Future<String?> readSecret(String key) => secure.read(key: _sk(key));

  Future<void> writeSecret(String key, String? value) async {
    if (value == null) {
      await secure.delete(key: _sk(key));
    } else {
      await secure.write(key: _sk(key), value: value);
    }
    notifyListeners();
  }
}

/// Vue des préférences limitée à un compte Mon Hub : chaque compte a ses
/// propres modules, réglages et connexions.
class ProfilePrefs {
  ProfilePrefs(this._p, this._ns);
  final SharedPreferences _p;
  final String _ns;

  String _k(String k) => '$_ns$k';
  bool _mine(String full) =>
      _ns.isEmpty ? !full.startsWith('p.') && !full.startsWith('app.') : full.startsWith(_ns);

  Set<String> getKeys() => {
    for (final k in _p.getKeys())
      if (_mine(k)) k.substring(_ns.length),
  };
  Object? get(String k) => _p.get(_k(k));
  String? getString(String k) => _p.getString(_k(k));
  int? getInt(String k) => _p.getInt(_k(k));
  bool? getBool(String k) => _p.getBool(_k(k));
  List<String>? getStringList(String k) => _p.getStringList(_k(k));
  Future<bool> setString(String k, String v) => _p.setString(_k(k), v);
  Future<bool> setInt(String k, int v) => _p.setInt(_k(k), v);
  Future<bool> setDouble(String k, double v) => _p.setDouble(_k(k), v);
  Future<bool> setBool(String k, bool v) => _p.setBool(_k(k), v);
  Future<bool> setStringList(String k, List<String> v) => _p.setStringList(_k(k), v);
  Future<bool> remove(String k) => _p.remove(_k(k));
}
