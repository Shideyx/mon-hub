import 'dart:convert';

import 'hub_module.dart';

/// Smily économe : au lieu d'envoyer à Claude les ~90 actions de Mon Hub à
/// chaque question (des milliers de mots relus à chaque fois), on n'envoie
/// que celles qui servent à cette question, plus deux petites actions pour
/// atteindre toutes les autres si besoin ([metaTools]).
class ToolRouter {
  ToolRouter._();

  /// Groupes d'actions : préfixe des noms → mots qui les appellent.
  static const groups = <String, (List<String>, List<String>)>{
    'agenda': (
      ['agenda_'],
      [
        'agenda',
        'emploi du temps',
        'edt',
        'cours',
        'demain',
        'aujourd',
        'semaine',
        'lundi',
        'mardi',
        'mercredi',
        'jeudi',
        'vendredi',
        'samedi',
        'dimanche',
        'rendez',
        'rdv',
        'creneau',
        'libre',
        'planning',
        'calendrier',
        'heure',
      ],
    ),
    'ecole': (
      ['ecole_'],
      [
        'ecole',
        'note',
        'moyenne',
        'devoir',
        'controle',
        'interro',
        'prof',
        'classe',
        'bulletin',
        'ed ',
        'ecole directe',
        'message de',
        'vie scolaire',
        'cloud',
        'espace de travail',
        'evaluation',
      ],
    ),
    'revision': (
      ['revision_'],
      ['revis', 'carte', 'fiche', 'quiz', 'interroge', 'apprendre', 'memoriser', 'exercice', 'controle', 'minuteur'],
    ),
    'cours': (
      ['cours_'],
      [
        'compte rendu',
        'comptes rendus',
        'ecoute le cours',
        'ecouter le cours',
        'ecoute mon cours',
        'enregistre le cours',
        'prends le cours',
        'arrete le cours',
        'ce qu on a vu en',
      ],
    ),
    'nav': (
      ['nav_'],
      [
        'navigateur',
        'site',
        'page web',
        'onglet',
        'chrome',
        'classroom',
        'formulaire',
        'pronote',
        'en ligne',
        'sur internet',
      ],
    ),
    'carnet': (
      ['carnet_'],
      [
        'retiens',
        'souviens',
        'note ca',
        'idee',
        'tache',
        'todo',
        'a faire',
        'budget',
        'depense',
        'sport',
        'meteo',
        'poeme',
        'jeu',
        'bilan',
        'protocole',
        'presse-papier',
        'copie',
        'telephone',
        'notif',
      ],
    ),
    'assistant': (
      ['assistant_'],
      [
        'briefing',
        'priorit',
        'objectif',
        'planifie',
        'organise',
        'ma journee',
        'programme',
        'plan',
        'coucher',
        'dormir',
        'sommeil',
        'sac',
      ],
    ),
    'mail': (['mail_', 'mails_'], ['mail', 'courriel', 'email', 'e-mail', 'boite']),
    'discord': (['discord_'], ['discord', 'serveur', 'salon', 'vocal', 'appel', 'appelle', 'dm']),
    'instagram': (['instagram_'], ['insta', 'instagram', 'reel', 'story']),
    'musique': (
      ['musique_', 'spotify'],
      [
        'musique',
        'chanson',
        'son ',
        'titre',
        'playlist',
        'spotify',
        'deezer',
        'ecoute',
        'joue',
        'pause',
        'suivant',
        'album',
        'artiste',
        'volume',
      ],
    ),
    'youtube': (['youtube_'], ['youtube', 'video', 'regarder', 'clip', 'chaine']),
    'livres': (
      ['livre_', 'livres_'],
      ['livre', 'roman', 'lire', 'lecture', 'manga', 'bd', 'chapitre', 'tome', 'biblio'],
    ),
    'docs': (
      ['doc_'],
      ['document', 'doc ', 'docs', 'expose', 'lettre', 'redige', 'ecris', 'word', 'pdf', 'dissertation'],
    ),
    'drive': (['drive_'], ['drive', 'google drive', 'fichier', 'dossier', 'range']),
    'roblox': (['roblox_'], ['roblox', 'jeu roblox', 'studio']),
    'pc': (
      ['pc_'],
      [
        'pc',
        'ordinateur',
        'ordi',
        'windows',
        'installe',
        'ouvre',
        'lance',
        'ferme',
        'fichier',
        'dossier',
        'range',
        'telechargement',
        'bureau',
        'wifi',
        'son',
        'luminosite',
        'mode sombre',
        'disque',
        'eteins',
        'redemarre',
        'commande',
        'powershell',
        'logiciel',
        'appli',
        'batterie',
        'rame',
        'lent',
        'memoire',
        'fenetre',
        'processeur',
      ],
    ),
    'clicky': (
      ['clicky_'],
      [
        'micro',
        'entends',
        'marche pas',
        'voix',
        'repare',
        'bug',
        'panne',
        'concentration',
        'focus',
        'deranger',
        'quand j ouvre',
        'rappel',
        'situation',
        'le point',
        'rate',
        'loupe',
        'quoi de neuf',
        'absence',
        'nouvelles',
        'habitude',
        'presse papier',
        'copie',
        'explique l ecran',
        'erreur',
        'sais faire',
        'capable',
        'capacite',
        'mise a jour',
        'nouveaute',
        'version',
        'jeton',
        'token',
        'budget',
        'consomm',
      ],
    ),
    'securite': (
      ['securite_'],
      [
        'securite',
        'antivirus',
        'virus',
        'arnaque',
        'lien',
        'pirate',
        'hack',
        'double authentification',
        '2fa',
        'protege',
        'pare-feu',
        'mot de passe',
        'phishing',
        'nitro',
        'robux gratuit',
      ],
    ),
    'recherche': (['recherche_'], ['cherche', 'retrouve', 'trouve', 'ou est', 'ou j ai mis', 'perdu', 'partout']),
    'ecran': (
      ['temps_ecran'],
      ['temps d ecran', 'temps passe', 'combien de temps', 'limite', 'trop joue', 'accro', 'pause'],
    ),
    'camera': (
      ['camera_', 'micro_', 'appel_'],
      [
        'camera',
        'webcam',
        'filme',
        'micro',
        'sourdine',
        'mute',
        'appel',
        'flou',
        'arriere plan',
        'espion',
        'ecoute',
        'visage',
        'pirate',
        'privee',
      ],
    ),
    'jeu': (
      ['jeu_'],
      ['jeu', 'jouer', 'je joue', 'niveau', 'boss', 'quete', 'mission', 'build', 'astuce', 'partie', 'manette'],
    ),
    'anniversaires': (['anniversaire'], ['anniversaire', 'anniv', 'ne le', 'nee le', 'fete', 'cadeau']),
    'telephone': (['telephone_'], ['telephone', 'iphone', 'portable', 'mon tel']),
    'argent': (
      ['argent_'],
      [
        'abonnement',
        'essai gratuit',
        'preleve',
        'colis',
        'livraison',
        'commande',
        'jeux gratuits',
        'jeu gratuit',
        'promo',
        'steam',
        'epic',
        'netflix',
        'depense',
        'resilier',
      ],
    ),
    'etudes': (
      ['copie_', 'oral_', 'video_', 'carte_'],
      [
        'copie',
        'redaction',
        'dissertation',
        'corrige',
        'oral',
        'expose',
        'repeter',
        'jury',
        'video',
        'fiche',
        'carte mentale',
        'schema',
        'mind map',
      ],
    ),
    'langues': (
      ['interprete_', 'soustitres_'],
      ['traduis', 'traduction', 'interprete', 'sous titre', 'sous-titre', 'langue', 'anglais', 'espagnol', 'allemand'],
    ),
    'soiree': (['soiree_'], ['soiree', 'fete', 'playlist', 'anniv', 'potes', 'invites']),
    'actualites': (['actualites'], ['actu', 'news', 'nouvelles', 'info', 'journal']),
    'guetteurs': (
      ['guetteur_', 'clicky_brouillon'],
      ['previens moi', 'dis moi quand', 'surveille', 'alerte', 'fais moi signe', 'des que', 'reponse', 'repondre'],
    ),
    'memoire': (
      ['memoire_', 'sens_', 'clicky_creer_capacite', 'clicky_capacites_perso'],
      [
        'retiens',
        'tu sais sur moi',
        'capacite',
        'raccourci',
        'souviens',
        'rappelles',
        'j ai vu',
        'vu hier',
        'que je regardais',
        'que je faisais',
        'que je lisais',
        'oublie',
        'memoire',
        'entendu',
        'il a dit',
        'elle a dit',
        'dans la video',
        'mon ecran',
        'regarde mon',
        'ecoute le son',
        'a retenir',
        'tout a l heure',
      ],
    ),
    'extensions': (['mcp_'], []),
    'perso': (['perso_'], ['ouvre', 'module', 'site']),
  };

