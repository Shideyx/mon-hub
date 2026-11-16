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

  static SharedPreferences get prefs {
    final p = _prefs;
    if (p == null) throw StateError('ModuleStore.init() non appelé');
    return p;
  }

  String _moduleId = '';
  void bind(String moduleId) => _moduleId = moduleId;

  /// Force le rafraîchissement des widgets qui écoutent ce module.
  void changed() => notifyListeners();

  String _k(String key) => 'mod.$_moduleId.$key';

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

  Future<String?> readSecret(String key) => secure.read(key: _k(key));

  Future<void> writeSecret(String key, String? value) async {
    if (value == null) {
      await secure.delete(key: _k(key));
    } else {
      await secure.write(key: _k(key), value: value);
    }
    notifyListeners();
  }
}
