import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import '../../core/hub_feed.dart';
import '../../core/hub_files.dart';

/// Les fonctions « façon JARVIS » de Nexo, **sans IA** : l'état du PC, le
/// mode concentration, les rappels « quand j'ouvre telle appli », et le
/// point de situation donné à l'IA pour qu'elle réponde juste du premier
/// coup.

// ===================================================================== PC

/// L'état du PC : batterie, mémoire, disque, processeur, internet.
class SystemStatus {
  const SystemStatus({
    this.battery,
    this.charging = false,
    this.saver = false,
    this.memLoad = 0,
    this.memTotalGb = 0,
    this.memFreeGb = 0,
    this.diskFreeGb = 0,
    this.diskTotalGb = 0,
    this.cpu,
    this.online,
    this.hubMb = 0,
    this.topApps = const [],
  });

  /// Batterie en % (null : PC fixe, pas de batterie).
  final int? battery;
  final bool charging;

  /// L'économiseur de batterie est allumé.
  final bool saver;

  /// Mémoire utilisée (%).
  final int memLoad;
  final double memTotalGb;
  final double memFreeGb;

  /// Disque C:.
  final double diskFreeGb;
  final double diskTotalGb;

  /// Processeur occupé (%).
  final int? cpu;
  final bool? online;

  /// Mémoire utilisée par Mon Hub.
  final int hubMb;

  /// Les applis qui prennent le plus de mémoire (nom, Mo).
  final List<(String, int)> topApps;

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Lit l'état du PC ([apps] : aussi les applis les plus gourmandes).
  static Future<SystemStatus> read({bool apps = false}) async {
    int? battery;
    var charging = false, saver = false;
    var memLoad = 0;
    double memTotal = 0, memFree = 0, diskFree = 0, diskTotal = 0;
    int? cpu;
    if (supported) {
      try {
        using((a) {
          final p = a<SYSTEM_POWER_STATUS>();
          if (GetSystemPowerStatus(p).value) {
            final s = p.ref;
            // 128 = pas de batterie, 255 = inconnu.
            if ((s.BatteryFlag & 128) == 0 && s.BatteryLifePercent <= 100) battery = s.BatteryLifePercent;
            charging = s.ACLineStatus == 1;
            saver = s.SystemStatusFlag == 1;
          }
          final m = a<MEMORYSTATUSEX>();
          m.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
          if (GlobalMemoryStatusEx(m).value) {
            memLoad = m.ref.dwMemoryLoad;
            memTotal = m.ref.ullTotalPhys / (1 << 30);
            memFree = m.ref.ullAvailPhys / (1 << 30);
          }
          final free = a<Uint64>(), total = a<Uint64>(), all = a<Uint64>();
          if (GetDiskFreeSpaceEx('C:\\'.toPcwstr(allocator: a), free, total, all).value) {
            diskFree = free.value / (1 << 30);
            diskTotal = total.value / (1 << 30);
          }
        });
        cpu = await _cpu();
      } catch (_) {}
    }
    final results = await Future.wait([
      _online(),
      if (apps && supported) _topApps() else Future.value(const <(String, int)>[]),
    ]);
    int hub = 0;
    try {
      hub = ProcessInfo.currentRss ~/ (1 << 20);
    } catch (_) {}
    return SystemStatus(
      battery: battery,
      charging: charging,
      saver: saver,
      memLoad: memLoad,
      memTotalGb: memTotal,
      memFreeGb: memFree,
      diskFreeGb: diskFree,
      diskTotalGb: diskTotal,
      cpu: cpu,
      online: results[0] as bool?,
      hubMb: hub,
      topApps: results[1] as List<(String, int)>,
    );
  }

  /// Batterie seulement (instantané, sans attendre) : (%, en charge), ou
  /// null sans batterie.
  static (int, bool)? batteryNow() {
    if (!supported) return null;
    try {
      return using((a) {
        final p = a<SYSTEM_POWER_STATUS>();
        if (!GetSystemPowerStatus(p).value) return null;
        final s = p.ref;
        if ((s.BatteryFlag & 128) != 0 || s.BatteryLifePercent > 100) return null;
        return (s.BatteryLifePercent, s.ACLineStatus == 1);
      });
    } catch (_) {
      return null;
    }
  }

