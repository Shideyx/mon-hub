// Clicky autonome : il regarde la situation, décide tout seul d'une chose
// utile à faire, te la propose (à l'oral et dans sa boîte) et la fait après
// ton accord. Il apprend de tes réponses.

import 'dart:convert';

import '../../core/hub_module.dart';
import 'tutor.dart' show normalize;

/// Une décision de Clicky, en attente de ton accord.
class ClickyIdea {
  ClickyIdea({required this.say, required this.tool, this.args = const {}, this.why = '', String? id})
    : id = id ?? '${DateTime.now().microsecondsSinceEpoch}';

  final String id;

  /// Ce qu'il te dit pour proposer (une phrase, à l'oral).
  final String say;

  /// L'action de Mon Hub à lancer, ou 'agent' (une tâche en plusieurs
  /// étapes confiée au cerveau de Clicky, args['tache']).
  final String tool;
  final Map<String, dynamic> args;
  final String why;

  Map<String, dynamic> toJson() => {'id': id, 'say': say, 'tool': tool, 'args': args, 'why': why};

  static ClickyIdea? fromJson(Object? j) {
    if (j is! Map || j['say'] is! String || j['tool'] is! String) return null;
    return ClickyIdea(
      id: '${j['id'] ?? ''}',
      say: j['say'] as String,
      tool: j['tool'] as String,
      args: (j['args'] is Map) ? (j['args'] as Map).cast<String, dynamic>() : const {},
      why: '${j['why'] ?? ''}',
    );
  }
}

class Autonomy {
  Autonomy._();

  /// Ce qu'il peut décider de lui-même (toujours avec ton accord).
  static const allowed = {
    'agenda_ajouter',
    'agenda_ajouter_plan',
    'carnet_taches_notes',
    'carnet_idees',
    'carnet_meteo',
    'revision_preparer_controle',
    'revision_planifier',
    'revision_lancer',
    'revision_generer',
    'assistant_ajouter_plan_journee',
    'assistant_priorites',
    'assistant_briefing',
    'musique_commande',
    'youtube_chercher',
    'doc_creer',
    'pc_ranger_apercu',
    'drive_ranger_apercu',
    'agent',
  };

  /// Jamais de lui-même, même avec accord : envoyer un message à
  /// quelqu'un, supprimer, lancer une commande, écrire un fichier.
  static final never = RegExp(r'envoyer|repondre|supprimer|effacer|pc_commande|pc_ecrire|appeler|^mcp_|ranger$|annuler');

  static bool usable(String tool, Set<String> available) =>
      !never.hasMatch(tool) && allowed.contains(tool) && (tool == 'agent' || available.contains(tool));

  /// La consigne pour décider (Gemini, jamais Claude).
  static String prompt({
    required String situation,
    required List<HubTool> tools,
    String name = '',
    String window = '',
    String memory = '',
    String likes = '',
    String dislikes = '',
    required DateTime now,
  }) {
    final who = name.trim().isEmpty ? 'la personne' : name.trim();
    final list = [
      for (final t in tools)
        if (usable(t.name, {t.name}))
          '- ${t.name} : ${t.description}${t.params.isEmpty ? '' : ' (paramètres : ${t.params.entries.map((e) => '${e.key} = ${e.value.$2}').join(' ; ')})'}',
      '- agent : une tâche en plusieurs étapes que tu feras toi-même (chercher des infos, préparer un exposé, organiser…) (paramètres : tache = ce qu\'il faut faire, précisément)',
    ];
    return '''
Tu es Clicky, l'assistant personnel autonome de $who (un·e lycéen·ne). Il est ${now.hour} h ${now.minute.toString().padLeft(2, '0')}.
Voici sa situation, préparée par son appli :
---
$situation
---
${window.isEmpty ? '' : 'Fenêtre ouverte en ce moment : « $window ».\n'}${memory.isEmpty ? '' : '$memory\n'}${likes.isEmpty ? '' : 'Ce que $who accepte volontiers : $likes.\n'}${dislikes.isEmpty ? '' : 'Ce que $who refuse souvent (évite) : $dislikes.\n'}
Actions possibles :
${list.join('\n')}

Décide toi-même UNE initiative vraiment utile MAINTENANT (adaptée à l'heure et à ce qu'il fait, pas une répétition, pas un rappel de devoir déjà fait), que tu feras après son accord — ou rien si ce n'est pas le moment. Ne propose jamais d'envoyer un message à quelqu'un ni de supprimer quoi que ce soit.
Réponds seulement en JSON : {"dire":"ce que tu lui proposes, une phrase naturelle à l'oral qui finit par une demande d'accord","outil":"nom","args":{...},"pourquoi":"raison courte"} — ou {"rien":true}.''';
  }

