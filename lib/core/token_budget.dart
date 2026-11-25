import 'dart:async';

import 'package:flutter/foundation.dart';

import 'claude_api.dart';
import 'hub_module.dart';

/// Ce que Nexo fait selon ce qu'il a déjà dépensé aujourd'hui.
enum TokenLevel {
  /// Moins de la moitié du budget : comme d'habitude.
  normal,

  /// Plus de la moitié : les questions simples vont à Gemini, moins
  /// d'historique, réflexion légère.
  econome,

  /// Plus de 80 % : Claude seulement pour les vraies tâches.
  serre,

  /// Budget dépassé : Claude seulement pour une grosse tâche ou « réfléchis
  /// bien » ; tout le reste par Gemini (gratuit).
  depasse,
}

/// Les règles des jetons (« tokens »), **sans fichiers** : testables.
///
/// Un jeton ≈ ¾ de mot. Claude compte ce qu'il lit (la question, les
/// consignes, l'historique, les actions de Mon Hub) et ce qu'il écrit. Les
/// jetons relus depuis le cache coûtent 20 fois moins.
class TokenRules {
  const TokenRules._();

  /// Prix en dollars pour 1 million de jetons : lus, écrits, relus du
  /// cache, mis en cache.
  static const prices = {
    'claude-opus-5-5': (4.0, 20.0, 0.20, 5.0),
    'claude-sonnet-5-5': (2.0, 10.0, 0.10, 2.5),
    'claude-haiku-5-5': (0.10, 0.50, 0.01, 0.125),
  };

  /// Le prix d'une demande (dollars).
  static double cost(String model, {int input = 0, int output = 0, int cacheRead = 0, int cacheWrite = 0}) {
    final p = prices[model] ?? prices['claude-opus-5-5']!;
    return (input * p.$1 + output * p.$2 + cacheRead * p.$3 + cacheWrite * p.$4) / 1e6;
  }

  /// Les jetons « qui comptent » pour le budget : ce que ça coûterait en
  /// jetons lus au prix normal (écrire coûte 5 fois plus, relire le cache
  /// 20 fois moins). Une seule mesure simple, la même pour tous les modèles.
  static int weighted({int input = 0, int output = 0, int cacheRead = 0, int cacheWrite = 0}) =>
      (input + output * 5 + cacheRead * 0.05 + cacheWrite * 1.25).round();

  /// Budget par défaut : 200 000 jetons par jour (≈ 0,80 $ avec Opus).
  static const defaultBudget = 200000;
  static const budgets = [50000, 100000, 200000, 400000, 1000000];

  static TokenLevel level(int used, int budget) {
    if (budget <= 0) return TokenLevel.normal;
    final r = used / budget;
    if (r >= 1) return TokenLevel.depasse;
    if (r >= 0.8) return TokenLevel.serre;
    if (r >= 0.5) return TokenLevel.econome;
    return TokenLevel.normal;
  }

  /// Combien d'échanges précédents envoyer à Claude (l'historique est ce
  /// qui coûte le plus à chaque question).
  static int historyTurns(TokenLevel l) => switch (l) {
    TokenLevel.normal => 8,
    TokenLevel.econome => 4,
    TokenLevel.serre || TokenLevel.depasse => 2,
  };

  /// La réflexion demandée à Claude, réglée selon le budget.
  static String effort(String wanted, TokenLevel l, {required bool deep}) {
    if (deep) return 'high'; // « réfléchis bien » : toujours écouté
    if (l == TokenLevel.normal) return wanted;
    return 'low';
  }

  /// La recherche internet de Claude (elle relit des pages : beaucoup de
  /// jetons) : seulement quand on la demande, dès que le budget se resserre.
  static bool webAllowed(TokenLevel l, String question) =>
      l == TokenLevel.normal ||
      RegExp(
        r'internet|en ligne|sur le web|cherche|recherche|actu|actualite|news|derniere|dernieres|aujourd|prix|meteo|resultat',
      ).hasMatch(question.toLowerCase().replaceAll(RegExp('[éèê]'), 'e').replaceAll('à', 'a'));

  /// Gemini (gratuit) essaie d'abord : seulement les questions simples en
  /// temps normal, toutes les questions sans écran ni document dès que le
  /// budget se resserre (Gemini répond « CLAUDE » s'il lui faut Mon Hub).
  static bool geminiFirst(
    TokenLevel l, {
    required bool light,
    required bool heavy,
    required bool deep,
    required bool screen,
    required bool docs,
  }) {
    if (light) return true;
    if (screen || docs || deep) return false;
    return switch (l) {
      TokenLevel.normal => false,
      TokenLevel.econome => !heavy,
      TokenLevel.serre || TokenLevel.depasse => true,
    };
  }

