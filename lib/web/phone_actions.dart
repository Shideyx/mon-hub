import 'dart:convert';

/// Ce que Smily peut faire **sur le téléphone** depuis la version web.
///
/// Une page web ne peut pas piloter l'iPhone toute seule (Apple l'interdit) :
/// elle ouvre les applis par leurs liens (`tel:`, `sms:`, Plans, Spotify…),
/// lance les **Raccourcis** de l'iPhone (`shortcuts://run-shortcut`), ajoute un
/// événement à l'agenda (fichier .ics), partage, copie, et garde un minuteur
/// tant que Mon Hub est ouvert. Rien ne part tout seul : chaque action est
/// un bouton que la personne touche (un SMS est seulement **préparé**).
class PhoneAction {
  const PhoneAction(
    this.kind,
    this.label, {
    this.url,
    this.fallbackUrl,
    this.ics,
    this.share,
    this.copy,
    this.timer,
    this.timerFor,
    this.contact,
    this.say,
  });

  /// appel, sms, mail, itineraire, raccourci, appli, musique, recherche,
  /// agenda, minuteur, partager, copier, contact.
  final String kind;

  /// Texte du bouton (« 📞 Appeler Maman »).
  final String label;

  /// Le lien à ouvrir.
  final String? url;

  /// Si l'appli n'est pas sur le téléphone (ex. Spotify → open.spotify.com).
  final String? fallbackUrl;

  /// Événement d'agenda (contenu du fichier .ics).
  final String? ics;

  /// Texte à partager (feuille de partage de l'iPhone).
  final String? share;

  /// Texte à copier.
  final String? copy;

  /// Minuteur (gardé par Mon Hub tant qu'il est ouvert).
  final Duration? timer;
  final String? timerFor;

  /// Contact à retenir : (nom, numéro).
  final (String, String)? contact;

  /// Ce que Smily répond en proposant l'action.
  final String? say;

  /// Les actions qui se font sans bouton (rien ne sort du téléphone).
  bool get immediate => kind == 'minuteur' || kind == 'contact';

  Map<String, Object?> toJson() => {
    'k': kind,
    'l': label,
    'u': ?url,
    'f': ?fallbackUrl,
    'i': ?ics,
    's': ?share,
    'c': ?copy,
    if (timer != null) 't': timer!.inSeconds,
    'tf': ?timerFor,
    if (contact != null) 'n': [contact!.$1, contact!.$2],
  };

  static PhoneAction? fromJson(Object? j) {
    if (j is! Map || j['k'] is! String) return null;
    final n = j['n'];
    return PhoneAction(
      '${j['k']}',
      '${j['l'] ?? ''}',
      url: j['u'] as String?,
      fallbackUrl: j['f'] as String?,
      ics: j['i'] as String?,
      share: j['s'] as String?,
      copy: j['c'] as String?,
      timer: j['t'] is num ? Duration(seconds: (j['t'] as num).toInt()) : null,
      timerFor: j['tf'] as String?,
      contact: n is List && n.length == 2 ? ('${n[0]}', '${n[1]}') : null,
    );
  }
}

/// Les règles, sans IA (testables) : reconnaître une demande et fabriquer le
/// bon lien.
class PhoneRules {
  PhoneRules._();

  static String _enc(String s) => Uri.encodeComponent(s.trim());

  /// Un numéro de téléphone propre (« 06 12 34 56 78 » → « 0612345678 »),
  /// null si ce n'en est pas un.
  static String? number(String raw) {
    final t = raw.trim();
    if (!RegExp(r'^[+\d][\d\s.\-()]{5,}$').hasMatch(t)) return null;
    final digits = t.replaceAll(RegExp(r'[\s.\-()]'), '');
    if (!RegExp(r'^\+?\d{6,15}$').hasMatch(digits)) return null;
    return digits;
  }

  /// Le numéro d'un contact retenu (« maman », « Léo »), ou le numéro tapé.
  static (String name, String number)? who(String raw, Map<String, String> contacts) {
    final t = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final n = number(t);
    if (n != null) return (n, n);
    final key = contactKey(t);
    if (key.isEmpty) return null;
    for (final e in contacts.entries) {
      if (contactKey(e.key) == key) return (e.key, e.value);
    }
    return null;
  }