  /// La décision renvoyée par l'IA (null si rien ou mal formée).
  static ClickyIdea? parse(Object? json, Set<String> available) {
    if (json is! Map || json['rien'] == true) return null;
    final tool = '${json['outil'] ?? ''}'.trim();
    final say = '${json['dire'] ?? ''}'.trim();
    if (say.isEmpty || say.length > 260 || !usable(tool, available)) return null;
    final args = json['args'] is Map ? (json['args'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    if (tool == 'agent' && '${args['tache'] ?? ''}'.trim().length < 8) return null;
    return ClickyIdea(say: say, tool: tool, args: args, why: '${json['pourquoi'] ?? ''}');
  }

  /// Sans IA : quelques décisions évidentes, d'après la situation.
  /// [ctx] : 'controle' (matière, dans ≤ 3 jours, sans fiche), 'cartes'
  /// (à revoir), 'trop' (trop de choses à faire), 'briefing_fait'.
  static ClickyIdea? rules(Map<String, Object?> ctx, DateTime now, {Set<String> available = const {}, Set<String> skip = const {}}) {
    bool can(String t) => usable(t, available) && !skip.contains(t);
    final test = '${ctx['controle'] ?? ''}'.trim();
    if (test.isNotEmpty && can('revision_preparer_controle')) {
      return ClickyIdea(
        say: 'Ton contrôle de $test approche. Je te prépare une fiche, des cartes et un quiz maintenant ?',
        tool: 'revision_preparer_controle',
        args: {'matiere': test},
        why: 'contrôle bientôt',
      );
    }
    if (now.hour >= 7 && now.hour < 10 && ctx['briefing_fait'] != true && can('assistant_briefing')) {
      return ClickyIdea(say: 'Je te fais le point sur ta journée ?', tool: 'assistant_briefing', why: 'le matin');
    }
    if (now.hour >= 16 && now.hour < 21 && ctx['trop'] == true && can('assistant_ajouter_plan_journee')) {
      return ClickyIdea(
        say: 'Tu as pas mal de choses à faire. Je t\'organise ta soirée dans ton agenda ?',
        tool: 'assistant_ajouter_plan_journee',
        why: 'soirée chargée',
      );
    }
    final cards = (ctx['cartes'] as num?)?.toInt() ?? 0;
    if (cards >= 10 && now.hour >= 17 && now.hour < 22 && can('revision_lancer')) {
      return ClickyIdea(say: 'Tu as $cards cartes à revoir. On en fait quelques-unes ensemble ?', tool: 'revision_lancer', args: {'mode': 'cartes'}, why: 'cartes à revoir');
    }
    return null;
  }

  static final _yes = RegExp(r'^(?:oui|ouais|ok|okay|d accord|dac|vas y|go|fais le|fais la|c est parti|carrement|grave|volontiers|yes|bien sur|allez|banco)(?: (?:vas y|fais le|merci|clicky))*$');
  static final _no = RegExp(r'^(?:non|nan|non merci|pas maintenant|plus tard|laisse|laisse tomber|pas besoin|ca ira|nope|stop)(?: (?:merci|clicky))*$');

  /// Réponse à une proposition : true (oui), false (non), null (autre chose).
  static bool? answer(String said) {
    final n = normalize(said).replaceFirst(RegExp(r'^(?:clicky )'), '').trim();
    if (_yes.hasMatch(n)) return true;
    if (_no.hasMatch(n)) return false;
    return null;
  }

  /// Résumé d'un résultat pour le dire (sans IA quand c'est simple).
  static String plainResult(Object? r) {
    if (r == null) return 'C\'est fait.';
    if (r is String) return r.length > 220 ? '${r.substring(0, 220)}…' : r;
    if (r is Map && r['ok'] == true) return 'C\'est fait.';
    if (r is Map && r['ajoutes'] is num) return 'C\'est fait : ${r['ajoutes']} ajout${(r['ajoutes'] as num) > 1 ? 's' : ''} dans ton agenda.';
    final s = jsonEncode(r);
    return s.length > 200 ? 'C\'est fait.' : 'C\'est fait.';
  }
}
