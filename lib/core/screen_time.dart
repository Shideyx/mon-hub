import 'game_pal.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'hub_files.dart';
import 'perf.dart';
import 'module_store.dart';

/// **Temps d'écran** (sur ce PC seulement, jamais envoyé) : le temps passé
/// sur chaque appli ou site (Roblox, YouTube, Discord…), compté seulement
/// quand tu es devant le PC, avec des limites douces si tu en veux.
class ScreenTime extends ChangeNotifier {
  ScreenTime._();
  static final instance = ScreenTime._();

  /// Un tour toutes les 15 secondes.
  static const step = Duration(seconds: 15);

  final _file = JsonFile<Map<String, dynamic>>(
    'temps-ecran.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  Timer? _timer;
  int _ticks = 0;
  bool _loaded = false;

  /// Prévenir (notification + Nexo) quand une limite est atteinte.
  void Function(String title, String body)? alert;

  Map<String, dynamic> get _data => _file.value;

  static String dayKey(DateTime d) => d.toIso8601String().substring(0, 10);

  Future<void> load() async {
    await _file.load();
    _loaded = true;
    notifyListeners();
  }

  /// Le suivi est-il actif ? (oui par défaut)
  bool get on => _data['on'] != false;
  Future<void> setOn(bool v) async {
    await _file.update((m) => {...m, 'on': v});
    notifyListeners();
  }

  /// Limites douces par appli (minutes par jour).
  Map<String, int> get limits => {
    for (final e in ((_data['limites'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt(),
  };

  Future<void> setLimit(String app, int? minutes) async {
    await _file.update((m) {
      final l = Map<String, dynamic>.from((m['limites'] as Map?) ?? const {});
      if (minutes == null || minutes <= 0) {
        l.remove(app);
      } else {
        l[app] = minutes;
      }
      return {...m, 'limites': l};
    });
    notifyListeners();
  }

  /// Secondes par appli pour un jour.
  Map<String, int> day(DateTime d) => {
    for (final e in (((_data['jours'] as Map?) ?? const {})[dayKey(d)] as Map? ?? const {}).entries)
      '${e.key}': (e.value as num).toInt(),
  };

  /// Par heure : jour (« 2026-11-22 ») → heure → appli → secondes.
  Map<String, dynamic> get hours => ((_data['heures'] as Map?) ?? const {}).cast<String, dynamic>();

  /// Secondes par appli sur les 7 derniers jours.
  Map<String, int> week(DateTime now) {
    final out = <String, int>{};
    for (var i = 0; i < 7; i++) {
      for (final e in day(now.subtract(Duration(days: i))).entries) {
        out[e.key] = (out[e.key] ?? 0) + e.value;
      }
    }
    return out;
  }

  static const _browsers = {'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi', 'arc'};

  /// Les sites reconnus dans le titre d'un onglet.
  static const _sites = [
    ('youtube', 'YouTube'),
    ('instagram', 'Instagram'),
    ('tiktok', 'TikTok'),
    ('netflix', 'Netflix'),
    ('twitch', 'Twitch'),
    ('discord', 'Discord'),
    ('roblox', 'Roblox'),
    ('google docs', 'Google Docs'),
    ('google slides', 'Google Slides'),
    ('ecole directe', 'École Directe'),
    ('ecoledirecte', 'École Directe'),
    ('pronote', 'Pronote'),
    ('gmail', 'Gmail'),
    ('chatgpt', 'ChatGPT'),
    ('claude', 'Claude'),
    ('x.com', 'X'),
    ('reddit', 'Reddit'),
    ('snapchat', 'Snapchat'),
    ('crunchyroll', 'Crunchyroll'),
    ('disney+', 'Disney+'),
    ('prime video', 'Prime Video'),
    ('wikipedia', 'Wikipédia'),
    ('classroom', 'Google Classroom'),
  ];

  static const _names = {
    'robloxplayerbeta': 'Roblox',
    'robloxstudiobeta': 'Roblox Studio',
    'discord': 'Discord',
    'spotify': 'Spotify',
    'code': 'VS Code',
    'hub': 'Mon Hub',
    'winword': 'Word',
    'excel': 'Excel',
    'powerpnt': 'PowerPoint',
    'javaw': 'Minecraft',
    'minecraft': 'Minecraft',
    'fortniteclient-win64-shipping': 'Fortnite',
    'valorant-win64-shipping': 'Valorant',
    'leagueclient': 'League of Legends',
    'league of legends': 'League of Legends',
    'steam': 'Steam',
    'steamwebhelper': 'Steam',
    'explorer': 'Explorateur',
    'vlc': 'VLC',
    'obs64': 'OBS',
    'rocketleague': 'Rocket League',
    'gta5': 'GTA V',
    'cs2': 'Counter-Strike 2',
    'r5apex': 'Apex Legends',
    'overwatch': 'Overwatch',
    'genshinimpact': 'Genshin Impact',
    'whatsapp': 'WhatsApp',
    'notepad': 'Bloc-notes',
  };

  /// Toutes les applis et tous les sites qu'on sait nommer.
  static Set<String> get knownApps => {for (final (_, n) in _sites) n, ..._names.values};

  /// L'appli (ou le site, dans un navigateur) d'une fenêtre.
  static String appName(String exe, String title) {
    final e = exe.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
    final t = title.toLowerCase();
    if (_browsers.contains(e)) {
      for (final (k, name) in _sites) {
        if (t.contains(k)) return name;
      }
      return 'Navigateur (autres sites)';
    }
    if (_names[e] case final n?) return n;
    if (e.isEmpty) return 'Autre';
    return e[0].toUpperCase() + e.substring(1);
  }

  static String _plain(String s) {
    const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9+]'), '');
  }

  /// Retrouve l'appli dont on parle (« yt » → YouTube, « minecraft » …).
  static String? matchApp(String said, Iterable<String> names) {
    const alias = {
      'yt': 'youtube',
      'insta': 'instagram',
      'mc': 'minecraft',
      'lol': 'leagueoflegends',
      'ed': 'ecoledirecte',
      'gta': 'gtav',
      'cs': 'counterstrike2',
      'vscode': 'vscode',
      'fortnite': 'fortnite',
      'tiktok': 'tiktok',
    };
    var q = _plain(said);
    if (q.isEmpty) return null;
    q = alias[q] ?? q;
    final list = names.toList();
    for (final n in list) {
      if (_plain(n) == q) return n;
    }
    for (final n in list) {
      final p = _plain(n);
      if (p.length >= 3 && (p.startsWith(q) || q.startsWith(p))) return n;
    }
    for (final n in list) {
      if (q.length >= 4 && _plain(n).contains(q)) return n;
    }
    return null;
  }

  /// Un tour : [exe]/[title] = la fenêtre au premier plan, [idleSeconds] =
  /// depuis quand la souris et le clavier ne bougent plus. Renvoie l'appli
  /// comptée (ou null : absent).
  Future<String?> tick({required String exe, required String title, required int idleSeconds, DateTime? now}) async {
    if (!_loaded) await load();
    if (!on || idleSeconds >= 120 || (exe.isEmpty && title.isEmpty)) return null;
    final n = now ?? DateTime.now();
    final app = appName(exe, title);
    final key = dayKey(n);
    final days = Map<String, dynamic>.from((_data['jours'] as Map?) ?? const {});
    final today = Map<String, dynamic>.from((days[key] as Map?) ?? const {});
    final secs = ((today[app] as num?)?.toInt() ?? 0) + step.inSeconds;
    today[app] = secs;
    days[key] = today;
    // On garde 35 jours.
    final keep = dayKey(n.subtract(const Duration(days: 35)));
    days.removeWhere((k, _) => k.compareTo(keep) < 0);
    _file.value['jours'] = days;
    // Par heure (pour les habitudes : « le mercredi vers 14 h, c'est Roblox »).
    final hours = Map<String, dynamic>.from((_data['heures'] as Map?) ?? const {});
    final h = Map<String, dynamic>.from((hours[key] as Map?) ?? const {});
    final apps = Map<String, dynamic>.from((h['${n.hour}'] as Map?) ?? const {});
    apps[app] = ((apps[app] as num?)?.toInt() ?? 0) + step.inSeconds;
    h['${n.hour}'] = apps;
    hours[key] = h;
    hours.removeWhere((k, _) => k.compareTo(keep) < 0);
    _file.value['heures'] = hours;
    // Limite douce atteinte : prévenu une fois par jour et par appli.
    final limit = limits[app];
    if (limit != null && secs >= limit * 60) {
      final alerted = Map<String, dynamic>.from((_data['alertes'] as Map?) ?? const {});
      final k = '$key|$app';
      if (alerted[k] != true) {
        alerted[k] = true;
        alerted.removeWhere((x, _) => !x.startsWith(key));
        _file.value['alertes'] = alerted;
        alert?.call('⏳ ${say(limit * 60)} de $app aujourd\'hui', 'C\'est la limite que tu t\'es fixée. Une pause ?');
        await _file.save();
      }
    }
    // Enregistré une fois par minute.
    if (++_ticks % 4 == 0) await _file.save();
    notifyListeners();
    return app;
  }

  void start() {
    _timer?.cancel();
    // Mode léger : un tour toutes les 40 s au lieu de 15.
    _timer = Timer.periodic(Perf.slow(step), (_) => onTick?.call());
  }

  void stop() {
    _timer?.cancel();
    unawaited(_file.save());
  }

  /// Appelé à chaque tour (branché par Mon Hub : lit la fenêtre au premier plan).
  void Function()? onTick;

  /// « 1 h 05 », « 40 min ».
  static String say(int secs) {
    final m = (secs / 60).round();
    if (m < 60) return '$m min';
    final h = m ~/ 60, r = m % 60;
    return r == 0 ? '$h h' : '$h h ${r.toString().padLeft(2, '0')}';
  }

  static List<MapEntry<String, int>> sorted(Map<String, int> m) =>
      m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  /// « Aujourd'hui : 3 h 20 sur l'écran, surtout Roblox (1 h 30)… ».
  static String summary(Map<String, int> m, {String when = 'Aujourd\'hui'}) {
    final total = m.values.fold<int>(0, (a, b) => a + b);
    if (total < 60) return '$when : presque rien pour l\'instant.';
    final top = sorted(m).where((e) => e.key != 'Mon Hub').take(3).map((e) => '${e.key} (${say(e.value)})').toList();
    return '$when : ${say(total)} sur l\'écran${top.isEmpty ? '' : ', surtout ${top.join(', ')}'}.';
  }
}

/// **Sommeil** : l'heure de se coucher d'après le premier cours du lendemain.
class Sleep {
  Sleep._();

  /// L'heure du coucher pour dormir [hours] heures, réveil [prep] minutes
  /// avant le premier cours.
  static DateTime bedtime(DateTime firstLesson, {double hours = 9, int prep = 60}) =>
      firstLesson.subtract(Duration(minutes: prep + (hours * 60).round()));

  static String _hm(DateTime d) => d.minute == 0 ? '${d.hour} h' : '${d.hour} h ${d.minute.toString().padLeft(2, '0')}';

  static String say(DateTime firstLesson, {double hours = 9, int prep = 60}) {
    final b = bedtime(firstLesson, hours: hours, prep: prep);
    final h = hours == hours.roundToDouble() ? '${hours.round()}' : '$hours'.replaceAll('.', ',');
    return 'Demain, cours à ${_hm(firstLesson)} : au lit vers ${_hm(b)} pour dormir $h h.';
  }
}

/// **Mode jeu** : quand un jeu est en plein écran, Mon Hub se fait léger
/// (notifications gardées pour la fin, rien de lourd en fond, Nexo
/// discret) ; à la fin, le bilan de la partie.
class GameMode extends ChangeNotifier {
  GameMode._();
  static final instance = GameMode._();

  bool active = false;
  String game = '';
  DateTime? since;
  int held = 0;
  int _seen = 0, _gone = 0;

  /// Le mode jeu automatique est-il voulu ? (oui par défaut)
  static bool get enabled {
    try {
      return ModuleStore.global.getBool('jeu.auto') != false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool v) async {
    await ModuleStore.global.setBool('jeu.auto', v);
    if (!v) instance._reset();
    instance.notifyListeners();
  }

  void _reset() {
    active = false;
    game = '';
    since = null;
    held = 0;
    _seen = _gone = 0;
  }

  /// Un vrai jeu en plein écran (v1.62 : il faut un signe que c'est un jeu,
  /// voir `GameRules.gameOf` ; avant, toute appli agrandie inconnue comptait).
  static bool isGame(String exe, bool fullscreen, {String path = '', String title = '', bool engine = false}) =>
      fullscreen && GameRules.gameOf(exe: exe, path: path, title: title, engine: engine) != null;

  /// Un tour (toutes les 15 s). Renvoie le bilan à dire quand la partie se
  /// termine (sinon null).
  String? tick({
    required String exe,
    required bool fullscreen,
    String path = '',
    String title = '',
    bool engine = false,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    if (isGame(exe, fullscreen, path: path, title: title, engine: engine) && (enabled || active)) {
      _gone = 0;
      // 30 s de jeu avant d'entrer en mode jeu (pas pour un simple coup d'œil).
      if (!active && ++_seen >= 2) {
        active = true;
        game = GameRules.gameOf(exe: exe, path: path, title: title, engine: engine) ?? ScreenTime.appName(exe, '');
        since = n;
        held = 0;
        notifyListeners();
      }
      return null;
    }
    _seen = 0;
    if (active && ++_gone >= 2) {
      final mins = n.difference(since ?? n).inMinutes;
      final text =
          'Fin de ta partie de $game (${ScreenTime.say(mins * 60)}).'
          '${held == 0 ? '' : ' Pendant ce temps, $held notification${held > 1 ? 's sont arrivées' : ' est arrivée'} : elles t\'attendent dans Mon Hub.'}';
      _reset();
      notifyListeners();
      return text;
    }
    return null;
  }
}
