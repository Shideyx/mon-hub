/// Ce que Clicky comprend sans demander à l'IA (commandes vocales), et les
/// petits outils du « prof » : protection de la vie privée, mode code,
/// langue de la question, lecture du petit texte (OCR).
library;

enum ClickyCommand {
  /// « suivant », « continue », « étape suivante » : étape suivante.
  next,

  /// « répète », « redis-le » : relit la dernière réponse.
  repeat,

  /// « stop », « annule », « tais-toi » : arrête tout.
  stop,

  /// « nouvelle conversation », « on change de sujet ».
  newChat,

  /// « qu'est-ce qu'on a vu aujourd'hui ? ».
  today,

  /// « qu'est-ce qu'on a vu cette semaine ? ».
  week,

  /// « qu'est-ce que je dois réviser ? », « interroge-moi sur mes révisions ».
  review,

  /// « interroge-moi », « quiz » (sur l'écran ou le sujet en cours).
  quiz,

  /// « qu'est-ce que je viens de faire ? » (capture de gestes).
  whatDidIDo,

  /// « briefing », « fais-moi le point ».
  briefing,

  /// « change de voix pour Paul ».
  changeVoice,

  /// « montre-moi l'historique ».
  history,

  /// « protocole travail ».
  protocol,

  /// « répare le micro », « le micro ne marche pas » : Clicky se répare.
  repair,
}

/// Minuscules, sans accents ni ponctuation, espaces simples.
String normalize(String s) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    final i = from.indexOf(c);
    b.write(i >= 0 ? to[i] : c);
  }
  return '$b'
      .replaceAll(RegExp(r"[^a-z0-9' ]+"), ' ')
      .replaceAll("'", ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Reconnaît une commande. Renvoie (commande, reste de la phrase).
(ClickyCommand, String)? parseCommand(String raw) {
  var n = normalize(raw);
  // « Clicky, … », « dis Clicky … » au début.
  n = n.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|he) )?clicky ?'), '').trim();
  if (n.isEmpty) return null;
  bool any(List<String> l) => l.any((p) => n == p || n == '$p s il te plait' || n == '$p merci');
  if (any([
    'suivant',
    'suivante',
    'continue',
    'continuer',
    'etape suivante',
    'la suite',
    'et apres',
    'ensuite',
    'next',
    'ok suivant',
    'c est bon suivant',
    'j ai fini',
    'c est fait',
  ])) {
    return (ClickyCommand.next, '');
  }
  if (any([
    'repete',
    'repete ca',
    'redis le',
    'redis',
    'tu peux repeter',
    'repeat',
    'encore une fois',
  ])) {
    return (ClickyCommand.repeat, '');
  }
  if (any(['stop', 'arrete', 'arrete toi', 'annule', 'tais toi', 'silence', 'cancel', 'chut'])) {
    return (ClickyCommand.stop, '');
  }
  if (RegExp(r'^(nouvelle conversation|on change de sujet|efface la conversation|repars de zero)')
      .hasMatch(n)) {
    return (ClickyCommand.newChat, '');
  }
  if (RegExp(
    r"(qu est ce qu |qu )?on a (vu|appris|fait) aujourd hui|resume de (la journee|aujourd hui)|ce qu on a vu aujourd hui",
  ).hasMatch(n)) {
    return (ClickyCommand.today, '');
  }
  if (RegExp(
    r'(qu est ce qu |qu )?on a (vu|appris|fait) cette semaine|resume de la semaine|ce qu on a vu cette semaine',
  ).hasMatch(n)) {
    return (ClickyCommand.week, '');
  }
  if (RegExp(
    r'(que|qu est ce que) (je dois|j ai a|il faut) reviser|mes revisions|interroge moi sur (ce que je dois reviser|mes revisions)|quiz (de|sur mes) revisions|fais moi reviser',
  ).hasMatch(n)) {
    return (ClickyCommand.review, '');
  }
  if (RegExp(r'^(interroge moi|teste moi|quiz|fais moi un quiz|pose moi des questions)')
      .hasMatch(n)) {
    return (
      ClickyCommand.quiz,
      n
          .replaceFirst(
            RegExp(r'^(interroge moi|teste moi|quiz|fais moi un quiz|pose moi des questions)'),
            '',
          )
          .trim(),
    );
  }
  if (RegExp(
    r"(qu est ce que|qu ai je|qu est ce qu) (je viens|j ai) (de faire|fait)|ce que je viens de faire",
  ).hasMatch(n)) {
    return (ClickyCommand.whatDidIDo, '');
  }
  if (RegExp(
    r'^(briefing|fais moi (le|un) (point|briefing)|le point du jour|rapport du jour|quoi de neuf aujourd hui)',
  ).hasMatch(n)) {
    return (ClickyCommand.briefing, '');
  }
  final v = RegExp(
    r'^(?:change(?:r)? (?:de |la )?voix|prends la voix|utilise la voix)(?: (?:pour|de|a))? ?(.*)$',
  ).firstMatch(n);
  if (v != null) return (ClickyCommand.changeVoice, v.group(1)!.trim());
  final proto = RegExp(r'^(?:lance |active |demarre )?(?:le )?protocole (.+)$').firstMatch(n);
  if (proto != null) return (ClickyCommand.protocol, proto.group(1)!.trim());
  if (RegExp(
    r'^(?:(?:repare|reparer|repars|depanne|relance)(?: le| mon| ton| ce)? (?:micro|toi|clicky|l ecoute)'
    r'|(?:le |mon |ton )?micro (?:ne )?(?:marche|fonctionne|m entend) (?:pas|plus)'
    r'|tu (?:ne )?m entends (?:pas|plus)|diagnostic(?: du micro)?$)',
  ).hasMatch(n)) {
    return (ClickyCommand.repair, '');
  }
  if (RegExp(r'^(montre|ouvre|affiche) (moi )?(l )?historique').hasMatch(n)) {
    return (ClickyCommand.history, '');
  }
  return null;
}

