/// **Bouclier anti-arnaque**, sur le PC (rien n'est envoyé ailleurs) : repère
/// les pièges classiques envoyés aux jeunes sur Discord, Roblox, Instagram
/// ou par mail — faux « Nitro / Robux gratuits », sites sosies
/// (dlscord.com, steamcommunnity.com…), espions d'adresse IP, « teste mon
/// jeu » avec un .exe, faux signalements, codes à envoyer…
enum ScamLevel { ok, suspect, danger }

class ScamVerdict {
  const ScamVerdict(this.level, this.reasons);
  final ScamLevel level;
  final List<String> reasons;

  bool get danger => level == ScamLevel.danger;
  bool get suspect => level != ScamLevel.ok;

  /// Ce que Smily dit.
  String say() => switch (level) {
    ScamLevel.ok => 'Je ne vois rien de suspect.',
    ScamLevel.suspect => 'Méfie-toi : ${reasons.join(' ; ')}.',
    ScamLevel.danger =>
      'Attention, ça ressemble à une arnaque : ${reasons.join(' ; ')}. N\'ouvre pas et ne donne rien.',
  };
}

class ScamShield {
  ScamShield._();

  /// Les vrais sites (nom de domaine → marque).
  static const official = {
    'discord.com': 'Discord', 'discord.gg': 'Discord', 'discordapp.com': 'Discord', 'discord.gift': 'Discord',
    'discordapp.net': 'Discord', 'discord.media': 'Discord',
    'roblox.com': 'Roblox', 'rbxcdn.com': 'Roblox', 'roblox.qq.com': 'Roblox',
    'steampowered.com': 'Steam', 'steamcommunity.com': 'Steam', 'steamstatic.com': 'Steam',
    'instagram.com': 'Instagram', 'facebook.com': 'Facebook', 'fb.com': 'Facebook',
    'google.com': 'Google', 'youtube.com': 'YouTube', 'youtu.be': 'YouTube', 'gmail.com': 'Google',
    'microsoft.com': 'Microsoft', 'live.com': 'Microsoft', 'outlook.com': 'Microsoft', 'xbox.com': 'Xbox',
    'epicgames.com': 'Epic Games', 'fortnite.com': 'Fortnite', 'tiktok.com': 'TikTok', 'snapchat.com': 'Snapchat',
    'twitch.tv': 'Twitch', 'paypal.com': 'PayPal', 'apple.com': 'Apple', 'icloud.com': 'Apple',
    'ecoledirecte.com': 'École Directe', 'minecraft.net': 'Minecraft', 'mojang.com': 'Minecraft',
    'spotify.com': 'Spotify', 'netflix.com': 'Netflix', 'amazon.fr': 'Amazon', 'amazon.com': 'Amazon',
    'x.com': 'X', 'twitter.com': 'X', 'github.com': 'GitHub', 'whatsapp.com': 'WhatsApp',
    // Leurs serveurs d'images et de fichiers.
    'googleusercontent.com': 'Google', 'googleapis.com': 'Google', 'gstatic.com': 'Google', 'ggpht.com': 'Google',
    'ytimg.com': 'YouTube', 'cdninstagram.com': 'Instagram', 'fbcdn.net': 'Facebook', 'steamusercontent.com': 'Steam',
    'xboxlive.com': 'Xbox', 'tenor.com': 'Tenor', 'giphy.com': 'Giphy', 'imgur.com': 'Imgur', 'medal.tv': 'Medal',
  };

  /// Les marques que les arnaqueurs imitent le plus (pour repérer les sosies).
  static const _phished = [
    'discord',
    'discordapp',
    'roblox',
    'steampowered',
    'steamcommunity',
    'instagram',
    'paypal',
    'epicgames',
    'fortnite',
    'minecraft',
    'ecoledirecte',
    'microsoft',
    'snapchat',
    'netflix',
    'spotify',
    'youtube',
    'google',
  ];

  /// Les marques les plus imitées (leur nom dans un faux domaine).
  static const _brands = [
    'discord',
    'nitro',
    'roblox',
    'robux',
    'steam',
    'instagram',
    'paypal',
    'google',
    'microsoft',
    'xbox',
    'epicgames',
    'fortnite',
    'vbucks',
    'tiktok',
    'snapchat',
    'twitch',
    'netflix',
    'apple',
    'minecraft',
    'ecoledirecte',
    'spotify',
  ];

