import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../chat_history.dart';
import '../widgets.dart';
import 'capture.dart';
import 'clicky.dart';
import 'extensions.dart';
import 'journal.dart';
import 'pc.dart';
import 'routines.dart';
import 'neural_voice.dart';
import 'tutorial.dart';
import 'wake.dart';
import 'win.dart';
import 'whisper.dart';
import 'mic_test.dart' show WhisperInstallDialog;
import 'thrift.dart';

/// Un réglage de Clicky : sa rubrique, les mots pour le retrouver, et son
/// interrupteur (ou ses boutons).
class _Opt {
  const _Opt(this.section, this.words, this.widget);
  final String section;
  final String words;
  final Widget widget;
}

/// Les rubriques des réglages de Clicky (une page chacune).
class ClickySection {
  const ClickySection(this.id, this.title, this.subtitle, this.icon, this.color);
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  static const all = [
    ClickySection('look', 'Apparence', 'Réacteur ou curseur, ton prénom, Clicky vivant, suivre la souris',
        Icons.palette_rounded, Color(0xFF7C5CFF)),
    ClickySection('voice', 'Voix', 'La voix Gemini, la réponse instantanée, parler pendant l\'écriture',
        Icons.record_voice_over_rounded, Color(0xFF2B6CFF)),
    ClickySection('listen', 'Écoute et micro', 'Reconnaissance vocale (Whisper), « Clicky » mains libres, dictée',
        Icons.hearing_rounded, Color(0xFF0EA5E9)),
    ClickySection('topo', 'Topos du matin et du soir', 'Le résumé de ta journée, à l\'heure que tu veux',
        Icons.wb_twilight_rounded, Color(0xFFF59E0B)),
    ClickySection('teach', 'Aide aux devoirs', 'Leçons pas à pas, mode quiz, dessins à l\'écran, journal des notions',
        Icons.school_rounded, Color(0xFF10B981)),
    ClickySection('privacy', 'Vie privée et mémoire', 'Pas de capture sur les pages sensibles, effacer l\'historique',
        Icons.privacy_tip_rounded, Color(0xFF64748B)),
    ClickySection('tools', 'Outils avancés', 'Internet, contrôle du PC, raccourcis vocaux, économies, MCP',
        Icons.extension_rounded, Color(0xFFEA580C)),
  ];

  static ClickySection? byId(String id) => all.where((x) => x.id == id).firstOrNull;
}

/// Minuscules sans accents (pour la recherche).
String _plain(String s) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final k = from.indexOf(ch);
    b.write(k < 0 ? ch : to[k]);
  }
  return b.toString();
}

/// Les réglages de Clicky : une rubrique ([section]), ceux qui
/// correspondent à une recherche ([query]), ou tous.
class ClickyMoreSettings extends StatelessWidget {
  const ClickyMoreSettings({super.key, this.section, this.query = ''});

  /// Une seule rubrique (voir [ClickySection]).
  final String? section;

