import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Ouvre un lien dans l'appli correspondante si elle est installée
/// (Instagram, Discord…), sinon dans le navigateur.
Future<void> openLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final ok = uri != null &&
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Impossible d\'ouvrir $url')));
  }
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Erreur : $error')),
  );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.info_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: color)),
          ],
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
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
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
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(ctx, ctrls.map((c) => c.text.trim()).toList()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

String two(int n) => n.toString().padLeft(2, '0');
String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

const _days = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
String dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Demain';
  return '${_days[d.weekday - 1]} ${d.day}/${two(d.month)}';
}
