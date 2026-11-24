import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/online/online.dart';
import 'online/online_page.dart';

import '../core/browser.dart';
import '../core/error_log.dart';
import '../core/install.dart';
import '../modules/instagram/instagram_watch.dart';
import 'phone_link_page.dart';
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
import '../core/perf.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../core/shortcuts.dart';
import '../core/updater.dart';
import '../core/vault.dart';
import '../core/version.dart';
import 'clicky/clicky_settings_page.dart';
import 'clicky/life_view.dart' show emojiFonts;
import 'clicky/skills.dart';
import 'clicky/tutorial.dart';
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
  final search = TextEditingController();
  String q = '';

  @override
  void dispose() {
    name.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final n = widget.notifications;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListenableBuilder(
        listenable: Listenable.merge([c, n, AppSession.instance]),
        builder: (context, _) {
          final cats = SettingsCategory.find(q).where((k) => k.id != 'demarrage' || AppShortcuts.supported).toList();
          final showClicky = SettingsCategory.clickyMatches(q);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  TextField(
                    controller: search,
                    onChanged: (v) => setState(() => q = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Chercher un réglage (thème, téléphone, notifications…)',
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                      suffixIcon: q.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() {
                                search.clear();
                                q = '';
                              }),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (showClicky) const _ClickyHero(),
                  if (cats.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
                      child: Text(
                        'MON HUB',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  for (final k in cats)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: k.color.withValues(alpha: 0.14),
                          child: Text(k.emoji, style: const TextStyle(fontSize: 20, fontFamilyFallback: emojiFonts)),
                        ),
                        title: Text(k.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(k.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _SettingsSection.open(
                          context,
                          title: '${k.emoji} ${k.title}',
                          listenable: Listenable.merge([c, n, AppSession.instance]),
                          build: (ctx, refresh) => _content(k.id, ctx, refresh),
                        ),
                      ),
                    ),
                  if (!showClicky && cats.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Rien trouvé : essaie un autre mot.')),
                    ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Mon Hub $appVersion${Updater.supported ? ' · se met à jour tout seul' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Le contenu d'une rubrique ([refresh] : redessiner sa page).
  List<Widget> _content(String id, BuildContext context, VoidCallback refresh) {
    final c = widget.controller;
    final n = widget.notifications;
    final theme = Theme.of(context);
    return switch (id) {
      'compte' => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Ton prénom',
              helperText: 'Pour l\'accueil, et c\'est comme ça que Nexo t\'appelle (sauf si tu lui donnes un surnom).',
              prefixIcon: Icon(Icons.person_rounded),
            ),
            onChanged: (v) => ModuleStore.prefs.setString('hub.name', v.trim()),
          ),
        ),
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
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Tu as déjà la dernière version 👍')));
                  }
                },
              ),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.account_circle_rounded),
          title: Text(AppSession.instance.current?.name ?? ''),
          subtitle: Text('@${AppSession.instance.current?.login ?? ''}'),
        ),
        ListTile(
          leading: const Icon(Icons.logout_rounded),
          title: const Text('Se déconnecter'),
          subtitle: const Text('Tes données restent sur l\'appareil'),
          // Avant : un seul clic par erreur et on était déconnecté.
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                title: const Text('Te déconnecter ?'),
                content: const Text('Tes données restent sur l\'appareil : tu les retrouves en te reconnectant.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Annuler')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Me déconnecter')),
                ],
              ),
            );
            if (ok != true || !context.mounted) return;
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
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Annuler')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
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
      ],
      'apparence' => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: Text('Clair')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('Sombre')),
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded), label: Text('Auto')),
            ],
            selected: {AppSession.instance.themeMode},
            onSelectionChanged: (v) => AppSession.instance.setThemeMode(v.first),
          ),
        ),
        if (Platform.isWindows) ...[
          const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 6), child: Text('Ouvrir les liens dans')),
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
                refresh();
              },
            ),
          ),
        ],
      ],
      'notifs' => [
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Vérifier toutes les'),
          subtitle: const Text('Discord et Instagram arrivent tout de suite, sans attendre'),
          trailing: DropdownButton<int>(
            // Une valeur hors de la liste faisait planter la page.
            value: const [1, 2, 5, 10, 15, 30].contains(n.interval) ? n.interval : 2,
            underline: const SizedBox.shrink(),
            items: const [1, 2, 5, 10, 15, 30].map((v) => DropdownMenuItem(value: v, child: Text('$v min'))).toList(),
            onChanged: (v) => n.interval = v ?? 2,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.layers_rounded),
          title: const Text('Regrouper les notifications'),
          subtitle: const Text('Un seul résumé au lieu de 15 notifications d\'affilée (les appels passent toujours)'),
          trailing: DropdownButton<int>(
            value: const [0, 15, 30, 60].contains(n.digest) ? n.digest : 30,
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
        if (InstagramWatch.supported)
          SwitchListTile(
            secondary: const Icon(Icons.camera_alt_rounded),
            title: const Text('Messages Instagram en direct'),
            subtitle: const Text(
              'Le vrai Instagram reste ouvert en fond, comme un onglet : tu es prévenu dès qu\'on t\'écrit. '
              'Rien n\'est demandé à Instagram (aucun risque pour ton compte).',
            ),
            value: InstagramWatch.wanted,
            onChanged: (v) async {
              await InstagramWatch.setWanted(v);
              refresh();
            },
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
      ],
      'modules' => [
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
                    icon: Icon(n.isMuted(m.id) ? Icons.notifications_off_outlined : Icons.notifications_active_rounded),
                    onPressed: () => n.setMuted(m.id, !n.isMuted(m.id)),
                  ),
                  Switch(value: c.isEnabled(m), onChanged: (v) => c.setEnabled(m, v)),
                ],
              ),
            );
          },
        ),
      ],
      'enligne' => [
        ListTile(
          leading: const Icon(Icons.cloud_rounded),
          title: const Text('Compte en ligne'),
          subtitle: Text(
            Online.instance.signedIn
                ? 'Connecté : ${Online.instance.email}. Ton compte est le même sur tous tes appareils.'
                : Online.instance.configured
                ? 'Mets ton compte en ligne pour le retrouver partout et partager des espaces.'
                : 'Règle ton serveur (5 minutes, une fois) pour partager des espaces avec tes amis.',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            await OnlinePage.open(context);
            refresh();
          },
        ),
      ],
      'appareils' => [
        // Le compte sur tous tes appareils, sans export (Google Drive).
        const AccountSyncSection(),
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ListTile(
            leading: const Icon(Icons.devices_rounded),
            title: const Text('Mon téléphone'),
            subtitle: const Text('Fichiers, presse-papier et télécommande du PC, par le Wi-Fi'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => PhoneLinkPage.open(context),
          ),
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
              child: Text('Le fichier est chiffré avec un mot de passe que tu choisis : sans lui, il est illisible.'),
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
      'google' => [
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
          onTap: () => GoogleSetupPage.open(context).then((_) => refresh()),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_done_rounded),
          title: const Text('Sauvegarde de mes travaux'),
          subtitle: const Text('Documents et Bureau copiés tout seuls dans ton Google Drive'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => WorkBackupPage.open(context),
        ),
        ListTile(
          leading: const Icon(Icons.auto_fix_high_rounded),
          title: const Text('Ranger mon PC et mon Drive'),
          subtitle: const Text('Téléchargements, Bureau, Documents, Google Drive : par type et par matière, annulable'),
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TidyPage())),
        ),
      ],
      'bienetre' => [
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
      ],
      'securite' => [
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
            'Spotify, Google, Discord, Instagram, ta boîte mail… ; ce que tu demandes à Nexo va à '
            'Claude (ton compte Anthropic) ou à Gemini (ta clé Google), et sa voix aussi à Gemini. Les mises à jour viennent '
            'de GitHub, qui ne reçoit rien de toi.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_rounded),
          title: const Text('Journal des erreurs'),
          subtitle: const Text('Ce qui a planté (gardé sur ce PC uniquement) : utile pour corriger un souci.'),
          onTap: () => _errors(context),
        ),
      ],
      'vitesse' => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Mon Hub regarde la puissance de ton PC et s\'adapte. En mode léger, Nexo reste dans la '
            'fenêtre de Mon Hub (pas de second programme) et tout ce qui surveille en continu se fait '
            'plus rarement.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        StatefulBuilder(
          builder: (context, setState) {
            Widget choice(String value, String title, String subtitle) {
              final on = Perf.choice == value;
              return ListTile(
                leading: Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                title: Text(title),
                subtitle: Text(subtitle),
                selected: on,
                onTap: () async {
                  await Perf.setChoice(value);
                  setState(() {});
                },
              );
            }

            return Column(
              children: [
                choice(
                  'auto',
                  'Automatique (conseillé)',
                  Perf.light
                      ? 'Ton PC est modeste : mode léger activé.'
                      : 'Ton PC suit sans problème : tout est allumé.',
                ),
                choice('leger', 'Toujours léger', 'À choisir si l\'appli rame ou chauffe.'),
                choice(
                  'complet',
                  'Toujours complet',
                  'Nexo partout, ses yeux et ses oreilles, sauvegarde en continu.',
                ),
                ListTile(
                  leading: const Icon(Icons.speed_rounded),
                  title: Text(Perf.explain),
                  subtitle: const Text('Après un changement de mode, Mon Hub redémarre pour que tout reparte au bon rythme.'),
                ),
                // Avant : « redémarre Mon Hub » sans bouton pour le faire.
                if (AppInstall.canRestart)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: FilledButton.icon(
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: const Text('Redémarrer Mon Hub maintenant'),
                        onPressed: AppInstall.restart,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
      'demarrage' => [
        if (AppShortcuts.supported) ...[
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
                  SnackBar(content: Text(ok ? 'Raccourcis créés ✅' : 'Impossible de créer les raccourcis sur ce PC')),
                );
              }
            },
          ),
          if (Platform.isWindows)
            StatefulBuilder(
              builder: (context, setState) => SwitchListTile(
                secondary: const Icon(Icons.power_settings_new_rounded),
                title: const Text('Lancer Mon Hub au démarrage de Windows'),
                subtitle: const Text('Pratique pour avoir Nexo et les alertes tout de suite'),
                value: AppShortcuts.startup,
                onChanged: (v) async {
                  await AppShortcuts.setStartup(v);
                  setState(() {});
                },
              ),
            ),
        ],
      ],
      _ => const <Widget>[],
    };
  }

  Future<String> _dump() async {
    final prefs = ModuleStore.prefs;
    final data = <String, Object?>{
      for (final k in prefs.getKeys())
        if (k.startsWith('mod.') || k.startsWith('hub.') || k == 'notif.muted' || k == 'notif.interval')
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
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: log.length > 20000 ? log.substring(log.length - 20000) : log)),
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
    final json = const JsonEncoder.withIndent(' ')
        .convert({'app': 'mon-hub', 'version': 2, 'protege': await Vault.protect(await _dump(), pass)});
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Clipboard.setData(ClipboardData(text: json));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Configuration copiée dans le presse-papiers')));
        }
        return;
      }
      final loc = await getSaveLocation(suggestedName: 'mon-hub-config.json');
      if (loc == null) return;
      await File(loc.path).writeAsString(json);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exporté vers ${loc.path}')));
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
        j = jsonDecode(
          await Vault.unprotect((j['protege'] as Map).cast<String, dynamic>(), pass),
        ) as Map<String, dynamic>;
      }
      final prefs = ModuleStore.prefs;
      for (final e in (j['prefs'] as Map<String, dynamic>).entries) {
        final v = e.value;
        if (v is String) await prefs.setString(e.key, v);
        if (v is int) await prefs.setInt(e.key, v);
        // Les nombres à virgule (vitesse de la voix…) étaient perdus à l'import.
        if (v is double) await prefs.setDouble(e.key, v);
        if (v is bool) await prefs.setBool(e.key, v);
        if (v is List) await prefs.setStringList(e.key, [for (final x in v) '$x']);
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

/// Une rubrique des réglages de Mon Hub.
class SettingsCategory {
  const SettingsCategory(this.id, this.emoji, this.title, this.subtitle, this.color, this.keywords);
  final String id;
  final String emoji;
  final String title;
  final String subtitle;
  final Color color;

  /// Mots qui la font trouver dans la recherche.
  final String keywords;

  static const all = [
    SettingsCategory(
      'compte',
      '👤',
      'Mon compte',
      'Ton prénom, la version et les mises à jour, se déconnecter',
      Color(0xFF7C5CFF),
      'prenom nom profil version mise a jour deconnexion supprimer compte',
    ),
    SettingsCategory(
      'apparence',
      '🎨',
      'Apparence',
      'Clair ou sombre, le navigateur pour les liens',
      Color(0xFFE5487B),
      'theme sombre clair couleur navigateur chrome lien',
    ),
    SettingsCategory(
      'notifs',
      '🔔',
      'Notifications',
      'Toutes les combien, les regrouper, tester une alerte',
      Color(0xFFF59E0B),
      'alerte alertes notification notifications regrouper resume tester',
    ),
    SettingsCategory(
      'modules',
      '🧩',
      'Mes modules',
      'Afficher, cacher et ranger les cartes de l\'accueil',
      Color(0xFF2B6CFF),
      'module modules carte cartes ordre afficher cacher accueil',
    ),
    SettingsCategory(
      'enligne',
      '🌐',
      'Compte en ligne et espaces',
      'Même compte partout, espaces partagés, discussions, ton @pseudo',
      Color(0xFF7C5CFF),
      'en ligne supabase serveur compte adresse mail email espace espaces partage partager amis equipe entreprise discussion chat message pseudo android iphone',
    ),
    SettingsCategory(
      'appareils',
      '📱',
      'Mes appareils',
      'Ton compte sur tous tes appareils, ton téléphone, ton iPhone',
      Color(0xFF0EA5E9),
      'telephone iphone synchro synchronisation appareils export import fichier usb pc principal',
    ),
    SettingsCategory(
      'google',
      '☁️',
      'Google, sauvegarde et rangement',
      'Connexion Google, sauvegarde de tes travaux, ranger ton PC',
      Color(0xFF16A34A),
      'google drive docs agenda gmail sauvegarde ranger rangement telechargements',
    ),
    SettingsCategory(
      'bienetre',
      '🌙',
      'Bien-être',
      'Temps d\'écran, heure du coucher, mode jeu, anniversaires',
      Color(0xFF5B5BD6),
      'temps ecran sommeil coucher anniversaire anniversaires limite jeu habitudes',
    ),
    SettingsCategory(
      'securite',
      '🛡️',
      'Sécurité et vie privée',
      'Bilan de sécurité, ce qui reste sur ton PC, journal des erreurs',
      Color(0xFF16A34A),
      'securite antivirus arnaque confidentialite vie privee erreurs journal donnees',
    ),
    SettingsCategory(
      'vitesse',
      '⚡',
      'Vitesse de l\'appli',
      'Mode léger pour les PC modestes : tout reste fluide',
      Color(0xFFF59E0B),
      'vitesse lent lenteur rame rapide fluide leger performance ram memoire processeur clicky partout',
    ),
    SettingsCategory(
      'demarrage',
      '⌨️',
      'Démarrage et raccourcis',
      'Lancer Mon Hub avec Windows, raccourcis du Bureau',
      Color(0xFF64748B),
      'demarrage windows raccourci raccourcis bureau menu demarrer lancer',
    ),
  ];

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  static List<String> _words(String q) => _plain(q).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length >= 2).toList();

  /// Les rubriques qui parlent de [q] (toutes si [q] est vide).
  static List<SettingsCategory> find(String q) {
    final ws = _words(q);
    if (ws.isEmpty) return all;
    return [
      for (final k in all)
        if (ws.every((w) => _plain('${k.title} ${k.subtitle} ${k.keywords}').contains(w))) k,
    ];
  }

  /// La carte de Nexo correspond-elle à [q] ?
  static bool clickyMatches(String q) {
    final ws = _words(q);
    return ws.isEmpty ||
        ws.every(
          (w) => 'clicky assistant voix micro cerveau claude gemini ecran yeux oreilles visite tuto tutoriel aide sait faire'
              .contains(w),
        );
  }
}

