import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Ouvre un lien dans l'appli correspondante si elle est installée
/// (Instagram, Discord…), sinon dans le navigateur.
Future<void> openLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Impossible d\'ouvrir $url')));
  }
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$error'),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.info_outline_rounded, this.action});

  final String text;
  final IconData icon;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant.withValues(alpha: 0.7), size: 28),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            if (action != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadingHint extends StatelessWidget {
  const LoadingHint({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox.square(
            dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onErrorContainer))),
      ]),
    );
  }
}

/// Avatar rond : image réseau, ou initiale sur fond coloré.
class HubAvatar extends StatelessWidget {
  const HubAvatar({super.key, this.url, required this.label, required this.color, this.size = 40});

  final String? url;
  final String label;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = Text(
      label.isEmpty ? '?' : label.characters.first.toUpperCase(),
      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.42),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Colors.black, 0.35)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: url == null
          ? initial
          : Image.network(url!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => initial),
    );
  }
}

class Dot extends StatelessWidget {
  const Dot({super.key, required this.color, this.size = 9});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.text,
    required this.time,
    required this.mine,
    required this.color,
    this.author,
  });

  final String text;
  final String time;
  final bool mine;
  final Color color;
  final String? author;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? color : scheme.surfaceContainerHighest;
    final fg = mine ? Colors.white : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (author != null)
                Text(author!,
                    style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
              Text(text, style: TextStyle(color: fg)),
              const SizedBox(height: 2),
              Text(time, style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Petite boîte de dialogue « champ(s) texte » réutilisée par les modules.
Future<List<String>?> askFields(
  BuildContext context, {
  required String title,
  required List<String> labels,
  String? message,
  List<String>? initial,
  Set<int> obscure = const {},
}) {
  final ctrls = [
    for (var i = 0; i < labels.length; i++)
      TextEditingController(text: initial != null ? initial[i] : ''),
  ];
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(message),
                ),
              for (var i = 0; i < labels.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(
                    controller: ctrls[i],
                    obscureText: obscure.contains(i),
                    autofocus: i == 0,
                    decoration: InputDecoration(labelText: labels[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrls.map((c) => c.text.trim()).toList()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

String two(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

const frDays = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
const frMonths = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
  'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
];

String dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Demain';
  if (diff == -1) return 'Hier';
  return '${frDays[d.weekday - 1].substring(0, 3)}. ${d.day} ${frMonths[d.month - 1]}';
}

String timeAgo(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'à l\'instant';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  if (diff.inHours < 24) return '${diff.inHours} h';
  if (diff.inDays < 7) return '${diff.inDays} j';
  return '${d.day}/${two(d.month)}';
}
