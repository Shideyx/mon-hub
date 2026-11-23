import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:supabase/supabase.dart';

import '../module_store.dart';
import 'online.dart';

/// Un espace partagé entre plusieurs comptes (ou une conversation privée).
class Space {
  const Space({
    required this.id,
    required this.name,
    this.kind = 'space',
    this.color = '#7C5CFF',
    this.owner = '',
    this.inviteCode,
    this.clickyChat = false,
  });

  final String id;
  final String name;

  /// 'space' (espace partagé) ou 'dm' (conversation à deux).
  final String kind;
  final String color;
  final String owner;
  final String? inviteCode;

  /// Les Clicky des membres peuvent se parler entre eux ici.
  final bool clickyChat;

  bool get isDm => kind == 'dm';

  Color get colorValue {
    final v = int.tryParse(color.replaceFirst('#', ''), radix: 16);
    return Color(0xFF000000 | (v ?? 0x7C5CFF));
  }

  factory Space.fromJson(Map j) => Space(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    kind: '${j['kind'] ?? 'space'}',
    color: '${j['color'] ?? '#7C5CFF'}',
    owner: '${j['owner'] ?? ''}',
    inviteCode: j['invite_code'] as String?,
    clickyChat: j['clicky_chat'] == true,
  );

  /// Couleurs proposées à la création d'un espace.
  static const palette = ['#7C5CFF', '#E0457B', '#3B82F6', '#10B981', '#F59E0B', '#0EA5E9', '#EF4444', '#A855F7'];
}

/// Quelqu'un (profil en ligne).
class Person {
  const Person(this.id, this.name, this.handle);
  final String id;
  final String name;
  final String? handle;

  String get label => name.trim().isNotEmpty ? name.trim() : (handle != null ? '@$handle' : 'Quelqu\'un');
  String get initial => label.replaceAll('@', '').isEmpty ? '?' : label.replaceAll('@', '').substring(0, 1).toUpperCase();

  factory Person.fromJson(Map j) => Person('${j['id']}', '${j['name'] ?? ''}', j['handle'] as String?);
}

/// Une tâche du tableau d'un espace.
class SpaceTask {
  const SpaceTask({
    required this.id,
    required this.spaceId,
    required this.title,
    this.notes = '',
    this.status = 'todo',
    this.tag = '',
    this.assignee,
    this.due,
    this.position = 0,
    this.createdBy = '',
  });

  final String id;
  final String spaceId;
  final String title;
  final String notes;
  final String status;
  final String tag;
  final String? assignee;
  final DateTime? due;
  final double position;
  final String createdBy;

  /// Les colonnes du tableau, dans l'ordre.
  static const statuses = ['todo', 'doing', 'review', 'done'];
  static const labels = {'todo': 'À faire', 'doing': 'En cours', 'review': 'À valider', 'done': 'Fini'};

  factory SpaceTask.fromJson(Map j) => SpaceTask(
    id: '${j['id']}',
    spaceId: '${j['space_id']}',
    title: '${j['title'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
    status: SpaceTask.statuses.contains(j['status']) ? '${j['status']}' : 'todo',
    tag: '${j['tag'] ?? ''}',
    assignee: j['assignee'] as String?,
    due: DateTime.tryParse('${j['due']}'),
    position: (j['position'] as num?)?.toDouble() ?? 0,
    createdBy: '${j['created_by'] ?? ''}',
  );

  /// En retard (pas fini et échéance passée) ?
  bool lateAt(DateTime now) => status != 'done' && due != null && due!.isBefore(DateTime(now.year, now.month, now.day));
}

/// Un message d'un espace.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.spaceId,
    required this.author,
    required this.body,
    this.fromClicky = false,
    this.depth = 0,
    this.replyTo,
    this.at,
  });

  final int id;
  final String spaceId;
  final String author;
  final String body;

  /// Écrit par le Clicky de [author] (pas par la personne elle-même).
  final bool fromClicky;

  /// Combien de Clicky se sont répondu à la suite (garde-fou anti-boucle).
  final int depth;
  final int? replyTo;
  final DateTime? at;

  factory ChatMessage.fromJson(Map j) => ChatMessage(
    id: (j['id'] as num?)?.toInt() ?? 0,
    spaceId: '${j['space_id']}',
    author: '${j['author']}',
    body: '${j['body'] ?? ''}',
    fromClicky: j['from_clicky'] == true,
    depth: (j['depth'] as num?)?.toInt() ?? 0,
    replyTo: (j['reply_to'] as num?)?.toInt(),
    at: DateTime.tryParse('${j['created_at']}')?.toLocal(),
  );
}