  /// Espions d'adresse IP et raccourcisseurs souvent utilisés pour piéger.
  static const _loggers = [
    'grabify',
    'iplogger',
    'blasze',
    'ps3cfw',
    'yip.su',
    '2no.co',
    'iplis',
    'bmwforum',
    'leancoding',
  ];
  static const _shorteners = [
    'bit.ly',
    'tinyurl.com',
    'cutt.ly',
    'is.gd',
    'rb.gy',
    't.ly',
    'shorturl.at',
    'ow.ly',
    'tiny.cc',
    'rebrand.ly',
  ];

  /// Fichiers qui lancent un programme.
  static final _exe = RegExp(
    r'\.(exe|scr|bat|cmd|msi|vbs|js|jar|ps1|lnk|hta|pif|com|reg|apk)(\b|$)',
    caseSensitive: false,
  );
  static final _archive = RegExp(r'\.(zip|rar|7z)(\b|$)', caseSensitive: false);

  static final _url = RegExp(
    r'''(?:https?://|www\.)[^\s<>"'\)\]]+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:gift|gg|ru|xyz|top|click|link|site|online|shop|store|live|fun|icu|cfd|sbs|lol|pw|tk|ml|ga|cf|gq|cc|io|me|co|com|net|org|fr)\b(?:/[^\s<>"']*)?''',
    caseSensitive: false,
  );

  /// Les liens d'un texte.
  static List<String> links(String text) => [
    for (final m in _url.allMatches(text)) m[0]!.replaceAll(RegExp(r'[.,;:!?]+$'), ''),
  ];

  static String _host(String url) {
    var u = url.trim();
    if (!u.contains('://')) u = 'https://$u';
    return (Uri.tryParse(u)?.host ?? '').toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  }

  /// Le domaine « principal » (discord.com pour cdn.discord.com).
  static String registrable(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    const twoLevel = {'co.uk', 'com.br', 'qq.com', 'gouv.fr'};
    final last2 = parts.sublist(parts.length - 2).join('.');
    if (twoLevel.contains(last2) && parts.length >= 3) return parts.sublist(parts.length - 3).join('.');
    return last2;
  }

  static int _distance(String a, String b) {
    if ((a.length - b.length).abs() > 2) return 3;
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final c = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// Vérifie un lien.
  static ScamVerdict checkUrl(String url) {
    final reasons = <String>[];
    var level = ScamLevel.ok;
    void bad(String r, {bool danger = true}) {
      reasons.add(r);
      if (danger) {
        level = ScamLevel.danger;
      } else if (level == ScamLevel.ok) {
        level = ScamLevel.suspect;
      }
    }

    final host = _host(url);
    if (host.isEmpty) return const ScamVerdict(ScamLevel.ok, []);
    final reg = registrable(host);
    final path = url.toLowerCase();
    if (official.containsKey(reg)) {
      // Un vrai site… sauf une connexion par QR code ou un « cadeau » louche.
      if (reg.startsWith('discord') && path.contains('/ra/')) {
        bad('lien de connexion à Discord par QR code (vol de compte classique)');
      }
      return ScamVerdict(level, reasons);
    }
    if (_loggers.any(host.contains)) bad('c\'est un espion d\'adresse IP ($reg)');
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      bad('adresse en chiffres au lieu d\'un nom de site', danger: false);
    }
    if (host.contains('xn--')) bad('nom de site avec des lettres déguisées');
    if (_shorteners.contains(reg)) bad('lien raccourci : on ne voit pas où il mène', danger: false);
    // Un site qui se fait passer pour une marque (dlscord, steamcommunnity…).
    final name = reg.split('.').first.replaceAll('-', '');
    for (final b in _phished) {
      final d = _distance(name, b);
      if (name != b && d <= (b.length >= 8 ? 2 : 1)) {
        bad('faux site qui imite ${b[0].toUpperCase()}${b.substring(1)} ($reg)');
        break;
      }
    }
    final gift = RegExp(
      r'free|gratuit|gift|claim|giveaway|reward|airdrop|bonus|nitro|robux|vbucks',
      caseSensitive: false,
    ).hasMatch(host);
    if (level != ScamLevel.danger) {
      // Le nom de la marque comme un mot du site (« discord-nitro.gift »,
      // « freerobux.xyz »), pas caché dans un autre mot (« pineapple »).
      final words = host.split(RegExp(r'[.-]'));
      bool uses(String b) => words.any((w) => w == b || w.startsWith(b) || (gift && w.contains(b)));
      for (final b in _brands) {
        if (uses(b)) {
          // « discord-nitro-gift.com » : danger ; « mon-fan-site-roblox.fr » : méfiance.
          bad('le site utilise le nom « $b » mais ce n\'est pas le vrai site ($reg)', danger: gift);
          break;
        }
      }
    }
    if (gift && level == ScamLevel.ok) bad('site de « cadeau gratuit »', danger: false);
    if (_exe.hasMatch(Uri.tryParse(url.contains('://') ? url : 'https://$url')?.path ?? '')) {
      bad('le lien télécharge un programme');
    }
    return ScamVerdict(level, reasons);
  }

