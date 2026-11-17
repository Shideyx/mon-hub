import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/google_auth.dart';
import '../core/module_store.dart';
import 'widgets.dart';

/// Activer la connexion Google (une seule fois) : Mon Hub n'a pas de
/// serveur, donc il utilise TON « identifiant client » Google, créé
/// gratuitement en 5 minutes sur console.cloud.google.com.
class GoogleSetupPage extends StatefulWidget {
  const GoogleSetupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const GoogleSetupPage()));

  @override
  State<GoogleSetupPage> createState() => _GoogleSetupPageState();
}

class _GoogleSetupPageState extends State<GoogleSetupPage> {
  final id = TextEditingController(text: GoogleAuth.builtInId.isEmpty ? GoogleAuth.clientId : '');
  final secret = TextEditingController(text: GoogleAuth.builtInId.isEmpty ? GoogleAuth.clientSecret : '');
  bool busy = false;
  String? done;

  static const steps = [
    (
      'Crée un projet « Mon Hub »',
      'Sur Google Cloud (gratuit, avec ton compte Google).',
      'https://console.cloud.google.com/projectcreate',
    ),
    (
      'Active les API Drive, Agenda et Gmail',
      'Ouvre chaque lien et clique sur « Activer ».',
      'https://console.cloud.google.com/apis/library/drive.googleapis.com',
    ),
    (
      'Agenda',
      '',
      'https://console.cloud.google.com/apis/library/calendar-json.googleapis.com',
    ),
    (
      'Gmail',
      '',
      'https://console.cloud.google.com/apis/library/gmail.googleapis.com',
    ),
    (
      'Écran de connexion',
      '« Commencer » : nom « Mon Hub », ton adresse, public « Externe ». Puis dans « Audience », '
          'clique « Publier l\'application » (sinon la connexion expire tous les 7 jours).',
      'https://console.cloud.google.com/auth/overview',
    ),
    (
      'Crée l\'identifiant client',
      'Type d\'application : « Application de bureau », nom « Mon Hub ». Copie l\'ID client et le code '
          'secret, puis colle-les ci-dessous.',
      'https://console.cloud.google.com/auth/clients/create',
    ),
  ];

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      await GoogleAuth.setClient(id.text, secret.text);
      final email = await GoogleAuth.signIn();
      await (ModuleStore()..bind('drive')).setJson('account', email);
      setState(() => done = email);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final builtIn = GoogleAuth.builtInId.isNotEmpty;
    var n = 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Activer la connexion Google')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(colors: [Color(0xFF4285F4), Color(0xFF34A853)]),
            ),
            child: const Text(
              'Mon Hub n\'a aucun serveur : pour parler à Google (Drive, Docs, agenda, Gmail), il utilise ton propre '
              '« identifiant client », gratuit. Ça se fait une seule fois, en 5 minutes, puis Clicky pourra ranger '
              'ton Drive et ouvrir tes Google Docs.',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, height: 1.4),
            ),
          ),
          if (builtIn) ...[
            const SizedBox(height: 16),
            const Text('✅ La connexion Google est déjà activée dans cette version de Mon Hub.'),
          ] else ...[
            const SizedBox(height: 16),
            for (final (title, text, url) in steps)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: text.isEmpty
                      ? const SizedBox(width: 32)
                      : CircleAvatar(radius: 16, child: Text('${++n}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: text.isEmpty ? null : Text(text),
                  trailing: FilledButton.tonal(onPressed: () => Browser.open(url), child: const Text('Ouvrir')),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: id,
              decoration: const InputDecoration(labelText: 'ID client (…apps.googleusercontent.com)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: secret,
              decoration: InputDecoration(
                labelText: 'Code secret du client',
                suffixIcon: IconButton(
                  tooltip: 'Coller',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final t = (await Clipboard.getData('text/plain'))?.text ?? '';
                    secret.text = t.trim();
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.login_rounded),
              label: Text(busy ? 'Termine dans ton navigateur…' : 'Enregistrer et me connecter'),
              onPressed: busy ? null : _save,
            ),
            const SizedBox(height: 8),
            Text(
              'Google affichera « Google n\'a pas validé cette application » : c\'est normal, c\'est la tienne. '
              'Clique sur « Paramètres avancés » puis « Accéder à Mon Hub ».',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (done != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: const Color(0xFF23A55A).withValues(alpha: 0.14),
              ),
              child: Text('✅ $done est connecté. Dis à Clicky « range mon Drive » !', style: theme.textTheme.titleSmall),
            ),
          ],
        ],
      ),
    );
  }
}
