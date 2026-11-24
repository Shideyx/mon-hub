import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'module_store.dart';
import 'powershell.dart';
import 'safe_open.dart';

/// Une appli installée sur le PC (celles du menu Démarrer).
class PcApp {
  const PcApp(this.name, this.id);
  final String name;

  /// L'identifiant Windows (« AppID ») : sert à la lancer.
  final String id;

  /// Deux lettres pour son icône.
  String get initials {
    final words = name
        .replaceAll(RegExp(r'[^A-Za-zÀ-ÿ0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, words.first.length.clamp(1, 2)).toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  Map<String, String> toJson() => {'n': name, 'i': id};
}

/// **Toutes les applis du PC dans Mon Hub** (plus besoin de la touche
/// Windows) : la liste du menu Démarrer (`Get-StartApps` : programmes et
/// applis du Store), lancées comme un clic dans le menu Démarrer.
///
/// Rien ne quitte le PC. La liste est gardée pour s'afficher tout de suite au
/// prochain démarrage, puis relue en fond.
class PcApps extends ChangeNotifier {
  PcApps._();
  static final instance = PcApps._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Liste gardée sur ce PC (tous les comptes).
  static const _cacheKey = 'app.pcapps.liste';

  /// Épinglées et utilisées : propres à ce PC (préfixe « app. » : jamais
  /// synchronisé, l'autre PC n'a pas les mêmes applis).
  static const _pinKey = 'app.applis.epinglees';
  static const _useKey = 'app.applis.usage';

  List<PcApp> apps = const [];
  bool loading = false;
  String? error;
  DateTime? _loadedAt;

  static const _script = r'''
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress
''';

  /// La sortie de `Get-StartApps | ConvertTo-Json` → les applis utiles,
  /// triées par nom, sans doublons.
  static List<PcApp> parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    Object? j;
    try {
      j = jsonDecode(t);
    } catch (_) {
      return const [];
    }
    final rows = j is List ? j : (j is Map ? [j] : const []);
    final seen = <String>{};
    final out = <PcApp>[];
    for (final r in rows) {
      if (r is! Map) continue;
      final name = '${r['Name'] ?? ''}'.trim();
      final id = '${r['AppID'] ?? ''}'.trim();
      final a = PcApp(name, id);
      if (name.isEmpty || id.isEmpty || junk(a) || !seen.add(name.toLowerCase())) continue;
      out.add(a);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  static final _junk = RegExp(
    r'(uninstall|d[ée]sinstall|readme|lisez-moi|release notes|notes de version|license|licence|documentation'
    r'|help$|^aide$|manuel|website|site web|support center)',
    caseSensitive: false,
  );

  /// Entrées du menu Démarrer qui ne sont pas des applis (désinstalleurs,
  /// fichiers d'aide, liens web…).
  static bool junk(PcApp a) {
    final id = a.id.toLowerCase();
    if (id.startsWith('http:') || id.startsWith('https:')) return true;
    if (RegExp(r'\.(txt|pdf|htm|html|chm|url|rtf)$').hasMatch(id)) return true;
    return _junk.hasMatch(a.name);
  }

  /// Affiche tout de suite la liste gardée, puis la relit (au plus toutes
  /// les 10 minutes, sauf [force]).
  Future<void> load({bool force = false}) async {
    if (!supported) return;
    if (apps.isEmpty) {
      try {
        final raw = ModuleStore.global.getString(_cacheKey);
        if (raw != null) {
          apps = [
            for (final e in jsonDecode(raw) as List)
              if (e is Map) PcApp('${e['n']}', '${e['i']}'),
          ];
          notifyListeners();
        }
      } catch (_) {}
    }
    final at = _loadedAt;
    if (loading || (!force && at != null && DateTime.now().difference(at) < const Duration(minutes: 10))) return;
    loading = true;
    notifyListeners();
    try {
      final r = await PowerShell.run(_script, const {}, const Duration(seconds: 40));
      final list = parse('${r.stdout}');
      if (list.isNotEmpty) {
        apps = list;
        _loadedAt = DateTime.now();
        error = null;
        await ModuleStore.global.setString(_cacheKey, jsonEncode([for (final a in list) a.toJson()]));
      } else if (apps.isEmpty) {
        error = PowerShell.firstError('${r.stderr}');
      }
    } catch (e) {
      if (apps.isEmpty) error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Lance l'appli (comme un clic dans le menu Démarrer).
  Future<bool> launch(PcApp a) async {
    var ok = await SafeOpen.launch('shell:AppsFolder\\${a.id}');
    // Quelques entrées donnent le chemin du programme lui-même.
    if (!ok && RegExp(r'^[A-Za-z]:\\').hasMatch(a.id)) ok = await SafeOpen.launch(a.id);
    if (ok) {
      final u = usage;
      u[a.id] = (u[a.id] ?? 0) + 1;
      await ModuleStore.prefs.setString(_useKey, jsonEncode(u));
      notifyListeners();
    }
    return ok;
  }

  Map<String, int> get usage {
    try {
      final raw = ModuleStore.prefs.getString(_useKey);
      if (raw == null) return {};
      return {for (final e in (jsonDecode(raw) as Map).entries) '${e.key}': (e.value as num).toInt()};
    } catch (_) {
      return {};
    }
  }

  List<String> get pinnedIds => ModuleStore.prefs.getStringList(_pinKey) ?? const [];
  bool isPinned(PcApp a) => pinnedIds.contains(a.id);

  List<PcApp> get pinned => [
    for (final id in pinnedIds)
      if (apps.any((a) => a.id == id)) apps.firstWhere((a) => a.id == id),
  ];

  Future<void> togglePin(PcApp a) async {
    final l = [...pinnedIds];
    l.contains(a.id) ? l.remove(a.id) : l.add(a.id);
    await ModuleStore.prefs.setStringList(_pinKey, l);
    notifyListeners();
  }

  /// Les plus utilisées (pour l'accueil).
  List<PcApp> frequent({int max = 8}) {
    final u = usage;
    final l = [
      for (final a in apps)
        if ((u[a.id] ?? 0) > 0) a,
    ]..sort((a, b) => (u[b.id] ?? 0).compareTo(u[a.id] ?? 0));
    return l.take(max).toList();
  }

  /// Les applis qui correspondent à [query] : début du nom d'abord, puis
  /// début d'un mot, puis n'importe où ; à égalité, les plus utilisées.
  static List<PcApp> match(List<PcApp> apps, String query, {Map<String, int> usage = const {}, int max = 50}) {
    final q = _plain(query.trim());
    if (q.isEmpty) return apps.take(max).toList();
    final scored = <(PcApp, int)>[];
    for (final a in apps) {
      final n = _plain(a.name);
      int s;
      if (n.startsWith(q)) {
        s = 3;
      } else if (n.split(RegExp(r'[\s._-]+')).any((w) => w.startsWith(q))) {
        s = 2;
      } else if (n.contains(q) || _initials(n).startsWith(q)) {
        s = 1;
      } else {
        continue;
      }
      scored.add((a, s * 100000 + (usage[a.id] ?? 0).clamp(0, 99999)));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    return [for (final e in scored.take(max)) e.$1];
  }

  List<PcApp> search(String query, {int max = 50}) => match(apps, query, usage: usage, max: max);

  static String _initials(String n) => n.split(RegExp(r'[\s._-]+')).where((w) => w.isNotEmpty).map((w) => w[0]).join();

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyy';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }
}