  /// Faut-il prévenir ? Une fois à 20 %, une fois à 10 % (et de nouveau
  /// après une recharge).
  static int? batteryAlert(int percent, bool charging, int? lastAlert) {
    if (charging) return null;
    if (percent <= 10 && (lastAlert == null || lastAlert > 10)) return 10;
    if (percent <= 20 && lastAlert == null) return 20;
    return null;
  }

  static int _ft(FILETIME f) => (f.dwHighDateTime << 32) | f.dwLowDateTime;

  /// Processeur occupé : deux mesures à 0,4 s d'écart.
  static Future<int?> _cpu() async {
    (int, int, int)? sample() => using((a) {
      final idle = a<FILETIME>(), kernel = a<FILETIME>(), user = a<FILETIME>();
      if (!GetSystemTimes(idle, kernel, user).value) return null;
      return (_ft(idle.ref), _ft(kernel.ref), _ft(user.ref));
    });
    final a = sample();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final b = sample();
    if (a == null || b == null) return null;
    final idle = b.$1 - a.$1;
    final total = (b.$2 - a.$2) + (b.$3 - a.$3); // le noyau compte aussi l'inactivité
    if (total <= 0) return null;
    return (100 * (total - idle) / total).round().clamp(0, 100);
  }

  static Future<bool?> _online() async {
    try {
      final r = await InternetAddress.lookup('www.google.com').timeout(const Duration(seconds: 3));
      return r.isNotEmpty;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } catch (_) {
      return null;
    }
  }

  static Future<List<(String, int)>> _topApps() async {
    try {
      final r = await Process.run('tasklist', ['/fo', 'csv', '/nh']).timeout(const Duration(seconds: 6));
      return topMemory('${r.stdout}');
    } catch (_) {
      return const [];
    }
  }

  /// Les applis qui prennent le plus de mémoire, d'après `tasklist /fo csv`
  /// (« "chrome.exe","1234","Console","1","123 456 Ko" »), regroupées par
  /// programme.
  static List<(String, int)> topMemory(String csv, {int take = 4}) {
    const system = {
      'system',
      'registry',
      'memory compression',
      'svchost.exe',
      'csrss.exe',
      'dwm.exe',
      'smss.exe',
      'lsass.exe',
      'services.exe',
      'wininit.exe',
      'winlogon.exe',
      'fontdrvhost.exe',
      'system idle process',
      'msmpeng.exe',
    };
    final byApp = <String, int>{};
    for (final line in csv.split(RegExp(r'\r?\n'))) {
      final cols = RegExp(r'"([^"]*)"').allMatches(line).map((m) => m[1]!).toList();
      if (cols.length < 5) continue;
      final name = cols[0];
      if (system.contains(name.toLowerCase())) continue;
      final kb = int.tryParse(cols[4].replaceAll(RegExp(r'[^0-9]'), ''));
      if (kb == null) continue;
      byApp[name] = (byApp[name] ?? 0) + kb;
    }
    final list = [for (final e in byApp.entries) (prettyApp(e.key), e.value ~/ 1024)]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return list.take(take).toList();
  }

