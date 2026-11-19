import 'dart:convert';

import 'package:http/http.dart' as http;

/// Un jeu gratuit (Epic Games Store).
class FreeGame {
  const FreeGame({required this.id, required this.title, required this.url, this.image = '', this.from, this.to, this.now = true});
  final String id;
  final String title;
  final String url;
  final String image;
  final DateTime? from;
  final DateTime? to;

  /// Gratuit maintenant (sinon : bientôt).
  final bool now;

  Map<String, Object?> toJson() => {
    'id': id,
    'titre': title,
    'lien': url,
    'image': image,
    'debut': from?.toIso8601String(),
    'fin': to?.toIso8601String(),
    'maintenant': now,
  };

  static FreeGame fromJson(Map m) => FreeGame(
    id: '${m['id']}',
    title: '${m['titre']}',
    url: '${m['lien']}',
    image: '${m['image'] ?? ''}',
    from: DateTime.tryParse('${m['debut']}'),
    to: DateTime.tryParse('${m['fin']}'),
    now: m['maintenant'] == true,
  );
}

/// Un jeu de la liste de souhaits Steam en promo.
class SteamDeal {
  const SteamDeal({required this.appId, required this.name, required this.discount, required this.price, required this.before});
  final int appId;
  final String name;
  final int discount;
  final String price;
  final String before;

  String get url => 'https://store.steampowered.com/app/$appId/';

  Map<String, Object> toJson() => {'appid': appId, 'nom': name, 'remise': discount, 'prix': price, 'avant': before};

  static SteamDeal fromJson(Map m) => SteamDeal(
    appId: (m['appid'] as num).toInt(),
    name: '${m['nom']}',
    discount: (m['remise'] as num).toInt(),
    price: '${m['prix']}',
    before: '${m['avant']}',
  );
}

/// Jeux gratuits et promos : seulement des adresses publiques (Epic, Steam),
/// sans compte ni clé. Rien n'est envoyé à part l'identifiant Steam public
/// que la personne a donné.
class GameDeals {
  GameDeals._();

