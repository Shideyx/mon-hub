import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/online/online.dart';
import '../../core/online/spaces.dart';
import '../hud/hud.dart';
import '../online/online_page.dart';

/// Les boîtes « Créer un espace », « Rejoindre », « Écrire à quelqu'un ».
class SpaceActions {
  SpaceActions._();

  static Future<bool> _needOnline(BuildContext context) async {
    if (Spaces.instance.available) return true;
    await OnlinePage.open(context);
    return Spaces.instance.available;
  }

  static void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// Nouvel espace (nom + couleur). Renvoie l'espace créé.
  static Future<Space?> create(BuildContext context) async {
    if (!await _needOnline(context) || !context.mounted) return null;
    final name = TextEditingController();
    var color = Space.palette.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('NOUVEL ESPACE'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Nom (Projet SNT, Classe de 1re B, Mon entreprise…)'),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final c in Space.palette)
                      Semantics(
                        button: true,
                        selected: c == color,
                        label: 'Couleur $c',
                        child: InkWell(
                          onTap: () => set(() => color = c),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(border: Border.all(color: c == color ? HudColors.of(ctx).text : Colors.transparent, width: 2)),
                            child: HudDiamond(Space(id: '', name: '', color: c).colorValue, size: 18),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return null;
    try {
      final s = await Spaces.instance.create(name.text, color: color);
      if (context.mounted) _toast(context, 'Espace créé et épinglé. Invite du monde avec « Inviter ».');
      return s;
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return null;
    }
  }

  /// Rejoindre avec un code.
  static Future<Space?> join(BuildContext context) async {
    if (!await _needOnline(context) || !context.mounted) return null;
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('REJOINDRE UN ESPACE'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: code,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Code d\'invitation (ou le message reçu)'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rejoindre')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    try {
      final s = await Spaces.instance.join(code.text);
      if (context.mounted) _toast(context, 'Bienvenue dans « ${s.name} » !');
      return s;
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return null;
    }
  }

  /// Écrire en privé à @pseudo.
  static Future<Space?> message(BuildContext context) async {
    if (!await _needOnline(context) || !context.mounted) return null;
    final handle = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('NOUVEAU MESSAGE'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: handle,
            autofocus: true,
            decoration: const InputDecoration(labelText: '@pseudo de la personne', prefixText: '@'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Écrire')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    try {
      return await Spaces.instance.openDm(handle.text);
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
      return null;
    }
  }

  /// Le code d'invitation, à copier.
  static Future<void> invite(BuildContext context, Space s) async {
    final c = HudColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('INVITER'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Donne ce code à la personne (elle doit utiliser le même serveur Mon Hub en ligne) :', style: TextStyle(color: c.muted)),
              const SizedBox(height: 14),
              SelectableText(s.inviteCode ?? '—', style: hudTitle(ctx, size: 34, color: c.accentText).copyWith(letterSpacing: 4)),
              const SizedBox(height: 8),
              Text('Elle : Espaces → Rejoindre → ce code.', style: hudLabel(ctx)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copier l\'invitation'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: Spaces.inviteText(s)));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) _toast(context, 'Invitation copiée.');
            },
          ),
        ],
      ),
    );
  }
}