  /// « chrome.exe » → « Chrome ».
  static String prettyApp(String exe) {
    final base = exe.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), '');
    const names = {
      'msedge': 'Edge',
      'msedgewebview2': 'Edge (pages intégrées)',
      'chrome': 'Chrome',
      'firefox': 'Firefox',
      'discord': 'Discord',
      'spotify': 'Spotify',
      'code': 'VS Code',
      'hub': 'Mon Hub',
      'explorer': 'l\'Explorateur',
      'robloxplayerbeta': 'Roblox',
      'robloxstudiobeta': 'Roblox Studio',
      'teams': 'Teams',
      'winword': 'Word',
      'excel': 'Excel',
      'powerpnt': 'PowerPoint',
      'steam': 'Steam',
      'steamwebhelper': 'Steam',
    };
    final k = base.toLowerCase();
    if (names[k] case final n?) return n;
    return base.isEmpty ? exe : base[0].toUpperCase() + base.substring(1);
  }

  static String _go(double gb) {
    if (gb >= 10) return '${gb.round()} Go';
    return '${gb.toStringAsFixed(1).replaceAll('.', ',')} Go';
  }

  static String _mo(int mb) => mb >= 1024 ? _go(mb / 1024) : '$mb Mo';

  /// Les soucis à signaler (vide : tout va bien).
  List<String> get warnings => [
    if (battery != null && battery! <= 15 && !charging) 'batterie très faible ($battery %) : branche le chargeur',
    if (battery != null && battery! > 15 && battery! <= 25 && !charging) 'batterie à $battery %, pense au chargeur',
    if (memLoad >= 88) 'la mémoire est presque pleine ($memLoad %)',
    if (diskTotalGb > 0 && diskFreeGb < 8) 'il ne reste que ${_go(diskFreeGb)} sur le disque',
    if (cpu != null && cpu! >= 90) 'le processeur est à fond ($cpu %)',
    if (online == false) 'pas d\'internet',
  ];

  /// Ce que Nexo dit (à voix haute).
  String say({bool why = false}) {
    final parts = <String>[
      if (battery != null) 'batterie à $battery %${charging ? ', en charge' : ''}',
      if (memTotalGb > 0) 'mémoire utilisée à $memLoad %',
      if (cpu != null) 'processeur à $cpu %',
      if (diskTotalGb > 0) '${_go(diskFreeGb)} libres sur le disque',
      if (online != null) online! ? 'internet OK' : 'pas d\'internet',
    ];
    final w = warnings;
    final head = w.isEmpty ? 'Tous les systèmes sont opérationnels.' : 'Attention : ${w.join(' ; ')}.';
    final body = parts.isEmpty ? '' : ' ${_cap(parts.join(', '))}.';
    var tail = '';
    if (why || memLoad >= 80) {
      final apps = topApps.where((a) => a.$2 >= 150).take(3).toList();
      if (apps.isNotEmpty) {
        tail = ' Ce qui prend le plus de mémoire : ${apps.map((a) => '${a.$1} (${_mo(a.$2)})').join(', ')}.';
        if (why && memLoad >= 75) tail += ' Ferme ce dont tu ne te sers pas, ça ira mieux.';
      } else if (why && w.isEmpty) {
        tail = ' Rien d\'anormal de mon côté : si ça rame encore, redémarre le PC.';
      }
    }
    return '$head$body$tail';
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Map<String, dynamic> toJson() => {
    if (battery != null) 'batterie_pourcent': battery,
    'en_charge': charging,
    'memoire_utilisee_pourcent': memLoad,
    'memoire_libre_go': double.parse(memFreeGb.toStringAsFixed(1)),
    if (diskTotalGb > 0) 'disque_libre_go': double.parse(diskFreeGb.toStringAsFixed(1)),
    if (cpu != null) 'processeur_pourcent': cpu,
    if (online != null) 'internet': online,
    'mon_hub_mo': hubMb,
    if (topApps.isNotEmpty) 'applis_gourmandes': [for (final a in topApps) '${a.$1} (${_mo(a.$2)})'],
    'resume': say(),
  };
}

// ======================================================== Concentration

/// **Mode concentration** : pendant la séance, Nexo ne dit plus rien de
/// lui-même (idées, remarques, rappels), les notifications de Mon Hub sont
/// gardées pour la fin (sauf les appels), et il annonce la fin avec le
/// bilan. Gardé dans un fichier partagé : Mon Hub et Nexo partout le
/// voient tous les deux.
class FocusMode extends ChangeNotifier {
  FocusMode._();
  static final instance = FocusMode._();