  static String k(int n) => n >= 1000000
      ? '${(n / 1e6).toStringAsFixed(1).replaceAll('.', ',')} M'
      : n >= 1000
      ? '${(n / 1000).round()} k'
      : '$n';

  static String euros(double usd) {
    if (usd < 0.01) return 'moins d\'un centime';
    return '≈ ${usd.toStringAsFixed(2).replaceAll('.', ',')} \$';
  }

  static String levelName(TokenLevel l) => switch (l) {
    TokenLevel.normal => 'normal',
    TokenLevel.econome => 'économe',
    TokenLevel.serre => 'très économe',
    TokenLevel.depasse => 'budget dépassé',
  };

  /// La phrase de Nexo sur ses jetons.
  static String say({
    required int used,
    required int budget,
    required double usd,
    required int claudeAsks,
    required int saved,
    required int gemini,
  }) {
    final l = level(used, budget);
    final pct = budget <= 0 ? 0 : (used * 100 / budget).round();
    final b = StringBuffer(
      'Aujourd\'hui j\'ai utilisé ${k(used)} jetons Claude sur ${k(budget)} ($pct %, ${euros(usd)}), '
      'en $claudeAsks question${claudeAsks > 1 ? 's' : ''}. ',
    );
    if (saved > 0) b.write('$saved réponse${saved > 1 ? 's' : ''} sans Claude (règles ou Gemini, gratuit). ');
    if (gemini > 0) b.write('Gemini : ${k(gemini)} jetons (gratuit). ');
    b.write(switch (l) {
      TokenLevel.normal => 'Tout va bien.',
      TokenLevel.econome => 'Je fais attention : questions simples par Gemini, moins d\'historique.',
      TokenLevel.serre => 'Je me serre la ceinture : Claude seulement pour les vraies tâches.',
      TokenLevel.depasse =>
        'Budget dépassé : Claude seulement pour une grosse tâche ou si tu me dis « réfléchis bien ».',
    });
    return '$b';
  }
}

/// Le compteur de jetons de Nexo (sur ce compte), et le budget du jour.
///
/// Rien n'est envoyé nulle part : les chiffres viennent des réponses de
/// Claude et de Gemini.
class TokenBudget extends ChangeNotifier {
  TokenBudget._();
  static final instance = TokenBudget._();

  static const _kData = 'jetons';
  static const _kBudget = 'jetons.budget';