/// Fenêtres sensibles : Clicky ne prend pas de capture quand l'une d'elles
/// est ouverte à l'écran (gestionnaires de mots de passe, banque…).
bool isSensitiveTitle(String title) {
  final t = title.toLowerCase();
  const words = [
    'keepass',
    'bitwarden',
    '1password',
    'lastpass',
    'dashlane',
    'authenticator',
    'mot de passe',
    'password',
    'banque',
    'banking',
    'bank ',
    'carte bancaire',
    'credit card',
    'paypal',
    'lydia',
    '.env',
    'credentials',
    'coffre-fort',
  ];
  return words.any(t.contains);
}

/// Un éditeur de code est au premier plan (VS Code, Cursor, IntelliJ…).
bool isCodeEditorTitle(String title) => RegExp(
  r'visual studio code|vs ?code|\bcursor\b|intellij|pycharm|webstorm|android studio|'
  r'sublime text|notepad\+\+|\bvim\b|neovim|nvim|eclipse|xcode|rider|clion|goland|'
  r'visual studio|\.(py|js|ts|dart|java|cpp|cs|html|css|json|lua|rs|go)\b',
  caseSensitive: false,
).hasMatch(title);

/// Nom court de l'appli d'après le titre de sa fenêtre
/// (« Document1 - Word » → « Word »).
String appFromTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return '';
  final parts = t.split(RegExp(r'\s+[-–—|]\s+'));
  var app = parts.last.trim();
  if (app.length > 40) app = app.substring(0, 40);
  return app;
}

/// Langue probable d'une question (code BCP 47 pour la voix).
String detectLanguage(String text) {
  final n = ' ${normalize(text)} ';
  int score(List<String> words) => words.where((w) => n.contains(' $w ')).length;
  final scores = {
    'fr-FR': score([
      'le',
      'la',
      'les',
      'est',
      'je',
      'tu',
      'un',
      'une',
      'des',
      'quoi',
      'comment',
      'pourquoi',
      'que',
      'qui',
      'c',
      'et',
      'pas',
      'moi',
    ]),
    'en-US': score([
      'the',
      'is',
      'what',
      'how',
      'why',
      'you',
      'i',
      'my',
      'and',
      'can',
      'this',
      'to',
      'of',
      'does',
      'are',
    ]),
    'es-ES': score([
      'el',
      'es',
      'que',
      'como',
      'por',
      'una',
      'los',
      'las',
      'esto',
      'yo',
      'y',
      'puedes',
      'donde',
      'porque',
    ]),
    'de-DE': score([
      'der',
      'die',
      'das',
      'ist',
      'ich',
      'du',
      'und',
      'wie',
      'was',
      'nicht',
      'ein',
      'eine',
      'warum',
      'kannst',
    ]),
    'it-IT': score([
      'il',
      'che',
      'come',
      'perche',
      'sono',
      'una',
      'gli',
      'questo',
      'cosa',
      'io',
      'non',
      'puoi',
      'dove',
    ]),
    'pt-PT': score([
      'o',
      'que',
      'como',
      'voce',
      'uma',
      'os',
      'isso',
      'eu',
      'nao',
      'porque',
      'onde',
      'pode',
    ]),
  };
  var best = 'fr-FR';
  var top = scores['fr-FR']!;
  for (final e in scores.entries) {
    if (e.value > top + 1) {
      best = e.key;
      top = e.value;
    }
  }
  return best;
}

/// La question parle de petit texte à lire : on lit l'écran (OCR) en plus.
bool wantsOcr(String q) => RegExp(
  r"petit texte|ecrit en petit|lis (moi )?(ce|le|l) |lire (ce|le|l)|qu est ce qui est ecrit|"
  r"texte (de|a) l ecran|recopie|ce que dit le texte|en tout petit|fine print|read (that|this)",
).hasMatch(normalize(q));

/// La question demande des infos récentes (recherche web utile).
bool wantsWeb(String q) => RegExp(
  r"cherche|recherche|actualite|actu |aujourd hui|en ce moment|derniere(s)? (nouvelle|version|info)|"
  r"meteo|qui a gagne|resultat du match|prix d|combien coute|sur internet|sur le web|google",
).hasMatch(normalize(q));
