import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/file_viewer.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import 'ed_client.dart';
import 'grade_math.dart';

/// Emploi du temps École Directe (API non officielle, expérimental).
class EcoleDirecteModule extends HubModule {
  final client = EdClient();
  List<EdLesson> _cache = [];

  /// Cours chargés (semaine en cours + 3 semaines), utilisés par l'Agenda.
  List<EdLesson> get lessons => _cache;

  /// Cours entre deux dates (semaine affichée dans l'Agenda). Recharge depuis
  /// École Directe si la période sort de ce qui est déjà chargé.
  Future<List<EdLesson>> lessonsBetween(DateTime from, DateTime to) async {
    if (!configured) return const [];
    await load();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cacheFrom = today.subtract(Duration(days: today.weekday - 1));
    final cacheTo = today.add(const Duration(days: 21));
    if (!from.isBefore(cacheFrom) && !to.isAfter(cacheTo)) {
      return _cache.where((l) => l.end.isAfter(from) && l.start.isBefore(to)).toList();
    }
    final key = from.toIso8601String();
    if (_weeks[key] case final w?) return w;
    if (client.accountId == null) return const [];
    try {
      return _weeks[key] = await withSession(() => client.timetable(from, to));
    } catch (_) {
      return const [];
    }
  }

  final Map<String, List<EdLesson>> _weeks = {};
  List<EdGrade> grades = [];
  List<EdHomework> homework = [];
  List<EdMessage> messages = [];
  List<EdMessage> sentMessages = [];

  /// Pourquoi la messagerie n'a pas pu être lue (affiché dans l'onglet).
  String? messagesError;
  Future<List<EdLesson>>? _loading;
  String? lastError;

  @override
  String get id => 'ecoledirecte';
  @override
  String get name => 'École Directe';
  @override
  String get description => 'Emploi du temps, devoirs, notes et messagerie';
  @override
  IconData get icon => Icons.school_rounded;
  @override
  Color get color => const Color(0xFF0B6FB8);
  @override
  ApiAccess get access => ApiAccess.unofficial;

  bool get configured => store.getJson<String>('user') != null;

  /// Le module a besoin d'un [BuildContext] pour poser la question de
  /// sécurité ; on garde le dernier disponible.
  BuildContext? _ctx;

  bool _busy = false;
  DateTime? _homeworkAt;

  /// Charge (ou recharge) les données.
  ///
  /// Pour ne pas passer pour un robot aux yeux d'École Directe :
  /// * on **garde la session** (jeton) au lieu de se reconnecter à chaque
  ///   fois, même après un redémarrage de Mon Hub ;
  /// * une seule connexion à la fois, et pas plus d'une connexion
  ///   automatique toutes les 30 minutes ;
  /// * si École Directe refuse le mot de passe ou la réponse de sécurité,
  ///   Mon Hub **s'arrête** et attend que tu te reconnectes (les essais ratés
  ///   à répétition font bloquer le compte).
  ///
  /// [manual] : demandé par toi (bouton Actualiser, Réessayer…).
  Future<List<EdLesson>> load({bool force = false, bool manual = false}) {
    final running = _loading;
    if (running != null && (!force || _busy)) return running;
    return _loading = _run(manual: manual);
  }

  /// Message affiché quand Mon Hub s'est arrêté après un refus.
  String? get blocked => store.getJson<String>('blocked');

  Future<List<EdLesson>> _run({required bool manual}) async {
    _busy = true;
    lastError = null;
    try {
      final user = store.getJson<String>('user');
      final pass = await store.readSecret('password');
      if (user == null || pass == null) return _cache = [];
      if (blocked case final b?) {
        lastError = b;
        return _cache;
      }
      if (client.token == null) await _restoreSession();
      if (client.token == null) await _login(user, pass, manual: manual);
      try {
        await _fetch();
      } on EdSessionExpired {
        await _login(user, pass, manual: manual);
        await _fetch();
      }
      return _cache;
    } catch (e) {
      lastError = '$e';
      // Échec : la prochaine demande retentera (sans reconnexion trop tôt).
      _loading = null;
      return _cache;
    } finally {
      _busy = false;
    }
  }