  /// « ma mère », « Maman », « à maman » → « maman ».
  static String contactKey(String raw) {
    var t = _fold(raw).trim();
    t = t.replaceFirst(RegExp(r"^(a |au |aux |a l'|chez )"), '');
    t = t.replaceFirst(RegExp(r'^(ma |mon |mes )'), '');
    const same = {'mere': 'maman', 'pere': 'papa', 'meuf': 'copine', 'mec': 'copain'};
    return same[t] ?? t;
  }

  static String _fold(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  static PhoneAction call(String name, String num) =>
      PhoneAction('appel', '📞 Appeler $name', url: 'tel:$num', say: 'Je t\'appelle $name ? Touche le bouton.');

  /// Un SMS **préparé** dans Messages (c'est toi qui appuies sur Envoyer).
  /// iOS lit « sms:numéro&body= ».
  static PhoneAction sms(String? name, String? num, String text) => PhoneAction(
    'sms',
    name == null ? '💬 Écrire le message' : '💬 Écrire à $name',
    url: 'sms:${num ?? ''}&body=${_enc(text)}',
    say: name == null
        ? 'J\'ai préparé le message, choisis à qui l\'envoyer.'
        : 'J\'ai préparé le message pour $name : tu n\'as plus qu\'à appuyer sur Envoyer.',
  );

  static PhoneAction mail(String to, String subject, String body) => PhoneAction(
    'mail',
    '✉️ Écrire le mail',
    url: 'mailto:${to.trim()}?subject=${_enc(subject)}&body=${_enc(body)}',
    say: 'Le mail est prêt, il ne reste qu\'à l\'envoyer.',
  );

  /// Itinéraire dans Plans (s'ouvre aussi sans iPhone).
  static PhoneAction route(String place) => PhoneAction(
    'itineraire',
    '🧭 Y aller : ${place.trim()}',
    url: 'https://maps.apple.com/?daddr=${_enc(place)}',
    say: 'Je t\'ouvre l\'itinéraire.',
  );

  /// Un Raccourci de l'iPhone (appli Raccourcis), avec un texte en entrée.
  static String shortcutUrl(String name, [String? input]) =>
      'shortcuts://run-shortcut?name=${_enc(name)}'
      '${input == null || input.trim().isEmpty ? '' : '&input=text&text=${_enc(input)}'}';

  static PhoneAction shortcut(String name, [String? input]) => PhoneAction(
    'raccourci',
    '⚡ Lancer « ${name.trim()} »',
    url: shortcutUrl(name, input),
    say: 'Je lance ton raccourci « ${name.trim()} ».',
  );

  /// Les applis qu'on sait ouvrir par leur lien.
  static const apps = <String, (String, String, String?)>{
    // clé : (nom affiché, lien de l'appli, page web si elle manque)
    'spotify': ('Spotify', 'spotify:', 'https://open.spotify.com'),
    'youtube': ('YouTube', 'youtube://', 'https://m.youtube.com'),
    'instagram': ('Instagram', 'instagram://', 'https://www.instagram.com'),
    'insta': ('Instagram', 'instagram://', 'https://www.instagram.com'),
    'snapchat': ('Snapchat', 'snapchat://', null),
    'snap': ('Snapchat', 'snapchat://', null),
    'whatsapp': ('WhatsApp', 'whatsapp://', null),
    'discord': ('Discord', 'discord://', 'https://discord.com/app'),
    'netflix': ('Netflix', 'nflx://', 'https://www.netflix.com'),
    'deezer': ('Deezer', 'deezer://', 'https://www.deezer.com'),
    'telegram': ('Telegram', 'tg://', null),
    'musique': ('Musique', 'music://', null),
    'apple music': ('Musique', 'music://', null),
    'plans': ('Plans', 'maps://', 'https://maps.apple.com'),
    'calendrier': ('Calendrier', 'calshow://', null),
    'agenda': ('Calendrier', 'calshow://', null),
    'rappels': ('Rappels', 'x-apple-reminderkit://', null),
    'notes': ('Notes', 'mobilenotes://', null),
    'photos': ('Photos', 'photos-redirect://', null),
    'mail': ('Mail', 'message://', null),
    'mails': ('Mail', 'message://', null),
    'raccourcis': ('Raccourcis', 'shortcuts://', null),
    'facetime': ('FaceTime', 'facetime://', null),
    'messages': ('Messages', 'sms:', null),
    'telephone': ('Téléphone', 'tel:', null),
    'ecole directe': ('École Directe', 'https://www.ecoledirecte.com', null),
    'google docs': ('Google Docs', 'https://docs.google.com', null),
    'drive': ('Drive', 'https://drive.google.com', null),
  };

  static PhoneAction? app(String raw) {
    final k = _fold(raw).trim().replaceAll(RegExp(r"^(l'appli |l'application |l'app |appli |app )"), '');
    final a = apps[k];
    if (a == null) return null;
    return PhoneAction('appli', '📱 Ouvrir ${a.$1}', url: a.$2, fallbackUrl: a.$3, say: 'J\'ouvre ${a.$1}.');
  }

  static PhoneAction music(String query) => PhoneAction(
    'musique',
    '🎵 Écouter : ${query.trim()}',
    url: 'spotify:search:${_enc(query)}',
    fallbackUrl: 'https://open.spotify.com/search/${_enc(query)}',
    say: 'Je te mets « ${query.trim()} » sur Spotify.',
  );

  static PhoneAction search(String query) => PhoneAction(
    'recherche',
    '🔍 Chercher : ${query.trim()}',
    url: 'https://www.google.com/search?q=${_enc(query)}',
    say: 'Je cherche « ${query.trim()} ».',
  );

  static PhoneAction timer(Duration d, [String? what]) => PhoneAction(
    'minuteur',
    '⏱️ ${sayDuration(d)}${what == null || what.isEmpty ? '' : ' : $what'}',
    timer: d,
    timerFor: what,
    say:
        'Minuteur de ${sayDuration(d)} lancé${what == null || what.isEmpty ? '' : ' pour « $what »'}. Garde Mon Hub '
        'ouvert (ou demande-moi un rappel dans l\'agenda : lui sonne même téléphone verrouillé).',
  );

  static PhoneAction share(String text) =>
      PhoneAction('partager', '📤 Partager', share: text, say: 'Choisis où l\'envoyer.');

  static PhoneAction copyText(String text) =>
      PhoneAction('copier', '📋 Copier', copy: text, say: 'Touche pour copier.');

  static PhoneAction remember(String name, String num) =>
      PhoneAction('contact', '👤 $name', contact: (name, num), say: 'C\'est noté : $name, $num.');

  /// Un événement d'agenda avec une alarme (l'iPhone sonne même verrouillé).
  static PhoneAction event(String title, DateTime start, {Duration length = const Duration(hours: 1), int alarm = 10}) {
    final when = sayWhen(start);
    return PhoneAction(
      'agenda',
      '📅 Ajouter « ${title.trim()} »',
      ics: ics(title, start, length: length, alarm: alarm),
      say: 'Je l\'ajoute à ton agenda $when, avec une alarme ${alarm == 0 ? 'à l\'heure' : '$alarm min avant'}.',
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _icsDate(DateTime d) {
    final u = d.toUtc();
    return '${u.year}${_two(u.month)}${_two(u.day)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
  }

  static String _icsText(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\n', r'\n');

  static String ics(String title, DateTime start, {Duration length = const Duration(hours: 1), int alarm = 10}) {
    final now = _icsDate(DateTime.now());
    final id = '${start.millisecondsSinceEpoch}-${title.hashCode.abs()}@monhub';
    return [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Mon Hub//Smily//FR',
      'BEGIN:VEVENT',
      'UID:$id',
      'DTSTAMP:$now',
      'DTSTART:${_icsDate(start)}',
      'DTEND:${_icsDate(start.add(length))}',
      'SUMMARY:${_icsText(title.trim())}',
      'BEGIN:VALARM',
      'ACTION:DISPLAY',
      'DESCRIPTION:${_icsText(title.trim())}',
      'TRIGGER:-PT${alarm}M',
      'END:VALARM',
      'END:VEVENT',
      'END:VCALENDAR',
      '',
    ].join('\r\n');
  }

  static String sayDuration(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final parts = [if (h > 0) '$h h', if (m > 0) '$m min', if (s > 0 && h == 0) '$s s'];
    return parts.isEmpty ? '0 s' : parts.join(' ');
  }

  static String sayWhen(DateTime d, [DateTime? now]) {
    final n = now ?? DateTime.now();
    final day = DateTime(d.year, d.month, d.day).difference(DateTime(n.year, n.month, n.day)).inDays;
    final h = '${d.hour} h${d.minute == 0 ? '' : _two(d.minute)}';
    return switch (day) {
      0 => 'aujourd\'hui à $h',
      1 => 'demain à $h',
      2 => 'après-demain à $h',
      _ => 'le ${d.day}/${d.month} à $h',
    };
  }

  /// « 10 min », « 1 h 30 », « 45 secondes », « une heure » → durée.
  static Duration? duration(String raw) {
    var t = _fold(raw).replaceAll('une ', '1 ').replaceAll('un ', '1 ').replaceAll('demi-heure', '30 min');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    final hm = RegExp(r'^(\d+) ?h(?:eures?)? ?(\d+)?(?: ?min(?:utes?)?)?$').firstMatch(t);
    if (hm != null) {
      return Duration(hours: int.parse(hm.group(1)!), minutes: int.tryParse(hm.group(2) ?? '') ?? 0);
    }
    final m = RegExp(r'^(\d+) ?(min|minutes?|mn|m)$').firstMatch(t);
    if (m != null) return Duration(minutes: int.parse(m.group(1)!));
    final s = RegExp(r'^(\d+) ?(s|sec|secondes?)$').firstMatch(t);
    if (s != null) return Duration(seconds: int.parse(s.group(1)!));
    return null;
  }

  /// « demain à 8 h », « à 17h30 », « lundi à 9 h », « ce soir » → date.
  static DateTime? when(String raw, [DateTime? now]) {
    final n = now ?? DateTime.now();
    final t = _fold(raw).trim();
    var day = DateTime(n.year, n.month, n.day);
    var dayGiven = false;
    if (RegExp(r'\bapres-demain\b').hasMatch(t)) {
      day = day.add(const Duration(days: 2));
      dayGiven = true;
    } else if (RegExp(r'\bdemain\b').hasMatch(t)) {
      day = day.add(const Duration(days: 1));
      dayGiven = true;
    } else {
      const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
      for (var i = 0; i < days.length; i++) {
        if (RegExp('\\b${days[i]}\\b').hasMatch(t)) {
          var diff = (i + 1 - n.weekday) % 7;
          if (diff == 0) diff = 7;
          day = day.add(Duration(days: diff));
          dayGiven = true;
          break;
        }
      }
    }
    int? hour, minute;
    final hm = RegExp(r'\b(\d{1,2}) ?h ?(\d{2})?\b').firstMatch(t);
    if (hm != null) {
      hour = int.parse(hm.group(1)!);
      minute = int.tryParse(hm.group(2) ?? '') ?? 0;
    } else if (RegExp(r'\bce soir\b|\bsoir\b').hasMatch(t)) {
      hour = 19;
      minute = 0;
    } else if (RegExp(r'\bmatin\b').hasMatch(t)) {
      hour = 8;
      minute = 0;
    } else if (RegExp(r'\bmidi\b').hasMatch(t)) {
      hour = 12;
      minute = 0;
    } else if (RegExp(r'\baprem|apres-midi\b').hasMatch(t)) {
      hour = 14;
      minute = 0;
    }
    if (hour == null || hour > 23 || minute! > 59) return null;
    var d = DateTime(day.year, day.month, day.day, hour, minute);
    if (!dayGiven && d.isBefore(n)) d = d.add(const Duration(days: 1));
    return d;
  }

  /// Une demande reconnue **entière** → l'action, sinon null (la phrase part
  /// vers l'IA). [contacts] : nom → numéro.
  static PhoneAction? parse(String raw, Map<String, String> contacts, {DateTime? now}) {
    final q = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    final f = _fold(q).replaceAll(RegExp(r'[.!]+$'), '').trim();
    final orig = q.replaceAll(RegExp(r'[.!]+$'), '').trim();
    String tail(RegExpMatch m) => orig.substring(m.end).trim();

    // Retenir un numéro : « le numéro de maman c'est 06… », « retiens le numéro de Léo : 06… ».
    final num = RegExp(
      r"^(?:retiens (?:que )?|note |enregistre )?le (?:numero|num|tel|telephone) de (.+?) (?:c'est|est|:|=) ?([+\d][\d .\-]{5,})$",
    ).firstMatch(f);
    if (num != null) {
      final n = number(num.group(2)!);
      final start = orig.toLowerCase().indexOf(' de ') + 4;
      final name = orig.substring(start, start + num.group(1)!.length).trim();
      if (n != null && name.isNotEmpty) return remember(_cap(name), n);
    }

    // Appeler.
    final c = RegExp(r"^(?:appelle|appeler|telephone a|tel a|passe un coup de fil a|fais (?:le|un) appel a) ").firstMatch(f);
    if (c != null) {
      final w = who(tail(c), contacts);
      if (w != null) return call(_cap(w.$1), w.$2);
      return PhoneAction(
        'contact?',
        '',
        say:
            'Je n\'ai pas le numéro de « ${tail(c)} ». Dis-moi « le numéro de ${tail(c)} c\'est 06… » et je le '
            'retiendrai.',
      );
    }

    // SMS : « envoie un message à maman pour lui dire que j'arrive », « écris à Léo : j'arrive ».
    final s = RegExp(
      r"^(?:envoie|envoyer|ecris|ecrire|texte)(?: un)?(?: (?:sms|message|texto|msg))? a (.+?)(?: pour (?:lui |leur )?dire(?: que| qu')?| : |: | que | qu'|, )(.+)$",
    ).firstMatch(f);
    if (s != null) {
      final textStart = f.length - s.group(2)!.length;
      final text = orig.substring(textStart).trim();
      final w = who(s.group(1)!, contacts);
      return sms(w == null ? null : _cap(w.$1), w?.$2, _cap(text));
    }

    // Itinéraire.
    final r = RegExp(
      r"^(?:itineraire|trajet|emmene-moi|amene-moi|guide-moi|comment (?:aller|je vais|on va))(?: (?:pour|vers|jusqu'a|a|au|aux|chez))? ",
    ).firstMatch(f);
    if (r != null && tail(r).isNotEmpty) return route(tail(r));

    // Raccourci de l'iPhone.
    final sc = RegExp(r'^(?:lance|execute|active|demarre)(?: le| mon)? raccourci ').firstMatch(f);
    if (sc != null && tail(sc).isNotEmpty) return shortcut(tail(sc).replaceAll(RegExp(r'^[«"]|[»"]$'), '').trim());

    // Minuteur : « minuteur 10 min », « mets un minuteur de 5 minutes pour les pâtes ».
    final t = RegExp(r'^(?:mets |lance |demarre )?(?:un )?(?:minuteur|chrono|timer|compte a rebours)(?: de| pour)? (.+)$')
        .firstMatch(f);
    if (t != null) {
      final rest = t.group(1)!;
      final cut = RegExp(r" pour (?:les |la |le |l')?").firstMatch(rest);
      final d = duration(cut == null ? rest : rest.substring(0, cut.start));
      if (d != null && d.inSeconds > 0 && d.inHours < 24) {
        final what = cut == null ? null : _origPart(orig, f, rest.substring(cut.end));
        return timer(d, what);
      }
    }

    // Rappel : « rappelle-moi de X dans 20 min » (minuteur) ou « … demain à 8 h » (agenda).
    final rm = RegExp(r'^rappelle(?:-| )moi (?:de |d\x27|que |qu\x27)(.+?) (dans|demain|apres-demain|ce soir|a|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\b(.*)$')
        .firstMatch(f);
    if (rm != null) {
      final what = _cap(_origPart(orig, f, rm.group(1)!));
      final whenText = '${rm.group(2)}${rm.group(3)}';
      if (rm.group(2) == 'dans') {
        final d = duration(rm.group(3)!.trim());
        if (d != null && d.inSeconds > 0) return timer(d, what);
      } else {
        final at = when(whenText, now);
        if (at != null) return event(what, at, length: const Duration(minutes: 15), alarm: 0);
      }
    }

    // Ouvrir une appli.
    final o = RegExp(r'^(?:ouvre|ouvrir|lance|va sur|mets) ').firstMatch(f);
    if (o != null) {
      final a = app(f.substring(o.end));
      if (a != null) return a;
    }

    // Musique : « mets du Jul », « joue Blinding Lights », « mets de la musique ».
    final mu = RegExp(r'^(?:mets|joue|ecoute|lance)(?: moi)? (?:du |de la |des |de l\x27)?(.+)$').firstMatch(f);
    if (mu != null && RegExp(r'^(?:mets|joue|ecoute)').hasMatch(f)) {
      final what = _origPart(orig, f, mu.group(1)!);
      if (!RegExp(r'^(minuteur|chrono|timer|un |une |le |la |les )').hasMatch(_fold(what))) {
        return music(_fold(what) == 'musique' ? 'Ma playlist' : what);
      }
    }

    // Partager.
    final p = RegExp(r'^partage ').firstMatch(f);
    if (p != null && tail(p).isNotEmpty) return share(tail(p));

    // Chercher.
    final g = RegExp(r'^(?:cherche|recherche|google) ').firstMatch(f);
    if (g != null && tail(g).isNotEmpty) return search(tail(g));

    return null;
  }

  /// Le morceau de [orig] qui correspond à [part] (trouvé dans la version
  /// sans accents [folded], de même longueur).
  static String _origPart(String orig, String folded, String part) {
    final i = folded.indexOf(part);
    if (i < 0 || orig.length != folded.length) return part;
    return orig.substring(i, i + part.length);
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Les actions que Gemini peut demander (déclarations de fonctions).
  static const tools = [
    {
      'name': 'telephone_appeler',
      'description': 'Appeler quelqu\'un (un nom de contact retenu, ou un numéro).',
      'parameters': {
        'type': 'object',
        'properties': {
          'qui': {'type': 'string'},
        },
        'required': ['qui'],
      },
    },
    {
      'name': 'telephone_sms',
      'description': 'Préparer un SMS dans Messages (la personne appuie elle-même sur Envoyer).',
      'parameters': {
        'type': 'object',
        'properties': {
          'qui': {'type': 'string', 'description': 'Nom du contact ou numéro (vide : choisir dans Messages).'},
          'texte': {'type': 'string'},
        },
        'required': ['texte'],
      },
    },
    {
      'name': 'telephone_itineraire',
      'description': 'Ouvrir l\'itinéraire vers un lieu dans Plans.',
      'parameters': {
        'type': 'object',
        'properties': {
          'lieu': {'type': 'string'},
        },
        'required': ['lieu'],
      },
    },
    {
      'name': 'telephone_raccourci',
      'description':
          'Lancer un Raccourci de l\'iPhone (appli Raccourcis) par son nom exact, avec un texte en entrée si besoin. '
          'Sert à tout ce qu\'une page web ne peut pas faire : alarme, minuteur de l\'horloge, mode concentration, '
          'luminosité, lampe, rappel…',
      'parameters': {
        'type': 'object',
        'properties': {
          'nom': {'type': 'string'},
          'texte': {'type': 'string'},
        },
        'required': ['nom'],
      },
    },
    {
      'name': 'telephone_ouvrir_appli',
      'description':
          'Ouvrir une appli du téléphone : Spotify, YouTube, Instagram, Snapchat, WhatsApp, Discord, Netflix, '
          'Deezer, Musique, Plans, Calendrier, Rappels, Notes, Photos, Mail, Raccourcis, FaceTime, Messages.',
      'parameters': {
        'type': 'object',
        'properties': {
          'appli': {'type': 'string'},
        },
        'required': ['appli'],
      },
    },
    {
      'name': 'telephone_musique',
      'description': 'Chercher et jouer une musique, un artiste ou une playlist sur Spotify.',
      'parameters': {
        'type': 'object',
        'properties': {
          'recherche': {'type': 'string'},
        },
        'required': ['recherche'],
      },
    },
    {
      'name': 'telephone_minuteur',
      'description': 'Minuteur dans Mon Hub (sonne tant que Mon Hub est ouvert).',
      'parameters': {
        'type': 'object',
        'properties': {
          'minutes': {'type': 'number'},
          'pour': {'type': 'string'},
        },
        'required': ['minutes'],
      },
    },
    {
      'name': 'telephone_agenda',
      'description': 'Ajouter un événement ou un rappel à l\'agenda de l\'iPhone, avec une alarme.',
      'parameters': {
        'type': 'object',
        'properties': {
          'titre': {'type': 'string'},
          'debut': {'type': 'string', 'description': 'Date et heure locales, format AAAA-MM-JJTHH:MM.'},
          'duree_minutes': {'type': 'number'},
          'alarme_minutes_avant': {'type': 'number'},
        },
        'required': ['titre', 'debut'],
      },
    },
    {
      'name': 'telephone_partager',
      'description': 'Ouvrir la feuille de partage de l\'iPhone avec un texte.',
      'parameters': {
        'type': 'object',
        'properties': {
          'texte': {'type': 'string'},
        },
        'required': ['texte'],
      },
    },
    {
      'name': 'telephone_recherche',
      'description': 'Faire une recherche sur internet.',
      'parameters': {
        'type': 'object',
        'properties': {
          'recherche': {'type': 'string'},
        },
        'required': ['recherche'],
      },
    },
    {
      'name': 'telephone_retenir_contact',
      'description': 'Retenir le numéro de téléphone d\'un contact.',
      'parameters': {
        'type': 'object',
        'properties': {
          'nom': {'type': 'string'},
          'numero': {'type': 'string'},
        },
        'required': ['nom', 'numero'],
      },
    },
    {
      'name': 'memoire_retenir',
      'description': 'Retenir quelque chose d\'important sur la personne (goûts, projets, proches…).',
      'parameters': {
        'type': 'object',
        'properties': {
          'texte': {'type': 'string'},
        },
        'required': ['texte'],
      },
    },
  ];

  /// Un appel de fonction de Gemini → l'action (null : rien à faire, ou
  /// [remembered] pour memoire_retenir).
  static PhoneAction? fromTool(
    String name,
    Map<String, dynamic> a,
    Map<String, String> contacts, {
    void Function(String text)? remembered,
  }) {
    String s(String k) => '${a[k] ?? ''}'.trim();
    switch (name) {
      case 'telephone_appeler':
        final w = who(s('qui'), contacts);
        return w == null
            ? PhoneAction(
                'contact?',
                '',
                say: 'Je n\'ai pas le numéro de « ${s('qui')} ». Dis-moi « le numéro de ${s('qui')} c\'est 06… ».',
              )
            : call(_cap(w.$1), w.$2);
      case 'telephone_sms':
        final w = s('qui').isEmpty ? null : who(s('qui'), contacts);
        return sms(w == null ? null : _cap(w.$1), w?.$2, s('texte'));
      case 'telephone_itineraire':
        return s('lieu').isEmpty ? null : route(s('lieu'));
      case 'telephone_raccourci':
        return s('nom').isEmpty ? null : shortcut(s('nom'), s('texte'));
      case 'telephone_ouvrir_appli':
        return app(s('appli'));
      case 'telephone_musique':
        return s('recherche').isEmpty ? null : music(s('recherche'));
      case 'telephone_minuteur':
        final m = a['minutes'];
        if (m is! num || m <= 0 || m > 24 * 60) return null;
        return timer(Duration(seconds: (m * 60).round()), s('pour'));
      case 'telephone_agenda':
        final d = DateTime.tryParse(s('debut'));
        if (d == null || s('titre').isEmpty) return null;
        final len = a['duree_minutes'];
        final al = a['alarme_minutes_avant'];
        return event(
          s('titre'),
          d,
          length: Duration(minutes: len is num && len > 0 ? len.round() : 60),
          alarm: al is num && al >= 0 ? al.round() : 10,
        );
      case 'telephone_partager':
        return s('texte').isEmpty ? null : share(s('texte'));
      case 'telephone_recherche':
        return s('recherche').isEmpty ? null : search(s('recherche'));
      case 'telephone_retenir_contact':
        final n = number(s('numero'));
        return n == null || s('nom').isEmpty ? null : remember(_cap(s('nom')), n);
      case 'memoire_retenir':
        if (s('texte').isNotEmpty) remembered?.call(s('texte'));
        return null;
    }
    return null;
  }
}

/// Ce que le PC donne au téléphone par le QR code (« Version web » dans
/// Réglages → Mes appareils → Ajouter mon iPhone) : le prénom, la clé
/// Gemini, le serveur Mon Hub en ligne et quelques souvenirs de Smily. Le
/// code voyage dans la partie « # » du lien, qui n'est **jamais** envoyée au
/// site (GitHub Pages ne la voit pas).
class PhoneLinkCode {
  const PhoneLinkCode({this.name = '', this.gemini = '', this.serverUrl, this.serverKey, this.memories = const []});

  final String name;
  final String gemini;
  final String? serverUrl;
  final String? serverKey;

  /// (sujet, texte).
  final List<(String, String)> memories;

  static const prefix = 'MONHUB-TEL:';

  /// Le lien a une taille limitée (QR code lisible).
  static const maxLength = 1800;

  String encode() {
    Map<String, Object?> j(List<(String, String)> mem) => {
      'v': 1,
      if (name.isNotEmpty) 'n': name,
      if (gemini.isNotEmpty) 'g': gemini,
      if (serverUrl != null && serverKey != null) 's': [serverUrl, serverKey],
      if (mem.isNotEmpty) 'm': [for (final m in mem) [m.$1, m.$2]],
    };
    var mem = [for (final m in memories) (m.$1, m.$2.length > 140 ? '${m.$2.substring(0, 140)}…' : m.$2)];
    var out = '';
    while (true) {
      out = '$prefix${base64Url.encode(utf8.encode(jsonEncode(j(mem)))).replaceAll('=', '')}';
      if (out.length <= maxLength || mem.isEmpty) return out;
      mem = mem.sublist(0, mem.length - 1);
    }
  }

  /// Le lien complet de la version web.
  String link(String site) => '$site#lien=${encode().substring(prefix.length)}';

  static PhoneLinkCode? decode(String raw) {
    var t = raw.trim();
    final h = RegExp(r'[#&]lien=([A-Za-z0-9_-]+)').firstMatch(t);
    if (h != null) {
      t = h.group(1)!;
    } else if (t.startsWith(prefix)) {
      t = t.substring(prefix.length);
    } else {
      return null;
    }
    try {
      final pad = (4 - t.length % 4) % 4;
      final j = jsonDecode(utf8.decode(base64Url.decode(t + '=' * pad))) as Map;
      if (j['v'] != 1) return null;
      final s = j['s'];
      final m = j['m'];
      return PhoneLinkCode(
        name: '${j['n'] ?? ''}',
        gemini: '${j['g'] ?? ''}',
        serverUrl: s is List && s.length == 2 ? '${s[0]}' : null,
        serverKey: s is List && s.length == 2 ? '${s[1]}' : null,
        memories: [
          if (m is List)
            for (final e in m)
              if (e is List && e.length == 2) ('${e[0]}', '${e[1]}'),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// L'adresse de la version web (GitHub Pages du dépôt).
  static String siteFor(String repo) {
    final parts = repo.split('/');
    if (parts.length != 2) return 'https://shideyx.github.io/mon-hub/';
    return 'https://${parts[0].toLowerCase()}.github.io/${parts[1]}/';
  }
}
