import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../chat_history.dart';
import '../widgets.dart';
import 'capture.dart';
import 'clicky.dart';
import 'extensions.dart';
import 'journal.dart';
import 'tutorial.dart';
import 'voice.dart';
import 'wake.dart';
import 'win.dart';

/// Réglages de Clicky (apparence, voix, écoute, prof, vie privée,
/// outils), affichés sous le choix du cerveau.
class ClickyMoreSettings extends StatelessWidget {
  const ClickyMoreSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ClickyController.instance;
    final text = Theme.of(context).textTheme;
    Widget head(String t, IconData i) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Row(
        children: [
          Icon(i, size: 20),
          const SizedBox(width: 8),
          Text(t, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
    Widget sw(String key, bool value, String title, [String? sub]) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: sub == null ? null : Text(sub),
      value: value,
      onChanged: (v) => c.setOption(key, v),
    );
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head('Apparence', Icons.palette_rounded),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'hud',
                icon: Icon(Icons.blur_circular_rounded),
                label: Text('Réacteur animé'),
              ),
              ButtonSegment(
                value: 'classic',
                icon: Icon(Icons.near_me_rounded),
                label: Text('Curseur classique'),
              ),
            ],
            selected: {c.hud ? 'hud' : 'classic'},
            onSelectionChanged: (v) => c.setOption('look', v.first),
          ),
          const SizedBox(height: 6),
          Text(
            c.hud
                ? 'Un réacteur bleu animé à côté du curseur (il tourne quand Clicky réfléchit, '
                      's\'anime quand il t\'écoute) et des fenêtres « tête haute ».'
                : 'Le petit curseur bleu d\'origine.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 10),
          _TextOption(
            label: 'Comment Clicky t\'appelle',
            hint: c.callName.isEmpty ? 'Ton prénom, un surnom…' : c.callName,
            value: c.callName,
            onSave: (v) => c.setOption('callName', v),
          ),
          sw('greet', c.greet, 'Me saluer au premier démarrage de la journée'),
          sw(
            'alive',
            c.alive,
            'Clicky vivant',
            'Il flotte et bouge tout seul autour de ta souris, fait des petites boucles.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.slideshow_rounded),
              label: const Text('Revoir la visite guidée'),
              onPressed: () => ClickyTutorial.show(context),
            ),
          ),

          head('Voix', Icons.record_voice_over_rounded),
          const _VoicePicker(),
          sw(
            'narrate',
            c.narrate,
            'Parler pendant que la réponse s\'écrit',
            'Il commence à lire dès la première phrase, sans attendre la fin.',
          ),

          head('Écoute', Icons.hearing_rounded),
          if (WakeWord.supported) ...[
            sw(
              'wake',
              c.wakeOn,
              'Mot d\'activation (mains libres)',
              'Dis « Clicky » et pose ta question, sans toucher au clavier. '
                  'L\'écoute du mot se fait sur ton PC.',
            ),
          ],
          if (Win.supportedHere)
            sw(
              'dictation',
              c.dictation,
              'Dictée partout : Ctrl + Alt + Maj',
              'Maintiens Ctrl + Alt + Maj et parle : le texte est tapé dans l\'appli ouverte (Word, Discord…).',
            ),

          head('Mode prof', Icons.school_rounded),
          sw(
            'steps',
            c.stepsMode,
            'Leçons pas à pas',
            'Pour « comment faire… », une étape à la fois : dis « suivant » quand c\'est fait.',
          ),
          sw(
            'annotate',
            c.annotate,
            'Dessiner sur l\'écran',
            'Flèches, cercles, soulignés et étiquettes.',
          ),
          sw(
            'slow',
            c.slow,
            'Mode lent',
            'Le curseur vole plus lentement et les dessins restent plus longtemps.',
          ),
          sw(
            'quiz',
            c.quizMode,
            'Mode quiz',
            'Il te pose des questions au lieu de donner la réponse.',
          ),
          sw(
            'codeMode',
            c.codeMode,
            'Mode code automatique',
            'Explications de programmeur quand un éditeur de code est ouvert.',
          ),
          sw(
            'multilang',
            c.multilang,
            'Multilingue',
            'Il répond dans la langue de ta question (et change de voix).',
          ),
          sw(
            'ocr',
            c.ocr,
            'Lire le petit texte (OCR de Windows)',
            '« Lis-moi ce qui est écrit en petit ».',
          ),
          sw(
            'precise',
            c.precise,
            'Pointage précis (2 passes)',
            'Zoom + grille pour viser pile le bouton. Plus lent, compte double dans ton abonnement.',
          ),
          sw(
            'journal',
            c.journalOn,
            'Journal des connaissances',
            'Chaque notion est notée pour la réviser au bon moment (1, 3, 7, 14, 30… jours).',
          ),

          head('Vie privée et mémoire', Icons.privacy_tip_rounded),
          sw(
            'privacy',
            c.privacy,
            'Protection de la vie privée',
            'Pas de capture d\'écran quand un gestionnaire de mots de passe ou une page de banque est ouvert.',
          ),
          sw(
            'perApp',
            c.perApp,
            'Une mémoire par appli',
            'Clicky partout garde une conversation séparée pour chaque appli (Word, Chrome, Roblox Studio…).',
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Effacer l\'historique de Clicky'),
                onPressed: () => _confirm(
                  context,
                  'Effacer tout l\'historique de Clicky ?',
                  ChatHistory.clicky.clear,
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Vider le journal'),
                onPressed: () => _confirm(
                  context,
                  'Vider le journal des connaissances ?',
                  Journal.instance.clear,
                ),
              ),
            ],
          ),

          head('Internet et outils', Icons.extension_rounded),
          sw(
            'web',
            c.webSearch,
            'Recherche sur internet',
            'Pour l\'actualité, la météo, les infos récentes (outil officiel de Claude).',
          ),
          if (Win.supportedHere)
            sw(
              'drive',
              c.driveOn,
              'Clicky pilote (Clicky partout)',
              'Sur demande (« fais-le pour moi »), il propose un plan de clics et de frappe ; tu le relis '
                  'avant. Échap arrête tout, bouger la souris aussi.',
            ),
          if (WorkflowCapture.supported)
            Text(
              'Capture des gestes et enregistrement de leçon : menu ⋮ dans la boîte de Clicky.',
              style: text.bodySmall,
            ),
          const SizedBox(height: 8),
          const _SkillsEditor(),
          const SizedBox(height: 8),
          const _McpEditor(),
        ],
      ),
    );
  }

  static Future<void> _confirm(BuildContext context, String q, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(q),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Effacer')),
        ],
      ),
    );
    if (ok == true) await run();
  }
}

