import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/hub_files.dart';
import 'widgets.dart';

/// Un message d'une conversation enregistrée.
class ChatMsg {
  ChatMsg({required this.mine, required this.text, DateTime? at, this.note}) : at = at ?? DateTime.now();

  /// Écrit par toi (sinon : par Claude / Nexo).
  final bool mine;
  final String text;
  final DateTime at;

  /// Complément affiché en petit (tableau dessiné, appli, pièce jointe…).
  final String? note;

  Map<String, dynamic> toJson() => {'m': mine, 't': text, 'a': at.millisecondsSinceEpoch, 'n': ?note};

  factory ChatMsg.fromJson(Map j) => ChatMsg(
    mine: j['m'] == true,
    text: '${j['t'] ?? ''}',
    at: DateTime.fromMillisecondsSinceEpoch((j['a'] as num?)?.toInt() ?? 0),
    note: j['n'] as String?,
  );
}

/// Une conversation enregistrée.
class ChatThread {
  ChatThread({
    required this.id,
    this.title = '',
    DateTime? created,
    DateTime? updated,
    this.app = '',
    this.pinned = false,
    List<ChatMsg>? messages,
  }) : created = created ?? DateTime.now(),
       updated = updated ?? DateTime.now(),
       messages = messages ?? [];

  final String id;
  String title;
  final DateTime created;
  DateTime updated;

  /// Appli au premier plan (Nexo) : la mémoire est rangée par appli.
  String app;
  bool pinned;
  final List<ChatMsg> messages;

  /// Titre affiché : celui choisi, sinon le début de la première question.
  String get label {
    if (title.trim().isNotEmpty) return title.trim();
    final first = messages.where((m) => m.mine).firstOrNull?.text ?? '';
    final t = first.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return 'Nouvelle conversation';
    return t.length > 60 ? '${t.substring(0, 57)}…' : t;
  }

  String get preview {
    final last = messages.lastOrNull?.text ?? '';
    final t = last.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 90 ? '${t.substring(0, 87)}…' : t;
  }

  bool matches(String q) {
    final s = q.toLowerCase().trim();
    if (s.isEmpty) return true;
    return label.toLowerCase().contains(s) ||
        app.toLowerCase().contains(s) ||
        messages.any((m) => m.text.toLowerCase().contains(s));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'c': created.millisecondsSinceEpoch,
    'u': updated.millisecondsSinceEpoch,
    if (app.isNotEmpty) 'app': app,
    if (pinned) 'pin': true,
    'msgs': [for (final m in messages) m.toJson()],
  };

  factory ChatThread.fromJson(Map j) => ChatThread(
    id: '${j['id']}',
    title: '${j['title'] ?? ''}',
    created: DateTime.fromMillisecondsSinceEpoch((j['c'] as num?)?.toInt() ?? 0),
    updated: DateTime.fromMillisecondsSinceEpoch((j['u'] as num?)?.toInt() ?? 0),
    app: '${j['app'] ?? ''}',
    pinned: j['pin'] == true,
    messages: [
      for (final m in (j['msgs'] as List?) ?? const [])
        if (m is Map) ChatMsg.fromJson(m),
    ],
  );

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${math.Random().nextInt(1 << 20).toRadixString(36)}';
}

/// Historique des conversations (une liste par source : discussion Claude,
/// Nexo). Gardé dans les fichiers du compte, partagé avec Nexo partout.
class ChatHistory extends ChangeNotifier {
  ChatHistory(String file, {this.maxThreads = 300, this.maxMessages = 400})
    : _file = JsonFile<List<ChatThread>>(
        file,
        empty: () => [],
        decode: (j) => [
          for (final t in (j is List ? j : const []))
            if (t is Map) ChatThread.fromJson(t),
        ],
        encode: (v) => [for (final t in v) t.toJson()],
      );

  final JsonFile<List<ChatThread>> _file;
  final int maxThreads;
  final int maxMessages;

  /// Discussion directe avec Claude (module Claude).
  static final claude = ChatHistory('claude-chats.json');

  /// Échanges avec Nexo.
  static final clicky = ChatHistory('clicky-history.json');

  List<ChatThread> get threads {
    final l = [..._file.value];
    l.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updated.compareTo(a.updated);
    });
    return l;
  }

  Future<List<ChatThread>> load() async {
    if (await _file.reload()) notifyListeners();
    return threads;
  }

  ChatThread? byId(String? id) => id == null ? null : _file.value.where((t) => t.id == id).firstOrNull;

  /// Ajoute un message (crée la conversation au besoin).
  Future<ChatThread> add(String threadId, ChatMsg msg, {String app = ''}) async {
    late ChatThread out;
    await _file.update((list) {
      var t = list.where((x) => x.id == threadId).firstOrNull;
      if (t == null) {
        t = ChatThread(id: threadId, app: app);
        list.add(t);
      }
      if (app.isNotEmpty && t.app.isEmpty) t.app = app;
      t.messages.add(msg);
      if (t.messages.length > maxMessages) {
        t.messages.removeRange(0, t.messages.length - maxMessages);
      }
      t.updated = msg.at;
      out = t;
      // On garde les plus récentes (les épinglées restent).
      if (list.length > maxThreads) {
        list.sort((a, b) => b.updated.compareTo(a.updated));
        final keep = list.where((x) => x.pinned).toSet()..addAll(list.where((x) => !x.pinned).take(maxThreads));
        list.retainWhere(keep.contains);
      }
      return list;
    });
    notifyListeners();
    return out;
  }

  /// Ajoute ou remplace des conversations entières (import claude.ai).
  Future<int> upsertAll(List<ChatThread> threads) async {
    await _file.update((list) {
      for (final t in threads) {
        list.removeWhere((x) => x.id == t.id);
        list.add(t);
      }
      return list;
    });
    notifyListeners();
    return threads.length;
  }

  Future<void> rename(String id, String title) => _change(id, (t) => t.title = title);
  Future<void> togglePin(String id) => _change(id, (t) => t.pinned = !t.pinned);

  Future<void> _change(String id, void Function(ChatThread t) f) async {
    await _file.update((list) {
      final t = list.where((x) => x.id == id).firstOrNull;
      if (t != null) f(t);
      return list;
    });
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await _file.update((list) => list..removeWhere((t) => t.id == id));
    notifyListeners();
  }

  Future<void> clear() async {
    await _file.save([]);
    notifyListeners();
  }

  /// Texte brut d'une conversation (pour l'exporter / la copier).
  static String export(ChatThread t, {String me = 'Moi', String other = 'Claude'}) {
    final b = StringBuffer('# ${t.label}\n\n');
    for (final m in t.messages) {
      b.writeln('**${m.mine ? me : other}** (${dayLabel(m.at)} ${hhmm(m.at)}) :');
      b.writeln(m.text);
      if (m.note != null) b.writeln('_${m.note}_');
      b.writeln();
    }
    return '$b';
  }
}

