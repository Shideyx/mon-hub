import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';
import 'ed_client.dart';

/// Emploi du temps École Directe (API non officielle, expérimental).
class EcoleDirecteModule extends HubModule {
  final client = EdClient();
  List<EdLesson> _cache = [];
  Future<List<EdLesson>>? _loading;
  String? lastError;

  @override
  String get id => 'ecoledirecte';
  @override
  String get name => 'École Directe';
  @override
  String get description => 'Ton emploi du temps scolaire';
  @override
  IconData get icon => Icons.school_outlined;
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
      try {
        await client.login(
          user,
          pass,
          savedFa: faRaw == null
              ? null
              : (jsonDecode(faRaw) as List)
                  .map((e) => Map<String, String>.from(e as Map))
                  .toList(),
          answerQuestion: _ask,
        );
        if (client.lastFa != null) {
          await store.writeSecret('fa', jsonEncode(client.lastFa));
        }
        final now = DateTime.now();
        final from = DateTime(now.year, now.month, now.day);
        return _cache = await client.timetable(from, from.add(const Duration(days: 7)));
      } catch (e) {
        lastError = '$e';
        return _cache;
      }
    }();
  }

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
    final r = await askFields(context,
        title: 'Connexion École Directe',
        labels: ['Identifiant', 'Mot de passe'],
        initial: [store.getJson<String>('user') ?? '', ''],
        obscure: {1});
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
                    subtitle: Text('${dayLabel(l.start)} · ${hhmm(l.start)}'
                        '${l.room.isEmpty ? '' : ' · ${l.room}'}'),
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
    return Scaffold(
      appBar: AppBar(title: Text(name), actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => load(force: true).then((_) => store.changed()),
        ),
        Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.manage_accounts_outlined),
            onPressed: () => _configure(context),
          ),
        ),
      ]),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (!configured) {
            return Center(
              child: FilledButton.icon(
                icon: const Icon(Icons.login),
                label: const Text('Se connecter'),
                onPressed: () => _configure(context),
              ),
            );
          }
          return FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) {
              final lessons = snap.data ?? [];
              final children = <Widget>[
                if (lastError != null)
                  MaterialBanner(
                    content: Text(lastError!),
                    actions: [
                      TextButton(
                        onPressed: () => openLink(context, 'https://www.ecoledirecte.com'),
                        child: const Text('Ouvrir le site'),
                      ),
                    ],
                  ),
              ];
              String? lastDay;
              for (final l in lessons) {
                final d = dayLabel(l.start);
                if (d != lastDay) {
                  children.add(Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(d, style: Theme.of(context).textTheme.titleMedium),
                  ));
                  lastDay = d;
                }
                children.add(ListTile(
                  leading: Text('${hhmm(l.start)}\n${hhmm(l.end)}'),
                  title: Text(l.subject,
                      style: l.cancelled
                          ? const TextStyle(decoration: TextDecoration.lineThrough)
                          : null),
                  subtitle: Text([
                    if (l.cancelled) 'ANNULÉ',
                    if (l.room.isNotEmpty) l.room,
                    if (l.teacher.isNotEmpty) l.teacher,
                  ].join(' · ')),
                ));
              }
              if (lessons.isEmpty && lastError == null) {
                children.add(const EmptyHint('Aucun cours cette semaine'));
              }
              return ListView(children: children);
            },
          );
        },
      ),
    );
  }
}
