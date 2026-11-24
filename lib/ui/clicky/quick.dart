import 'dart:async';

import 'dart:math' as math;

import '../widgets.dart';
import 'tutor.dart' show normalize;
import 'patience.dart';
import 'watchers.dart' show WatchParse;
import '../../core/birthdays.dart';

/// Appel d'une action de Mon Hub (agenda, devoirs, musique…).
typedef QuickTool = Future<Object?> Function(String name, Map<String, dynamic> args);

/// Ce que Smily répond sans l'IA.
class QuickReply {
  const QuickReply(this.text, {this.timer, this.timerLabel = '', this.media});
  final String text;

  /// Un minuteur à lancer.
  final Duration? timer;
  final String timerLabel;

  /// Une touche multimédia à envoyer (volup, voldown, mute).
  final String? media;
}

/// Réponses **instantanées et sans IA** : tout ce qu'un algorithme sait
/// faire (l'heure, un calcul, un minuteur, la musique, tes devoirs, ton
/// emploi du temps, tes notes, la météo, ouvrir une appli, ranger…). Claude
/// reste le cerveau pour le reste. Les phrases sont reconnues entières, pour
/// ne jamais répondre à côté.
class QuickAnswers {
  QuickAnswers._();

  static const _days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  /// La phrase nettoyée : minuscules, sans accents, sans « Smily » ni
  /// « s'il te plaît ».
  static String clean(String raw) {
    var n = normalize(raw);
    n = n.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|he|alors) )?(?:clicky|smily|smiley|simile) ?'), '');
    n = n.replaceFirst(RegExp(r' (?:s il te plait|s il vous plait|stp|svp|merci)$'), '');
    return n.trim();
  }

  /// Retrouve dans la phrase d'origine les mots de [fragment] (avec leurs
  /// accents et majuscules) : « lea » → « Léa ».
  static String original(String raw, String fragment) {
    final want = fragment.trim().split(' ');
    final words = RegExp(r"[\p{L}\p{N}-]+", unicode: true).allMatches(raw).map((m) => m[0]!).toList();
    final plain = [for (final w in words) normalize(w)];
    for (var i = 0; i + want.length <= words.length; i++) {
      var ok = true;
      for (var j = 0; j < want.length && ok; j++) {
        ok = plain[i + j] == want[j];
      }
      if (ok) {
        final s = words.sublist(i, i + want.length).join(' ');
        return s[0].toUpperCase() + s.substring(1);
      }
    }
    final f = fragment.trim();
    return f.isEmpty ? f : f[0].toUpperCase() + f.substring(1);
  }

  /// Le jour visé par « demain », « aujourd'hui », « jeudi »…
  static DateTime? dayFrom(String n, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    if (RegExp(r'\bapres demain\b').hasMatch(n)) return today.add(const Duration(days: 2));
    if (RegExp(r'\bdemain\b').hasMatch(n)) return today.add(const Duration(days: 1));
    if (RegExp(r"\baujourd hui\b|\bce (?:matin|soir|midi)\b|\bcet apres midi\b").hasMatch(n)) return today;
    for (var i = 0; i < 7; i++) {
      if (RegExp('\\b${_days[i]}\\b').hasMatch(n)) {
        var d = (i + 1 - now.weekday) % 7;
        if (d == 0) d = 7;
        return today.add(Duration(days: d));
      }
    }
    return null;
  }

  static String _dayName(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    if (diff == 0) return 'aujourd\'hui';
    if (diff == 1) return 'demain';
    return '${frDays[d.weekday - 1]} ${d.day} ${frMonths[d.month - 1]}';
  }

  static String _hour(DateTime d) =>
      d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static String _short(String s, [int max = 90]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  static List<Map> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map) e,
  ];

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('$v');

  /// Ce que Smily sait ouvrir tout seul.
  static const opens = {
    'youtube': 'https://www.youtube.com',
    'discord': 'https://discord.com/app',
    'instagram': 'https://www.instagram.com',
    'insta': 'https://www.instagram.com',
    'spotify': 'spotify:',
    'google drive': 'https://drive.google.com',
    'le drive': 'https://drive.google.com',
    'mon drive': 'https://drive.google.com',
    'drive': 'https://drive.google.com',
    'gmail': 'https://mail.google.com',
    'mes mails': 'https://mail.google.com',
    'chrome': 'chrome',
    'google': 'https://www.google.com',
    'netflix': 'https://www.netflix.com',
    'tiktok': 'https://www.tiktok.com',
    'twitter': 'https://x.com',
    'whatsapp': 'https://web.whatsapp.com',
    'roblox': 'https://www.roblox.com',
    'ecole directe': 'https://www.ecoledirecte.com',
    'pronote': 'https://www.index-education.com/fr/pronote-info191.php',
    'la calculatrice': 'calc',
    'calculatrice': 'calc',
    'le bloc notes': 'notepad',
    'bloc notes': 'notepad',
    'l explorateur': 'explorer',
    'l explorateur de fichiers': 'explorer',
    'mes telechargements': '~\\Downloads',
    'les parametres': 'ms-settings:',
    'les reglages': 'ms-settings:',
  };

  static const _folders = {
    'mes telechargements': 'telechargements',
    'les telechargements': 'telechargements',
    'mon dossier telechargements': 'telechargements',
    'mon bureau': 'bureau',
    'le bureau': 'bureau',
    'mes documents': 'documents',
    'mes images': 'images',
    'mes photos': 'images',
  };

  /// La réponse, ou null : la question part vers l'IA.
  static Future<QuickReply?> answer(
    String raw, {
    required QuickTool call,
    Set<String> tools = const {},
    DateTime? now,
  }) async {
    final n = clean(raw);
    if (n.isEmpty) return null;
    final t = now ?? DateTime.now();
    bool has(String tool) => tools.contains(tool);

    // Politesse.
    if (RegExp(r'^(?:salut|bonjour|coucou|hello|yo|hey|wesh)$').hasMatch(n)) {
      return const QuickReply('Salut ! Je t\'écoute.');
    }
    if (n == 'bonsoir') return const QuickReply('Bonsoir ! Je t\'écoute.');
    if (RegExp(r'^(?:merci|merci beaucoup|merci bien|super|top|parfait|genial|nickel)(?: merci)?$').hasMatch(n)) {
      return const QuickReply('Avec plaisir !');
    }

    // L'heure, la date.
    if (RegExp(r'^(?:quelle heure (?:est il|il est)|il est quelle heure|c est quelle heure|l heure|donne moi l heure)$')
        .hasMatch(n)) {
      return QuickReply('Il est ${_hour(t)}.');
    }
    if (RegExp(
      r'^(?:quel jour (?:sommes nous|on est|est on|est il|c est|nous sommes)|on est quel jour|c est quel jour|'
      r'quelle (?:est la )?date|on est le combien|nous sommes le combien)(?: aujourd hui| d aujourd hui)?$',
    ).hasMatch(n)) {
      return QuickReply('Nous sommes ${frDays[t.weekday - 1]} ${t.day} ${frMonths[t.month - 1]} ${t.year}.');
    }

    // Calculs.
    final calc = Calc.fromSentence(raw);
    if (calc != null) return QuickReply(calc);

    // Assistant personnel : priorités, plan de la journée, objectifs.
    if (has('assistant_priorites') &&
        RegExp(
          r'^(?:quelles sont |c est quoi |donne moi )?mes priorites(?: du jour| aujourd hui)?$|'
          r'^par quoi (?:je )?(?:commence|dois commencer|devrais commencer|je commence)(?: aujourd hui| ce soir)?$|'
          r'^qu est ce que je (?:dois|devrais) faire (?:en premier|d abord)$|'
          r'^j ai trop de (?:trucs|choses|devoirs|taches)(?: a faire)?$',
        ).hasMatch(n)) {
      final r = await call('assistant_priorites', const {});
      if (r is Map) {
        final l = [
          for (final x in (r['priorites'] as List?) ?? const [])
            if (x is Map) x,
        ];
        if (l.isEmpty) return const QuickReply('Rien d\'urgent : tu es à jour, bravo !');
        return QuickReply(
          [
            r['trop_de_choses'] == true
                ? 'Ça fait beaucoup, alors concentre-toi sur les 3 premières :'
                : 'Par quoi commencer :',
            for (final (i, t) in l.take(5).indexed) '${i + 1}. ${t['tache']} (${t['pourquoi']})',
          ].join('\n'),
        );
      }
    }
    if (has('assistant_planifier_journee') &&
        RegExp(
          r'^(?:aide moi a )?(?:re)?organise(?:r)? ma (?:journee|soiree)$|^planifie(?:r)? ma (?:journee|soiree)$|'
          r'^fais moi un (?:planning|plan|programme) (?:pour )?(?:ce soir|aujourd hui|ma journee|ma soiree)$',
        ).hasMatch(n)) {
      final r = await call('assistant_planifier_journee', const {});
      if (r is String) return QuickReply(r);
      if (r is Map) {
        final plan = [
          for (final x in (r['plan_propose'] as List?) ?? const [])
            if (x is Map) x,
        ];
        return QuickReply(
          [
            'Voici ce que je te propose :',
            for (final p in plan) '• ${'${p['debut']}'.substring(11, 16)} ${p['titre']}',
            'Clique sur « Mettre dans l\'agenda » pour l\'enregistrer.',
          ].join('\n'),
        );
      }
    }
    if (has('assistant_objectifs') && RegExp(r'^(?:quels sont |c est quoi )?mes objectifs$').hasMatch(n)) {
      final r = await call('assistant_objectifs', const {'action': 'lister'});
      if (r is List) {
        final open = [
          for (final g in r)
            if (g is Map && g['atteint'] != true) '${g['objectif']}',
        ];
        return QuickReply(
          open.isEmpty
              ? 'Tu n\'as pas encore d\'objectif. Dis-moi « mon objectif est de… » et je le retiens.'
              : 'Tes objectifs : ${open.join(' · ')}.',
        );
      }
    }

    // ---- « Tu peux me reparler de tout » : il oublie les refus ----

    if (RegExp(
      r'^(?:tu peux (?:me )?(?:re)?parler de tout|oublie (?:mes|les) refus|tu peux (?:me )?relancer|'
      r'reparle moi de tout|remets (?:tout|les rappels))$',
    ).hasMatch(n)) {
      await Patience.instance.reset();
      return const QuickReply('C\'est oublié : je peux te reparler de tout, comme avant.');
    }

    // ---- « Répare-toi » : il relit son journal et corrige ----

    if (has('clicky_reparer') &&
        RegExp(
          r'^(?:repare|reparer|repare toi|reparer toi|auto reparation)$|'
          r'^(?:tu (?:bugues|bug|plantes|deconnes)|ca (?:ne )?marche plus|rien ne marche|tu marches plus)\s?!?$|'
          r'^(?:verifie|regarde) (?:si tout va bien|ton journal|tes erreurs)$',
        ).hasMatch(n)) {
      final r = await call('clicky_reparer', {});
      if (r is Map && r['resume'] != null) return QuickReply('${r['resume']}');
    }

    // ---- Caméra et micro : couper, rallumer, savoir qui s'en sert ----

    if (has('camera_couper')) {
      final off = RegExp(
        r'^(?:coupe|ferme|desactive|eteins|bloque) (?:moi )?(?:ma|la|le) (camera|webcam|micro|microphone)$|'
        r'^(?:je (?:ne )?veux pas etre (?:filme|filmee|espionne|espionnee))$|'
        r'^(?:personne ne (?:doit|peut) me filmer)$',
      ).firstMatch(n);
      if (off != null) {
        final mic = (off.group(1) ?? '').startsWith('mic');
        final r = await call('camera_couper', {'couper': 'oui', 'appareil': mic ? 'micro' : 'camera'});
        return QuickReply('${r is Map ? r['resume'] : 'C\'est coupé.'}');
      }
      final on = RegExp(
        r'^(?:rallume|remets|reactive|debloque|ouvre) (?:moi )?(?:ma|la|le) (camera|webcam|micro|microphone)$',
      ).firstMatch(n);
      if (on != null) {
        final mic = (on.group(1) ?? '').startsWith('mic');
        final r = await call('camera_couper', {'couper': 'non', 'appareil': mic ? 'micro' : 'camera'});
        return QuickReply('${r is Map ? r['resume'] : 'C\'est rallumé.'}');
      }
    }
    if (has('camera_etat') &&
        RegExp(
          r'^(?:est ce que )?(?:ma|la) (?:camera|webcam) est (?:allumee|active|coupee|eteinte)\s?\??$|'
          r'^(?:qui|quelle appli|quelle application) (?:utilise|se sert de) (?:ma|la) (?:camera|webcam|mon micro)\s?\??$|'
          r'^(?:on me filme|quelqu un me filme|je suis filme|je suis filmee)\s?\??$|'
          r'^etat de (?:ma|la) (?:camera|webcam)$',
        ).hasMatch(n)) {
      final r = await call('camera_etat', {});
      if (r is Map && r['resume'] != null) return QuickReply('${r['resume']}');
    }

    // ---- Façon JARVIS : état du PC, fenêtres, concentration, rappels ----

    // Le point de la situation (« rapport », « fais le point »).
    if (RegExp(
          r'^(?:fais(?: moi)? (?:le |un )?)?(?:rapport|point)(?: de (?:la )?situation)?$|^(?:statut|situation) (?:general|generale|actuelle)$|^fais le point$',
        ).hasMatch(n) &&
        (has('clicky_situation') || has('pc_etat'))) {
      final sit = has('clicky_situation') ? await call('clicky_situation', {}) : null;
      final pc = has('pc_etat') ? await call('pc_etat', {}) : null;
      final lines = '${sit ?? ''}'
          .split('\n')
          .map((l) => l.replaceFirst(RegExp(r'^- '), '').trim())
          .where((l) => l.isNotEmpty)
          .take(4)
          .toList();
      final parts = [
        'Voici le point. Il est ${_hour(t)}.',
        if (lines.isNotEmpty) '${lines.join('. ')}.',
        if (pc is Map && pc['resume'] != null) '${pc['resume']}',
      ];
      return QuickReply(parts.join(' ').replaceAll('..', '.'));
    }

    // L'état du PC.
    if (has('pc_etat')) {
      final why = RegExp(
        r'^pourquoi (?:mon |le )?(?:pc|ordi|ordinateur) (?:rame|lag|lague|est (?:si )?lent|bug|bugue|ralentit)$|^(?:mon |le )?(?:pc|ordi|ordinateur) (?:rame|lag|lague|est (?:trop )?lent)$',
      ).hasMatch(n);
      final status =
          why ||
          RegExp(
            r'^(?:etat|statut|diagnostic|bilan|sante) (?:du |de mon |de l )?(?:pc|ordi|ordinateur|systeme|systemes)$|'
            r'^comment (?:va|se porte) (?:mon |le )?(?:pc|ordi|ordinateur)$|^(?:diagnostic|diagnostic systeme|statut systeme|etat des systemes)$|'
            r'^(?:il me reste combien de batterie|combien de batterie(?: il me reste| j ai| reste t il)?|(?:ma |la )?batterie|niveau de (?:la )?batterie|j ai combien de batterie)$',
          ).hasMatch(n);
      if (status) {
        final r = await call('pc_etat', {'applis': why});
        if (r is Map && r['resume'] != null) {
          var text = '${r['resume']}';
          if (why && r['applis_gourmandes'] is List && !text.contains('mémoire :')) {
            text += ' Ce qui prend le plus de mémoire : ${(r['applis_gourmandes'] as List).take(3).join(', ')}.';
          }
          return QuickReply(text);
        }
      }
    }

    // Le texte surligné : corriger, reformuler, traduire.
    if (has('clicky_corriger_selection')) {
      final sel =
          r'(?:ce que j ai (?:surligne|selectionne|ecrit)|le texte (?:surligne|selectionne)|la selection|mon texte|ce texte)';
      final fix = RegExp('^(?:corrige|relis|verifie l orthographe de) $sel\$').hasMatch(n);
      final re = RegExp('^(?:reformule|ameliore) $sel\$').hasMatch(n);
      final tr = RegExp('^traduis $sel en (\\w+)\$|^traduis en (\\w+) $sel\$').firstMatch(n);
      if (fix || re || tr != null) {
        final mode = fix ? 'corriger' : (re ? 'reformuler' : 'traduire:${tr!.group(1) ?? tr.group(2)}');
        return QuickReply('${await call('clicky_corriger_selection', {'mode': mode})}');
      }
    }

    // « Qu'est-ce que j'ai raté ? »
    if (has('clicky_rate') &&
        RegExp(
          r'^(?:qu est ce que j ai rate|j ai rate quoi|j ai loupe quoi|qu est ce que j ai loupe|quoi de neuf|du nouveau|'
          r'on m a ecrit|quelqu un m a ecrit|j ai des messages|des nouvelles|resume(?: moi)? (?:mes |les )?messages)'
          r'(?: sur discord| pendant mon absence| aujourd hui| depuis ce matin| depuis hier)?$',
        ).hasMatch(n)) {
      final hours = RegExp(r'depuis hier').hasMatch(n)
          ? 24
          : (RegExp(r'aujourd hui|depuis ce matin').hasMatch(n) ? (t.hour + 1) : 12);
      return QuickReply('${await call('clicky_rate', {'heures': hours})}');
    }

    // Bilan de sécurité.
    if (has('securite_bilan') &&
        RegExp(
          r'^(?:fais(?: moi)? (?:un |le )?)?(?:bilan|check|verification|controle) (?:de )?(?:la |ma )?securite(?: du pc| de mon pc| de mes comptes)?$|'
          r'^(?:verifie|controle) (?:la |ma )?securite(?: du pc| de mon pc| de mes comptes)?$|'
          r'^(?:est ce que )?(?:mon pc|mon ordi|mon ordinateur) (?:est|il est) (?:bien )?protege$|'
          r'^(?:est ce que )?j ai (?:un|bien un) antivirus(?: actif)?$',
        ).hasMatch(n)) {
      final r = await call('securite_bilan', {});
      if (r is Map) return QuickReply('${r['resume']}');
    }

    // Bouclier anti-arnaque (le lien copié).
    if (has('securite_lien') &&
        RegExp(
          r'^(?:est ce que )?(?:ce|le|mon) (?:lien|site|message) (?:est|il est) (?:sur|fiable|dangereux|safe|une arnaque|legit)$|'
          r'^(?:c est|est ce que c est|est ce) une arnaque$|^(?:verifie|regarde|check) (?:ce|le|mon) (?:lien|site|message)(?: copie)?$|'
          r'^je peux (?:cliquer|ouvrir) (?:sur )?ce lien$',
        ).hasMatch(n)) {
      final r = await call('securite_lien', {});
      if (r is Map) return QuickReply('${r['resume']}');
    }

    // Temps d'écran.
    if (has('temps_ecran')) {
      const when = r'(?: (aujourd hui|ce jour|hier|cette semaine|la semaine|sur la semaine|depuis une semaine))?';
      final all = RegExp(
        '^(?:(?:c est )?combien (?:de temps )?(?:j ai passe |je suis reste )?(?:sur|devant) (?:l ecran|le pc|mon pc|l ordi)|'
        '(?:mon |le |quel est mon )?temps (?:d ecran|devant l ecran|passe sur le pc))$when\$',
      ).firstMatch(n);
      final one = RegExp(
        '^combien de temps (?:(?:j ai passe|je suis reste|j ai joue|j ai regarde) (?:sur|a jouer a|a regarder|a)|sur) '
        '(?:l |la |le |les )?([a-z0-9+]+(?: [a-z0-9+]+){0,2}?)$when\$',
      ).firstMatch(n);
      final m = all ?? one;
      if (m != null && !(one != null && RegExp(r'^(?:l ecran|le pc|mon pc|l ordi)$').hasMatch(one[1]!))) {
        final w = (all != null ? all[1] : one![2]) ?? '';
        final periode = w.contains('hier') ? 'hier' : (w.contains('semaine') ? 'semaine' : 'jour');
        final r = await call('temps_ecran', {
          'periode': periode,
          if (one != null && all == null) 'appli': one[1]!.trim(),
        });
        if (r is Map) return QuickReply('${r['resume']}');
      }
    }
    if (has('temps_ecran_limite')) {
      const app = r'([a-z0-9+][a-z0-9+ ]{1,29}?)';
      // « limite de 1 h par jour sur Roblox »
      final b = RegExp(
        '^(?:mets? |fixe )?(?:moi )?(?:une )?limite de (.+?) (?:par jour )?(?:sur|pour|a) (?:l |la |le )?$app\$',
      ).firstMatch(n);
      // « limite Roblox à 1 h (par jour) », « mets une limite sur YouTube de 30 min »
      final a = b != null
          ? null
          : RegExp(
              '^(?:mets? (?:moi )?(?:une )?limite (?:sur |pour |a )?|limite )(?:mon temps (?:sur|de) |le temps (?:sur|de) )?'
              '(?:l |la |le )?$app (?:a|de|pendant) (.+?)(?: par jour)?\$',
            ).firstMatch(n);
      if (b != null || a != null) {
        final (name, dur) = b != null ? (b[2]!, b[1]!) : (a![1]!, a[2]!);
        final d = FocusDuration.parse(dur);
        if (d != null) {
          return QuickReply('${await call('temps_ecran_limite', {'appli': name.trim(), 'minutes': d.inMinutes})}');
        }
      }
      final off = RegExp(
        r'^(?:enleve|supprime|retire) (?:la )?limite (?:de temps )?(?:sur |de |pour )?([a-z0-9+ ]{2,30})$',
      ).firstMatch(n);
      if (off != null) {
        return QuickReply('${await call('temps_ecran_limite', {'appli': off[1]!.trim(), 'minutes': 0})}');
      }
    }

    // Ses habitudes.
    if (has('clicky_habitudes') &&
        RegExp(
          r'^(?:quelles sont |c est quoi )?mes habitudes(?: sur le pc)?$|^qu est ce que tu (?:sais|as remarque) (?:sur|de) mes habitudes$|^tu as remarque quoi sur (?:moi|mes habitudes)$|^tu me connais$',
        ).hasMatch(n)) {
      final r = await call('clicky_habitudes', {});
      if (r is Map) return QuickReply('${r['resume']}');
    }

    // « Préviens-moi quand j'ai ma note de maths », « …quand Lucas m'écrit ».
    if (has('guetteur_creer')) {
      final m = WatchParse.lead.firstMatch(n);
      if (m != null) {
        final rest = (m[1] ?? m[2] ?? m[3])!.trim();
        final r = '${await call('guetteur_creer', {'phrase': rest, 'texte': raw})}';
        // Pas un guetteur (« préviens-moi quand il est 18 h ») : l'IA s'en charge.
        if (!r.startsWith('Je ne sais pas encore')) return QuickReply(r);
      }
    }
    if (has('guetteur_liste')) {
      if (RegExp(
        r'^(?:qu est ce que tu surveilles|tu surveilles quoi|mes alertes|quelles sont mes alertes|tu guettes quoi)$',
      ).hasMatch(n)) {
        return QuickReply('${await call('guetteur_liste', {})}');
      }
      final stop = RegExp(
        r'^(?:arrete de surveiller|ne surveille plus|annule (?:l alerte|les alertes|mes alertes))(?: (?:pour |de |du |la |le )?(.+))?$',
      ).firstMatch(n);
      if (stop != null) return QuickReply('${await call('guetteur_liste', {'supprimer': (stop[1] ?? 'tout').trim()})}');
    }

    // Ses yeux et ses oreilles : la mémoire de l'écran (« tu te souviens ? »).
    if (has('memoire_ecran')) {
      final rem = RegExp(
        r'^(?:tu te souviens|tu te rappelles?) (?:de |du |des |d )?(.{3,90}?)(?: que j ai (?:vu|regarde|lu|ouvert).*)?$|'
        r'^(?:c etait quoi|c est quoi|quel etait|quelle etait|retrouve(?: moi)?) (?:le |la |les |l |ce |cette )?'
        r'(?:site|page|video|article|document|doc|fichier|image|pdf|exercice|lien|recette|chanson)(.{3,90}?)'
        r'(?: que j ai (?:vu|regarde|lu|ouvert|ecoute)| que je (?:regardais|lisais|faisais))(.*)$|'
        r'^ou (?:est ce que )?j ai vu (.{3,80})$',
      ).firstMatch(n);
      final what = (rem?[1] ?? rem?[2] ?? rem?[4])?.trim() ?? '';
      if (rem != null && what.isNotEmpty && !RegExp(r'^(?:moi|quoi|ce que je t ai dit|nous)$').hasMatch(what)) {
        // Le moment (« hier », « mardi vers 16 h ») est cherché dans toute la phrase.
        final r = await call('memoire_ecran', {'texte': what, 'quand': n});
        // Rien vu : l'IA cherche aussi dans vos conversations.
        if (r is Map && (r['resultats'] as List?)?.isNotEmpty == true) return QuickReply('${r['resume']}');
      }
      final doing = RegExp(r'^qu est ce que je (?:faisais|regardais|lisais) (.{3,60})$|^je faisais quoi (.{3,60})$')
          .firstMatch(n);
      if (doing != null) {
        final r = await call('memoire_ecran', {'quand': (doing[1] ?? doing[2])!});
        if (r is Map && (r['moments'] as List?)?.isNotEmpty == true) return QuickReply('${r['resume']}');
      }
      final forget = RegExp(
        r'^(?:oublie|efface) (?:ce que tu as vu (?:pendant )?)?(?:les |la )?(?:(\d+) )?(?:dernieres? )?(minutes?|min|heures?|h)(?: dernieres?)?$',
      ).firstMatch(n);
      if (forget != null && has('memoire_oublier')) {
        final k = int.tryParse(forget[1] ?? '') ?? 1;
        final minutes = forget[2]!.startsWith('h') ? k * 60 : k;
        return QuickReply('${await call('memoire_oublier', {'minutes': minutes})}');
      }
      if (has('memoire_oublier') && RegExp(r'^(?:oublie|efface) tout ce que tu as (?:vu|entendu)$').hasMatch(n)) {
        return QuickReply('${await call('memoire_oublier', {'minutes': 0})}');
      }
    }
    if (has('sens_etat') &&
        RegExp(
          r'^(?:qu est ce qu (?:il|elle|on) (?:a dit|vient de dire)|(?:il|elle) a dit quoi|(?:tu as|t as) entendu quoi)(?: dans la video)?$',
        ).hasMatch(n)) {
      final r = await call('sens_etat', {});
      if (r is Map) {
        final said = '${r['vient_d_etre_dit'] ?? ''}'.trim();
        if (said.isEmpty) {
          return const QuickReply('Je n\'ai rien entendu ces 2 dernières minutes (ou mes oreilles sont éteintes).');
        }
        return QuickReply(
          'Il vient de dire : « ${said.length > 320 ? '…${said.substring(said.length - 320)}' : said} »',
        );
      }
    }
    if (has('sens_regler')) {
      Future<QuickReply> set(Map<String, dynamic> a, String text) async {
        await call('sens_regler', a);
        return QuickReply(text);
      }

      if (RegExp(
        r'^(?:regarde|surveille|tu peux regarder|vois) (?:mon |l )?ecran(?: en continu| tout le temps| en permanence)?$',
      ).hasMatch(n)) {
        return set(
          {'ecran': true},
          'D\'accord : je vois ton écran en continu, et tout reste sur ton PC (jamais tes messages, ta banque ni la navigation privée).',
        );
      }
      if (RegExp(
        r'^(?:arrete|stop) de (?:regarder|voir|surveiller) (?:mon |l )?ecran$|^ne regarde plus (?:mon |l )?ecran$',
      ).hasMatch(n)) {
        return set({'ecran': false}, 'C\'est noté : je ne regarde plus ton écran.');
      }
      if (RegExp(
        r'^(?:ecoute|tu peux ecouter|entends) (?:le son|ce qui passe|mes videos)(?: du pc| de mon pc| sur mon pc)?(?: en continu| tout le temps)?$',
      ).hasMatch(n)) {
        return set(
          {'son': true},
          'D\'accord : j\'écoute le son de ton PC (les vidéos, pas la musique), jamais pendant un appel, et tout reste sur ton PC.',
        );
      }
      if (RegExp(
        r'^(?:arrete|stop) d ecouter(?: le son)?(?: du pc| de mon pc)?$|^n ecoute plus(?: le son)?(?: du pc)?$',
      ).hasMatch(n)) {
        return set({'son': false}, 'C\'est noté : je n\'écoute plus le son de ton PC.');
      }
      final eyes = RegExp(r'^(?:ferme les yeux|ne regarde pas|fais une pause d ecran)(?: pendant (.+))?$')
          .firstMatch(n);
      if (eyes != null) {
        final d = eyes[1] == null
            ? const Duration(hours: 1)
            : (FocusDuration.parse(eyes[1]!) ?? const Duration(hours: 1));
        return set({
          'pause_minutes': d.inMinutes,
        }, 'Je ferme les yeux et les oreilles pendant ${FocusDuration.say(d)}.');
      }
    }

    // Recherche partout.
    if (has('recherche_partout')) {
      final m = RegExp(
        r'^(?:cherche|recherche|trouve|retrouve)(?: moi)? (.{2,60}?) partout$|^(?:cherche|recherche) partout (.{2,60})$|'
        r'^(?:retrouve|trouve)(?: moi)? (?:le|mon|ma|la|les|mes) (?:fichier|document|doc|mail|message|note|pdf|expose) (?:sur |de |du |avec |qui parle de )?(.{2,60})$|'
        r'^ou est (?:le|mon|ma|la) (?:fichier|document|doc|pdf|expose) (?:sur |de |du )?(.{2,60})$',
      ).firstMatch(n);
      if (m != null) {
        final q = (m[1] ?? m[2] ?? m[3] ?? m[4])!.trim();
        final r = await call('recherche_partout', {'texte': q});
        if (has('recherche_ouvrir')) unawaited(call('recherche_ouvrir', {'texte': q}));
        if (r is Map) return QuickReply('${r['resume']}');
      }
    }

    // Mon argent : abonnements, colis, jeux gratuits.
    if (has('argent_abonnements') &&
        RegExp(
          r'^(?:quels sont |montre |liste |donne )?(?:moi )?mes abonnements$|'
          r'^combien (?:je depense|je paye|je paie|ca me coute)(?: par mois)? (?:en|pour mes|avec mes) abonnements$|'
          r'^(?:j ai|ai je) (?:quels|des) abonnements$',
        ).hasMatch(n)) {
      final r = await call('argent_abonnements', const {});
      if (r is Map) {
        final subs = _list(r['abonnements']).where((s) => s['resilie'] != true).toList();
        if (subs.isEmpty) {
          return const QuickReply(
            'Je ne connais aucun abonnement pour l\'instant. Ouvre « Mon argent » : je cherche dans tes mails.',
          );
        }
        final names = [for (final s in subs) s['prix'] == null ? '${s['service']}' : '${s['service']} (${s['prix']})'];
        final next = subs.where((s) => s['prochain'] != null).toList()
          ..sort((a, b) => '${a['prochain']}'.compareTo('${b['prochain']}'));
        final d = next.isEmpty ? null : DateTime.tryParse('${next.first['prochain']}');
        return QuickReply(
          '${subs.length} abonnement${subs.length > 1 ? 's' : ''} : ${names.join(', ')}. Soit ${r['total_par_mois']} par mois.'
          '${d == null ? '' : ' Le prochain : ${next.first['service']} ${_dayName(d, t)}.'}',
        );
      }
    }
    if (has('argent_colis') &&
        RegExp(
          r'^(?:ou (?:est|en est|en sont) (?:mon|mes) colis|mes colis|(?:il|elle) arrive quand mon colis|'
          r'(?:j ai|est ce que j ai) (?:un|des) colis(?: a recuperer| a retirer)?)$',
        ).hasMatch(n)) {
      final list = _list(await call('argent_colis', const {}));
      if (list.isEmpty) return const QuickReply('Aucun colis en cours dans tes mails.');
      return QuickReply([for (final p in list.take(4)) '📦 ${p['boutique']} : ${p['etat']}'].join('\n'));
    }
    if (has('argent_jeux') &&
        RegExp(
          r'^(?:quels sont les |y a t il des |il y a des |c est quoi les )?jeux gratuits(?: cette semaine| en ce moment| sur epic)?$',
        ).hasMatch(n)) {
      final r = await call('argent_jeux', const {});
      final free = r is Map ? _list(r['gratuits']).where((g) => g['maintenant'] == true).toList() : const <Map>[];
      if (free.isEmpty) return const QuickReply('Pas de jeu gratuit sur Epic en ce moment (ou pas d\'internet).');
      return QuickReply('🎮 Gratuit sur Epic en ce moment : ${free.map((g) => g['titre']).join(', ')}.');
    }

    // Outils d'études : correction sur la photo, coach d'oral, carte mentale.
    if (has('copie_corriger') &&
        RegExp(
          r'^corrige(?: moi)? (?:ma|mon|cette|la) (?:copie|redaction|dissertation|commentaire|photo|devoir|essai)$',
        ).hasMatch(n)) {
      return QuickReply('${await call('copie_corriger', const {})}');
    }
    if (has('oral_coach') &&
        RegExp(
          r'^(?:coach d oral|entraine moi (?:a|pour) (?:mon |l |le |mon grand )?(?:oral|expose|grand oral)|'
          r'(?:je veux |aide moi a )?repeter mon (?:oral|expose|grand oral))$',
        ).hasMatch(n)) {
      return QuickReply('${await call('oral_coach', const {})}');
    }
    if (has('carte_mentale')) {
      final m = RegExp(r'^(?:fais|dessine|cree)(?: moi)? une carte mentale (?:sur |de |du |des |d )(.{2,80})$')
          .firstMatch(n);
      if (m != null) {
        return QuickReply('${await call('carte_mentale', {'sujet': QuickAnswers.original(raw, m[1]!.trim())})}');
      }
    }

    // Langues : interprète et sous-titres en direct.
    if (has('interprete_ouvrir')) {
      const langs =
          r'(anglais|espagnol|allemand|italien|portugais|arabe|chinois|japonais|coreen|russe|turc|ukrainien|polonais|neerlandais|roumain)';
      final m = RegExp(
        '^(?:mode |lance |ouvre |active )?(?:l |un |mon )?interprete(?: (?:en |d |de |pour l |pour |francais )?$langs)?\$|'
        '^traduis (?:ma |notre |la |cette )?conversation(?: (?:en |avec l )?$langs)?\$',
      ).firstMatch(n);
      if (m != null) {
        return QuickReply('${await call('interprete_ouvrir', {'langue': m[1] ?? m[2] ?? 'anglais'})}');
      }
    }
    if (has('soustitres_lancer') &&
        RegExp(
          r'^(?:mets |lance |active |affiche )?(?:moi )?(?:les |des )?sous titres?(?: en direct| en francais)?$|'
          r'^sous titre(?: moi)? (?:ce que j ecoute|la video|ce qui passe|la serie)$|'
          r'^traduis(?: moi)? (?:ce que j ecoute|la video|ce qui passe|la serie|ce qu ils disent)$',
        ).hasMatch(n)) {
      return QuickReply('${await call('soustitres_lancer', const {})}');
    }

    // Playlist de soirée.
    if (has('soiree_ouvrir') &&
        RegExp(
          r'^(?:lance|ouvre|demarre|commence|fais)(?: une| la| ma)? (?:soiree|playlist de soiree|playlist soiree|fete)$|^mode (?:soiree|fete)$',
        ).hasMatch(n)) {
      return QuickReply('${await call('soiree_ouvrir', const {})}');
    }

    // Anniversaires.
    if (has('anniversaire_ajouter')) {
      final m = RegExp(
        r'^(?:retiens que |note que |souviens toi que |rappelle toi que |ajoute )?l anniv(?:ersaire)? (?:de |d )'
        r'([a-z][a-z -]{0,30}?) (?:c est |est |tombe )?(?:le |au )?(\d.*)$',
      ).firstMatch(n);
      final date = m == null ? null : Birthdays.parseDate(raw);
      if (m != null && date != null) {
        final (month, day, year) = date;
        final when = '$day/$month${year == null ? '' : '/$year'}';
        return QuickReply('${await call('anniversaire_ajouter', {'nom': original(raw, m[1]!), 'date': when})}');
      }
    }
    if (has('anniversaires')) {
      final one = RegExp(
        r'^(?:c est )?quand (?:est |c est |tombe )?l anniv(?:ersaire)? (?:de |d )([a-z][a-z -]{0,30}?)$|'
        r'^l anniv(?:ersaire)? (?:de |d )([a-z][a-z -]{0,30}?) (?:c est|est|tombe) quand$|'
        r'^(?:quelle est la )?date (?:de l |d )anniv(?:ersaire)? (?:de |d )([a-z][a-z -]{0,30}?)$',
      ).firstMatch(n);
      if (one != null) {
        return QuickReply('${await call('anniversaires', {'nom': original(raw, (one[1] ?? one[2] ?? one[3])!)})}');
      }
      final list = RegExp(
        r'^(?:les |mes )?(?:prochains )?anniv(?:ersaire)?s(?: a venir| qui arrivent| de la semaine| cette semaine| du mois| ce mois ci| ce mois)?$|'
        r'^qui (?:a|fete) son anniv(?:ersaire)? (?:bientot|cette semaine|aujourd hui|demain|ce mois ci|ce mois)$|'
        r'^c est l anniv(?:ersaire)? de qui(?: aujourd hui| demain)?$|^il y a des anniv(?:ersaire)?s (?:bientot|cette semaine|ce mois ci)$',
      ).hasMatch(n);
      if (list) {
        final days = n.contains('aujourd hui') || n.endsWith('de qui')
            ? 0
            : n.contains('demain')
            ? 1
            : n.contains('semaine')
            ? 7
            : 30;
        final r = await call('anniversaires', {'jours': days});
        if (r is Map) return QuickReply('${r['resume']}');
      }
    }

    // L'heure du coucher.
    if (has('assistant_coucher') &&
        RegExp(
          r'^(?:a )?quelle heure (?:je dois|dois je|il faut que je|est ce que je dois|je devrais) (?:me coucher|aller (?:me coucher|dormir|au lit)|dormir)(?: ce soir)?$|'
          r'^(?:quand|a quelle heure) (?:est ce que )?(?:je )?(?:dois|devrais) (?:me coucher|dormir)(?: ce soir)?$|^(?:mon |l )?heure (?:du|de) coucher(?: ce soir)?$|'
          r'^je me couche a quelle heure(?: ce soir)?$',
        ).hasMatch(n)) {
      return QuickReply('${await call('assistant_coucher', {})}');
    }

    // Les fenêtres.
    if (has('pc_fenetres')) {
      Future<QuickReply> win(String action, [String app = '']) async {
        final r = await call('pc_fenetres', {'action': action, 'appli': app});
        if (r is Map && r['ok'] == false) return QuickReply('${r['message'] ?? 'Je ne trouve pas cette fenêtre.'}');
        return const QuickReply('C\'est fait.');
      }

      if (RegExp(
        r'^(?:montre|affiche)(?: moi)? le bureau$|^(?:reduis|cache|baisse) tout(?:es les fenetres)?$|^(?:reduis|cache) toutes les fenetres$',
      ).hasMatch(n)) {
        return win('bureau');
      }
      if (RegExp(
        r'^(?:mets|met|passe)(?: cette fenetre| la fenetre| ca)? en (?:plein ecran|grand)$|^agrandis(?: la| cette)? fenetre$',
      ).hasMatch(n)) {
        return win('agrandir');
      }
      if (RegExp(r'^(?:reduis|cache)(?: la| cette)? fenetre$').hasMatch(n)) return win('reduire');
      final side = RegExp(r'^(?:mets|met|place|range|colle) (.+?) (?:a|sur la|sur le cote|du cote) (gauche|droite)$')
          .firstMatch(n);
      if (side != null) {
        final app = side.group(1)!;
        final here = RegExp(r'^(?:ca|cette fenetre|la fenetre|cette appli|l appli)$').hasMatch(app);
        return win(side.group(2)!, here ? '' : app);
      }
      final go = RegExp(r'^(?:bascule|reviens|retourne) (?:sur|dans|vers) (?:mon |ma |le |la |l )?(.+)$').firstMatch(n);
      if (go != null && !RegExp(r'\b(?:mode|cours|menu|accueil|question|sujet|debut|etape)\b').hasMatch(go.group(1)!)) {
        // Fenêtre introuvable : ce n'était peut-être pas une appli, l'IA répond.
        final r = await call('pc_fenetres', {'action': 'activer', 'appli': go.group(1)!});
        if (r is Map && r['ok'] != false) return const QuickReply('C\'est fait.');
      }
    }

    // Mode concentration.
    if (has('clicky_concentration')) {
      if (RegExp(
        r'^(?:arrete|stop|stoppe|fin du|termine|desactive|quitte|coupe|sors du) (?:le )?mode (?:concentration|focus|travail|ne pas deranger)$|'
        r'^(?:fin de (?:la )?(?:seance|concentration)|j ai fini de (?:travailler|bosser|reviser))$',
      ).hasMatch(n)) {
        final r = await call('clicky_concentration', {'arreter': true});
        return QuickReply(r is Map ? '${r['bilan'] ?? 'C\'est fini.'}' : 'C\'est fini.');
      }
      final focus = RegExp(
        r'^(?:(?:active|lance|demarre|mets|met|passe en|on passe en|je passe en) (?:le )?)?mode (?:concentration|focus|travail|ne pas deranger)(?: (.+))?$|'
        r'^(?:je (?:dois|veux|vais) (?:me concentrer|travailler|bosser|reviser))(?: (.+))?$|'
        r'^ne me derange (?:pas|plus)(?: (.+))?$|^concentration (.+)$',
      ).firstMatch(n);
      if (focus != null) {
        final rest = focus.group(1) ?? focus.group(2) ?? focus.group(3) ?? focus.group(4);
        final d = rest == null ? const Duration(minutes: 45) : FocusDuration.parse(rest);
        if (d != null) {
          final r = await call('clicky_concentration', {'minutes': d.inMinutes});
          final end = r is Map ? '${r['fin'] ?? ''}' : '';
          return QuickReply(
            'Mode concentration activé pour ${FocusDuration.say(d)}${end.isEmpty ? '' : ', jusqu\'à $end'}. '
            'Je ne te dérange plus et je garde les notifications pour la fin. Courage !',
          );
        }
      }
    }

    // « Rappelle-moi de … quand j'ouvre … ».
    if (has('clicky_rappel_appli')) {
      final m = RegExp(
        r'^(?:rappelle|redis|redit)(?: moi)? (?:de |d |que |qu )?(.+?) (?:quand|des que|la prochaine fois que) (?:j ouvre|j ouvrirai|je lance|je vais sur|j allume|j arrive sur) (.+)$',
      ).firstMatch(n);
      if (m != null) {
        // Le texte d'origine (avec ses accents) quand on le retrouve.
        final o = RegExp(
          r"(?:rappelle|redis|redit)[-\s]*(?:moi)?\s+(?:de\s+|d['’]\s*|que\s+|qu['’]\s*)?(.+?)\s+(?:quand|dès que|des que|la prochaine fois que)\s+(?:j['’]\s*ouvre|j['’]\s*ouvrirai|je lance|je vais sur|j['’]\s*allume|j['’]\s*arrive sur)\s+(.+?)[\s.!?]*$",
          caseSensitive: false,
        ).firstMatch(raw);
        final what = (o?.group(1) ?? m.group(1)!).trim();
        final app = (o?.group(2) ?? m.group(2)!).trim();
        await call('clicky_rappel_appli', {'appli': app, 'texte': what});
        return QuickReply('D\'accord : la prochaine fois que tu ouvres $app, je te rappelle de $what.');
      }
    }

    // Minuteur.
    final timer = RegExp(
      r'^(?:mets |met |lance |demarre |fais )?(?:moi )?(?:un |le )?(?:minuteur|chrono|timer|compte a rebours)(?: de| pour)? '
      r'(\d+) ?(secondes?|sec|s|minutes?|min|mn|heures?|h)$',
    ).firstMatch(n);
    final remind = RegExp(
      r'^(?:rappelle moi|previens moi) dans (\d+) ?(secondes?|minutes?|min|heures?|h)(?: de | pour | que | d )?(.*)$',
    ).firstMatch(n);
    final tm = timer ?? remind;
    if (tm != null) {
      final v = int.parse(tm.group(1)!);
      final unit = tm.group(2)!;
      final d = unit.startsWith('h')
          ? Duration(hours: v)
          : unit.startsWith('s')
          ? Duration(seconds: v)
          : Duration(minutes: v);
      if (d.inSeconds < 1 || d.inHours > 24) return null;
      final label = remind?.group(3)?.trim() ?? '';
      final what = unit.startsWith('h')
          ? '$v heure${v > 1 ? 's' : ''}'
          : unit.startsWith('s')
          ? '$v seconde${v > 1 ? 's' : ''}'
          : '$v minute${v > 1 ? 's' : ''}';
      return QuickReply(
        label.isEmpty ? 'C\'est parti pour $what.' : 'D\'accord, je te le rappelle dans $what.',
        timer: d,
        timerLabel: label,
      );
    }

    // Son.
    if (RegExp(r'^(?:monte|augmente|pousse) (?:le son|le volume|la musique)$').hasMatch(n)) {
      return const QuickReply('Je monte le son.', media: 'volup');
    }
    if (RegExp(r'^(?:baisse|diminue) (?:le son|le volume|la musique)$').hasMatch(n)) {
      return const QuickReply('Je baisse le son.', media: 'voldown');
    }
    if (RegExp(r'^(?:coupe|mute|enleve) (?:le son|le volume)$').hasMatch(n)) {
      return const QuickReply('Son coupé.', media: 'mute');
    }

    // Musique.
    if (has('musique_commande')) {
      Future<QuickReply> music(String action, String say) async {
        await call('musique_commande', {'action': action});
        return QuickReply(say);
      }

      if (RegExp(r'^(?:mets |met )?(?:la musique )?(?:en )?pause(?: la musique)?$|^(?:arrete|stoppe|stop) la musique$')
          .hasMatch(n)) {
        return music('pause', 'Pause.');
      }
      if (RegExp(
        r'^(?:(?:musique|chanson|titre|son|morceau) suivante?|(?:passe|mets|met) (?:a )?(?:la )?(?:musique|chanson) suivante|suivant(?:e)? (?:musique|chanson|titre)|next|skip)$',
      ).hasMatch(n)) {
        return music('suivant', 'Suivante !');
      }
      if (RegExp(
        r'^(?:(?:musique|chanson|titre|morceau) precedente?|(?:remets|mets|met) (?:la )?(?:musique|chanson) precedente|precedent(?:e)? (?:musique|chanson|titre))$',
      ).hasMatch(n)) {
        return music('precedent', 'La précédente.');
      }
      if (RegExp(r'^(?:remets|relance|reprends|rejoue) la musique$|^(?:play|lecture|joue de la musique)$')
          .hasMatch(n)) {
        return music('lecture', 'C\'est reparti.');
      }
    }
    if (has('musique_en_cours') &&
        RegExp(
          r'^(?:c est quoi|quelle est|c est quelle|quel est) (?:cette|la|ce) (?:musique|chanson|son|titre|morceau)(?: qu on ecoute)?$|^(?:qu est ce qu on ecoute|on ecoute quoi)$',
        ).hasMatch(n)) {
      final r = await call('musique_en_cours', {});
      if (r is Map) return QuickReply('C\'est « ${r['titre']} » de ${r['artiste']}.');
      return const QuickReply('Rien n\'est en écoute pour l\'instant.');
    }

    // Devoirs et contrôles (École Directe).
    if (has('ecole_devoirs')) {
      final test = RegExp(
        r'^(?:c est quand |quand est |quand c est |j ai quand )?(?:mon |le )?prochain (?:controle|devoir surveille|ds|interro|evaluation)$|'
        r'^(?:j ai des|quels sont mes|mes) (?:controles|evaluations|interros)(?: cette semaine| a venir)?$',
      ).hasMatch(n);
      final hw = RegExp(
        r'^(?:c est quoi |quels sont |qu est ce que j ai comme |j ai quoi comme |j ai des |mes |les )?devoirs'
        r'(?: a faire)?(?: (?:pour )?(?:demain|apres demain|aujourd hui|cette semaine|la semaine|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche))?$|'
        r'^(?:qu est ce que j ai|j ai quoi) a faire(?: pour)?(?: (?:demain|apres demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche))?$',
      ).hasMatch(n);
      if (test || hw) {
        final list = _list(await call('ecole_devoirs', {}));
        final today = DateTime(t.year, t.month, t.day);
        if (test) {
          final tests = [
            for (final h in list)
              if (h['controle'] == true && !(_date(h['pour_le'])?.isBefore(today) ?? true)) h,
          ]..sort((a, b) => _date(a['pour_le'])!.compareTo(_date(b['pour_le'])!));
          if (tests.isEmpty) return const QuickReply('Je ne vois aucun contrôle prévu dans le cahier de texte.');
          final first = tests.first;
          final more = tests.length > 1
              ? ' Puis ${[for (final x in tests.skip(1).take(3)) '${x['matiere']} ${_dayName(_date(x['pour_le'])!, t)}'].join(', ')}.'
              : '';
          final c = '${first['contenu'] ?? ''}'.trim();
          return QuickReply(
            'Ton prochain contrôle : ${first['matiere']} ${_dayName(_date(first['pour_le'])!, t)}${c.isEmpty ? '' : ' (${_short(c, 70)})'}.$more',
          );
        }
        final day = dayFrom(n, t);
        final week = RegExp(r'\bsemaine\b').hasMatch(n);
        final pick = [
          for (final h in list)
            if (h['fait'] != true)
              if (_date(h['pour_le']) case final d?)
                if (day != null
                    ? d.year == day.year && d.month == day.month && d.day == day.day
                    : !d.isBefore(today) && d.difference(today).inDays <= (week ? 7 : 3))
                  h,
        ]..sort((a, b) => _date(a['pour_le'])!.compareTo(_date(b['pour_le'])!));
        if (pick.isEmpty) {
          return QuickReply(day != null ? 'Rien à faire pour ${_dayName(day, t)} 🎉' : 'Aucun devoir en attente 🎉');
        }
        final parts = [
          for (final h in pick.take(6))
            '${day == null ? '${_dayName(_date(h['pour_le'])!, t)}, ' : ''}${h['matiere']} : ${_short('${h['contenu']}', 80)}',
        ];
        return QuickReply(
          '${day != null ? 'Pour ${_dayName(day, t)}' : 'À faire'} (${pick.length}) : ${parts.join(' ; ')}${pick.length > 6 ? '…' : '.'}',
        );
      }
    }

    // Emploi du temps.
    if (has('agenda_lire')) {
      final next = RegExp(r'^(?:c est quoi |quel est |j ai quoi comme )?(?:mon |le )?prochain cours$').hasMatch(n);
      final day = RegExp(
        r'^(?:j ai quoi|qu est ce que j ai|j ai cours|quels cours j ai|j ai quels cours|quels sont mes cours|'
        r'c est quoi mon emploi du temps|mon emploi du temps|emploi du temps|mon planning|c est quoi mon planning)'
        r'(?: (?:pour )?(?:demain|apres demain|aujourd hui|cet apres midi|ce matin|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche))?$',
      ).hasMatch(n);
      if (next || day) {
        final target = next ? DateTime(t.year, t.month, t.day) : (dayFrom(n, t) ?? DateTime(t.year, t.month, t.day));
        final items = [
          for (final e in _list(
            await call('agenda_lire', {'debut': target.toIso8601String().substring(0, 10), 'jours': next ? 7 : 1}),
          ))
            if (e['annule'] != true) e,
        ]..sort((a, b) => _date(a['debut'])!.compareTo(_date(b['debut'])!));
        if (next) {
          final up = items.where((e) => _date(e['debut'])!.isAfter(t)).firstOrNull;
          if (up == null) return const QuickReply('Je ne vois pas de cours à venir cette semaine.');
          final d = _date(up['debut'])!;
          final lieu = '${up['lieu'] ?? ''}'.trim();
          return QuickReply(
            'Ton prochain cours : ${up['titre']}, ${_dayName(d, t)} à ${_hour(d)}${lieu.isEmpty ? '' : ' (salle $lieu)'}.',
          );
        }
        final cancelled = RegExp(r'\bapres midi\b').hasMatch(n)
            ? items.where((e) => _date(e['debut'])!.hour >= 12).toList()
            : RegExp(r'\bmatin\b').hasMatch(n)
            ? items.where((e) => _date(e['debut'])!.hour < 12).toList()
            : items;
        if (cancelled.isEmpty) return QuickReply('Rien de prévu ${_dayName(target, t)} 😎');
        final parts = [for (final e in cancelled.take(9)) '${_hour(_date(e['debut'])!)} ${e['titre']}'];
        final end = _date(cancelled.last['fin']);
        return QuickReply(
          '${_dayName(target, t)[0].toUpperCase()}${_dayName(target, t).substring(1)} : ${parts.join(', ')}'
          '${end == null ? '' : '. Tu finis à ${_hour(end)}'}.',
        );
      }
    }

    // Prépare ton sac.
    if (has('assistant_sac') &&
        RegExp(
          r'^(?:qu est ce que je dois prendre|je dois prendre quoi|qu est ce que je prends|je prends quoi|qu est ce que je mets dans mon sac)(?: demain| pour demain)?$|'
          r'^(?:prepare|fais|on prepare|aide moi a preparer) (?:mon |le )?sac(?: pour demain)?$|^(?:mon |le )?sac(?: pour demain| de demain)$',
        ).hasMatch(n)) {
      return QuickReply('${await call('assistant_sac', {})}');
    }

    // Moyennes : la note qu'il faut, la moyenne d'une matière, le bilan.
    if (has('ecole_moyenne')) {
      final need =
          RegExp(
            r'^(?:il me faut|il faut que j aie|je dois avoir|j ai besoin de|faut que j ai|faut que j aie) combien|'
            r'^quelle note (?:il me faut|je dois avoir|dois je avoir|faut il)',
          ).hasMatch(n)
          ? RegExp(
              r'\b(?:en|de) (.+?) pour (?:avoir|atteindre|monter a|remonter a|etre a|passer a) (\d{1,2})(?: (\d))?(?: de moyenne)?$',
            ).firstMatch(n)
          : null;
      if (need != null) {
        final target = double.parse('${need.group(2)}${need.group(3) == null ? '' : '.${need.group(3)}'}');
        final subject = need.group(1)!.replaceFirst(RegExp(r'^(?:au prochain (?:devoir|controle|test|ds) )'), '');
        final coef = RegExp(r'coef(?:ficient)? (\d)').firstMatch(n);
        final r = await call('ecole_moyenne', {
          'matiere': subject,
          'objectif': target,
          if (coef != null) 'coef': int.parse(coef.group(1)!),
        });
        if (r is Map && r['resume'] != null) return QuickReply('${r['resume']}');
        if (r is Map && r['message'] != null) return QuickReply('${r['message']}');
      }
      final avg = RegExp(
        r'^(?:c est quoi |quelle est |combien j ai de |j ai combien de )?(?:ma |de )?moyenne(?: generale)?(?: (?:en|de) (.+?))?$',
      ).firstMatch(n);
      if (avg != null) {
        final subject = avg.group(1);
        final r = await call('ecole_moyenne', {'matiere': subject ?? ''});
        if (r is Map && subject == null && r['generale'] != null) {
          return QuickReply('Ta moyenne générale est de ${r['generale']} pour l\'instant.');
        }
        if (r is Map && r['moyenne'] != null) {
          return QuickReply(
            'Ta moyenne en ${subject ?? r['matiere']} est de ${r['moyenne']} (${r['nombre_de_notes']} notes ce trimestre).',
          );
        }
        if (r is Map && r['message'] != null) return QuickReply('${r['message']}');
      }
    }
    if (has('ecole_bilan_notes') &&
        RegExp(
          r'^(?:fais(?: moi)? (?:le |un )?)?bilan (?:de |des )?(?:mes )?notes(?: de la semaine)?$|^comment (?:vont|sont) mes notes(?: cette semaine)?$',
        ).hasMatch(n)) {
      return QuickReply('${await call('ecole_bilan_notes', {})}');
    }

    // Notes.
    if (has('ecole_notes') &&
        RegExp(
          r'^(?:mes |quelles sont mes |c est quoi mes |j ai eu quoi comme |j ai quoi comme |montre moi mes )?(?:dernieres |nouvelles )?notes$',
        ).hasMatch(n)) {
      final list = _list(await call('ecole_notes', {}));
      if (list.isEmpty) return const QuickReply('Je ne vois pas encore de notes.');
      final parts = [for (final g in list.take(5)) '${g['matiere']} ${g['note']}'];
      return QuickReply('Tes dernières notes : ${parts.join(', ')}.');
    }

    // Météo.
    if (has('carnet_meteo') &&
        RegExp(
          r'^(?:quel temps (?:fait il|il fait|fera t il|va t il faire|il va faire)|(?:la )?meteo|il va pleuvoir|'
          r'il pleut|il fait (?:froid|chaud)(?: dehors)?|qu est ce que je mets|je mets quoi|comment je m habille)'
          r'(?: aujourd hui| demain| dehors| ce soir)?$',
        ).hasMatch(n)) {
      final w = await call('carnet_meteo', {});
      if (w is! Map) return null;
      if (RegExp(r'\bdemain\b').hasMatch(n) && w['demain'] != null) {
        return QuickReply('Demain : ${w['demain'] is Map ? (w['demain'] as Map).values.join(', ') : w['demain']}.');
      }
      return QuickReply(
        '${w['icone'] ?? ''} ${w['maintenant']} à ${w['ville']}. Entre ${w['min']} et ${w['max']} °C, '
                '${w['pluie_pourcent']} % de risque de pluie. ${w['tenue'] ?? ''}'
            .trim(),
      );
    }

    // Révisions.
    final mock = RegExp(
      r'^(?:(?:fais|fait|prepare|lance|donne)(?: moi)? |je veux )?(?:un |une )?(?:controle|interro|interrogation|devoir|examen|ds) blanc(?:he)? (?:de |d |en |sur (?:le |la |les )?)(.+)$',
    ).firstMatch(n);
    if (mock != null && has('revision_controle_blanc')) {
      await call('revision_controle_blanc', {'matiere': mock.group(1)!});
      return QuickReply(
        'Je te prépare un contrôle blanc de ${mock.group(1)} : il s\'ouvre dans Mon Hub. Bon courage !',
      );
    }
    if (has('revision_lancer')) {
      if (RegExp(
        r'^(?:lance |mets |demarre )?(?:le |un )?(?:pomodoro|minuteur de (?:travail|concentration|revision|revisions))$',
      ).hasMatch(n)) {
        await call('revision_lancer', {'mode': 'minuteur'});
        return const QuickReply('Minuteur de concentration ouvert. Bon courage !');
      }
      if (RegExp(
        r'^(?:lance |commence |on fait |je veux faire )?(?:une |mes |ma )?(?:revision|revisions|seance de revision)(?: du jour)?$|^(?:fais moi reviser|revise avec moi|on revise)$',
      ).hasMatch(n)) {
        await call('revision_lancer', {'mode': 'cartes'});
        return const QuickReply('C\'est parti, ta séance est ouverte.');
      }
    }
    if (has('revision_paquets') &&
        RegExp(
          r'^(?:combien (?:de cartes|j ai de cartes)(?: a reviser| a revoir)?|ma serie|c est quoi ma serie|j en suis ou dans mes revisions)$',
        ).hasMatch(n)) {
      final r = await call('revision_paquets', {});
      if (r is! Map) return null;
      final due = r['a_revoir_aujourdhui'];
      final s = r['serie_jours'];
      return QuickReply(
        '$due carte${due == 1 ? '' : 's'} à revoir aujourd\'hui, série de $s jour${s == 1 ? '' : 's'} 🔥',
      );
    }

    // Ranger.
    final tidy = RegExp(r'^(?:range|trie|nettoie|organise) (.+)$').firstMatch(n);
    if (tidy != null) {
      final what = tidy.group(1)!;
      final folder = _folders[what];
      if (folder != null && has('pc_ranger')) {
        final plan = await call('pc_ranger_apercu', {'dossier': folder});
        final count = plan is Map ? plan['fichiers'] : 0;
        if (count == 0) return const QuickReply('C\'est déjà rangé ✨');
        final r = await call('pc_ranger', {'dossier': folder});
        final done = r is Map ? r['ranges'] : 0;
        return QuickReply(
          'C\'est rangé : $done fichier${done == 1 ? '' : 's'} dans des dossiers. Dis « annule le rangement » pour revenir en arrière.',
        );
      }
      if (RegExp(r'^(?:mon |le )?(?:google )?drive$').hasMatch(what) && has('drive_ranger')) {
        final r = await call('drive_ranger', {});
        final done = r is Map ? r['ranges'] : 0;
        return QuickReply('Ton Drive est rangé : $done fichier${done == 1 ? '' : 's'} déplacé${done == 1 ? '' : 's'}.');
      }
    }
    if (RegExp(r'^(?:annule|defais) (?:le |mon )?rangement(?: du pc)?$').hasMatch(n) && has('pc_ranger_annuler')) {
      final r = await call('pc_ranger_annuler', {});
      final k = r is Map ? r['remis_en_place'] : 0;
      return QuickReply(k == 0 ? 'Il n\'y a rien à annuler.' : '$k fichier${k == 1 ? '' : 's'} remis à leur place.');
    }

    // YouTube.
    final yt = RegExp(r'^(?:mets|met|lance|joue|montre moi|cherche|mets moi)(?: moi)? (.+?) sur youtube$')
        .firstMatch(n);
    if (yt != null && has('youtube_lire')) {
      await call('youtube_lire', {'recherche': yt.group(1)!});
      return QuickReply('Je lance « ${yt.group(1)} » sur YouTube.');
    }

    // Écouter un cours en entier, puis le compte rendu.
    if (has('cours_ecouter')) {
      final stop = RegExp(
        r'^(?:arrete|stop|stoppe|termine|finis|fini|coupe) (?:d ecouter |l ecoute (?:du |de )?|l enregistrement (?:du |de )?|d enregistrer )?(?:le |mon |ce )?cours$|'
        r'^le cours est (?:fini|termine)$|^c est la fin du cours$',
      ).hasMatch(n);
      final start = RegExp(
        r'^(?:ecoute|enregistre|suis) (?:le |mon |ce |tout le )?cours(?: en entier)?(?: (?:et|pour) (?:fais|fait|faire) (?:moi )?(?:un |le )?compte rendu)?$|'
        r'^(?:fais|fait) (?:moi )?(?:un |le )?compte rendu (?:du|de mon|de ce) cours$|'
        r'^prends? (?:le cours )?en notes?$|^prends? des notes(?: du cours)?$',
      ).hasMatch(n);
      if (stop) {
        final r = await call('cours_arreter', {});
        if (r is Map && r['ok'] == false) return QuickReply('${r['message'] ?? 'Je n\'écoutais pas de cours.'}');
        return const QuickReply('Cours terminé : je finis la transcription et je rédige ton compte rendu.');
      }
      if (start) {
        final r = await call('cours_ecouter', {});
        if (r is Map && r['ok'] == false) return QuickReply('${r['message'] ?? 'Impossible d\'écouter le cours.'}');
        final subject = r is Map ? '${r['matiere'] ?? ''}' : '';
        final end = r is Map ? '${r['fin'] ?? ''}' : '';
        return QuickReply(
          'Je t\'écoute${subject.isEmpty ? '' : ' en $subject'} : je prends tout le cours en notes'
          '${end.isEmpty ? '' : ' jusqu\'à $end'}. Dis « arrête le cours » à la fin et je te fais le compte rendu.',
        );
      }
    }

    // Nouveau document.
    if (has('doc_nouveau') &&
        RegExp(
          r'^(?:cree|ouvre|fais|commence|nouveau)(?: moi)?(?: un)?(?: nouveau)? (?:document|doc|google doc|word)(?: vierge)?$',
        ).hasMatch(n)) {
      await call('doc_nouveau', {});
      return const QuickReply('Voilà un nouveau document.');
    }

    // Liste de tâches.
    final todo = RegExp(
      r'^(?:ajoute|note|mets|rajoute) (.+?) (?:a|dans|sur) (?:ma|la) (?:liste|todo|to do)(?: de taches| de choses a faire| de trucs a faire)?$',
    ).firstMatch(n);
    if (todo != null && has('carnet_taches_notes')) {
      // Le texte d'origine (avec ses accents) quand on le retrouve.
      final m = RegExp(
        r'(?:ajoute|note|mets|rajoute)\s+(.+?)\s+(?:à|a|dans|sur)\s+(?:ma|la)\s+(?:liste|todo|to do)',
        caseSensitive: false,
      ).firstMatch(raw);
      final text = (m?.group(1) ?? todo.group(1)!).trim();
      await call('carnet_taches_notes', {'action': 'ajouter_tache', 'texte': text});
      return QuickReply('Ajouté à ta liste : $text.');
    }

    // Ouvrir une appli ou un site.
    final open = RegExp(r'^(?:ouvre|lance|ouvre moi|va sur|demarre) (.+)$').firstMatch(n);
    if (open != null && has('pc_ouvrir')) {
      final target = opens[open.group(1)!.trim()];
      if (target != null) {
        await call('pc_ouvrir', {'cible': target});
        return const QuickReply('C\'est ouvert.');
      }
    }
    return null;
  }
}

