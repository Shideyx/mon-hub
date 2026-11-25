import 'dart:convert';

import 'package:archive/archive.dart' show GZipDecoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

/// Lecture seule de la copie chiffrée du compte (`compte-<identifiant>.monhub`,
/// même format que `SyncBox` dans `core/account_sync.dart`), pour la version
/// web : elle n'a ni fichiers ni Isolate. Rien n'est réécrit : le PC reste
/// le seul à modifier le compte.
class AccountCopy {
  AccountCopy._();

  static const app = 'mon-hub-compte';

  /// Même calcul que `AppSession.passwordHash`.
  static String passwordHash(String salt, String password) {
    List<int> bytes = utf8.encode('$salt:$password');
    for (var i = 0; i < 20000; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return base64.encode(bytes);
  }

  /// Le contenu (clé → valeur : `p:` réglages, `s:` secrets, `f:` fichiers),
  /// ou une erreur en français (mauvais mot de passe…).
  static Future<Map<String, Object?>> open(String text, String password) async {
    Map j;
    try {
      j = jsonDecode(text) as Map;
      if (j['app'] != app) throw 'x';
    } catch (_) {
      throw 'La copie de ton compte est abîmée.';
    }
    final login = '${j['identifiant']}';
    final salt = base64.decode('${j['sel']}');
    final iterations = (j['iterations'] as num).toInt();
    final accountSalt = j['sel_compte'] as String?;
    final secret = accountSalt == null ? password : passwordHash(accountSalt, password);
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: secret, nonce: salt);
    final aes = AesGcm.with256bits();
    final box = SecretBox.fromConcatenation(
      base64.decode('${j['donnees']}'),
      nonceLength: aes.nonceLength,
      macLength: aes.macAlgorithm.macLength,
    );
    List<int> packed;
    try {
      packed = await aes.decrypt(box, secretKey: key, aad: utf8.encode('$app:$login'));
    } on SecretBoxAuthenticationError {
      throw 'Ce n\'est pas le mot de passe de ton compte Mon Hub.';
    }
    final inner = jsonDecode(utf8.decode(GZipDecoder().decodeBytes(packed))) as Map;
    final data = (inner['donnees'] as Map? ?? const {}).cast<String, dynamic>();
    return {
      for (final e in data.entries)
        if (e.value is List && (e.value as List).isNotEmpty && (e.value as List)[0] != null) e.key: (e.value as List)[0],
      '_nom': (inner['compte'] as Map?)?['nom'],
      '_identifiant': login,
    };
  }

  /// Les souvenirs de Nexo (`memoire.json`) : (sujet, texte), les plus
  /// importants d'abord.
  static List<(String, String)> memories(Map<String, Object?> content, {int max = 60}) {
    final raw = content['f:memoire.json'];
    if (raw is! String) return const [];
    try {
      final j = jsonDecode(raw) as Map;
      final list = [
        for (final m in (j['souvenirs'] as List? ?? const []))
          if (m is Map && '${m['t'] ?? ''}'.trim().isNotEmpty) m,
      ];
      int score(Map m) => ((m['p'] == true) ? 100 : 0) + ((m['w'] as num?)?.toInt() ?? 1);
      list.sort((a, b) => score(b).compareTo(score(a)));
      return [for (final m in list.take(max)) ('${m['s'] ?? 'divers'}', '${m['t']}'.trim())];
    } catch (_) {
      return const [];
    }
  }
}