/// **Les espaces partagés** de Mon Hub en ligne : les espaces dont on est
/// membre, leurs membres, les tâches et la discussion (en direct), les
/// espaces épinglés et les messages non lus.
class Spaces extends ChangeNotifier {
  Spaces._();
  static final instance = Spaces._();

  List<Space> all = const [];

  /// Membres de chaque espace (identifiants).
  final members = <String, List<String>>{};
  final people = <String, Person>{};
  final unread = <String, int>{};

  bool loading = false;
  String? error;
  bool get available => Online.instance.signedIn;

  /// Espace affiché à l'écran (ses messages ne comptent pas comme non lus).
  String? viewing;

  /// Un message est arrivé (notification, Clicky…).
  void Function(Space space, ChatMessage m)? onMessage;

  RealtimeChannel? _channel;
  Timer? _poll;
  final _messageListeners = <String, Set<void Function(ChatMessage)>>{};
  final _taskListeners = <String, Set<VoidCallback>>{};

  String? get me => Online.instance.userId;

  /// Compte en ligne connecté : charge les espaces et écoute en direct.
  Future<void> start() async {
    stop();
    if (!available) {
      notifyListeners();
      return;
    }
    await refresh();
    _listen();
    // Filet de sécurité si le direct coupe (Wi-Fi qui change…).
    _poll = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(refresh(quiet: true)));
  }

  void stop() {
    final c = _channel;
    _channel = null;
    if (c != null) unawaited(Online.instance.clientOrNull?.removeChannel(c).catchError((Object _) => 'error'));
    _poll?.cancel();
    _poll = null;
    all = const [];
    members.clear();
    people.clear();
    unread.clear();
    error = null;
  }

  Future<void> refresh({bool quiet = false}) async {
    if (!available) return;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    try {
      final db = Online.instance.db;
      final rows = await db.from('spaces').select().order('created_at');
      final mem = await db.from('space_members').select('space_id,user_id');
      members.clear();
      for (final m in mem) {
        (members['${m['space_id']}'] ??= []).add('${m['user_id']}');
      }
      final ids = {for (final l in members.values) ...l};
      if (ids.isNotEmpty) {
        final ps = await db.from('profiles').select('id,name,handle').inFilter('id', ids.toList());
        for (final p in ps) {
          final person = Person.fromJson(p);
          people[person.id] = person;
        }
      }
      all = [for (final r in rows) Space.fromJson(r)];
      error = null;
    } catch (e) {
      error = Online.explain(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _listen() {
    final c = Online.instance.clientOrNull;
    final id = me;
    if (c == null || id == null) return;
    _channel = c
        .channel('monhub-$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (p) => _gotMessage(ChatMessage.fromJson(p.newRecord)),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'tasks',
          callback: (p) {
            final space = '${p.newRecord['space_id'] ?? p.oldRecord['space_id'] ?? ''}';
            // Une suppression ne dit pas toujours de quel espace : tous relisent.
            final targets = space.isEmpty ? _taskListeners.values.expand((s) => s) : (_taskListeners[space] ?? const {});
            for (final f in [...targets]) {
              f();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'space_members',
          callback: (_) => unawaited(refresh(quiet: true)),
        )
        .subscribe();
  }

  void _gotMessage(ChatMessage m) {
    for (final f in [...?_messageListeners[m.spaceId]]) {
      f(m);
    }
    final space = byId(m.spaceId);
    if (space == null) {
      // Nouvel espace (quelqu'un nous a écrit en privé) : on relit la liste.
      unawaited(refresh(quiet: true));
      return;
    }
    if (m.author != me && viewing != m.spaceId) {
      unread[m.spaceId] = (unread[m.spaceId] ?? 0) + 1;
      notifyListeners();
    }
    onMessage?.call(space, m);
  }

  int get totalUnread => unread.values.fold(0, (a, b) => a + b);

  void markRead(String spaceId) {
    if ((unread.remove(spaceId) ?? 0) > 0) notifyListeners();
  }

  /// Écoute les messages d'un espace (renvoie de quoi arrêter).
  VoidCallback listenMessages(String spaceId, void Function(ChatMessage) f) {
    (_messageListeners[spaceId] ??= {}).add(f);
    return () => _messageListeners[spaceId]?.remove(f);
  }

  /// Prévenu quand une tâche de l'espace change.
  VoidCallback listenTasks(String spaceId, VoidCallback f) {
    (_taskListeners[spaceId] ??= {}).add(f);
    return () => _taskListeners[spaceId]?.remove(f);
  }

  Space? byId(String id) => all.where((s) => s.id == id).firstOrNull;

  /// Le nom affiché (conversation privée : le nom de l'autre).
  String titleOf(Space s) {
    if (!s.isDm) return s.name;
    final other = (members[s.id] ?? const []).where((u) => u != me).firstOrNull;
    return other == null ? 'Discussion' : (people[other]?.label ?? 'Discussion');
  }

  Person? person(String? id) => id == null ? null : people[id];

  List<Person> membersOf(String spaceId) => [
    for (final u in members[spaceId] ?? const <String>[]) people[u] ?? Person(u, '', null),
  ];

  // ---------- Épinglés (synchronisés avec le compte) ----------

  static const _pinKey = 'hub.spaces.pinned';

  List<String> get pinned => ModuleStore.prefs.getStringList(_pinKey) ?? const [];
  bool isPinned(String id) => pinned.contains(id);

  Future<void> togglePin(String id) async {
    final l = [...pinned];
    l.contains(id) ? l.remove(id) : l.add(id);
    await ModuleStore.prefs.setStringList(_pinKey, l);
    notifyListeners();
  }

  /// Espaces partagés : les épinglés d'abord (dans l'ordre des épingles).
  List<Space> get spaces => sortPinned([for (final s in all) if (!s.isDm) s], pinned);

  /// Conversations privées.
  List<Space> get chats => sortPinned([for (final s in all) if (s.isDm) s], pinned);

  @visibleForTesting
  static List<Space> sortPinned(List<Space> l, List<String> pins) {
    final top = [
      for (final id in pins)
        if (l.any((s) => s.id == id)) l.firstWhere((s) => s.id == id),
    ];
    return [...top, ...l.where((s) => !pins.contains(s.id))];
  }

  // ---------- Espaces ----------

  Future<Space> create(String name, {String color = '#7C5CFF'}) async {
    final n = name.trim();
    if (n.isEmpty) throw 'Donne un nom à l\'espace.';
    try {
      final r = await Online.instance.db.rpc('create_space', params: {'p_name': n, 'p_color': color});
      final s = Space.fromJson(r as Map);
      await refresh(quiet: true);
      await togglePin(s.id);
      return s;
    } catch (e) {
      throw Online.explain(e);
    }
  }

  /// Rejoindre avec un code d'invitation (ou le lien qui le contient).
  Future<Space> join(String code) async {
    final c = inviteCodeIn(code);
    if (c == null) throw 'Ce n\'est pas un code d\'invitation (10 lettres et chiffres).';
    try {
      final r = await Online.instance.db.rpc('join_space', params: {'p_code': c});
      final s = Space.fromJson(r as Map);
      await refresh(quiet: true);
      return s;
    } catch (e) {
      throw Online.explain(e);
    }
  }

  /// Le code d'invitation dans un texte (« MONHUB-ESPACE:abcd012345 »…).
  static String? inviteCodeIn(String text) {
    final m = RegExp(r'(?:^|[^0-9a-f])([0-9a-f]{10})(?:$|[^0-9a-f])').firstMatch(text.trim().toLowerCase());
    return m?.group(1);
  }

  /// Le texte à envoyer pour inviter quelqu'un.
  static String inviteText(Space s) =>
      'Rejoins mon espace « ${s.name} » dans Mon Hub : Espaces → Rejoindre → code ${s.inviteCode ?? '?'}';

  Future<Space> openDm(String handle) async {
    final h = Online.cleanHandle(handle);
    if (h == null) throw 'Tape le @pseudo de la personne.';
    try {
      final r = await Online.instance.db.rpc('open_dm', params: {'p_handle': h});
      final s = Space.fromJson(r as Map);
      await refresh(quiet: true);
      return s;
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> leave(Space s) async {
    try {
      final db = Online.instance.db;
      if (s.owner == me) {
        await db.from('spaces').delete().eq('id', s.id);
      } else {
        await db.from('space_members').delete().eq('space_id', s.id).eq('user_id', me!);
      }
      if (isPinned(s.id)) await togglePin(s.id);
      await refresh(quiet: true);
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<String> newInviteCode(Space s) async {
    try {
      final c = await Online.instance.db.rpc('new_invite_code', params: {'p_space': s.id});
      await refresh(quiet: true);
      return '$c';
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> update(Space s, {String? name, String? color, bool? clickyChat}) async {
    try {
      await Online.instance.db
          .from('spaces')
          .update({'name': ?name?.trim(), 'color': ?color, 'clicky_chat': ?clickyChat})
          .eq('id', s.id);
      await refresh(quiet: true);
    } catch (e) {
      throw Online.explain(e);
    }
  }

  // ---------- Tâches ----------

  Future<List<SpaceTask>> tasks(String spaceId) async {
    try {
      final rows = await Online.instance.db.from('tasks').select().eq('space_id', spaceId).order('position');
      return [for (final r in rows) SpaceTask.fromJson(r)];
    } catch (e) {
      throw Online.explain(e);
    }
  }

  /// Les tâches de tous mes espaces (pour l'accueil et Clicky).
  Future<List<SpaceTask>> allTasks() async {
    if (!available) return const [];
    try {
      final rows = await Online.instance.db.from('tasks').select().neq('status', 'done').order('due').limit(200);
      return [for (final r in rows) SpaceTask.fromJson(r)];
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> addTask(String spaceId, String title, {String status = 'todo', String tag = '', String? assignee, DateTime? due}) async {
    final t = title.trim();
    if (t.isEmpty) return;
    try {
      await Online.instance.db.from('tasks').insert({
        'space_id': spaceId,
        'title': t.length > 200 ? t.substring(0, 200) : t,
        'status': status,
        'tag': tag.trim(),
        'assignee': ?assignee,
        if (due != null) 'due': dateOnly(due),
        'position': DateTime.now().millisecondsSinceEpoch / 1000,
      });
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> updateTask(SpaceTask t, Map<String, Object?> fields) async {
    try {
      await Online.instance.db.from('tasks').update(fields).eq('id', t.id);
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> moveTask(SpaceTask t, String status) => updateTask(t, {
    'status': status,
    'position': DateTime.now().millisecondsSinceEpoch / 1000,
  });

  Future<void> deleteTask(SpaceTask t) async {
    try {
      await Online.instance.db.from('tasks').delete().eq('id', t.id);
    } catch (e) {
      throw Online.explain(e);
    }
  }

  static String dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------- Discussion ----------

  Future<List<ChatMessage>> messages(String spaceId, {int limit = 80}) async {
    try {
      final rows = await Online.instance.db
          .from('messages')
          .select()
          .eq('space_id', spaceId)
          .order('id', ascending: false)
          .limit(limit);
      return [for (final r in rows.reversed) ChatMessage.fromJson(r)];
    } catch (e) {
      throw Online.explain(e);
    }
  }

  Future<void> send(String spaceId, String body, {bool fromClicky = false, int depth = 0, int? replyTo}) async {
    final b = body.trim();
    if (b.isEmpty) return;
    try {
      await Online.instance.db.from('messages').insert({
        'space_id': spaceId,
        'body': b.length > 4000 ? b.substring(0, 4000) : b,
        'from_clicky': fromClicky,
        'depth': depth.clamp(0, 10),
        'reply_to': ?replyTo,
      });
    } catch (e) {
      throw Online.explain(e);
    }
  }
}