/// Une calculatrice qui comprend « combien font 12 fois 7 », « 15 % de 80 »,
/// « racine de 144 », « (3+4)*2 »…
class Calc {
  Calc._();

  static String format(double v) {
    if (v.isNaN || v.isInfinite) return 'impossible';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    var s = v.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }

  /// Le résultat en phrase, ou null si ce n'est pas un calcul.
  static String? fromSentence(String raw) {
    var s = raw.toLowerCase().trim();
    s = s.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis) )?(?:clicky|smily|smiley|simile)[, ]*'), '');
    final before = s;
    s = s.replaceFirst(
      RegExp(
        r'^(?:combien (?:font|fait|ça fait|ca fait|ça donne|ca donne)|calcule(?:-moi)?|c.est combien|ça fait combien|ca fait combien|résultat de|resultat de)\s*',
      ),
      '',
    );
    // « Calcule… », « … divisé par … » : c'est sûr que c'est un calcul.
    final asked = s != before || RegExp(r'[a-zàâçéèêëîïôûù]').hasMatch(s);
    s = s.replaceFirst(RegExp(r'\s*(?:\?|=|égale? combien|egale? combien|ça fait combien|ca fait combien)\s*$'), '');
    if (s.isEmpty) return null;
    // Pourcentage : « 15 % de 80 », « 20 pour cent de 45 ».
    final pc = RegExp(r'^(\d+(?:[.,]\d+)?)\s*(?:%|pour ?cents?|pourcents?) de (\d+(?:[.,]\d+)?)$').firstMatch(s);
    if (pc != null) {
      final a = double.parse(pc.group(1)!.replaceAll(',', '.'));
      final b = double.parse(pc.group(2)!.replaceAll(',', '.'));
      return '${pc.group(1)} % de ${pc.group(2)}, ça fait ${format(a * b / 100)}.';
    }
    var e = s
        .replaceAll(RegExp(r'racine(?: carrée| carree)? de'), 'sqrt ')
        .replaceAll(RegExp(r'\bau carré\b|\bau carre\b'), '^2')
        .replaceAll(RegExp(r'\bau cube\b'), '^3')
        .replaceAll(RegExp(r'\bmultiplié par\b|\bmultiplie par\b|\bfois\b|×'), '*')
        .replaceAll(RegExp(r'\bdivisé par\b|\bdivise par\b|÷'), '/')
        .replaceAll(RegExp(r'\bplus\b'), '+')
        .replaceAll(RegExp(r'\bmoins\b'), '-')
        .replaceAll(RegExp(r'\bpuissance\b'), '^')
        .replaceAllMapped(RegExp(r'(\d)\s*x\s*(\d)'), (m) => '${m[1]}*${m[2]}')
        .replaceAllMapped(RegExp(r'(\d),(\d)'), (m) => '${m[1]}.${m[2]}');
    e = e.replaceAll(' ', '');
    if (!RegExp(r'^[\d.+\-*/^()sqrt]+$').hasMatch(e)) return null;
    if (!RegExp(r'\d').hasMatch(e) || !RegExp(r'[+\-*/^]|sqrt').hasMatch(e)) return null;
    // Une date (« 12/11 ») ou un numéro tout seul n'est pas un calcul.
    if (!asked && RegExp(r'^\d{1,2}/\d{1,2}(?:/\d{2,4})?$').hasMatch(e)) return null;
    try {
      final v = _Parser(e).parse();
      return 'Ça fait ${format(v)}.';
    } catch (_) {
      return null;
    }
  }
}