  /// Phrases typiques des arnaques (en français et en anglais).
  static final _phrases = <(RegExp, String, bool)>[
    (
      RegExp(
        r'(free|gratuit\w*|offert\w*)\W+(discord\s+)?nitro|nitro\W+(free|gratuit\w*|offert)',
        caseSensitive: false,
      ),
      'promesse de Nitro gratuit',
      true,
    ),
    (
      RegExp(r'(free|gratuit\w*)\W+robux|robux\W+(free|gratuit\w*|illimit)', caseSensitive: false),
      'promesse de Robux gratuits',
      true,
    ),
    (
      RegExp(r'(free|gratuit\w*)\W+(v-?bucks|skins?)|steam\W+(gift|cadeau)', caseSensitive: false),
      'cadeau de jeu gratuit',
      true,
    ),
    (
      RegExp(
        r'(signal|report)\w*\W+(par erreur|by mistake|accidentally)|(accidentally|par erreur)\W+report',
        caseSensitive: false,
      ),
      'faux « je t\'ai signalé par erreur » (arnaque au support)',
      true,
    ),
    (
      RegExp(
        r'(envoie|donne|send|give)\w*\W+(moi\W+)?(le |ton |the |your )?(code|mot de passe|password|2fa|sms)',
        caseSensitive: false,
      ),
      'on te demande un code ou un mot de passe',
      true,
    ),
    (
      RegExp(r'(scan|scanne)\w*\W+(ce |le |this |the )?qr', caseSensitive: false),
      'on te demande de scanner un QR code (vol de compte)',
      true,
    ),
    (
      RegExp(r'(test|teste|essaie|try)\w*\W+(mon|my|notre|our)\W+(jeu|game|appli|app|logiciel)', caseSensitive: false),
      '« teste mon jeu » (souvent un virus)',
      false,
    ),
    (
      RegExp(
        r'(compte|account)\W+(va être|will be|sera)\W+(supprim|banni|bann|desactiv|delet|disabl|suspend)',
        caseSensitive: false,
      ),
      'menace de supprimer ton compte',
      false,
    ),
    (RegExp(r'(vote|voter)\W+(pour moi|for me)', caseSensitive: false), '« vote pour moi » avec un lien', false),
    (
      RegExp(r'(gagn|won|win)\w*\W+(un |an? )?(iphone|ps5|airpods|carte cadeau|gift card)', caseSensitive: false),
      'faux gain d\'un cadeau',
      false,
    ),
  ];

  /// Vérifie un message entier (texte + liens + noms de fichiers joints).
  static ScamVerdict checkMessage(String text, {List<String> files = const []}) {
    final reasons = <String>[];
    var level = ScamLevel.ok;
    void add(ScamVerdict v) {
      for (final r in v.reasons) {
        if (!reasons.contains(r)) reasons.add(r);
      }
      if (v.level.index > level.index) level = v.level;
    }

    final found = links(text);
    for (final l in found) {
      add(checkUrl(l));
    }
    for (final (re, why, danger) in _phrases) {
      if (re.hasMatch(text)) {
        // Une phrase louche seule = méfiance ; avec un lien ou un fichier = danger.
        add(ScamVerdict(danger || found.isNotEmpty || files.isNotEmpty ? ScamLevel.danger : ScamLevel.suspect, [why]));
      }
    }
    for (final f in files) {
      if (_exe.hasMatch(f)) add(ScamVerdict(ScamLevel.danger, ['fichier « $f » qui lance un programme']));
      if (_archive.hasMatch(f) && level != ScamLevel.ok) {
        add(ScamVerdict(ScamLevel.danger, ['archive « $f » envoyée avec un message louche']));
      }
    }
    return ScamVerdict(level, reasons);
  }
}
