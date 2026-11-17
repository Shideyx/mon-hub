import 'dart:convert';
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'module_store.dart';

/// Coffre-fort local : chiffre les données de Mon Hub enregistrées sur
/// l'appareil (historiques de Clicky, journal, carnet, routines…) en
/// AES-256-GCM.
///
/// La clé est tirée au hasard, une par compte Mon Hub, et rangée dans le
/// coffre du système (Gestionnaire d'identification Windows, Trousseau,
/// Keystore Android). Rien ne sort de l'appareil : sans cette clé, les
/// fichiers sont illisibles, même copiés ailleurs.
class Vault {
  Vault._();

  static const prefix = 'MHV1:';
  static final _aes = AesGcm.with256bits();

  /// Clé imposée (tests).
  @visibleForTesting
  static List<int>? overrideKey;

  static final _keys = <String, Future<SecretKey?>>{};

  static Future<SecretKey?> _key() {
    final o = overrideKey;
    if (o != null) return Future.value(SecretKey(o));
    final profile = ModuleStore.profile;
    return _keys[profile] ??= () async {
      try {
        final name = '${profile}vault.key';
        final saved = await ModuleStore.secure.read(key: name);
        if (saved != null) return SecretKey(base64.decode(saved));
        final fresh = await _aes.newSecretKey();
        final bytes = await fresh.extractBytes();
        await ModuleStore.secure.write(key: name, value: base64.encode(bytes));
        // Relu : si l'autre programme (Clicky partout) a créé la sienne en
        // même temps, on garde celle qui est enregistrée.
        final again = await ModuleStore.secure.read(key: name);
        return again == null ? fresh : SecretKey(base64.decode(again));
      } catch (_) {
        // Pas de coffre du système (rare) : on n'empêche pas l'appli de
        // marcher, les données restent comme avant.
        _keys.remove(profile);
        return null;
      }
    }();
  }

  static bool isSealed(String text) => text.startsWith(prefix);

  /// Chiffre un texte (renvoie le texte tel quel si aucune clé n'est
  /// disponible).
  static Future<String> seal(String plain) async {
    final key = await _key();
    if (key == null) return plain;
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: key);
    return '$prefix${base64.encode(box.concatenation())}';
  }

  /// Déchiffre ce que [seal] a produit (un ancien fichier en clair est
  /// renvoyé tel quel). Lève une erreur si la clé ne correspond pas.
  static Future<String> open(String text) async {
    if (!isSealed(text)) return text;
    final key = await _key();
    if (key == null) throw StateError('Clé du coffre introuvable');
    final box = SecretBox.fromConcatenation(
      base64.decode(text.substring(prefix.length)),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    return utf8.decode(await _aes.decrypt(box, secretKey: key));
  }

  // ---- Export protégé par un mot de passe ----

  static final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 210000, bits: 256);

  /// Chiffre un export avec un mot de passe choisi par la personne.
  static Future<Map<String, Object>> protect(String plain, String password) async {
    final salt = Uint8List.fromList(List.generate(16, (_) => _rnd.nextInt(256)));
    final key = await _kdf.deriveKeyFromPassword(password: password, nonce: salt);
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: key);
    return {
      'chiffre': 'AES-256-GCM / PBKDF2-SHA256',
      'iterations': _kdf.iterations,
      'sel': base64.encode(salt),
      'donnees': base64.encode(box.concatenation()),
    };
  }

  /// Ouvre un export protégé. Lève une erreur si le mot de passe est faux.
  static Future<String> unprotect(Map<String, dynamic> j, String password) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: (j['iterations'] as num?)?.toInt() ?? _kdf.iterations,
      bits: 256,
    );
    final key = await kdf.deriveKeyFromPassword(
      password: password,
      nonce: base64.decode('${j['sel']}'),
    );
    final box = SecretBox.fromConcatenation(
      base64.decode('${j['donnees']}'),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    try {
      return utf8.decode(await _aes.decrypt(box, secretKey: key));
    } on SecretBoxAuthenticationError {
      throw 'Mot de passe incorrect';
    }
  }

  static final _rnd = Random.secure();
}
