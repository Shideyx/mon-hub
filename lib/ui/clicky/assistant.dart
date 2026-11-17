import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../core/hub_module.dart';
import '../../core/module_store.dart';
import '../../modules/carnet/carnet_store.dart';
import '../widgets.dart';
import 'initiatives.dart';
import 'quick.dart' show QuickTool;
import 'tutor.dart' show normalize;

/// Le texte sans emojis (pour la voix).
String withoutEmoji(String text) => text
    .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]', unicode: true), '')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'^ ', multiLine: true), '');

/// Un automatisme de l'assistant (chacun s'active à part).
class AssistantFeature {
  const AssistantFeature(this.key, this.icon, this.color, this.title, this.text);
  final String key;
  final IconData icon;
  final Color color;
  final String title;
  final String text;

  static const all = [
    AssistantFeature('anticipation', Icons.alarm_rounded, Color(0xFFE67E22), 'Anticipation',
        'Te prévenir d\'un devoir avant sa date limite : la veille, et 3 jours avant un contrôle ou un gros travail.'),
    AssistantFeature('organisation', Icons.call_split_rounded, Color(0xFFE5484D), 'Organisation',
        'Repérer quand deux évènements de ton agenda se chevauchent.'),
    AssistantFeature('surveillance', Icons.visibility_rounded, Color(0xFF0B6FB8), 'Surveillance',
        'Te dire quand un évènement ou une réunion arrive dans ton agenda, ou qu\'un cours est annulé.'),
    AssistantFeature('assistance', Icons.event_repeat_rounded, Color(0xFF16A085), 'Assistance',
        'Proposer de réorganiser ta journée : un conflit, un cours annulé, une soirée chargée.'),
    AssistantFeature('memoire', Icons.bookmark_rounded, Color(0xFF8E44AD), 'Mémoire',
        'Se souvenir de tes projets, décisions et objectifs quand tu en parles à Clicky.'),
    AssistantFeature('automatisation', Icons.playlist_add_check_rounded, Color(0xFF7C5CFF), 'Automatisation',
        'Proposer d\'ajouter tes nouveaux devoirs à ta liste, et le faire après ton accord.'),
    AssistantFeature('conseils', Icons.lightbulb_rounded, Color(0xFFF1C40F), 'Conseils',
        'Repérer que tu accumules trop de tâches et te proposer des priorités.'),
    AssistantFeature('initiatives', Icons.rocket_launch_rounded, Color(0xFFD35400), 'Initiatives',
        'Prendre les devants sur tout le reste : un rendez-vous ou une date limite dans un message, une mauvaise '
        'note à rattraper, ta série de révisions à sauver, un message qui attend ta réponse, la pluie demain, '
        'un objectif oublié… et les idées de Gemini (si tu as la clé).'),
  ];
}

/// Une proposition de Clicky, à accepter ou non.
class Proposal {
  Proposal({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.details = const [],
    this.accept = 'Oui',
    this.decline = 'Non merci',
    this.onAccept,
    this.onDecline,
  });

  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final List<String> details;
  final String accept;
  final String decline;
  final Future<String?> Function()? onAccept;
  final Future<void> Function()? onDecline;
}

/// Une chose à faire, avec son importance.
class RankedTask {
  RankedTask(this.text, this.score, this.reason, {this.due, this.minutes = 30, this.isTest = false});
  final String text;
  final double score;
  final String reason;
  final DateTime? due;
  final int minutes;
  final bool isTest;
}

/// L'assistant personnel : Clicky qui prend les devants (si tu le veux).
/// Tout est calculé par Mon Hub, sans IA, à partir de ton agenda, de ton
/// cahier de texte, de ta liste et de tes messages.
class Assistant extends ChangeNotifier {
  Assistant._();
  static final instance = Assistant._();

  final store = ModuleStore()..bind('assistant');
  final proposals = <Proposal>[];

  QuickTool? _call;
  Set<String> Function()? _tools;

  /// Alerte (bandeau + notification de Windows).
  void Function(String title, String body)? notify;

  /// Afficher un texte en grand chez Clicky (briefing).
  Future<void> Function(String title, String text)? present;

  Timer? _timer;
  Timer? _first;
  Timer? _ask;
  bool _busy = false;

  // ---------------------------------------------------------------- Réglages

  /// La personne a dit oui à l'assistant.
  bool get consent => store.getJson<bool>('consent') == true;
  bool on(String feature) => consent && store.getJson<bool>('on.$feature') != false;

  /// Le briefing du matin intelligent (activé par défaut).
  bool get briefingOn => store.getJson<bool>('on.briefing') != false;

  Future<void> setOn(String feature, bool v) async {
    await store.setJson('on.$feature', v);
    notifyListeners();
  }

  Future<void> setConsent(bool v) async {
    await store.setJson('consent', v);
    await store.setJson('asked', true);
    proposals.removeWhere((p) => p.id == 'consent');
    notifyListeners();
    if (v) unawaited(tick());
  }

  // ----------------------------------------------------------------- Marche

