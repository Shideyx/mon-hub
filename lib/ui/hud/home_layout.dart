import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/module_store.dart';

/// Un bloc de l'accueil : un module (« mod:musique ») ou un bloc spécial
/// (« fil », « espaces », « taches », « applis », « discussions »), et sa
/// largeur (1 colonne, 2 colonnes, toute la largeur).
@immutable
class HomeBlock {
  const HomeBlock(this.id, [this.span = 1]);
  final String id;

  /// 1, 2 ou 3 (= toute la largeur).
  final int span;

  bool get isModule => id.startsWith('mod:');
  String? get moduleId => isModule ? id.substring(4) : null;

  HomeBlock withSpan(int s) => HomeBlock(id, s.clamp(1, 3));

  Map<String, Object> toJson() => {'id': id, 'l': span};

  static HomeBlock? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}';
    if (id.isEmpty) return null;
    return HomeBlock(id, ((j['l'] as num?)?.toInt() ?? 1).clamp(1, 3));
  }

  @override
  bool operator ==(Object other) => other is HomeBlock && other.id == id && other.span == span;

  @override
  int get hashCode => Object.hash(id, span);
}

/// **L'accueil à ta façon** : quels blocs, dans quel ordre, quelle taille.
/// Gardé avec le compte (synchronisé sur tous tes appareils).
class HomeLayout extends ChangeNotifier {
  HomeLayout._();
  static final instance = HomeLayout._();

  static const _key = 'hub.accueil.blocs';
  static const _seenKey = 'hub.accueil.vus';

  /// Blocs spéciaux (hors modules), avec leur nom.
  static const specials = {
    'fil': 'Ton fil (ce qui compte maintenant)',
    'espaces': 'Mes espaces partagés',
    'taches': 'Mes tâches (tous les espaces)',
    'discussions': 'Discussions',
    'applis': 'Mes applis du PC',
  };

  /// Mode « Personnaliser » de l'accueil.
  bool editing = false;

  void setEditing(bool on) {
    if (editing == on) return;
    editing = on;
    notifyListeners();
  }

  /// La disposition à afficher, à partir de ce qui est gardé ([saved], null :
  /// jamais personnalisé), des modules déjà vus ([seen]) et des modules
  /// actifs. Un module activé depuis arrive à la fin ; un bloc retiré ne
  /// revient pas tout seul.
  static (List<HomeBlock>, Set<String>) resolve({
    required List<HomeBlock>? saved,
    required Set<String> seen,
    required List<String> modules,
    required Set<String> specialsHere,
  }) {
    bool here(String id) => id.startsWith('mod:') ? modules.contains(id.substring(4)) : specialsHere.contains(id);
    final List<HomeBlock> out;
    if (saved == null) {
      out = [
        if (specialsHere.contains('fil')) const HomeBlock('fil', 3),
        for (final m in modules) HomeBlock('mod:$m'),
        for (final s in const ['taches', 'espaces', 'applis'])
          if (specialsHere.contains(s)) HomeBlock(s),
      ];
    } else {
      final ids = <String>{};
      out = [
        for (final b in saved)
          if (here(b.id) && ids.add(b.id)) b,
      ];
      for (final m in modules) {
        final id = 'mod:$m';
        if (!seen.contains(id) && !ids.contains(id)) out.add(HomeBlock(id));
      }
    }
    return (out, {...seen, for (final m in modules) 'mod:$m', ...specialsHere});
  }

  List<HomeBlock>? get _saved {
    try {
      final raw = ModuleStore.prefs.getString(_key);
      if (raw == null) return null;
      return [
        for (final j in jsonDecode(raw) as List) ?HomeBlock.fromJson(j),
      ];
    } catch (_) {
      return null;
    }
  }

  Set<String> get _seen => (ModuleStore.prefs.getStringList(_seenKey) ?? const []).toSet();

  /// Les blocs à afficher maintenant.
  List<HomeBlock> blocks({required List<String> modules, required Set<String> specialsHere}) {
    final saved = _saved;
    final seen = _seen;
    final (out, nowSeen) = resolve(saved: saved, seen: seen, modules: modules, specialsHere: specialsHere);
    if (saved != null && (nowSeen.length != seen.length || out.length != saved.length)) {
      // Nouveau module : on le garde (sans prévenir pendant la construction).
      ModuleStore.prefs.setString(_key, jsonEncode([for (final b in out) b.toJson()]));
    }
    if (nowSeen.length != seen.length) ModuleStore.prefs.setStringList(_seenKey, nowSeen.toList());
    return out;
  }

  Future<void> save(List<HomeBlock> blocks) async {
    await ModuleStore.prefs.setString(_key, jsonEncode([for (final b in blocks) b.toJson()]));
    notifyListeners();
  }

  /// Largeur réelle d'un bloc dans [cols] colonnes (le fil : toute la
  /// largeur).
  static int spanIn(HomeBlock b, int cols) => b.id == 'fil' || b.span >= 3 ? cols : b.span.clamp(1, cols);

  /// Les blocs rangés en rangées de [cols] colonnes (le fil est toujours seul
  /// sur sa rangée).
  static List<List<HomeBlock>> rows(List<HomeBlock> blocks, int cols) {
    final out = <List<HomeBlock>>[];
    var row = <HomeBlock>[];
    var used = 0;
    for (final b in blocks) {
      final span = spanIn(b, cols);
      if (row.isNotEmpty && (used + span > cols || b.id == 'fil' || row.first.id == 'fil')) {
        out.add(row);
        row = [];
        used = 0;
      }
      row.add(b);
      used += span;
    }
    if (row.isNotEmpty) out.add(row);
    return out;
  }

  /// [dragged] se place juste avant [target] (ou à la fin si null).
  static List<HomeBlock> moved(List<HomeBlock> l, String dragged, String? target) {
    final b = l.where((x) => x.id == dragged).firstOrNull;
    if (b == null || dragged == target) return l;
    final out = [...l]..remove(b);
    final i = target == null ? -1 : out.indexWhere((x) => x.id == target);
    i < 0 ? out.add(b) : out.insert(i, b);
    return out;
  }

  Future<void> move(List<HomeBlock> current, String dragged, String? target) => save(moved(current, dragged, target));

  Future<void> resize(List<HomeBlock> current, String id, int span) =>
      save([for (final b in current) b.id == id ? b.withSpan(span) : b]);

  Future<void> remove(List<HomeBlock> current, String id) => save([for (final b in current) if (b.id != id) b]);

  Future<void> add(List<HomeBlock> current, String id, {int span = 1}) =>
      save([...current.where((b) => b.id != id), HomeBlock(id, span)]);

  /// Revenir à l'accueil d'origine.
  Future<void> reset() async {
    await ModuleStore.prefs.remove(_key);
    notifyListeners();
  }
}