class _TextOption extends StatefulWidget {
  const _TextOption({
    required this.label,
    required this.hint,
    required this.value,
    required this.onSave,
  });
  final String label;
  final String hint;
  final String value;
  final void Function(String v) onSave;

  @override
  State<_TextOption> createState() => _TextOptionState();
}

class _TextOptionState extends State<_TextOption> {
  late final ctrl = TextEditingController(text: widget.value);

  @override
  Widget build(BuildContext context) => TextField(
    controller: ctrl,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: widget.hint,
      border: const OutlineInputBorder(),
      suffixIcon: IconButton(
        tooltip: 'Enregistrer',
        icon: const Icon(Icons.check_rounded),
        onPressed: () => widget.onSave(ctrl.text.trim()),
      ),
    ),
    onSubmitted: (v) => widget.onSave(v.trim()),
  );
}

/// Choix de la voix (voix installées sur le PC), vitesse et hauteur.
class _VoicePicker extends StatefulWidget {
  const _VoicePicker();

  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  final c = ClickyController.instance;
  late final Future<List<SystemVoice>> voices = c.voiceOut.voices();
  double? rate, pitch;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: voices,
      builder: (context, snap) {
        final all = snap.data ?? const <SystemVoice>[];
        final names = {for (final v in all) v.name};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: names.contains(c.ttsVoice) ? c.ttsVoice : '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Voix', border: OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: '', child: Text('Automatique (voix française)')),
                for (final v in all)
                  DropdownMenuItem(value: v.name, child: Text('${v.name} (${v.locale})')),
              ],
              onChanged: (v) => c.setOption('ttsVoice', v ?? ''),
            ),
            if (snap.connectionState == ConnectionState.done && all.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Pour plus de voix : Paramètres Windows → Heure et langue → Voix → Ajouter des voix.',
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 80, child: Text('Vitesse')),
                Expanded(
                  child: Slider(
                    min: 0.6,
                    max: 1.6,
                    divisions: 10,
                    value: (rate ?? c.ttsRate).clamp(0.6, 1.6),
                    label: '×${(rate ?? c.ttsRate).toStringAsFixed(1)}',
                    onChanged: (v) => setState(() => rate = v),
                    onChangeEnd: (v) => c.setOption('ttsRate', v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 80, child: Text('Hauteur')),
                Expanded(
                  child: Slider(
                    min: 0.7,
                    max: 1.4,
                    divisions: 7,
                    value: (pitch ?? c.ttsPitch).clamp(0.7, 1.4),
                    label: (pitch ?? c.ttsPitch).toStringAsFixed(1),
                    onChanged: (v) => setState(() => pitch = v),
                    onChangeEnd: (v) => c.setOption('ttsPitch', v),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Écouter la voix'),
                onPressed: () => c.speak(
                  'Salut${c.callName.isEmpty ? '' : ' ${c.callName}'} ! C\'est Clicky. Je suis là pour t\'aider.',
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Raccourcis vocaux.
class _SkillsEditor extends StatefulWidget {
  const _SkillsEditor();

  @override
  State<_SkillsEditor> createState() => _SkillsEditorState();
}

class _SkillsEditorState extends State<_SkillsEditor> {
  List<VoiceSkill> list = VoiceSkill.all;

  Future<void> _save() async {
    await VoiceSkill.save(list);
    setState(() {});
  }

  Future<void> _add() async {
    final phrase = TextEditingController();
    final value = TextEditingController();
    var kind = 'url';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Nouveau raccourci vocal'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: phrase,
                  decoration: const InputDecoration(
                    labelText: 'Quand je dis…',
                    hintText: 'ouvre mon cours de maths',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Alors'),
                  items: [
                    for (final e in VoiceSkill.kinds.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => set(() => kind = v ?? kind),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: value,
                  decoration: InputDecoration(
                    labelText: switch (kind) {
                      'url' => 'Adresse du site',
                      'app' => 'Programme (ex. calc.exe, notepad.exe)',
                      'say' => 'Phrase à dire',
                      _ => 'Question à poser',
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ajouter')),
          ],
        ),
      ),
    );
    if (ok != true || phrase.text.trim().isEmpty || value.text.trim().isEmpty) return;
    list = [...list, VoiceSkill(phrase.text.trim(), kind, value.text.trim())];
    await _save();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Raccourcis vocaux', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (list.isEmpty)
                TextButton(
                  onPressed: () {
                    list = VoiceSkill.examples();
                    _save();
                  },
                  child: const Text('Exemples'),
                ),
              IconButton(tooltip: 'Ajouter', icon: const Icon(Icons.add_rounded), onPressed: _add),
            ],
          ),
          const Text('Une phrase → une action, tout de suite, sans passer par l\'IA.'),
          for (final s in list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (s.kind) {
                'url' => Icons.public_rounded,
                'app' => Icons.apps_rounded,
                'say' => Icons.record_voice_over_rounded,
                _ => Icons.question_answer_rounded,
              }),
              title: Text('« ${s.phrase} »'),
              subtitle: Text(
                '${VoiceSkill.kinds[s.kind]} : ${s.value}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  list = [...list]..remove(s);
                  _save();
                },
              ),
            ),
        ],
      ),
    ),
  );
}