  final _file = JsonFile<Map<String, dynamic>>(
    'concentration.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  DateTime? until;
  DateTime? started;

  /// Notifications gardées pendant la séance.
  int held = 0;
  bool announced = true;

  /// Pour les tests.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  bool get active => until != null && now().isBefore(until!);
  Duration get left => active ? until!.difference(now()) : Duration.zero;

  void _read(Map<String, dynamic> j) {
    final u = j['fin'], s = j['debut'];
    until = u is num ? DateTime.fromMillisecondsSinceEpoch(u.toInt()) : null;
    started = s is num ? DateTime.fromMillisecondsSinceEpoch(s.toInt()) : null;
    held = (j['gardees'] as num?)?.toInt() ?? 0;
    announced = j['annoncee'] != false;
  }

  Map<String, dynamic> _json() => {
    if (until != null) 'fin': until!.millisecondsSinceEpoch,
    if (started != null) 'debut': started!.millisecondsSinceEpoch,
    'gardees': held,
    'annoncee': announced,
  };

  /// Relit le fichier (l'autre programme a pu lancer ou arrêter la séance).
  Future<void> sync() async {
    try {
      if (await _file.reload()) {
        _read(_file.value);
        notifyListeners();
      } else if (until == null && _file.value.isNotEmpty) {
        _read(_file.value);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    await _file.save(_json());
    notifyListeners();
  }

  Future<void> start(Duration d) async {
    final n = now();
    started = n;
    until = n.add(d);
    held = 0;
    announced = false;
    await _save();
  }

  /// Arrête la séance ; renvoie le bilan (ou null s'il n'y en avait pas).
  Future<String?> stop() async {
    await sync();
    final s = started;
    if (s == null || announced) {
      until = null;
      await _save();
      return null;
    }
    final end = active ? now() : until!;
    until = null;
    announced = true;
    final text = summary(end.difference(s), held);
    await _save();
    return text;
  }

  /// La séance vient de finir et personne ne l'a encore annoncée.
  bool get endedUnannounced => !announced && until != null && !now().isBefore(until!);

  /// Une notification gardée pour la fin.
  Future<void> holdOne() async {
    held++;
    await _save();
  }

  static String summary(Duration d, int held) {
    final m = d.inMinutes;
    final time = m >= 60
        ? '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${(m % 60).toString().padLeft(2, '0')}'}'
        : '$m minute${m > 1 ? 's' : ''}';
    final pause = m >= 80 ? 20 : (m >= 40 ? 10 : 5);
    return 'Séance terminée : $time de concentration, bravo. Fais une pause de $pause minutes.'
        '${held == 0 ? '' : ' Pendant ce temps, $held notification${held > 1 ? 's sont arrivées' : ' est arrivée'} : elles t\'attendent dans Mon Hub.'}';
  }
}

// ======================================================= Rappels d'appli

/// « Rappelle-moi de répondre à Léo quand j'ouvre Discord. »
class AppReminder {
  AppReminder({required this.id, required this.app, required this.text, required this.created});
  final String id;

  /// Ce qu'on cherche dans le titre ou le programme de la fenêtre (minuscules).
  final String app;
  final String text;
  final DateTime created;

  Map<String, dynamic> toJson() => {'id': id, 'appli': app, 'texte': text, 'cree': created.millisecondsSinceEpoch};

  factory AppReminder.fromJson(Map j) => AppReminder(
    id: '${j['id']}',
    app: '${j['appli'] ?? ''}',
    text: '${j['texte'] ?? ''}',
    created: DateTime.fromMillisecondsSinceEpoch((j['cree'] as num?)?.toInt() ?? 0),
  );
}

/// Les rappels liés à une appli : dits par Nexo la prochaine fois qu'elle
/// passe au premier plan (fichier partagé entre Mon Hub et Nexo partout).
class AppReminders {
  AppReminders._();
  static final instance = AppReminders._();

  final _file = JsonFile<List<AppReminder>>(
    'rappels-applis.json',
    empty: () => [],
    decode: (j) => [
      for (final e in (j is List ? j : const []))
        if (e is Map) AppReminder.fromJson(e),
    ],
    encode: (v) => [for (final r in v) r.toJson()],
  );

  DateTime? _readAt;

  Future<List<AppReminder>> list() => _file.load();

  /// Le mot à chercher pour une appli dite à l'oral (« mon Discord » →
  /// « discord », « VS Code » → « visual studio code »).
  static String appKey(String raw) {
    var a = raw.toLowerCase().trim();
    a = a
        .replaceFirst(RegExp(r'^(?:mon |ma |le |la |l |les |sur |dans )+'), '')
        .replaceAll(RegExp(r'[.!?,]+$'), '')
        .trim();
    const aliases = {
      'vs code': 'visual studio code',
      'vscode': 'visual studio code',
      'insta': 'instagram',
      'word': 'word',
      'roblox studio': 'roblox studio',
      'ecole directe': 'ecole',
      'école directe': 'ecole',
      'yt': 'youtube',
      'le navigateur': 'chrome',
      'navigateur': 'chrome',
      'mes mails': 'mail',
      'gmail': 'gmail',
    };
    return aliases[a] ?? a;
  }

