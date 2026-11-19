import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// « Mon mot de passe a-t-il fuité ? » avec la base publique Have I Been
/// Pwned, **sans jamais envoyer le mot de passe** : on calcule son empreinte
/// SHA-1 sur l'appareil, on n'envoie que ses 5 premiers caractères, le site
/// renvoie toutes les empreintes qui commencent pareil (des centaines), et
/// la comparaison se fait ici. Le site ne peut pas savoir lequel on cherchait.
class PwnedPasswords {
  PwnedPasswords._();

  static String hash(String password) => sha1.convert(utf8.encode(password)).toString().toUpperCase();

  /// Combien de fois ce mot de passe apparaît dans des fuites connues (0 = jamais).
  static Future<int> count(String password, {http.Client? client}) async {
    final h = hash(password);
    final prefix = h.substring(0, 5);
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(
            Uri.parse('https://api.pwnedpasswords.com/range/$prefix'),
            // Réponse remplie de fausses lignes : même sa taille ne trahit rien.
            headers: {'Add-Padding': 'true', 'User-Agent': 'MonHub'},
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'Service de vérification indisponible (${r.statusCode})';
      return find(r.body, h.substring(5));
    } finally {
      if (client == null) c.close();
    }
  }

  /// Cherche la fin d'empreinte dans la réponse (« SUFFIXE:NOMBRE » par ligne).
  static int find(String body, String suffix) {
    for (final line in const LineSplitter().convert(body)) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim().toUpperCase() == suffix) {
        return int.tryParse(line.substring(i + 1).trim()) ?? 0;
      }
    }
    return 0;
  }

  /// Ce qu'il faut en penser, en clair.
  static String advice(int n) {
    if (n == 0) {
      return '✅ Ce mot de passe n\'apparaît dans aucune fuite connue. Garde-le pour un seul site, et active la double '
          'authentification là où c\'est possible.';
    }
    final times = n >= 1000000
        ? '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} million de fois'
        : n >= 1000
        ? '${(n / 1000).round()} 000 fois'
        : '$n fois';
    return '⚠️ Ce mot de passe a déjà fuité ($times). Les pirates l\'essaient en premier : change-le partout où tu '
        'l\'utilises, et prends une phrase longue et unique (ex. « 3 chats mangent des crêpes à Lyon ! »).';
  }
}