  /// Minuscules, sans accents, pour comparer les mots.
  static String normalize(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  /// Le groupe d'une action (null : aucun groupe connu).
  static String? groupOf(String toolName) {
    for (final e in groups.entries) {
      if (e.value.$1.any(toolName.startsWith)) return e.key;
    }
    return null;
  }

  /// Les groupes utiles pour cette question.
  static Set<String> groupsFor(String question) {
    final q = ' ${normalize(question)} ';
    return {
      for (final e in groups.entries)
        if (e.value.$2.any(q.contains)) e.key,
    };
  }

  /// Les actions de [groupNames] (avec les actions sans groupe, et les deux
  /// actions « pour aller chercher le reste »).
  static List<HubTool> forGroups(Iterable<String> groupNames, List<HubTool> all) {
    final wanted = {for (final g in groupNames) g.trim()}..remove('');
    return [
      for (final t in all)
        if (t.name == listName ||
            t.name == callName ||
            always.contains(t.name) ||
            wanted.contains(groupOf(t.name) ?? '·'))
          t,
    ];
  }

  /// Ce qu'on envoie à Claude pour [question] : les groupes reconnus, sinon
  /// un petit ensemble de base. Les actions meta permettent d'aller plus loin.
  static List<HubTool> pick(String question, List<HubTool> all) => forGroups(groupsOrDefault(question), all);

  /// Les groupes reconnus, ou un petit ensemble de base.
  static Set<String> groupsOrDefault(String question) {
    final g = groupsFor(question);
    if (g.isEmpty) g.addAll(const ['assistant', 'carnet']);
    return g;
  }

  /// Toujours envoyées (petites) : Smily vérifie ce qu'il sait faire avant
  /// de dire « je ne sais pas ».
  static const always = {'clicky_capacites'};

  static const listName = 'mon_hub_outils';
  static const callName = 'mon_hub_action';

  /// Deux petites actions qui donnent accès à toutes les autres sans les
  /// envoyer à chaque fois.
  static List<HubTool> metaTools(List<HubTool> all) {
    final real = [
      for (final t in all)
        if (t.name != listName && t.name != callName) t,
    ];
    final names = {for (final t in real) groupOf(t.name) ?? 'autres'};
    return [
      HubTool(
        name: listName,
        description:
            'Liste les autres actions de Mon Hub d\'un groupe (avec leurs paramètres), quand celles que tu as ne '
            'suffisent pas. Groupes : ${names.join(', ')}.',
        params: {'groupe': ('string', 'Un des groupes.')},
        required: ['groupe'],
        run: (a) async {
          final g = '${a['groupe'] ?? ''}'.trim();
          final list = [
            for (final t in real)
              if ((groupOf(t.name) ?? 'autres') == g) t,
          ];
          if (list.isEmpty) return 'Groupe inconnu. Groupes : ${names.join(', ')}.';
          return {
            'actions': [
              for (final t in list)
                {
                  'nom': t.name,
                  'description': t.description,
                  if (t.params.isNotEmpty) 'parametres': {for (final p in t.params.entries) p.key: p.value.$2},
                  if (t.required.isNotEmpty) 'obligatoires': t.required,
                },
            ],
            'comment': 'Appelle $callName avec nom et arguments.',
          };
        },
      ),
      HubTool(
        name: callName,
        description: 'Lance une action de Mon Hub trouvée avec $listName (mêmes permissions que l\'action elle-même).',
        params: {'nom': ('string', 'Nom exact de l\'action.'), 'arguments': ('object', 'Ses paramètres.')},
        required: ['nom'],
        // Jamais lancée directement : [resolve] la remplace par la vraie
        // action (pour que la permission soit bien demandée).
        run: (_) async => 'Utilise le nom exact d\'une action.',
      ),
    ];
  }

  /// Remplace [callName] par l'action visée (et ses arguments), pour que les
  /// permissions s'appliquent à la vraie action.
  static (HubTool?, Map<String, dynamic>) resolve(String name, Map<String, dynamic> args, List<HubTool> all) {
    if (name == callName) {
      final target = '${args['nom'] ?? ''}'.trim();
      if (target == callName || target == listName) return (null, const {});
      final raw = args['arguments'];
      Map<String, dynamic> inner;
      if (raw is Map) {
        inner = raw.cast<String, dynamic>();
      } else if (raw is String && raw.trim().startsWith('{')) {
        try {
          inner = (jsonDecode(raw) as Map).cast<String, dynamic>();
        } catch (_) {
          inner = {};
        }
      } else {
        inner = {};
      }
      return (all.where((t) => t.name == target).firstOrNull, inner);
    }
    return (all.where((t) => t.name == name).firstOrNull, args);
  }

  /// Longueur maximale d'un résultat renvoyé à Claude (au-delà, coupé et
  /// signalé) : une liste de 300 messages coûte cher pour rien.
  static const maxResult = 16000;

  static String cap(String text) => text.length <= maxResult
      ? text
      : '${text.substring(0, maxResult)}\n… (résultat coupé : ${text.length - maxResult} caractères de plus ; '
            'demande une partie précise si besoin)';
}
