import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/module_store.dart';

/// Un devoir repéré, et ce que Nexo en a fait.
@immutable
class AutoHomework {
  const AutoHomework({required this.id, required this.subject, required this.at, this.docUrl, this.failed = false});

  /// L'identifiant du devoir (celui d'École Directe).
  final String id;

  /// La matière, telle qu'elle est écrite dans le cahier de texte.
  final String subject;

  /// Quand il l'a fait.
  final DateTime at;

  /// Le Google Doc écrit (null s'il n'a pas réussi).
  final String? docUrl;
  final bool failed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'matiere': subject,
    'quand': at.toIso8601String(),
    if (docUrl != null) 'doc': docUrl,
    if (failed) 'rate': true,
  };

  static AutoHomework? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['quand']}');
    if (at == null) return null;
    return AutoHomework(
      id: '${j['id'] ?? ''}',
      subject: '${j['matiere'] ?? ''}',
      at: at,
      docUrl: j['doc'] == null ? null : '${j['doc']}',
      failed: j['rate'] == true,
    );
  }
}

/// Les règles, **sans réseau ni fichiers** : testables.
class HomeworkRules {
  const HomeworkRules._();

  /// Au plus deux devoirs faits tout seuls par jour (c'est long, et ça
  /// consomme du quota).
  static const perDay = 2;

  /// Absent depuis au moins ce temps-là : il peut se mettre au travail.
  static const awayAfter = Duration(minutes: 10);

  /// La matière d'une notification de devoir (« 📚 Maths : exercices 4 et 5 »).
  static String subjectOf(String title) {
    final t = title.replaceAll(RegExp(r'^[^A-Za-zÀ-ÿ]+'), '').trim();
    final cut = t.split(RegExp(r'\s*[:\-–]\s*')).first.trim();
    return cut.isEmpty ? 'ce devoir' : cut;
  }

  /// Faut-il s'y mettre maintenant ?
  static bool shouldStart({
    required bool allowed,
    required Duration awayFor,
    required int doneToday,
    required bool busy,
    DateTime? now,
  }) {
    if (!allowed || busy) return false;
    if (doneToday >= perDay) return false;
    if (awayFor < awayAfter) return false;
    // Jamais la nuit : il ne travaille pas pendant que la personne dort (et
    // elle ne verrait le travail qu'au matin de toute façon).
    final h = (now ?? DateTime.now()).hour;
    return h >= 7 && h < 23;
  }

  /// Ce qu'il dit au retour de la personne.
  static String welcome(List<AutoHomework> done) {
    if (done.isEmpty) return '';
    final ok = [
          for (final d in done)
            if (!d.failed) d,
        ],
        ko = [
          for (final d in done)
            if (d.failed) d,
        ];
    final parts = <String>[];
    if (ok.length == 1) {
      parts.add('Pendant que tu n\'étais pas là, j\'ai fait ton devoir de ${ok.first.subject}.');
    } else if (ok.length > 1) {
      parts.add(
        'Pendant que tu n\'étais pas là, j\'ai fait tes devoirs de ${[for (final d in ok) d.subject].join(' et ')}.',
      );
    }
    if (ok.isNotEmpty) parts.add('Le travail est dans un Google Doc, avec « Comment j\'ai fait » à chaque exercice.');
    if (ko.isNotEmpty) {
      parts.add(
        'Je n\'ai pas réussi ${ko.length == 1 ? 'celui de ${ko.first.subject}' : 'ceux de ${[for (final d in ko) d.subject].join(' et ')}'} : il me manquait l\'énoncé.',
      );
    }
    return parts.join(' ');
  }
}

/// **Il fait tes devoirs pendant ton absence** (si tu l'y autorises).
///
/// Demandé par Erik : « il voit que j'ai un devoir, hop, il fait mon
/// devoir ». Le travail part en arrière-plan seulement si la personne a
/// donné son accord une fois, qu'elle est absente depuis dix minutes, qu'il
/// ne fait pas déjà autre chose, et au plus deux fois par jour. Au retour,
/// il dit ce qu'il a fait — et il dit aussi quand il n'a pas réussi.
class HomeworkAuto extends ChangeNotifier {
  HomeworkAuto._();
  static final instance = HomeworkAuto._();

  static const _kOn = 'app.devoirs.auto', _kDone = 'app.devoirs.faits';

  /// L'autorisation (non par défaut : c'est à la personne de la donner).
  bool get allowed {
    try {
      return ModuleStore.global.getBool(_kOn) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setAllowed(bool v) async {
    try {
      await ModuleStore.global.setBool(_kOn, v);
    } catch (_) {}
    notifyListeners();
  }

  /// Ce qu'il a fait tout seul (les 7 derniers jours).
  List<AutoHomework> get done {
    try {
      final raw = ModuleStore.global.getStringList(_kDone) ?? const <String>[];
      final limit = DateTime.now().subtract(const Duration(days: 7));
      return [
        for (final s in raw)
          if (AutoHomework.fromJson(jsonDecode(s)) case final h?)
            if (h.at.isAfter(limit)) h,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Ceux d'aujourd'hui.
  int doneToday({DateTime? now}) {
    final t = now ?? DateTime.now();
    return done.where((h) => h.at.year == t.year && h.at.month == t.month && h.at.day == t.day).length;
  }

  /// Déjà fait (ou déjà tenté) : on n'y revient pas.
  bool already(String id) => done.any((h) => h.id == id);

  Future<void> record(AutoHomework h) async {
    try {
      final raw = ModuleStore.global.getStringList(_kDone) ?? const <String>[];
      await ModuleStore.global.setStringList(_kDone, [jsonEncode(h.toJson()), ...raw].take(40).toList());
    } catch (_) {}
    notifyListeners();
  }

  /// Ce qu'il n'a pas encore raconté à la personne.
  final _toTell = <AutoHomework>[];

  void willTell(AutoHomework h) => _toTell.add(h);

  /// Au retour : la phrase à dire, puis la liste est vidée.
  String takeWelcome() {
    final say = HomeworkRules.welcome(_toTell);
    _toTell.clear();
    return say;
  }
}
