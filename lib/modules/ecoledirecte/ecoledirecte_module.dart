import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
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
      return _weeks[key] = await client.timetable(from, to);
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

  Future<List<EdLesson>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      lastError = null;
      final user = store.getJson<String>('user');
      final pass = await store.readSecret('password');
      if (user == null || pass == null) return _cache = [];
      final faRaw = await store.readSecret('fa');
      var uuid = store.getJson<String>('uuid');
      if (uuid == null) {
        final r = Random.secure();
        String h(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
        uuid = '${h(8)}-${h(4)}-4${h(3)}-a${h(3)}-${h(12)}';
        await store.setJson('uuid', uuid);
      }
      client.uuid = uuid;
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
        if (client.lastFa != null) {
          await store.writeSecret('fa', jsonEncode(client.lastFa));
        }
        final now = DateTime.now();
        final from = DateTime(now.year, now.month, now.day);
        try {
          _cache = await client.timetable(
            from.subtract(Duration(days: from.weekday - 1)),
            from.add(const Duration(days: 21)),
          );
        } catch (e) {
          lastError = '$e';
        }
        try {
          grades = await client.grades();
        } catch (_) {}
        try {
          homework = await client.homework();
        } catch (_) {}
        try {
          messages = await client.messages();
        } catch (_) {}
        badge.value =
            messages.where((m) => !m.read).length +
            homework.where((h) => !h.done && h.due.difference(now).inDays <= 1).length;
        return _cache;
      } catch (e) {
        lastError = '$e';
        return _cache;
      }
    }();
  }

  @override
  Future<List<HubNotification>> poll() async {
    if (!configured) return const [];
    // Toutes les 2 min c'est trop pour École Directe : 15 min minimum.
    final last = _lastPoll;
    if (last != null && DateTime.now().difference(last).inMinutes < 15) return _lastItems;
    _lastPoll = DateTime.now();
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
                {'matiere': g.subject, 'note': '${g.value}/${g.outOf}', 'devoir': g.title, 'date': g.date},
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
          run: (a) => client.messageContent((a['id'] as num).toInt()),
        ),
      ];

  DateTime? _lastPoll;
  List<HubNotification> _lastItems = const [];

  Future<String?> _ask(String question, List<String> choices) async {
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return null;
    return showDialog<String>(
      context: ctx,
      builder: (c) => SimpleDialog(
        title: Text(question),
        children: [
          for (final ch in choices)
            SimpleDialogOption(onPressed: () => Navigator.pop(c, ch), child: Text(ch)),
        ],
      ),
    );
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
    await store.setJson('user', r[0]);
    await load(force: true);
    store.changed();
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
            if (lastError != null && _cache.isEmpty) return EmptyHint(lastError!);
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
              onPressed: () => load(force: true).then((_) => store.changed()),
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
                            future: client.messageContent(m.id),
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
                          await client.reply(m, text);
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
