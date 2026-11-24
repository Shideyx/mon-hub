import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import '../../core/prompt_shield.dart';
import 'tutor.dart' show normalize;

/// Un souvenir de Nexo sur la personne.
@immutable
class Memory {
  const Memory({
    required this.id,
    required this.topic,
    required this.text,
    required this.at,
    required this.seen,
    this.weight = 1,
    this.pinned = false,
  });

  final String id;

  /// Le sujet (voir [MemoryRules.topics]).
  final String topic;
  final String text;

  /// Appris le…
  final DateTime at;

  /// Revu / confirmé pour la dernière fois le…
  final DateTime seen;

  /// Combien de fois il l'a entendu (plus c'est haut, plus c'est sûr).
  final int weight;

  /// Dit par la personne (« retiens que… ») : jamais oublié tout seul.
  final bool pinned;

  Memory copyWith({String? text, String? topic, DateTime? seen, int? weight, bool? pinned}) => Memory(
    id: id,
    topic: topic ?? this.topic,
    text: text ?? this.text,
    at: at,
    seen: seen ?? this.seen,
    weight: weight ?? this.weight,
    pinned: pinned ?? this.pinned,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    's': topic,
    't': text,
    'a': at.millisecondsSinceEpoch,
    'v': seen.millisecondsSinceEpoch,
    if (weight != 1) 'w': weight,
    if (pinned) 'p': true,
  };

  static Memory? fromJson(Object? j) {
    if (j is! Map || '${j['t'] ?? ''}'.trim().isEmpty) return null;
    DateTime ms(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : DateTime(2026);
    return Memory(
      id: '${j['id'] ?? ''}',
      topic: MemoryRules.topics.containsKey(j['s']) ? '${j['s']}' : 'divers',
      text: '${j['t']}'.trim(),
      at: ms(j['a']),
      seen: ms(j['v'] ?? j['a']),
      weight: (j['w'] as num?)?.toInt() ?? 1,
      pinned: j['p'] == true,
    );
  }
}

/// Ce qu'un « rêve » a donné : souvenirs rangés, idées de capacités, et le
/// rêve à raconter.
@immutable
class DreamResult {
  const DreamResult({this.memories = const [], this.skills = const [], this.dream = '', this.local = false});

  /// (sujet, texte)
  final List<(String, String)> memories;

  /// (phrase qui déclenche, consigne pour Nexo)
  final List<(String, String)> skills;
  final String dream;

  /// Fait par une IA locale (Ollama) — sinon par des règles, sans IA.
  final bool local;
}

/// Les règles de la mémoire, **sans fichiers** : testables.
class MemoryRules {
  const MemoryRules._();

  /// Les tiroirs de sa mémoire.
  static const topics = {
    'moi': '🙂 Qui tu es',
    'proches': '👥 Tes proches',
    'ecole': '🎒 L\'école',
    'gouts': '❤️ Ce que tu aimes',
    'projets': '✍️ Tes projets (poèmes, lecture…)',
    'objectifs': '🎯 Tes objectifs',
    'habitudes': '🕒 Tes habitudes',
    'a_eviter': '🙅 Ce que tu ne veux pas que je fasse',
    'savoir': '💡 Ce que tu as appris',
    'divers': '📦 Divers',
  };

  /// Au plus ce nombre de souvenirs (les plus faibles partent d'abord).
  static const max = 400;

  static Set<String> _words(String s) => {
    for (final w in normalize(s).split(RegExp(r'[^a-z0-9]+')))
      if (w.length > 2 && !_stop.contains(w)) w.endsWith('s') && w.length > 4 ? w.substring(0, w.length - 1) : w,
  };

  static const _stop = {
    'les', 'des', 'une', 'est', 'que', 'qui', 'pour', 'pas', 'dans', 'avec', 'sur', 'son', 'ses', 'mon', 'mes',
    'ton', 'tes', 'elle', 'lui', 'aime', 'bien', 'tres', 'plus', 'tout', 'fait', 'etre', 'avoir', 'par', 'mais',
    'aux', 'ces', 'cette', 'quand', 'comme', 'personne', 'erik',
  };