/// Rubrique de date d'une conversation.
String historySection(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Hier';
  if (diff < 7) return 'Cette semaine';
  if (diff < 31) return 'Ce mois-ci';
  return 'Plus ancien';
}

/// Liste des conversations : recherche, rubriques par date, épingler,
/// renommer, supprimer.
class ChatHistoryList extends StatefulWidget {
  const ChatHistoryList({
    super.key,
    required this.history,
    required this.onOpen,
    this.selectedId,
    this.onNew,
    this.color,
    this.otherName = 'Claude',
    this.dense = false,
  });

  final ChatHistory history;
  final void Function(ChatThread t) onOpen;
  final String? selectedId;
  final VoidCallback? onNew;
  final Color? color;
  final String otherName;
  final bool dense;

  @override
  State<ChatHistoryList> createState() => _ChatHistoryListState();
}

class _ChatHistoryListState extends State<ChatHistoryList> {
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.history.load());
  }

  Future<void> _rename(ChatThread t) async {
    final r = await askFields(context, title: 'Renommer la conversation', labels: const ['Titre'], initial: [t.label]);
    final v = r?.first.trim();
    if (v != null && v.isNotEmpty) await widget.history.rename(t.id, v);
  }

  Future<void> _delete(ChatThread t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Supprimer la conversation ?'),
        content: Text('« ${t.label} » sera effacée de cet appareil.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok == true) await widget.history.remove(t.id);
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Effacer tout l\'historique ?'),
        content: const Text('Toutes les conversations enregistrées ici seront supprimées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tout effacer')),
        ],
      ),
    );
    if (ok == true) await widget.history.clear();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.history, search]),
      builder: (context, _) {
        final all = widget.history.threads;
        final list = all.where((t) => t.matches(search.text)).toList();
        final rows = <Widget>[];
        String? section;
        for (final t in list) {
          final s = t.pinned ? 'Épinglées' : historySection(t.updated);
          if (s != section) {
            section = s;
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(s, style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
            );
          }
          rows.add(
            ListTile(
              dense: widget.dense,
              selected: t.id == widget.selectedId,
              leading: Icon(
                t.pinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
                color: widget.color,
                size: widget.dense ? 18 : 22,
              ),
              title: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (t.app.isNotEmpty) t.app,
                  '${t.messages.length} message${t.messages.length > 1 ? 's' : ''}',
                  '${dayLabel(t.updated)} ${hhmm(t.updated)}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => widget.onOpen(t),
              trailing: PopupMenuButton<String>(
                tooltip: 'Options',
                onSelected: (v) async {
                  switch (v) {
                    case 'pin':
                      await widget.history.togglePin(t.id);
                    case 'rename':
                      await _rename(t);
                    case 'copy':
                      await Clipboard.setData(ClipboardData(text: ChatHistory.export(t, other: widget.otherName)));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Conversation copiée')));
                      }
                    case 'delete':
                      await _delete(t);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'pin', child: Text(t.pinned ? 'Désépingler' : 'Épingler')),
                  const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                  const PopupMenuItem(value: 'copy', child: Text('Copier le texte')),
                  const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Rechercher dans l\'historique',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (widget.onNew != null) ...[
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      tooltip: 'Nouvelle conversation',
                      icon: const Icon(Icons.add_comment_rounded),
                      onPressed: widget.onNew,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyHint(
                      all.isEmpty
                          ? 'Aucune conversation pour l\'instant. Elles s\'enregistrent toutes seules ici.'
                          : 'Rien ne correspond à ta recherche.',
                      icon: Icons.history_rounded,
                    )
                  : ListView(children: rows),
            ),
            if (all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                  label: const Text('Effacer tout l\'historique'),
                  onPressed: _clearAll,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Lecture d'une conversation enregistrée (bulles).
class ChatThreadView extends StatelessWidget {
  const ChatThreadView({super.key, required this.thread, required this.color, this.otherName = 'Claude'});

  final ChatThread thread;
  final Color color;
  final String otherName;

  @override
  Widget build(BuildContext context) => ListView.builder(
    reverse: true,
    padding: const EdgeInsets.all(12),
    itemCount: thread.messages.length,
    itemBuilder: (context, i) {
      final m = thread.messages[thread.messages.length - 1 - i];
      return ChatBubble(
        text: m.note == null ? m.text : '${m.text}\n\n${m.note}',
        time: '${dayLabel(m.at)} ${hhmm(m.at)}',
        mine: m.mine,
        color: color,
        author: m.mine ? null : otherName,
      );
    },
  );
}
