import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/widgets.dart';
import 'ed_client.dart';

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
      if (at == null || DateTime.now().difference(at) > const Duration(hours: 12)) return;
      client
        ..token = j['token'] as String?
        ..accountId = j['id'] as int?
        ..studentName = j['name'] as String?;
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
    } on EdSessionExpired {
      rethrow;
    } catch (_) {}
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
    return _lastItems = [
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
              'devoir': g.title,
              'date': g.date,
            },
        ];
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
            },
        ];
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
  ];

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
                .take(5)
                .toList();
            if (snap.connectionState == ConnectionState.waiting && next.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (next.isEmpty) return const EmptyHint('Pas de cours à venir');
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final l in next)
                  ListTile(
                    dense: true,
                    title: Text(l.subject),
                    subtitle: Text(
                      '${dayLabel(l.start)} · ${hhmm(l.start)}'
                      '${l.room.isEmpty ? '' : ' · ${l.room}'}',
                    ),
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
      length: 4,
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
                    wrap(_messageTiles(context), 'Aucun message'),
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
              h.content.split('\n').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [SelectableText(h.content)],
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

  List<Widget> _messageTiles(BuildContext context) => [
    for (final m in messages)
      ListTile(
        leading: HubAvatar(label: m.from, color: m.read ? Colors.blueGrey : color),
        title: Text(
          m.from,
          style: TextStyle(fontWeight: m.read ? FontWeight.w500 : FontWeight.w800),
        ),
        subtitle: Text(m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: m.date == null
            ? null
            : Text(timeAgo(m.date!), style: Theme.of(context).textTheme.labelSmall),
        onTap: () async {
          m.read = true;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: Text(m.from)),
                body: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            m.subject,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const Divider(height: 28),
                          FutureBuilder(
                            future: withSession(() => client.messageContent(m.id)),
                            builder: (c, snap) => snap.hasError
                                ? ErrorBanner('${snap.error}')
                                : !snap.hasData
                                ? const LoadingHint()
                                : SelectableText(snap.data!, style: const TextStyle(height: 1.5)),
                          ),
                        ],
                      ),
                    ),
                    Builder(
                      builder: (c) => ChatComposer(
                        color: color,
                        hint: 'Répondre à ${m.from}',
                        onSend: (text) async {
                          await withSession(() => client.reply(m, text));
                          if (c.mounted) {
                            ScaffoldMessenger.of(c)
                                .showSnackBar(const SnackBar(content: Text('Réponse envoyée ✉️')));
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          store.changed();
        },
      ),
  ];
}