  /// Deux souvenirs disent-ils la même chose ?
  static bool same(String a, String b) {
    final x = _words(a), y = _words(b);
    if (x.isEmpty || y.isEmpty) return normalize(a) == normalize(b);
    final inter = x.intersection(y).length;
    return inter / (x.length < y.length ? x.length : y.length) >= 0.75 && inter >= 2 ||
        normalize(a) == normalize(b);
  }

  /// Le sujet d'un souvenir, deviné sans IA.
  static String topicOf(String text) {
    final n = normalize(text);
    if (RegExp(r'\b(?:ne (?:veut|veux) (?:pas|plus)|deteste qu|n aime pas qu|arrete de|ne (?:me|lui) (?:dis|parle))').hasMatch(n)) {
      return 'a_eviter';
    }
    if (RegExp(r'\b(?:poeme|poesie|ecri|roman|histoire|lecture|lit |livre|lire|dessin|musique qu il fait|projet|chanson)').hasMatch(n)) {
      return 'projets';
    }
    if (RegExp(r'\b(?:veut|voudrait|objectif|reve de|aimerait|compte) ').hasMatch(n)) return 'objectifs';
    if (RegExp(r'\b(?:mere|pere|maman|papa|frere|soeur|ami|amie|copain|copine|cousin|cousine|prof)\b').hasMatch(n)) {
      return 'proches';
    }
    if (RegExp(r'\b(?:college|lycee|classe|seconde|premiere|terminale|bac|brevet|controle|note|matiere|maths|svt|francais)\b').hasMatch(n)) {
      return 'ecole';
    }
    if (RegExp(r'\b(?:aime|adore|prefere|fan|joue a|ecoute|kiffe)\b').hasMatch(n)) return 'gouts';
    if (RegExp(r'\b(?:chaque|tous les|d habitude|souvent|le soir|le matin|se couche|se leve)\b').hasMatch(n)) {
      return 'habitudes';
    }
    if (RegExp(r'\b(?:s appelle|ans\b|habite|ne le|nee le|anniversaire|il est|elle est)').hasMatch(n)) return 'moi';
    return 'divers';
  }

  /// Ajoute (ou renforce) des souvenirs. Renvoie (liste, nombre de nouveaux).
  static (List<Memory>, int) merge(List<Memory> old, List<(String, String)> found, DateTime now, {bool pinned = false}) {
    final out = [...old];
    var added = 0;
    for (final (topic0, text0) in found) {
      final text = text0.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.length < 4 || text.length > 300) continue;
      final topic = topics.containsKey(topic0) ? topic0 : topicOf(text);
      final i = out.indexWhere((m) => same(m.text, text));
      if (i >= 0) {
        final m = out[i];
        // La version la plus récente gagne (« il a 15 ans » remplace « 14 ans »).
        out[i] = m.copyWith(text: text, topic: topic, seen: now, weight: m.weight + 1, pinned: m.pinned || pinned);
      } else {
        out.add(
          Memory(id: '${now.microsecondsSinceEpoch}-$added', topic: topic, text: text, at: now, seen: now, pinned: pinned),
        );
        added++;
      }
    }
    return (prune(out, now), added);
  }

  /// L'oubli naturel : un détail entendu une seule fois et jamais revu
  /// depuis 60 jours s'efface. Ce que tu as demandé de retenir, jamais.
  static List<Memory> prune(List<Memory> l, DateTime now) {
    final keep = [
      for (final m in l)
        if (m.pinned || m.weight > 1 || m.topic == 'moi' || m.topic == 'proches' || m.topic == 'a_eviter' ||
            now.difference(m.seen) < const Duration(days: 60))
          m,
    ];
    if (keep.length <= max) return keep;
    keep.sort((a, b) => score(b, now).compareTo(score(a, now)));
    return keep.take(max).toList();
  }

