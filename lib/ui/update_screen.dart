import 'package:material_ui/material_ui.dart';

import '../core/updater.dart';
import '../core/version.dart';
import '../core/browser.dart';

/// Met l'appli en pause et affiche l'écran de mise à jour par-dessus tout
/// (connexion comprise) dès qu'une nouvelle version est trouvée.
class UpdateGate extends StatelessWidget {
  const UpdateGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Updater.instance,
    builder: (context, _) {
      final u = Updater.instance;
      return Stack(
        children: [
          // L'appli reste dessous, figée (aucun clic ne passe).
          AbsorbPointer(absorbing: u.showing, child: child),
          if (u.showing) Positioned.fill(child: UpdateScreen(updater: u)),
        ],
      );
    },
  );
}

class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key, required this.updater});
  final Updater updater;

  static String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} Mo';

  @override
  Widget build(BuildContext context) {
    final u = updater;
    final info = u.available!;
    final error = u.error;
    final notes = info.notes
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Merge pull request'))
        .take(12)
        .join('\n');
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B1220), Color(0xFF13233A), Color(0xFF0B1220)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset('assets/logo.png', width: 96, height: 96),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Mise à jour de Mon Hub',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$appVersion  →  ${info.tag}',
                      style: const TextStyle(color: Colors.white70, fontSize: 16, letterSpacing: 1),
                    ),
                    const SizedBox(height: 26),
                    if (error == null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: u.progress,
                          minHeight: 10,
                          color: const Color(0xFF29E6FF),
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              u.status.isEmpty ? 'Préparation…' : u.status,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          if (u.progress != null)
                            Text(
                              '${(u.progress! * 100).round()} %'
                              '${info.size > 0 ? ' · ${_mb(u.received)} / ${_mb(info.size)}' : ''}',
                              style: const TextStyle(color: Colors.white70),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Mon Hub est en pause pendant la mise à jour. Il redémarre tout seul, '
                        'tes comptes et réglages sont gardés.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                        ),
                        child: Text(error, style: const TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Télécharger à la main'),
                            onPressed: () => Browser.open(
                              Updater.releasesUrl,
                            ),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Réessayer'),
                            onPressed: u.install,
                          ),
                        ],
                      ),
                    ],
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            'Nouveautés\n\n$notes',
                            style: const TextStyle(color: Colors.white70, height: 1.4),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: u.later,
                      child: const Text(
                        'Plus tard (au prochain démarrage)',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