/// Serveurs MCP personnalisés.
class _McpEditor extends StatefulWidget {
  const _McpEditor();

  @override
  State<_McpEditor> createState() => _McpEditorState();
}

class _McpEditorState extends State<_McpEditor> {
  List<McpServer> list = McpTools.servers;
  String? info;

  Future<void> _add() async {
    final r = await askFields(
      context,
      title: 'Ajouter un serveur MCP',
      message:
          'Un serveur MCP donne de nouveaux outils à Claude (Notion, Spotify, ton propre serveur…). '
          'Adresse HTTPS (ou http://localhost). Chaque action te demandera la permission.',
      labels: const ['Nom', 'Adresse (https://…/mcp)', 'Jeton (facultatif)'],
      obscure: const {2},
    );
    if (r == null) return;
    final name = r[0].trim(), url = r[1].trim(), token = r[2].trim();
    if (name.isEmpty || !McpServer.validUrl(url)) {
      if (mounted) {
        showError(context, 'Adresse invalide : il faut https://… (ou http://localhost…)');
      }
      return;
    }
    final s = McpServer('${DateTime.now().microsecondsSinceEpoch}', name, url);
    await McpTools.setToken(s.id, token);
    list = [...list, s];
    await McpTools.saveServers(list);
    await _test();
  }

  Future<void> _test() async {
    setState(() => info = 'Connexion aux serveurs…');
    final tools = await McpTools.refresh(force: true);
    if (mounted) {
      setState(
        () => info = tools.isEmpty
            ? 'Aucun outil trouvé (serveur injoignable, ou jeton refusé).'
            : '${tools.length} outil${tools.length > 1 ? 's' : ''} : ${tools.map((t) => t.name).take(8).join(', ')}',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Outils MCP en plus', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (list.isNotEmpty)
                IconButton(
                  tooltip: 'Tester',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _test,
                ),
              IconButton(tooltip: 'Ajouter', icon: const Icon(Icons.add_rounded), onPressed: _add),
            ],
          ),
          const Text('Des serveurs MCP à toi, utilisables par Claude et Clicky (avec permission).'),
          if (info != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(info!)),
          for (final s in list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.hub_rounded),
              title: Text(s.name),
              subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  list = [...list]..remove(s);
                  await McpTools.saveServers(list);
                  await McpTools.setToken(s.id, null);
                  unawaited(McpTools.refresh(force: true));
                  setState(() {});
                },
              ),
            ),
        ],
      ),
    ),
  );
}
