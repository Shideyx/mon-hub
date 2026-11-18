import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Une info qui relie plusieurs modules (« contrôle jeudi → ta fiche est
/// prête dans Révisions », « reprends 1984 à 32 % »…).
class FeedItem {
  const FeedItem({
    required this.id,
    required this.moduleId,
    required this.icon,
    required this.title,
    this.detail = '',
    this.action = 'Ouvrir',
    this.from = const [],
    this.priority = 0,
  });

  /// Clé stable (pour ne pas répéter la même chose).
  final String id;

  /// Le module qui s'ouvre quand on touche l'info.
  final String moduleId;
  final IconData icon;
  final String title;
  final String detail;
  final String action;

  /// Les modules d'où vient l'info (affichés en petit : « Agenda + Révisions »).
  final List<String> from;

  /// Plus c'est haut, plus c'est important (le premier est dit par Clicky).
  final int priority;
}

/// « Ton fil » : ce qui compte maintenant, rassemblé depuis tous les modules
/// **sans IA** (avec les actions de lecture des modules), pour que Mon Hub
/// ressemble à une seule appli et pas à des modules posés côte à côte.
///
/// Rien ne part sur internet de plus que d'habitude : on ne lit que l'agenda,
/// les devoirs (déjà relevés par les notifications), les révisions, la
/// bibliothèque, le carnet et les pastilles des modules.
class HubFeed extends ChangeNotifier {
  HubFeed._();
  static final instance = HubFeed._();

  List<FeedItem> items = const [];
  DateTime? updatedAt;
  bool _busy = false;

  /// L'info la plus importante (Clicky peut la dire).
  FeedItem? get top => items.firstOrNull;

  /// Relit les modules (au plus une fois toutes les 3 minutes, sauf [force]).
  Future<void> refresh({
    required Future<Object?> Function(String tool, Map<String, dynamic> args) call,
    required Set<String> tools,
    required Map<String, int> badges,
    required Map<String, String> names,
    DateTime? now,
    bool force = false,
  }) async {
    final n = now ?? DateTime.now();
    final at = updatedAt;
    if (_busy || (!force && at != null && n.difference(at) < const Duration(minutes: 3))) return;
    _busy = true;
    try {
      Future<Object?> get(String t, [Map<String, dynamic> a = const {}]) async {
        if (!tools.contains(t)) return null;
        try {
          return await call(t, a).timeout(const Duration(seconds: 12));
        } catch (_) {
          return null;
        }
      }

      final day = DateTime(n.year, n.month, n.day).toIso8601String().substring(0, 10);
      final results = await Future.wait([
        get('agenda_lire', {'debut': day, 'jours': 2}),
        get('ecole_devoirs'),
        get('revision_paquets'),
        get('livres_lister'),
      ]);
      items = build(
        events: _maps(results[0]),
        homework: _maps(results[1]),
        revisions: results[2] is Map ? results[2] as Map : const {},
        books: _maps(results[3]),
        badges: badges,
        names: names,
        now: n,
      );
      updatedAt = n;
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  static List<Map> _maps(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is Map) x,
  ];

  static DateTime? _date(Object? v) => v is DateTime ? v : DateTime.tryParse('${v ?? ''}');

  static String _hour(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static String _when(DateTime d, DateTime now) {
    final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    const names = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
    return switch (days) {
      0 => 'aujourd\'hui',
      1 => 'demain',
      _ => days < 7 ? names[d.weekday - 1] : 'le ${d.day}/${d.month}',
    };
  }

  /// Fabrique le fil à partir des données des modules (sans réseau, testable).
  static List<FeedItem> build({
    List<Map> events = const [],
    List<Map> homework = const [],
    Map revisions = const {},
    List<Map> books = const [],
    Map<String, int> badges = const {},
    Map<String, String> names = const {},
    required DateTime now,
  }) {
    final out = <FeedItem>[];
    final today = DateTime(now.year, now.month, now.day);

    // 1. Le prochain cours / rendez-vous (Agenda).
    final next = [
      for (final e in events)
        if (e['annule'] != true)
          if (_date(e['debut']) case final d? when d.isAfter(now)) (e, d),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (next.isNotEmpty) {
      final (e, d) = next.first;
      final soon = d.difference(now).inMinutes;
      out.add(
        FeedItem(
          id: 'next:${e['titre']}:${d.toIso8601String()}',
          moduleId: 'schedule',
          icon: Icons.schedule_rounded,
          title: soon <= 60 ? '${e['titre']} dans $soon min' : '${e['titre']} ${_when(d, now)} à ${_hour(d)}',
          detail: [if ('${e['lieu'] ?? ''}'.isNotEmpty) '${e['lieu']}', '${e['source'] ?? ''}'].where((x) => x.isNotEmpty).join(' · '),
          action: 'Agenda',
          from: const ['schedule'],
          priority: soon <= 30 ? 90 : 40,
        ),
      );
    }

    // 2. Un contrôle qui arrive : relié aux Révisions (fiche + cartes prêtes).
    final tests = [
      for (final h in homework)
        if (h['controle'] == true)
          if (_date(h['pour_le']) case final d? when !d.isBefore(today) && d.difference(today).inDays <= 7) (h, d),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final decks = [
      for (final p in (revisions['paquets'] as List?) ?? const [])
        if (p is Map) p,
    ];
    if (tests.isNotEmpty) {
      final (h, d) = tests.first;
      final subject = '${h['matiere'] ?? ''}'.trim();
      final deck = decks.where((p) => subject.isNotEmpty && '${p['nom']}'.toLowerCase().contains(subject.toLowerCase())).firstOrNull;
      out.add(
        FeedItem(
          id: 'test:$subject:${d.toIso8601String()}',
          moduleId: 'revisions',
          icon: Icons.quiz_rounded,
          title: 'Contrôle de ${subject.isEmpty ? 'cours' : subject} ${_when(d, now)}',
          detail: deck == null
              ? 'Prépare ta fiche et tes cartes dans Révisions'
              : 'Ta fiche est prête · ${deck['maitrise_pourcent'] ?? 0} % maîtrisé',
          action: 'Réviser',
          from: const ['ecoledirecte', 'revisions'],
          priority: d.difference(today).inDays <= 1 ? 85 : 60,
        ),
      );
    }

    // 3. Les devoirs pour demain (École Directe → Carnet).
    final due = [
      for (final h in homework)
        if (h['fait'] != true && h['controle'] != true)
          if (_date(h['pour_le']) case final d? when d.difference(today).inDays == 1) h,
    ];
    if (due.isNotEmpty) {
      final subjects = {for (final h in due) '${h['matiere'] ?? ''}'.trim()}..remove('');
      out.add(
        FeedItem(
          id: 'hw:${today.toIso8601String()}:${due.length}',
          moduleId: 'ecoledirecte',
          icon: Icons.assignment_rounded,
          title: '${due.length} devoir${due.length > 1 ? 's' : ''} pour demain',
          detail: subjects.take(3).join(', '),
          action: 'Voir',
          from: const ['ecoledirecte', 'schedule'],
          priority: now.hour >= 16 ? 75 : 50,
        ),
      );
    }

    // 4. Les cartes à revoir (Révisions), avec la série.
    final cards = (revisions['a_revoir_aujourdhui'] as num?)?.toInt() ?? 0;
    final streak = (revisions['serie_jours'] as num?)?.toInt() ?? 0;
    if (cards > 0) {
      out.add(
        FeedItem(
          id: 'cards:${today.toIso8601String()}',
          moduleId: 'revisions',
          icon: Icons.style_rounded,
          title: '$cards carte${cards > 1 ? 's' : ''} à revoir',
          detail: streak > 1 ? 'Série de $streak jours : ne la casse pas' : '10 minutes suffisent',
          action: 'Réviser',
          from: const ['revisions'],
          priority: streak > 2 ? 55 : 35,
        ),
      );
    }

    // 5. Une lecture en cours (Bibliothèque).
    final reading = books.where((b) => '${b['statut'] ?? ''}'.toLowerCase().contains('cours')).firstOrNull;
    if (reading != null) {
      final p = '${reading['progression'] ?? ''}';
      out.add(
        FeedItem(
          id: 'book:${reading['titre']}',
          moduleId: 'books',
          icon: Icons.auto_stories_rounded,
          title: 'Reprends « ${reading['titre']} »',
          detail: [if (p.isNotEmpty) p, '${reading['auteur'] ?? ''}'].where((x) => x.isNotEmpty).join(' · '),
          action: 'Lire',
          from: const ['books'],
          priority: now.hour >= 20 ? 45 : 20,
        ),
      );
    }

    // 6. Les messages non lus (pastilles des modules, sans requête en plus).
    final unread = {
      for (final e in badges.entries)
        if (e.value > 0 && const {'discord', 'mail', 'instagram', 'ecoledirecte'}.contains(e.key)) e.key: e.value,
    };
    if (unread.isNotEmpty) {
      final total = unread.values.fold(0, (a, b) => a + b);
      final best = (unread.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
      out.add(
        FeedItem(
          id: 'unread:$total',
          moduleId: best,
          icon: Icons.mark_chat_unread_rounded,
          title: '$total message${total > 1 ? 's' : ''} non lu${total > 1 ? 's' : ''}',
          detail: [for (final e in unread.entries) '${e.value} ${names[e.key] ?? e.key}'].join(' · '),
          action: 'Lire',
          from: unread.keys.toList(),
          priority: 45,
        ),
      );
    }

    out.sort((a, b) => b.priority.compareTo(a.priority));
    return out;
  }

  /// Ce que Clicky peut dire de l'info la plus importante (sans IA).
  static String? say(FeedItem? i) {
    if (i == null || i.priority < 50) return null;
    return switch (i.moduleId) {
      'revisions' => '${i.title}. ${i.detail}.',
      'schedule' => 'Petit rappel : ${i.title}.',
      'ecoledirecte' => '${i.title} : ${i.detail}.',
      _ => '${i.title}.',
    };
  }

  /// Remis à zéro (tests).
  @visibleForTesting
  void reset() {
    items = const [];
    updatedAt = null;
  }
}

/// Petite minuterie partagée : le fil se relit tout seul toutes les
/// 5 minutes tant qu'il est affiché.
class HubFeedTicker {
  HubFeedTicker(this.onTick) {
    _t = Timer.periodic(const Duration(minutes: 5), (_) => onTick());
  }
  final VoidCallback onTick;
  late final Timer _t;
  void dispose() => _t.cancel();
}
