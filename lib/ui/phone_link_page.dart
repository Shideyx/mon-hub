import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import '../core/pc_apps.dart';
import '../core/phone_link.dart';
import '../core/safe_open.dart';
import 'clicky/shot_encode.dart';
import 'clicky/win.dart';
import 'party_page.dart';

/// La page « Mon téléphone » : relier le téléphone au PC par un QR code, puis
/// s'envoyer des fichiers, du texte, et piloter le PC depuis le téléphone.
class PhoneLinkPage extends StatelessWidget {
  const PhoneLinkPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PhoneLinkPage()));

  /// Les fils de la page (presse-papier, télécommande, notifications) sont
  /// branchés ici, au lancement de Mon Hub.
  static void wire(void Function(String title, String body) notify) {
    final link = PhoneLink.instance;
    link.notify = notify;
    link.command = Win.supportedHere ? PhoneRemote.run : null;
    // L'écran du PC en direct sur le téléphone, ses applis et ses fenêtres.
    link.screen = Win.supportedHere ? PhoneRemote.capture : null;
    link.apps = PcApps.supported ? PhoneRemote.apps : null;
    link.windows = Win.supportedHere ? PhoneRemote.windows : null;
    link.readClipboard = () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    link.writeClipboard = (t) => Clipboard.setData(ClipboardData(text: t));
    link.loadAsset = (p) async {
      try {
        final d = await rootBundle.load('assets/$p');
        return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      } catch (_) {
        return null;
      }
    };
  }

  static String size(int n) => n < 1000000
      ? '${(n / 1000).ceil()} Ko'
      : n < 1000000000
      ? '${(n / 1e6).toStringAsFixed(1).replaceAll('.', ',')} Mo'
      : '${(n / 1e9).toStringAsFixed(2).replaceAll('.', ',')} Go';

  Future<void> _sendFiles(BuildContext context) async {
    final files = await openFiles();
    for (final f in files) {
      await PhoneLink.instance.share(f.path);
    }
    if (files.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sur ton téléphone : onglet « Du PC » (${files.length} fichier${files.length > 1 ? 's' : ''}).',
          ),
        ),
      );
    }
  }

  Future<void> _newLink(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Changer le lien ?'),
        content: const Text(
          'Les téléphones reliés jusqu\'ici ne pourront plus se connecter : il faudra rescanner le nouveau QR code. '
          'Utile si quelqu\'un d\'autre a eu le lien.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Changer')),
        ],
      ),
    );
    if (ok == true) await PhoneLink.instance.newLink();
  }

  @override
  Widget build(BuildContext context) {
    final link = PhoneLink.instance;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Mon téléphone')),
      body: ListenableBuilder(
        listenable: link,
        builder: (context, _) {
          final url = link.link;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                children: [
                  Text(
                    'Ton téléphone et ton PC reliés par le Wi-Fi de la maison : envoie tes photos au PC sans câble, '
                    'récupère des fichiers, partage le presse-papier et pilote le PC depuis ton lit.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: SwitchListTile(
                      value: link.enabled,
                      onChanged: (v) => link.setEnabled(v),
                      title: const Text('Relier mon téléphone'),
                      subtitle: const Text('Mon Hub reste joignable depuis ton téléphone tant qu\'il est ouvert.'),
                    ),
                  ),
                  if (link.enabled && link.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(link.error!, style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (url != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 20,
                          runSpacing: 16,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(10),
                              child: SizedBox.square(dimension: 200, child: QrView('$url')),
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 380),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Une seule fois', style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 6),
                                  const Text(
                                    '1. Ton téléphone sur le même Wi-Fi que le PC.\n'
                                    '2. Scanne ce code avec l\'appareil photo, touche le lien.\n'
                                    '3. Si Windows demande d\'autoriser Mon Hub sur le réseau : « Autoriser ».\n'
                                    '4. Sur iPhone : Partager ⬆️ → « Sur l\'écran d\'accueil » : l\'icône « Mon PC » '
                                    'ouvrira la page directement.',
                                  ),
                                  const SizedBox(height: 8),
                                  SelectableText('$url', style: theme.textTheme.bodySmall),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _sendFiles(context),
                          icon: const Icon(Icons.upload_file_rounded),
                          label: const Text('Envoyer au téléphone'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final d = await link.receiveDir();
                            await d.create(recursive: true);
                            await SafeOpen.launch(d.path);
                          },
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('Fichiers reçus'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: PartyPage.open,
                          icon: const Icon(Icons.celebration_rounded),
                          label: const Text('Playlist de soirée'),
                        ),
                        TextButton.icon(
                          onPressed: () => _newLink(context),
                          icon: const Icon(Icons.key_rounded),
                          label: const Text('Changer le lien'),
                        ),
                      ],
                    ),
                    if (link.shared.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('Proposés au téléphone', style: theme.textTheme.titleSmall),
                      for (final f in link.shared)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.insert_drive_file_rounded),
                          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(size(f.size)),
                          trailing: IconButton(
                            tooltip: 'Retirer',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => link.unshare(f.id),
                          ),
                        ),
                    ],
                    if (link.received.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('Reçus du téléphone', style: theme.textTheme.titleSmall),
                      for (final f in link.received.take(20))
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.download_done_rounded),
                          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(size(f.size)),
                          onTap: () => SafeOpen.launch(f.path),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// La télécommande du téléphone, sur Windows.
class PhoneRemote {
  PhoneRemote._();

  static const _keys = {
    'droite': 'right',
    'gauche': 'left',
    'espace': 'space',
    'echap': 'esc',
    'plein_ecran': 'f5',
    'f11': 'f11',
  };

  static int _int(Object? v, int lo, int hi) => ((v is num ? v : 0).round()).clamp(lo, hi);

  static double _frac(Object? v) => ((v is num ? v : num.tryParse('$v') ?? 0.5).toDouble()).clamp(0.0, 1.0);

  /// L'écran montré sur le téléphone (le principal).
  static (int, int, int, int) get screenRect => Win.monitors().first;

  /// L'écran du PC en JPEG ([width] pixels de large au plus).
  static Future<Uint8List?> capture(int width) async {
    try {
      final (x, y, w, h) = screenRect;
      final (tw, th) = shotSize(w, h, width);
      final px = Win.captureScaled(x, y, w, h, tw, th);
      return await Isolate.run(() => encodeShot(px, tw, th, quality: 55));
    } catch (_) {
      return null;
    }
  }

  /// La taille de l'image envoyée au téléphone.
  static (int, int) shotSize(int w, int h, int width) {
    final tw = math.min(width, w);
    return (tw, (h * tw / w).round());
  }

  /// Un point touché sur l'image (0..1) → l'écran.
  static (int, int) toScreen(double fx, double fy, (int, int, int, int) rect) {
    final (x, y, w, h) = rect;
    return ((x + fx * (w - 1)).round(), (y + fy * (h - 1)).round());
  }

  /// Les applis du PC (épinglées et fréquentes d'abord, ou la recherche).
  static Future<List<Map<String, Object?>>> apps(String query) async {
    final a = PcApps.instance;
    await a.load();
    final q = query.trim();
    final list = q.isEmpty ? [...a.pinned, ...a.frequent(max: 12), ...a.apps.take(40)] : a.search(q, max: 40);
    final seen = <String>{};
    return [
      for (final x in list)
        if (seen.add(x.id)) {'id': x.id, 'nom': x.name, 'ini': x.initials},
    ];
  }

  /// Les fenêtres ouvertes.
  static List<Map<String, Object?>> windows() => [
    for (final (id, title, exe) in Win.windowList().take(30)) {'id': id, 'titre': title, 'appli': exe},
  ];

  /// Les touches qu'on peut envoyer du téléphone.
  static final _combo = RegExp(r'^[a-z0-9]{1,9}(?:\+[a-z0-9]{1,9}){0,3}$');

  static Future<String?> run(String action, Map<String, dynamic> a) async {
    switch (action) {
      case 'volup' || 'voldown' || 'mute' || 'next' || 'prev':
        Win.mediaKey(action);
        return const {
          'volup': 'Son + 🔊',
          'voldown': 'Son − 🔉',
          'mute': 'Son coupé / remis',
          'next': 'Suivant ⏭',
          'prev': 'Précédent ⏮',
        }[action];
      case 'playpause':
        Win.mediaKey('play');
        return 'Lecture / pause ⏯';
      case 'droite' || 'gauche' || 'espace' || 'echap' || 'plein_ecran' || 'f11':
        Win.pressCombo(_keys[action]!);
        return 'OK';
      case 'souris':
        Win.mouseBy(_int(a['dx'], -400, 400), _int(a['dy'], -400, 400));
        return 'OK';
      case 'defiler':
        Win.scroll(_int(a['n'], -20, 20));
        return 'OK';
      case 'clic':
        Win.clickHere();
        return 'Clic';
      case 'clic_droit':
        Win.clickHere(right: true);
        return 'Clic droit';
      case 'clic_ecran':
        // Toucher l'écran du PC sur le téléphone = cliquer à cet endroit.
        final (x, y) = toScreen(_frac(a['x']), _frac(a['y']), screenRect);
        Win.click(x, y, right: a['droit'] == true, double: a['double'] == true);
        return 'OK';
      case 'taper':
        final t = '${a['texte'] ?? ''}';
        if (t.isEmpty || t.length > 4000) return 'Rien à taper.';
        Win.releaseModifiers();
        Win.typeText(t);
        if (a['entree'] == true) Win.pressCombo('enter');
        return 'Tapé sur le PC ⌨️';
      case 'touche':
        final k = '${a['touche'] ?? ''}'.trim().toLowerCase();
        if (!_combo.hasMatch(k)) return 'Touche inconnue.';
        return Win.pressCombo(k) ? 'OK' : 'Touche inconnue.';
      case 'lancer':
        final id = '${a['id'] ?? ''}';
        final app = PcApps.instance.apps.where((x) => x.id == id).firstOrNull;
        if (app == null) return 'Appli introuvable.';
        return await PcApps.instance.launch(app) ? '${app.name} s\'ouvre 🚀' : 'Pas réussi à ouvrir ${app.name}.';
      case 'fenetre':
        final id = a['id'] is num ? (a['id'] as num).toInt() : int.tryParse('${a['id']}');
        final what = '${a['faire'] ?? 'activer'}';
        if (id == null || !const {'activer', 'reduire', 'agrandir', 'fermer'}.contains(what)) return 'Fenêtre inconnue.';
        return Win.windowAction(id, what) ? 'OK' : 'Cette fenêtre est déjà fermée.';
      case 'verrouiller':
        return Win.lock() ? 'PC verrouillé 🔒' : 'Le PC n\'a pas voulu se verrouiller.';
      case 'veille':
        // Le temps de répondre au téléphone avant de s'endormir.
        Timer(const Duration(seconds: 1), Win.sleep);
        return 'Le PC se met en veille 🌙';
      case 'eteindre':
        final r = await Process.run('shutdown', [
          '/s',
          '/t',
          '60',
          '/c',
          'Mon Hub : extinction demandée depuis ton téléphone.',
        ]);
        if (r.exitCode != 0) return 'Le PC refuse de s\'éteindre (une extinction est peut-être déjà prévue).';
        PhoneLink.instance.notify?.call(
          '⏻ Le PC s\'éteint dans 1 minute',
          'Demandé depuis ton téléphone. Pour annuler : « Annuler l\'extinction » sur le téléphone.',
        );
        return 'Le PC s\'éteint dans 1 minute ⏻';
      case 'annuler_extinction':
        final r = await Process.run('shutdown', ['/a']);
        return r.exitCode == 0 ? 'Extinction annulée ✅' : 'Aucune extinction prévue.';
    }
    return null;
  }
}

/// Un QR code dessiné (paquet qr, sans Internet).
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _QrPainter(data));
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
    : _image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (_image.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
