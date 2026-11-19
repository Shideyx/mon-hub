/// « Mon argent » : ce qu'un algorithme sait lire dans les mails, **sans IA**
/// (rien n'est envoyé nulle part) : abonnements, essais gratuits, colis.
library;

/// Minuscules sans accents, pour comparer.
String foldText(String s) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i < 0 ? ch : to[i]);
  }
  return b.toString();
}

/// Un service payant connu : son nom, ses adresses d'envoi, son prix
/// habituel (si le mail ne le dit pas) et la page pour résilier.
class KnownService {
  const KnownService(this.name, this.domains, {this.words = const [], this.price, this.cancel = ''});
  final String name;
  final List<String> domains;
  final List<String> words;
  final double? price;
  final String cancel;
}

const knownServices = [
  KnownService('Spotify', ['spotify.com'], price: 11.12, cancel: 'https://www.spotify.com/fr/account/subscription/'),
  KnownService('Deezer', ['deezer.com'], price: 11.99, cancel: 'https://www.deezer.com/account/subscription'),
  KnownService('Netflix', ['netflix.com'], price: 7.99, cancel: 'https://www.netflix.com/cancelplan'),
  KnownService('Disney+', ['disneyplus.com', 'disney.com'], words: ['disney+'], price: 6.99,
      cancel: 'https://www.disneyplus.com/account'),
  KnownService('Prime Video', ['primevideo.com'], words: ['prime video'], price: 6.99,
      cancel: 'https://www.amazon.fr/mc'),
  KnownService('Amazon Prime', ['amazon.fr', 'amazon.com'], words: ['amazon prime', 'abonnement prime'], price: 6.99,
      cancel: 'https://www.amazon.fr/mc'),
  KnownService('YouTube Premium', ['youtube.com'], words: ['youtube premium', 'youtube music premium'], price: 12.99,
      cancel: 'https://www.youtube.com/paid_memberships'),
  KnownService('Apple', ['apple.com', 'itunes.com'], words: ['icloud+', 'apple music', 'apple tv+', 'apple one']),
  KnownService('Google Play', ['google.com', 'googleplay.com'], words: ['google play', 'google one']),
  KnownService('Xbox Game Pass', ['xbox.com', 'microsoft.com'], words: ['game pass', 'xbox'], price: 11.99,
      cancel: 'https://account.microsoft.com/services'),
  KnownService('PlayStation Plus', ['playstation.com', 'sony.com'], words: ['playstation plus', 'ps plus'],
      cancel: 'https://www.playstation.com/fr-fr/support/subscriptions/'),
  KnownService('Nintendo Switch Online', ['nintendo.com', 'nintendo.net', 'nintendo.fr'],
      words: ['nintendo switch online'], cancel: 'https://accounts.nintendo.com/'),
  KnownService('Discord Nitro', ['discord.com', 'discordapp.com'], words: ['nitro'], price: 9.99,
      cancel: 'https://discord.com/settings/subscriptions'),
  KnownService('Roblox Premium', ['roblox.com'], words: ['roblox premium'], price: 5.49,
      cancel: 'https://www.roblox.com/my/account#!/billing'),
  KnownService('Crunchyroll', ['crunchyroll.com'], price: 6.99, cancel: 'https://www.crunchyroll.com/account/membership'),
  KnownService('ADN', ['animationdigitalnetwork.fr', 'animationdigitalnetwork.com'], price: 6.99),
  KnownService('Canal+', ['canalplus.com', 'canal-plus.com'], words: ['canal+'], cancel: 'https://client.canalplus.com/'),
  KnownService('Twitch', ['twitch.tv'], words: ['twitch turbo', 'abonnement twitch']),
  KnownService('Snapchat+', ['snapchat.com'], words: ['snapchat+'], price: 4.49),
  KnownService('ChatGPT', ['openai.com'], words: ['chatgpt plus'], price: 23),
  KnownService('Claude', ['anthropic.com'], words: ['claude pro'], price: 21.6),
  KnownService('EA Play', ['ea.com'], words: ['ea play'], price: 5.99),
  KnownService('Ubisoft+', ['ubisoft.com'], words: ['ubisoft+'], price: 17.99),
];

/// Ce qu'un mail dit d'un abonnement.
class SubFinding {
  const SubFinding({required this.service, this.price, this.yearly = false, this.date, this.kind = 'paiement', this.cancel = ''});
  final String service;
  final double? price;
  final bool yearly;

  /// Prochain prélèvement ou fin de l'essai.
  final DateTime? date;

  /// essai, renouvellement, paiement ou resiliation.
  final String kind;
  final String cancel;
}

/// Ce qu'un mail dit d'un colis.
class ParcelFinding {
  const ParcelFinding({required this.carrier, required this.number, required this.status, this.link = '', this.shop = ''});
  final String carrier;
  final String number;

