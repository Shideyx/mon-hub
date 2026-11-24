import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/google_auth.dart';
import '../core/module_store.dart';
import '../core/updater.dart';
import 'widgets.dart';
import 'phone_setup_page.dart';

/// Activer la connexion Google, **une seule fois, par le créateur** de Mon
/// Hub : 5 liens directs sur Google Cloud (gratuit), puis on choisit le
/// fichier téléchargé. Ensuite, chaque utilisateur se connecte en un clic.
class GoogleSetupPage extends StatefulWidget {
  const GoogleSetupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GoogleSetupPage()));

  /// Les API utiles à Mon Hub, activées d'un seul clic.
  static const apis = 'drive.googleapis.com,docs.googleapis.com,calendar-json.googleapis.com,gmail.googleapis.com';

  static const steps = [
    ('Crée le projet', 'Nom : « Mon Hub » → Créer.', 'https://console.cloud.google.com/projectcreate'),
    (
      'Active les API (un clic)',
      'Vérifie que « Mon Hub » est choisi en haut → Suivant → Activer.',
      'https://console.cloud.google.com/flows/enableapi?apiid=$apis',
    ),
    (
      'Écran de connexion',
      'Commencer → nom « Mon Hub » et ton adresse → Externe → ton adresse → J\'accepte → Créer.',
      'https://console.cloud.google.com/auth/branding',
    ),
    (
      'Publie-le',
      '« Publier l\'application » → Confirmer (sinon la connexion expire tous les 7 jours).',
      'https://console.cloud.google.com/auth/audience',
    ),
    (
      'Crée la clé de l\'appli',
      'Type « Application de bureau » → Créer → « Télécharger le fichier JSON ».',
      'https://console.cloud.google.com/auth/clients/create',
    ),
  ];

  /// Lit l'ID et le secret dans le fichier JSON de Google
  /// ({"installed": {"client_id": …, "client_secret": …}}).
  static (String, String) parseJson(String text) {
    final j = jsonDecode(text);
    if (j is! Map) throw 'Ce fichier n\'est pas une clé Google';
    final c = (j['installed'] ?? j['web'] ?? j) as Map;
    final id = '${c['client_id'] ?? ''}';
    if (!id.endsWith('.apps.googleusercontent.com')) throw 'Ce fichier n\'est pas une clé Google (client_secret….json)';
    return (id, '${c['client_secret'] ?? ''}');
  }

  @override
  State<GoogleSetupPage> createState() => _GoogleSetupPageState();
}

class _GoogleSetupPageState extends State<GoogleSetupPage> {
  final id = TextEditingController(text: GoogleAuth.builtInId.isEmpty ? GoogleAuth.clientId : '');
  final secret = TextEditingController(text: GoogleAuth.builtInId.isEmpty ? GoogleAuth.clientSecret : '');
  bool busy = false;
  String? done;