  /// Recherche (« voix », « micro »…) : seulement les réglages qui en parlent.
  final String query;

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
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final opts = <_Opt>[];
        void sw(String sec, String key, bool value, String title, [String? sub, void Function(bool)? onChanged]) => opts.add(
          _Opt(
            sec,
            '$title ${sub ?? ''}',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(title),
              subtitle: sub == null ? null : Text(sub),
              value: value,
              onChanged: onChanged ?? (v) => c.setOption(key, v),
            ),
          ),
        );
        void add(String sec, String words, Widget w) => opts.add(_Opt(sec, words, w));

        // ---- Apparence ----
        add(
          'look',
          'apparence reacteur anime curseur classique bleu look',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'hud', icon: Icon(Icons.blur_circular_rounded), label: Text('Réacteur animé')),
                  ButtonSegment(value: 'classic', icon: Icon(Icons.near_me_rounded), label: Text('Curseur classique')),
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
            ],
          ),
        );
        add(
          'look',
          'comment clicky t appelle prenom surnom nom',
          _TextOption(
            label: 'Comment Clicky t\'appelle',
            hint: c.callName.isEmpty ? 'Ton prénom, un surnom…' : c.callName,
            value: c.callName,
            onSave: (v) => c.setOption('callName', v),
          ),
        );
        sw('look', 'show', c.alwaysShow, 'Toujours afficher Clicky', 'Sinon, il n\'apparaît que quand tu lui parles.');
        sw('look', 'follow', c.follow, 'Clicky suit la souris');
        sw('look', 'alive', c.alive, 'Clicky vivant', 'Il flotte et bouge tout seul autour de ta souris, fait des petites boucles.');
        sw('look', 'greet', c.greet, 'Me saluer au premier démarrage de la journée');
        add(
          'look',
          'visite guidee tutoriel aide',
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.slideshow_rounded),
              label: const Text('Revoir la visite guidée'),
              onPressed: () => ClickyTutorial.show(context),
            ),
          ),
        );

        // ---- Topos ----
        add('topo', 'topo matin soir briefing resume journee heure', const _TopoSettings());

        // ---- Voix ----
        if (Win.supportedHere) {
          sw(
            'voice',
            'instant',
            c.instant,
            'Réponse instantanée (Gemini Live, comme JARVIS)',
            c.voiceOut.geminiKey.trim().isEmpty
                ? 'Ajoute ta clé Gemini gratuite (ci-dessous) : Clicky répondra au tac au tac, en direct.'
                : 'Ta voix part en direct vers Gemini, qui répond tout de suite en voix. Pour un tableau, un schéma ou '
                      'montrer où cliquer, Claude prend le relais.'
                      '${c.liveError == null ? '' : '\nDernier souci : ${c.liveError}'}',
          );
        }
        add('voice', 'voix gemini cle api gratuite ecouter la voix choisir', const _NeuralVoicePicker());
        sw('voice', 'narrate', c.narrate, 'Parler pendant que la réponse s\'écrit', 'Il commence à lire dès la première phrase, sans attendre la fin.');

        // ---- Écoute ----
        sw('listen', 'followUp', c.followUp, 'Conversation continue',
        'Après sa réponse à voix haute, il t\'écoute encore quelques secondes : enchaîne sans Ctrl + Alt, comme avec '
            'JARVIS. Si tu ne dis rien, il arrête tout seul (et rien n\'est envoyé).');
    if (Whisper.supported) add('listen', 'reconnaissance vocale whisper gemini windows micro installer modele', const _MicEngine());
        if (WakeWord.supported) {
          sw('listen', 'wake', c.wakeOn, 'Mot d\'activation (mains libres)',
              'Dis « Clicky » et pose ta question, sans toucher au clavier. L\'écoute du mot se fait sur ton PC.');
        }
        if (Win.supportedHere) {
          sw('listen', 'dictation', c.dictation, 'Dictée partout : Ctrl + Alt + Maj',
              'Maintiens Ctrl + Alt + Maj et parle : le texte est tapé dans l\'appli ouverte (Word, Discord…).');
        }

        // ---- Aide aux devoirs ----
        sw('teach', 'steps', c.stepsMode, 'Leçons pas à pas', 'Pour « comment faire… », une étape à la fois : dis « suivant » quand c\'est fait.');
        sw('teach', 'quiz', c.quizMode, 'Mode quiz', 'Il te pose des questions au lieu de donner la réponse.');
        sw('teach', 'annotate', c.annotate, 'Dessiner sur l\'écran', 'Flèches, cercles, soulignés et étiquettes.');
        sw('teach', 'slow', c.slow, 'Mode lent', 'Le curseur vole plus lentement et les dessins restent plus longtemps.');
        sw('teach', 'journal', c.journalOn, 'Journal des connaissances', 'Chaque notion est notée pour la réviser au bon moment (1, 3, 7, 14, 30… jours).');
        sw('teach', 'multilang', c.multilang, 'Multilingue', 'Il répond dans la langue de ta question (et change de voix).');
        sw('teach', 'codeMode', c.codeMode, 'Mode code automatique', 'Explications de programmeur quand un éditeur de code est ouvert.');
        sw('teach', 'ocr', c.ocr, 'Lire le petit texte (OCR de Windows)', '« Lis-moi ce qui est écrit en petit ».');
        sw('teach', 'precise', c.precise, 'Pointage précis (2 passes)', 'Zoom + grille pour viser pile le bouton. Plus lent, compte double dans ton abonnement.');

        // ---- Vie privée ----
        sw('privacy', 'privacy', c.privacy, 'Protection de la vie privée',
            'Pas de capture d\'écran quand un gestionnaire de mots de passe ou une page de banque est ouvert.');
        sw('privacy', 'perApp', c.perApp, 'Une mémoire par appli',
            'Clicky partout garde une conversation séparée pour chaque appli (Word, Chrome, Roblox Studio…).');
        add(
          'privacy',
          'effacer historique vider journal supprimer conversations',
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Effacer l\'historique de Clicky'),
                onPressed: () => _confirm(context, 'Effacer tout l\'historique de Clicky ?', ChatHistory.clicky.clear),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Vider le journal'),
                onPressed: () => _confirm(context, 'Vider le journal des connaissances ?', Journal.instance.clear),
              ),
            ],
          ),
        );

        // ---- Outils avancés ----
        sw('tools', 'web', c.webSearch, 'Recherche sur internet', 'Pour l\'actualité, la météo, les infos récentes (outil officiel de Claude).');
        sw(
          'tools',
          'thrift',
          c.thrift,
          'Clicky économe (Claude pour les demandes difficiles)',
          'Les questions simples vont à Gemini (gratuit) ; Claude ne reçoit que les actions utiles à ta question '
              'et réfléchit juste ce qu\'il faut. ${ClaudeUsage.summary}',
        );
        if (Win.supportedHere) {
          sw('tools', 'drive', c.driveOn, 'Clicky pilote (Clicky partout)',
              'Sur demande (« fais-le pour moi »), il propose un plan de clics et de frappe ; tu le relis avant. '
                  'Échap arrête tout, bouger la souris aussi.');
        }
        if (PcControl.supported) {
          add(
            'tools',
            'controle du pc commandes installer logiciels fichiers demander sans demander desactive',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text('Contrôle du PC', style: text.titleSmall),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ask', icon: Icon(Icons.verified_user_rounded), label: Text('Demander')),
                    ButtonSegment(value: 'auto', icon: Icon(Icons.bolt_rounded), label: Text('Sans demander')),
                    ButtonSegment(value: 'off', icon: Icon(Icons.block_rounded), label: Text('Désactivé')),
                  ],
                  selected: {c.pcControl},
                  onSelectionChanged: (v) => c.setOption('pc', v.first),
                ),
                const SizedBox(height: 4),
                Text(
                  switch (c.pcControl) {
                    'auto' =>
                      'Clicky fait tout ce que tu lui demandes sur le PC (commandes, fichiers, logiciels, '
                          'réglages) sans demander. Il demande quand même pour les commandes dangereuses '
                          '(formatage, suppressions en masse, extinction…) et en administrateur.',
                    'off' => 'Clicky ne touche pas à ton PC (il peut seulement t\'expliquer comment faire).',
                    _ =>
                      'Dis « Clicky, installe VLC », « range mes téléchargements », « mets le son à 30 % »… : '
                          'il le fait lui-même. Chaque commande s\'affiche avant et attend ton « Autoriser ».',
                  },
                  style: text.bodySmall,
                ),
                const SizedBox(height: 8),
                if (WorkflowCapture.supported)
                  Text(
                    'Capture des gestes et enregistrement de leçon : menu ⋮ dans la boîte de Clicky.',
                    style: text.bodySmall,
                  ),
              ],
            ),
          );
        }
        add('tools', 'raccourcis vocaux phrase action', const Padding(padding: EdgeInsets.only(top: 8), child: _SkillsEditor()));
        add('tools', 'mcp serveur outils en plus', const Padding(padding: EdgeInsets.only(top: 8), child: _McpEditor()));
        final q = _plain(query).trim();
        if (q.isNotEmpty) {
          final words = q.split(RegExp(r'\s+'));
          final found = [
            for (final o in opts)
              if (words.every((w) => _plain('${o.words} ${ClickySection.byId(o.section)?.title ?? ''}').contains(w))) o,
          ];
          if (found.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('Aucun réglage ne correspond à « $query ».', style: text.bodyMedium),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final o in found) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    ClickySection.byId(o.section)?.title.toUpperCase() ?? '',
                    style: text.labelSmall?.copyWith(letterSpacing: 1.1, color: Theme.of(context).colorScheme.primary),
                  ),
                ),
                o.widget,
              ],
            ],
          );
        }
        if (section != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final o in opts.where((o) => o.section == section)) o.widget],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final sec in ClickySection.all) ...[
              head(sec.title, sec.icon),
              for (final o in opts.where((o) => o.section == sec.id)) o.widget,
            ],
          ],
        );
      },
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

