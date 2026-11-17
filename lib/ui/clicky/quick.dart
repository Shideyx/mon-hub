import 'dart:math' as math;

import '../widgets.dart';
import 'tutor.dart' show normalize;

/// Appel d'une action de Mon Hub (agenda, devoirs, musique…).
typedef QuickTool = Future<Object?> Function(String name, Map<String, dynamic> args);

/// Ce que Clicky répond sans l'IA.
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

  /// La phrase nettoyée : minuscules, sans accents, sans « Clicky » ni
  /// « s'il te plaît ».
  static String clean(String raw) {
    var n = normalize(raw);
    n = n.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis|eh|he|alors) )?clicky ?'), '');
    n = n.replaceFirst(RegExp(r' (?:s il te plait|s il vous plait|stp|svp|merci)$'), '');
    return n.trim();
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

  static String _hour(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static String _short(String s, [int max = 90]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  static List<Map> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map) e,
  ];

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('$v');

  /// Ce que Clicky sait ouvrir tout seul.
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
    if (RegExp(r'^(?:quelle heure (?:est il|il est)|il est quelle heure|c est quelle heure|l heure|donne moi l heure)$').hasMatch(n)) {
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
        final l = [for (final x in (r['priorites'] as List?) ?? const []) if (x is Map) x];
        if (l.isEmpty) return const QuickReply('Rien d\'urgent : tu es à jour, bravo !');
        return QuickReply([
          r['trop_de_choses'] == true ? 'Ça fait beaucoup, alors concentre-toi sur les 3 premières :' : 'Par quoi commencer :',
          for (final (i, t) in l.take(5).indexed) '${i + 1}. ${t['tache']} (${t['pourquoi']})',
        ].join('\n'));
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
        final plan = [for (final x in (r['plan_propose'] as List?) ?? const []) if (x is Map) x];
        return QuickReply([
          'Voici ce que je te propose :',
          for (final p in plan) '• ${'${p['debut']}'.substring(11, 16)} ${p['titre']}',
          'Clique sur « Mettre dans l\'agenda » pour l\'enregistrer.',
        ].join('\n'));
      }
    }
    if (has('assistant_objectifs') && RegExp(r'^(?:quels sont |c est quoi )?mes objectifs$').hasMatch(n)) {
      final r = await call('assistant_objectifs', const {'action': 'lister'});
      if (r is List) {
        final open = [
          for (final g in r)
            if (g is Map && g['atteint'] != true) '${g['objectif']}',
        ];
        return QuickReply(open.isEmpty
            ? 'Tu n\'as pas encore d\'objectif. Dis-moi « mon objectif est de… » et je le retiens.'
            : 'Tes objectifs : ${open.join(' · ')}.');
      }
    }

    // Minuteur.
    final timer = RegExp(
      r'^(?:mets |met |lance |demarre |fais )?(?:moi )?(?:un |le )?(?:minuteur|chrono|timer|compte a rebours)(?: de| pour)? '
      r'(\d+) ?(secondes?|sec|s|minutes?|min|mn|heures?|h)$',
    ).firstMatch(n);
    final remind = RegExp(r'^(?:rappelle moi|previens moi) dans (\d+) ?(secondes?|minutes?|min|heures?|h)(?: de | pour | que | d )?(.*)$')
        .firstMatch(n);
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
      final what = unit.startsWith('h') ? '$v heure${v > 1 ? 's' : ''}' : unit.startsWith('s') ? '$v seconde${v > 1 ? 's' : ''}' : '$v minute${v > 1 ? 's' : ''}';
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

      if (RegExp(r'^(?:mets |met )?(?:la musique )?(?:en )?pause(?: la musique)?$|^(?:arrete|stoppe|stop) la musique$').hasMatch(n)) {
        return music('pause', 'Pause.');
      }
      if (RegExp(r'^(?:(?:musique|chanson|titre|son|morceau) suivante?|(?:passe|mets|met) (?:a )?(?:la )?(?:musique|chanson) suivante|suivant(?:e)? (?:musique|chanson|titre)|next|skip)$').hasMatch(n)) {
        return music('suivant', 'Suivante !');
      }
      if (RegExp(r'^(?:(?:musique|chanson|titre|morceau) precedente?|(?:remets|mets|met) (?:la )?(?:musique|chanson) precedente|precedent(?:e)? (?:musique|chanson|titre))$').hasMatch(n)) {
        return music('precedent', 'La précédente.');
      }
      if (RegExp(r'^(?:remets|relance|reprends|rejoue) la musique$|^(?:play|lecture|joue de la musique)$').hasMatch(n)) {
        return music('lecture', 'C\'est reparti.');
      }
    }
    if (has('musique_en_cours') &&
        RegExp(r'^(?:c est quoi|quelle est|c est quelle|quel est) (?:cette|la|ce) (?:musique|chanson|son|titre|morceau)(?: qu on ecoute)?$|^(?:qu est ce qu on ecoute|on ecoute quoi)$').hasMatch(n)) {
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
          final more = tests.length > 1 ? ' Puis ${[for (final x in tests.skip(1).take(3)) '${x['matiere']} ${_dayName(_date(x['pour_le'])!, t)}'].join(', ')}.' : '';
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
          for (final e in _list(await call('agenda_lire', {
            'debut': target.toIso8601String().substring(0, 10),
            'jours': next ? 7 : 1,
          })))
            if (e['annule'] != true) e,
        ]..sort((a, b) => _date(a['debut'])!.compareTo(_date(b['debut'])!));
        if (next) {
          final up = items.where((e) => _date(e['debut'])!.isAfter(t)).firstOrNull;
          if (up == null) return const QuickReply('Je ne vois pas de cours à venir cette semaine.');
          final d = _date(up['debut'])!;
          final lieu = '${up['lieu'] ?? ''}'.trim();
          return QuickReply('Ton prochain cours : ${up['titre']}, ${_dayName(d, t)} à ${_hour(d)}${lieu.isEmpty ? '' : ' (salle $lieu)'}.');
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

    // Notes.
    if (has('ecole_notes') &&
        RegExp(r'^(?:mes |quelles sont mes |c est quoi mes |j ai eu quoi comme |j ai quoi comme |montre moi mes )?(?:dernieres |nouvelles )?notes$').hasMatch(n)) {
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
        '${w['pluie_pourcent']} % de risque de pluie. ${w['tenue'] ?? ''}'.trim(),
      );
    }

    // Révisions.
    if (has('revision_lancer')) {
      if (RegExp(r'^(?:lance |mets |demarre )?(?:le |un )?(?:pomodoro|minuteur de (?:travail|concentration|revision|revisions))$').hasMatch(n)) {
        await call('revision_lancer', {'mode': 'minuteur'});
        return const QuickReply('Minuteur de concentration ouvert. Bon courage !');
      }
      if (RegExp(r'^(?:lance |commence |on fait |je veux faire )?(?:une |mes |ma )?(?:revision|revisions|seance de revision)(?: du jour)?$|^(?:fais moi reviser|revise avec moi|on revise)$').hasMatch(n)) {
        await call('revision_lancer', {'mode': 'cartes'});
        return const QuickReply('C\'est parti, ta séance est ouverte.');
      }
    }
    if (has('revision_paquets') &&
        RegExp(r'^(?:combien (?:de cartes|j ai de cartes)(?: a reviser| a revoir)?|ma serie|c est quoi ma serie|j en suis ou dans mes revisions)$').hasMatch(n)) {
      final r = await call('revision_paquets', {});
      if (r is! Map) return null;
      final due = r['a_revoir_aujourdhui'];
      final s = r['serie_jours'];
      return QuickReply('$due carte${due == 1 ? '' : 's'} à revoir aujourd\'hui, série de $s jour${s == 1 ? '' : 's'} 🔥');
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
        return QuickReply('C\'est rangé : $done fichier${done == 1 ? '' : 's'} dans des dossiers. Dis « annule le rangement » pour revenir en arrière.');
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
    final yt = RegExp(r'^(?:mets|met|lance|joue|montre moi|cherche|mets moi)(?: moi)? (.+?) sur youtube$').firstMatch(n);
    if (yt != null && has('youtube_lire')) {
      await call('youtube_lire', {'recherche': yt.group(1)!});
      return QuickReply('Je lance « ${yt.group(1)} » sur YouTube.');
    }

    // Nouveau document.
    if (has('doc_nouveau') &&
        RegExp(r'^(?:cree|ouvre|fais|commence|nouveau)(?: moi)?(?: un)?(?: nouveau)? (?:document|doc|google doc|word)(?: vierge)?$').hasMatch(n)) {
      await call('doc_nouveau', {});
      return const QuickReply('Voilà un nouveau document.');
    }

    // Liste de tâches.
    final todo = RegExp(r'^(?:ajoute|note|mets|rajoute) (.+?) (?:a|dans|sur) (?:ma|la) (?:liste|todo|to do)(?: de taches| de choses a faire| de trucs a faire)?$')
        .firstMatch(n);
    if (todo != null && has('carnet_taches_notes')) {
      // Le texte d'origine (avec ses accents) quand on le retrouve.
      final m = RegExp(r'(?:ajoute|note|mets|rajoute)\s+(.+?)\s+(?:à|a|dans|sur)\s+(?:ma|la)\s+(?:liste|todo|to do)', caseSensitive: false)
          .firstMatch(raw);
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
    s = s.replaceFirst(RegExp(r'^(?:(?:hey|ok|dis) )?clicky[, ]*'), '');
    final before = s;
    s = s.replaceFirst(RegExp(r'^(?:combien (?:font|fait|ça fait|ca fait|ça donne|ca donne)|calcule(?:-moi)?|c.est combien|ça fait combien|ca fait combien|résultat de|resultat de)\s*'), '');
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