  static double score(Memory m, DateTime now) {
    final days = now.difference(m.seen).inDays;
    return (m.pinned ? 50 : 0) + m.weight * 3 - days / 10;
  }

  /// Les souvenirs utiles pour cette question (les plus proches + les plus
  /// importants : qui tu es, ce que tu ne veux pas).
  static List<Memory> relevant(List<Memory> all, String question, DateTime now, {int k = 10}) {
    final q = _words(question);
    final scored = <(Memory, double)>[];
    for (final m in all) {
      final overlap = q.isEmpty ? 0 : _words(m.text).intersection(q).length;
      var s = overlap * 10.0 + score(m, now);
      if (m.topic == 'a_eviter') s += 25;
      if (m.topic == 'moi') s += 12;
      scored.add((m, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (m, _) in scored.take(k)) m];
  }

  /// Le bloc des consignes de l'IA.
  static String promptBlock(List<Memory> picked) {
    if (picked.isEmpty) return '';
    final lines = [for (final m in picked) '- (${m.topic}) ${m.text}'];
    return 'Ta mémoire à long terme sur la personne (rangée par sujets ; sers-t\'en naturellement, ne la récite '
        'pas ; « a_eviter » = à respecter absolument) :\n${PromptShield.wrap('memoire', lines.join('\n'))}\n';
  }

  /// « retiens que je préfère les mangas aux romans » → le souvenir.
  static String? rememberRequest(String said) {
    final n = said.trim();
    final m = RegExp(
      r"^(?:(?:smily|smiley|nexo|nexos|nekso|nexou|clicky)[\s,]+)?(?:retiens|souviens[- ]toi|n'oublie pas|note|rappelle[- ]toi)\s+(?:bien\s+)?(?:que|qu'|de ce que)\s*(.{4,300})$",
      caseSensitive: false,
    ).firstMatch(n);
    if (m == null) return null;
    var t = m.group(1)!.trim().replaceAll(RegExp(r'[.!]+$'), '');
    // « je préfère » → « préfère » à la troisième personne, sans inventer.
    t = t
        .replaceFirst(RegExp(r"^je\s+", caseSensitive: false), 'Il/elle ')
        .replaceFirst(RegExp(r"^j'", caseSensitive: false), "Il/elle ")
        .replaceAll(RegExp(r'\bmon\b', caseSensitive: false), 'son')
        .replaceAll(RegExp(r'\bma\b', caseSensitive: false), 'sa')
        .replaceAll(RegExp(r'\bmes\b', caseSensitive: false), 'ses');
    return t;
  }

  // ---------------------------------------------------------------- Rêves

  /// La consigne pour l'IA **locale** : ranger ce qu'il a vécu.
  static String dreamPrompt(List<String> material, List<Memory> known, {String name = ''}) {
    final who = name.isEmpty ? 'la personne' : name;
    final mem = known.take(60).map((m) => '- (${m.topic}) ${m.text}').join('\n');
    final day = material.take(120).map((l) => '- ${l.length > 220 ? '${l.substring(0, 220)}…' : l}').join('\n');
    return 'Tu es la mémoire de Nexo, l\'assistant de $who. Pendant que $who n\'est pas là, tu ranges ce que Nexo '
        'a vécu aujourd\'hui, comme un cerveau qui rêve.\n\n'
        'Ce qu\'il savait déjà :\n${mem.isEmpty ? '(rien)' : mem}\n\n'
        'Ce qu\'il a vécu (messages de $who, faits) :\n$day\n\n'
        'Réponds UNIQUEMENT en JSON :\n'
        '{"souvenirs": [{"sujet": "moi|proches|ecole|gouts|projets|objectifs|habitudes|a_eviter|savoir|divers", '
        '"texte": "une phrase courte et durable sur $who"}], '
        '"capacites": [{"phrase": "ce que $who pourrait dire", "consigne": "ce que Nexo doit faire alors"}], '
        '"reve": "un rêve drôle et tendre de 1 à 2 phrases, inspiré de la journée"}\n'
        'Règles : seulement des choses VRAIES et UTILES plus tard (goûts, projets, personnes, objectifs, ce que '
        '$who n\'aime pas que Nexo fasse). Rien de passager (« il a faim »). Pas de mots de passe, d\'adresses, '
        'de numéros, ni de secrets de santé. 0 à 8 souvenirs. "capacites" : seulement si $who a demandé PLUSIEURS '
        'fois la même chose qu\'un raccourci ferait mieux (0 à 2).';
  }

  static final _secret = RegExp(
    r'mot de passe|password|\b\d{4,}\b|@[a-z0-9.-]+\.[a-z]|\b(?:rue|avenue|boulevard)\b|iban|carte bancaire|code',
    caseSensitive: false,
  );

  /// Lit la réponse de l'IA (même entourée de texte ou de ```json).
  static DreamResult? parseDream(String reply) {
    final a = reply.indexOf('{'), b = reply.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Object? j;
    try {
      j = jsonDecode(reply.substring(a, b + 1));
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final mems = <(String, String)>[
      for (final m in (j['souvenirs'] is List ? j['souvenirs'] as List : const []))
        if (m is Map && '${m['texte'] ?? ''}'.trim().length >= 4 && !_secret.hasMatch('${m['texte']}'))
          ('${m['sujet'] ?? ''}', '${m['texte']}'.trim()),
    ].take(8).toList();
    final skills = <(String, String)>[
      for (final s in (j['capacites'] is List ? j['capacites'] as List : const []))
        if (s is Map && '${s['phrase'] ?? ''}'.trim().length >= 4 && '${s['consigne'] ?? ''}'.trim().length >= 8)
          ('${s['phrase']}'.trim(), '${s['consigne']}'.trim()),
    ].take(2).toList();
    var dream = '${j['reve'] ?? ''}'.trim();
    if (dream.length > 280) dream = '${dream.substring(0, 277)}…';
    return DreamResult(memories: mems, skills: skills, dream: dream, local: true);
  }

  /// Sans IA locale : les phrases où la personne parle d'elle (« j'aime… »,
  /// « je veux… », « mon frère… », « je n'aime pas que tu… »).
  static DreamResult byRules(List<String> mine) {
    final out = <(String, String)>[];
    final re = RegExp(
      r"\b(?:j'aime|j'adore|je préfère|je deteste|je déteste|j'ai \d+ ans|je m'appelle|j'habite|je veux devenir|je voudrais|"
      r"mon (?:frère|père|meilleur ami|ami|cousin|prof)|ma (?:sœur|soeur|mère|meilleure amie|copine|prof)|"
      r"j'écris|j'ecris|je lis|je suis en (?:seconde|première|terminale|\d+e)|"
      r"je (?:ne )?veux (?:pas|plus) que tu|arrête de me|ne me (?:dis|parle) plus)\b[^.?!]{3,140}",
      caseSensitive: false,
    );
    for (final line in mine) {
      if (_secret.hasMatch(line)) continue;
      for (final m in re.allMatches(line)) {
        final t = m.group(0)!.trim();
        out.add((topicOf(t), _third(t)));
      }
    }
    return DreamResult(memories: out.take(8).toList());
  }

  static String _third(String t) => t
      .replaceFirst(RegExp(r"^j'", caseSensitive: false), 'Il/elle ')
      .replaceFirst(RegExp(r'^je ', caseSensitive: false), 'Il/elle ')
      .replaceFirst(RegExp(r'^mon ', caseSensitive: false), 'Son ')
      .replaceFirst(RegExp(r'^ma ', caseSensitive: false), 'Sa ')
      .replaceAll(RegExp(r'\btu\b', caseSensitive: false), 'Nexo')
      .replaceAll(RegExp(r'\bme\b', caseSensitive: false), 'lui');

  /// Faut-il rêver maintenant ? (absent depuis 20 min, au plus toutes les
  /// 6 heures, et seulement s'il y a assez de nouveau)
  static bool dreamDue({required Duration away, required DateTime? last, required int fresh, required DateTime now}) {
    if (away < const Duration(minutes: 20)) return false;
    if (fresh < 3) return false;
    return last == null || now.difference(last) >= const Duration(hours: 6);
  }

  /// Ce qu'il dit au réveil.
  static String morning(DreamResult r, int added) {
    final parts = <String>[];
    if (r.dream.isNotEmpty) parts.add('🌙 ${r.dream}');
    if (added > 0) {
      parts.add(
        'En rêvant, j\'ai rangé $added nouveau${added > 1 ? 'x' : ''} souvenir${added > 1 ? 's' : ''} sur toi'
        '${r.local ? ' (avec mon IA locale : rien n\'est sorti du PC)' : ''}.',
      );
    }
    if (r.skills.isNotEmpty) {
      parts.add('Et j\'ai eu une idée de nouvelle capacité : « ${r.skills.first.$1} ». Je te la propose ?');
    }
    return parts.join(' ');
  }
}

/// **La mémoire à long terme de Nexo** (v1.62) : un seul endroit, rangé par
/// sujets, où il garde ce qui compte sur toi. Il l'enrichit en **rêvant** :
/// quand tu n'es pas là, une IA **locale** (Ollama, sur ton PC) relit sa
/// journée et range ce qu'il a appris ; sans IA locale, des règles simples
/// font le tri. Il oublie les détails, garde l'important, et tu peux tout voir,
/// corriger et effacer (Réglages de Nexo → Sa mémoire).
class LongMemory extends ChangeNotifier {
  LongMemory._();
  static final instance = LongMemory._();

  final _file = JsonFile<Map<String, dynamic>>(
    'memoire.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  List<Memory> get all => [
    for (final m in (_file.value['souvenirs'] as List?) ?? const []) ?Memory.fromJson(m),
  ];

  DateTime? get lastDream {
    final v = _file.value['reve_at'];
    return v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  }

  /// Le dernier rêve pas encore raconté (texte prêt).
  String get untold => '${_file.value['a_dire'] ?? ''}';

  /// Les capacités imaginées en rêvant, en attente de ton accord.
  List<(String, String)> get ideas => [
    for (final s in (_file.value['idees'] as List?) ?? const [])
      if (s is Map) ('${s['p']}', '${s['c']}'),
  ];

  Future<void> load() async {
    try {
      await _file.load();
    } catch (_) {}
  }

  Future<void> _save(List<Memory> l, [Map<String, dynamic> extra = const {}]) async {
    await _file.update((v) => {...v, 'souvenirs': [for (final m in l) m.toJson()], ...extra});
    notifyListeners();
  }

  /// « Retiens que… » : gardé pour de bon.
  Future<int> remember(String text, {String? topic, DateTime? now}) async {
    await load();
    final n = now ?? DateTime.now();
    final (l, added) = MemoryRules.merge(all, [(topic ?? MemoryRules.topicOf(text), text)], n, pinned: true);
    await _save(l);
    return added;
  }

  Future<int> forget(String query) async {
    await load();
    final q = normalize(query);
    final before = all;
    final keep = [
      for (final m in before)
        if (!(m.id == query || (q.length >= 3 && normalize(m.text).contains(q)))) m,
    ];
    await _save(keep);
    return before.length - keep.length;
  }

  Future<void> forgetAll() async {
    await _save(const [], {'a_dire': '', 'idees': <Object>[]});
  }

  /// Le bloc pour les consignes de l'IA (souvenirs utiles à [question]).
  String promptBlock(String question, {DateTime? now}) =>
      MemoryRules.promptBlock(MemoryRules.relevant(all, question, now ?? DateTime.now()));

  /// Il rêve : [material] = ce qu'il a vécu depuis le dernier rêve (tes
  /// messages, ses souvenirs du jour), [mine] = seulement tes phrases,
  /// [local] = l'IA locale (null si pas d'Ollama).
  Future<(DreamResult, int)> dream({
    required List<String> material,
    required List<String> mine,
    Future<String> Function(String prompt)? local,
    String name = '',
    DateTime? now,
  }) async {
    await load();
    final n = now ?? DateTime.now();
    DreamResult? r;
    if (local != null) {
      try {
        r = MemoryRules.parseDream(
          await local(MemoryRules.dreamPrompt(material, all, name: name)).timeout(const Duration(minutes: 4)),
        );
      } catch (_) {}
    }
    r ??= MemoryRules.byRules(mine);
    final (l, added) = MemoryRules.merge(all, r.memories, n);
    final said = MemoryRules.morning(r, added);
    await _save(l, {
      'reve_at': n.millisecondsSinceEpoch,
      if (said.isNotEmpty) 'a_dire': said,
      'idees': [
        ...[for (final (p, c) in ideas) {'p': p, 'c': c}],
        for (final (p, c) in r.skills) {'p': p, 'c': c},
      ].take(6).toList(),
    });
    return (r, added);
  }

  /// Il raconte son rêve : la phrase, puis elle est effacée.
  Future<String> takeUntold() async {
    await load();
    final s = untold;
    if (s.isNotEmpty) await _file.update((v) => {...v, 'a_dire': ''});
    return s;
  }

  Future<void> dropIdea(String phrase) async {
    await _file.update(
      (v) => {
        ...v,
        'idees': [
          for (final (p, c) in ideas)
            if (p != phrase) {'p': p, 'c': c},
        ],
      },
    );
    notifyListeners();
  }

  List<HubTool> tools() => [
    HubTool(
      name: 'memoire_retenir',
      description:
          'Retient pour de bon une chose sur la personne (« retiens que je préfère les mangas »). Une phrase '
          'courte, à la 3ᵉ personne. Jamais de mot de passe ni de secret.',
      params: {
        'texte': ('string', 'Le souvenir, une phrase courte'),
        'sujet': ('string', MemoryRules.topics.keys.join(', ')),
      },
      required: const ['texte'],
      run: (a) async {
        final t = '${a['texte'] ?? ''}'.trim();
        if (t.isEmpty) return {'resume': 'Rien à retenir.'};
        final s = '${a['sujet'] ?? ''}';
        await remember(t, topic: MemoryRules.topics.containsKey(s) ? s : null);
        return {'resume': 'C\'est retenu : « $t ».'};
      },
    ),
    HubTool(
      name: 'memoire_souvenirs',
      description:
          'Ce que Nexo sait sur la personne (sa mémoire à long terme, par sujets). Avec « question » : les '
          'souvenirs utiles pour elle.',
      params: {'question': ('string', 'facultatif')},
      run: (a) async {
        await load();
        final q = '${a['question'] ?? ''}';
        final list = q.isEmpty ? all : MemoryRules.relevant(all, q, DateTime.now(), k: 15);
        return {
          'nombre': all.length,
          'souvenirs': [
            for (final m in list.take(40)) {'id': m.id, 'sujet': m.topic, 'texte': m.text, 'force': m.weight},
          ],
          'dernier_reve': lastDream?.toIso8601String(),
        };
      },
    ),
    HubTool(
      name: 'memoire_effacer_souvenir',
      description: 'Efface un ou des souvenirs (par id, ou ceux qui contiennent ces mots). « Oublie que… ».',
      params: {'quoi': ('string', 'id ou mots')},
      required: const ['quoi'],
      run: (a) async {
        final k = await forget('${a['quoi'] ?? ''}');
        return {'resume': k == 0 ? 'Je n\'avais rien retenu de tel.' : 'C\'est oublié ($k souvenir${k > 1 ? 's' : ''}).'};
      },
    ),
  ];
}