/// **Espaces** : tous mes espaces partagés et mes discussions privées.
class SpacesPage extends StatelessWidget {
  const SpacesPage({super.key, required this.onOpen});
  final ValueChanged<Space> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Spaces.instance, Online.instance]),
      builder: (context, _) {
        final s = Spaces.instance;
        final o = Online.instance;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 8),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  runSpacing: 12,
                  spacing: 12,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PARTAGÉ AVEC TES AMIS // EN DIRECT', style: hudLabel(context)),
                        const SizedBox(height: 6),
                        Text('ESPACES', style: hudTitle(context, size: 34)),
                        const SizedBox(height: 10),
                        Row(mainAxisSize: MainAxisSize.min, children: [const Hatch(width: 64, height: 7), const SizedBox(width: 12), const Barcode(width: 80, height: 14)]),
                      ],
                    ),
                    if (s.available)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          HudButton(label: 'Rejoindre', onPressed: () => _then(SpaceActions.join(context))),
                          HudButton(label: 'Message', icon: Icons.chat_bubble_outline_rounded, onPressed: () => _then(SpaceActions.message(context))),
                          HudButton(label: '+ Espace', primary: true, onPressed: () => _then(SpaceActions.create(context))),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (!o.configured || !o.signedIn)
              SliverFillRemaining(
                hasScrollBody: false,
                child: HudEmpty(
                  !o.configured
                      ? 'Les espaces partagés passent par Mon Hub en ligne : règle-le une fois (5 minutes), puis invite '
                            'tes amis avec un code.'
                      : 'Connecte ton compte en ligne pour créer des espaces, rejoindre ceux de tes amis et discuter.',
                  action: HudButton(label: 'Compte en ligne', primary: true, onPressed: () => OnlinePage.open(context)),
                ),
              )
            else ...[
              if (s.error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Text(s.error!, style: TextStyle(color: c.bad)),
                  ),
                ),
              if (s.spaces.isEmpty && !s.loading)
                SliverToBoxAdapter(
                  child: HudEmpty(
                    'Pas encore d\'espace. Crée-en un pour un exposé, ta classe, ton équipe ou ton entreprise, '
                    'ou rejoins celui d\'un ami avec son code.',
                    action: HudButton(label: '+ Créer un espace', primary: true, onPressed: () => _then(SpaceActions.create(context))),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 360,
                      mainAxisExtent: 128,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                    ),
                    itemCount: s.spaces.length,
                    itemBuilder: (context, i) => _SpaceCard(space: s.spaces[i], onOpen: onOpen),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: HudSectionLabel('Discussions privées', trailing: IconButton(
                    tooltip: 'Nouveau message',
                    icon: const Icon(Icons.add_rounded, size: 18),
                    onPressed: () => _then(SpaceActions.message(context)),
                  )),
                ),
              ),
              SliverList.builder(
                itemCount: s.chats.length,
                itemBuilder: (context, i) {
                  final d = s.chats[i];
                  final title = s.titleOf(d);
                  final n = s.unread[d.id] ?? 0;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    leading: HexAvatar(title.isEmpty ? '?' : title.substring(0, 1).toUpperCase()),
                    title: Text(title),
                    trailing: n > 0 ? HudTag('$n', color: c.pink, textColor: Colors.white) : null,
                    onTap: () => onOpen(d),
                  );
                },
              ),
              if (s.chats.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    child: Text('Écris à quelqu\'un avec son @pseudo (« Message »).', style: TextStyle(color: c.muted)),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ],
        );
      },
    );
  }

  void _then(Future<Space?> f) => unawaited(f.then((s) {
    if (s != null) onOpen(s);
  }));
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({required this.space, required this.onOpen});
  final Space space;
  final ValueChanged<Space> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final s = Spaces.instance;
    final members = s.membersOf(space.id);
    final unread = s.unread[space.id] ?? 0;
    final pinned = s.isPinned(space.id);
    return HudPanel(
      onTap: () => onOpen(space),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HudDiamond(space.colorValue, size: 9),
              const SizedBox(width: 10),
              Expanded(child: Text(space.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: hudTitle(context, size: 18))),
              if (unread > 0) HudTag('$unread', color: c.pink, textColor: Colors.white),
              IconButton(
                tooltip: pinned ? 'Désépingler du menu' : 'Épingler en haut du menu',
                icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined, size: 18, color: pinned ? c.accentText : c.dim),
                onPressed: () => s.togglePin(space.id),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              for (final p in members.take(5))
                Padding(padding: const EdgeInsets.only(right: 2), child: HexAvatar(p.initial, size: 26, color: HexAvatar.colorFor(p.id))),
              const SizedBox(width: 8),
              Text('${members.length} MEMBRE${members.length > 1 ? 'S' : ''}', style: hudLabel(context, size: 10)),
              const Spacer(),
              if (space.clickyChat) Tooltip(message: 'Les Clicky peuvent se parler ici', child: Icon(Icons.near_me_rounded, size: 16, color: c.accentText)),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
  }
}