class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  double parse() {
    final v = _sum();
    if (i != s.length) throw const FormatException('reste');
    return v;
  }

  double _sum() {
    var v = _product();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = _product();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  double _product() {
    var v = _power();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = _power();
      v = op == '*' ? v * r : v / r;
    }
    return v;
  }

  double _power() {
    final b = _unary();
    if (i < s.length && s[i] == '^') {
      i++;
      return math.pow(b, _power()).toDouble();
    }
    return b;
  }

  double _unary() {
    if (i < s.length && s[i] == '-') {
      i++;
      return -_unary();
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return _unary();
    }
    if (s.startsWith('sqrt', i)) {
      i += 4;
      return math.sqrt(_unary());
    }
    if (i < s.length && s[i] == '(') {
      i++;
      final v = _sum();
      if (i >= s.length || s[i] != ')') throw const FormatException(')');
      i++;
      return v;
    }
    final start = i;
    while (i < s.length && RegExp(r'[\d.]').hasMatch(s[i])) {
      i++;
    }
    if (start == i) throw const FormatException('nombre');
    return double.parse(s.substring(start, i));
  }
}

/// Durées dites à l'oral pour le mode concentration (« 45 min », « 1 h 30 »,
/// « une demi-heure »).
class FocusDuration {
  FocusDuration._();