  void start({required QuickTool call, required Set<String> Function() tools}) {
    _call = call;
    _tools = tools;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => unawaited(tick()));
    _first?.cancel();
    _first = Timer(const Duration(seconds: 30), () => unawaited(tick()));
    _ask?.cancel();
    if (!consent && store.getJson<bool>('asked') != true) {
      _ask = Timer(const Duration(seconds: 20), () {
        if (consent || proposals.any((p) => p.id == 'consent')) return;
        propose(
          Proposal(
            id: 'consent',
            icon: Icons.auto_awesome_rounded,
            color: const Color(0xFF7C5CFF),
            title: 'Je peux devenir ton assistant personnel',
            body: 'Te prévenir avant tes devoirs, repérer les conflits dans ton agenda, surveiller les nouveaux '
                'évènements, réorganiser ta journée, retenir tes projets, ajouter tes devoirs à ta liste '
                '(avec ton accord) et te conseiller des priorités. Tout reste sur ton PC.',
            accept: 'Oui, vas-y',
            decline: 'Plus tard',
            onAccept: () async {
              await setConsent(true);
              return 'C\'est parti ! Tu peux tout régler dans Réglages → Assistant personnel.';
            },
            onDecline: () => store.setJson('asked', true),
          ),
        );
      });
    }
  }

  void stop() {
    _timer?.cancel();
    _first?.cancel();
    _ask?.cancel();
    _timer = null;
    _call = null;
  }

  /// Les actions de Mon Hub sont branchées (assistant démarré).
  bool get ready => _call != null;

  /// Donne les actions sans démarrer l'assistant (briefing demandé à Clicky
  /// partout, par exemple).
  void useTools({required QuickTool call, required Set<String> Function() tools}) {
    _call ??= call;
    _tools ??= tools;
  }

  /// Repart de zéro (tests).
  @visibleForTesting
  void reset() {
    stop();
    _tools = null;
    _busy = false;
    proposals.clear();
  }


  void propose(Proposal p) {
    if (proposals.any((x) => x.id == p.id)) return;
    proposals.add(p);
    notifyListeners();
  }

  /// La personne répond à une proposition.
  Future<String?> answer(Proposal p, bool yes) async {
    proposals.remove(p);
    notifyListeners();
    try {
      if (yes) return await p.onAccept?.call();
      await p.onDecline?.call();
    } catch (e) {
      return '$e';
    }
    return null;
  }

  Future<Object?> _get(String tool, [Map<String, dynamic> args = const {}]) async {
    final call = _call;
    if (call == null || !(_tools?.call().contains(tool) ?? false)) return null;
    try {
      return await call(tool, args);
    } catch (_) {
      return null;
    }
  }

  static List<Map> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map) e,
  ];

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('$v');

  // Ce qui a déjà été dit (pour ne jamais répéter une alerte).
  Map<String, int> get _seenMap => (store.getJson<Map<String, dynamic>>('seen') ?? const {}).map(
    (k, v) => MapEntry(k, (v as num?)?.toInt() ?? 0),
  );

  bool seen(String key) => _seenMap.containsKey(key);

  Future<void> mark(String key, [DateTime? now]) async {
    final n = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final m = {
      for (final e in _seenMap.entries)
        if (n - e.value < const Duration(days: 60).inMilliseconds) e.key: e.value,
      key: n,
    };
    await store.setJson('seen', m);
  }

  // ---------------------------------------------------------- Le tour (5 min)

  Future<void> tick({DateTime? now}) async {
    if (_busy || _call == null || !consent) return;
    _busy = true;
    final n = now ?? DateTime.now();
    try {
      final hw = _list(await _get('ecole_devoirs'));
      final events = _list(await _get('agenda_lire', {
        'debut': DateTime(n.year, n.month, n.day).toIso8601String().substring(0, 10),
        'jours': 14,
      }));
      if (on('anticipation')) await _anticipate(hw, n);
      final clash = on('organisation') ? await _conflicts(events, n) : <String>[];
      final changes = on('surveillance') ? await _watch(events, n) : <String>[];
      if (on('automatisation')) await _offerTasks(hw, n);
      final overloaded = on('conseils') ? await _advise(hw, n) : false;
      if (on('assistance') && (clash.isNotEmpty || changes.any((c) => c.startsWith('annul')) || overloaded)) {
        await _offerPlan(hw, n, why: clash.isNotEmpty ? 'conflit' : (overloaded ? 'chargée' : 'annulé'));
      }
      if (on('initiatives')) await _initiatives(hw, n);
    } finally {
      _busy = false;
    }
  }

  // Anticipation ------------------------------------------------------------

  static final _bigWork = RegExp(r'expos|dm\b|devoir maison|projet|r[ée]daction|dissertation|oral|dossier|commentaire', caseSensitive: false);

  /// Les alertes de devoirs à donner maintenant : (clé, titre, texte).
  static List<(String, String, String)> homeworkAlerts(List<Map> hw, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final out = <(String, String, String)>[];
    for (final h in hw) {
      if (h['fait'] == true) continue;
      final due = _date(h['pour_le']);
      if (due == null) continue;
      final days = DateTime(due.year, due.month, due.day).difference(today).inDays;
      final subject = '${h['matiere'] ?? ''}';
      final content = '${h['contenu'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      final short = content.length > 90 ? '${content.substring(0, 90)}…' : content;
      final test = h['controle'] == true;
      final big = test || _bigWork.hasMatch(content);
      final key = '$subject|${due.toIso8601String().substring(0, 10)}';
      // La veille, à partir de 16 h.
      if (days == 1 && now.hour >= 16) {
        out.add((
          'hw1|$key',
          test ? '📝 Contrôle de $subject demain' : '⏰ Pour demain : $subject',
          short.isEmpty ? 'Pense à t\'y mettre ce soir.' : short,
        ));
      }
      // 3 jours avant un contrôle ou un gros travail.
      if (big && days >= 2 && days <= 3) {
        out.add((
          'hw3|$key',
          test ? '📝 Contrôle de $subject dans $days jours' : '📌 $subject à rendre dans $days jours',
          '${short.isEmpty ? '' : '$short. '}Mieux vaut commencer maintenant.',
        ));
      }
    }
    return out;
  }

  Future<void> _anticipate(List<Map> hw, DateTime n) async {
    for (final (key, title, body) in homeworkAlerts(hw, n)) {
      if (seen(key)) continue;
      await mark(key, n);
      notify?.call(title, body);
    }
  }

  // Organisation ------------------------------------------------------------

  /// Les évènements qui se chevauchent (sans les journées entières).
  static List<(Map, Map)> conflicts(List<Map> events) {
    final list = [
      for (final e in events)
        if (e['annule'] != true)
          if ((_date(e['debut']), _date(e['fin'])) case (final a?, final b?) when b.difference(a).inHours < 20) e,
    ]..sort((x, y) => _date(x['debut'])!.compareTo(_date(y['debut'])!));
    final out = <(Map, Map)>[];
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        final aEnd = _date(list[i]['fin'])!;
        final bStart = _date(list[j]['debut'])!;
        if (!bStart.isBefore(aEnd)) break;
        // Deux cours d'École Directe ne « se battent » pas entre eux.
        if (list[i]['source'] == list[j]['source'] && '${list[i]['source']}'.contains('cole')) continue;
        out.add((list[i], list[j]));
      }
    }
    return out;
  }

  static String _hour(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static String _day(DateTime d, DateTime now) {
    final diff = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (diff == 0) return 'aujourd\'hui';
    if (diff == 1) return 'demain';
    return '${frDays[d.weekday - 1]} ${d.day} ${frMonths[d.month - 1]}';
  }

  Future<List<String>> _conflicts(List<Map> events, DateTime n) async {
    final found = <String>[];
    for (final (a, b) in conflicts(events)) {
      final at = _date(b['debut'])!;
      final key = 'clash|${a['titre']}|${b['titre']}|${at.toIso8601String()}';
      if (seen(key)) continue;
      await mark(key, n);
      found.add(key);
      notify?.call(
        '⚠️ Conflit ${_day(at, n)} à ${_hour(at)}',
        '« ${a['titre']} » et « ${b['titre']} » se chevauchent.',
      );
    }
    return found;
  }

  // Surveillance ------------------------------------------------------------

  static String eventKey(Map e) => '${e['titre']}|${_date(e['debut'])?.toIso8601String()}';

  Future<List<String>> _watch(List<Map> events, DateTime n) async {
    final changes = <String>[];
    // Ce qui arrive de l'extérieur (invitations Google Agenda…) : ce que tu
    // ajoutes toi-même dans Mon Hub, tu le sais déjà.
    final personal = [
      for (final e in events)
        if ('${e['source']}'.contains('Google') && e['annule'] != true) e,
    ];
    final keys = {for (final e in personal) eventKey(e)};
    final before = (store.getJson<List<dynamic>>('snapshot') ?? const []).cast<String>().toSet();
    final first = store.getJson<List<dynamic>>('snapshot') == null;
    if (!first) {
      for (final e in personal.where((e) => !before.contains(eventKey(e)))) {
        final at = _date(e['debut'])!;
        if (!at.isAfter(n)) continue;
        final meeting = RegExp(r'r[ée]union|meeting|rdv|rendez|conseil|parents', caseSensitive: false).hasMatch('${e['titre']}');
        notify?.call(
          meeting ? '📅 Réunion ajoutée à ton agenda' : '📅 Nouveau dans ton agenda',
          '« ${e['titre']} » ${_day(at, n)} à ${_hour(at)}${'${e['lieu'] ?? ''}'.isEmpty ? '' : ' (${e['lieu']})'}.',
        );
        changes.add('nouveau|${eventKey(e)}');
      }
    }
    await store.setJson('snapshot', keys.toList());
    // Cours annulés (aujourd'hui et demain).
    for (final e in events) {
      if (e['annule'] != true) continue;
      final at = _date(e['debut'])!;
      if (!at.isAfter(n) || at.difference(n).inHours > 36) continue;
      final key = 'annule|${eventKey(e)}';
      if (seen(key)) continue;
      await mark(key, n);
      notify?.call('🎉 Cours annulé ${_day(at, n)}', '${e['titre']} à ${_hour(at)} n\'a pas lieu.');
      changes.add(key);
    }
    return changes;
  }

  // Automatisation ----------------------------------------------------------

  Future<void> _offerTasks(List<Map> hw, DateTime n) async {
    final today = DateTime(n.year, n.month, n.day);
    final fresh = [
      for (final h in hw)
        if (h['fait'] != true)
          if (_date(h['pour_le']) case final d? when !d.isBefore(today))
            if (!seen('task|${h['matiere']}|${d.toIso8601String().substring(0, 10)}')) h,
    ];
    if (fresh.isEmpty || proposals.any((p) => p.id == 'tasks')) return;
    String label(Map h) {
      final c = '${h['contenu'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      return '${h['matiere']} : ${c.length > 60 ? '${c.substring(0, 60)}…' : c}';
    }

    Future<void> markAll() async {
      for (final h in fresh) {
        await mark('task|${h['matiere']}|${_date(h['pour_le'])!.toIso8601String().substring(0, 10)}', n);
      }
    }

    propose(
      Proposal(
        id: 'tasks',
        icon: Icons.playlist_add_check_rounded,
        color: const Color(0xFF7C5CFF),
        title: fresh.length == 1 ? 'Un nouveau devoir' : '${fresh.length} nouveaux devoirs',
        body: 'Je les ajoute à ta liste de tâches, avec leur date ?',
        details: [for (final h in fresh.take(5)) '${label(h)} — ${_day(_date(h['pour_le'])!, n)}'],
        accept: 'Ajouter',
        onAccept: () async {
          final c = Carnet.instance;
          await c.load();
          for (final h in fresh) {
            await c.add('todos', {
              'text': label(h),
              'due': _date(h['pour_le'])!.millisecondsSinceEpoch,
              'source': 'ecole',
            });
          }
          await markAll();
          return '${fresh.length} tâche${fresh.length > 1 ? 's' : ''} ajoutée${fresh.length > 1 ? 's' : ''} à ta liste.';
        },
        onDecline: markAll,
      ),
    );
  }

  // Conseils ----------------------------------------------------------------

  /// Tout ce qu'il y a à faire, du plus important au moins important.
  static List<RankedTask> rank(List<Map> hw, List<CarnetItem> todos, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final out = <RankedTask>[];
    for (final h in hw) {
      if (h['fait'] == true) continue;
      final due = _date(h['pour_le']);
      if (due == null) continue;
      final days = DateTime(due.year, due.month, due.day).difference(today).inDays;
      if (days < 0 || days > 7) continue;
      final test = h['controle'] == true;
      final c = '${h['contenu'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      var score = 70.0 - days * 12;
      if (test) score += 25;
      if (_bigWork.hasMatch(c)) score += 10;
      out.add(RankedTask(
        test ? 'Réviser ${h['matiere']}' : '${h['matiere']} : ${c.length > 50 ? '${c.substring(0, 50)}…' : c}',
        score,
        test ? 'contrôle ${days == 1 ? 'demain' : 'dans $days jours'}' : (days <= 1 ? 'pour ${days == 0 ? 'aujourd\'hui' : 'demain'}' : 'pour dans $days jours'),
        due: due,
        minutes: test ? 45 : (_bigWork.hasMatch(c) ? 45 : 30),
        isTest: test,
      ));
    }
    for (final t in todos) {
      if (t.done) continue;
      final dueMs = (t.data['due'] as num?)?.toInt();
      final due = dueMs == null ? null : DateTime.fromMillisecondsSinceEpoch(dueMs);
      // Les devoirs déjà ajoutés à la liste sont comptés une seule fois.
      if (t.data['source'] == 'ecole' && due != null && !due.isBefore(today)) continue;
      final age = now.difference(t.at).inDays;
      double score;
      String reason;
      if (due != null && due.isBefore(today)) {
        final late = today.difference(DateTime(due.year, due.month, due.day)).inDays;
        score = 90 + math.min(late, 10).toDouble();
        reason = 'en retard de $late jour${late > 1 ? 's' : ''}';
      } else if (due != null) {
        final days = DateTime(due.year, due.month, due.day).difference(today).inDays;
        score = 70.0 - days * 10;
        reason = days == 0 ? 'pour aujourd\'hui' : (days == 1 ? 'pour demain' : 'pour dans $days jours');
      } else {
        score = 20 + math.min(age * 2, 30).toDouble();
        reason = age >= 3 ? 'attend depuis $age jours' : 'à faire';
      }
      out.add(RankedTask(t.text, score, reason, due: due, minutes: 25));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// Trop de choses à faire ?
  static bool overloaded(List<RankedTask> tasks) =>
      tasks.length >= 8 || tasks.where((t) => t.score >= 55).length >= 4;

  Future<bool> _advise(List<Map> hw, DateTime n) async {
    final c = Carnet.instance;
    await c.load();
    final tasks = rank(hw, c.list('todos'), n);
    if (!overloaded(tasks)) return false;
    final key = 'conseil|${n.toIso8601String().substring(0, 10)}';
    if (seen(key) || n.hour < 12) return true;
    await mark(key, n);
    propose(
      Proposal(
        id: 'conseil',
        icon: Icons.lightbulb_rounded,
        color: const Color(0xFFF1C40F),
        title: 'Ça fait beaucoup (${tasks.length} choses à faire)',
        body: 'Voici par quoi commencer :',
        details: [for (final (i, t) in tasks.take(3).indexed) '${i + 1}. ${t.text} (${t.reason})'],
        accept: on('assistance') ? 'Les placer ce soir' : 'Compris',
        onAccept: () async {
          if (!on('assistance')) return null;
          final plan = await planDay(n, tasks: tasks.take(3).toList());
          if (plan.isEmpty) return 'Je ne trouve pas de créneau libre ce soir.';
          await _get('agenda_ajouter_plan', {'plan': jsonEncode(plan)});
          return 'C\'est dans ton agenda : ${[for (final p in plan) '${(p['debut'] as String).substring(11, 16)} ${p['titre']}'].join(', ')}.';
        },
      ),
    );
    return true;
  }

  // Assistance --------------------------------------------------------------

  /// Place les tâches dans des créneaux libres (« 17:00-18:30 »).
  static List<Map<String, String>> planSlots(List<String> slots, List<RankedTask> tasks, DateTime day) {
    final plan = <Map<String, String>>[];
    var queue = [...tasks];
    String fmt(DateTime d) => d.toIso8601String().substring(0, 16);
    for (final slot in slots) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$').firstMatch(slot);
      if (m == null) continue;
      var t = DateTime(day.year, day.month, day.day, int.parse(m[1]!), int.parse(m[2]!));
      final end = DateTime(day.year, day.month, day.day, int.parse(m[3]!), int.parse(m[4]!));
      final rest = <RankedTask>[];
      for (final task in queue) {
        final stop = t.add(Duration(minutes: task.minutes));
        if (stop.isAfter(end)) {
          rest.add(task);
          continue;
        }
        plan.add({'titre': task.text, 'debut': fmt(t), 'fin': fmt(stop), 'note': 'Placé par Clicky (${task.reason})'});
        // 10 minutes de pause entre deux choses.
        t = stop.add(const Duration(minutes: 10));
      }
      queue = rest;
      if (queue.isEmpty) break;
    }
    return plan;
  }

  /// Un plan pour aujourd'hui (après les cours), dans les créneaux libres.
  Future<List<Map<String, String>>> planDay(DateTime n, {List<RankedTask>? tasks}) async {
    final list = tasks ?? rank(_list(await _get('ecole_devoirs')), Carnet.instance.list('todos'), n).take(4).toList();
    if (list.isEmpty) return const [];
    final start = math.max(n.hour + 1, n.weekday >= 6 ? 10 : 17);
    if (start >= 21) return const [];
    final free = _list(await _get('agenda_creneaux_libres', {
      'debut': n.toIso8601String().substring(0, 10),
      'jours': 1,
      'de': start,
      'a': 21,
      'minimum': 30,
    }));
    final slots = [for (final s in (free.firstOrNull?['libre'] as List?) ?? const []) '$s'];
    return planSlots(slots, list, n);
  }

  Future<void> _offerPlan(List<Map> hw, DateTime n, {required String why}) async {
    final key = 'plan|${n.toIso8601String().substring(0, 10)}|$why';
    if (seen(key) || proposals.any((p) => p.id == 'plan')) return;
    await mark(key, n);
    final plan = await planDay(n);
    if (plan.isEmpty) return;
    propose(
      Proposal(
        id: 'plan',
        icon: Icons.event_repeat_rounded,
        color: const Color(0xFF16A085),
        title: switch (why) {
          'conflit' => 'Ta journée a un conflit : je te propose un plan',
          'annulé' => 'Un cours est annulé : on en profite ?',
          _ => 'Ta soirée est chargée : je te propose un plan',
        },
        body: 'Je le mets dans ton agenda ?',
        details: [for (final p in plan) '${p['debut']!.substring(11, 16)}–${p['fin']!.substring(11, 16)} ${p['titre']}'],
        accept: 'Mettre dans l\'agenda',
        onAccept: () async {
          await _get('agenda_ajouter_plan', {'plan': jsonEncode(plan)});
          return 'Ton plan est dans l\'agenda.';
        },
      ),
    );
  }

  // Initiatives -------------------------------------------------------------

  Future<void> _initiatives(List<Map> hw, DateTime n) async {
    for (final step in [
      () => _spotInMessages(n),
      () => _grades(n),
      () => _streak(n),
      () => _unanswered(n),
      () => _weather(n),
      () => _bedtime(hw, n),
      () => _goals(n),
      () => _aiIdeas(n),
    ]) {
      try {
        await step();
      } catch (_) {
        // Une source en panne n'empêche pas les autres.
      }
    }
  }

  /// Le titre d'un rendez-vous repéré.
  static String spotTitle(SpottedDate d, {String subject = '', String who = ''}) {
    final cue = d.cue[0].toUpperCase() + d.cue.substring(1);
    final sub = subject.trim();
    if (sub.isNotEmpty && sub.length <= 70) return sub;
    if (who.isNotEmpty) return d.kind == 'rdv' ? '$cue avec $who' : '$cue ($who)';
    final s = d.sentence.replaceAll(RegExp(r'\s+'), ' ');
    return s.length <= 60 ? s : '${s.substring(0, 60)}…';
  }

  /// Propose d'ajouter un rendez-vous ou une date limite trouvés dans un
  /// message.
  void offerSpotted(String key, SpottedDate d, DateTime n, {required String source, String subject = '', String who = ''}) {
    if (proposals.where((p) => p.id.startsWith('spot|')).length >= 3) return;
    final title = spotTitle(d, subject: subject, who: who);
    final when = '${_day(d.at, n)}${d.hasTime ? ' à ${_hour(d.at)}' : ''}';
    final event = d.kind == 'rdv' && d.hasTime;
    String iso(DateTime t) => t.toIso8601String().substring(0, 16);
    propose(
      Proposal(
        id: 'spot|$key',
        icon: event ? Icons.event_available_rounded : Icons.hourglass_bottom_rounded,
        color: const Color(0xFFD35400),
        title: event ? 'Un rendez-vous dans $source' : 'Une date limite dans $source',
        body: '« $title » $when. ${event ? 'Je l\'ajoute à ton agenda ?' : 'Je l\'ajoute à ta liste ?'}',
        details: [d.sentence.length > 140 ? '${d.sentence.substring(0, 140)}…' : d.sentence],
        accept: event ? 'Ajouter à l\'agenda' : 'Ajouter à ma liste',
        onAccept: () async {
          if (event) {
            await _get('agenda_ajouter', {
              'titre': title,
              'debut': iso(d.at),
              'fin': iso(d.at.add(const Duration(hours: 1))),
              'note': 'Repéré par Clicky dans $source',
            });
            return 'C\'est dans ton agenda : $title, $when.';
          }
          final c = Carnet.instance;
          await c.load();
          await c.add('todos', {'text': title, 'due': d.at.millisecondsSinceEpoch, 'source': 'clicky'});
          return 'Ajouté à ta liste, pour $when.';
        },
      ),
    );
  }

  Future<void> _spotInMessages(DateTime n) async {
    var reads = 0;
    for (final m in _list(await _get('ecole_messages'))) {
      if (m['lu'] != false) continue;
      final key = 'msg|ed|${m['id']}';
      if (seen(key)) continue;
      if (reads >= 3) break;
      reads++;
      await mark(key, n);
      final body = await _get('ecole_message_lire', {'id': m['id']});
      final text = '${m['objet'] ?? ''}. ${body is Map ? (body['texte'] ?? body['contenu'] ?? body['text'] ?? '') : (body ?? '')}';
      final found = DateSpotter.find(text, n).firstOrNull;
      if (found != null) offerSpotted(key, found, n, source: 'un message École Directe', subject: '${m['objet'] ?? ''}');
    }
    for (final m in _list(await _get('mails_lister', {'nombre': 15}))) {
      if (m['lu'] != false || _promo.hasMatch('${m['de']} ${m['objet']}')) continue;
      final key = 'msg|mail|${m['boite']}|${m['uid']}';
      if (seen(key)) continue;
      await mark(key, n);
      final found = DateSpotter.find('${m['objet'] ?? ''}', n).firstOrNull;
      if (found != null) offerSpotted(key, found, n, source: 'un mail', subject: '${m['objet'] ?? ''}');
    }
    // (Instagram n'est jamais lu en arrière-plan : il l'interdit.)
    final dms = [
      ..._list(await _get('discord_conversations')).map((d) => ('Discord', d)),
    ];
    for (final (app, d) in dms) {
      if (d['non_lu'] != true || '${d['dernier'] ?? ''}'.isEmpty) continue;
      final key = 'msg|$app|${d['id']}|${'${d['dernier']}'.hashCode}';
      if (seen(key)) continue;
      await mark(key, n);
      final text = '${d['dernier']}'.replaceFirst(RegExp(r'^[^:]{1,40} : '), '');
      final found = DateSpotter.find(text, n).firstOrNull;
      if (found != null) offerSpotted(key, found, n, source: '$app (${d['nom']})', who: '${d['nom'] ?? ''}');
    }
  }

  /// Le premier créneau libre (aujourd'hui puis les jours suivants) pour
  /// une tâche.
  Future<Map<String, String>?> _nextSlot(RankedTask task, DateTime n, {int days = 3}) async {
    final free = _list(await _get('agenda_creneaux_libres', {
      'debut': n.toIso8601String().substring(0, 10),
      'jours': days,
      'de': 17,
      'a': 21,
      'minimum': task.minutes,
    }));
    for (final d in free) {
      final day = DateTime.tryParse('${d['jour']}');
      if (day == null) continue;
      final plan = planSlots([for (final s in (d['libre'] as List?) ?? const []) '$s'], [task], day);
      if (plan.isNotEmpty) return plan.first;
    }
    return null;
  }

  Future<void> _grades(DateTime n) async {
    final grades = _list(await _get('ecole_notes'));
    if (grades.isEmpty) return;
    String key(Map g) => 'note|${g['matiere']}|${g['devoir']}|${g['date']}|${g['note']}';
    // La première fois : on ne commente pas les anciennes notes.
    if (store.getJson<bool>('grades.init') != true) {
      for (final g in grades) {
        await mark(key(g), n);
      }
      await store.setJson('grades.init', true);
      return;
    }
    for (final g in grades) {
      final k = key(g);
      if (seen(k)) continue;
      await mark(k, n);
      final v = DateSpotter.grade20('${g['note']}');
      if (v == null) continue;
      final subject = '${g['matiere']}';
      if (v >= 16) {
        notify?.call('🎉 Bravo pour ton ${g['note']} en $subject !', 'Continue comme ça${'${g['devoir']}'.isEmpty ? '' : ' (« ${g['devoir']} »)'}.');
      } else if (v < 10) {
        final task = RankedTask('Revoir $subject${'${g['devoir']}'.isEmpty ? '' : ' : ${g['devoir']}'}', 80, 'note de ${g['note']}');
        final slot = await _nextSlot(task, n);
        propose(
          Proposal(
            id: 'note|$k',
            icon: Icons.trending_up_rounded,
            color: const Color(0xFFD35400),
            title: 'Ta note en $subject (${g['note']}) : on rattrape ça ?',
            body: slot == null
                ? 'Revois ce chapitre cette semaine : 30 minutes suffisent pour remonter la pente.'
                : 'Je te réserve 30 minutes ${_day(DateTime.parse(slot['debut']!), n)} à ${_hour(DateTime.parse(slot['debut']!))} pour revoir ce chapitre ?',
            accept: slot == null ? 'Compris' : 'Réserver',
            onAccept: slot == null
                ? null
                : () async {
                    await _get('agenda_ajouter_plan', {'plan': jsonEncode([slot])});
                    return 'C\'est réservé dans ton agenda.';
                  },
          ),
        );
      }
    }
  }

  Future<void> _streak(DateTime n) async {
    if (n.hour < 19 || n.hour >= 23) return;
    final key = 'serie|${n.toIso8601String().substring(0, 10)}';
    if (seen(key)) return;
    final r = await _get('revision_paquets');
    if (r is! Map) return;
    final serie = (r['serie_jours'] as num?)?.toInt() ?? 0;
    final done = (r['cartes_faites_aujourdhui'] as num?)?.toInt() ?? 0;
    final due = (r['a_revoir_aujourdhui'] as num?)?.toInt() ?? 0;
    if (serie < 2 || done > 0 || due == 0) return;
    await mark(key, n);
    notify?.call('🔥 Ta série de $serie jours de révision', 'Elle s\'arrête ce soir si tu ne révises pas : 5 minutes de cartes suffisent ($due à revoir).');
  }

  Future<void> _unanswered(DateTime n) async {
    if (n.hour < 10 || n.hour >= 21) return;
    final waiting = (store.getJson<Map<String, dynamic>>('waiting') ?? const {}).map((k, v) => MapEntry(k, (v as num).toInt()));
    final now = <String, int>{};
    final list = [
      ..._list(await _get('discord_conversations')).map((d) => ('Discord', d)),
    ];
    for (final (app, d) in list) {
      if (d['non_lu'] != true) continue;
      final key = 'attente|$app|${d['id']}|${'${d['dernier']}'.hashCode}';
      final since = waiting[key] ?? n.millisecondsSinceEpoch;
      now[key] = since;
      final hours = (n.millisecondsSinceEpoch - since) ~/ 3600000;
      if (hours < 12 || seen(key)) continue;
      await mark(key, n);
      final last = '${d['dernier'] ?? ''}'.replaceFirst(RegExp(r'^[^:]{1,40} : '), '');
      notify?.call('💬 ${d['nom']} attend ta réponse', 'Message sur $app depuis $hours h${last.isEmpty ? '' : ' : « ${last.length > 80 ? '${last.substring(0, 80)}…' : last} »'}');
    }
    await store.setJson('waiting', now);
  }

  Future<void> _weather(DateTime n) async {
    if (n.hour < 19 || n.hour >= 23) return;
    final key = 'meteo|${n.toIso8601String().substring(0, 10)}';
    if (seen(key)) return;
    await mark(key, n);
    final w = await _get('carnet_meteo');
    if (w is! Map) return;
    final rain = (w['pluie_demain_pourcent'] as num?)?.toInt() ?? 0;
    if (rain >= 60) notify?.call('☔ Demain, $rain % de risque de pluie', 'Pense à ton parapluie (demain : ${w['demain']}).');
  }

  Future<void> _bedtime(List<Map> hw, DateTime n) async {
    if (n.hour < 23 && n.hour >= 1) return;
    final day = n.hour < 1 ? n : n.add(const Duration(days: 1));
    final test = hw.where((h) {
      final d = _date(h['pour_le']);
      return h['controle'] == true && d != null && d.year == day.year && d.month == day.month && d.day == day.day;
    }).firstOrNull;
    if (test == null) return;
    final key = 'dodo|${day.toIso8601String().substring(0, 10)}';
    if (seen(key)) return;
    await mark(key, n);
    notify?.call('😴 Contrôle de ${test['matiere']} demain', 'Il est tard : une bonne nuit t\'aidera plus qu\'une heure de révision en plus.');
  }

  Future<void> _goals(DateTime n) async {
    if (n.hour < 9 || n.hour >= 20) return;
    final today = 'objectifs|${n.toIso8601String().substring(0, 10)}';
    if (seen(today) || proposals.any((p) => p.id.startsWith('goal|'))) return;
    final c = Carnet.instance;
    await c.load();
    final seenAt = _seenMap;
    for (final g in c.list('goals')) {
      if (g.done || n.difference(g.at).inDays < 3) continue;
      final key = 'goal|${normalize(g.text)}';
      final last = seenAt[key];
      if (last != null && n.millisecondsSinceEpoch - last < const Duration(days: 7).inMilliseconds) continue;
      await mark(today, n);
      await mark(key, n);
      final slot = await _nextSlot(RankedTask(g.text, 50, 'ton objectif'), n);
      propose(
        Proposal(
          id: key,
          icon: Icons.flag_rounded,
          color: const Color(0xFFD35400),
          title: 'Un petit pas pour ton objectif ?',
          body: '« ${g.text} »${slot == null ? '' : ' : je te réserve 30 minutes ${_day(DateTime.parse(slot['debut']!), n)} à ${_hour(DateTime.parse(slot['debut']!))} ?'}',
          accept: slot == null ? 'Bonne idée' : 'Réserver',
          onAccept: slot == null
              ? null
              : () async {
                  await _get('agenda_ajouter_plan', {'plan': jsonEncode([slot])});
                  return 'Réservé dans ton agenda. Courage !';
                },
        ),
      );
      return;
    }
  }

  /// Une fois par jour, Gemini (gratuit, jamais Claude) cherche ce que les
  /// règles n'ont pas vu.
  Future<void> _aiIdeas(DateTime n) async {
    if (n.hour < 10 || n.hour >= 21 || store.getJson<bool>('initiativesAi') == false) return;
    final key = 'ia|${n.toIso8601String().substring(0, 10)}';
    if (seen(key) || !await AiText.hasGemini()) return;
    await mark(key, n);
    final today = briefingText(await collect(n));
    final r = await AiText.ask(
      'Voici la situation de ma journée, préparée par mon appli :\n---\n$today\n---\n'
      'Les rappels de devoirs, les conflits d\'agenda et les priorités sont déjà gérés. Trouve au maximum 2 '
      'initiatives VRAIMENT utiles en plus (préparer quelque chose à l\'avance, profiter d\'un créneau libre, un '
      'message important à traiter, la santé, un objectif…). Rien d\'utile : réponds []. Réponds seulement en JSON : '
      '[{"titre":"court","texte":"une phrase","action":"tache|evenement|aucune","quand":"AAAA-MM-JJTHH:MM","duree_min":30}]',
      system: 'Tu es Clicky, l\'assistant personnel proactif d\'un lycéen français. Tu es concret et bref.',
      geminiOnly: true,
    );
    for (final (i, idea) in parseIdeas(AiText.json(r), n).take(2).indexed) {
      propose(
        Proposal(
          id: 'ia|$i|${n.day}',
          icon: Icons.tips_and_updates_rounded,
          color: const Color(0xFFD35400),
          title: idea.title,
          body: idea.text,
          accept: switch (idea.action) {
            'evenement' => 'Mettre dans l\'agenda',
            'tache' => 'Ajouter à ma liste',
            _ => 'Merci',
          },
          onAccept: switch (idea.action) {
            'evenement' => () async {
              final at = idea.when!;
              await _get('agenda_ajouter', {
                'titre': idea.title,
                'debut': at.toIso8601String().substring(0, 16),
                'fin': at.add(Duration(minutes: idea.minutes)).toIso8601String().substring(0, 16),
                'note': 'Idée de Clicky',
              });
              return 'C\'est dans ton agenda.';
            },
            'tache' => () async {
              final c = Carnet.instance;
              await c.load();
              await c.add('todos', {'text': idea.title, 'source': 'clicky'});
              return 'Ajouté à ta liste.';
            },
            _ => null,
          },
        ),
      );
    }
  }

  /// Les idées renvoyées par l'IA (en ignorant ce qui est mal formé).
  static List<({String title, String text, String action, DateTime? when, int minutes})> parseIdeas(Object? json, DateTime now) => [
    for (final x in (json is List ? json : const []))
      if (x is Map && '${x['titre'] ?? ''}'.trim().isNotEmpty)
        if (('${x['action']}', DateTime.tryParse('${x['quand'] ?? ''}')) case (final a, final w))
          (
            title: '${x['titre']}'.trim(),
            text: '${x['texte'] ?? ''}'.trim(),
            // Un évènement sans date valide (ou passée) devient une tâche.
            action: a == 'evenement' ? (w != null && w.isAfter(now) ? 'evenement' : 'tache') : (a == 'tache' ? 'tache' : 'aucune'),
            when: w,
            minutes: ((x['duree_min'] as num?)?.toInt() ?? 30).clamp(10, 240),
          ),
  ];

  // Outils (pour Clicky et Claude) ------------------------------------------

  List<HubTool> get tools => [
    HubTool(
      name: 'assistant_priorites',
      description: 'Assistant personnel : tout ce que j\'ai à faire (devoirs, contrôles, ma liste), classé du plus '
          'important au moins important, avec la raison. Pour « par quoi je commence ? », « mes priorités ».',
      run: (_) async {
        final n = DateTime.now();
        final c = Carnet.instance;
        await c.load();
        final tasks = rank(_list(await _get('ecole_devoirs')), c.list('todos'), n);
        return {
          'trop_de_choses': overloaded(tasks),
          'priorites': [for (final t in tasks.take(10)) {'tache': t.text, 'pourquoi': t.reason}],
        };
      },
    ),
    HubTool(
      name: 'assistant_planifier_journee',
      description: 'Assistant personnel : propose un plan pour aujourd\'hui (après les cours), dans mes créneaux '
          'libres, avec mes tâches les plus importantes. Montre une proposition à accepter (rien n\'est ajouté sans '
          'mon accord).',
      run: (_) async {
        final n = DateTime.now();
        final plan = await planDay(n);
        if (plan.isEmpty) return 'Rien à placer (ou plus de créneau libre aujourd\'hui).';
        proposals.removeWhere((p) => p.id == 'plan');
        propose(
          Proposal(
            id: 'plan',
            icon: Icons.event_repeat_rounded,
            color: const Color(0xFF16A085),
            title: 'Mon plan pour ta journée',
            body: 'Je le mets dans ton agenda ?',
            details: [for (final p in plan) '${p['debut']!.substring(11, 16)}–${p['fin']!.substring(11, 16)} ${p['titre']}'],
            accept: 'Mettre dans l\'agenda',
            onAccept: () async {
              await _get('agenda_ajouter_plan', {'plan': jsonEncode(plan)});
              return 'Ton plan est dans l\'agenda.';
            },
          ),
        );
        return {'plan_propose': plan, 'info': 'La proposition est affichée : la personne clique pour l\'ajouter.'};
      },
    ),
    HubTool(
      name: 'assistant_ajouter_plan_journee',
      description: 'Assistant personnel : prépare le plan de la journée (tâches importantes dans les créneaux libres '
          'après les cours) et l\'ajoute directement à l\'agenda. Seulement quand la personne a dit oui.',
      run: (_) async {
        final plan = await planDay(DateTime.now());
        if (plan.isEmpty) return 'Rien à placer (ou plus de créneau libre aujourd\'hui).';
        await _get('agenda_ajouter_plan', {'plan': jsonEncode(plan)});
        proposals.removeWhere((p) => p.id == 'plan');
        notifyListeners();
        return 'C\'est dans ton agenda : ${[for (final p in plan) '${p['debut']!.substring(11, 16)} ${p['titre']}'].join(', ')}.';
      },
    ),
    HubTool(
      name: 'assistant_objectifs',
      description: 'Mes objectifs personnels : action = lister, ajouter, fini ou supprimer (avec texte).',
      params: {
        'action': ('string', 'lister, ajouter, fini ou supprimer'),
        'texte': ('string', 'l\'objectif (pour ajouter, fini, supprimer)'),
      },
      run: (a) async {
        final c = Carnet.instance;
        await c.load();
        final action = '${a['action'] ?? 'lister'}';
        final text = '${a['texte'] ?? ''}'.trim();
        CarnetItem? find() => c.list('goals').where((g) => normalize(g.text).contains(normalize(text))).firstOrNull;
        switch (action) {
          case 'ajouter' when text.isNotEmpty:
            await c.add('goals', {'text': text}, max: 100);
          case 'fini':
            final g = find();
            if (g == null) return 'Objectif introuvable';
            await c.change('goals', g.id, {'done': true});
          case 'supprimer':
            final g = find();
            if (g == null) return 'Objectif introuvable';
            await c.remove('goals', g.id);
        }
        return [for (final g in c.list('goals')) {'objectif': g.text, 'atteint': g.done}];
      },
    ),
    HubTool(
      name: 'assistant_briefing',
      description: 'Le briefing du jour (emploi du temps, devoirs, rendez-vous, messages importants, retards, '
          'objectifs, conseils), préparé par Mon Hub.',
      run: (_) => morningBriefing(),
    ),
  ];

  // Mémoire -----------------------------------------------------------------

  /// Un projet, une décision ou un objectif dans ce que la personne dit.
  static (String, String)? detectMemory(String said) {
    final s = said.trim().replaceAll(RegExp(r'\s+'), ' ');
    final n = normalize(s);
    String tail(RegExp re) {
      final m = re.firstMatch(s);
      var t = (m?.group(1) ?? '').trim().replaceFirst(RegExp(r'[.!?]+$'), '');
      if (t.isEmpty) return '';
      return t[0].toUpperCase() + t.substring(1);
    }

    if (RegExp(r'^(?:j ai|on a|nous avons|j ai finalement) decide|^je decide|^c est decide').hasMatch(n)) {
      final t = tail(RegExp(r"(?:décidé|decide|décide|décidé,)\s*(?:de |d'|que |qu')?(.+)$", caseSensitive: false));
      if (t.length > 4) return ('décision', t);
    }
    if (RegExp(r'^(?:mon|notre) (?:projet|nouveau projet)|^je (?:lance|commence|monte|prepare) (?:un|mon) projet').hasMatch(n)) {
      final t = tail(RegExp(r"projet\s*(?:,|:|c.est|est)?\s*(?:de |d'|d’)?(.+)$", caseSensitive: false));
      if (t.length > 4) return ('projet', t);
    }
    if (RegExp(r'^(?:mon (?:objectif|but)|cette annee je veux|je me fixe comme objectif|mon objectif cette)').hasMatch(n)) {
      final t = tail(RegExp(r"(?:objectif|but|je veux)\s*(?:,|:|c.est|est|de|d'|cette année|ce trimestre)?\s*(?:de |d'|que )?(.+)$", caseSensitive: false));
      if (t.length > 4) return ('objectif', t);
    }
    return null;
  }

  /// Retient (si l'automatisme est actif) : renvoie le petit mot à afficher.
  Future<String?> remember(String said) async {
    if (!on('memoire')) return null;
    final found = detectMemory(said);
    if (found == null) return null;
    final (kind, text) = found;
    final c = Carnet.instance;
    await c.load();
    if (kind == 'objectif') {
      if (c.list('goals').any((g) => normalize(g.text) == normalize(text))) return null;
      await c.add('goals', {'text': text}, max: 100);
    } else {
      final label = '${kind == 'projet' ? 'Projet' : 'Décision'} : $text';
      if (c.list('memory').any((m) => normalize(m.text) == normalize(label))) return null;
      await c.add('memory', {'text': label, 'kind': kind}, max: 300);
    }
    return '📌 Retenu : $text';
  }

  // Briefing du matin -------------------------------------------------------

  static final _promo = RegExp(r'no-?reply|newsletter|promo|marketing|notification|offre|soldes|%|unsubscribe|publicit', caseSensitive: false);

  /// Les données du jour, rassemblées (sans IA).
  Future<Map<String, Object?>> collect(DateTime n) async {
    final today = DateTime(n.year, n.month, n.day);
    final day = today.toIso8601String().substring(0, 10);
    final events = _list(await _get('agenda_lire', {'debut': day, 'jours': 2}));
    final hw = _list(await _get('ecole_devoirs'));
    final c = Carnet.instance;
    await c.load();
    final todos = c.list('todos');
    final tasks = rank(hw, todos, n);
    final weather = await _get('carnet_meteo');
    final ed = _list(await _get('ecole_messages'));
    final mails = _list(await _get('mails_lister', {'nombre': 20}));
    final discord = _list(await _get('discord_conversations'));
    final rev = await _get('revision_paquets');
    final free = _list(await _get('agenda_creneaux_libres', {'debut': day, 'jours': 1, 'de': n.weekday >= 6 ? 10 : 16, 'a': 21, 'minimum': 45}));
    bool isToday(Map e) {
      final d = _date(e['debut']);
      return d != null && d.year == today.year && d.month == today.month && d.day == today.day;
    }
    return {
      'date': n,
      'meteo': weather,
      'cours': [for (final e in events) if (isToday(e) && '${e['source']}'.contains('cole')) e],
      'rdv': [
        for (final e in events)
          if (!'${e['source']}'.contains('cole') && e['annule'] != true && (_date(e['debut'])?.isAfter(n.subtract(const Duration(hours: 1))) ?? false)) e,
      ],
      'devoirs': [
        for (final h in hw)
          if (h['fait'] != true)
            if (_date(h['pour_le']) case final d? when d.difference(today).inDays >= 0 && d.difference(today).inDays <= 2) h,
      ],
      'controles': [
        for (final h in hw)
          if (h['controle'] == true)
            if (_date(h['pour_le']) case final d? when d.difference(today).inDays >= 0 && d.difference(today).inDays <= 7) h,
      ],
      'messages_ecole': [for (final m in ed) if (m['lu'] == false) m],
      'mails': [for (final m in mails) if (m['lu'] == false && !_promo.hasMatch('${m['de']} ${m['objet']}')) m],
      'discord_non_lus': discord.where((d) => d['non_lu'] == true).length,
      'en_retard': [for (final t in tasks) if (t.reason.startsWith('en retard') || t.reason.startsWith('attend')) t],
      'taches': tasks,
      'objectifs': [for (final g in c.list('goals')) if (!g.done) g.text],
      'cartes': rev is Map ? rev['a_revoir_aujourdhui'] : null,
      'creneaux': [for (final s in (free.firstOrNull?['libre'] as List?) ?? const []) '$s'],
    };
  }

  /// Les conseils du jour (règles simples, toujours utiles).
  static List<String> advise(Map<String, Object?> d) {
    final now = d['date'] as DateTime;
    final out = <String>[];
    final tests = (d['controles'] as List).cast<Map>();
    if (tests.isNotEmpty) {
      final t = tests.first;
      out.add('Révise ${t['matiere']} un peu chaque jour : contrôle ${_day(_date(t['pour_le'])!, now)}. Ta fiche et tes cartes sont dans Révisions.');
    }
    final tasks = (d['taches'] as List).cast<RankedTask>();
    final slots = (d['creneaux'] as List).cast<String>();
    if (tasks.isNotEmpty) {
      final first = tasks.first;
      out.add(slots.isNotEmpty
          ? 'Ton meilleur créneau : ${slots.first.replaceAll('-', ' – ')}. Commence par « ${first.text} » (${first.reason}).'
          : 'Commence par « ${first.text} » (${first.reason}).');
    }
    final late = (d['en_retard'] as List).cast<RankedTask>();
    if (late.isNotEmpty && (tasks.isEmpty || late.first.text != tasks.first.text)) {
      out.add('Débarrasse-toi de « ${late.first.text} » : ${late.first.reason}.');
    }
    if (overloaded(tasks)) out.add('Tu as beaucoup de choses : concentre-toi sur les 3 premières, le reste peut attendre.');
    final cards = d['cartes'];
    if (cards is num && cards > 0) out.add('$cards carte${cards > 1 ? 's' : ''} à revoir : 10 minutes suffisent.');
    final w = d['meteo'];
    if (w is Map && (w['pluie_pourcent'] as num? ?? 0) >= 60) out.add('Prends un parapluie, il va pleuvoir.');
    final goals = (d['objectifs'] as List).cast<String>();
    if (goals.isNotEmpty) out.add('Pour ton objectif « ${goals[now.day % goals.length]} », fais un petit pas aujourd\'hui.');
    final lessons = (d['cours'] as List).length;
    if (lessons >= 7) out.add('Grosse journée de cours : garde un moment pour souffler ce soir.');
    return out.take(4).toList();
  }

  /// Le briefing en texte (sans IA).
  static String briefingText(Map<String, Object?> d, {String name = ''}) {
    final now = d['date'] as DateTime;
    final b = StringBuffer();
    final hello = now.hour < 18 ? 'Bonjour' : 'Bonsoir';
    b.writeln('☀️ $hello${name.isEmpty ? '' : ' $name'} ! Nous sommes ${frDays[now.weekday - 1]} ${now.day} ${frMonths[now.month - 1]}.');
    final w = d['meteo'];
    if (w is Map) b.writeln('${w['icone'] ?? '🌤️'} ${w['maintenant']}, entre ${w['min']} et ${w['max']} °C. ${w['tenue'] ?? ''}'.trim());
    final lessons = (d['cours'] as List).cast<Map>();
    b.writeln();
    if (lessons.isEmpty) {
      b.writeln('📚 Pas de cours aujourd\'hui.');
    } else {
      final cancelled = [for (final l in lessons) if (l['annule'] == true) l];
      final on = [for (final l in lessons) if (l['annule'] != true) l]..sort((a, c) => _date(a['debut'])!.compareTo(_date(c['debut'])!));
      b.writeln('📚 Emploi du temps : ${[for (final l in on) '${_hour(_date(l['debut'])!)} ${l['titre']}'].join(', ')}'
          '${on.isEmpty ? '' : '. Tu finis à ${_hour(_date(on.last['fin'])!)}'}.');
      for (final c in cancelled) {
        b.writeln('🎉 Annulé : ${c['titre']} à ${_hour(_date(c['debut'])!)}.');
      }
    }
    final hw = (d['devoirs'] as List).cast<Map>();
    final tests = (d['controles'] as List).cast<Map>();
    if (hw.isNotEmpty || tests.isNotEmpty) {
      b.writeln();
      for (final t in tests) {
        b.writeln('📝 Contrôle de ${t['matiere']} ${_day(_date(t['pour_le'])!, now)}.');
      }
      for (final h in hw.where((h) => h['controle'] != true).take(6)) {
        final c = '${h['contenu'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
        b.writeln('✏️ ${h['matiere']} pour ${_day(_date(h['pour_le'])!, now)} : ${c.length > 70 ? '${c.substring(0, 70)}…' : c}');
      }
    }
    final rdv = (d['rdv'] as List).cast<Map>();
    if (rdv.isNotEmpty) {
      b.writeln();
      for (final e in rdv.take(4)) {
        final at = _date(e['debut'])!;
        b.writeln('📅 ${e['titre']} ${_day(at, now)} à ${_hour(at)}${'${e['lieu'] ?? ''}'.isEmpty ? '' : ' (${e['lieu']})'}.');
      }
    }
    final edm = (d['messages_ecole'] as List).cast<Map>();
    final mails = (d['mails'] as List).cast<Map>();
    final dc = d['discord_non_lus'] as int;
    if (edm.isNotEmpty || mails.isNotEmpty || dc > 0) {
      b.writeln();
      for (final m in edm.take(3)) {
        b.writeln('✉️ École Directe — ${m['de']} : « ${m['objet']} »');
      }
      for (final m in mails.take(3)) {
        b.writeln('📧 ${'${m['de']}'.split('<').first.trim()} : « ${m['objet']} »');
      }
      if (dc > 0) {
        b.writeln('💬 Non lus : $dc sur Discord.');
      }
    }
    final late = (d['en_retard'] as List).cast<RankedTask>();
    if (late.isNotEmpty) {
      b.writeln();
      b.writeln('⏰ En retard : ${[for (final t in late.take(3)) '« ${t.text} » (${t.reason})'].join(', ')}.');
    }
    final goals = (d['objectifs'] as List).cast<String>();
    if (goals.isNotEmpty) {
      b.writeln();
      b.writeln('🎯 Tes objectifs : ${goals.take(3).join(' · ')}.');
    }
    final tips = advise(d);
    if (tips.isNotEmpty) {
      b.writeln();
      b.writeln('💡 Mes conseils pour aujourd\'hui :');
      for (final (i, t) in tips.indexed) {
        b.writeln('${i + 1}. $t');
      }
    }
    return b.toString().trim();
  }

  /// Le briefing du matin : les données (sans IA), puis Gemini les rédige
  /// joliment si la clé est là (jamais Claude).
  Future<String> morningBriefing({DateTime? now, String name = ''}) async {
    final n = now ?? DateTime.now();
    final d = await collect(n);
    final text = briefingText(d, name: name);
    if (store.getJson<bool>('briefingAi') == false || !await AiText.hasGemini()) return text;
    try {
      final r = await AiText.ask(
        'Voici mon briefing du matin, préparé par Mon Hub :\n---\n$text\n---\n'
        'Réécris-le de façon naturelle et chaleureuse, comme un assistant personnel (JARVIS), sans rien inventer et '
        'sans rien oublier d\'important : garde les mêmes rubriques avec leurs emojis, des phrases courtes, et termine '
        'par 3 recommandations concrètes et réalistes pour la journée.',
        system: 'Tu es Clicky, l\'assistant personnel d\'un lycéen français. Tu écris en français, simplement.',
        geminiOnly: true,
      );
      return r.trim().isEmpty ? text : r.trim();
    } catch (_) {
      return text;
    }
  }
}
