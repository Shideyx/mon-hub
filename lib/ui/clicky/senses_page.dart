import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/screen_memory.dart';
import 'mic_test.dart' show WhisperInstallDialog;
import 'pc_watch.dart';
import 'senses.dart';
import 'interests.dart';
import 'watchers.dart' show Replies;
import 'whisper.dart' show Whisper;

/// Réglages de Nexo → **Ses yeux et ses oreilles** : voir l'écran et
/// entendre le son du PC en continu (tout reste sur le PC), ce qu'il voit et
/// entend en ce moment, et sa mémoire de l'écran (chercher, oublier).
class SensesPage extends StatefulWidget {
  const SensesPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SensesPage()));

  @override
  State<SensesPage> createState() => _SensesPageState();
}

class _SensesPageState extends State<SensesPage> {
  final s = ClickySenses.instance;
  final mem = ScreenMemory.instance;
  final search = TextEditingController();
  List<MemoryHit>? hits;
  bool? whisper;

  @override
  void initState() {
    super.initState();
    unawaited(
      mem.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
    unawaited(
      Whisper.ready.then((v) {
        if (mounted) setState(() => whisper = v);
      }),
    );
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<bool> _consent(String what) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Text('👀', style: TextStyle(fontSize: 34)),
          title: Text('Nexo $what en continu ?'),
          content: const Text(
            'Tout se passe sur ton PC : le texte de l\'écran est lu par Windows et le son est transcrit par Whisper, '
            'sans internet. Ce qu\'il a vu et entendu reste 7 jours sur ce PC, chiffré, jamais synchronisé ni envoyé.\n\n'
            'Il ne regarde jamais tes messageries, tes mails, ta banque, tes mots de passe, la navigation privée ni Mon '
            'Hub, et il n\'écoute jamais pendant un appel. L\'IA ne reçoit quelque chose que quand il remarque un truc '
            'utile ou quand tu lui parles.\n\nTu peux le mettre en pause ou lui faire tout oublier à tout moment.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Non merci')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('D\'accord')),
          ],
        ),
      ) ==
      true;

  Future<void> _forget(Duration? d) async {
    if (d == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Tout oublier ?'),
          content: const Text('Nexo effacera tout ce qu\'il a vu et entendu sur ce PC.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tout oublier')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final k = await mem.forget(last: d);
    s.heard.clear();
    if (!mounted) return;
    setState(() => hits = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('C\'est oublié ($k moments).')));
  }

  void _show(ScreenMoment m) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(m.title.isEmpty ? m.app : m.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(
            '${m.heard ? '🔊 Entendu' : '👀 Vu'} ${ScreenMemory.when(m.at, DateTime.now())} (${m.app})\n\n'
            '${m.text.isEmpty ? '(pas de texte lu)' : m.text}',
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fermer'))],
    ),
  );

  Widget _moment(ScreenMoment m, {String excerpt = ''}) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Text(m.heard ? '🔊' : '👀', style: const TextStyle(fontSize: 20)),
    title: Text(m.title.isEmpty ? m.app : m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${ScreenMemory.when(m.at, DateTime.now())} · ${m.app}${excerpt.isEmpty ? '' : '\n$excerpt'}',
      maxLines: excerpt.isEmpty ? 1 : 3,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: () => _show(m),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ses yeux et ses oreilles')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s, mem]),
        builder: (context, _) {
          final now = DateTime.now();
          final today = [
            for (final m in mem.moments.reversed)
              if (m.at.year == now.year && m.at.month == now.month && m.at.day == now.day) m,
          ].take(40).toList();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: const LinearGradient(colors: [Color(0xFF0EA5E9), Color(0xFF7C5CFF)]),
                    ),
                    child: Row(
                      children: [
                        const Text('👀', style: TextStyle(fontSize: 40)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.paused
                                    ? 'En pause'
                                    : s.screenOn || s.soundOn
                                    ? 'Nexo ${[if (s.screenOn) 'voit ton écran', if (s.soundOn) 'entend ton PC'].join(' et ')}'
                                    : 'Nexo ne regarde pas ton écran',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Tout se passe sur ton PC. Jamais tes messages, ta banque, la navigation privée, ni pendant un appel.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!ClickySenses.supported)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Ses yeux et ses oreilles marchent sur le PC (Windows).'),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Text('👀', style: TextStyle(fontSize: 22)),
                    title: const Text('Il voit ton écran en continu', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text(
                      'Quand ta fenêtre change, il lit son texte (sur le PC). Il s\'en souvient (« tu te souviens du site sur… ? »), '
                      'il sait de quoi tu parles quand tu lui poses une question, et il remarque une erreur ou une date limite.',
                    ),
                    value: s.screenOn,
                    onChanged: !ClickySenses.supported
                        ? null
                        : (v) async {
                            if (v && !s.soundOn && !await _consent('voit ton écran')) return;
                            await s.setScreen(v);
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Text('👂', style: TextStyle(fontSize: 22)),
                    title: const Text('Il entend le son de ton PC', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      'Quand une vidéo ou un site parle, il transcrit ce qui est dit (pas la musique, jamais pendant un appel) : '
                      '« qu\'est-ce qu\'il a dit ? », il note les « à retenir » des cours en vidéo, il propose les sous-titres '
                      'quand c\'est en anglais.${s.soundOn && s.soundState.isNotEmpty ? '\nEn ce moment : ${s.soundState}' : ''}',
                    ),
                    value: s.soundOn,
                    onChanged: !ClickySenses.supported
                        ? null
                        : (v) async {
                            if (v && !s.screenOn && !await _consent('entend ton PC')) return;
                            await s.setSound(v);
                          },
                  ),
                  if (s.soundOn && whisper == false)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Installer la reconnaissance sur le PC (Whisper)'),
                        onPressed: () async {
                          await WhisperInstallDialog.show(context);
                          final v = await Whisper.ready;
                          if (mounted) setState(() => whisper = v);
                        },
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Text('⏰', style: TextStyle(fontSize: 22)),
                    title: const Text('Il me recadre quand je procrastine'),
                    subtitle: const Text(
                      'Le soir, si tu as un devoir ou un contrôle pour demain et que ça fait 40 minutes de YouTube, de jeu ou de '
                      'réseaux : « on fait 25 minutes et je te laisse tranquille ? ». Une fois par soir au plus.',
                    ),
                    value: s.nudgeOn,
                    onChanged: s.setNudge,
                  ),
                  if (PcWatch.supported) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Text('📋', style: TextStyle(fontSize: 22)),
                      title: const Text('Le presse-papier malin'),
                      subtitle: const Text(
                        'Tu copies un lien d\'arnaque → il te prévient ; un calcul → le résultat ; une date → « je l\'ajoute à ton '
                        'agenda ? » ; un colis → le suivi ; une adresse → le plan ; de l\'anglais → « je te le traduis ? » ; un long '
                        'texte → « je te le résume ? ». Rien n\'est gardé, et jamais depuis un gestionnaire de mots de passe.',
                      ),
                      value: PcWatch.instance.clipOn,
                      onChanged: (v) async {
                        await PcWatch.instance.setClip(v);
                        if (mounted) setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Text('💻', style: TextStyle(fontSize: 22)),
                      title: const Text('Il réagit à ton PC'),
                      subtitle: const Text(
                        'Un cours téléchargé → « je le range dans Cours/Maths ? » ; une capture d\'écran → « je copie son texte ? » ; '
                        'une clé USB → il l\'ouvre (et prévient s\'il y a un programme suspect dessus) ; une appli qui ne répond '
                        'plus ; un disque presque plein.',
                      ),
                      value: PcWatch.instance.pcOn,
                      onChanged: (v) async {
                        await PcWatch.instance.setPc(v);
                        if (mounted) setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Text('💬', style: TextStyle(fontSize: 22)),
                      title: const Text('Réponses toutes prêtes'),
                      subtitle: const Text(
                        'Quand on te pose une question en message privé sur Discord : « je te prépare une réponse ? ». Elle est '
                        'copiée, prête à coller : Nexo n\'envoie jamais rien tout seul.',
                      ),
                      value: Replies.on,
                      onChanged: (v) async {
                        await Replies.setOn(v);
                        if (mounted) setState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Text('🎵', style: TextStyle(fontSize: 22)),
                      title: const Text('Veille sur tes artistes'),
                      subtitle: const Text(
                        'Deux fois par jour, il regarde les artistes de tes titres likés et te prévient quand l\'un d\'eux sort un '
                        'nouveau son (recherche publique Deezer : seuls les noms d\'artistes sont cherchés).',
                      ),
                      value: ArtistWatch.on,
                      onChanged: (v) async {
                        await ArtistWatch.setOn(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                  if (s.screenOn || s.soundOn) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (s.paused)
                          FilledButton.icon(
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text('Reprendre (en pause jusqu\'à ${ScreenMemory.hm(s.pausedUntil!)})'),
                            onPressed: s.resume,
                          )
                        else ...[
                          OutlinedButton.icon(
                            icon: const Icon(Icons.pause_rounded),
                            label: const Text('Pause 15 min'),
                            onPressed: () => s.pause(const Duration(minutes: 15)),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.pause_circle_rounded),
                            label: const Text('Pause 1 h'),
                            onPressed: () => s.pause(const Duration(hours: 1)),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if ((s.screenOn && s.seeing.isNotEmpty) || s.heard.isNotEmpty || s.notes.isNotEmpty) ...[
                    const Divider(height: 32),
                    Text('En ce moment', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    if (s.screenOn && s.seeing.isNotEmpty)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Text('👀', style: TextStyle(fontSize: 20)),
                        title: Text(s.seeing, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          s.seeingText.isEmpty ? '(pas de texte lu)' : s.seeingText.replaceAll('\n', ' '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (s.heard.isNotEmpty)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Text('🔊', style: TextStyle(fontSize: 20)),
                        title: Text(s.heard.last.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('« ${s.heard.last.$3} »', maxLines: 3, overflow: TextOverflow.ellipsis),
                      ),
                    for (final (at, title, line) in s.notes.reversed.take(5))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Text('📌', style: TextStyle(fontSize: 18)),
                        title: Text(line),
                        subtitle: Text('${ScreenMemory.hm(at)} · $title', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  const Divider(height: 32),
                  Text(
                    'Sa mémoire de l\'écran',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Retrouver… (« volcans hier », « exercice de maths mardi »)',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onSubmitted: (q) {
                      final w = TimeWindow.parse(q, DateTime.now());
                      setState(() => hits = mem.search(q, from: w?.from, to: w?.to, limit: 20));
                    },
                  ),
                  const SizedBox(height: 6),
                  if (hits != null) ...[
                    if (hits!.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Rien trouvé.')),
                    for (final h in hits!) _moment(h.moment, excerpt: h.excerpt),
                    const SizedBox(height: 8),
                  ],
                  Text('Aujourd\'hui', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  if (today.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        s.screenOn || s.soundOn
                            ? 'Rien pour l\'instant : ça se remplit au fil de ta journée.'
                            : 'Rien : il ne regarde pas.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  for (final m in today) _moment(m),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => _forget(const Duration(minutes: 15)),
                        child: const Text('Oublier les 15 dernières minutes'),
                      ),
                      OutlinedButton(
                        onPressed: () => _forget(const Duration(hours: 1)),
                        child: const Text('Oublier la dernière heure'),
                      ),
                      TextButton.icon(
                        icon: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
                        label: Text('Tout oublier', style: TextStyle(color: theme.colorScheme.error)),
                        onPressed: () => _forget(null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Demande-lui : « tu te souviens du site sur les volcans que j\'ai vu hier ? », « qu\'est-ce que je faisais mardi '
                    'vers 16 h ? », « qu\'est-ce qu\'il a dit ? », « oublie les 10 dernières minutes », « ferme les yeux pendant 1 h ».',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