  /// commande, expedie, en_livraison, a_retirer, livre.
  final String status;
  final String link;
  final String shop;
}

class MoneyRules {
  MoneyRules._();

  static const _months = {
    'janvier': 1, 'janv': 1, 'january': 1, 'jan': 1,
    'fevrier': 2, 'fevr': 2, 'fev': 2, 'february': 2, 'feb': 2,
    'mars': 3, 'march': 3, 'mar': 3,
    'avril': 4, 'avr': 4, 'april': 4, 'apr': 4,
    'mai': 5, 'may': 5,
    'juin': 6, 'june': 6, 'jun': 6,
    'juillet': 7, 'juil': 7, 'july': 7, 'jul': 7,
    'aout': 8, 'august': 8, 'aug': 8,
    'septembre': 9, 'sept': 9, 'sep': 9, 'september': 9,
    'octobre': 10, 'oct': 10, 'october': 10,
    'novembre': 11, 'nov': 11, 'november': 11,
    'decembre': 12, 'dec': 12, 'december': 12,
  };

  /// Le service d'un mail (d'après l'expéditeur, puis les mots du sujet).
  static KnownService? serviceOf(String fromEmail, String subject) {
    final domain = fromEmail.contains('@') ? fromEmail.split('@').last.toLowerCase() : '';
    final s = foldText(subject);
    for (final k in knownServices) {
      if (k.words.any((w) => s.contains(foldText(w)))) return k;
    }
    for (final k in knownServices) {
      // Apple, Google, Amazon, Microsoft envoient de tout : il faut aussi un mot.
      if (k.words.isNotEmpty && k.domains.length > 1 && !k.words.any((w) => s.contains(foldText(w)))) continue;
      if (k.domains.any((d) => domain == d || domain.endsWith('.$d'))) return k;
    }
    return null;
  }

  /// Un montant en euros (« 11,12 € », « €9.99 », « 9.99 EUR »).
  static double? amount(String text) {
    final m = RegExp(r'(\d{1,4}(?:[.,]\d{2}))\s?(?:€|eur\b|euros?)|€\s?(\d{1,4}(?:[.,]\d{2}))', caseSensitive: false)
        .firstMatch(text);
    final v = m == null ? null : (m[1] ?? m[2])!.replaceAll(',', '.');
    final d = v == null ? null : double.tryParse(v);
    return d == null || d <= 0 || d > 500 ? null : d;
  }

