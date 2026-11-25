import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../core/news.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import '../claude/claude_module.dart';
import 'carnet_store.dart';
import '../../core/browser.dart';

/// Carnet : les plugins de ton JARVIS, dans Mon Hub (tâches, notes, idées en
/// vrac, mémoire de Nexo, budget, sport, jeux, poèmes, météo + tenue,
/// bilan du soir, protocoles, presse-papier, notification téléphone).
/// Nexo s'en sert à la voix (« note que… », « j'ai dépensé 12 € »,
/// « protocole travail »…).
class CarnetModule extends HubModule {
  @override
  String get id => 'carnet';
  @override
  String get name => 'Carnet';
  @override
  String get description => 'Tâches, notes, idées, mémoire de Nexo, budget, sport, jeux, poèmes, météo, protocoles';
  @override
  IconData get icon => Icons.auto_stories_rounded;
  @override
  Color get color => const Color(0xFF00A6B4);
  @override
  ApiAccess get access => ApiAccess.local;

  final c = Carnet.instance;

  /// Branché par Nexo : dire une phrase, appeler un outil de Mon Hub.
  static Future<void> Function(String text)? say;
  static Future<Object?> Function(String tool, Map<String, dynamic> args)? callTool;

  @override
  void attach() {
    super.attach();
    unawaited(c.load());
  }

  String get city => c.setting<String>('city', '');
  String get ntfy => c.setting<String>('ntfy', '');

