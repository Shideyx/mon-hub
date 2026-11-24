import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../ui/widgets.dart';
import '../docs/docs_module.dart';
import '../ecoledirecte/ed_client.dart';
import '../ecoledirecte/ecoledirecte_module.dart';
import '../schedule/schedule_module.dart';
import 'fiche_view.dart';
import 'fsrs.dart';
import 'revisions_store.dart';
import '../../core/photo.dart';
import '../../ui/clicky/course_listener.dart';
import '../../ui/clicky/copy_check.dart';
import '../../ui/clicky/course_page.dart';
import '../../ui/clicky/interpreter.dart';
import '../../ui/clicky/live_captions.dart';
import '../../ui/clicky/mind_map.dart';
import '../../ui/clicky/oral_coach.dart';
import '../../ui/clicky/video_notes.dart' show VideoNotesPage;
import '../ecoledirecte/grade_math.dart';
import 'mock_exam.dart';

/// Révisions : comme Anki, Quizlet et les applis de révision des lycéens
/// (SchoolMouv, Eliott…), en un seul endroit, sur l'appareil :
/// - cartes qui reviennent juste avant que tu les oublies (FSRS, l'algorithme
///   d'Anki) ;
/// - quiz QCM, réponse écrite, jeu d'association ;
/// - Nexo crée les cartes à partir d'un cours (texte, document, photo, PDF) ;
/// - minuteur de concentration et série de jours 🔥 ;
/// - plan de révision placé dans l'agenda avant chaque contrôle d'École
///   Directe.
class RevisionsModule extends HubModule {
  RevisionsModule({this.ecole, this.schedule});

  final EcoleDirecteModule? ecole;
  final ScheduleModule? schedule;

  @override
  String get id => 'revisions';
  @override
  String get name => 'Révisions';
  @override
  String get description => 'Cartes, quiz, minuteur et plan avant les contrôles';
  @override
  IconData get icon => Icons.style_rounded;
  @override
  Color get color => const Color(0xFFE0457B);
  @override
  ApiAccess get access => ApiAccess.local;

  final revisions = RevisionsStore.instance;

  /// Les prochains contrôles (École Directe), dans les 4 semaines.
  List<EdHomework> get tests {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return [
      for (final h in ecole?.homework ?? const <EdHomework>[])
        if (h.isTest && !h.due.isBefore(today) && h.due.difference(today).inDays <= 28) h,
    ]..sort((a, b) => a.due.compareTo(b.due));
  }

  Future<int> refreshBadge() async {
    await revisions.load();
    final n = revisions.dueCount();
    badge.value = n;
    return n;
  }

  @override
  Future<List<HubNotification>> poll() async {
    final prepared = await autoPrepare();
    final n = await refreshBadge();
    final now = DateTime.now();
    if (prepared != null) return [prepared];
    // Un rappel par jour, en fin d'après-midi, s'il reste des cartes.
    if (n == 0 || now.hour < 17 || now.hour >= 22) return const [];
    final streak = revisions.streak(now);
    return [
      HubNotification(
        id: 'revisions-${RevisionsStore.dayKey(now)}',
        title: 'Révisions · $n carte${n > 1 ? 's' : ''} à revoir',
        body: streak > 0 ? 'Garde ta série de $streak jour${streak > 1 ? 's' : ''} 🔥' : 'Quelques minutes suffisent.',
      ),
    ];
  }