/// Voix gratuites de qualité : Microsoft (sans clé) ou Gemini (clé gratuite).
class _NeuralVoicePicker extends StatefulWidget {
  const _NeuralVoicePicker();

  @override
  State<_NeuralVoicePicker> createState() => _NeuralVoicePickerState();
}

class _NeuralVoicePickerState extends State<_NeuralVoicePicker> {
  final c = ClickyController.instance;
  final key = TextEditingController();
  String? info;
  bool testing = false;

  Future<void> _test() async {
    setState(() {
      testing = true;
      info = null;
    });
    final err = await c.voiceOut.test(
      'Salut${c.callName.isEmpty ? '' : ' ${c.callName}'} ! C\'est Clicky. Voilà ma nouvelle voix.',
    );
    if (mounted) {
      setState(() {
        testing = false;
        info = err == null
            ? null
            : 'La voix Gemini ne répond pas ($err). Vérifie ta clé et ta connexion internet ; sinon Clicky répond par écrit.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Une seule voix, naturelle : celle de Google Gemini, avec ta clé gratuite (aistudio.google.com → '
        'Get API key). Clicky lit ses réponses par gros morceaux ; si le quota gratuit du jour est épuisé, '
        'Gemini Live prend le relais avec la même voix. Sans clé ni internet, Clicky répond par écrit.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      ...[
        TextField(
          controller: key,
          obscureText: true,
          decoration: InputDecoration(
            labelText: c.voiceOut.geminiKey.isEmpty
                ? 'Clé API Gemini (gratuite)'
                : 'Clé enregistrée (remplacer…)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.check_rounded),
              onPressed: () async {
                await c.setGeminiKey(key.text);
                key.clear();
                setState(() {});
              },
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Créer une clé gratuite'),
            onPressed: () => openLink(context, 'https://aistudio.google.com/apikey'),
          ),
        ),
        DropdownButtonFormField<String>(
          initialValue: GeminiVoice.voices.contains(c.geminiVoice) ? c.geminiVoice : 'Charon',
          decoration: const InputDecoration(labelText: 'Voix Gemini', border: OutlineInputBorder()),
          items: [for (final v in GeminiVoice.voices) DropdownMenuItem(value: v, child: Text(v))],
          onChanged: (v) => c.setOption('geminiVoice', v ?? 'Charon'),
        ),
      ],
      Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Écouter la voix'),
            onPressed: testing ? null : _test,
          ),
        ),
      if (info != null) Text(info!, style: const TextStyle(color: Colors.orange)),
    ],
  );
}