  /// Lance un protocole (« travail », « nuit »…). Renvoie un compte rendu.
  Future<String> runProtocol(String name) async {
    await c.load();
    final all = c.protocols;
    final key =
        all.keys.where((k) => k.toLowerCase() == name.toLowerCase().trim()).firstOrNull ??
        all.keys.where((k) => k.toLowerCase().contains(name.toLowerCase().trim())).firstOrNull;
    if (key == null) return 'Pas de protocole « $name ». Protocoles : ${all.keys.join(', ')}.';
    final done = <String>[];
    for (final s in all[key]!) {
      final v = '${s['valeur'] ?? ''}';
      try {
        switch ('${s['type']}') {
          case 'appli':
            await openApp(v);
          case 'site':
            await Browser.open(v);
          case 'dire':
            await say?.call(v);
          case 'notifier':
            await PhoneNotify.send(ntfy, 'Nexo', v);
          case 'attendre':
            await Future<void>.delayed(Duration(milliseconds: ((double.tryParse(v) ?? 1) * 1000).round()));
          case 'spotify':
            await callTool?.call('spotify', {'action': v, 'requete': '${s['requete'] ?? ''}'});
          case 'musique':
            await callTool?.call('musique_commande', {'action': v});
          case 'outil':
            await callTool?.call(v, (s['args'] as Map?)?.cast<String, dynamic>() ?? {});
        }
        done.add('${s['type']}');
      } catch (e) {
        done.add('${s['type']} (échec : $e)');
      }
    }
    return 'Protocole $key exécuté (${done.join(', ')}).';
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'carnet_memoire',
      description:
          'Ma mémoire à long terme (ce que Nexo doit retenir sur moi) : action=retenir + texte '
          '(« retiens que je suis allergique aux noix »), action=oublier + texte, action=liste.',
      params: {'action': ('string', 'retenir, oublier ou liste'), 'texte': ('string', 'le souvenir')},
      required: ['action'],
      run: (a) async {
        await c.load();
        final t = '${a['texte'] ?? ''}'.trim();
        switch ('${a['action']}') {
          case 'retenir':
            if (t.isEmpty) return 'Quoi retenir ?';
            await c.add('memory', {'text': t}, max: 300);
            return 'C\'est noté, je m\'en souviendrai.';
          case 'oublier':
            final e = c.find('memory', t);
            if (e == null) return 'Je ne trouve pas ce souvenir.';
            await c.remove('memory', e.id);
            return 'Oublié : ${e.text}';
          default:
            return c.facts.isEmpty ? 'Je n\'ai encore rien retenu.' : c.facts;
        }
      },
    ),
    HubTool(
      name: 'carnet_idees',
      description:
          'Idées en vrac (brain dump) : action=capturer + texte dès que je dis « note ça », '
          '« retiens », « faut que je… » sans préciser où ranger ; action=liste pour voir la boîte '
          'de réception ; action=ranger + id quand tu l\'as classée ailleurs (tâche, budget, agenda…).',
      params: {
        'action': ('string', 'capturer, liste ou ranger'),
        'texte': ('string', 'la pensée à capturer'),
        'id': ('string', 'id de l\'idée rangée'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        switch ('${a['action']}') {
          case 'capturer':
            final t = '${a['texte'] ?? ''}'.trim();
            if (t.isEmpty) return 'Quoi noter ?';
            await c.add('inbox', {'text': t});
            return 'Capturé.';
          case 'ranger':
            await c.remove('inbox', '${a['id']}');
            return 'Rangée.';
          default:
            return [
              for (final e in c.list('inbox')) {'id': e.id, 'texte': e.text, 'le': e.at},
            ];
        }
      },
    ),
    HubTool(
      name: 'carnet_taches_notes',
      description:
          'Ma liste de tâches et mes notes : action=ajouter_tache + texte, action=ajouter_note + '
          'texte, action=liste (tout), action=cocher + texte (tâche faite), action=effacer + texte.',
      params: {
        'action': ('string', 'ajouter_tache, ajouter_note, liste, cocher ou effacer'),
        'texte': ('string', 'texte de la tâche ou de la note'),
        'pour_le': ('string', 'date limite de la tâche AAAA-MM-JJ (facultatif)'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        final t = '${a['texte'] ?? ''}'.trim();
        switch ('${a['action']}') {
          case 'ajouter_tache':
            final due = DateTime.tryParse('${a['pour_le'] ?? ''}');
            await c.add('todos', {'text': t, 'due': ?due?.millisecondsSinceEpoch});
            return 'Tâche ajoutée : $t';
          case 'ajouter_note':
            await c.add('notes', {'text': t});
            return 'Note ajoutée.';
          case 'cocher':
            final e = c.find('todos', t);
            if (e == null) return 'Tâche introuvable.';
            await c.change('todos', e.id, {'done': true, 'doneAt': DateTime.now().millisecondsSinceEpoch});
            return 'Bravo, « ${e.text} » est faite.';
          case 'effacer':
            final e = c.find('todos', t) ?? c.find('notes', t);
            if (e == null) return 'Introuvable.';
            await c.remove(c.find('todos', t) != null ? 'todos' : 'notes', e.id);
            return 'Effacé.';
          default:
            return {
              'a_faire': [
                for (final x in c.list('todos'))
                  if (!x.done) x.text,
              ],
              'fait': [
                for (final x in c.list('todos').reversed.take(10))
                  if (x.done) x.text,
              ],
              'notes': [for (final x in c.list('notes').reversed.take(30)) x.text],
            };
        }
      },
    ),
    HubTool(
      name: 'carnet_budget',
      description:
          'Mon budget : action=depense + montant (€) + categorie (+ note) quand je dis avoir dépensé '
          'ou payé ; action=revenu + montant quand j\'ai reçu de l\'argent ; action=bilan + periode '
          '(jour, semaine, mois) ; action=liste.',
      params: {
        'action': ('string', 'depense, revenu, bilan ou liste'),
        'montant': ('number', 'montant en euros'),
        'categorie': ('string', 'repas, sorties, jeux, transport, vêtements…'),
        'note': ('string', 'détail'),
        'periode': ('string', 'jour, semaine ou mois'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        final m = (a['montant'] as num?)?.toDouble() ?? 0;
        switch ('${a['action']}') {
          case 'depense':
            await c.add('money', {
              'amount': -m.abs(),
              'category': '${a['categorie'] ?? ''}',
              'text': '${a['note'] ?? ''}',
            });
            return 'Dépense de ${m.abs().toStringAsFixed(2)} € notée.';
          case 'revenu':
            await c.add('money', {'amount': m.abs(), 'category': 'revenu', 'text': '${a['note'] ?? ''}'});
            return 'Revenu de ${m.abs().toStringAsFixed(2)} € noté.';
          case 'liste':
            return [
              for (final e in c.list('money').reversed.take(40))
                {'montant': e.amount, 'categorie': e.category, 'note': e.text, 'le': e.at},
            ];
          default:
            final now = DateTime.now();
            final from = switch ('${a['periode']}') {
              'jour' => DateTime(now.year, now.month, now.day),
              'semaine' => now.subtract(const Duration(days: 7)),
              _ => DateTime(now.year, now.month),
            };
            final (spent, earned, cats) = c.money(from);
            return {'depenses': spent, 'revenus': earned, 'solde': earned - spent, 'par_categorie': cats};
        }
      },
    ),
    HubTool(
      name: 'carnet_sport',
      description:
          'Mes perfs de sport / muscu : action=noter + exercice + poids (kg) + reps (« 80 kg au '
          'développé couché pour 5 ») ; action=progres + exercice ; action=liste.',
      params: {
        'action': ('string', 'noter, progres ou liste'),
        'exercice': ('string', 'nom de l\'exercice'),
        'poids': ('number', 'charge en kg'),
        'reps': ('integer', 'répétitions'),
        'notes': ('string', 'ressenti'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        final ex = '${a['exercice'] ?? ''}'.trim();
        switch ('${a['action']}') {
          case 'noter':
            await c.add('sport', {
              'exercise': ex,
              'weight': (a['poids'] as num?)?.toDouble(),
              'reps': (a['reps'] as num?)?.toInt(),
              'text': '${a['notes'] ?? ''}',
            });
            final (best, _, _) = c.progress(ex);
            final w = (a['poids'] as num?)?.toDouble() ?? 0;
            return w >= best && w > 0 ? 'Noté, et c\'est ton record sur $ex !' : 'Séance notée.';
          case 'progres':
            final (best, last, n) = c.progress(ex);
            if (n == 0) return 'Aucune séance de $ex notée.';
            return {'record_kg': best, 'seances': n, 'derniere': last?.data};
          default:
            return [for (final e in c.list('sport').reversed.take(40)) e.data];
        }
      },
    ),
    HubTool(
      name: 'carnet_jeux',
      description:
          'Mes jeux vidéo : action=session + jeu + minutes (« 2 h de Roblox ») ; action=statut + jeu + '
          'statut (en cours, en pause, fini, abandonné) ; action=liste.',
      params: {
        'action': ('string', 'session, statut ou liste'),
        'jeu': ('string', 'nom du jeu'),
        'minutes': ('integer', 'temps joué'),
        'statut': ('string', 'en cours, en pause, fini ou abandonné'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        final g = '${a['jeu'] ?? ''}'.trim();
        switch ('${a['action']}') {
          case 'session':
            await c.add('games', {'game': g, 'minutes': (a['minutes'] as num?)?.toInt() ?? 0});
            return 'Session de $g notée.';
          case 'statut':
            await c.add('games', {'game': g, 'status': '${a['statut'] ?? 'en cours'}'});
            return '$g : ${a['statut']}.';
          default:
            final status = <String, String>{}, minutes = <String, int>{};
            for (final e in c.list('games')) {
              final n = '${e.data['game']}';
              if (e.data['status'] != null) status[n] = '${e.data['status']}';
              minutes[n] = (minutes[n] ?? 0) + ((e.data['minutes'] as num?)?.toInt() ?? 0);
            }
            return {
              for (final n in {...status.keys, ...minutes.keys})
                n: {'statut': status[n] ?? 'en cours', 'minutes_total': minutes[n] ?? 0},
            };
        }
      },
    ),
    HubTool(
      name: 'carnet_poemes',
      description:
          'Mes poèmes : action=enregistrer + titre + texte quand je partage un poème à garder ; '
          'action=liste ; action=lire + titre (pour que tu me fasses un retour dessus).',
      params: {
        'action': ('string', 'enregistrer, liste ou lire'),
        'titre': ('string', 'titre'),
        'texte': ('string', 'le poème'),
      },
      required: ['action'],
      run: (a) async {
        await c.load();
        switch ('${a['action']}') {
          case 'enregistrer':
            await c.add('poems', {'title': '${a['titre'] ?? 'Sans titre'}', 'text': '${a['texte'] ?? ''}'});
            return 'Poème enregistré.';
          case 'lire':
            final q = '${a['titre'] ?? ''}'.toLowerCase();
            final p = c.list('poems').where((e) => '${e.data['title']}'.toLowerCase().contains(q)).lastOrNull;
            return p == null ? 'Poème introuvable.' : {'titre': p.data['title'], 'texte': p.text};
          default:
            return [for (final e in c.list('poems')) '${e.data['title']}'];
        }
      },
    ),
    HubTool(
      name: 'carnet_meteo',
      description:
          'Vraie météo du jour et de demain + conseil de tenue (manteau, parapluie…). Pour « qu\'est-ce '
          'que je mets ? », « il va pleuvoir ? ». ville facultative (sinon ma ville).',
      params: {'ville': ('string', 'ville (facultatif)')},
      run: (a) async {
        await c.load();
        final v = '${a['ville'] ?? ''}'.trim();
        return Weather.forCity(v.isEmpty ? city : v);
      },
    ),
    HubTool(
      name: 'actualites',
      description:
          'Les dernières actualités (franceinfo, Le Monde, France 24…) : zone=france, monde, sport, '
          'tech ou tout. Pour le topo du matin / du soir ou « quoi de neuf dans le monde ? ».',
      params: {
        'zone': ('string', 'france, monde, sport, tech ou tout'),
        'nombre': ('integer', 'nombre de titres par zone (8 par défaut)'),
      },
      run: (a) async {
        final n = ((a['nombre'] as num?)?.toInt() ?? 8).clamp(1, 20);
        final z = '${a['zone'] ?? 'tout'}'.toLowerCase();
        final zones = z == 'tout' ? const ['france', 'monde'] : [z];
        return {
          for (final zone in zones) zone: [for (final i in await News.latest(zone, max: n)) i.toJson()],
        };
      },
    ),
    HubTool(
      name: 'carnet_bilan_du_soir',
      description:
          'Bilan du soir : ce que j\'ai fait aujourd\'hui (tâches, notes, dépenses, sport, jeux). '
          'Complète avec l\'agenda de demain et les devoirs si tu les as.',
      run: (_) async {
        await c.load();
        return c.eveningRecap();
      },
    ),
    HubTool(
      name: 'carnet_protocole',
      description:
          'Protocoles (« Nexo, protocole travail ») : une suite d\'actions préparées (ouvrir des '
          'applis, lancer une playlist, mettre en pause, prévenir le téléphone…). action=lancer + nom, '
          'action=liste.',
      params: {'action': ('string', 'lancer ou liste'), 'nom': ('string', 'nom du protocole')},
      required: ['action'],
      run: (a) async {
        await c.load();
        if ('${a['action']}' == 'liste') return c.protocols.keys.toList();
        return runProtocol('${a['nom'] ?? ''}');
      },
    ),
    HubTool(
      name: 'carnet_presse_papier',
      description:
          'Historique de mon presse-papier (si je l\'ai activé) : action=chercher + requete pour '
          'retrouver un texte copié avant, action=recent.',
      params: {'action': ('string', 'chercher ou recent'), 'requete': ('string', 'mots cherchés')},
      required: ['action'],
      run: (a) async {
        await c.load();
        final l = c.list('clipboard').reversed.toList();
        if (l.isEmpty) {
          return 'Rien : l\'historique du presse-papier est désactivé ou vide (Carnet → Réglages).';
        }
        final q = '${a['requete'] ?? ''}'.toLowerCase();
        final hits = '${a['action']}' == 'chercher' ? l.where((e) => e.text.toLowerCase().contains(q)) : l;
        return [
          for (final e in hits.take(15)) {'texte': e.text, 'copie_le': e.at},
        ];
      },
    ),
    HubTool(
      name: 'carnet_notifier_telephone',
      description:
          'Envoie une notification sur mon téléphone (appli ntfy), quand je demande d\'être prévenu '
          'sur mon tel ou pour une alerte importante.',
      params: {'titre': ('string', 'titre'), 'message': ('string', 'message'), 'urgent': ('boolean', 'urgent')},
      required: ['message'],
      run: (a) async {
        await c.load();
        await PhoneNotify.send(ntfy, '${a['titre'] ?? 'Nexo'}', '${a['message']}', urgent: a['urgent'] == true);
        return 'Notification envoyée sur ton téléphone.';
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final todos = [
        for (final t in c.list('todos'))
          if (!t.done) t.text,
      ];
      final now = DateTime.now();
      final (spent, _, _) = c.money(DateTime(now.year, now.month));
      final theme = Theme.of(context);
      // La météo en bandeau, les tâches en pastilles, deux chiffres en bas.
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (city.isNotEmpty)
              FutureBuilder(
                future: Weather.forCity(city),
                builder: (context, snap) => !snap.hasData
                    ? const SizedBox.shrink()
                    : Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF4FC3F7).withValues(alpha: 0.25),
                              const Color(0xFF7C5CFF).withValues(alpha: 0.12),
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            Text('${snap.data!['icone']}', style: const TextStyle(fontSize: 22)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${snap.data!['maintenant']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  Text(
                                    '${snap.data!['tenue']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            Expanded(
              child: todos.isEmpty
                  ? Center(
                      child: Text(
                        'Rien à faire 🎉\nDis à Nexo « ajoute … à ma liste ».',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in todos.take(6))
                            Container(
                              constraints: const BoxConstraints(maxWidth: 190),
                              padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: color.withValues(alpha: 0.25)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.radio_button_unchecked_rounded, size: 14, color: color),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      t,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (todos.length > 6)
                            Padding(
                              padding: const EdgeInsets.all(5),
                              child: Text('+${todos.length - 6}', style: theme.textTheme.labelSmall),
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.euro_rounded,
                    value: '${spent.toStringAsFixed(0)} €',
                    label: 'dépensés ce mois-ci',
                    color: color,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    icon: Icons.lightbulb_outline_rounded,
                    value: '${c.list('inbox').length}',
                    label: 'idées à trier',
                    color: const Color(0xFFFFB300),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget buildPage(BuildContext context) => _CarnetPage(module: this);
}

class _CarnetPage extends StatelessWidget {
  const _CarnetPage({required this.module});
  final CarnetModule module;

  static const tabs = [
    ('Tâches', Icons.checklist_rounded),
    ('Idées', Icons.lightbulb_rounded),
    ('Notes', Icons.sticky_note_2_rounded),
    ('Mémoire', Icons.psychology_alt_rounded),
    ('Budget', Icons.savings_rounded),
    ('Sport', Icons.fitness_center_rounded),
    ('Jeux', Icons.sports_esports_rounded),
    ('Poèmes', Icons.edit_note_rounded),
    ('Protocoles', Icons.play_circle_rounded),
    ('Presse-papier', Icons.content_paste_rounded),
    ('Réglages', Icons.settings_rounded),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: tabs.length,
    child: Scaffold(
      appBar: AppBar(
        title: Text(module.name),
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final (t, i) in tabs) Tab(icon: Icon(i), text: t)],
        ),
      ),
      body: ListenableBuilder(
        listenable: module.c,
        builder: (context, _) => TabBarView(
          children: [
            _TodoTab(m: module),
            _TextList(
              m: module,
              list: 'inbox',
              hint: 'Une pensée, une idée, un truc à pas oublier…',
              empty: 'Boîte vide. Dis à Nexo « note ça : … », il range plus tard.',
              action: (
                'Demander à Nexo de trier',
                () => ClaudeModule.askClicky(
                  'Trie mes idées en vrac du carnet : range chacune au bon endroit (tâche, note, budget, agenda…) puis retire-la de la boîte.',
                ),
              ),
            ),
            _TextList(m: module, list: 'notes', hint: 'Nouvelle note', empty: 'Aucune note.'),
            _TextList(
              m: module,
              list: 'memory',
              hint: 'Quelque chose que Nexo doit savoir sur toi',
              empty: 'Nexo ne sait encore rien de toi. Dis-lui « retiens que … ».',
            ),
            _BudgetTab(m: module),
            _SportTab(m: module),
            _GamesTab(m: module),
            _PoemsTab(m: module),
            _ProtocolsTab(m: module),
            _ClipboardTab(m: module),
            _SettingsTab(m: module),
          ],
        ),
      ),
    ),
  );
}

/// Champ d'ajout en haut d'une liste.
class _AddBar extends StatefulWidget {
  const _AddBar({required this.hint, required this.onAdd});
  final String hint;
  final Future<void> Function(String text) onAdd;

  @override
  State<_AddBar> createState() => _AddBarState();
}

class _AddBarState extends State<_AddBar> {
  final t = TextEditingController();

  Future<void> _go() async {
    final v = t.text.trim();
    if (v.isEmpty) return;
    t.clear();
    await widget.onAdd(v);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: TextField(
      controller: t,
      onSubmitted: (_) => _go(),
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(icon: const Icon(Icons.add_rounded), onPressed: _go),
      ),
    ),
  );
}

class _TodoTab extends StatelessWidget {
  const _TodoTab({required this.m});
  final CarnetModule m;

  @override
  Widget build(BuildContext context) {
    final l = m.c.list('todos');
    final todo = [
      for (final t in l)
        if (!t.done) t,
    ];
    final done = [
      for (final t in l.reversed)
        if (t.done) t,
    ];
    return ListView(
      children: [
        _AddBar(hint: 'Nouvelle tâche', onAdd: (v) => m.c.add('todos', {'text': v})),
        if (l.isEmpty) const Padding(padding: EdgeInsets.all(24), child: EmptyHint('Rien à faire 🎉')),
        for (final t in todo)
          CheckboxListTile(
            value: false,
            title: Text(t.text),
            subtitle: Text(timeAgo(t.at)),
            onChanged: (_) =>
                m.c.change('todos', t.id, {'done': true, 'doneAt': DateTime.now().millisecondsSinceEpoch}),
            secondary: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => m.c.remove('todos', t.id),
            ),
          ),
        if (done.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Fait')),
        for (final t in done.take(30))
          CheckboxListTile(
            value: true,
            title: Text(t.text, style: const TextStyle(decoration: TextDecoration.lineThrough)),
            onChanged: (_) => m.c.change('todos', t.id, {'done': false}),
            secondary: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => m.c.remove('todos', t.id),
            ),
          ),
      ],
    );
  }
}

class _TextList extends StatelessWidget {
  const _TextList({required this.m, required this.list, required this.hint, required this.empty, this.action});
  final CarnetModule m;
  final String list;
  final String hint;
  final String empty;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final l = m.c.list(list).reversed.toList();
    return ListView(
      children: [
        _AddBar(hint: hint, onAdd: (v) => m.c.add(list, {'text': v})),
        if (action != null && l.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton.icon(
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(action!.$1),
                onPressed: action!.$2,
              ),
            ),
          ),
        if (l.isEmpty) Padding(padding: const EdgeInsets.all(24), child: EmptyHint(empty)),
        for (final e in l)
          ListTile(
            title: SelectableText(e.text),
            subtitle: Text('${dayLabel(e.at)} ${hhmm(e.at)}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => m.c.remove(list, e.id),
            ),
          ),
      ],
    );
  }
}

class _BudgetTab extends StatelessWidget {
  const _BudgetTab({required this.m});
  final CarnetModule m;

  Future<void> _add(BuildContext context, bool income) async {
    final r = await askFields(
      context,
      title: income ? 'Argent reçu' : 'Dépense',
      labels: income ? const ['Montant (€)', 'Note'] : const ['Montant (€)', 'Catégorie (repas, jeux…)', 'Note'],
    );
    if (r == null) return;
    final v = double.tryParse(r[0].replaceAll(',', '.'));
    if (v == null) return;
    await m.c.add('money', {
      'amount': income ? v.abs() : -v.abs(),
      'category': income ? 'revenu' : r[1].trim(),
      'text': (income ? r[1] : r[2]).trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final (spent, earned, cats) = m.c.money(DateTime(now.year, now.month));
    final l = m.c.list('money').reversed.toList();
    final sorted = cats.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ce mois-ci', style: Theme.of(context).textTheme.labelLarge),
                Text(
                  '${(earned - spent).toStringAsFixed(2)} €',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text('${spent.toStringAsFixed(2)} € dépensés · ${earned.toStringAsFixed(2)} € reçus'),
                const SizedBox(height: 8),
                for (final e in sorted.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(width: 110, child: Text(e.key, overflow: TextOverflow.ellipsis)),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: spent == 0 ? 0 : e.value / spent,
                            minHeight: 8,
                            color: m.color,
                          ),
                        ),
                        SizedBox(width: 70, child: Text('${e.value.toStringAsFixed(0)} €', textAlign: TextAlign.right)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.remove_rounded),
              label: const Text('Dépense'),
              onPressed: () => _add(context, false),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('Argent reçu'),
              onPressed: () => _add(context, true),
            ),
          ],
        ),
        for (final e in l.take(100))
          ListTile(
            leading: Icon(
              e.amount < 0 ? Icons.south_east_rounded : Icons.north_east_rounded,
              color: e.amount < 0 ? Colors.redAccent : Colors.green,
            ),
            title: Text('${e.amount.toStringAsFixed(2)} € · ${e.category.isEmpty ? 'autre' : e.category}'),
            subtitle: Text([if (e.text.isNotEmpty) e.text, dayLabel(e.at)].join(' · ')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => m.c.remove('money', e.id),
            ),
          ),
      ],
    );
  }
}

class _SportTab extends StatelessWidget {
  const _SportTab({required this.m});
  final CarnetModule m;

  @override
  Widget build(BuildContext context) {
    final l = m.c.list('sport').reversed.toList();
    final best = <String, double>{};
    for (final e in l) {
      final ex = '${e.data['exercise']}';
      final w = (e.data['weight'] as num?)?.toDouble() ?? 0;
      if (w > (best[ex] ?? 0)) best[ex] = w;
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: const Text('Noter une série'),
          onPressed: () async {
            final r = await askFields(
              context,
              title: 'Nouvelle série',
              labels: const ['Exercice', 'Charge (kg)', 'Répétitions'],
            );
            if (r == null || r[0].trim().isEmpty) return;
            await m.c.add('sport', {
              'exercise': r[0].trim(),
              'weight': double.tryParse(r[1].replaceAll(',', '.')),
              'reps': int.tryParse(r[2]),
            });
          },
        ),
        if (best.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in best.entries)
                Chip(
                  avatar: const Icon(Icons.emoji_events_rounded, size: 16),
                  label: Text('${e.key} : ${e.value.toStringAsFixed(1)} kg'),
                ),
            ],
          ),
        ],
        if (l.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: EmptyHint('Dis à Nexo « 80 kg au squat pour 5 ».')),
        for (final e in l.take(80))
          ListTile(
            leading: const Icon(Icons.fitness_center_rounded),
            title: Text('${e.data['exercise']} · ${e.data['weight'] ?? '?'} kg × ${e.data['reps'] ?? '?'}'),
            subtitle: Text([if (e.text.isNotEmpty) e.text, dayLabel(e.at)].join(' · ')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => m.c.remove('sport', e.id),
            ),
          ),
      ],
    );
  }
}

