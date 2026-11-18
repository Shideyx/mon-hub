import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/browser.dart';
import '../core/error_log.dart';
import 'account_sync_view.dart';
import 'backup_page.dart';
import 'security_page.dart';
import 'screen_time_page.dart';
import 'birthdays_page.dart';
import 'phone_setup_page.dart';
import 'google_setup.dart';
import 'tidy_page.dart';
import '../core/google_auth.dart';
import '../core/hub_controller.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../core/shortcuts.dart';
import '../core/updater.dart';
import '../core/vault.dart';
import '../core/version.dart';
import 'clicky/clicky_settings_page.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller, required this.notifications});

  final HubController controller;
  final NotificationCenter notifications;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final name = TextEditingController(text: ModuleStore.prefs.getString('hub.name'));

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final n = widget.notifications;
    final theme = Theme.of(context);
    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        t.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.1,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListenableBuilder(
        listenable: Listenable.merge([c, n, AppSession.instance]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Version de Mon Hub'),
              subtitle: Updater.supported
                  ? const Text('Mises à jour automatiques : Mon Hub se met à jour tout seul.')
                  : null,
              trailing: Text(appVersion, style: Theme.of(context).textTheme.titleMedium),
            ),
            if (Updater.supported)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: TextButton.icon(
                    icon: const Icon(Icons.system_update_alt_rounded),
                    label: const Text('Vérifier les mises à jour'),
                    onPressed: () async {
                      final found = await Updater.instance.check(manual: true);
                      if (found == null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Tu as déjà la dernière version 👍')),
                        );
                      }
                    },
                  ),
                ),
              ),
            section('Profil'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Ton prénom (pour le message d\'accueil)',
                  prefixIcon: Icon(Icons.person_rounded),
                ),
                onChanged: (v) => ModuleStore.prefs.setString('hub.name', v.trim()),
              ),
            ),
            section('Apparence'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_rounded),
                    label: Text('Clair'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_rounded),
                    label: Text('Sombre'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_rounded),
                    label: Text('Auto'),
                  ),
                ],
                selected: {AppSession.instance.themeMode},
                onSelectionChanged: (v) => AppSession.instance.setThemeMode(v.first),
              ),
            ),
            if (Platform.isWindows) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
                child: Text('Ouvrir les liens dans'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'chrome',
                      icon: const Icon(Icons.public_rounded),
                      label: Text(Browser.chromePath() == null ? 'Google Chrome (pas installé)' : 'Google Chrome'),
                    ),
                    const ButtonSegment(
                      value: 'defaut',
                      icon: Icon(Icons.open_in_browser_rounded),
                      label: Text('Navigateur par défaut'),
                    ),
                  ],
                  selected: {Browser.choice},
                  onSelectionChanged: (v) async {
                    await Browser.setChoice(v.first);
                    setState(() {});
                  },
                ),
              ),
            ],
            section('Google'),
            ListTile(
              leading: const Icon(Icons.g_mobiledata_rounded, size: 32),
              title: const Text('Connexion Google'),
              subtitle: Text(
                !GoogleAuth.available
                    ? 'À activer une fois (5 min) : Drive, Google Docs, agenda, Gmail'
                    : GoogleAuth.driveAccount == null
                        ? 'Activée : connecte ton compte'
                        : 'Compte : ${GoogleAuth.driveAccount}',
              ),
              onTap: () => GoogleSetupPage.open(context).then((_) => setState(() {})),
            ),
            section('Sauvegarde'),
            ListTile(
              leading: const Icon(Icons.cloud_done_rounded),
              title: const Text('Sauvegarde de mes travaux'),
              subtitle: const Text('Documents et Bureau copiés tout seuls dans ton Google Drive'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => WorkBackupPage.open(context),
            ),
            section('Rangement'),
            ListTile(
              leading: const Icon(Icons.auto_fix_high_rounded),
              title: const Text('Ranger mon PC et mon Drive'),
              subtitle: const Text('Téléchargements, Bureau, Documents, Google Drive : par type et par matière, annulable'),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TidyPage())),
            ),
            section('Compte'),
            ListTile(
              leading: const Icon(Icons.account_circle_rounded),
              title: Text(AppSession.instance.current?.name ?? ''),
              subtitle: Text('@${AppSession.instance.current?.login ?? ''}'),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Se déconnecter'),
              subtitle: const Text('Tes données restent sur l\'appareil'),
              onTap: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
                AppSession.instance.signOut();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
              title: Text('Supprimer mon compte', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Supprimer ton compte ?'),
                    content: const Text(
                      'Tes réglages, livres, évènements et connexions '
                      'seront effacés de cet appareil.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(d, false),
                        child: const Text('Annuler'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('Supprimer'),
                      ),
                    ],
                  ),
                );
                if (ok != true || !context.mounted) return;
                Navigator.of(context).popUntil((r) => r.isFirst);
                await AppSession.instance.deleteAccount();
              },
            ),
            section('Notifications'),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Vérifier toutes les'),
              trailing: DropdownButton<int>(
                value: n.interval,
                underline: const SizedBox.shrink(),
                items: const [
                  1,
                  2,
                  5,
                  10,
                  15,
                  30,
                ].map((v) => DropdownMenuItem(value: v, child: Text('$v min'))).toList(),
                onChanged: (v) => n.interval = v ?? 2,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.layers_rounded),
              title: const Text('Regrouper les notifications'),
              subtitle: const Text('Un seul résumé au lieu de 15 notifications d\'affilée (les appels passent toujours)'),
              trailing: DropdownButton<int>(
                value: n.digest,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Non')),
                  DropdownMenuItem(value: 15, child: Text('15 min')),
                  DropdownMenuItem(value: 30, child: Text('30 min')),
                  DropdownMenuItem(value: 60, child: Text('1 h')),
                ],
                onChanged: (v) => n.digest = v ?? 30,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Tester une alerte'),
              onTap: () => n.show(
                HubNotification(
                  id: 'test${DateTime.now().millisecondsSinceEpoch}',
                  title: 'Mon Hub',
                  body: 'Les alertes fonctionnent 🎉',
                ),
              ),
            ),
            section('Modules'),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Glisse ⠿ pour changer l\'ordre. Interrupteur = afficher le module. '
                'Cloche = recevoir ses alertes.',
              ),
            ),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: c.ordered.length,
              onReorderItem: c.reorder,
              itemBuilder: (context, i) {
                final m = c.ordered[i];
                return ListTile(
                  key: ValueKey(m.id),
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.drag_indicator_rounded),
                        const SizedBox(width: 8),
                        HubAvatar(label: m.name, color: m.color, size: 34),
                      ],
                    ),
                  ),
                  title: Text(m.name),
                  subtitle: Text(m.access.label),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Alertes',
                        icon: Icon(
                          n.isMuted(m.id)
                              ? Icons.notifications_off_outlined
                              : Icons.notifications_active_rounded,
                        ),
                        onPressed: () => n.setMuted(m.id, !n.isMuted(m.id)),
                      ),
                      Switch(value: c.isEnabled(m), onChanged: (v) => c.setEnabled(m, v)),
                    ],
                  ),
                );
              },
            ),
            section('Clicky'),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x227C5CFF),
                child: Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
              ),
              title: const Text('Réglages de Clicky'),
              subtitle: const Text(
                'Tout au même endroit : voix, micro, cerveau, apparence, prend les devants, écouter un cours…',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => ClickySettingsPage.open(context),
            ),
            if (AppShortcuts.supported) ...[
              section('Raccourcis'),
              ListTile(
                leading: const Icon(Icons.shortcut_rounded),
                title: Text(
                  Platform.isWindows
                      ? 'Recréer les raccourcis (Bureau et menu Démarrer)'
                      : 'Recréer le raccourci du menu des applications',
                ),
                subtitle: const Text('Ils sont créés tout seuls au premier lancement'),
                onTap: () async {
                  final ok = await AppShortcuts.create();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok
                              ? 'Raccourcis créés ✅'
                              : 'Impossible de créer les raccourcis sur ce PC',
                        ),
                      ),
                    );
                  }
                },
              ),
              if (Platform.isWindows)
                StatefulBuilder(
                  builder: (context, setState) => SwitchListTile(
                    secondary: const Icon(Icons.power_settings_new_rounded),
                    title: const Text('Lancer Mon Hub au démarrage de Windows'),
                    subtitle: const Text('Pratique pour avoir Clicky et les alertes tout de suite'),
                    value: AppShortcuts.startup,
                    onChanged: (v) async {
                      await AppShortcuts.setStartup(v);
                      setState(() {});
                    },
                  ),
                ),
            ],
            section('Bien-être'),
            ListTile(
              leading: const Icon(Icons.hourglass_bottom_rounded, color: Color(0xFF5B5BD6)),
              title: const Text('Temps d\'écran et sommeil'),
              subtitle: const Text('Temps par appli, limites douces, heure du coucher, mode jeu'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => ScreenTimePage.open(context),
            ),
            ListTile(
              leading: const Icon(Icons.cake_rounded, color: Color(0xFFE5487B)),
              title: const Text('Anniversaires des proches'),
              subtitle: const Text('Google Agenda + ceux que tu ajoutes, rappel la veille et le jour même'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => BirthdaysPage.open(context),
            ),
            section('Confidentialité et sécurité'),
            ListTile(
              leading: const Icon(Icons.verified_user_rounded, color: Colors.green),
              title: const Text('Bilan de sécurité'),
              subtitle: const Text('Antivirus, pare-feu, mises à jour, double authentification, bouclier anti-arnaque'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => SecurityPage.open(context),
            ),
            const ListTile(
              leading: Icon(Icons.lock_rounded),
              title: Text('Tout reste sur cet appareil'),
              subtitle: Text(
                'Mon Hub n\'a aucun serveur : personne d\'autre que toi (ni le créateur de l\'appli) '
                'ne voit tes comptes, messages, notes ou conversations. Mots de passe et jetons sont '
                'dans le coffre du système (Gestionnaire d\'identification Windows, Trousseau, '
                'Keystore Android) ; historiques, journal, carnet et routines sont chiffrés '
                '(AES-256) avec une clé qui ne quitte pas l\'appareil. Si tu actives « Mon compte sur '
                'tous mes appareils », une copie chiffrée avec ton mot de passe va dans ton propre '
                'Google Drive (illisible pour Google).',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.public_rounded),
              title: Text('Ce qui part sur internet'),
              subtitle: Text(
                'Seulement vers le service concerné, directement depuis ton appareil : École Directe, '
                'Spotify, Google, Discord, Instagram, ta boîte mail… ; ce que tu demandes à Clicky va à '
                'Claude (ton compte Anthropic) ; la voix neurale à Microsoft. Les mises à jour viennent '
                'de GitHub, qui ne reçoit rien de toi.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_rounded),
              title: const Text('Journal des erreurs'),
              subtitle: const Text('Ce qui a planté (gardé sur ce PC uniquement) : utile pour corriger un souci.'),
              onTap: () => _errors(context),
            ),
            section('Mes appareils'),
            // Le compte sur tous tes appareils, sans export (Google Drive).
            const AccountSyncSection(),
            if (Platform.isWindows)
              ListTile(
                leading: const Icon(Icons.phone_iphone_rounded),
                title: const Text('Ajouter mon iPhone'),
                subtitle: const Text('Mon Hub sur l\'iPhone, synchronisé avec ce PC'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => PhoneSetupPage.open(context),
              ),
            ExpansionTile(
              leading: const Icon(Icons.folder_zip_rounded),
              title: const Text('Sans internet : passer par un fichier'),
              subtitle: const Text('Exporter / importer (clé USB…)'),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Le fichier est chiffré avec un mot de passe que tu choisis : sans lui, il est illisible.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.upload_file_rounded),
                  title: const Text('Exporter ma configuration'),
                  onTap: () => _export(context),
                ),
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Importer une configuration'),
                  onTap: () => _import(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _dump() async {
    final prefs = ModuleStore.prefs;
    final data = <String, Object?>{
      for (final k in prefs.getKeys())
        if (k.startsWith('mod.') ||
            k.startsWith('hub.') ||
            k == 'notif.muted' ||
            k == 'notif.interval')
          k: prefs.get(k),
    };
    final secrets = await ModuleStore.readAllSecrets();
    return const JsonEncoder.withIndent(' ').convert({
      'app': 'mon-hub',
      'version': 1,
      'prefs': data,
      'secrets': {
        for (final e in secrets.entries)
          if (e.key.startsWith('mod.')) e.key: e.value,
      },
    });
  }

  static Future<void> _errors(BuildContext context) => showDialog<void>(
    context: context,
    builder: (c) {
      final log = ErrorLog.read();
      return AlertDialog(
        title: const Text('Journal des erreurs'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: log.isEmpty
              ? const Center(child: Text('Aucune erreur notée. 🎉'))
              : SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(log, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
                ),
        ),
        actions: [
          if (log.isNotEmpty)
            TextButton(
              onPressed: () {
                ErrorLog.clear();
                Navigator.pop(c);
              },
              child: const Text('Vider'),
            ),
          if (log.isNotEmpty)
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: log.length > 20000 ? log.substring(log.length - 20000) : log)),
              child: const Text('Copier'),
            ),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
        ],
      );
    },
  );

  /// Mot de passe de l'export (deux fois à la création).
  static Future<String?> _password(BuildContext context, {required bool create}) async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          icon: const Icon(Icons.lock_rounded),
          title: Text(create ? 'Protéger l\'export' : 'Mot de passe de l\'export'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (create)
                const Text(
                  'Choisis un mot de passe : il sera demandé pour importer le fichier. '
                  'Mon Hub ne peut pas le retrouver si tu l\'oublies.',
                ),
              TextField(
                controller: a,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Mot de passe'),
              ),
              if (create)
                TextField(
                  controller: b,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Encore une fois'),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                if (create && a.text.length < 8) {
                  return set(() => error = 'Au moins 8 caractères.');
                }
                if (create && a.text != b.text) {
                  return set(() => error = 'Les deux mots de passe sont différents.');
                }
                Navigator.pop(c, a.text);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final pass = await _password(context, create: true);
    if (pass == null || !context.mounted) return;
    final json = const JsonEncoder.withIndent(' ').convert({
      'app': 'mon-hub',
      'version': 2,
      'protege': await Vault.protect(await _dump(), pass),
    });
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Clipboard.setData(ClipboardData(text: json));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Configuration copiée dans le presse-papiers')),
          );
        }
        return;
      }
      final loc = await getSaveLocation(suggestedName: 'mon-hub-config.json');
      if (loc == null) return;
      await File(loc.path).writeAsString(json);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Exporté vers ${loc.path}')));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _import(BuildContext context) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Config Mon Hub', extensions: ['json']),
        ],
      );
      if (file == null) return;
      var j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (j['app'] != 'mon-hub') throw 'Ce fichier n\'est pas une configuration Mon Hub';
      if (j['protege'] is Map) {
        if (!context.mounted) return;
        final pass = await _password(context, create: false);
        if (pass == null) return;
        j = jsonDecode(await Vault.unprotect((j['protege'] as Map).cast<String, dynamic>(), pass))
            as Map<String, dynamic>;
      }
      final prefs = ModuleStore.prefs;
      for (final e in (j['prefs'] as Map<String, dynamic>).entries) {
        final v = e.value;
        if (v is String) await prefs.setString(e.key, v);
        if (v is int) await prefs.setInt(e.key, v);
        if (v is bool) await prefs.setBool(e.key, v);
        if (v is List) await prefs.setStringList(e.key, v.cast<String>());
      }
      for (final e in (j['secrets'] as Map<String, dynamic>).entries) {
        await ModuleStore.writeSecretRaw(e.key, e.value as String);
      }
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Configuration importée'),
            content: const Text('Redémarre l\'appli pour que tout soit pris en compte.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