  /// Reprend la session gardée (évite une connexion à chaque démarrage).
  Future<void> _restoreSession() async {
    final raw = await store.readSecret('session');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.tryParse('${j['at']}');
      // Session d'une ancienne version (sans la messagerie de la famille) :
      // on se reconnecte une fois pour l'avoir.
      if (!j.containsKey('family')) return;
      if (at == null || DateTime.now().difference(at) > const Duration(hours: 12)) return;
      client
        ..token = j['token'] as String?
        ..accountId = j['id'] as int?
        ..studentName = j['name'] as String?
        ..familyId = j['family'] as int?
        ..year = j['year'] as String?;
      if (client.accountId == null) client.token = null;
    } catch (_) {}
  }

  Future<void> _login(String user, String pass, {required bool manual}) async {
    final now = DateTime.now();
    final last = DateTime.tryParse(store.getJson<String>('lastLogin') ?? '');
    final pause = manual ? const Duration(minutes: 1) : const Duration(minutes: 30);
    if (last != null && now.difference(last) < pause && now.isAfter(last)) {
      final left = pause - now.difference(last);
      throw 'Connexion à École Directe en pause encore ${left.inMinutes + 1} min, '
          'pour ne pas être pris pour un robot.';
    }
    await store.setJson('lastLogin', now.toIso8601String());
    client.token = null;
    await store.writeSecret('session', null);
    final faRaw = await store.readSecret('fa');
    // Comme le site officiel : identifiant d'appareil vide.
    client.uuid = '';
    _weeks.clear();
    try {
      await client.login(
        user,
        pass,
        savedFa: faRaw == null
            ? null
            : (jsonDecode(faRaw) as List).map((e) => Map<String, String>.from(e as Map)).toList(),
        answerQuestion: _ask,
      );
    } on EdAuthError catch (e) {
      // Plus aucun essai automatique tant que tu ne t'es pas reconnecté.
      await store.setJson(
        'blocked',
        '$e. Mon Hub a arrêté d\'essayer pour protéger ton compte : '
            'reconnecte-toi (icône clé) avec le bon mot de passe.',
      );
      rethrow;
    }
    if (client.lastFa != null) await store.writeSecret('fa', jsonEncode(client.lastFa));
    await store.writeSecret(
      'session',
      jsonEncode({
        'token': client.token,
        'id': client.accountId,
        'name': client.studentName,
        'family': client.familyId,
        'year': client.year,
        'at': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// Récupère les données avec la session ouverte (requêtes espacées).
  Future<void> _fetch() async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    try {
      _cache = await client.timetable(
        from.subtract(Duration(days: from.weekday - 1)),
        from.add(const Duration(days: 21)),
      );
    } on EdSessionExpired {
      rethrow;
    } catch (e) {
      lastError = '$e';
    }
    try {
      grades = await client.grades();
    } on EdSessionExpired {
      rethrow;
    } catch (_) {}
    try {
      messages = await client.messages();
      messagesError = null;
    } on EdSessionExpired {
      rethrow;
    } catch (e) {
      messagesError = '$e';
    }
    // Le cahier de texte demande une requête par jour : pas plus d'une
    // fois toutes les 2 heures.
    final hw = _homeworkAt;
    if (hw == null || now.difference(hw) > const Duration(hours: 2)) {
      try {
        homework = await client.homework();
        _homeworkAt = now;
      } on EdSessionExpired {
        rethrow;
      } catch (_) {}
    }
    badge.value =
        messages.where((m) => !m.read).length +
        homework.where((h) => !h.done && h.due.difference(now).inDays <= 1).length;
    // La session reste valable : on note qu'elle vient de servir.
    await store.writeSecret(
      'session',
      jsonEncode({
        'token': client.token,
        'id': client.accountId,
        'name': client.studentName,
        'family': client.familyId,
        'year': client.year,
        'at': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// Une action ponctuelle (lire, répondre…) avec reconnexion si la session
  /// a expiré.
  Future<T> withSession<T>(Future<T> Function() f) async {
    if (blocked case final b?) throw b;
    if (client.token == null) await load(force: true, manual: true);
    try {
      return await f();
    } on EdSessionExpired {
      final user = store.getJson<String>('user');
      final pass = await store.readSecret('password');
      if (user == null || pass == null) rethrow;
      await _login(user, pass, manual: true);
      return f();
    }
  }

  DateTime? _nextPoll;

  @override
  Future<List<HubNotification>> poll() async {
    if (!configured || blocked != null) return _lastItems;
    final now0 = DateTime.now();
    // Pas de vérification la nuit (22 h – 6 h 30) : personne ne consulte
    // École Directe toutes les demi-heures en pleine nuit.
    final night = now0.hour >= 22 || now0.hour < 6 || (now0.hour == 6 && now0.minute < 30);
    if (_nextPoll != null && (night || now0.isBefore(_nextPoll!))) return _lastItems;
    // Toutes les 30 à 45 minutes environ (jamais pile au même rythme).
    _nextPoll = now0.add(Duration(minutes: 30 + math.Random().nextInt(16)));
    await load(force: true);
    store.changed();
    final now = DateTime.now();
    // Le bilan des notes de la semaine, le vendredi à partir de 17 h (et le
    // week-end), une fois par semaine.
    final weekend = now.weekday >= DateTime.saturday || (now.weekday == DateTime.friday && now.hour >= 17);
    final report = weekend ? GradeMath.weekReport(grades, now) : null;
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    return _lastItems = [
      if (report != null)
        HubNotification(
          id: 'bilan-notes:${monday.toIso8601String().substring(0, 10)}',
          title: '📊 Bilan de tes notes de la semaine',
          body: report,
        ),
      for (final g in grades.take(30))
        HubNotification(
          id: 'note:${g.id}',
          title: '📝 Nouvelle note en ${g.subject}',
          body: '${g.value}/${g.outOf}${g.title.isEmpty ? '' : ' · ${g.title}'}',
        ),
      for (final m in messages)
        if (!m.read)
          HubNotification(
            id: 'msg:${m.id}',
            title: '📨 École Directe · ${m.from}',
            body: m.subject,
          ),
      for (final h in homework)
        HubNotification(
          id: 'devoir:${h.id}',
          title: '${h.isTest ? '⚠️ Contrôle' : '📚 Devoir'} en ${h.subject}',
          body: 'Pour ${dayLabel(h.due).toLowerCase()}',
        ),
      for (final l in _cache)
        if (l.cancelled && l.end.isAfter(now))
          HubNotification(
            id: 'annule:${l.subject}@${l.start.toIso8601String()}',
            title: '🎉 Cours annulé : ${l.subject}',
            body: '${dayLabel(l.start)} à ${hhmm(l.start)}',
          ),
    ];
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'ecole_notes',
      description: 'Dernières notes École Directe.',
      run: (_) async {
        await load();
        return [
          for (final g in grades.take(40))
            {
              'matiere': g.subject,
              'note': '${g.value}/${g.outOf}',
              if (g.coef != 1) 'coef': g.coef,
              'devoir': g.title,
              'date': g.date,
            },
        ];
      },
    ),
    HubTool(
      name: 'ecole_moyenne',
      description:
          'Moyennes du trimestre (avec les coefficients) et la note qu\'il faut au prochain devoir pour atteindre un '
          'objectif (« il me faut combien en maths pour avoir 14 ? »).',
      params: {
        'matiere': ('string', 'Matière (vide : toutes les moyennes et la générale)'),
        'objectif': ('number', 'Moyenne visée (facultatif)'),
        'coef': ('number', 'Coefficient du prochain devoir (défaut 1)'),
        'sur': ('number', 'Le prochain devoir est noté sur… (défaut 20)'),
      },
      run: (a) async {
        await load();
        final period = GradeMath.currentPeriod(grades);
        final q = '${a['matiere'] ?? ''}'.trim();
        if (q.isEmpty) {
          final by = GradeMath.bySubject(period);
          final g = GradeMath.general(period);
          return {
            'moyennes': {for (final e in by.entries) e.key: GradeMath.fmt(e.value)},
            if (g != null) 'generale': GradeMath.fmt(g),
          };
        }
        final subject = GradeMath.matchSubject(q, {for (final g in period) g.subject});
        if (subject == null) return {'ok': false, 'message': 'Pas de note en « $q » ce trimestre.'};
        final mine = [for (final g in period) if (g.subject == subject) g];
        final avg = GradeMath.average(mine);
        final target = (a['objectif'] as num?)?.toDouble();
        final coef = (a['coef'] as num?)?.toDouble() ?? 1;
        final outOf = (a['sur'] as num?)?.toDouble() ?? 20;
        return {
          'matiere': subject,
          if (avg != null) 'moyenne': GradeMath.fmt(avg),
          'nombre_de_notes': mine.length,
          if (target != null) ...{
            'note_necessaire': switch (GradeMath.needed(mine, target, coef: coef, outOf: outOf)) {
              final n? => GradeMath.fmt(n),
              null => null,
            },
            'resume': GradeMath.sayNeeded(_pretty(subject), mine, target, coef: coef, outOf: outOf),
          },
        };
      },
    ),
    HubTool(
      name: 'ecole_bilan_notes',
      description: 'Bilan des notes de la semaine : nouvelles notes et comment les moyennes ont bougé.',
      params: {'jours': ('integer', 'Nombre de jours (défaut 7)')},
      run: (a) async {
        await load();
        final r = GradeMath.weekReport(grades, DateTime.now(), days: (a['jours'] as num?)?.toInt() ?? 7);
        return r ?? 'Pas de nouvelle note sur cette période.';
      },
    ),
    HubTool(
      name: 'ecole_devoirs',
      description: 'Devoirs à faire (cahier de texte École Directe).',
      run: (_) async {
        await load();
        return [
          for (final h in homework)
            {
              'pour_le': h.due,
              'matiere': h.subject,
              'contenu': h.content,
              'fait': h.done,
              if (h.isTest) 'controle': true,
              if (h.files.isNotEmpty) 'fichiers_joints': [for (final f in h.files) f.name],
              if (h.lesson.trim().isNotEmpty) 'fait_en_classe': h.lesson,
            },
        ];
      },
    ),
    HubTool(
      name: 'ecole_fichier_lire',
      description:
          'Lit un fichier joint à un devoir École Directe (PDF, photo, Word) et en donne l\'essentiel : consignes, '
          'à rendre, contenu.',
      params: {
        'matiere': ('string', 'Matière du devoir'),
        'fichier': ('string', 'Nom (ou début du nom) du fichier, facultatif'),
      },
      required: ['matiere'],
      run: (a) async {
        await load();
        String low(Object? v) => '${v ?? ''}'.toLowerCase().trim();
        final subject = low(a['matiere']);
        final wanted = low(a['fichier']);
        final candidates = [
          for (final h in homework)
            if (h.files.isNotEmpty && (subject.isEmpty || h.subject.toLowerCase().contains(subject)))
              for (final f in h.files) f,
        ];
        if (candidates.isEmpty) throw 'Aucun fichier joint aux devoirs de « ${a['matiere']} »';
        final f = candidates.where((f) => wanted.isNotEmpty && f.name.toLowerCase().contains(wanted)).firstOrNull ??
            candidates.first;
        final bytes = await withSession(() => client.attachment(f));
        final summary = await FileViewer.summarize(f.name, Uint8List.fromList(bytes));
        return {'fichier': f.name, 'essentiel': summary, if (candidates.length > 1) 'autres_fichiers': [
          for (final x in candidates) if (x != f) x.name,
        ]};
      },
    ),
    HubTool(
      name: 'ecole_messages',
      description: 'Messages reçus sur la messagerie École Directe.',
      run: (_) async {
        await load();
        return [
          for (final m in messages.take(20))
            {'id': m.id, 'de': m.from, 'objet': m.subject, 'date': m.date, 'lu': m.read},
        ];
      },
    ),
    HubTool(
      name: 'ecole_message_lire',
      description: 'Contenu d\'un message École Directe.',
      params: {'id': ('integer', 'id donné par ecole_messages')},
      required: ['id'],
      run: (a) => withSession(() => client.messageContent((a['id'] as num).toInt())),
    ),
    HubTool(
      name: 'ecole_cloud',
      description:
          'Tout mon cloud École Directe (tous les fichiers de tous les dossiers) et les documents '
          'de l\'établissement (bulletins, vie scolaire…). Avec dossier : seulement ce dossier.',
      params: {'dossier': ('string', 'id du dossier (facultatif)')},
      run: (a) async {
        final id = '${a['dossier'] ?? ''}'.trim();
        if (id.isEmpty) {
          // Tout le cloud d'un coup, et les documents de l'établissement.
          final all = await withSession(() => client.cloudAll());
          List<EdDocument> docs = const [];
          try {
            docs = await withSession(client.documents);
          } catch (_) {}
          return {
            'fichiers_du_cloud': [
              for (final f in all.allFiles.take(200))
                {'id': f.id, 'nom': f.name, if (f.size > 0) 'taille': fileSize(f.size), if (f.date != null) 'date': f.date},
            ],
            'documents': [
              for (final d in docs.take(60)) {'id': d.id, 'nom': d.title, 'type': d.category, if (d.date != null) 'date': d.date},
            ],
          };
        }
        final n = await withSession(() => client.cloud(folderId: id));
        return {
          'dossier': n.name,
          'contenu': [
            for (final c in n.children)
              {
                'id': c.id,
                'nom': c.name,
                'type': c.folder ? 'dossier' : 'fichier',
                if (!c.folder) 'taille': fileSize(c.size),
                if (c.date != null) 'date': c.date,
              },
          ],
        };
      },
    ),
    HubTool(
      name: 'ecole_espaces_travail',
      description: 'Mes espaces de travail École Directe (classes, clubs, projets) : titre, description, '
          'membre ou non, et les fichiers de leur cloud.',
      run: (_) async {
        final list = await withSession(client.workspaces);
        final out = <Map<String, Object?>>[];
        for (final w in list.take(15)) {
          List<String> files = const [];
          if (w.member && w.hasCloud) {
            try {
              final c = await withSession(() => client.cloudAll(owner: 'W/${w.id}', maxFolders: 10));
              files = [for (final f in c.allFiles.take(40)) '${f.name} (id ${f.id})'];
            } catch (_) {}
          }
          out.add({
            'titre': w.title,
            if (w.description.isNotEmpty) 'description': w.description,
            'membre': w.member,
            if (w.members > 0) 'membres': w.members,
            if (files.isNotEmpty) 'fichiers': files,
          });
        }
        return out;
      },
    ),
    HubTool(
      name: 'ecole_cloud_telecharger',
      description:
          'Télécharge un fichier de mon cloud École Directe dans Téléchargements\\École Directe '
          '(id donné par ecole_cloud) et renvoie où il est.',
      params: {
        'id': ('string', 'id du fichier'),
        'nom': ('string', 'nom du fichier'),
      },
      required: ['id'],
      run: (a) async {
        final id = '${a['id']}';
        final name = '${a['nom'] ?? ''}'.trim().isEmpty
            ? id.split(RegExp(r'[\\/]')).last
            : '${a['nom']}'.trim();
        final f = EdCloudNode(id: id, name: name, folder: false);
        final bytes = await withSession(() => client.cloudFile(f));
        return 'Enregistré : ${await saveDownload(name, bytes)}';
      },
    ),
  ];

  /// Enregistre un fichier dans Téléchargements\École Directe (sans écraser).
  static Future<String> saveDownload(String name, List<int> bytes) async {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    final dir = Directory([home, 'Downloads', 'École Directe'].join(sep));
    await dir.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    var f = File('${dir.path}$sep$safe');
    for (var i = 2; await f.exists(); i++) {
      f = File('${dir.path}$sep$base ($i)$ext');
    }
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  List<HubNotification> _lastItems = const [];

  Future<String?>? _pendingQuestion;

  /// Question de sécurité (double authentification). Affichée par le
  /// navigateur principal : elle marche même si la connexion a été lancée en
  /// arrière-plan (vérification des notifications au démarrage…).
  Future<String?> _ask(String question, List<String> choices) {
    return _pendingQuestion ??= () async {
      try {
        BuildContext? ctx = _ctx;
        if (ctx == null || !ctx.mounted) ctx = await hubDialogContext();
        if (ctx == null || !ctx.mounted) return null;
        return await showDialog<String>(
          context: ctx,
          barrierDismissible: false,
          useRootNavigator: true,
          builder: (c) => AlertDialog(
            icon: const Icon(Icons.verified_user_rounded),
            title: const Text('Question de sécurité École Directe'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(question, style: Theme.of(c).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    for (final ch in choices)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(c, ch),
                          child: Text(ch, textAlign: TextAlign.center),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Plus tard')),
            ],
          ),
        );
      } finally {
        _pendingQuestion = null;
      }
    }();
  }

  /// Relance la connexion (après une question restée sans réponse…).
  Future<void> retry() async {
    await load(force: true, manual: true);
    store.changed();
  }

  Future<void> _configure(BuildContext context) async {
    final r = await askFields(
      context,
      title: 'Connexion École Directe',
      labels: ['Identifiant', 'Mot de passe'],
      initial: [store.getJson<String>('user') ?? '', ''],
      obscure: {1},
    );
    if (r == null || r[0].isEmpty || r[1].isEmpty) return;
    await store.writeSecret('password', r[1]);
    await store.writeSecret('fa', null);
    await store.writeSecret('session', null);
    await store.setJson('user', r[0]);
    // Nouveaux identifiants : on a le droit de réessayer tout de suite.
    await store.setJson('blocked', null);
    await store.setJson('lastLogin', null);
    client.token = null;
    final messenger = context.mounted ? ScaffoldMessenger.of(context) : null;
    messenger?.showSnackBar(
      const SnackBar(content: Text('Connexion à École Directe…'), duration: Duration(seconds: 20)),
    );
    await load(force: true, manual: true);
    store.changed();
    // Toujours un retour clair : connecté, ou l'erreur exacte.
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            lastError == null
                ? '✅ Connecté à École Directe${client.studentName == null ? '' : ' : ${client.studentName}'}'
                : '❌ $lastError',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  @override
  Widget buildSummary(BuildContext context) {
    _ctx = context;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!configured) {
          return const EmptyHint('Connecte ton compte École Directe', icon: Icons.login);
        }
        return FutureBuilder(
          future: load(),
          initialData: _cache,
          builder: (context, snap) {
            if (lastError != null && _cache.isEmpty) {
              return EmptyHint(lastError!, action: ('Réessayer', retry));
            }
            final now = DateTime.now();
            final next = (snap.data ?? [])
                .where((l) => l.end.isAfter(now) && !l.cancelled)
                .take(7)
                .toList();
            if (snap.connectionState == ConnectionState.waiting && next.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (next.isEmpty) return const EmptyHint('Pas de cours à venir');
            return NextUpSummary(
              items: [
                for (final l in next)
                  NextItem(
                    title: l.subject,
                    start: l.start,
                    end: l.end,
                    color: lessonColor(l.color) ?? color,
                    place: [l.room, l.teacher].where((x) => x.isNotEmpty).join(' · '),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget buildPage(BuildContext context) {
    _ctx = context;
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => load(force: true, manual: true).then((_) => store.changed()),
            ),
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Compte',
                icon: const Icon(Icons.manage_accounts_rounded),
                onPressed: () => _configure(context),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Emploi du temps'),
              Tab(text: 'Devoirs'),
              Tab(text: 'Notes'),
              Tab(text: 'Messages'),
              Tab(text: 'Cloud'),
              Tab(text: 'Espaces de travail'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            if (!configured) {
              return EmptyHint(
                'Connecte ton compte École Directe',
                icon: icon,
                action: ('Se connecter', () => _configure(context)),
              );
            }
            return FutureBuilder(
              future: load(),
              initialData: _cache,
              builder: (context, snap) {
                final waiting = snap.connectionState == ConnectionState.waiting;
                Widget wrap(List<Widget> children, String empty) => ListView(
                  children: [
                    if (lastError != null) ErrorBanner(lastError!),
                    if (waiting && children.isEmpty)
                      const Padding(padding: EdgeInsets.all(32), child: LoadingHint()),
                    ...children,
                    if (!waiting && children.isEmpty)
                      Padding(padding: const EdgeInsets.all(32), child: EmptyHint(empty)),
                  ],
                );
                return TabBarView(
                  children: [
                    wrap(_lessonTiles(context), 'Aucun cours cette semaine'),
                    wrap(_homeworkTiles(context), 'Aucun devoir à venir 🎉'),
                    wrap(_gradeTiles(context), 'Aucune note pour l\'instant'),
                    _MessagesTab(module: this),
                    _CloudTab(module: this),
                    _WorkspacesTab(module: this),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _dayHeader(BuildContext context, String d) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      d,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  List<Widget> _lessonTiles(BuildContext context) {
    final out = <Widget>[];
    String? lastDay;
    for (final l in _cache) {
      final d = dayLabel(l.start);
      if (d != lastDay) {
        out.add(_dayHeader(context, d));
        lastDay = d;
      }
      out.add(
        ListTile(
          leading: SizedBox(
            width: 52,
            child: Text(
              '${hhmm(l.start)}\n${hhmm(l.end)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(
            l.subject,
            style: l.cancelled ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
          ),
          subtitle: Text(
            [
              if (l.cancelled) 'ANNULÉ',
              if (l.room.isNotEmpty) l.room,
              if (l.teacher.isNotEmpty) l.teacher,
            ].join(' · '),
          ),
        ),
      );
    }
    return out;
  }

  List<Widget> _homeworkTiles(BuildContext context) {
    final out = <Widget>[];
    String? lastDay;
    for (final h in homework) {
      final d = 'Pour ${dayLabel(h.due).toLowerCase()}';
      if (d != lastDay) {
        out.add(_dayHeader(context, d));
        lastDay = d;
      }
      out.add(
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ExpansionTile(
            shape: const Border(),
            leading: Icon(
              h.done
                  ? Icons.check_circle_rounded
                  : (h.isTest ? Icons.warning_rounded : Icons.circle_outlined),
              color: h.done ? Colors.green : (h.isTest ? Colors.orange : color),
            ),
            title: Text(h.subject, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              [
                h.content.split('\n').first,
                if (h.files.isNotEmpty) '📎 ${h.files.length} fichier${h.files.length > 1 ? 's' : ''}',
              ].where((x) => x.trim().isNotEmpty).join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // Avec des fichiers joints, le devoir s'ouvre déjà déplié.
            initiallyExpanded: h.files.isNotEmpty && !h.done,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(h.content),
              if (h.files.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in h.files)
                      AttachmentChip(name: f.name, load: () => withSession(() => client.attachment(f))),
                  ],
                ),
              ],
              if (h.lesson.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('En classe', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                SelectableText(h.lesson, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      );
    }
    return out;
  }

  List<Widget> _gradeTiles(BuildContext context) => [
    for (final g in grades)
      ListTile(
        leading: HubAvatar(label: g.subject, color: color, size: 38),
        title: Text(g.subject),
        subtitle: Text(
          [if (g.title.isNotEmpty) g.title, if (g.date != null) dayLabel(g.date!)].join(' · '),
        ),
        trailing: Text(
          '${g.value}/${g.outOf}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
      ),
  ];
}

/// Messagerie École Directe : reçus / envoyés, lecture, pièces jointes,
/// réponse.
class _MessagesTab extends StatefulWidget {
  const _MessagesTab({required this.module});
  final EcoleDirecteModule module;

  @override
  State<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<_MessagesTab> {
  String folder = 'received';
  Future<List<EdMessage>>? _sent;

  EcoleDirecteModule get m => widget.module;

  Future<void> _refresh() async {
    if (folder == 'sent') {
      setState(() => _sent = m.withSession(() => m.client.messages(folder: 'sent')));
      await _sent;
    } else {
      await m.load(force: true, manual: true);
      m.store.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = folder == 'sent'
        ? FutureBuilder(
            future: _sent ??= m.withSession(() => m.client.messages(folder: 'sent')),
            builder: (context, snap) => _list(
              context,
              snap.data ?? const [],
              error: snap.hasError ? '${snap.error}' : null,
              waiting: snap.connectionState == ConnectionState.waiting,
            ),
          )
        : _list(context, m.messages, error: m.messagesError ?? m.lastError);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'received',
                    icon: Icon(Icons.inbox_rounded),
                    label: Text('Reçus'),
                  ),
                  ButtonSegment(
                    value: 'sent',
                    icon: Icon(Icons.send_rounded),
                    label: Text('Envoyés'),
                  ),
                ],
                selected: {folder},
                onSelectionChanged: (v) => setState(() => folder = v.first),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Actualiser la messagerie',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    List<EdMessage> msgs, {
    String? error,
    bool waiting = false,
  }) => RefreshIndicator(
    onRefresh: _refresh,
    child: ListView(
      children: [
        if (error != null) ErrorBanner(error),
        if (waiting) const Padding(padding: EdgeInsets.all(32), child: LoadingHint()),
        if (!waiting && msgs.isEmpty && error == null)
          Padding(
            padding: const EdgeInsets.all(32),
            child: EmptyHint(folder == 'sent' ? 'Aucun message envoyé' : 'Aucun message'),
          ),
        for (final msg in msgs)
          ListTile(
            leading: HubAvatar(label: msg.from, color: msg.read ? Colors.blueGrey : m.color),
            title: Text(
              msg.from,
              style: TextStyle(fontWeight: msg.read ? FontWeight.w500 : FontWeight.w800),
            ),
            subtitle: Text(msg.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (msg.date != null)
                  Text(timeAgo(msg.date!), style: Theme.of(context).textTheme.labelSmall),
                if (msg.hasFiles) const Icon(Icons.attach_file_rounded, size: 16),
              ],
            ),
            onTap: () async {
              msg.read = true;
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => _MessagePage(module: m, message: msg)),
              );
              m.store.changed();
              if (mounted) setState(() {});
            },
          ),
      ],
    ),
  );
}

class _MessagePage extends StatefulWidget {
  const _MessagePage({required this.module, required this.message});
  final EcoleDirecteModule module;
  final EdMessage message;

  @override
  State<_MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<_MessagePage> {
  late Future<EdMessageContent> content = widget.module.withSession(
    () => widget.module.client.message(widget.message.id, sent: widget.message.sent),
  );

  Future<void> _download(EdAttachment f) async {
    try {
      final bytes = await widget.module.withSession(() => widget.module.client.attachment(f));
      final name = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final loc = await getSaveLocation(suggestedName: name);
      if (loc == null) return;
      await File(loc.path).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Enregistré : ${loc.path}'),
            action: SnackBarAction(
              label: 'Ouvrir',
              onPressed: () => launchUrl(Uri.file(loc.path)),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final m = widget.module;
    return Scaffold(
      appBar: AppBar(title: Text(msg.from)),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  msg.subject,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (msg.date != null)
                  Text(
                    '${dayLabel(msg.date!)} à ${hhmm(msg.date!)}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                const Divider(height: 28),
                FutureBuilder(
                  future: content,
                  builder: (c, snap) {
                    if (snap.hasError) {
                      return Column(
                        children: [
                          ErrorBanner('${snap.error}'),
                          TextButton.icon(
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Réessayer'),
                            onPressed: () => setState(() {
                              content = m.withSession(
                                () => m.client.message(msg.id, sent: msg.sent),
                              );
                            }),
                          ),
                        ],
                      );
                    }
                    if (!snap.hasData) return const LoadingHint();
                    final d = snap.data!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          d.text.isEmpty ? '(message vide)' : d.text,
                          style: const TextStyle(height: 1.5),
                        ),
                        if (d.files.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text('Pièces jointes', style: Theme.of(context).textTheme.titleSmall),
                          for (final f in d.files)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(FileViewer.iconFor(f.name)),
                              title: Text(f.name),
                              subtitle: const Text('Cliquer pour voir'),
                              trailing: IconButton(
                                tooltip: 'Enregistrer sous…',
                                icon: const Icon(Icons.download_rounded),
                                onPressed: () => _download(f),
                              ),
                              onTap: () => FileViewer.open(
                                context,
                                f.name,
                                () => m.withSession(() => m.client.attachment(f)),
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          if (!msg.sent)
            Builder(
              builder: (c) => ChatComposer(
                color: m.color,
                hint: 'Répondre à ${msg.from}',
                onSend: (text) async {
                  await m.withSession(() => m.client.reply(msg, text));
                  if (c.mounted) {
                    ScaffoldMessenger.of(c)
                        .showSnackBar(const SnackBar(content: Text('Réponse envoyée ✉️')));
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}


/// Taille lisible (« 1,2 Mo »).
String fileSize(int bytes) {
  if (bytes <= 0) return '';
  const units = ['o', 'Ko', 'Mo', 'Go'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${i == 0 ? v.toInt() : v.toStringAsFixed(1).replaceAll('.', ',')} ${units[i]}';
}

/// Le cloud École Directe en entier : ton cloud (tous les dossiers ouverts
/// d'un coup), les clouds des espaces de travail et les documents de
/// l'établissement (bulletins, vie scolaire…). Recherche dans tout.
class _CloudTab extends StatefulWidget {
  const _CloudTab({required this.module});
  final EcoleDirecteModule module;

  @override
  State<_CloudTab> createState() => _CloudTabState();
}

class _CloudTabState extends State<_CloudTab> with AutomaticKeepAliveClientMixin {
  late Future<EdCloudNode> _mine;
  late Future<List<EdWorkspace>> _spaces;
  late Future<List<EdDocument>> _docs;
  final _spaceClouds = <String, Future<EdCloudNode>>{};
  final search = TextEditingController();
  String? _downloading;

  EcoleDirecteModule get m => widget.module;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _spaceClouds.clear();
    _mine = m.withSession(() => m.client.cloudAll());
    // Les requêtes se suivent (jamais en rafale) : le client les espace.
    _spaces = _mine.then((_) => m.withSession(m.client.workspaces), onError: (_) => m.withSession(m.client.workspaces));
    _docs = _spaces.then((_) => m.withSession(m.client.documents), onError: (_) => m.withSession(m.client.documents));
  }

  Future<void> _save(String id, String name, Future<List<int>> Function() fetch, {required bool open}) async {
    setState(() => _downloading = id);
    try {
      final bytes = await m.withSession(fetch);
      String path;
      if (open) {
        path = await EcoleDirecteModule.saveDownload(name, bytes);
        await launchUrl(Uri.file(path));
      } else {
        final loc = await getSaveLocation(suggestedName: name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
        if (loc == null) return;
        await File(loc.path).writeAsBytes(bytes, flush: true);
        path = loc.path;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Enregistré : $path'),
              action: SnackBarAction(label: 'Ouvrir', onPressed: () => launchUrl(Uri.file(path))),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Widget _busyOr(String id, Widget w) => _downloading == id
      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
      : w;

  Widget _fileTile(EdCloudNode f, {double indent = 0, bool showPath = false}) {
    final text = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
      leading: Icon(_fileIcon(f.name)),
      title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (showPath) _folderOf(f.id),
          if (f.size > 0) fileSize(f.size),
          if (f.date != null) dayLabel(f.date!),
        ].where((x) => x.isNotEmpty).join(' · '),
        style: text.labelSmall,
      ),
      trailing: _busyOr(
        f.id,
        IconButton(
          tooltip: 'Enregistrer sous…',
          icon: const Icon(Icons.download_rounded),
          onPressed: () => _save(f.id, f.name, () => m.client.cloudFile(f), open: false),
        ),
      ),
      onTap: () => FileViewer.open(context, f.name, () => m.withSession(() => m.client.cloudFile(f))),
    );
  }

  static String _folderOf(String id) {
    final parts = id.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    return parts.length <= 3 ? '' : parts.sublist(2, parts.length - 1).join(' › ');
  }

  /// Un dossier et tout son contenu (dépliable).
  List<Widget> _tree(EdCloudNode n, double indent) => [
    for (final c in n.children)
      if (c.folder)
        ExpansionTile(
          key: PageStorageKey(c.id),
          tilePadding: EdgeInsets.only(left: 16 + indent, right: 16),
          leading: Icon(Icons.folder_rounded, color: m.color),
          title: Text(c.name),
          subtitle: Text(
            '${c.allFiles.length} fichier${c.allFiles.length > 1 ? 's' : ''}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          children: c.children.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.only(left: 32 + indent, bottom: 8),
                    child: const Align(alignment: Alignment.centerLeft, child: Text('Dossier vide')),
                  ),
                ]
              : _tree(c, indent + 16),
        )
      else
        _fileTile(c, indent: indent),
  ];

  Widget _cloudBlock(Future<EdCloudNode> future, String query) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      if (snap.hasError) return ErrorBanner('${snap.error}');
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('J\'ouvre tous les dossiers…'),
            ],
          ),
        );
      }
      final root = snap.data!;
      if (query.isNotEmpty) {
        final hits = root.allFiles.where((f) => f.name.toLowerCase().contains(query)).toList();
        if (hits.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Aucun fichier ne correspond.'));
        return Column(children: [for (final f in hits) _fileTile(f, showPath: true)]);
      }
      if (root.children.isEmpty) {
        return const Padding(padding: EdgeInsets.all(16), child: Text('Rien ici pour l\'instant.'));
      }
      return Column(children: _tree(root, 0));
    },
  );

  Widget _head(String title, IconData icon, {String? sub}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Row(
      children: [
        Icon(icon, color: m.color),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (sub != null) ...[
          const SizedBox(width: 8),
          Text(sub, style: Theme.of(context).textTheme.labelSmall),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: () async {
        setState(_reload);
        await _mine.then((_) {}, onError: (_) {});
      },
      child: ListenableBuilder(
        listenable: search,
        builder: (context, _) {
          final q = search.text.trim().toLowerCase();
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: TextField(
                  controller: search,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Chercher un fichier dans tout le cloud et les documents',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              _head('Mon cloud', Icons.cloud_rounded),
              _cloudBlock(_mine, q),
              FutureBuilder(
                future: _spaces,
                builder: (context, snap) {
                  final spaces = [for (final w in snap.data ?? const <EdWorkspace>[]) if (w.hasCloud && w.member) w];
                  if (spaces.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _head('Espaces de travail', Icons.groups_rounded),
                      for (final w in spaces)
                        ExpansionTile(
                          key: PageStorageKey('w${w.id}'),
                          leading: Icon(Icons.folder_shared_rounded, color: m.color),
                          title: Text(w.title),
                          initiallyExpanded: q.isNotEmpty,
                          onExpansionChanged: (open) {
                            if (open) {
                              setState(() {
                                _spaceClouds[w.id] ??= m.withSession(() => m.client.cloudAll(owner: 'W/${w.id}'));
                              });
                            }
                          },
                          children: [
                            if (_spaceClouds[w.id] != null) _cloudBlock(_spaceClouds[w.id]!, q),
                          ],
                        ),
                    ],
                  );
                },
              ),
              _head('Documents de l\'établissement', Icons.description_rounded),
              FutureBuilder(
                future: _docs,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorBanner('${snap.error}');
                  if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: LoadingHint());
                  final docs = [
                    for (final d in snap.data!)
                      if (q.isEmpty || d.title.toLowerCase().contains(q) || d.category.toLowerCase().contains(q)) d,
                  ];
                  if (docs.isEmpty) {
                    return const Padding(padding: EdgeInsets.all(16), child: Text('Aucun document.'));
                  }
                  final byCat = <String, List<EdDocument>>{};
                  for (final d in docs) {
                    (byCat[d.category] ??= []).add(d);
                  }
                  return Column(
                    children: [
                      for (final e in byCat.entries)
                        ExpansionTile(
                          key: PageStorageKey('d${e.key}'),
                          initiallyExpanded: q.isNotEmpty || byCat.length == 1,
                          leading: Icon(Icons.folder_special_rounded, color: m.color),
                          title: Text(e.key),
                          subtitle: Text('${e.value.length} document${e.value.length > 1 ? 's' : ''}'),
                          children: [
                            for (final d in e.value)
                              ListTile(
                                contentPadding: const EdgeInsets.only(left: 32, right: 8),
                                leading: const Icon(Icons.picture_as_pdf_rounded),
                                title: Text(d.title),
                                subtitle: d.date == null ? null : Text(dayLabel(d.date!)),
                                trailing: _busyOr(
                                  'doc${d.id}',
                                  IconButton(
                                    tooltip: 'Enregistrer sous…',
                                    icon: const Icon(Icons.download_rounded),
                                    onPressed: () => _save(
                                      'doc${d.id}',
                                      '${d.title}.pdf',
                                      () => m.client.documentFile(d),
                                      open: false,
                                    ),
                                  ),
                                ),
                                onTap: () => FileViewer.open(
                                  context,
                                  '${d.title}.pdf',
                                  () => m.withSession(() => m.client.documentFile(d)),
                                ),
                              ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_rounded,
      'doc' || 'docx' || 'odt' || 'txt' || 'rtf' => Icons.description_rounded,
      'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Icons.image_rounded,
      'mp3' || 'wav' || 'm4a' || 'ogg' => Icons.audio_file_rounded,
      'mp4' || 'mov' || 'avi' || 'mkv' => Icons.video_file_rounded,
      'zip' || 'rar' || '7z' => Icons.folder_zip_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }
}


/// Les espaces de travail : ceux dont tu es membre en premier, avec leur
/// description et leur cloud.
class _WorkspacesTab extends StatefulWidget {
  const _WorkspacesTab({required this.module});
  final EcoleDirecteModule module;

  @override
  State<_WorkspacesTab> createState() => _WorkspacesTabState();
}

class _WorkspacesTabState extends State<_WorkspacesTab> with AutomaticKeepAliveClientMixin {
  late Future<List<EdWorkspace>> future = widget.module.withSession(widget.module.client.workspaces);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final m = widget.module;
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => future = m.withSession(m.client.workspaces));
        await future.then((_) {}, onError: (_) {});
      },
      child: FutureBuilder(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return ListView(children: [ErrorBanner('${snap.error}')]);
          if (!snap.hasData) return const LoadingHint();
          final list = [...snap.data!]..sort((a, b) => a.member == b.member ? a.title.compareTo(b.title) : (a.member ? -1 : 1));
          if (list.isEmpty) {
            return ListView(
              children: const [
                Padding(padding: EdgeInsets.all(32), child: EmptyHint('Aucun espace de travail', icon: Icons.groups_rounded)),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final w in list)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: m.color.withValues(alpha: w.member ? 0.9 : 0.25),
                      child: Icon(Icons.groups_rounded, color: w.member ? Colors.white : m.color),
                    ),
                    title: Text(w.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      [
                        if (w.description.isNotEmpty) w.description.split('\n').first,
                        [
                          w.member ? 'Membre' : 'Pas encore membre',
                          if (w.members > 0) '${w.members} membres',
                          if (w.createdBy.isNotEmpty) 'par ${w.createdBy}',
                        ].join(' · '),
                      ].join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: w.description.isNotEmpty,
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(builder: (_) => _WorkspacePage(module: m, space: w)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _WorkspacePage extends StatefulWidget {
  const _WorkspacePage({required this.module, required this.space});
  final EcoleDirecteModule module;
  final EdWorkspace space;

  @override
  State<_WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<_WorkspacePage> {
  EcoleDirecteModule get m => widget.module;
  EdWorkspace get w => widget.space;
  late Future<EdCloudNode>? cloud = w.member && w.hasCloud ? m.withSession(() => m.client.cloudAll(owner: 'W/${w.id}')) : null;
  bool joined = false;
  String? busy;

  Future<void> _open(EdCloudNode f, {required bool saveAs}) async {
    setState(() => busy = f.id);
    try {
      final bytes = await m.withSession(() => m.client.cloudFile(f));
      if (saveAs) {
        final loc = await getSaveLocation(suggestedName: f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'));
        if (loc == null) return;
        await File(loc.path).writeAsBytes(bytes, flush: true);
      } else {
        await launchUrl(Uri.file(await EcoleDirecteModule.saveDownload(f.name, bytes)));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  List<Widget> _tree(EdCloudNode n, double indent) => [
    for (final c in n.children)
      if (c.folder)
        ExpansionTile(
          tilePadding: EdgeInsets.only(left: 16 + indent, right: 16),
          leading: Icon(Icons.folder_rounded, color: m.color),
          title: Text(c.name),
          children: _tree(c, indent + 16),
        )
      else
        ListTile(
          contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
          leading: const Icon(Icons.insert_drive_file_rounded),
          title: Text(c.name),
          subtitle: Text([if (c.size > 0) fileSize(c.size), if (c.date != null) dayLabel(c.date!)].join(' · ')),
          trailing: busy == c.id
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.download_rounded),
                  tooltip: 'Enregistrer sous…',
                  onPressed: () => _open(c, saveAs: true),
                ),
          onTap: () => FileViewer.open(context, c.name, () => m.withSession(() => m.client.cloudFile(c))),
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(w.title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(w.title, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  [
                    w.member || joined ? 'Tu es membre' : 'Tu n\'es pas encore membre',
                    if (w.members > 0) '${w.members} membres',
                    if (w.createdBy.isNotEmpty) 'créé par ${w.createdBy}',
                  ].join(' · '),
                  style: text.labelMedium,
                ),
                if (w.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(w.description, style: const TextStyle(height: 1.45)),
                ],
                if (!w.member && !joined) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.group_add_rounded),
                    label: const Text('Rejoindre cet espace'),
                    onPressed: () async {
                      try {
                        await m.withSession(() => m.client.joinWorkspace(w));
                        setState(() {
                          joined = true;
                          if (w.hasCloud) cloud = m.withSession(() => m.client.cloudAll(owner: 'W/${w.id}'));
                        });
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          if (cloud != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.cloud_rounded, color: m.color),
                  const SizedBox(width: 8),
                  Text('Cloud de l\'espace', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            FutureBuilder(
              future: cloud,
              builder: (context, snap) {
                if (snap.hasError) return ErrorBanner('${snap.error}');
                if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: LoadingHint());
                final root = snap.data!;
                if (root.children.isEmpty) {
                  return const Padding(padding: EdgeInsets.all(16), child: Text('Le cloud de cet espace est vide.'));
                }
                return Column(children: _tree(root, 0));
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// « MATHEMATIQUES » → « Mathematiques » (plus joli à l'oral).
String _pretty(String s) {
  if (s.isEmpty || s != s.toUpperCase()) return s;
  final l = s.toLowerCase();
  return l[0].toUpperCase() + l.substring(1);
}
