import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/module_store.dart';
import 'tutor.dart' show normalize;

/// Ce que la personne a répondu à une proposition.
enum Answer {
  /// Elle n'a pas répondu à la proposition (c'est autre chose).
  none,

  /// « oui », « vas-y », « d'accord ».
  yes,

  /// « plus tard », « après », « pas maintenant ».
  later,

  /// « non », « j'ai pas envie », « laisse tomber ».
  no,

  /// « arrête », « jamais », « ne me le redis plus ».
  never,
}

/// Les règles, **sans fichiers** : testables.
///
/// Le principe : plus la personne refuse un sujet, plus Smily se taît
/// longtemps dessus. Au troisième refus, il laisse tomber le sujet (il n'en
/// reparle que si on lui demande).
class PatienceRules {
  const PatienceRules._();

  /// Ce que veut dire ce que la personne a dit.
  static Answer read(String raw) {
    final n = normalize(raw).trim().replaceAll(RegExp(r'[!.…]+$'), '');
    if (n.isEmpty) return Answer.none;
    if (RegExp(
      r'^(?:arrete|arretes|stop|ca suffit|lache moi|laisse moi tranquille|ne me le (?:redis|repete) plus|'
      r'arrete de (?:me )?(?:le )?(?:repeter|me saouler|insister)|jamais|plus jamais|je (?:ne )?veux plus (?:en )?entendre parler)',
    ).hasMatch(n)) {
      return Answer.never;
    }
    if (RegExp(r'^(?:plus tard|apres|tantot|pas maintenant|tout a l heure|ce soir|demain|attends|pas tout de suite)')
        .hasMatch(n)) {
      return Answer.later;
    }
    if (RegExp(
      r'^(?:non|nan|no|nope|j ai pas envie|pas envie|laisse tomber|oublie|pas (?:la|le) peine|ca (?:ne )?m interesse pas|'
      r'je (?:ne )?veux pas|flemme|pas maintenant non)',
    ).hasMatch(n)) {
      return Answer.no;
    }
    if (RegExp(r'^(?:oui|ouais|ok|okay|d accord|vas y|va y|allez|yes|si|avec plaisir|fais le|carrement)').hasMatch(n)) {
      return Answer.yes;
    }
    return Answer.none;
  }

  /// Combien de temps il se taît sur ce sujet après [refusals] refus.
  ///
  /// null = plus jamais de lui-même.
  static Duration? silence(int refusals, {Answer last = Answer.no}) {
    if (last == Answer.never) return null;
    if (last == Answer.later) return const Duration(hours: 2);
    return switch (refusals) {
      <= 1 => const Duration(hours: 6),
      2 => const Duration(days: 2),
      _ => null,
    };
  }

  /// Peut-il parler de [subject] maintenant ?
  static bool mayTalk({required DateTime now, DateTime? mutedUntil, bool dropped = false}) {
    if (dropped) return false;
    return mutedUntil == null || now.isAfter(mutedUntil);
  }

  /// Ce qu'il répond quand il abandonne un sujet (sans IA, et sans vexer).
  static String ack(Answer a, {String subject = ''}) {
    final what = subject.isEmpty ? '' : ' de $subject';
    return switch (a) {
      Answer.never => 'C\'est noté : je ne te reparle plus$what de moi-même. Si tu en as besoin, demande-moi.',
      Answer.no => 'Ok, j\'arrête d\'insister$what.',
      Answer.later => 'D\'accord, je te le remets plus tard.',
      Answer.yes => 'Ok, je m\'en occupe.',
      Answer.none => '',
    };
  }
}

/// **Smily n'insiste pas** : il retient tes refus, sujet par sujet.
///
/// Avant, chaque système (l'assistant, les rappels, les guetteurs, les
/// initiatives) relançait dans son coin sans savoir que la personne avait
/// déjà dit non. Maintenant tout passe par ici : un seul endroit qui sait ce
/// qu'elle a refusé, et pour combien de temps.
class Patience extends ChangeNotifier {
  Patience._();
  static final instance = Patience._();

  static const _key = 'app.patience';

  Map<String, dynamic> _data = const {};
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = ModuleStore.global.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) _data = j.cast<String, dynamic>();
      }
    } catch (_) {
      _data = const {};
    }
  }

  Future<void> _save() async {
    try {
      await ModuleStore.global.setString(_key, jsonEncode(_data));
    } catch (_) {}
  }

  Map<String, dynamic> _of(String subject) {
    _load();
    final v = _data[subject];
    return v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// Nombre de refus sur ce sujet.
  int refusals(String subject) => (_of(subject)['refus'] as num?)?.toInt() ?? 0;

  /// Sujet laissé tomber (il n'en reparle que si on le lui demande).
  bool dropped(String subject) => _of(subject)['abandonne'] == true;

  /// Jusqu'à quand il se taît sur ce sujet.
  DateTime? mutedUntil(String subject) {
    final v = _of(subject)['jusqu'];
    return v == null ? null : DateTime.tryParse('$v');
  }

  /// Peut-il parler de [subject] de lui-même ?
  bool mayTalk(String subject, {DateTime? now}) =>
      PatienceRules.mayTalk(now: now ?? DateTime.now(), mutedUntil: mutedUntil(subject), dropped: dropped(subject));

  /// La personne a refusé (ou accepté) quelque chose sur ce sujet.
  Future<void> answered(String subject, Answer a, {DateTime? now}) async {
    if (subject.isEmpty || a == Answer.none) return;
    _load();
    final t = now ?? DateTime.now();
    if (a == Answer.yes) {
      // Elle a dit oui : on repart de zéro sur ce sujet.
      _data = {..._data}..remove(subject);
      await _save();
      notifyListeners();
      return;
    }
    final count = a == Answer.later ? refusals(subject) : refusals(subject) + 1;
    final hold = PatienceRules.silence(count, last: a);
    _data = {
      ..._data,
      subject: {
        'refus': count,
        'abandonne': hold == null,
        if (hold != null) 'jusqu': t.add(hold).toIso8601String(),
        'dernier': t.toIso8601String(),
      },
    };
    await _save();
    notifyListeners();
  }

  /// La personne redemande ce sujet elle-même : on oublie les refus.
  Future<void> wanted(String subject) => answered(subject, Answer.yes);

  /// Tous les sujets laissés tomber (pour la page des réglages).
  List<String> get droppedSubjects {
    _load();
    return [
      for (final e in _data.entries)
        if (e.value is Map && (e.value as Map)['abandonne'] == true) e.key,
    ];
  }

  /// Remet tout à zéro (« tu peux me reparler de tout »).
  Future<void> reset() async {
    _data = const {};
    _loaded = true;
    await _save();
    notifyListeners();
  }

  @visibleForTesting
  void setForTest(Map<String, dynamic> data) {
    _data = data;
    _loaded = true;
  }
}