  static const _ua = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) MonHub', 'Accept-Language': 'fr-FR'};

  static const epicUrl =
      'https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=fr&country=FR&allowCountries=FR';

  static Future<List<FreeGame>> epic({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse(epicUrl), headers: _ua).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw 'Epic : erreur ${r.statusCode}';
      return parseEpic(jsonDecode(utf8.decode(r.bodyBytes)));
    } finally {
      if (client == null) c.close();
    }
  }

  /// Lit la réponse d'Epic : les jeux à 0 € maintenant, et ceux de la semaine prochaine.
  static List<FreeGame> parseEpic(Object? json) {
    final out = <FreeGame>[];
    final elements = (((json as Map?)?['data'] as Map?)?['Catalog'] as Map?)?['searchStore'] as Map?;
    for (final e in (elements?['elements'] as List?) ?? const []) {
      if (e is! Map) continue;
      final promos = e['promotions'];
      if (promos is! Map) continue;
      (DateTime?, DateTime?)? free(Object? groups) {
        for (final g in (groups as List?) ?? const []) {
          for (final o in ((g as Map?)?['promotionalOffers'] as List?) ?? const []) {
            if (o is! Map) continue;
            final pct = (o['discountSetting'] as Map?)?['discountPercentage'];
            if (pct == 0) return (DateTime.tryParse('${o['startDate']}'), DateTime.tryParse('${o['endDate']}'));
          }
        }
        return null;
      }

      final nowFree = free(promos['promotionalOffers']);
      final soon = nowFree == null ? free(promos['upcomingPromotionalOffers']) : null;
      final when = nowFree ?? soon;
      if (when == null) continue;
      String slug = '${e['productSlug'] ?? ''}';
      for (final key in ['catalogNs', 'offerMappings']) {
        if (slug.isNotEmpty && slug != 'null' && slug != '[]') break;
        final ns = e['catalogNs'];
        final maps = key == 'catalogNs' ? (ns is Map ? ns['mappings'] : null) : e['offerMappings'];
        for (final m in (maps as List?) ?? const []) {
          if (m is! Map) continue;
          final s = '${m['pageSlug'] ?? ''}';
          if (s.isNotEmpty) {
            slug = s;
            break;
          }
        }
      }
      slug = slug.split('/').first;
      String image = '';
      for (final img in (e['keyImages'] as List?) ?? const []) {
        if (img is! Map) continue;
        final t = '${img['type']}';
        if (t == 'OfferImageWide' || t == 'Thumbnail' || t == 'DieselStoreFrontWide') {
          image = '${img['url'] ?? ''}';
          if (t == 'OfferImageWide') break;
        }
      }
      out.add(
        FreeGame(
          id: '${e['id'] ?? e['title']}',
          title: '${e['title'] ?? 'Jeu'}',
          url: slug.isEmpty || slug == 'null' ? 'https://store.epicgames.com/fr/free-games' : 'https://store.epicgames.com/fr/p/$slug',
          image: image,
          from: when.$1,
          to: when.$2,
          now: nowFree != null,
        ),
      );
    }
    return out;
  }

  /// Le numéro Steam (17 chiffres) d'un lien de profil, d'un pseudo ou d'un numéro.
  static Future<String?> steamId(String input, {http.Client? client}) async {
    final t = input.trim();
    final direct = RegExp(r'(7656119\d{10})').firstMatch(t);
    if (direct != null) return direct[1];
    final vanity = RegExp(r'steamcommunity\.com/id/([A-Za-z0-9_-]{2,32})').firstMatch(t)?[1] ??
        (RegExp(r'^[A-Za-z0-9_-]{2,32}$').hasMatch(t) ? t : null);
    if (vanity == null) return null;
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(Uri.parse('https://steamcommunity.com/id/$vanity/?xml=1'), headers: _ua)
          .timeout(const Duration(seconds: 15));
      return RegExp(r'<steamID64>(\d{17})</steamID64>').firstMatch(r.body)?[1];
    } finally {
      if (client == null) c.close();
    }
  }

  /// Les jeux de la liste de souhaits (publique) en promo d'au moins [min] %.
  static Future<List<SteamDeal>> steamDeals(String steamId, {int min = 20, http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final w = await c
          .get(Uri.parse('https://api.steampowered.com/IWishlistService/GetWishlist/v1/?steamid=$steamId'), headers: _ua)
          .timeout(const Duration(seconds: 20));
      if (w.statusCode != 200) throw 'Steam : liste de souhaits introuvable (est-elle publique ?)';
      final ids = parseWishlist(jsonDecode(w.body));
      if (ids.isEmpty) return const [];
      final deals = <(int, int, String, String)>[];
      for (var i = 0; i < ids.length; i += 50) {
        final chunk = ids.sublist(i, (i + 50).clamp(0, ids.length));
        final p = await c
            .get(
              Uri.parse('https://store.steampowered.com/api/appdetails?appids=${chunk.join(',')}&cc=fr&filters=price_overview'),
              headers: _ua,
            )
            .timeout(const Duration(seconds: 20));
        if (p.statusCode == 200) deals.addAll(parsePrices(jsonDecode(p.body), min));
      }
      final out = <SteamDeal>[];
      for (final d in deals.take(15)) {
        var name = 'Jeu ${d.$1}';
        try {
          final n = await c
              .get(Uri.parse('https://store.steampowered.com/api/appdetails?appids=${d.$1}&cc=fr&l=french&filters=basic'), headers: _ua)
              .timeout(const Duration(seconds: 15));
          name = '${((jsonDecode(n.body) as Map)['${d.$1}'] as Map?)?['data']?['name'] ?? name}';
        } catch (_) {}
        out.add(SteamDeal(appId: d.$1, name: name, discount: d.$2, price: d.$3, before: d.$4));
      }
      out.sort((a, b) => b.discount.compareTo(a.discount));
      return out;
    } finally {
      if (client == null) c.close();
    }
  }

  static List<int> parseWishlist(Object? json) => [
    for (final it in (((json as Map?)?['response'] as Map?)?['items'] as List?) ?? const [])
      if ((it as Map?)?['appid'] is num) (it!['appid'] as num).toInt(),
  ];

  /// (appid, remise %, prix, prix avant) des jeux en promo d'au moins [min] %.
  static List<(int, int, String, String)> parsePrices(Object? json, int min) {
    final out = <(int, int, String, String)>[];
    if (json is! Map) return out;
    for (final e in json.entries) {
      // Steam renvoie « data: [] » pour un jeu sans prix (gratuit, pas encore sorti).
      final v = e.value;
      final data = v is Map ? v['data'] : null;
      final p = data is Map && data['price_overview'] is Map ? data['price_overview'] as Map : null;
      final pct = p?['discount_percent'];
      if (p == null || pct is! num || pct < min) continue;
      final id = int.tryParse('${e.key}');
      if (id == null) continue;
      out.add((id, pct.toInt(), '${p['final_formatted'] ?? ''}', '${p['initial_formatted'] ?? ''}'));
    }
    return out;
  }
}