  static Duration? parse(String n) {
    var t = n.trim().replaceFirst(RegExp(r'^(?:pendant|pour|durant) '), '');
    t = t
        .replaceAll(RegExp(r'\b(?:une )?demi heure\b'), '30 min')
        .replaceAll(RegExp(r'\b(?:un )?quart d heure\b'), '15 min');
    const words = {
      'une': 1,
      'un': 1,
      'deux': 2,
      'trois': 3,
      'quatre': 4,
      'cinq': 5,
      'dix': 10,
      'quinze': 15,
      'vingt': 20,
      'trente': 30,
    };
    final m = RegExp(
      r'^(\d{1,3}|une|un|deux|trois|quatre|cinq|dix|quinze|vingt|trente) ?(h|heures?|min|minutes?|mn)(?: ?(?:et )?(\d{1,2}|demie|quart)(?: ?(?:min|minutes?|mn))?)?$',
    ).firstMatch(t);
    if (m == null) return null;
    final v = int.tryParse(m[1]!) ?? words[m[1]!]!;
    final hours = m[2]!.startsWith('h');
    var minutes = hours ? v * 60 : v;
    final extra = m[3];
    if (extra != null) {
      if (!hours) return null;
      minutes += extra == 'demie' ? 30 : (extra == 'quart' ? 15 : int.parse(extra));
    }
    if (minutes < 5 || minutes > 8 * 60) return null;
    return Duration(minutes: minutes);
  }

  static String say(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '$m minutes';
    final h = m ~/ 60, r = m % 60;
    return '$h heure${h > 1 ? 's' : ''}${r == 0 ? '' : ' $r'}';
  }
}
