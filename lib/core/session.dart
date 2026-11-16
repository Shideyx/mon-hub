import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';

import 'module_store.dart';

/// Un compte Mon Hub (sur cet appareil).
class HubAccount {
  HubAccount(this.login, this.name, this.ns, this.salt, this.hash);
  final String login;
  final String name;

  /// Préfixe des données du compte dans le stockage.
  final String ns;
  final String salt;
  final String hash;

  Map<String, dynamic> toJson() => {'name': name, 'ns': ns, 'salt': salt, 'hash': hash};
  factory HubAccount.fromJson(String login, Map<String, dynamic> j) => HubAccount(
    login,
    j['name'] as String? ?? login,
    j['ns'] as String? ?? '',
    j['salt'] as String,
    j['hash'] as String,
  );
}

/// Comptes Mon Hub, compte connecté et thème (clair / sombre).
///
/// Chaque personne qui utilise l'appli crée son compte (identifiant + mot de
/// passe) : ses modules, réglages et connexions (Instagram, mails…) sont
/// rangés à part. Le mot de passe n'est jamais stocké, seulement une
/// empreinte salée.
class AppSession extends ChangeNotifier {
  AppSession._();
  static final instance = AppSession._();

  static const _accountsKey = 'app.accounts';
  static const _currentKey = 'app.current';
  static const _themeKey = 'app.theme';

  HubAccount? current;

  Map<String, HubAccount> get accounts {
    final raw = ModuleStore.global.getString(_accountsKey);
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final e in m.entries) e.key: HubAccount.fromJson(e.key, e.value as Map<String, dynamic>),
    };
  }

  Future<void> _saveAccounts(Map<String, HubAccount> a) => ModuleStore.global.setString(
    _accountsKey,
    jsonEncode({for (final e in a.entries) e.key: e.value.toJson()}),
  );

  static String _hash(String salt, String password) {
    List<int> bytes = utf8.encode('$salt:$password');
    for (var i = 0; i < 20000; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return base64.encode(bytes);
  }

  static String _random(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  static String normalize(String login) => login.trim().toLowerCase();

  /// Reprend la session gardée (« rester connecté »).
  void restore() {
    final login = ModuleStore.global.getString(_currentKey);
    final acc = login == null ? null : accounts[login];
    if (acc != null) _open(acc);
  }

  void _open(HubAccount acc) {
    current = acc;
    ModuleStore.profile = acc.ns;
    notifyListeners();
  }

  Future<void> register(String login, String name, String password) async {
    final id = normalize(login);
    if (id.length < 3) throw 'L\'identifiant doit faire au moins 3 caractères';
    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(id)) {
      throw 'Identifiant : lettres, chiffres, point, tiret ou _ uniquement';
    }
    if (password.length < 6) throw 'Le mot de passe doit faire au moins 6 caractères';
    final all = accounts;
    if (all.containsKey(id)) throw 'Cet identifiant est déjà pris';
    // Le tout premier compte reprend les données déjà présentes sur l'appareil.
    final hasOldData = ModuleStore.global.getKeys().any(
      (k) => k.startsWith('mod.') || k.startsWith('hub.'),
    );
    final ns = all.isEmpty && hasOldData ? '' : 'p.${_random(10)}.';
    final salt = _random(16);
    final acc = HubAccount(
      id,
      name.trim().isEmpty ? login.trim() : name.trim(),
      ns,
      salt,
      _hash(salt, password),
    );
    all[id] = acc;
    await _saveAccounts(all);
    if (name.trim().isNotEmpty) {
      await ModuleStore.global.setString('${ns}hub.name', name.trim());
    }
    await ModuleStore.global.setString(_currentKey, id);
    _open(acc);
  }

  Future<void> signIn(String login, String password, {bool remember = true}) async {
    final acc = accounts[normalize(login)];
    if (acc == null || _hash(acc.salt, password) != acc.hash) {
      throw 'Identifiant ou mot de passe incorrect';
    }
    if (remember) {
      await ModuleStore.global.setString(_currentKey, acc.login);
    } else {
      await ModuleStore.global.remove(_currentKey);
    }
    _open(acc);
  }

  Future<void> signOut() async {
    await ModuleStore.global.remove(_currentKey);
    current = null;
    ModuleStore.profile = '';
    notifyListeners();
  }

  /// Supprime le compte connecté et toutes ses données sur cet appareil.
  Future<void> deleteAccount() async {
    final acc = current;
    if (acc == null) return;
    final p = ModuleStore.prefs;
    for (final k in p.getKeys()) {
      await p.remove(k);
    }
    for (final k in (await ModuleStore.readAllSecrets()).keys) {
      await ModuleStore.secure.delete(key: '${acc.ns}$k');
    }
    final all = accounts..remove(acc.login);
    await _saveAccounts(all);
    await signOut();
  }

  // ---- Thème ----
  ThemeMode get themeMode => switch (ModuleStore.global.getString(_themeKey)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  Future<void> setThemeMode(ThemeMode m) async {
    await ModuleStore.global.setString(_themeKey, m.name);
    notifyListeners();
  }
}