  static String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> _all() {
    try {
      final m = ClaudeApi.store.getJson<Map>(_kData);
      return m == null ? <String, dynamic>{} : Map<String, dynamic>.from(m);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _day(DateTime d) {
    final v = _all()[day(d)];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<void> _put(DateTime d, Map<String, dynamic> v) async {
    final all = _all()..[day(d)] = v;
    // 30 jours gardés.
    final keep = day(d.subtract(const Duration(days: 30)));
    all.removeWhere((k, _) => k.compareTo(keep) < 0);
    try {
      await ClaudeApi.store.setJson(_kData, all);
    } catch (_) {}
    notifyListeners();
  }

  int get budget {
    try {
      final b = ClaudeApi.store.getJson<num>(_kBudget);
      return b == null || b <= 0 ? TokenRules.defaultBudget : b.toInt();
    } catch (_) {
      return TokenRules.defaultBudget;
    }
  }

  Future<void> setBudget(int v) async {
    try {
      await ClaudeApi.store.setJson(_kBudget, v);
    } catch (_) {}
    notifyListeners();
  }

  static int _n(Object? v) => v is num ? v.toInt() : 0;

  /// Une réponse de Claude (API ou Claude Code) : ses jetons.
  Future<void> recordClaude(String model, Map<dynamic, dynamic>? usage, {DateTime? at}) async {
    if (usage == null) return;
    final now = at ?? DateTime.now();
    final input = _n(usage['input_tokens']);
    final output = _n(usage['output_tokens']);
    final read = _n(usage['cache_read_input_tokens']);
    final write = _n(usage['cache_creation_input_tokens']);
    if (input + output + read + write == 0) return;
    final d = _day(now);
    d['lus'] = _n(d['lus']) + input;
    d['ecrits'] = _n(d['ecrits']) + output;
    d['cache'] = _n(d['cache']) + read;
    d['mis_en_cache'] = _n(d['mis_en_cache']) + write;
    d['poids'] = _n(d['poids']) + TokenRules.weighted(input: input, output: output, cacheRead: read, cacheWrite: write);
    d['dollars'] =
        ((d['dollars'] as num?) ?? 0) +
        TokenRules.cost(model, input: input, output: output, cacheRead: read, cacheWrite: write);
    d['demandes'] = _n(d['demandes']) + 1;
    await _put(now, d);
  }

  /// Une réponse de Gemini (gratuit, compté pour information).
  Future<void> recordGemini(int input, int output, {DateTime? at}) async {
    if (input + output <= 0) return;
    final now = at ?? DateTime.now();
    final d = _day(now);
    d['gemini'] = _n(d['gemini']) + input + output;
    await _put(now, d);
  }

  /// Une question réglée sans Claude.
  Future<void> recordSaved({DateTime? at}) async {
    final now = at ?? DateTime.now();
    final d = _day(now);
    d['evite'] = _n(d['evite']) + 1;
    await _put(now, d);
  }

  int usedToday([DateTime? now]) => _n(_day(now ?? DateTime.now())['poids']);
  double dollarsToday([DateTime? now]) => ((_day(now ?? DateTime.now())['dollars'] as num?) ?? 0).toDouble();

  TokenLevel get level => TokenRules.level(usedToday(), budget);

  /// Les 7 derniers jours (le plus récent d'abord).
  List<(String, Map<String, dynamic>)> week([DateTime? now]) {
    final n = now ?? DateTime.now();
    return [for (var i = 0; i < 7; i++) (day(n.subtract(Duration(days: i))), _day(n.subtract(Duration(days: i))))];
  }

  String say([DateTime? now]) {
    final d = _day(now ?? DateTime.now());
    return TokenRules.say(
      used: _n(d['poids']),
      budget: budget,
      usd: ((d['dollars'] as num?) ?? 0).toDouble(),
      claudeAsks: _n(d['demandes']),
      saved: _n(d['evite']),
      gemini: _n(d['gemini']),
    );
  }

  /// Une ligne pour ses consignes (il sait où il en est, sans long texte).
  String promptBlock() {
    final l = level;
    return 'Tes jetons Claude aujourd\'hui : ${TokenRules.k(usedToday())} sur ${TokenRules.k(budget)} '
        '(mode ${TokenRules.levelName(l)}). Sois bref et n\'utilise que les actions utiles'
        '${l == TokenLevel.normal ? '' : ' ; pas de recherche internet sauf si on te la demande'}.';
  }

  /// Le budget vient d'être dépassé (une seule annonce par jour).
  bool takeOverAnnounce([DateTime? now]) {
    final n = now ?? DateTime.now();
    if (TokenRules.level(usedToday(n), budget) != TokenLevel.depasse) return false;
    final d = _day(n);
    if (d['annonce'] == true) return false;
    d['annonce'] = true;
    unawaited(_put(n, d));
    return true;
  }

  List<HubTool> tools() => [
    HubTool(
      name: 'clicky_jetons',
      description:
          'Les jetons (tokens) que Nexo a utilisés aujourd\'hui et cette semaine (Claude, payant ; Gemini, gratuit), '
          'son budget du jour, ce que ça a coûté et comment il se règle. À utiliser pour « combien de tokens », '
          '« tu consommes beaucoup ? », « combien tu m\'as coûté ».',
      run: (_) async => {
        'resume': say(),
        'budget': budget,
        'utilises': usedToday(),
        'mode': TokenRules.levelName(level),
        'semaine': [
          for (final (d, v) in week())
            {'jour': d, 'jetons': _n(v['poids']), 'dollars': ((v['dollars'] as num?) ?? 0).toStringAsFixed(2)},
        ],
      },
    ),
    HubTool(
      name: 'clicky_budget_jetons',
      description:
          'Change le budget de jetons Claude par jour (Nexo s\'y adapte tout seul : Gemini pour le simple, moins '
          'd\'historique, réflexion légère). Valeurs conseillées : 50000, 100000, 200000 (défaut), 400000, 1000000.',
      params: {'jetons': ('integer', 'Le nouveau budget par jour')},
      required: const ['jetons'],
      run: (a) async {
        final v = (a['jetons'] is num ? a['jetons'] as num : num.tryParse('${a['jetons']}') ?? 0).toInt();
        if (v < 10000) {
          return {'resume': 'Un budget de moins de 10 000 jetons ne permet plus de répondre : choisis plus.'};
        }
        await setBudget(v);
        return {'resume': 'C\'est noté : ${TokenRules.k(v)} jetons Claude par jour. ${say()}', 'fait': true};
      },
    ),
  ];
}