class _GamesTab extends StatelessWidget {
  const _GamesTab({required this.m});
  final CarnetModule m;

  @override
  Widget build(BuildContext context) {
    final status = <String, String>{}, minutes = <String, int>{};
    for (final e in m.c.list('games')) {
      final n = '${e.data['game']}';
      if (e.data['status'] != null) status[n] = '${e.data['status']}';
      minutes[n] = (minutes[n] ?? 0) + ((e.data['minutes'] as num?)?.toInt() ?? 0);
    }
    final games = {...status.keys, ...minutes.keys}.toList()
      ..sort((a, b) => (minutes[b] ?? 0).compareTo(minutes[a] ?? 0));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: const Text('Noter une session'),
          onPressed: () async {
            final r = await askFields(context, title: 'Session de jeu', labels: const ['Jeu', 'Minutes']);
            if (r == null || r[0].trim().isEmpty) return;
            await m.c.add('games', {'game': r[0].trim(), 'minutes': int.tryParse(r[1]) ?? 0});
          },
        ),
        if (games.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: EmptyHint('Dis à Nexo « j\'ai joué 2 h à Roblox ».')),
        for (final g in games)
          ListTile(
            leading: const Icon(Icons.sports_esports_rounded),
            title: Text(g),
            subtitle: Text('${((minutes[g] ?? 0) / 60).toStringAsFixed(1)} h au total'),
            trailing: DropdownButton<String>(
              value: status[g] ?? 'en cours',
              items: [
                for (final s in const ['en cours', 'en pause', 'fini', 'abandonné'])
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: (v) => m.c.add('games', {'game': g, 'status': v}),
            ),
          ),
      ],
    );
  }
}