/// La carte de Nexo, en tête des réglages : ses réglages, tout ce qu'il
/// sait faire, et la visite guidée.
class _ClickyHero extends StatelessWidget {
  const _ClickyHero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ButtonStyle white() =>
        FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF5B3FD9));
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(colors: [Color(0xFF7C5CFF), Color(0xFF2B6CFF)]),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🤖', style: TextStyle(fontSize: 34, fontFamilyFallback: emojiFonts)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nexo',
                      style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                    const Text(
                      'Sa voix, son micro, son cerveau, ses yeux et ses oreilles, ce qu\'il fait tout seul…',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: white(),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Réglages de Nexo'),
                onPressed: () => ClickySettingsPage.open(context),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('Ce qu\'il sait faire'),
                onPressed: () => ClickySkillsPage.open(context),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                icon: const Icon(Icons.slideshow_rounded),
                label: const Text('Revoir la visite guidée'),
                onPressed: () => ClickyTutorial.show(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Une rubrique des réglages, sur sa propre page.
class _SettingsSection extends StatefulWidget {
  const _SettingsSection({required this.title, required this.listenable, required this.build});
  final String title;
  final Listenable listenable;
  final List<Widget> Function(BuildContext context, VoidCallback refresh) build;

  static Future<void> open(
    BuildContext context, {
    required String title,
    required Listenable listenable,
    required List<Widget> Function(BuildContext context, VoidCallback refresh) build,
  }) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => _SettingsSection(title: title, listenable: listenable, build: build),
    ),
  );

  @override
  State<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<_SettingsSection> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListenableBuilder(
      listenable: widget.listenable,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: widget.build(context, () {
              if (mounted) setState(() {});
            }),
          ),
        ),
      ),
    ),
  );
}
