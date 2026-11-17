import 'package:material_ui/material_ui.dart';

import 'widgets.dart';

/// Les petits « résumés » des cartes de l'accueil, présentés joliment
/// (pas en liste) : le prochain cours en grand, les conversations en bulles
/// et en visages, les tâches en pastilles…

/// Un évènement à venir (cours, rendez-vous).
class NextItem {
  const NextItem({
    required this.title,
    required this.start,
    this.end,
    required this.color,
    this.place = '',
    this.allDay = false,
  });

  final String title;
  final DateTime start;
  final DateTime? end;
  final Color color;
  final String place;
  final bool allDay;
}

/// « Dans 25 min », « En cours », « Demain »…
String whenLabel(NextItem e, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final end = e.end ?? e.start.add(const Duration(hours: 1));
  if (!e.start.isAfter(n) && end.isAfter(n)) return 'En cours';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(e.start.year, e.start.month, e.start.day);
  final days = day.difference(today).inDays;
  if (days == 0) {
    final min = e.start.difference(n).inMinutes;
    if (e.allDay) return 'Aujourd\'hui';
    if (min < 1) return 'Maintenant';
    if (min < 60) return 'Dans $min min';
    final h = min ~/ 60;
    final m = min % 60;
    return 'Dans $h h${m == 0 ? '' : ' ${m.toString().padLeft(2, '0')}'}';
  }
  if (days == 1) return 'Demain';
  return dayLabel(e.start);
}

/// Le prochain évènement en grand, puis les suivants en pastilles.
class NextUpSummary extends StatelessWidget {
  const NextUpSummary({super.key, required this.items});

  final List<NextItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = items.first;
    final rest = items.skip(1).take(6).toList();
    return LayoutBuilder(
      builder: (context, box) {
        final roomForRest = box.maxHeight >= 160 && rest.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Hero(item: first),
              if (roomForRest) ...[
                const Spacer(),
                Text(
                  'ENSUITE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 50,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: rest.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => _Pill(item: rest[i]),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.item});
  final NextItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = item.color;
    final dark = theme.brightness == Brightness.dark;
    final when = whenLabel(item);
    final live = when == 'En cours' || when == 'Maintenant';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [c.withValues(alpha: dark ? 0.32 : 0.20), c.withValues(alpha: dark ? 0.10 : 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.allDay ? 'Journée' : hhmm(item.start),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: Color.lerp(c, dark ? Colors.white : Colors.black, dark ? 0.6 : 0.25),
                ),
              ),
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: live ? c : c.withValues(alpha: dark ? 0.35 : 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  when,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: live ? Colors.white : Color.lerp(c, dark ? Colors.white : Colors.black, dark ? 0.7 : 0.3),
                  ),
                ),
              ),
            ],
          ),
          Container(
            width: 3,
            height: 42,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (item.place.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(Icons.place_rounded, size: 13, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          item.place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.item});
  final NextItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final soon = whenLabel(item);
    final time = item.allDay ? 'Journée' : hhmm(item.start);
    final label = soon == 'Demain' || !soon.startsWith('Dans') && soon != 'En cours' && soon != 'Maintenant'
        ? '$soon · $time'
        : time;
    return Container(
      width: 132,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: item.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Dot(color: item.color, size: 7),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Une conversation (message privé, mail…).
class ChatItem {
  const ChatItem({
    required this.name,
    required this.preview,
    this.avatarUrl,
    this.unread = false,
    this.at,
    this.mine = false,
    this.onTap,
  });

  final String name;
  final String preview;
  final String? avatarUrl;
  final bool unread;
  final DateTime? at;

  /// Le dernier message vient de toi.
  final bool mine;
  final VoidCallback? onTap;
}

/// Les visages des dernières conversations (anneau de couleur = pas lu),
/// et le tout dernier message en bulle.
class ChatsSummary extends StatelessWidget {
  const ChatsSummary({super.key, required this.items, required this.color});

  final List<ChatItem> items;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = items.first;
    final unread = items.where((c) => c.unread).length;
    return LayoutBuilder(
      builder: (context, box) {
        final faces = box.maxHeight >= 150;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (faces) ...[
                SizedBox(
                  height: 70,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => SummaryFace(
                      name: items[i].name,
                      url: items[i].avatarUrl,
                      color: color,
                      ring: items[i].unread ? color : null,
                      onTap: items[i].onTap,
                    ),
                  ),
                ),
                const Spacer(),
              ],
              _Bubble(item: last, color: color),
              if (unread > 1) ...[
                const SizedBox(height: 6),
                Text(
                  '$unread conversations non lues',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.item, required this.color});
  final ChatItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: item.onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          HubAvatar(url: item.avatarUrl, label: item.name, color: color, size: 28),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
              decoration: BoxDecoration(
                color: color.withValues(alpha: dark ? 0.22 : 0.10),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: item.unread ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (item.at != null)
                        Text(
                          timeAgo(item.at!),
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.mine ? 'Toi : ' : ''}${item.preview}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: item.unread ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Un visage rond avec le prénom dessous ; [ring] colore le contour
/// (pas lu, en ligne…), [sub] ajoute une petite ligne (statut).
class SummaryFace extends StatelessWidget {
  const SummaryFace({
    super.key,
    required this.name,
    this.url,
    required this.color,
    this.ring,
    this.sub,
    this.onTap,
  });

  final String name;
  final String? url;
  final Color color;
  final Color? ring;
  final String? sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = name.trim().split(RegExp(r'\s+')).first;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: SizedBox(
        width: 58,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ring == null
                    ? null
                    : LinearGradient(
                        colors: [ring!, Color.lerp(ring!, const Color(0xFFE0457B), 0.55)!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                border: ring == null ? Border.all(color: theme.colorScheme.outlineVariant) : null,
              ),
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(shape: BoxShape.circle, color: theme.cardTheme.color ?? theme.colorScheme.surface),
                child: HubAvatar(url: url, label: name, color: color, size: 40),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(fontWeight: ring == null ? null : FontWeight.w700),
            ),
            if (sub != null)
              Text(
                sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9.5, color: ring ?? theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// Une petite tuile chiffrée (« 42 € ce mois-ci »).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.value, required this.label, required this.color});

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// La couleur d'une matière (« #rrggbb » d'École Directe), si elle est valide.
Color? lessonColor(String? hex) {
  final h = (hex ?? '').trim().replaceFirst('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
