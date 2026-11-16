import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/hub_controller.dart';
import '../core/module_store.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../core/shortcuts.dart';
import '../core/version.dart';
import '../modules/claude/claude_module.dart';
import 'clicky/clicky.dart';
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
              trailing: Text(appVersion, style: Theme.of(context).textTheme.titleMedium),
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
            ListenableBuilder(
              listenable: ClickyController.instance,
              builder: (context, _) {
                final c = ClickyController.instance;
                return Column(
                  children: [
                    SwitchListTile(
                      secondary: Icon(c.voice ? Icons.volume_up_rounded : Icons.volume_off_rounded),
                      title: const Text('Voix de Clicky'),
                      subtitle: const Text(
                        'Désactivée : Clicky répond seulement par écrit, sans parler',
                      ),
                      value: c.voice,
                      onChanged: (v) async {
                        if (!v) await c.stopSpeaking();
                        await c.setOption('voice', v);
                      },
                    ),
                    SwitchListTile(
                      secondary: Icon(c.mic ? Icons.mic_rounded : Icons.mic_off_rounded),
                      title: const Text('Parler à Clicky au micro'),
                      subtitle: const Text('Désactivé : Ctrl + Alt ouvre la zone pour écrire'),
                      value: c.mic,
                      onChanged: (v) => c.setOption('mic', v),
                    ),
                    ListTile(
                      leading: const Icon(Icons.auto_awesome_rounded),
                      title: const Text('Autres réglages de Clicky'),
                      subtitle: const Text('Cerveau (Claude ou Ollama), Clicky partout…'),
                      onTap: () => ClaudeModule.showSettings(context),
                    ),
                  ],
                );
              },
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
            section('Mes appareils'),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Configure tes comptes une fois (sur ton PC par exemple), exporte, puis '
                'importe le fichier sur ton téléphone. ⚠️ Le fichier contient tes mots de passe '
                'et jetons : garde-le pour toi et supprime-le après import.',
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

  Future<void> _export(BuildContext context) async {
    final json = await _dump();
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
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (j['app'] != 'mon-hub') throw 'Ce fichier n\'est pas une configuration Mon Hub';
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