/// Interrupteurs des topos (matin / soir), heure, et « maintenant ».
class _TopoSettings extends StatefulWidget {
  const _TopoSettings();

  @override
  State<_TopoSettings> createState() => _TopoSettingsState();
}

class _TopoSettingsState extends State<_TopoSettings> {
  final r = Routines.instance;

  @override
  void initState() {
    super.initState();
    unawaited(r.ensureTopos());
  }

  Widget _row(BuildContext context, String id, String title, String what) {
    final routine = r.list.where((x) => x.id == id).firstOrNull;
    final on = routine?.enabled ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(
            '$what${routine == null ? '' : '\nÀ ${two(routine.hour)}:${two(routine.minute)}'
                      '${id == 'topo-matin' ? ' (ou dès que tu allumes le PC, jusqu\'à midi)' : ''}'}',
          ),
          isThreeLine: true,
          value: on,
          onChanged: (v) => r.setTopo(id, v),
        ),
        Wrap(
          spacing: 8,
          children: [
            if (routine != null)
              TextButton.icon(
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: const Text('Changer l\'heure'),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: routine.hour, minute: routine.minute),
                  );
                  if (t == null) return;
                  routine
                    ..hour = t.hour
                    ..minute = t.minute;
                  await r.save(routine);
                },
              ),
            if (routine != null)
              TextButton.icon(
                icon: r.running(id)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Maintenant'),
                onPressed: r.running(id) ? null : () => r.runNow(id),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: r,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          context,
          'topo-matin',
          'Topo du matin',
          'Météo et tenue, actus France et monde, mails importants, cours, devoirs, notes et messages '
              'École Directe, tes tâches.',
        ),
        _row(
          context,
          'topo-soir',
          'Topo du soir',
          'Bilan de ta journée, devoirs et emploi du temps de demain, météo de demain, actus du jour, mails importants.',
        ),
        Text(
          'Clicky l\'affiche en grand et le lit avec sa voix ; il arrive aussi sur ton téléphone si ntfy est '
          'configuré (Carnet → Réglages). Mon Hub doit être ouvert.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}


/// Choix de la reconnaissance vocale (Windows ou Whisper sur le PC).
class _MicEngine extends StatefulWidget {
  const _MicEngine();

  @override
  State<_MicEngine> createState() => _MicEngineState();
}

class _MicEngineState extends State<_MicEngine> {
  late Future<String?> installed = Whisper.installedModel();

  @override
  Widget build(BuildContext context) {
    final c = ClickyController.instance;
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: installed,
      builder: (context, snap) {
        final model = snap.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Reconnaissance vocale', style: text.titleSmall),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'whisper', label: Text('Whisper (PC)')),
                ButtonSegment(value: 'gemini', label: Text('Gemini')),
                ButtonSegment(value: 'windows', label: Text('Windows')),
              ],
              selected: {c.micEngine},
              onSelectionChanged: (v) => c.setOption('micEngine', v.first),
            ),
            const SizedBox(height: 4),
            Text(
              switch (c.micEngine) {
                'whisper' => 'Whisper, sur ton PC, sans internet : le texte s\'écrit quand tu as fini de parler.',
                'windows' => 'La reconnaissance de Windows (comme Win + H) : le texte s\'écrit pendant que tu parles.',
                'gemini' => 'Gemini (ta clé gratuite, rubrique Voix) : rien à installer, mais le son part chez Google.',
                _ => 'Windows d\'abord ; s\'il ne marche pas, Whisper (ou Gemini si tu as une clé) prend le relais tout seul.',
              },
              style: text.bodySmall,
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    model == null
                        ? 'Whisper n\'est pas installé.'
                        : 'Whisper installé (modèle ${Whisper.models[model]?.$1 ?? model}).',
                    style: text.bodySmall,
                  ),
                ),
                TextButton.icon(
                  icon: Icon(model == null ? Icons.download_rounded : Icons.tune_rounded, size: 18),
                  label: Text(model == null ? 'Installer Whisper' : 'Changer de modèle'),
                  onPressed: () async {
                    await WhisperInstallDialog.show(context);
                    if (mounted) setState(() => installed = Whisper.installedModel());
                  },
                ),
                if (model != null)
                  IconButton(
                    tooltip: 'Désinstaller Whisper',
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () async {
                      await Whisper.uninstall();
                      if (c.micEngine == 'whisper') await c.setOption('micEngine', 'auto');
                      if (mounted) setState(() => installed = Whisper.installedModel());
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