class _PoemsTab extends StatelessWidget {
  const _PoemsTab({required this.m});
  final CarnetModule m;

  @override
  Widget build(BuildContext context) {
    final l = m.c.list('poems').reversed.toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nouveau poème'),
          onPressed: () async {
            final title = TextEditingController(), body = TextEditingController();
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Nouveau poème'),
                content: SizedBox(
                  width: 460,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: title,
                        decoration: const InputDecoration(labelText: 'Titre'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: body,
                        minLines: 6,
                        maxLines: 14,
                        decoration: const InputDecoration(labelText: 'Poème', border: OutlineInputBorder()),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Garder')),
                ],
              ),
            );
            if (ok == true && body.text.trim().isNotEmpty) {
              await m.c.add('poems', {
                'title': title.text.trim().isEmpty ? 'Sans titre' : title.text.trim(),
                'text': body.text.trim(),
              });
            }
          },
        ),
        if (l.isEmpty) const Padding(padding: EdgeInsets.all(24), child: EmptyHint('Tes poèmes, gardés ici.')),
        for (final p in l)
          Card(
            child: ExpansionTile(
              shape: const Border(),
              title: Text('${p.data['title']}'),
              subtitle: Text(dayLabel(p.at)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(p.text, style: const TextStyle(height: 1.6, fontStyle: FontStyle.italic)),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.auto_awesome_rounded),
                      label: const Text('Avis de Nexo'),
                      onPressed: () => ClaudeModule.askClicky(
                        'Donne-moi un retour bienveillant et précis sur mon poème « ${p.data['title']} » (images, rythme, rimes, ce qui marche, une piste d\'amélioration) :\n${p.text}',
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Supprimer'),
                      onPressed: () => m.c.remove('poems', p.id),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProtocolsTab extends StatelessWidget {
  const _ProtocolsTab({required this.m});
  final CarnetModule m;

  static const kinds = {
    'dire': 'Nexo dit',
    'site': 'Ouvrir le site',
    'appli': 'Ouvrir l\'appli',
    'spotify': 'Spotify (playlist / chercher_jouer)',
    'musique': 'Musique (lecture / pause / suivant)',
    'notifier': 'Notifier le téléphone',
    'attendre': 'Attendre (secondes)',
  };

  static String describe(Map<String, dynamic> s) =>
      '${kinds[s['type']] ?? s['type']} : ${s['valeur'] ?? ''}${s['requete'] == null ? '' : ' « ${s['requete']} »'}';

  Future<void> _edit(BuildContext context, String? name, List<Map<String, dynamic>> steps) async {
    final n = TextEditingController(text: name ?? '');
    final lines = TextEditingController(
      text: [
        for (final s in steps) '${s['type']}: ${s['valeur'] ?? ''}${s['requete'] == null ? '' : ' | ${s['requete']}'}',
      ].join('\n'),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(name == null ? 'Nouveau protocole' : 'Protocole $name'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'Nom (« Nexo, protocole … »)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: lines,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Étapes, une par ligne'),
              ),
              const SizedBox(height: 6),
              const Text(
                'type: valeur — dire: …, site: https://…, appli: discord, spotify: playlist | focus, '
                'musique: pause, notifier: …, attendre: 2',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok != true || n.text.trim().isEmpty) return;
    final parsed = <Map<String, dynamic>>[];
    for (final l in lines.text.split('\n')) {
      final i = l.indexOf(':');
      if (i <= 0) continue;
      final type = l.substring(0, i).trim().toLowerCase();
      var value = l.substring(i + 1).trim();
      String? query;
      if (value.contains('|')) {
        query = value.substring(value.indexOf('|') + 1).trim();
        value = value.substring(0, value.indexOf('|')).trim();
      }
      parsed.add({'type': type, 'valeur': value, 'requete': ?query});
    }
    final all = m.c.protocols;
    if (name != null && name != n.text.trim()) all.remove(name);
    all[n.text.trim()] = parsed;
    await m.c.saveProtocols(all);
  }

  @override
  Widget build(BuildContext context) {
    final all = m.c.protocols;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Dis « Nexo, protocole travail » : il enchaîne toutes les étapes.'),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nouveau protocole'),
          onPressed: () => _edit(context, null, const []),
        ),
        for (final e in all.entries)
          Card(
            child: ListTile(
              leading: const Icon(Icons.play_circle_rounded),
              title: Text('Protocole ${e.key}'),
              subtitle: Text(e.value.map(describe).join('\n')),
              isThreeLine: e.value.length > 1,
              onTap: () => _edit(context, e.key, e.value),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Lancer',
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: () async {
                      final r = await m.runProtocol(e.key);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r)));
                      }
                    },
                  ),
                  IconButton(
                    tooltip: 'Supprimer',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => m.c.saveProtocols(all..remove(e.key)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ClipboardTab extends StatefulWidget {
  const _ClipboardTab({required this.m});
  final CarnetModule m;

  @override
  State<_ClipboardTab> createState() => _ClipboardTabState();
}

class _ClipboardTabState extends State<_ClipboardTab> {
  final q = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final c = widget.m.c;
    final on = c.setting<bool>('clipboard', false);
    final s = q.text.toLowerCase();
    final l = c.list('clipboard').reversed.where((e) => s.isEmpty || e.text.toLowerCase().contains(s)).toList();
    return ListView(
      children: [
        SwitchListTile(
          title: const Text('Garder l\'historique du presse-papier'),
          subtitle: const Text(
            'Ce que tu copies est gardé sur ce PC (pas les textes qui ressemblent à des mots de passe, '
            'ni ceux copiés dans une fenêtre sensible). Nexo peut le retrouver : « retrouve le lien que j\'ai copié ».',
          ),
          value: on,
          onChanged: (v) => c.setSetting('clipboard', v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: q,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Rechercher',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (l.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => c.clear('clipboard'), child: const Text('Tout effacer')),
          ),
        for (final e in l.take(200))
          ListTile(
            dense: true,
            title: Text(e.text, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text('${dayLabel(e.at)} ${hhmm(e.at)}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => c.remove('clipboard', e.id),
            ),
          ),
      ],
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.m});
  final CarnetModule m;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  late final city = TextEditingController(text: widget.m.city);
  late final topic = TextEditingController(text: widget.m.ntfy);
  String? info;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: city,
        decoration: InputDecoration(
          labelText: 'Ta ville (météo et conseil de tenue)',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.check_rounded),
            onPressed: () async {
              await widget.m.c.setSetting('city', city.text.trim());
              try {
                final w = await Weather.forCity(city.text.trim());
                setState(() => info = '${w['icone']} ${w['ville']} : ${w['maintenant']}. ${w['tenue']}');
              } catch (e) {
                setState(() => info = '$e');
              }
            },
          ),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: topic,
        decoration: InputDecoration(
          labelText: 'Topic ntfy (notifications sur ton téléphone)',
          helperText: 'Installe l\'appli ntfy, abonne-toi à un nom secret (ex. erik-clicky-9f2a), écris-le ici.',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: 'Envoyer un test',
            icon: const Icon(Icons.send_rounded),
            onPressed: () async {
              await widget.m.c.setSetting('ntfy', topic.text.trim());
              try {
                await PhoneNotify.send(topic.text.trim(), 'Nexo', 'Test : les notifications arrivent bien ✔');
                setState(() => info = 'Notification de test envoyée.');
              } catch (e) {
                setState(() => info = '$e');
              }
            },
          ),
        ),
      ),
      if (info != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(info!)),
    ],
  );
}
