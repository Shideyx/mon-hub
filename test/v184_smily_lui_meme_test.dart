import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/claude_api.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/module_store.dart';
import 'package:hub/core/token_budget.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/core/whats_new.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:hub/ui/clicky/self_knowledge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleStore.init();
  });

  group('Jetons : règles', () {
    test('niveaux du budget', () {
      expect(TokenRules.level(10000, 200000), TokenLevel.normal);
      expect(TokenRules.level(100000, 200000), TokenLevel.econome);
      expect(TokenRules.level(170000, 200000), TokenLevel.serre);
      expect(TokenRules.level(250000, 200000), TokenLevel.depasse);
    });

    test('poids et prix : le cache coûte 20 fois moins, écrire 5 fois plus', () {
      expect(TokenRules.weighted(input: 1000), 1000);
      expect(TokenRules.weighted(output: 1000), 5000);
      expect(TokenRules.weighted(cacheRead: 1000), 50);
      expect(TokenRules.cost('claude-opus-5-5', input: 1000000), closeTo(4.0, 1e-9));
      expect(TokenRules.cost('claude-opus-5-5', output: 1000000), closeTo(20.0, 1e-9));
      expect(TokenRules.cost('claude-haiku-5-5', input: 1000000), closeTo(0.10, 1e-9));
    });

    test('il se règle tout seul', () {
      expect(TokenRules.historyTurns(TokenLevel.normal), 8);
      expect(TokenRules.historyTurns(TokenLevel.serre), 2);
      expect(TokenRules.effort('medium', TokenLevel.normal, deep: false), 'medium');
      expect(TokenRules.effort('medium', TokenLevel.econome, deep: false), 'low');
      // « Réfléchis bien » est toujours écouté.
      expect(TokenRules.effort('high', TokenLevel.depasse, deep: true), 'high');
      bool g(TokenLevel l, {bool light = false, bool heavy = false, bool screen = false}) =>
          TokenRules.geminiFirst(l, light: light, heavy: heavy, deep: false, screen: screen, docs: false);
      expect(g(TokenLevel.normal), isFalse);
      expect(g(TokenLevel.normal, light: true), isTrue);
      expect(g(TokenLevel.econome), isTrue);
      expect(g(TokenLevel.econome, heavy: true), isFalse);
      expect(g(TokenLevel.serre, heavy: true), isTrue);
      expect(g(TokenLevel.depasse, screen: true), isFalse);
      expect(TokenRules.webAllowed(TokenLevel.normal, 'Qui a gagné ?'), isTrue);
      expect(TokenRules.webAllowed(TokenLevel.serre, 'Explique la photosynthèse'), isFalse);
      expect(TokenRules.webAllowed(TokenLevel.serre, 'Cherche les résultats du match'), isTrue);
    });

    test('ce qu\'il dit', () {
      final s = TokenRules.say(used: 150000, budget: 200000, usd: 0.6, claudeAsks: 12, saved: 30, gemini: 50000);
      expect(s, contains('150 k'));
      expect(s, contains('75 %'));
      expect(s, contains('30 réponses sans Claude'));
      expect(s, contains('Je fais attention'));
    });
  });

  group('Jetons : compteur', () {
    test('compte les réponses de Claude, annonce le dépassement une fois', () async {
      final b = TokenBudget.instance;
      await b.setBudget(50000);
      final now = DateTime.now();
      expect(b.usedToday(now), 0);
      await b.recordClaude('claude-opus-5-5', {
        'input_tokens': 20000,
        'output_tokens': 7000,
        'cache_read_input_tokens': 40000,
        'cache_creation_input_tokens': 0,
      }, at: now);
      expect(b.usedToday(now), 20000 + 35000 + 2000);
      expect(b.dollarsToday(now), closeTo((20000 * 4 + 7000 * 20 + 40000 * 0.2) / 1e6, 1e-9));
      expect(b.level, TokenLevel.depasse);
      expect(b.takeOverAnnounce(now), isTrue);
      expect(b.takeOverAnnounce(now), isFalse);
      await b.recordGemini(1000, 500, at: now);
      await b.recordSaved(at: now);
      expect(b.say(now), contains('Gemini'));
      expect(b.promptBlock(), contains('budget dépassé'));
      final tool = b.tools().firstWhere((t) => t.name == 'clicky_jetons');
      expect('${(await tool.run({}) as Map)['resume']}', contains('jetons'));
      await b.setBudget(TokenRules.defaultBudget);
    });
  });

  group('Consignes en cache', () {
    test('le fixe d\'abord (avec le point de cache), le moment ensuite', () {
      final blocks = ClaudeApi.systemBlocks('Règles fixes${ClaudeApi.momentMark}Il est 10h.') as List;
      expect(blocks, hasLength(2));
      expect((blocks[0] as Map)['text'], 'Règles fixes');
      expect((blocks[0] as Map)['cache_control'], isNotNull);
      expect((blocks[1] as Map)['text'], contains('Il est 10h.'));
      expect(ClaudeApi.systemBlocks('Sans marque'), 'Sans marque');
    });
  });

  group('Nouveautés (GitHub)', () {
    const body =
        'Caméra privée, flou du visage dans les appels, sous-titres réparés (#65)\n\n'
        '- Mode caméra privée : la caméra reste coupée.\n'
        '- Flou du visage dans les appels.\n\n'
        'Co-Authored-By: Claude <noreply@anthropic.com>\n'
        'Claude-Session: https://claude.ai/code/session_x\n\n'
        'PC Windows : MonHub-Windows.zip · Guide : INSTALL.md';

    test('texte nettoyé', () {
      final l = NewsRules.clean(body);
      expect(l.first, 'Caméra privée, flou du visage dans les appels, sous-titres réparés');
      expect(l, contains('Mode caméra privée : la caméra reste coupée.'));
      expect(l.any((x) => x.contains('Co-Authored') || x.contains('PC Windows') || x.contains('http')), isFalse);
    });

    test('après une mise à jour : annoncé une fois, rien à la première ouverture', () async {
      WhatsNew.fetchOverride = () async => [
        {'tag_name': 'v1.83', 'published_at': '2026-11-24T12:00:00Z', 'body': 'Smily compte ses jetons'},
        {'tag_name': 'v1.82', 'published_at': '2026-11-24T10:00:00Z', 'body': body},
        {'tag_name': 'v1.81', 'published_at': '2026-11-23T10:00:00Z', 'body': 'Version web'},
      ];
      addTearDown(() => WhatsNew.fetchOverride = null);
      final w = WhatsNew.instance;
      expect(await w.afterUpdate(current: 81), isEmpty); // première ouverture
      final news = await w.afterUpdate(current: 83);
      expect(news.map((r) => r.tag), ['v1.83', 'v1.82']);
      expect(await w.afterUpdate(current: 83), isEmpty);
      expect(NewsRules.say(news), contains('v1.83 : Smily compte ses jetons'));
      expect(w.cached, hasLength(3));
      final tool = w.tools().single;
      expect('${(await tool.run({}) as Map)['resume']}', contains('v1.83'));
    });
  });

  group('Ce qu\'il sait faire', () {
    final tools = [
      HubTool(name: 'camera_flou', description: 'Floute la caméra dans les appels Discord', run: (_) async => null),
      HubTool(name: 'meteo_jour', description: 'La météo du jour', run: (_) async => null),
    ];

    test('il trouve dans le catalogue et dans ses vraies actions', () {
      final r = SelfKnowledge.search('Tu sais flouter mon visage ?', tools);
      expect(r.skills.join(' '), contains('Floute mon visage'));
      final a = SelfKnowledge.search('caméra flou appel', tools);
      expect(a.tools.map((t) => t.name), contains('camera_flou'));
      expect(SelfKnowledge.answer('', tools)['resume'], contains('thèmes'));
      expect(SelfKnowledge.answer('zzzz', tools)['trouve'], isFalse);
    });

    test('dans ses consignes, et toujours envoyé à Claude', () {
      expect(SelfKnowledge.promptBlock(), contains('clicky_capacites'));
      expect(SelfKnowledge.promptBlock(), contains('clicky_nouveautes'));
      final all = [
        HubTool(name: 'clicky_capacites', description: 'x', run: (_) async => null),
        HubTool(name: 'agenda_lire', description: 'x', run: (_) async => null),
      ];
      expect(ToolRouter.forGroups(['musique'], all).map((t) => t.name), contains('clicky_capacites'));
    });

    test('phrases sans IA', () async {
      final called = <String>[];
      Future<Object?> fake(String name, Map<String, dynamic> args) async {
        called.add('$name ${args['jetons'] ?? ''}'.trim());
        return {'resume': 'ok $name'};
      }

      const tools = {'clicky_capacites', 'clicky_nouveautes', 'clicky_jetons', 'clicky_budget_jetons'};
      Future<String?> ask(String q) async => (await QuickAnswers.answer(q, call: fake, tools: tools))?.text;
      expect(await ask('Qu\'est-ce que tu sais faire ?'), 'ok clicky_capacites');
      expect(await ask('Quoi de neuf dans Mon Hub ?'), 'ok clicky_nouveautes');
      expect(await ask('C\'est quoi la dernière mise à jour ?'), 'ok clicky_nouveautes');
      expect(await ask('Combien de tokens t\'as utilisé aujourd\'hui ?'), 'ok clicky_jetons');
      expect(await ask('Mets ton budget de jetons à 100k'), 'ok clicky_budget_jetons');
      expect(called.last, 'clicky_budget_jetons 100000');
      // Une vraie question part vers l'IA.
      expect(await ask('Tu peux m\'aider pour mon exposé sur les tokens ?'), isNull);
    });
  });
}