  /// La première date d'un texte (« le 12 décembre 2026 », « 12/12/2026 »,
  /// « December 12, 2026 », « 12 déc. »). [now] : pour deviner l'année.
  static DateTime? date(String text, DateTime now) {
    final t = foldText(text);
    DateTime fix(int y, int mo, int d) {
      var dt = DateTime(y, mo, d);
      // Sans année : la prochaine fois que cette date arrive.
      if (y == 0) {
        dt = DateTime(now.year, mo, d);
        if (dt.isBefore(DateTime(now.year, now.month, now.day).subtract(const Duration(days: 2)))) {
          dt = DateTime(now.year + 1, mo, d);
        }
      }
      return dt;
    }

    bool ok(int mo, int d) => mo >= 1 && mo <= 12 && d >= 1 && d <= 31;
    final num = RegExp(r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b').firstMatch(t);
    final mon = RegExp(r'\b(\d{1,2})(?:er)?\s+([a-z]{3,9})\.?\s*(\d{4})?\b').allMatches(t);
    final en = RegExp(r'\b([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?\b').allMatches(t);
    final found = <(int, DateTime)>[];
    if (num != null) {
      var y = int.parse(num[3]!);
      if (y < 100) y += 2000;
      final d = int.parse(num[1]!);
      final mo = int.parse(num[2]!);
      if (ok(mo, d)) found.add((num.start, fix(y, mo, d)));
    }
    for (final m in mon) {
      final mo = _months[m[2]!];
      final d = int.parse(m[1]!);
      if (mo != null && ok(mo, d)) found.add((m.start, fix(m[3] == null ? 0 : int.parse(m[3]!), mo, d)));
    }
    for (final m in en) {
      final mo = _months[m[1]!];
      final d = int.parse(m[2]!);
      if (mo != null && ok(mo, d)) found.add((m.start, fix(m[3] == null ? 0 : int.parse(m[3]!), mo, d)));
    }
    if (found.isEmpty) return null;
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return found.first.$2;
  }

  /// La date qui suit un mot-clé (« se termine le … », « renouvelé le … »),
  /// sinon la première date du texte.
  static DateTime? dateAfter(String text, List<String> keys, DateTime now) {
    final t = foldText(text);
    for (final k in keys) {
      final i = t.indexOf(k);
      if (i >= 0) {
        final d = date(t.substring(i, (i + 120).clamp(0, t.length)), now);
        if (d != null) return d;
      }
    }
    return null;
  }

  static const _trial = ['essai gratuit', 'periode d essai', 'free trial', 'trial', 'offert pendant', 'mois offert'];
  static const _end = ['se termine', 'prend fin', 'expire', 'ends', 'will end', 'fin de votre', 'jusqu au', 'until'];
  static const _renew = [
    'renouvel', 'prochain paiement', 'prochain prelevement', 'prochaine facturation', 'next billing', 'next payment',
    'renews', 'will renew', 'sera preleve', 'sera facture', 'will be charged',
  ];
  static const _paid = ['recu', 'receipt', 'facture', 'invoice', 'paiement', 'payment', 'confirmation de commande', 'merci pour votre achat'];
  static const _cancelled = ['resili', 'annul', 'cancel', 'ne sera pas renouvele', 'ended your', 'a pris fin'];

  /// Lit un mail d'un service payant.
  static SubFinding? subscription({
    required String fromEmail,
    required String subject,
    required String text,
    required DateTime mailDate,
  }) {
    final k = serviceOf(fromEmail, subject);
    if (k == null) return null;
    final all = foldText('$subject\n$text').replaceAll('\'', ' ').replaceAll('’', ' ');
    bool any(List<String> words) => words.any(all.contains);
    final cancelled = any(_cancelled);
    final trial = any(_trial);
    final renew = any(_renew);
    final paid = any(_paid);
    if (!cancelled && !trial && !renew && !paid) return null;
    final yearly = RegExp(r'\b(?:par an|annuel|annual|yearly|/an\b|/year\b)').hasMatch(all);
    final price = amount('$subject\n$text') ?? k.price;
    DateTime? when;
    String kind;
    if (cancelled) {
      kind = 'resiliation';
      when = dateAfter(all, const ['jusqu au', 'until', 'expire', 'se termine', 'prend fin'], mailDate);
    } else if (trial) {
      kind = 'essai';
      when = dateAfter(all, _end, mailDate) ?? dateAfter(all, _renew, mailDate);
    } else if (renew) {
      kind = 'renouvellement';
      when = dateAfter(all, _renew, mailDate);
    } else {
      kind = 'paiement';
    }
    // Un paiement sans date : le prochain est un mois (ou un an) plus tard.
    if (when == null && kind == 'paiement') {
      when = yearly
          ? DateTime(mailDate.year + 1, mailDate.month, mailDate.day)
          : DateTime(mailDate.year, mailDate.month + 1, mailDate.day);
    }
    return SubFinding(service: k.name, price: price, yearly: yearly, date: when, kind: kind, cancel: k.cancel);
  }

  // ------------------------------------------------------------ Colis
  static final _carriers = <String, (List<String>, RegExp)>{
    'Colissimo': (['colissimo', 'laposte'], _colissimo),
    'Chronopost': (['chronopost'], _upu),
    'UPS': (['ups.com', 'ups'], _ups),
    'DHL': (['dhl'], _dhl),
    'Mondial Relay': (['mondialrelay', 'mondial relay'], _mondial),
    'Relais Colis': (['relaiscolis', 'relais colis'], _relais),
    'GLS': (['gls'], _gls),
    'DPD': (['dpd'], _dpd),
    'Amazon': (['amazon'], _amazon),
  };
  static final _colissimo = RegExp(r'\b(\d[A-Z]\d{11}|[A-Z]{2}\d{9}FR)\b');
  static final _upu = RegExp(r'\b([A-Z]{2}\d{9}[A-Z]{2})\b');
  static final _ups = RegExp(r'\b(1Z[0-9A-Z]{16})\b');
  static final _dhl = RegExp(r'\b(\d{10}|JJD\d{15,20})\b');
  static final _mondial = RegExp(r'\b(\d{8})\b');
  static final _relais = RegExp(r'\b(\d{10,16})\b');
  static final _gls = RegExp(r'\b(\d{11,12}|[A-Z0-9]{8})\b');
  static final _dpd = RegExp(r'\b(\d{14})\b');
  static final _amazon = RegExp(r'\b(TBA\d{9,12})\b');

  static const _parcelWords = [
    'colis', 'livraison', 'expedi', 'expedie', 'suivi', 'tracking', 'shipped', 'delivery', 'delivered', 'commande',
    'point relais', 'retrait', 'parcel', 'package',
  ];

  /// L'état d'un colis d'après les mots du mail (le plus avancé gagne).
  static String? status(String text) {
    final t = foldText(text).replaceAll('\'', ' ').replaceAll('’', ' ');
    bool any(List<String> w) => w.any(t.contains);
    if (any(['a ete livre', 'avez ete livre', 'colis livre', 'a bien ete livre', 'delivered', 'livraison effectuee', 'remis'])) {
      return 'livre';
    }
    if (any(['point relais', 'disponible en', 'a retirer', 'pret a etre retire', 'en attente de retrait', 'locker', 'consigne',
        'ready for pickup', 'bureau de poste'])) {
      return 'a_retirer';
    }
    if (any(['en cours de livraison', 'livre aujourd hui', 'arrive aujourd hui', 'out for delivery', 'livraison prevue aujourd'])) {
      return 'en_livraison';
    }
    if (any(['expedie', 'expediee', 'shipped', 'pris en charge', 'en route', 'en cours d acheminement', 'on its way', 'a ete envoye'])) {
      return 'expedie';
    }
    if (any(['commande confirmee', 'confirmation de commande', 'order confirmed', 'merci pour votre commande'])) {
      return 'commande';
    }
    return null;
  }

  /// Lit un mail de commande ou de livraison.
  static ParcelFinding? parcel({required String fromEmail, required String fromName, required String subject, required String text}) {
    final all = '$subject\n$text';
    final low = foldText('$fromEmail $fromName $all');
    if (!_parcelWords.any(low.contains)) return null;
    final st = status(all);
    if (st == null) return null;
    final who = foldText('$fromEmail $fromName');
    for (final e in _carriers.entries) {
      // Les numéros très courts (8 chiffres…) seulement si le mail vient du transporteur.
      final fromCarrier = e.value.$1.any(who.contains);
      final generic = e.key == 'Colissimo' || e.key == 'Chronopost' || e.key == 'UPS' || e.key == 'Amazon';
      if (!fromCarrier && !(generic && e.value.$1.any(low.contains))) continue;
      final m = e.value.$2.firstMatch(all);
      if (m != null) {
        return ParcelFinding(carrier: e.key, number: m[1]!, status: st, link: trackingUrl(e.key, m[1]!), shop: shopOf(fromName, fromEmail));
      }
    }
    // Numéro au format La Poste / international, quel que soit l'expéditeur.
    final m = _colissimo.firstMatch(all) ?? _upu.firstMatch(all) ?? _ups.firstMatch(all);
    if (m != null) {
      final carrier = m[1]!.startsWith('1Z') ? 'UPS' : 'Colissimo';
      return ParcelFinding(carrier: carrier, number: m[1]!, status: st, link: trackingUrl(carrier, m[1]!), shop: shopOf(fromName, fromEmail));
    }
    // Lien de suivi sans numéro lisible.
    final link = RegExp(r'https?://[^\s"<>]*(?:suivi|tracking|track|tracker)[^\s"<>]*', caseSensitive: false).firstMatch(text);
    if (link != null) {
      return ParcelFinding(carrier: shopOf(fromName, fromEmail), number: '', status: st, link: link[0]!, shop: shopOf(fromName, fromEmail));
    }
    return null;
  }

  static String shopOf(String fromName, String fromEmail) {
    final n = fromName.trim();
    if (n.isNotEmpty && !n.contains('@')) return n.length > 30 ? n.substring(0, 30) : n;
    final d = fromEmail.split('@').last.split('.');
    return d.length >= 2 ? d[d.length - 2] : fromEmail;
  }

  static String trackingUrl(String carrier, String n) => switch (carrier) {
    'Colissimo' => 'https://www.laposte.fr/outils/suivre-vos-envois?code=$n',
    'Chronopost' => 'https://www.chronopost.fr/tracking-no-cms/suivi-page?listeNumerosLT=$n',
    'UPS' => 'https://www.ups.com/track?loc=fr_FR&tracknum=$n',
    'DHL' => 'https://www.dhl.com/fr-fr/home/suivi.html?tracking-id=$n',
    'Mondial Relay' => 'https://www.mondialrelay.fr/suivi-de-colis/?numeroExpedition=$n',
    'Relais Colis' => 'https://www.relaiscolis.com/suivi-de-colis/index/tracking/?valeur=$n',
    'GLS' => 'https://gls-group.com/FR/fr/suivi-colis?match=$n',
    'DPD' => 'https://www.dpd.fr/trace/$n',
    'Amazon' => 'https://www.amazon.fr/gp/css/order-history',
    _ => '',
  };

  static const statusLabels = {
    'commande': 'Commandé',
    'expedie': 'Expédié',
    'en_livraison': 'Livré aujourd\'hui',
    'a_retirer': 'À retirer',
    'livre': 'Livré',
  };

  static const _order = ['commande', 'expedie', 'en_livraison', 'a_retirer', 'livre'];

  /// [b] est-il plus avancé que [a] ?
  static bool later(String a, String b) => _order.indexOf(b) > _order.indexOf(a);

  /// Prix par mois (un abonnement annuel compte pour 1/12).
  static double monthly(double? price, bool yearly) => price == null ? 0 : (yearly ? price / 12 : price);

  static String euros(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';
}
