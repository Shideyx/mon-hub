import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/account_sync.dart';
import '../core/browser.dart';
import '../core/google_auth.dart';
import 'google_setup.dart';
import 'web_version_card.dart';

/// Réglages → Mes appareils → **Ajouter mon iPhone** (sur le PC) : installer
/// Mon Hub sur l'iPhone, lui donner la connexion Google du PC (code de
/// liaison) et retrouver le même compte, synchronisé avec le PC.
class PhoneSetupPage extends StatefulWidget {
  const PhoneSetupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PhoneSetupPage()));

  static const ipa = 'https://github.com/Shideyx/mon-hub/releases/latest/download/MonHub-iOS.ipa';

  @override
  State<PhoneSetupPage> createState() => _PhoneSetupPageState();
}

class _PhoneSetupPageState extends State<PhoneSetupPage> {
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _mail(String code) async {
    final to = GoogleAuth.driveAccount ?? '';
    final body =
        'Sur ton iPhone : ouvre Mon Hub → « Retrouver mon compte d\'un autre appareil » → copie tout ce '
        'message et appuie sur « Coller le code de mon PC ».\n\n$code\n';
    final uri =
        'mailto:$to?subject=${Uri.encodeComponent('Mon Hub : code pour mon iPhone')}&body=${Uri.encodeComponent(body)}';
    if (!await Browser.open(uri)) _snack('Pas d\'appli de mail sur ce PC : copie le code à la place.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = GoogleAuth.shareCode();
    final sync = AccountSync.instance;
    final steps = <(IconData, String, Widget)>[
      (
        Icons.install_mobile_rounded,
        'Installer Mon Hub sur l\'iPhone',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Apple n\'autorise que l\'App Store, sauf pour les applis « installées par le développeur » : on passe '
              'par Sideloadly (gratuit), depuis ce PC, avec ton identifiant Apple.\n'
              '1. Installe iTunes (site d\'Apple, pas le Microsoft Store) puis Sideloadly.\n'
              '2. Télécharge MonHub-iOS.ipa.\n'
              '3. Branche l\'iPhone en USB, déverrouille-le, « Faire confiance ».\n'
              '4. Dans Sideloadly : glisse le fichier .ipa, tape ton identifiant Apple, Start.\n'
              '5. Sur l\'iPhone : Réglages → Général → VPN et gestion de l\'appareil → ton identifiant → Faire '
              'confiance ; puis Réglages → Confidentialité et sécurité → Mode développeur → activer.\n'
              'Avec un identifiant gratuit, Apple demande de refaire l\'étape 4 tous les 7 jours (Sideloadly sait le '
              'faire tout seul quand l\'iPhone est sur le même Wi-Fi).',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Télécharger MonHub-iOS.ipa'),
                  onPressed: () => Browser.open(PhoneSetupPage.ipa),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Sideloadly'),
                  onPressed: () => Browser.open('https://sideloadly.io'),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('iTunes'),
                  onPressed: () => Browser.open('https://www.apple.com/fr/itunes/'),
                ),
              ],
            ),
          ],
        ),
      ),
      (
        Icons.key_rounded,
        'Donner la connexion Google à l\'iPhone',
        code == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Active d\'abord la connexion Google sur ce PC.'),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => GoogleSetupPage.open(context).then((_) => setState(() {})),
                    child: const Text('Connexion Google'),
                  ),
                ],
              )
            : GoogleAuth.builtInId.isNotEmpty
            ? const Text('Rien à faire : la connexion Google est déjà prête dans l\'appli iPhone.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pour que l\'iPhone se connecte à Google sans refaire les 5 étapes, envoie-lui ce code (il ne '
                    'passe que par toi : ton presse-papier ou ton propre mail).',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.mail_rounded),
                        label: const Text('M\'envoyer le code par mail'),
                        onPressed: () => _mail(code),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Copier le code'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: code));
                          _snack('Code copié.');
                        },
                      ),
                    ],
                  ),
                ],
              ),
      ),
      (
        Icons.sync_rounded,
        'Retrouver ton compte sur l\'iPhone',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sur l\'iPhone, ouvre Mon Hub → « Retrouver mon compte d\'un autre appareil » → « Coller le code de mon '
              'PC » → « Se connecter avec Google » (le même compte qu\'ici) → « Demander mon compte à mon PC '
              'principal ». Laisse Mon Hub ouvert sur ce PC : il envoie ton compte tout seul, puis les deux restent '
              'synchronisés (toutes les 3 minutes, par ton Google Drive, chiffré).',
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: sync,
              builder: (context, _) => Text(
                sync.enabled
                    ? '✅ La synchronisation est active sur ce PC (${sync.email}).'
                    : 'La synchronisation n\'est pas encore active ici : elle s\'activera toute seule quand l\'iPhone '
                          'la demandera (ou active-la dans Réglages → Mes appareils).',
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Ajouter mon iPhone')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              Text(
                'Mon Hub sur ton iPhone, avec le même compte que ce PC : tes modules, Smily, tes réglages, tes '
                'révisions, tes anniversaires… Ce que tu changes d\'un côté arrive de l\'autre. Rien ne passe par un '
                'serveur à nous : la copie chiffrée est dans ton propre Google Drive.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              const WebVersionCard(),
              const SizedBox(height: 6),
              Text('Ou l\'appli complète, installée depuis ce PC :', style: theme.textTheme.titleSmall),
              for (final (i, (icon, title, body)) in steps.indexed)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                            const SizedBox(width: 10),
                            Icon(icon, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                title,
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        body,
                      ],
                    ),
                  ),
                ),
              if (!Platform.isWindows)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Cette page se suit depuis le PC (Windows).', style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sur l'iPhone (ou un nouvel appareil) : « Coller le code de mon PC ».
class PasteGoogleCode extends StatefulWidget {
  const PasteGoogleCode({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<PasteGoogleCode> createState() => _PasteGoogleCodeState();
}

class _PasteGoogleCodeState extends State<PasteGoogleCode> {
  String? _error;

  Future<void> _paste() async {
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    try {
      if (await GoogleAuth.importCode(t)) {
        widget.onDone();
        return;
      }
      setState(
        () => _error =
            'Je ne trouve pas le code dans ce que tu as copié. Sur le PC : Réglages → Mes appareils → '
            'Ajouter mon iPhone → « M\'envoyer le code par mail », puis copie tout le mail.',
      );
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mon Hub est déjà sur ton PC ?',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sur le PC : Réglages → Mes appareils → « Ajouter mon iPhone » → « M\'envoyer le code par mail ». '
              'Ouvre le mail ici, copie-le, puis appuie sur le bouton.',
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const Icon(Icons.content_paste_rounded),
              label: const Text('Coller le code de mon PC'),
              onPressed: _paste,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}
