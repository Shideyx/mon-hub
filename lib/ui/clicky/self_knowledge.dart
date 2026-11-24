import '../../core/hub_module.dart';
import '../../core/tool_router.dart';
import '../../core/version.dart';
import '../../core/whats_new.dart';
import 'skills.dart';

/// **Ce que Nexo sait de lui-même** : ses capacités (le catalogue « Ce que
/// Nexo sait faire » **et** ses vraies actions, pour qu'il ne dise jamais
/// « je ne sais pas faire » à tort), sa version et ses nouveautés.
///
/// Une seule source pour tout : les actions branchées (la liste réelle,
/// toujours à jour), le catalogue (`skills.dart`) et les versions publiées
/// sur GitHub (`WhatsNew`).
class SelfKnowledge {
  const SelfKnowledge._();

  /// Les mots qui ne servent pas à chercher.
  static const _stop = {
    'est',
    'ce',
    'que',
    'qu',
    'tu',
    'sais',
    'savoir',
    'peux',
    'pouvoir',
    'faire',
    'fais',
    'les',
    'des',
    'une',
    'un',
    'le',
    'la',
    'de',
    'du',
    'mon',
    'ma',
    'mes',
    'ton',
    'ta',
    'tes',
    'pour',
    'avec',
    'sur',
    'dans',
    'quoi',
    'comment',
    'moi',
    'toi',
    'il',
    'elle',
    'et',
    'ou',
    'a',
    'au',
    'aux',
    'en',
    'je',
    'j',
    'me',
    'te',
    'se',
    'pas',
    'capable',
    'capacite',
    'capacites',
    'smily',
    'clicky',
    'stp',
    'svp',
  };

  static List<String> words(String q) => [
    for (final w in ToolRouter.normalize(q).split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 3 && !_stop.contains(w)) w,
  ];

  /// Un mot de la question retrouvé dans un texte (« floute » ≈ « flou »).
  static bool _hit(String hay, String w) {
    if (hay.contains(w)) return true;
    final root = w.length > 5 ? w.substring(0, w.length - 2) : w;
    return root.length >= 4 && hay.contains(root);
  }

  /// Ce qu'il sait faire sur [q] : les lignes du catalogue et ses actions
  /// qui en parlent, les plus proches d'abord.
  static ({List<String> skills, List<HubTool> tools}) search(String q, List<HubTool> tools, {int max = 8}) {
    final ws = words(q);
    if (ws.isEmpty) return (skills: const [], tools: const []);
    int score(String text) {
      final hay = ToolRouter.normalize(text);
      return ws.where((w) => _hit(hay, w)).length;
    }

    final lines = <(int, String)>[
      for (final g in ClickySkills.groups)
        for (final s in g.items) (score('${g.title} ${s.text}'), '${g.emoji} ${s.text}'),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    final acts = <(int, HubTool)>[for (final t in tools) (score('${t.name.replaceAll('_', ' ')} ${t.description}'), t)]
      ..sort((a, b) => b.$1.compareTo(a.$1));
    final need = ws.length == 1 ? 1 : 2;
    return (
      skills: [
        for (final (s, l) in lines.take(max))
          if (s >= need) l,
      ],
      tools: [
        for (final (s, t) in acts.take(max))
          if (s >= need) t,
      ],
    );
  }

  /// La réponse de l'outil `clicky_capacites`.
  static Map<String, dynamic> answer(String q, List<HubTool> tools) {
    if (words(q).isEmpty) {
      return {
        'resume':
            'Je sais faire plus de ${ClickySkills.count} choses, rangées en ${ClickySkills.groups.length} thèmes : '
            '${ClickySkills.groups.map((g) => g.title).join(', ')}. Tout est dans « Ce que Nexo sait faire » (bouton ✨).',
        'themes': [
          for (final g in ClickySkills.groups)
            {'theme': '${g.emoji} ${g.title}', 'exemples': g.items.take(3).map((s) => s.text).toList()},
        ],
        'nombre_actions': tools.length,
      };
    }
    final r = search(q, tools);
    if (r.skills.isEmpty && r.tools.isEmpty) {
      return {
        'resume':
            'Je ne trouve rien sur « $q » dans ce que je sais faire. Je peux quand même essayer avec mes actions '
            'générales (PC, navigateur, recherche internet), ou tu peux le demander à mon créateur.',
        'trouve': false,
      };
    }
    return {
      'resume': [
        if (r.skills.isNotEmpty) 'Oui : ${r.skills.take(3).join(' · ')}',
        if (r.skills.isEmpty) 'Oui, avec mes actions : ${r.tools.take(3).map((t) => t.name).join(', ')}.',
      ].join(' '),
      'trouve': true,
      'catalogue': r.skills,
      'actions': [
        for (final t in r.tools) {'nom': t.name, 'description': t.description},
      ],
    };
  }

  /// Une ligne fixe pour ses consignes (elle ne change qu'avec une mise à
  /// jour : relue depuis le cache de Claude).
  static String promptBlock() {
    final last = WhatsNew.instance.cached.firstOrNull;
    return 'Toi : Mon Hub $appVersion. Tu sais faire plus de ${ClickySkills.count} choses '
        '(${ClickySkills.groups.map((g) => g.title).join(', ')}). Avant de dire que tu ne sais pas faire quelque '
        'chose, vérifie avec clicky_capacites ; « quoi de neuf ? » → clicky_nouveautes'
        '${last == null || last.notes.isEmpty ? '' : ' (dernière mise à jour ${last.tag} : ${last.notes.first})'}.';
  }

  static List<HubTool> tools(List<HubTool> Function() all) => [
    HubTool(
      name: 'clicky_capacites',
      description:
          'Ce que Nexo sait faire : cherche dans son catalogue de capacités ET dans toutes ses actions réelles. '
          'À utiliser avant de répondre « je ne sais pas faire ça », et pour « tu sais faire quoi ? », « tu peux '
          '… ? », « comment je fais pour … avec toi ? ». Sans recherche : la liste des thèmes.',
      params: {'recherche': ('string', 'Ce que la personne veut faire (mots-clés), ou vide pour tout')},
      run: (a) async => answer('${a['recherche'] ?? ''}', all()),
    ),
    ...WhatsNew.instance.tools(),
  ];
}