  Future<void> _connect() async {
    setState(() => busy = true);
    try {
      if (GoogleAuth.builtInId.isEmpty) await GoogleAuth.setClient(id.text, secret.text);
      final email = await GoogleAuth.signIn();
      await (ModuleStore()..bind('drive')).setJson('account', email);
      setState(() => done = email);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickJson() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Clé Google (client_secret….json)', extensions: ['json']),
      ],
    );
    if (f == null) return;
    try {
      final (i, s) = GoogleSetupPage.parseJson(await f.readAsString());
      id.text = i;
      secret.text = s;
      await _connect();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _copy(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontFamily: 'Consolas'),
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Nom'),
          onPressed: () => Clipboard.setData(ClipboardData(text: label)),
        ),
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('Valeur'),
          onPressed: value.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final builtIn = GoogleAuth.builtInId.isNotEmpty;
    final connected = done ?? GoogleAuth.driveAccount;
    var n = 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Connexion Google')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(colors: [Color(0xFF4285F4), Color(0xFF34A853)]),
            ),
            child: Text(
              builtIn
                  ? 'La connexion Google est prête : un clic et c\'est fait. Drive, Google Docs, agenda, Gmail.'
                  : 'À faire une seule fois (5 étapes, gratuit). Mon Hub n\'a aucun serveur : il parle à Google avec '
                        'sa propre clé, que tu crées ici. Ensuite, tout le monde se connecte en un clic.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
          // Nouvel appareil (iPhone) : la clé vient du PC, pas besoin des 5 étapes.
          if (!builtIn && !GoogleAuth.available) ...[
            PasteGoogleCode(
              onDone: () {
                id.text = GoogleAuth.clientId;
                secret.text = GoogleAuth.clientSecret;
                setState(() {});
                _connect();
              },
            ),
            const SizedBox(height: 12),
          ],
          if (connected != null && GoogleAuth.available && GoogleAuth.canWriteDrive(connected))
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: const Color(0xFF23A55A).withValues(alpha: 0.14),
              ),
              child: Text(
                '✅ $connected est connecté. Dis à Smily « range mon Drive » !',
                style: theme.textTheme.titleSmall,
              ),
            )
          else if (builtIn)
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
              icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
              label: Text(busy ? 'Termine dans ton navigateur…' : 'Se connecter avec Google'),
              onPressed: busy ? null : _connect,
            ),
          if (!builtIn) ...[
            // L'appli Google est dans le compte Google, pas sur le PC : sur un
            // nouveau PC, pas besoin de la recréer (Google ne remontre plus un
            // code secret, mais on peut en ajouter un).
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tu as déjà créé l\'appli Google (sur un autre PC) ?',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Ne refais pas les 5 étapes : elle est dans ton compte Google. Ouvre la liste de tes clients '
                      '→ clique sur ton client « Mon Hub » → « Ajouter un code secret » → copie l\'ID client et le '
                      'nouveau code secret, puis colle-les plus bas dans « Ou colle l\'ID et le code secret à la '
                      'main ». Ne désactive pas l\'ancien code : ton autre PC l\'utilise encore.',
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Ouvrir mes clients Google'),
                      onPressed: () => Browser.open('https://console.cloud.google.com/auth/clients'),
                    ),
                  ],
                ),
              ),
            ),
            for (final (title, text, url) in GoogleSetupPage.steps)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    child: Text('${++n}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(text),
                  trailing: FilledButton.tonal(onPressed: () => Browser.open(url), child: const Text('Ouvrir')),
                ),
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.upload_file_rounded),
              label: Text(busy ? 'Termine dans ton navigateur…' : '6. Choisis le fichier téléchargé et connecte-toi'),
              onPressed: busy ? null : _pickJson,
            ),
            const SizedBox(height: 6),
            Text(
              'Google affichera « Google n\'a pas validé cette application » : normal, c\'est la tienne. '
              '« Paramètres avancés » → « Accéder à Mon Hub » → Continuer.',
              style: theme.textTheme.bodySmall,
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Ou colle l\'ID et le code secret à la main'),
              children: [
                TextField(
                  controller: id,
                  decoration: const InputDecoration(labelText: 'ID client (…apps.googleusercontent.com)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: secret,
                  decoration: const InputDecoration(labelText: 'Code secret du client'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: busy ? null : _connect,
                    child: const Text('Enregistrer et me connecter'),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
            if (GoogleAuth.available) ...[
              const Divider(height: 32),
              Text(
                'Pour que tout le monde se connecte en un clic',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'Ajoute ces deux valeurs dans les secrets GitHub de Mon Hub (une fois) : les prochaines versions '
                'auront la connexion Google déjà prête, et chaque utilisateur n\'aura plus qu\'à cliquer '
                '« Se connecter avec Google ».',
              ),
              const SizedBox(height: 8),
              _copy('GOOGLE_CLIENT_ID', GoogleAuth.clientId),
              _copy('GOOGLE_CLIENT_SECRET', GoogleAuth.clientSecret),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Ouvrir les secrets GitHub'),
                  onPressed: () => Browser.open('https://github.com/${Updater.repo}/settings/secrets/actions/new'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