  Future<AppReminder> add(String app, String text) async {
    final r = AppReminder(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      app: appKey(app),
      text: text.trim(),
      created: DateTime.now(),
    );
    await _file.update((l) => [...l, r]);
    return r;
  }

  Future<bool> remove(String idOrApp) async {
    final k = appKey(idOrApp);
    var removed = false;
    await _file.update((l) {
      final before = l.length;
      final out = [
        for (final r in l)
          if (r.id != idOrApp && r.app != k) r,
      ];
      removed = out.length != before;
      return out;
    });
    return removed;
  }

  /// Le rappel à dire pour la fenêtre [title] (programme [exe]), s'il y en a.
  static AppReminder? match(List<AppReminder> list, String title, [String exe = '']) {
    final t = ' ${title.toLowerCase()} ${exe.toLowerCase()} '.replaceAll(RegExp(r'[^a-z0-9àâçéèêëîïôûùüÿœ]+'), ' ');
    for (final r in list) {
      final k = r.app.replaceAll(RegExp(r'[^a-z0-9àâçéèêëîïôûùüÿœ]+'), ' ').trim();
      if (k.length >= 2 && t.contains(' $k ')) return r;
    }
    return null;
  }

  /// Regarde la fenêtre au premier plan (relit le fichier au plus toutes les
  /// 20 s). Le rappel trouvé est retiré (il n'est dit qu'une fois).
  Future<AppReminder?> due(String title, [String exe = '']) async {
    final n = DateTime.now();
    if (_readAt == null || n.difference(_readAt!) > const Duration(seconds: 20)) {
      _readAt = n;
      await _file.load();
    }
    final r = match(_file.value, title, exe);
    if (r == null) return null;
    await _file.update(
      (l) => [
        for (final x in l)
          if (x.id != r.id) x,
      ],
    );
    return r;
  }
}

// ============================================================ Situation

/// Ce qui se passe en ce moment (prochain cours, devoirs, contrôles,
/// révisions, musique…), en quelques lignes pour les consignes de l'IA :
/// elle répond juste du premier coup, sans relire trois modules.
class ClickySituation {
  ClickySituation._();

  static String describe({
    List<FeedItem> feed = const [],
    Map? music,
    bool focus = false,
    Duration focusLeft = Duration.zero,
    List<String> warnings = const [],
  }) {
    final lines = <String>[
      for (final i in feed.take(6)) '- ${i.title}${i.detail.isEmpty ? '' : ' — ${i.detail}'}',
      if (music != null && music['en_lecture'] == true && '${music['titre'] ?? ''}'.isNotEmpty)
        '- Musique en cours : ${music['titre']}${'${music['artiste'] ?? ''}'.isEmpty ? '' : ' de ${music['artiste']}'}',
      if (focus)
        '- Mode concentration en cours (encore ${focusLeft.inMinutes} min) : réponses brèves, pas de distraction.',
      for (final w in warnings) '- PC : $w',
    ];
    return lines.join('\n');
  }

  /// Lit les modules et fabrique le texte.
  static Future<String> build(
    Future<Object?> Function(String tool, Map<String, dynamic> args) call,
    Set<String> tools,
  ) async {
    Future<Object?> get(String t, [Map<String, dynamic> a = const {}]) async {
      if (!tools.contains(t)) return null;
      try {
        return await call(t, a).timeout(const Duration(seconds: 8));
      } catch (_) {
        return null;
      }
    }

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day).toIso8601String().substring(0, 10);
    final r = await Future.wait([
      get('agenda_lire', {'debut': day, 'jours': 2}),
      get('ecole_devoirs'),
      get('revision_paquets'),
      get('musique_en_cours'),
    ]);
    List<Map> maps(Object? v) => [
      if (v is List)
        for (final x in v)
          if (x is Map) x,
    ];
    final feed = HubFeed.build(
      events: maps(r[0]),
      homework: maps(r[1]),
      revisions: r[2] is Map ? r[2] as Map : const {},
      now: now,
    );
    final f = FocusMode.instance;
    await f.sync();
    return describe(feed: feed, music: r[3] is Map ? r[3] as Map : null, focus: f.active, focusLeft: f.left);
  }
}
