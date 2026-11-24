import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/online/spaces.dart';
import '../hud/hud.dart';
import 'spaces_page.dart';

/// Un espace partagé : son **tableau** (À faire / En cours / À valider /
/// Fini) et sa **discussion**, en direct. Une conversation privée n'a que la
/// discussion.
class SpacePage extends StatefulWidget {
  const SpacePage({super.key, required this.spaceId, this.onClosed});
  final String spaceId;

  /// Espace quitté ou supprimé.
  final VoidCallback? onClosed;

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> {
  int _tab = 0;

  void _toast(String t) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  Future<void> _menu(Space s, String action) async {
    final sp = Spaces.instance;
    try {
      switch (action) {
        case 'pin':
          await sp.togglePin(s.id);
        case 'invite':
          await SpaceActions.invite(context, s);
        case 'code':
          final code = await sp.newInviteCode(s);
          _toast('Nouveau code : $code (l\'ancien ne marche plus).');
        case 'clicky':
          await sp.update(s, clickyChat: !s.clickyChat);
          _toast(!s.clickyChat
              ? 'Les Smily peuvent se parler ici (chacun doit aussi l\'allumer dans Compte en ligne).'
              : 'Les Smily ne se parlent plus ici.');
        case 'rename':
          final name = await _ask('RENOMMER', s.name);
          if (name != null && name.trim().isNotEmpty) await sp.update(s, name: name);
        case 'leave':
          final owner = s.owner == sp.me;
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(owner ? 'SUPPRIMER L\'ESPACE ?' : 'QUITTER L\'ESPACE ?'),
              content: Text(owner
                  ? 'L\'espace, ses tâches et sa discussion disparaissent pour tout le monde.'
                  : 'Tu ne verras plus ses tâches ni sa discussion (tu pourras revenir avec un code).'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(owner ? 'Supprimer' : 'Quitter')),
              ],
            ),
          );
          if (ok == true) {
            await sp.leave(s);
            widget.onClosed?.call();
          }
      }
    } catch (e) {
      _toast('$e');
    }
  }

  Future<String?> _ask(String title, String initial) {
    final t = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 400, child: TextField(controller: t, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, t.text), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Spaces.instance,
      builder: (context, _) {
        final sp = Spaces.instance;
        final s = sp.byId(widget.spaceId);
        if (s == null) {
          return HudEmpty(sp.loading ? 'Chargement…' : 'Cet espace n\'existe plus (ou tu n\'en fais plus partie).');
        }
        final members = sp.membersOf(s.id);
        final owner = s.owner == sp.me;
        final unread = sp.unread[s.id] ?? 0;
        final chatOnly = s.isDm;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 16, 8),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        HudDiamond(s.colorValue),
                        const SizedBox(width: 8),
                        Text(chatOnly ? 'DISCUSSION PRIVÉE' : 'ESPACE // ${members.length} MEMBRE${members.length > 1 ? 'S' : ''}', style: hudLabel(context)),
                      ]),
                      const SizedBox(height: 6),
                      Text(sp.titleOf(s).toUpperCase(), style: hudTitle(context, size: 32)),
                      const SizedBox(height: 10),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Hatch(width: 64, height: 7, color: s.colorValue),
                        const SizedBox(width: 12),
                        Text('● EN DIRECT', style: hudLabel(context, size: 10, color: c.ok)),
                      ]),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final p in members.take(6))
                        Tooltip(
                          message: p.handle == null ? p.label : '${p.label} (@${p.handle})',
                          child: Padding(padding: const EdgeInsets.only(right: 2), child: HexAvatar(p.initial, size: 30, color: HexAvatar.colorFor(p.id))),
                        ),
                      const SizedBox(width: 10),
                      if (!chatOnly) HudButton(label: 'Inviter', onPressed: () => SpaceActions.invite(context, s)),
                      PopupMenuButton<String>(
                        tooltip: 'Plus',
                        icon: Icon(Icons.more_vert_rounded, color: c.muted),
                        onSelected: (a) => _menu(s, a),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'pin', child: Text(sp.isPinned(s.id) ? 'Désépingler du menu' : 'Épingler en haut du menu')),
                          if (!chatOnly && owner) const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                          if (!chatOnly && owner)
                            PopupMenuItem(value: 'clicky', child: Text(s.clickyChat ? 'Les Smily ne se parlent plus ici' : 'Laisser les Smily se parler ici')),
                          if (!chatOnly && owner) const PopupMenuItem(value: 'code', child: Text('Nouveau code d\'invitation')),
                          PopupMenuItem(value: 'leave', child: Text(owner && !chatOnly ? 'Supprimer l\'espace' : 'Quitter')),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!chatOnly)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Row(
                  children: [
                    _Tab(label: 'Tableau', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
                    _Tab(label: unread > 0 && _tab != 1 ? 'Discussion · $unread' : 'Discussion', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
                  ],
                ),
              ),
            Expanded(
              child: chatOnly || _tab == 1
                  ? _Chat(key: ValueKey('chat-${s.id}'), space: s)
                  : _Board(key: ValueKey('board-${s.id}'), space: s),
            ),
          ],
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    const shape = SlantBorder(slant: 8);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: selected ? c.accent : Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Text(label.toUpperCase(), style: hudLabel(context, size: 12, color: selected ? Colors.white : c.muted)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Tableau

class _Board extends StatefulWidget {
  const _Board({super.key, required this.space});
  final Space space;

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> {
  List<SpaceTask> _tasks = const [];
  bool _loading = true;
  String? _error;
  VoidCallback? _stop;
  Timer? _again;
  String? _adding;
  final _newTitle = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _stop = Spaces.instance.listenTasks(widget.space.id, () {
      // Plusieurs changements d'un coup : une seule relecture.
      _again?.cancel();
      _again = Timer(const Duration(milliseconds: 300), () => unawaited(_load()));
    });
  }

  @override
  void dispose() {
    _stop?.call();
    _again?.cancel();
    _newTitle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await Spaces.instance.tasks(widget.space.id);
      if (!mounted) return;
      setState(() {
        _tasks = t;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _do(Future<void> Function() f) async {
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _add(String status) async {
    final t = _newTitle.text.trim();
    _newTitle.clear();
    setState(() => _adding = null);
    if (t.isEmpty) return;
    await _do(() => Spaces.instance.addTask(widget.space.id, t, status: status));
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return HudEmpty(_error!, action: HudButton(label: 'Réessayer', onPressed: _load));
    final touch = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        for (final status in SpaceTask.statuses)
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: SizedBox(
              width: 290,
              child: DragTarget<SpaceTask>(
                onWillAcceptWithDetails: (d) => d.data.status != status,
                onAcceptWithDetails: (d) => _do(() => Spaces.instance.moveTask(d.data, status)),
                builder: (context, cand, _) {
                  final list = [for (final t in _tasks) if (t.status == status) t];
                  return HudPanel(
                    color: cand.isNotEmpty ? c.hotBg : c.panelLow,
                    lineColor: cand.isNotEmpty ? c.accent : null,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(SpaceTask.labels[status]!.toUpperCase(), style: hudTitle(context, size: 15))),
                            Text(list.length.toString().padLeft(2, '0'), style: hudTitle(context, size: 22, color: _statusColor(c, status))),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final t in list)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: touch
                                      ? LongPressDraggable<SpaceTask>(data: t, feedback: _feedback(t), childWhenDragging: Opacity(opacity: .3, child: _card(t)), child: _card(t))
                                      : Draggable<SpaceTask>(data: t, feedback: _feedback(t), childWhenDragging: Opacity(opacity: .3, child: _card(t)), child: _card(t)),
                                ),
                              if (_adding == status)
                                TextField(
                                  controller: _newTitle,
                                  autofocus: true,
                                  decoration: const InputDecoration(hintText: 'Titre de la tâche…', isDense: true),
                                  onSubmitted: (_) => _add(status),
                                  onTapOutside: (_) => _add(status),
                                )
                              else
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    icon: const Icon(Icons.add_rounded, size: 18),
                                    label: const Text('Ajouter'),
                                    onPressed: () => setState(() => _adding = status),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  static Color _statusColor(HudColors c, String s) => switch (s) {
    'doing' => const Color(0xFF3B82F6),
    'review' => const Color(0xFFF59E0B),
    'done' => const Color(0xFF10B981),
    _ => c.dim,
  };

  Widget _feedback(SpaceTask t) => Material(
    color: Colors.transparent,
    child: SizedBox(width: 266, child: Opacity(opacity: .92, child: _card(t))),
  );

  Widget _card(SpaceTask t) {
    final c = HudColors.of(context);
    final who = Spaces.instance.person(t.assignee);
    final late = t.lateAt(DateTime.now());
    final done = t.status == 'done';
    return Opacity(
      opacity: done ? .65 : 1,
      child: HudPanel(
        cut: 10,
        brackets: false,
        color: c.panel,
        padding: const EdgeInsets.all(12),
        onTap: () => _edit(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (t.tag.isNotEmpty) ...[HudTag(t.tag, color: c.selected, textColor: c.accentText), const SizedBox(height: 8)],
            Text(t.title, style: TextStyle(fontWeight: FontWeight.w600, decoration: done ? TextDecoration.lineThrough : null)),
            const SizedBox(height: 8),
            Row(
              children: [
                if (t.due != null)
                  Text(_day(t.due!), style: hudMono(context, size: 11, color: late ? c.bad : c.muted)),
                if (t.notes.isNotEmpty) ...[const SizedBox(width: 8), Icon(Icons.notes_rounded, size: 14, color: c.dim)],
                const Spacer(),
                if (who != null) HexAvatar(who.initial, size: 24, color: HexAvatar.colorFor(who.id)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _days = ['LUN', 'MAR', 'MER', 'JEU', 'VEN', 'SAM', 'DIM'];
  static String _day(DateTime d) => '${_days[d.weekday - 1]} ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

  Future<void> _edit(SpaceTask t) async {
    final title = TextEditingController(text: t.title);
    final notes = TextEditingController(text: t.notes);
    final tag = TextEditingController(text: t.tag);
    var status = t.status;
    String? assignee = t.assignee;
    DateTime? due = t.due;
    final members = Spaces.instance.membersOf(widget.space.id);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('TÂCHE'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: title, decoration: const InputDecoration(labelText: 'Titre'), maxLength: 200),
                  TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes'), minLines: 2, maxLines: 6),
                  const SizedBox(height: 10),
                  TextField(controller: tag, decoration: const InputDecoration(labelText: 'Étiquette (Maths, Design…)'), maxLength: 30),
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Colonne'),
                    items: [for (final s in SpaceTask.statuses) DropdownMenuItem(value: s, child: Text(SpaceTask.labels[s]!))],
                    onChanged: (v) => set(() => status = v ?? status),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: members.any((m) => m.id == assignee) ? assignee : null,
                    decoration: const InputDecoration(labelText: 'Qui s\'en occupe'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Personne')),
                      for (final m in members) DropdownMenuItem<String?>(value: m.id, child: Text(m.id == Spaces.instance.me ? '${m.label} (toi)' : m.label)),
                    ],
                    onChanged: (v) => set(() => assignee = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: Text(due == null ? 'Pas d\'échéance' : 'Pour le ${_day(due!)}')),
                      TextButton(
                        onPressed: () async {
                          final now = DateTime.now();
                          final d = await showDatePicker(
                            context: ctx,
                            initialDate: due ?? now,
                            firstDate: DateTime(now.year - 1),
                            lastDate: DateTime(now.year + 3),
                          );
                          if (d != null) set(() => due = d);
                        },
                        child: const Text('Choisir'),
                      ),
                      if (due != null) IconButton(tooltip: 'Sans échéance', icon: const Icon(Icons.close_rounded), onPressed: () => set(() => due = null)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Supprimer')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (r == 'delete') {
      await _do(() => Spaces.instance.deleteTask(t));
    } else if (r == 'save' && title.text.trim().isNotEmpty) {
      await _do(() => Spaces.instance.updateTask(t, {
        'title': title.text.trim(),
        'notes': notes.text.trim(),
        'tag': tag.text.trim(),
        'status': status,
        'assignee': assignee,
        'due': due == null ? null : Spaces.dateOnly(due!),
      }));
    }
  }
}

// ------------------------------------------------------------- Discussion

class _Chat extends StatefulWidget {
  const _Chat({super.key, required this.space});
  final Space space;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = const [];
  bool _loading = true;
  String? _error;
  VoidCallback? _stop;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final sp = Spaces.instance;
    sp.viewing = widget.space.id;
    sp.markRead(widget.space.id);
    _stop = sp.listenMessages(widget.space.id, (m) {
      if (!mounted || _messages.any((x) => x.id == m.id)) return;
      setState(() => _messages = [..._messages, m]);
      sp.markRead(widget.space.id);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _stop?.call();
    if (Spaces.instance.viewing == widget.space.id) Spaces.instance.viewing = null;
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await Spaces.instance.messages(widget.space.id);
      if (!mounted) return;
      setState(() {
        _messages = l;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await Spaces.instance.send(widget.space.id, t);
      _text.clear();
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final sp = Spaces.instance;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return HudEmpty(_error!, action: HudButton(label: 'Réessayer', onPressed: _load));
    final list = _messages.reversed.toList();
    return Column(
      children: [
        Expanded(
          child: list.isEmpty
              ? HudEmpty('Pas encore de message. Dis bonjour !\nAstuce : « @clicky … » et ton Smily répond ici pour tout le monde.')
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final older = i + 1 < list.length ? list[i + 1] : null;
                    final grouped = older != null &&
                        older.author == m.author &&
                        older.fromClicky == m.fromClicky &&
                        m.at != null &&
                        older.at != null &&
                        m.at!.difference(older.at!).inMinutes < 5;
                    return _Bubble(m: m, grouped: grouped, mine: m.author == sp.me);
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
          child: HudPanel(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            brackets: false,
            child: Row(
              children: [
                Text('>_', style: hudMono(context, color: c.accentText, weight: FontWeight.w700)),
                const SizedBox(width: 10),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: const InputDecoration(
                        hintText: 'Écris… (« @clicky » pour demander à ton Smily)',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Envoyer (Entrée)',
                  onPressed: _sending ? null : _send,
                  icon: Icon(Icons.send_rounded, color: c.accentText),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m, required this.grouped, required this.mine});
  final ChatMessage m;
  final bool grouped;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final p = Spaces.instance.person(m.author);
    final name = p?.label ?? 'Quelqu\'un';
    final time = m.at == null ? '' : '${m.at!.hour.toString().padLeft(2, '0')}:${m.at!.minute.toString().padLeft(2, '0')}';
    if (m.fromClicky) {
      return Padding(
        padding: EdgeInsets.only(top: grouped ? 4 : 12, left: 40),
        child: HudPanel(
          hot: true,
          cut: 10,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.near_me_rounded, size: 14, color: Color(0xFF7C5CFF)),
                  const SizedBox(width: 6),
                  Text('CLICKY DE ${name.toUpperCase()}', style: hudLabel(context, size: 10, color: c.accentText)),
                  const Spacer(),
                  Text(time, style: hudMono(context, size: 10, color: c.dim)),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(m.body, style: const TextStyle(height: 1.45)),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: grouped ? 2 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: grouped ? null : HexAvatar(p?.initial ?? '?', size: 30, color: HexAvatar.colorFor(m.author)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!grouped)
                  Row(children: [
                    Text(mine ? '$name (toi)' : name, style: TextStyle(fontWeight: FontWeight.w700, color: mine ? c.accentText : c.text)),
                    const SizedBox(width: 8),
                    Text(time, style: hudMono(context, size: 10, color: c.dim)),
                    if (Spaces.mentionsSmily(m.body)) ...[
                      const SizedBox(width: 8),
                      HudTag('@clicky', color: c.selected, textColor: c.accentText),
                    ],
                  ]),
                SelectableText(m.body, style: const TextStyle(height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