  /// Ouvre un écran de révision dans Mon Hub.
  Future<void> push(BuildContext? context, Widget Function() page) async {
    final ctx = context ?? await hubDialogContext();
    if (ctx == null || !ctx.mounted) throw 'Mon Hub n\'est pas affiché';
    unawaited(Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => page())));
  }

  // ------------------------------------------------------------ Nexo (IA)

  static const _cardsSystem =
      'Tu crées des cartes de révision (flashcards) pour un lycéen français. Réponds uniquement en JSON.';

  static String cardsPrompt(int count, String what) =>
      'Crée $count cartes de révision à partir de $what. Chaque carte : au recto une question précise, '
      'au verso une réponse courte et exacte (définition, date, formule, mot-clé, explication en une phrase). '
      'Couvre les notions les plus importantes, sans doublon, en français. '
      'Réponds uniquement avec ce JSON : [{"q": "question", "r": "réponse"}]';

  /// Lit les cartes renvoyées par l'IA.
  static List<(String, String)> parseCards(String text) {
    final j = AiText.json(text);
    final list = j is List ? j : (j is Map ? (j['cartes'] ?? j['cards'] ?? const []) as List : const []);
    return [
      for (final c in list)
        if (c is Map)
          (
            '${c['q'] ?? c['question'] ?? c['recto'] ?? c['front'] ?? ''}'.trim(),
            '${c['r'] ?? c['reponse'] ?? c['réponse'] ?? c['verso'] ?? c['back'] ?? ''}'.trim(),
          ),
    ].where((c) => c.$1.isNotEmpty && c.$2.isNotEmpty).toList();
  }

  /// Nexo fabrique des cartes à partir d'un cours.
  Future<List<(String, String)>> generate({
    String text = '',
    List<String> images = const [],
    String? pdf,
    int count = 15,
  }) async {
    if (!await AiText.available()) {
      throw 'Nexo a besoin d\'un cerveau : clé Gemini gratuite ou Claude (module Claude → Réglages).';
    }
    final what = text.trim().isNotEmpty
        ? 'ce cours :\n---\n${text.length > 30000 ? text.substring(0, 30000) : text}\n---'
        : pdf != null
        ? 'ce cours en PDF'
        : 'ces photos de cours (lis bien tout le texte)';
    final out = await AiText.ask(cardsPrompt(count, what), system: _cardsSystem, images: images, pdf: pdf);
    final cards = parseCards(out);
    if (cards.isEmpty) throw 'Nexo n\'a pas réussi à faire des cartes avec ce contenu';
    return cards;
  }

  // ------------------------------------------- Contrôles : préparation auto

  bool _preparing = false;

  static String testKey(EdHomework t) => '${t.subject}|${t.due.toIso8601String().substring(0, 10)}';

  /// Le contrôle n'a pas encore été préparé (ni tenté récemment).
  bool needsPrep(EdHomework t, DateTime now) {
    if (revisions.forTest(testKey(t)) != null) return false;
    final failed = store.getJson<int>('prepFail.${testKey(t)}');
    return failed == null || now.millisecondsSinceEpoch - failed > const Duration(hours: 6).inMilliseconds;
  }

  static const _prepSystem =
      'Tu es Nexo, le coach de révision d\'un lycéen français. Tu réponds uniquement en JSON valide.';

  static String prepPrompt(EdHomework t, String material) =>
      'Prépare la révision d\'un contrôle de ${t.subject} le ${frDays[t.due.weekday - 1]} ${t.due.day} '
      '${frMonths[t.due.month - 1]}, niveau lycée (programme français).\n'
      'Ce que le professeur a écrit : « ${t.content.trim().isEmpty ? 'contrôle (sans précision)' : t.content.trim()} ».\n'
      '${material.isEmpty ? '' : 'Ses cours (extraits) :\n---\n$material\n---\n'}'
      'Réponds uniquement avec ce JSON :\n'
      '{"titre": "titre court du chapitre", '
      '"fiche": "fiche de révision en Markdown : # titre, ## parties, l\'essentiel, définitions en **gras**, '
      'formules ou dates clés, méthodes, pièges fréquents, puis 5 questions pour se tester", '
      '"cartes": [{"q": "question", "r": "réponse courte et exacte"}] (15 à 20 cartes), '
      '"quiz": [{"q": "question", "bonne": "bonne réponse", "fausses": ["piège 1", "piège 2", "piège 3"]}] (10 questions)}';

  /// Ce que la réponse de l'IA contient : (titre, fiche, cartes, quiz).
  static (String, String, List<(String, String)>, List<QuizQuestion>) parsePrep(String text) {
    final j = AiText.json(text);
    if (j is! Map) throw 'Nexo n\'a pas réussi à préparer ce contrôle';
    final cards = parseCards(jsonEncode(j['cartes'] ?? const []));
    final quiz = [
      for (final q in (j['quiz'] as List?) ?? const [])
        if (q is Map && '${q['q'] ?? ''}'.trim().isNotEmpty && '${q['bonne'] ?? ''}'.trim().isNotEmpty)
          QuizQuestion(
            '${q['q']}'.trim(),
            '${q['bonne']}'.trim(),
            [
              for (final w in (q['fausses'] as List?) ?? const [])
                if ('$w'.trim().isNotEmpty) '$w'.trim(),
            ].take(3).toList(),
          ),
    ];
    final sheet = '${j['fiche'] ?? ''}'.trim();
    if (sheet.isEmpty && cards.isEmpty) throw 'Nexo n\'a pas réussi à préparer ce contrôle';
    return ('${j['titre'] ?? ''}'.trim(), sheet, cards, quiz);
  }

  /// Fiche + cartes + quiz pour un contrôle (dans un paquet à part).
  Future<Deck> prepareTest(EdHomework t) async {
    if (!await AiText.available()) {
      throw 'Nexo a besoin d\'un cerveau : clé Gemini gratuite ou Claude (module Claude → Réglages).';
    }
    // Les cours de la personne sur Google Docs, s'il y en a pour la matière.
    final material = StringBuffer();
    if (GoogleDocs.connected) {
      try {
        for (final d in (await GoogleDocs.list(search: t.subject.split(RegExp(r'[ -]')).first, size: 2))) {
          final txt = await GoogleDocs.text('${d['id']}');
          material.writeln('[${d['name']}]\n${txt.length > 8000 ? txt.substring(0, 8000) : txt}');
        }
      } catch (_) {}
    }
    final out = await AiText.ask(prepPrompt(t, '$material'), system: _prepSystem);
    final (title, sheet, cards, quiz) = parsePrep(out);
    await revisions.load();
    final name = '📝 ${t.subject}${title.isEmpty ? '' : ' — $title'}';
    final deck = Deck(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      color: 0xFFE67E22,
      sheet: sheet,
      quiz: quiz,
      testId: testKey(t),
      testDate: t.due,
    );
    revisions.data.decks.add(deck);
    await revisions.saveDeck();
    await revisions.addCards(deck.id, cards);
    // La fiche aussi dans Google Docs (si Google est connecté).
    if (GoogleDocs.connected && sheet.isNotEmpty) {
      try {
        deck.sheetDoc = await GoogleDocs.create('Fiche — ${t.subject}${title.isEmpty ? '' : ' — $title'}', sheet);
        await revisions.saveDeck();
      } catch (_) {}
    }
    await refreshBadge();
    return deck;
  }

  /// Prépare tout seul le prochain contrôle pas encore prêt (un à la fois).
  Future<HubNotification?> autoPrepare({DateTime? now}) async {
    final n = now ?? DateTime.now();
    if (_preparing || store.getJson<bool>('autoPrep') == false) return null;
    final next = tests
        .where((t) => t.due.difference(DateTime(n.year, n.month, n.day)).inDays <= 10)
        .where((t) => needsPrep(t, n))
        .firstOrNull;
    if (next == null || !await AiText.available()) return null;
    _preparing = true;
    try {
      final deck = await prepareTest(next);
      return HubNotification(
        id: 'prep-${testKey(next)}',
        title: '📝 Contrôle de ${next.subject} ${_inDays(next.due)}',
        body: 'Nexo a préparé ta fiche, ${deck.cards.length} cartes et un quiz de ${deck.quiz.length} questions.',
        moduleId: id,
      );
    } catch (_) {
      await store.setJson('prepFail.${testKey(next)}', n.millisecondsSinceEpoch);
      return null;
    } finally {
      _preparing = false;
    }
  }

  // --------------------------------------------------------- Plan contrôles

  /// Des séances de révision avant chaque contrôle (J-4, J-2, J-1), dans
  /// les créneaux libres de l'agenda.
  Future<List<PersonalEvent>> planFor(List<EdHomework> list, {DateTime? now}) async {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final out = <PersonalEvent>[];
    var k = 0;
    for (final t in list.take(6)) {
      for (final before in const [4, 2, 1]) {
        final day = DateTime(t.due.year, t.due.month, t.due.day - before);
        if (day.isBefore(today)) continue;
        if (out.any((e) => e.start.year == day.year && e.start.month == day.month && e.start.day == day.day)) {
          continue;
        }
        final weekend = day.weekday >= DateTime.saturday;
        final busy = schedule == null
            ? <(DateTime, DateTime)>[]
            : [
                for (final e in await schedule!.itemsBetween(day, day.add(const Duration(days: 1))))
                  if (!e.cancelled) (e.start, e.end),
              ];
        final free = freeSlots(
          busy,
          from: day,
          days: 1,
          dayStart: weekend ? 10 : 17,
          dayEnd: 21,
          minimum: const Duration(minutes: 45),
          notBefore: n,
        );
        final slots = (free.firstOrNull?['libre'] as List?) ?? const [];
        if (slots.isEmpty) continue;
        final hm = '${slots.first}'.split('-').first.split(':');
        final start = DateTime(day.year, day.month, day.day, int.parse(hm[0]), int.parse(hm[1]));
        out.add(
          PersonalEvent(
            id: '${DateTime.now().microsecondsSinceEpoch}${k++}',
            title: 'Révision ${t.subject}',
            start: start,
            end: start.add(const Duration(minutes: 45)),
            note:
                'Contrôle le ${frDays[t.due.weekday - 1]} ${t.due.day} ${frMonths[t.due.month - 1]}'
                '${t.content.trim().isEmpty ? '' : ' : ${t.content.trim()}'}',
          ),
        );
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'revision_paquets',
      description: 'Paquets de cartes de révision : nombre de cartes, à revoir, maîtrise ; série de jours.',
      run: (_) async {
        await revisions.load();
        final now = DateTime.now();
        return {
          'serie_jours': revisions.streak(now),
          'a_revoir_aujourdhui': revisions.dueCount(now),
          'cartes_faites_aujourdhui': revisions.today(now).cards,
          'paquets': [
            for (final d in revisions.decks)
              {
                'id': d.id,
                'nom': d.name,
                'cartes': d.cards.length,
                'a_revoir': d.dueReviews(now).length,
                'nouvelles': d.fresh.length,
                'maitrise_pourcent': (d.mastery * 100).round(),
              },
          ],
          'controles': [
            for (final t in tests) {'matiere': t.subject, 'date': t.due, 'contenu': t.content},
          ],
        };
      },
    ),
    HubTool(
      name: 'revision_ajouter_cartes',
      description: 'Ajoute des cartes de révision (question / réponse) dans un paquet (créé s\'il n\'existe pas).',
      params: {
        'paquet': ('string', 'Nom du paquet (ex. « Histoire — Guerre froide »)'),
        'cartes': ('string', 'JSON : [{"q": "question", "r": "réponse"}]'),
      },
      required: ['paquet', 'cartes'],
      run: (a) async {
        final cards = parseCards(a['cartes'] is String ? '${a['cartes']}' : jsonEncode(a['cartes']));
        final d = await revisions.createDeck('${a['paquet']}');
        final n = await revisions.addCards(d.id, cards);
        await refreshBadge();
        return {'ok': true, 'ajoutees': n, 'paquet': d.name};
      },
    ),
    HubTool(
      name: 'revision_generer',
      description: 'Nexo crée des cartes de révision à partir d\'un texte de cours ou d\'un Google Doc.',
      params: {
        'paquet': ('string', 'Nom du paquet'),
        'texte': ('string', 'Le cours (facultatif si document)'),
        'document': ('string', 'id ou titre d\'un Google Doc (facultatif)'),
        'nombre': ('integer', 'Nombre de cartes (défaut 15)'),
      },
      required: ['paquet'],
      run: (a) async {
        var text = '${a['texte'] ?? ''}';
        if (text.trim().isEmpty && a['document'] != null) {
          final doc = await GoogleDocs.find('${a['document']}');
          text = await GoogleDocs.text('${doc['id']}');
        }
        if (text.trim().isEmpty) throw 'Donne le texte du cours ou un document';
        final cards = await generate(text: text, count: ((a['nombre'] as num?)?.toInt() ?? 15).clamp(3, 60));
        final d = await revisions.createDeck('${a['paquet']}');
        final n = await revisions.addCards(d.id, cards);
        await refreshBadge();
        return {
          'ok': true,
          'ajoutees': n,
          'paquet': d.name,
          'exemples': [for (final c in cards.take(3)) '${c.$1} → ${c.$2}'],
        };
      },
    ),
    HubTool(
      name: 'revision_controle_blanc',
      description:
          'Ouvre un contrôle blanc chronométré (sujet fait par l\'IA à partir des fiches, cartes et comptes rendus de '
          'cours de la matière), corrigé et noté sur 20.',
      params: {'matiere': ('string', 'Matière ou chapitre')},
      required: ['matiere'],
      run: (a) async {
        final q = '${a['matiere'] ?? ''}'.trim();
        await revisions.load();
        final deck =
            revisions.decks
                .where(
                  (d) =>
                      GradeMath.matchSubject(q, [d.name.replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')]) !=
                      null,
                )
                .firstOrNull ??
            revisions.decks.where((d) => d.name.toLowerCase().contains(q.toLowerCase())).firstOrNull;
        // Les comptes rendus des cours écoutés par Nexo dans cette matière.
        final notes = [
          for (final n in await CourseListener.instance.list())
            if (n.done && GradeMath.matchSubject(q, [n.subject]) != null) n.summary,
        ].take(3).join('\n\n');
        final material = [
          if (deck != null) MockExam.material(deck),
          notes,
        ].where((m) => m.trim().isNotEmpty).join('\n\n');
        await push(
          null,
          () => MockExamPage(
            subject: deck?.name ?? q,
            material: material,
            color: deck == null ? color : Color(deck.color),
          ),
        );
        return {'ok': true, 'paquet': deck?.name, 'avec_comptes_rendus': notes.isNotEmpty};
      },
    ),
    HubTool(
      name: 'revision_lancer',
      description:
          'Ouvre une séance de révision dans Mon Hub (cartes à revoir, quiz, réponse écrite, association, minuteur).',
      params: {
        'mode': ('string', 'cartes (défaut), quiz, ecrire, associer ou minuteur'),
        'paquet': ('string', 'Nom ou id du paquet (facultatif pour « cartes »)'),
      },
      run: (a) async {
        await revisions.load();
        final mode = '${a['mode'] ?? 'cartes'}';
        final d = a['paquet'] == null ? null : revisions.deck('${a['paquet']}');
        if (mode == 'minuteur') {
          await push(null, () => FocusPage(module: this));
        } else if (mode == 'cartes' || d == null) {
          await push(null, () => ReviewPage(module: this, deckId: d?.id));
        } else {
          await push(
            null,
            () => switch (mode) {
              'quiz' => QuizPage(module: this, deck: d),
              'ecrire' => WritePage(module: this, deck: d),
              _ => MatchPage(module: this, deck: d),
            },
          );
        }
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'revision_preparer_controle',
      description:
          'Prépare un contrôle d\'École Directe : fiche de révision, cartes et quiz (le prochain, ou celui d\'une matière). '
          'Nexo le fait aussi tout seul dès qu\'il voit un contrôle dans le cahier de texte.',
      params: {'matiere': ('string', 'Matière (facultatif : le prochain contrôle)')},
      run: (a) async {
        final m = '${a['matiere'] ?? ''}'.toLowerCase().trim();
        final t = tests.where((x) => m.isEmpty || x.subject.toLowerCase().contains(m)).firstOrNull;
        if (t == null) throw 'Je ne vois pas de contrôle${m.isEmpty ? '' : ' de $m'} dans le cahier de texte';
        final existing = revisions.forTest(testKey(t));
        final deck = existing ?? await prepareTest(t);
        await push(null, () => DeckPage(module: this, deckId: deck.id));
        return {
          'ok': true,
          'paquet': deck.name,
          'cartes': deck.cards.length,
          'quiz': deck.quiz.length,
          'deja_pret': existing != null,
        };
      },
    ),
    HubTool(
      name: 'revision_planifier',
      description:
          'Propose des séances de révision avant les prochains contrôles (créneaux libres de l\'agenda) ; '
          'avec ajouter=true, les met dans l\'agenda.',
      params: {'ajouter': ('boolean', 'Mettre les séances dans l\'agenda')},
      run: (a) async {
        final plan = await planFor(tests);
        if (a['ajouter'] == true && schedule != null) {
          for (final e in plan) {
            await schedule!.savePersonal(e);
          }
        }
        return {
          'ajoute': a['ajouter'] == true,
          'seances': [
            for (final e in plan) {'titre': e.title, 'debut': e.start, 'fin': e.end, 'note': e.note},
          ],
        };
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => _RevisionsSummary(module: this);

  @override
  Widget buildPage(BuildContext context) => RevisionsHomePage(module: this);
}

// =================================================================== Accueil

class _RevisionsSummary extends StatelessWidget {
  const _RevisionsSummary({required this.module});
  final RevisionsModule module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = module.color;
    return ListenableBuilder(
      listenable: module.revisions,
      builder: (context, _) => FutureBuilder(
        future: module.revisions.load(),
        builder: (context, _) {
          final s = module.revisions;
          final now = DateTime.now();
          final due = s.dueCount(now);
          final today = s.today(now);
          final streak = s.streak(now);
          final next = module.tests.firstOrNull;
          final goal = today.cards + due;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: goal == 0 ? 1 : today.cards / goal,
                          strokeWidth: 10,
                          strokeCap: StrokeCap.round,
                          color: c,
                          backgroundColor: c.withValues(alpha: 0.12),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            due == 0 ? '✓' : '$due',
                            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: c),
                          ),
                          Text(due == 0 ? 'à jour' : 'à revoir', style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        streak > 0 ? '🔥 $streak jour${streak > 1 ? 's' : ''} de suite' : '🔥 Lance ta série',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${today.cards} carte${today.cards > 1 ? 's' : ''} aujourd\'hui · ${today.minutes} min',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (next != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE67E22).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '📝 ${next.subject} · ${_inDays(next.due)}'
                            '${s.forTest(RevisionsModule.testKey(next)) != null ? ' · fiche prête' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: c, visualDensity: VisualDensity.compact),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: Text(due == 0 ? 'Quiz rapide' : 'Réviser'),
                        onPressed: () => module.push(context, () => ReviewPage(module: module)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _inDays(DateTime d) {
  final now = DateTime.now();
  final n = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  return switch (n) {
    0 => 'aujourd\'hui',
    1 => 'demain',
    _ => 'dans $n j',
  };
}

/// La page Révisions.
class RevisionsHomePage extends StatelessWidget {
  const RevisionsHomePage({super.key, required this.module});
  final RevisionsModule module;

  Future<void> _newDeck(BuildContext context) async {
    final r = await askFields(context, title: 'Nouveau paquet', labels: ['Nom (ex. « SVT — Génétique »)']);
    final name = r?.first.trim() ?? '';
    if (name.isEmpty) return;
    final d = await module.revisions.createDeck(name);
    if (context.mounted) await module.push(context, () => DeckPage(module: module, deckId: d.id));
  }

  /// « Préparer maintenant » un contrôle (Nexo le fait aussi tout seul).
  Future<void> _prepare(BuildContext context, EdHomework t) async {
    final nav = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 16),
              Expanded(child: Text('Nexo prépare ta fiche, tes cartes et ton quiz de ${t.subject}…')),
            ],
          ),
        ),
      ),
    );
    try {
      final deck = await module.prepareTest(t);
      nav.pop();
      if (context.mounted) await module.push(context, () => DeckPage(module: module, deckId: deck.id));
    } catch (e) {
      nav.pop();
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _plan(BuildContext context) async {
    final plan = await module.planFor(module.tests);
    if (!context.mounted) return;
    if (plan.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pas de créneau libre trouvé avant tes contrôles.')));
      return;
    }
    final keep = {for (final e in plan) e.id};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Ton plan de révision'),
          content: SizedBox(
            width: 460,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Des séances de 45 min, quelques jours avant chaque contrôle, dans tes créneaux libres :'),
                const SizedBox(height: 8),
                for (final e in plan)
                  CheckboxListTile(
                    value: keep.contains(e.id),
                    onChanged: (v) => set(() => v == true ? keep.add(e.id) : keep.remove(e.id)),
                    title: Text(e.title),
                    subtitle: Text('${dayLabel(e.start)} · ${hhmm(e.start)}–${hhmm(e.end)}\n${e.note}'),
                    isThreeLine: true,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mettre dans l\'agenda')),
          ],
        ),
      ),
    );
    if (ok != true || module.schedule == null) return;
    for (final e in plan.where((e) => keep.contains(e.id))) {
      await module.schedule!.savePersonal(e);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${keep.length} séance${keep.length > 1 ? 's' : ''} ajoutée${keep.length > 1 ? 's' : ''} à l\'agenda',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = module.color;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Révisions'),
        actions: [
          if (CourseListener.supported)
            TextButton.icon(
              icon: const Icon(Icons.mic_external_on_rounded),
              label: const Text('Écouter un cours'),
              onPressed: () => CoursePage.open(context),
            ),
          PopupMenuButton<String>(
            tooltip: 'Outils',
            icon: const Icon(Icons.auto_awesome_rounded),
            onSelected: (v) => switch (v) {
              'copie' => CopyCheckPage.open(),
              'oral' => OralCoachPage.open(),
              'video' => VideoNotesPage.open(),
              'interprete' => InterpreterPage.open(),
              'soustitres' => LiveCaptions.launch(),
              _ => MindMapPage.open(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'copie',
                child: ListTile(leading: Icon(Icons.fact_check_rounded), title: Text('Corriger ma copie (photo)')),
              ),
              PopupMenuItem(
                value: 'oral',
                child: ListTile(leading: Icon(Icons.record_voice_over_rounded), title: Text('Coach d\'oral')),
              ),
              PopupMenuItem(
                value: 'video',
                child: ListTile(leading: Icon(Icons.smart_display_rounded), title: Text('Vidéo YouTube → fiche')),
              ),
              PopupMenuItem(
                value: 'carte',
                child: ListTile(leading: Icon(Icons.hub_rounded), title: Text('Carte mentale')),
              ),
              PopupMenuItem(
                value: 'interprete',
                child: ListTile(leading: Icon(Icons.translate_rounded), title: Text('Interprète en direct')),
              ),
              PopupMenuItem(
                value: 'soustitres',
                child: ListTile(leading: Icon(Icons.subtitles_rounded), title: Text('Sous-titres en direct')),
              ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListenableBuilder(
        listenable: module.revisions,
        builder: (context, _) => FutureBuilder(
          future: module.revisions.load(),
          builder: (context, _) {
            final s = module.revisions;
            final now = DateTime.now();
            final due = s.dueCount(now);
            final streak = s.streak(now);
            final tests = module.tests;
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                // Le bandeau : la série, les cartes du jour, le bouton.
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6D4AFF), Color(0xFFE0457B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 10)),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              streak > 0
                                  ? '🔥 $streak jour${streak > 1 ? 's' : ''} de suite'
                                  : '🔥 Commence ta série aujourd\'hui',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              due == 0 ? 'Tout est à jour 🎉' : '$due carte${due > 1 ? 's' : ''} t\'attendent',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: c),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('Réviser maintenant'),
                                  onPressed: () => module.push(context, () => ReviewPage(module: module)),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Colors.white70),
                                  ),
                                  icon: const Icon(Icons.timer_rounded),
                                  label: const Text('Minuteur'),
                                  onPressed: () => module.push(context, () => FocusPage(module: module)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      _WeekBars(store: s),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _ActionTile(
                        icon: Icons.auto_awesome_rounded,
                        color: const Color(0xFF7C5CFF),
                        title: 'Créer avec Nexo',
                        text: 'À partir d\'un cours, d\'une photo, d\'un PDF',
                        onTap: () => showGenerateSheet(context, module),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionTile(
                        icon: Icons.add_rounded,
                        color: const Color(0xFF16A085),
                        title: 'Nouveau paquet',
                        text: 'Tes propres cartes',
                        onTap: () => _newDeck(context),
                      ),
                    ),
                  ],
                ),
                if (tests.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Text(
                        'Prochains contrôles',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.event_available_rounded),
                        label: const Text('Planifier mes révisions'),
                        onPressed: () => _plan(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 112,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: tests.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final t = tests[i];
                        final ready = s.forTest(RevisionsModule.testKey(t));
                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => ready != null
                              ? module.push(context, () => DeckPage(module: module, deckId: ready.id))
                              : _prepare(context, t),
                          child: Container(
                            width: 220,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              color: const Color(0xFFE67E22).withValues(alpha: 0.10),
                              border: Border.all(color: const Color(0xFFE67E22).withValues(alpha: 0.3)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _inDays(t.due).toUpperCase(),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: const Color(0xFFE67E22),
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  t.subject,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                Text(
                                  t.content.trim().isEmpty ? dayLabel(t.due) : t.content.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                                const Spacer(),
                                Text(
                                  ready != null ? '✓ Fiche, cartes et quiz prêts' : '✨ Préparer maintenant',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: ready != null ? const Color(0xFF23A55A) : const Color(0xFF7C5CFF),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
                  title: const Text('Préparer mes contrôles automatiquement'),
                  subtitle: const Text(
                    'Dès qu\'un contrôle apparaît dans le cahier de texte : fiche, cartes et quiz, tout seuls.',
                  ),
                  value: module.store.getJson<bool>('autoPrep') != false,
                  onChanged: (v) async {
                    await module.store.setJson('autoPrep', v);
                    await module.revisions.saveDeck();
                  },
                ),
                const SizedBox(height: 12),
                Text('Mes paquets', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                if (s.decks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: EmptyHint(
                      'Pas encore de cartes. Crée-les avec Nexo à partir d\'un cours (photo, PDF, texte), '
                      'ou dis : « Nexo, fais-moi des cartes sur la guerre froide ».',
                      icon: Icons.style_outlined,
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, box) {
                      final cols = (box.maxWidth / 250).floor().clamp(1, 5);
                      return Wrap(
                        spacing: 14,
                        runSpacing: 14,
                        children: [
                          for (final d in s.decks)
                            SizedBox(
                              width: (box.maxWidth - 14 * (cols - 1)) / cols,
                              child: _DeckTile(module: module, deck: d),
                            ),
                        ],
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Les cartes revues ces 7 derniers jours, en barres.
class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.store});
  final RevisionsStore store;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = [for (var i = 6; i >= 0; i--) DateTime(now.year, now.month, now.day - i)];
    final values = [for (final d in days) store.data.days[RevisionsStore.dayKey(d)]?.cards ?? 0];
    final top = values.fold<int>(1, math.max);
    return SizedBox(
      height: 110,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 7; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    width: 12,
                    height: 6 + 70 * values[i] / top,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: i == 6 ? 1 : 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    frDays[days[i].weekday - 1].substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(20),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _DeckTile extends StatelessWidget {
  const _DeckTile({required this.module, required this.deck});
  final RevisionsModule module;
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final color = Color(deck.color);
    final due = deck.dueReviews(DateTime.now()).length;
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => module.push(context, () => DeckPage(module: module, deckId: deck.id)),
      child: Container(
        height: 150,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [color, Color.lerp(color, Colors.black, 0.35)!],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    deck.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: deck.mastery,
                          strokeWidth: 4,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      Text(
                        '${(deck.mastery * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              '${deck.cards.length} carte${deck.cards.length > 1 ? 's' : ''} · ${deck.fresh.length} nouvelle${deck.fresh.length > 1 ? 's' : ''}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (due > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      '$due à revoir',
                      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Réviser ce paquet',
                  style: IconButton.styleFrom(backgroundColor: Colors.white24),
                  color: Colors.white,
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: () => module.push(context, () => ReviewPage(module: module, deckId: deck.id)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ===================================================================== Paquet

/// Un paquet : ses modes de jeu, ses cartes.
class DeckPage extends StatelessWidget {
  const DeckPage({super.key, required this.module, required this.deckId});
  final RevisionsModule module;
  final String deckId;

  Future<void> _edit(BuildContext context, Deck d, [StudyCard? card]) async {
    final r = await askFields(
      context,
      title: card == null ? 'Nouvelle carte' : 'Modifier la carte',
      labels: ['Question (recto)', 'Réponse (verso)'],
      initial: card == null ? null : [card.front, card.back],
    );
    if (r == null || r[0].trim().isEmpty || r[1].trim().isEmpty) return;
    if (card == null) {
      await module.revisions.addCards(d.id, [(r[0], r[1])]);
    } else {
      await module.revisions.updateCard(
        d.id,
        card.copy()
          ..front = r[0].trim()
          ..back = r[1].trim(),
      );
    }
  }

  Future<void> _import(BuildContext context, Deck d) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Importer des cartes'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Une carte par ligne : « question - réponse » (ou avec « : », « = », une tabulation). '
                'Tu peux coller un export de Quizlet.',
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 12,
                decoration: const InputDecoration(
                  hintText: 'Capitale de l\'Italie - Rome\n1789 : Révolution française',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Importer')),
        ],
      ),
    );
    if (text == null) return;
    final n = await module.revisions.addCards(d.id, RevisionsStore.parseLines(text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$n carte${n > 1 ? 's' : ''} ajoutée${n > 1 ? 's' : ''}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: module.revisions,
      builder: (context, _) {
        final d = module.revisions.deck(deckId);
        if (d == null) return const Scaffold(body: EmptyHint('Paquet supprimé'));
        final color = Color(d.color);
        final enough = d.cards.length >= 4;
        return Scaffold(
          appBar: AppBar(
            title: Text(d.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final r = await askFields(context, title: 'Renommer', labels: ['Nom'], initial: [d.name]);
                    if (r != null) await module.revisions.renameDeck(d.id, r.first);
                  } else if (v == 'delete') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Supprimer « ${d.name} » ?'),
                        content: Text('${d.cards.length} cartes seront effacées.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Supprimer')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await module.revisions.deleteDeck(d.id);
                      if (context.mounted) Navigator.maybePop(context);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Renommer')),
                  PopupMenuItem(value: 'delete', child: Text('Supprimer le paquet')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: color,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Carte'),
            onPressed: () => _edit(context, d),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
            children: [
              if (d.sheet != null && d.sheet!.trim().isNotEmpty) ...[_SheetCard(deck: d), const SizedBox(height: 14)],
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Mode(
                    icon: Icons.style_rounded,
                    color: color,
                    title: 'Cartes',
                    text: '${d.dueReviews(DateTime.now()).length} à revoir',
                    onTap: () => module.push(context, () => ReviewPage(module: module, deckId: d.id)),
                  ),
                  _Mode(
                    icon: Icons.quiz_rounded,
                    color: const Color(0xFF0B6FB8),
                    title: 'Quiz',
                    text: d.quiz.isNotEmpty
                        ? 'QCM préparé, ${d.quiz.length} questions'
                        : enough
                        ? 'QCM, 10 questions'
                        : '4 cartes minimum',
                    onTap: enough || d.quiz.isNotEmpty
                        ? () => module.push(context, () => QuizPage(module: module, deck: d))
                        : null,
                  ),
                  _Mode(
                    icon: Icons.keyboard_rounded,
                    color: const Color(0xFF16A085),
                    title: 'Écrire',
                    text: 'Tape la réponse',
                    onTap: d.cards.isEmpty
                        ? null
                        : () => module.push(context, () => WritePage(module: module, deck: d)),
                  ),
                  _Mode(
                    icon: Icons.assignment_rounded,
                    color: const Color(0xFFE5484D),
                    title: 'Contrôle blanc',
                    text: enough || (d.sheet ?? '').isNotEmpty ? 'Sujet chronométré, noté /20' : '4 cartes minimum',
                    onTap: enough || (d.sheet ?? '').isNotEmpty
                        ? () => module.push(
                            context,
                            () => MockExamPage(subject: d.name, material: MockExam.material(d), color: Color(d.color)),
                          )
                        : null,
                  ),
                  _Mode(
                    icon: Icons.extension_rounded,
                    color: const Color(0xFFE67E22),
                    title: 'Associer',
                    text: enough ? 'Le plus vite possible' : '4 cartes minimum',
                    onTap: enough ? () => module.push(context, () => MatchPage(module: module, deck: d)) : null,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '${d.cards.length} cartes',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('Nexo'),
                    onPressed: () => showGenerateSheet(context, module, deck: d),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: const Text('Importer'),
                    onPressed: () => _import(context, d),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final c in d.cards)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      c.mastered
                          ? Icons.verified_rounded
                          : c.isNew
                          ? Icons.fiber_new_rounded
                          : Icons.trending_up_rounded,
                      color: c.mastered ? const Color(0xFF23A55A) : color,
                    ),
                    title: Text(c.front, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.back, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!c.isNew) Text(dayLabel(c.due), style: theme.textTheme.labelSmall),
                        IconButton(
                          tooltip: 'Supprimer',
                          icon: const Icon(Icons.delete_outline_rounded, size: 20),
                          onPressed: () => module.revisions.removeCard(d.id, c.id),
                        ),
                      ],
                    ),
                    onTap: () => _edit(context, d, c),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Mode extends StatelessWidget {
  const _Mode({required this.icon, required this.color, required this.title, required this.text, this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onTap == null ? 0.45 : 1,
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: 170,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.06)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            Text(text, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}

// ================================================================== Nexo

/// « Créer avec Nexo » : un cours (texte, document, photos, PDF) devient
/// des cartes.
Future<void> showGenerateSheet(BuildContext context, RevisionsModule module, {Deck? deck}) => showDialog<void>(
  context: context,
  builder: (_) => _GenerateDialog(module: module, deck: deck),
);

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog({required this.module, this.deck});
  final RevisionsModule module;
  final Deck? deck;

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  String source = 'texte';
  final text = TextEditingController();
  late final deckName = TextEditingController(text: widget.deck?.name ?? '');
  String? docId;
  List<String> images = [];
  String? pdf;
  String pdfName = '';
  double count = 15;
  bool busy = false;
  String? error;
  List<(String, String)>? cards;
  final keep = <int>{};

  Future<void> _pickImages() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp']),
      ],
    );
    final out = <String>[];
    for (final f in files.take(6)) {
      var bytes = await f.readAsBytes();
      try {
        // À côté (Isolate) : réduire 6 grosses photos figeait l'appli.
        bytes = (await Photo.toJpeg(bytes, maxSide: 1800, quality: 85)).$1;
      } catch (_) {}
      out.add(base64Encode(bytes));
    }
    setState(() => images = out);
  }

  Future<void> _pickPdf() async {
    final f = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF', extensions: ['pdf']),
      ],
    );
    if (f == null) return;
    final bytes = await f.readAsBytes();
    setState(() {
      pdf = base64Encode(bytes);
      pdfName = f.name;
    });
  }

  Future<void> _go() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var t = '';
      if (source == 'texte') t = text.text;
      if (source == 'document' && docId != null) t = await GoogleDocs.text(docId!);
      final list = await widget.module.generate(
        text: t,
        images: source == 'photo' ? images : const [],
        pdf: source == 'pdf' ? pdf : null,
        count: count.round(),
      );
      setState(() {
        cards = list;
        keep
          ..clear()
          ..addAll(List.generate(list.length, (i) => i));
      });
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add() async {
    final name = deckName.text.trim().isEmpty ? 'Cartes de Nexo' : deckName.text.trim();
    final d = widget.deck ?? await widget.module.revisions.createDeck(name);
    final list = [
      for (var i = 0; i < cards!.length; i++)
        if (keep.contains(i)) cards![i],
    ];
    final n = await widget.module.revisions.addCards(d.id, list);
    await widget.module.refreshBadge();
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n cartes ajoutées à « ${d.name} »')));
  }

  bool get ready => switch (source) {
    'texte' => text.text.trim().length > 40,
    'document' => docId != null,
    'photo' => images.isNotEmpty,
    _ => pdf != null,
  };

  @override
  Widget build(BuildContext context) {
    final list = cards;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome_rounded, color: Color(0xFF7C5CFF)),
          SizedBox(width: 10),
          Text('Créer des cartes avec Nexo'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: list != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${list.length} cartes proposées : décoche celles que tu ne veux pas.'),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (var i = 0; i < list.length; i++)
                          CheckboxListTile(
                            dense: true,
                            value: keep.contains(i),
                            onChanged: (v) => setState(() => v == true ? keep.add(i) : keep.remove(i)),
                            title: Text(list[i].$1, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(list[i].$2),
                          ),
                      ],
                    ),
                  ),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.deck == null)
                      TextField(
                        controller: deckName,
                        decoration: const InputDecoration(
                          labelText: 'Nom du paquet (ex. « Histoire — Guerre froide »)',
                        ),
                      ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'texte', icon: Icon(Icons.notes_rounded), label: Text('Texte')),
                        ButtonSegment(
                          value: 'document',
                          icon: Icon(Icons.description_rounded),
                          label: Text('Google Doc'),
                        ),
                        ButtonSegment(value: 'photo', icon: Icon(Icons.photo_camera_rounded), label: Text('Photos')),
                        ButtonSegment(value: 'pdf', icon: Icon(Icons.picture_as_pdf_rounded), label: Text('PDF')),
                      ],
                      selected: {source},
                      onSelectionChanged: (v) => setState(() => source = v.first),
                    ),
                    const SizedBox(height: 12),
                    switch (source) {
                      'texte' => TextField(
                        controller: text,
                        maxLines: 9,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(hintText: 'Colle ton cours ici…'),
                      ),
                      'document' =>
                        !GoogleDocs.connected
                            ? const Text(
                                'Connecte ton compte Google (Réglages → Connexion Google) pour choisir un Google Doc.',
                              )
                            : FutureBuilder(
                                future: GoogleDocs.list(size: 30),
                                builder: (context, snap) => snap.hasError
                                    ? Text('${snap.error}')
                                    : DropdownButtonFormField<String>(
                                        initialValue: docId,
                                        isExpanded: true,
                                        decoration: const InputDecoration(labelText: 'Un de tes Google Docs'),
                                        items: [
                                          for (final d in snap.data ?? const <Map<String, dynamic>>[])
                                            DropdownMenuItem(
                                              value: '${d['id']}',
                                              child: Text('${d['name']}', overflow: TextOverflow.ellipsis),
                                            ),
                                        ],
                                        onChanged: (v) => setState(() => docId = v),
                                      ),
                              ),
                      'photo' => OutlinedButton.icon(
                        icon: const Icon(Icons.add_photo_alternate_rounded),
                        label: Text(
                          images.isEmpty ? 'Choisir les photos du cours' : '${images.length} photo(s) choisie(s)',
                        ),
                        onPressed: _pickImages,
                      ),
                      _ => OutlinedButton.icon(
                        icon: const Icon(Icons.upload_file_rounded),
                        label: Text(pdf == null ? 'Choisir le PDF (clé Gemini)' : pdfName),
                        onPressed: _pickPdf,
                      ),
                    },
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('${count.round()} cartes'),
                        Expanded(
                          child: Slider(
                            value: count,
                            min: 5,
                            max: 40,
                            divisions: 7,
                            onChanged: (v) => setState(() => count = v),
                          ),
                        ),
                      ],
                    ),
                    if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        if (list == null)
          FilledButton.icon(
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(busy ? 'Nexo lit ton cours…' : 'Créer les cartes'),
            onPressed: busy || !ready ? null : _go,
          )
        else
          FilledButton(onPressed: keep.isEmpty ? null : _add, child: Text('Ajouter ${keep.length} cartes')),
      ],
    );
  }
}

// ============================================================ Séance (FSRS)

/// Une séance de cartes : la carte se retourne, tu dis si tu savais.
/// Espace : retourner · 1 2 3 4 : ta réponse.
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.module, this.deckId});
  final RevisionsModule module;
  final String? deckId;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final _focus = FocusNode();
  late List<(Deck, StudyCard)> queue = widget.module.revisions.session(deckId: widget.deckId);
  late final int total = queue.length;
  final started = DateTime.now();
  bool flipped = false;
  int done = 0;
  int right = 0;
  bool _logged = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _logTime();
    _focus.dispose();
    super.dispose();
  }

  void _logTime() {
    if (_logged || done == 0) return;
    _logged = true;
    unawaited(widget.module.revisions.addMinutes(math.max(1, DateTime.now().difference(started).inMinutes)));
  }

  Future<void> _grade(int g) async {
    if (queue.isEmpty || !flipped) return;
    final (deck, card) = queue.removeAt(0);
    final next = await widget.module.revisions.grade(deck.id, card, g);
    done++;
    if (g >= 3) right++;
    // Encore à apprendre aujourd'hui : elle revient un peu plus loin.
    if (next.due.difference(DateTime.now()).inMinutes <= 20) {
      queue.insert(math.min(queue.length, 3), (deck, next));
    }
    await widget.module.refreshBadge();
    setState(() => flipped = false);
    if (queue.isEmpty) _logTime();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      setState(() => flipped = !flipped);
      return KeyEventResult.handled;
    }
    final n = {
      LogicalKeyboardKey.digit1: 1,
      LogicalKeyboardKey.digit2: 2,
      LogicalKeyboardKey.digit3: 3,
      LogicalKeyboardKey.digit4: 4,
      LogicalKeyboardKey.numpad1: 1,
      LogicalKeyboardKey.numpad2: 2,
      LogicalKeyboardKey.numpad3: 3,
      LogicalKeyboardKey.numpad4: 4,
    }[k];
    if (n != null && flipped) {
      unawaited(_grade(n));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.module.color;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.deckId == null
                ? 'Révision du jour'
                : widget.module.revisions.deck(widget.deckId!)?.name ?? 'Révision',
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(6),
            child: LinearProgressIndicator(
              value: total == 0 ? 1 : (total - queue.length).clamp(0, total) / total,
              minHeight: 6,
              color: c,
              backgroundColor: c.withValues(alpha: 0.12),
            ),
          ),
        ),
        body: queue.isEmpty
            ? _Done(
                module: widget.module,
                done: done,
                right: right,
                minutes: DateTime.now().difference(started).inMinutes,
                deckId: widget.deckId,
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(
                          '${queue.length} carte${queue.length > 1 ? 's' : ''} restante${queue.length > 1 ? 's' : ''}',
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => flipped = !flipped),
                            child: FlipCard(
                              flipped: flipped,
                              color: Color(queue.first.$1.color),
                              tag: queue.first.$1.name,
                              front: queue.first.$2.front,
                              back: queue.first.$2.back,
                              isNew: queue.first.$2.isNew,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: flipped
                              ? Row(
                                  key: const ValueKey('grades'),
                                  children: [
                                    for (final (g, label, color) in const [
                                      (1, 'À revoir', Color(0xFFE5484D)),
                                      (2, 'Difficile', Color(0xFFE67E22)),
                                      (3, 'Bien', Color(0xFF23A55A)),
                                      (4, 'Facile', Color(0xFF0B6FB8)),
                                    ])
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 4),
                                          child: FilledButton(
                                            style: FilledButton.styleFrom(
                                              backgroundColor: color,
                                              padding: const EdgeInsets.symmetric(vertical: 14),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                            ),
                                            onPressed: () => _grade(g),
                                            child: Column(
                                              children: [
                                                Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                                                Text(
                                                  Fsrs.label(queue.first.$2, g, DateTime.now()),
                                                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                )
                              : SizedBox(
                                  key: const ValueKey('show'),
                                  width: double.infinity,
                                  child: FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 18),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    ),
                                    onPressed: () => setState(() => flipped = true),
                                    child: const Text('Voir la réponse  (Espace)'),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Une carte qui se retourne en 3D.
class FlipCard extends StatelessWidget {
  const FlipCard({
    super.key,
    required this.flipped,
    required this.color,
    required this.front,
    required this.back,
    this.tag = '',
    this.isNew = false,
  });

  final bool flipped;
  final Color color;
  final String front;
  final String back;
  final String tag;
  final bool isNew;

  Widget _face(BuildContext context, {required bool backSide}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        color: backSide ? theme.cardTheme.color ?? theme.colorScheme.surface : null,
        gradient: backSide
            ? null
            : LinearGradient(
                colors: [color, Color.lerp(color, Colors.black, 0.3)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        border: backSide ? Border.all(color: color.withValues(alpha: 0.5), width: 2) : null,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: backSide ? color.withValues(alpha: 0.12) : Colors.white24,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tag,
                  style: TextStyle(color: backSide ? color : Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ),
              const Spacer(),
              if (isNew && !backSide)
                const Text(
                  '✨ Nouvelle',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
            ],
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (backSide) ...[
                      Text(
                        front,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 14),
                      Container(width: 40, height: 3, color: color.withValues(alpha: 0.5)),
                      const SizedBox(height: 14),
                    ],
                    Text(
                      backSide ? back : front,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: backSide ? null : Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!backSide)
            const Text('Touche la carte pour la retourner', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: flipped ? math.pi : 0),
    duration: const Duration(milliseconds: 420),
    curve: Curves.easeInOutCubic,
    builder: (context, a, _) {
      final showBack = a > math.pi / 2;
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(a),
        child: showBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(math.pi),
                child: _face(context, backSide: true),
              )
            : _face(context, backSide: false),
      );
    },
  );
}

class _Done extends StatelessWidget {
  const _Done({required this.module, required this.done, required this.right, required this.minutes, this.deckId});
  final RevisionsModule module;
  final int done;
  final int right;
  final int minutes;
  final String? deckId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streak = module.revisions.streak();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(done == 0 ? '😎' : '🎉', style: const TextStyle(fontSize: 72)),
            const SizedBox(height: 12),
            Text(
              done == 0 ? 'Rien à revoir pour l\'instant' : 'Séance terminée !',
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              done == 0
                  ? 'Tes cartes reviendront au bon moment. Tu peux faire un quiz ou ajouter des cartes.'
                  : '$done carte${done > 1 ? 's' : ''} · ${done == 0 ? 0 : (right * 100 / done).round()} % de réussite'
                        ' · ${math.max(1, minutes)} min',
              textAlign: TextAlign.center,
            ),
            if (streak > 0) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE67E22).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text(
                  '🔥 $streak jour${streak > 1 ? 's' : ''} de suite',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Terminer')),
          ],
        ),
      ),
    );
  }
}

// ======================================================================= Quiz

/// Quiz QCM : 4 réponses, une seule juste (les autres viennent des autres
/// cartes du paquet).
class QuizPage extends StatefulWidget {
  const QuizPage({super.key, required this.module, required this.deck, this.length = 10, this.random});
  final RevisionsModule module;
  final Deck deck;
  final int length;
  final math.Random? random;

  /// Les 4 réponses d'une question (la bonne + 3 autres, mélangées).
  static List<String> options(StudyCard card, List<StudyCard> all, math.Random r) {
    final others = {
      for (final c in all)
        if (c.id != card.id && c.back != card.back) c.back,
    }.toList()..shuffle(r);
    return ([card.back, ...others.take(3)])..shuffle(r);
  }

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  late final r = widget.random ?? math.Random();

  /// Le quiz préparé par Nexo (avec de vrais pièges), sinon des questions
  /// tirées des cartes.
  late final List<StudyCard> questions = widget.deck.quiz.isNotEmpty
      ? [
          for (final (i, q) in ([...widget.deck.quiz]..shuffle(r)).take(widget.length).indexed)
            StudyCard(id: 'quiz$i', front: q.question, back: q.answer),
        ]
      : ([...widget.deck.cards]..shuffle(r)).take(widget.length).toList();
  late List<String> opts = _options(0);

  List<String> _options(int i) {
    if (widget.deck.quiz.isEmpty) return QuizPage.options(questions[i], widget.deck.cards, r);
    final q = widget.deck.quiz.firstWhere((x) => x.question == questions[i].front);
    final all = {q.answer, ...q.wrong}.toList();
    // Pas assez de pièges : on complète avec les autres réponses.
    for (final o in widget.deck.quiz) {
      if (all.length >= 4) break;
      if (!all.contains(o.answer)) all.add(o.answer);
    }
    return all..shuffle(r);
  }

  int i = 0;
  int score = 0;
  String? picked;
  final started = DateTime.now();

  void _pick(String o) {
    if (picked != null) return;
    setState(() {
      picked = o;
      if (o == questions[i].back) score++;
    });
  }

  void _next() {
    if (i + 1 >= questions.length) {
      unawaited(widget.module.revisions.addMinutes(math.max(1, DateTime.now().difference(started).inMinutes)));
      setState(() => i++);
      return;
    }
    setState(() {
      i++;
      picked = null;
      opts = _options(i);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(widget.deck.color);
    final finished = i >= questions.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Quiz · ${widget.deck.name}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(value: i / questions.length, minHeight: 6, color: color),
        ),
      ),
      body: finished
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(score * 2 >= questions.length ? '🏆' : '💪', style: const TextStyle(fontSize: 72)),
                  Text(
                    '$score / ${questions.length}',
                    style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: color),
                  ),
                  const SizedBox(height: 8),
                  Text(score == questions.length ? 'Parfait !' : 'Refais-le pour viser le sans-faute.'),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Terminer')),
                ],
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text('Question ${i + 1} / ${questions.length}', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: LinearGradient(colors: [color, Color.lerp(color, Colors.black, 0.3)!]),
                      ),
                      child: Text(
                        questions[i].front,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (final o in opts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: picked == null
                                ? theme.cardTheme.color
                                : o == questions[i].back
                                ? const Color(0xFF23A55A).withValues(alpha: 0.2)
                                : o == picked
                                ? const Color(0xFFE5484D).withValues(alpha: 0.2)
                                : theme.cardTheme.color,
                            border: Border.all(
                              color: picked != null && o == questions[i].back
                                  ? const Color(0xFF23A55A)
                                  : picked == o
                                  ? const Color(0xFFE5484D)
                                  : theme.colorScheme.outlineVariant,
                              width: 2,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _pick(o),
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text(o, style: theme.textTheme.titleMedium),
                            ),
                          ),
                        ),
                      ),
                    if (picked != null)
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: color),
                        onPressed: _next,
                        child: Text(i + 1 >= questions.length ? 'Voir mon score' : 'Suivante'),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ===================================================================== Écrire

/// Tu tapes la réponse ; les accents et les petites fautes de frappe sont
/// pardonnés.
class WritePage extends StatefulWidget {
  const WritePage({super.key, required this.module, required this.deck});
  final RevisionsModule module;
  final Deck deck;

  @override
  State<WritePage> createState() => _WritePageState();
}

class _WritePageState extends State<WritePage> {
  late final List<StudyCard> cards = ([...widget.deck.cards]..shuffle()).take(15).toList();
  final ctrl = TextEditingController();
  final focus = FocusNode();
  int i = 0;
  int score = 0;
  bool? ok;

  void _check() {
    if (ok != null) return _next();
    final good = Answer.correct(ctrl.text, cards[i].back);
    setState(() {
      ok = good;
      if (good) score++;
    });
  }

  void _next() {
    setState(() {
      i++;
      ok = null;
      ctrl.clear();
    });
    focus.requestFocus();
  }

  @override
  void dispose() {
    ctrl.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(widget.deck.color);
    if (i >= cards.length) {
      return Scaffold(
        appBar: AppBar(title: Text('Écrire · ${widget.deck.name}')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('✍️', style: TextStyle(fontSize: 72)),
              Text(
                '$score / ${cards.length}',
                style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: color),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Terminer')),
            ],
          ),
        ),
      );
    }
    final c = cards[i];
    return Scaffold(
      appBar: AppBar(title: Text('Écrire · ${widget.deck.name}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('${i + 1} / ${cards.length}', style: theme.textTheme.labelLarge),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: LinearGradient(colors: [color, Color.lerp(color, Colors.black, 0.3)!]),
                ),
                child: Text(
                  c.front,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: ctrl,
                focusNode: focus,
                autofocus: true,
                enabled: ok == null,
                onSubmitted: (_) => _check(),
                decoration: const InputDecoration(hintText: 'Ta réponse… (Entrée pour valider)'),
              ),
              const SizedBox(height: 14),
              if (ok != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: (ok! ? const Color(0xFF23A55A) : const Color(0xFFE5484D)).withValues(alpha: 0.14),
                  ),
                  child: Row(
                    children: [
                      Text(ok! ? '✅' : '❌', style: const TextStyle(fontSize: 26)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          ok! ? 'Juste ! ${c.back}' : 'La réponse : ${c.back}',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (ok == false)
                        TextButton(
                          onPressed: () => setState(() {
                            ok = true;
                            score++;
                          }),
                          child: const Text('J\'avais juste'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: color),
                onPressed: _check,
                child: Text(ok == null ? 'Valider' : 'Suivante'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================================================================== Associer

/// Jeu d'association : relie chaque question à sa réponse, le plus vite
/// possible.
class MatchPage extends StatefulWidget {
  const MatchPage({super.key, required this.module, required this.deck});
  final RevisionsModule module;
  final Deck deck;

  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> {
  late List<(String, String, bool)> tiles; // (id de la carte, texte, recto ?)
  final gone = <int>{};
  int? first;
  int? wrong;
  final watch = Stopwatch()..start();
  Timer? tick;

  @override
  void initState() {
    super.initState();
    final cards = ([...widget.deck.cards]..shuffle()).take(6);
    tiles = [
      for (final c in cards) ...[(c.id, c.front, true), (c.id, c.back, false)],
    ]..shuffle();
    tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    tick?.cancel();
    super.dispose();
  }

  void _tap(int i) {
    if (gone.contains(i) || watch.elapsed.inMilliseconds == 0) return;
    final f = first;
    if (f == null) return setState(() => first = i);
    if (f == i) return setState(() => first = null);
    if (tiles[f].$1 == tiles[i].$1 && tiles[f].$3 != tiles[i].$3) {
      setState(() {
        gone.addAll({f, i});
        first = null;
      });
      if (gone.length == tiles.length) {
        watch.stop();
        tick?.cancel();
        final best = widget.module.store.getJson<int>('best.${widget.deck.id}');
        if (best == null || watch.elapsedMilliseconds < best) {
          unawaited(widget.module.store.setJson('best.${widget.deck.id}', watch.elapsedMilliseconds));
        }
        unawaited(widget.module.revisions.addMinutes(1));
      }
    } else {
      setState(() {
        wrong = i;
        first = null;
      });
      // Une seconde de pénalité, comme dans Quizlet.
      Future<void>.delayed(const Duration(milliseconds: 450), () {
        if (mounted) setState(() => wrong = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(widget.deck.color);
    final secs = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    final done = gone.length == tiles.length;
    final best = widget.module.store.getJson<int>('best.${widget.deck.id}');
    return Scaffold(
      appBar: AppBar(
        title: Text('Associer · ${widget.deck.name}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('⏱️ $secs s', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
      body: done
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 72)),
                  Text(
                    '$secs s',
                    style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: color),
                  ),
                  if (best != null) Text('Record : ${(best / 1000).toStringAsFixed(1)} s'),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Terminer')),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(20),
              child: LayoutBuilder(
                builder: (context, box) {
                  final cols = box.maxWidth > 900 ? 4 : 3;
                  return GridView.count(
                    crossAxisCount: cols,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.6,
                    children: [
                      for (var i = 0; i < tiles.length; i++)
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 250),
                          opacity: gone.contains(i) ? 0 : 1,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              color: wrong == i
                                  ? const Color(0xFFE5484D).withValues(alpha: 0.25)
                                  : first == i
                                  ? color.withValues(alpha: 0.25)
                                  : theme.cardTheme.color,
                              border: Border.all(
                                color: first == i ? color : theme.colorScheme.outlineVariant,
                                width: 2,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => _tap(i),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    tiles[i].$2,
                                    textAlign: TextAlign.center,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: tiles[i].$3 ? FontWeight.w800 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}

// =================================================================== Minuteur

/// Minuteur de concentration (Pomodoro) : 25 min de travail, 5 min de pause.
class FocusPage extends StatefulWidget {
  const FocusPage({super.key, required this.module});
  final RevisionsModule module;

  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> {
  (int, int) preset = (25, 5);
  bool working = true;
  bool running = false;
  late int left = preset.$1 * 60;
  int rounds = 0;
  Timer? timer;

  int get total => (working ? preset.$1 : preset.$2) * 60;

  void _toggle() {
    if (running) {
      timer?.cancel();
      setState(() => running = false);
      return;
    }
    setState(() => running = true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => left--);
      if (left <= 0) _end();
    });
  }

  void _end() {
    timer?.cancel();
    unawaited(SystemSound.play(SystemSoundType.alert));
    if (working) {
      rounds++;
      unawaited(widget.module.revisions.addMinutes(preset.$1));
    }
    setState(() {
      working = !working;
      running = false;
      left = total;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(working ? 'C\'est reparti : on se concentre 💪' : 'Bravo ! ${preset.$2} min de pause ☕')),
    );
  }

  void _reset() {
    timer?.cancel();
    setState(() {
      running = false;
      working = true;
      left = total;
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    // Le temps déjà travaillé compte aussi.
    if (working && left < total) {
      unawaited(widget.module.revisions.addMinutes(((total - left) / 60).floor()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = working ? widget.module.color : const Color(0xFF16A085);
    final m = (left ~/ 60).toString().padLeft(2, '0');
    final s = (left % 60).toString().padLeft(2, '0');
    return Scaffold(
      appBar: AppBar(title: const Text('Minuteur de concentration')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<(int, int)>(
              segments: const [
                ButtonSegment(value: (25, 5), label: Text('25 / 5')),
                ButtonSegment(value: (50, 10), label: Text('50 / 10')),
                ButtonSegment(value: (15, 3), label: Text('15 / 3')),
              ],
              selected: {preset},
              onSelectionChanged: running
                  ? null
                  : (v) => setState(() {
                      preset = v.first;
                      working = true;
                      left = total;
                    }),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: 280,
              height: 280,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: left / total,
                      strokeWidth: 16,
                      strokeCap: StrokeCap.round,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.12),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        working ? 'CONCENTRATION' : 'PAUSE',
                        style: theme.textTheme.labelLarge?.copyWith(
                          letterSpacing: 2,
                          color: color,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '$m:$s',
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text('🍅' * rounds.clamp(0, 8), style: const TextStyle(fontSize: 18)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: color,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                  ),
                  icon: Icon(running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  label: Text(running ? 'Pause' : 'Démarrer'),
                  onPressed: _toggle,
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: 'Recommencer',
                  icon: const Icon(Icons.restart_alt_rounded),
                  onPressed: _reset,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Aujourd\'hui : ${widget.module.revisions.today().minutes} min de révision',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// La fiche de révision d'un paquet préparé pour un contrôle.
class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.deck});
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = deck.testDate;
    final lines = deck.sheet!.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => FichePage(
            title: deck.name,
            markdown: deck.sheet!,
            color: Color(deck.color),
            docLink: deck.sheetDoc == null ? null : GoogleDocs.edit(deck.sheetDoc!),
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFFE67E22), Color(0xFFE0457B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.article_rounded, color: Colors.white, size: 42),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ta fiche de révision${date == null ? '' : ' · contrôle ${_inDays(date)}'}',
                    style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lines.take(3).map((l) => l.replaceAll(RegExp(r'^[#>*\-\s]+'), '')).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }
}
