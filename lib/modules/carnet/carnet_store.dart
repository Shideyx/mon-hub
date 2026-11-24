import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/safe_open.dart';
import '../../core/hub_files.dart';

/// Une ligne du carnet (tâche, note, idée, dépense, séance…).
class CarnetItem {
  CarnetItem(this.data);
  final Map<String, dynamic> data;

  String get id => '${data['id']}';
  String get text => '${data['text'] ?? ''}';
  DateTime get at => DateTime.fromMillisecondsSinceEpoch((data['at'] as num?)?.toInt() ?? 0);
  bool get done => data['done'] == true;
  double get amount => (data['amount'] as num?)?.toDouble() ?? 0;
  String get category => '${data['category'] ?? ''}';
}

/// Le Carnet : tout ce que Smily retient pour toi (porté des plugins de
/// ton JARVIS) — tâches, notes, idées en vrac, mémoire, budget, sport, jeux,
/// poèmes, protocoles, presse-papier. Un fichier par compte, partagé avec
/// Smily partout.
class Carnet extends ChangeNotifier {
  Carnet._();
  static final instance = Carnet._();

  static const lists = ['todos', 'notes', 'inbox', 'memory', 'money', 'sport', 'games', 'poems', 'clipboard'];

  final _file = JsonFile<Map<String, dynamic>>(
    'carnet.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  Map<String, dynamic> get data => _file.value;

  List<CarnetItem> list(String name) => [
    for (final e in (data[name] as List?) ?? const [])
      if (e is Map) CarnetItem(e.cast<String, dynamic>()),
  ];

  T setting<T>(String k, T d) {
    final v = (data['settings'] as Map?)?[k];
    return v is T ? v : d;
  }

  Future<void> load() async {
    if (await _file.reload()) notifyListeners();
  }

  Future<CarnetItem> add(String name, Map<String, dynamic> item, {int max = 2000}) async {
    final now = DateTime.now();
    final full = {'id': '${now.microsecondsSinceEpoch}', 'at': now.millisecondsSinceEpoch, ...item};
    await _file.update((d) {
      final l = [...((d[name] as List?) ?? const []), full];
      if (l.length > max) l.removeRange(0, l.length - max);
      return {...d, name: l};
    });
    notifyListeners();
    return CarnetItem(full);
  }

  Future<void> change(String name, String id, Map<String, dynamic> fields) async {
    await _file.update((d) {
      final l = [
        for (final e in (d[name] as List?) ?? const [])
          if (e is Map && '${e['id']}' == id) {...e.cast<String, dynamic>(), ...fields} else e,
      ];
      return {...d, name: l};
    });
    notifyListeners();
  }

  Future<void> remove(String name, String id) async {
    await _file.update((d) {
      final l = [
        for (final e in (d[name] as List?) ?? const [])
          if (!(e is Map && '${e['id']}' == id)) e,
      ];
      return {...d, name: l};
    });
    notifyListeners();
  }

  Future<void> clear(String name) async {
    await _file.update((d) => {...d, name: <Object>[]});
    notifyListeners();
  }

  Future<void> setSetting(String k, Object? v) async {
    await _file.update((d) {
      final s = {...((d['settings'] as Map?) ?? const {}).cast<String, dynamic>()};
      if (v == null) {
        s.remove(k);
      } else {
        s[k] = v;
      }
      return {...d, 'settings': s};
    });
    notifyListeners();
  }

  /// Retrouve un élément par son id ou par un bout de son texte.
  CarnetItem? find(String name, String idOrText) {
    final q = idOrText.toLowerCase().trim();
    final l = list(name);
    return l.where((e) => e.id == idOrText).firstOrNull ??
        l.where((e) => e.text.toLowerCase() == q).firstOrNull ??
        l.where((e) => e.text.toLowerCase().contains(q)).firstOrNull;
  }

  // ---------- Mémoire ----------

  /// Ce que Smily sait de toi (ajouté à ses consignes).
  List<String> get facts => [for (final m in list('memory')) m.text];

  // ---------- Budget ----------

  /// Bilan d'une période : (dépenses, revenus, par catégorie).
  (double, double, Map<String, double>) money(DateTime from) {
    var spent = 0.0, earned = 0.0;
    final cats = <String, double>{};
    for (final e in list('money')) {
      if (e.at.isBefore(from)) continue;
      if (e.amount < 0) {
        spent += -e.amount;
        final c = e.category.isEmpty ? 'autre' : e.category;
        cats[c] = (cats[c] ?? 0) + -e.amount;
      } else {
        earned += e.amount;
      }
    }
    return (spent, earned, cats);
  }

  // ---------- Sport ----------

  /// Progrès sur un exercice : (meilleure charge, dernière séance, séances).
  (double, CarnetItem?, int) progress(String exercise) {
    final q = exercise.toLowerCase().trim();
    final l = list('sport').where((e) => '${e.data['exercise']}'.toLowerCase().contains(q)).toList();
    var best = 0.0;
    for (final e in l) {
      final w = (e.data['weight'] as num?)?.toDouble() ?? 0;
      if (w > best) best = w;
    }
    return (best, l.lastOrNull, l.length);
  }

  // ---------- Bilan du soir ----------

  Map<String, Object?> eveningRecap([DateTime? now]) {
    final n = now ?? DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    bool isToday(CarnetItem e) => !e.at.isBefore(today);
    final todos = list('todos');
    final (spent, earned, _) = money(today);
    return {
      'taches_faites_aujourd_hui': [
        for (final t in todos)
          if (t.done &&
              t.data['doneAt'] is num &&
              DateTime.fromMillisecondsSinceEpoch((t.data['doneAt'] as num).toInt()).isAfter(today))
            t.text,
      ],
      'taches_restantes': [
        for (final t in todos)
          if (!t.done) t.text,
      ],
      'notes_du_jour': [
        for (final x in list('notes'))
          if (isToday(x)) x.text,
      ],
      'idees_du_jour': [
        for (final x in list('inbox'))
          if (isToday(x)) x.text,
      ],
      'depenses_du_jour': spent,
      'revenus_du_jour': earned,
      'sport_du_jour': [
        for (final x in list('sport'))
          if (isToday(x)) '${x.data['exercise']} ${x.data['weight'] ?? ''} kg × ${x.data['reps'] ?? ''}',
      ],
      'jeux_du_jour': [
        for (final x in list('games'))
          if (isToday(x) && x.data['minutes'] != null) '${x.data['game']} (${x.data['minutes']} min)',
      ],
    };
  }

  // ---------- Protocoles ----------

  static const defaultProtocols = {
    'travail': [
      {'type': 'dire', 'valeur': 'Protocole travail. Je mets ta playlist focus, concentre-toi bien.'},
      {'type': 'spotify', 'valeur': 'playlist', 'requete': 'focus'},
    ],
    'nuit': [
      {'type': 'musique', 'valeur': 'pause'},
      {'type': 'notifier', 'valeur': 'Protocole nuit activé, bonne nuit.'},
      {'type': 'dire', 'valeur': 'Protocole nuit. Bonne nuit, à demain.'},
    ],
  };

  Map<String, List<Map<String, dynamic>>> get protocols {
    final raw = data['protocols'];
    final src = raw is Map ? raw : defaultProtocols;
    return {
      for (final e in src.entries)
        '${e.key}': [
          for (final s in (e.value as List?) ?? const [])
            if (s is Map) s.cast<String, dynamic>(),
        ],
    };
  }

  Future<void> saveProtocols(Map<String, List<Map<String, dynamic>>> p) async {
    await _file.update((d) => {...d, 'protocols': p});
    notifyListeners();
  }
}

/// Météo du jour (Open-Meteo : gratuit, sans clé) et conseil de tenue.
class Weather {
  Weather._();

  static final _cache = <String, (DateTime, Map<String, dynamic>)>{};

  static const _codes = {
    0: ('ciel dégagé', '☀️'),
    1: ('plutôt dégagé', '🌤️'),
    2: ('partiellement nuageux', '⛅'),
    3: ('couvert', '☁️'),
    45: ('brouillard', '🌫️'),
    48: ('brouillard givrant', '🌫️'),
    51: ('bruine légère', '🌦️'),
    53: ('bruine', '🌦️'),
    55: ('bruine dense', '🌧️'),
    61: ('pluie faible', '🌦️'),
    63: ('pluie', '🌧️'),
    65: ('forte pluie', '🌧️'),
    66: ('pluie verglaçante', '🌧️'),
    67: ('forte pluie verglaçante', '🌧️'),
    71: ('neige faible', '🌨️'),
    73: ('neige', '🌨️'),
    75: ('forte neige', '❄️'),
    77: ('grains de neige', '🌨️'),
    80: ('averses', '🌦️'),
    81: ('averses', '🌧️'),
    82: ('violentes averses', '⛈️'),
    85: ('averses de neige', '🌨️'),
    86: ('fortes averses de neige', '❄️'),
    95: ('orage', '⛈️'),
    96: ('orage avec grêle', '⛈️'),
    99: ('violent orage avec grêle', '⛈️'),
  };

  static (String, String) describe(int code) => _codes[code] ?? ('temps variable', '🌡️');

  /// Conseil de tenue (comme ton plugin outfit_weather).
  static String outfit({
    required double min,
    required double max,
    required int rainChance,
    required double wind,
    required int code,
  }) {
    final tips = <String>[];
    if (max <= 5) {
      tips.add('gros manteau, bonnet et gants');
    } else if (max <= 12) {
      tips.add('un manteau chaud');
    } else if (max <= 18) {
      tips.add('une veste ou un sweat');
    } else if (max <= 25) {
      tips.add('un t-shirt avec une petite veste pour le matin');
    } else {
      tips.add('des vêtements légers, et de l\'eau');
    }
    if (rainChance >= 50 || (code >= 51 && code <= 82)) tips.add('un parapluie ou un imperméable');
    if (wind >= 35) tips.add('quelque chose qui coupe le vent');
    if (code >= 71 && code <= 86) tips.add('des chaussures qui ne glissent pas');
    if (max - min >= 10) tips.add('plusieurs couches (il fait bien plus chaud l\'après-midi)');
    return 'Prends ${tips.join(', ')}.';
  }

  /// Météo d'une ville (mise en cache 20 min).
  static Future<Map<String, dynamic>> forCity(String city, [http.Client? client]) async {
    final key = city.toLowerCase().trim();
    if (key.isEmpty) throw 'Dis-moi ta ville (Carnet → Réglages) pour la météo';
    final c = _cache[key];
    if (c != null && DateTime.now().difference(c.$1) < const Duration(minutes: 20)) return c.$2;
    final h = client ?? http.Client();
    final g = jsonDecode(
      (await h
              .get(
                Uri.parse(
                  'https://geocoding-api.open-meteo.com/v1/search?name=${Uri.encodeQueryComponent(city)}&count=1&language=fr&format=json',
                ),
              )
              .timeout(const Duration(seconds: 10)))
          .body,
    );
    final place = ((g is Map ? g['results'] : null) as List?)?.whereType<Map>().firstOrNull;
    if (place == null) throw 'Ville introuvable : $city';
    final f = jsonDecode(
      (await h
              .get(
                Uri.parse(
                  'https://api.open-meteo.com/v1/forecast?latitude=${place['latitude']}&longitude=${place['longitude']}'
                  '&current=temperature_2m,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,'
                  'precipitation_probability_max,weather_code&timezone=auto&forecast_days=2',
                ),
              )
              .timeout(const Duration(seconds: 10)))
          .body,
    ) as Map;
    final cur = (f['current'] as Map?) ?? const {};
    final d = (f['daily'] as Map?) ?? const {};
    double at(String k, int i) => ((d[k] as List?)?.elementAtOrNull(i) as num?)?.toDouble() ?? 0;
    final code = (cur['weather_code'] as num?)?.toInt() ?? 0;
    final (desc, icon) = describe(code);
    final out = <String, dynamic>{
      'ville': '${place['name']}',
      'maintenant': '${(cur['temperature_2m'] as num?)?.round()} °C, $desc',
      'icone': icon,
      'temperature': (cur['temperature_2m'] as num?)?.toDouble(),
      'min': at('temperature_2m_min', 0).round(),
      'max': at('temperature_2m_max', 0).round(),
      'pluie_pourcent': at('precipitation_probability_max', 0).round(),
      'vent_kmh': (cur['wind_speed_10m'] as num?)?.round(),
      'pluie_demain_pourcent': at('precipitation_probability_max', 1).round(),
      'demain':
          '${at('temperature_2m_min', 1).round()} à ${at('temperature_2m_max', 1).round()} °C, '
          '${describe(at('weather_code', 1).toInt()).$1}',
      'tenue': outfit(
        min: at('temperature_2m_min', 0),
        max: at('temperature_2m_max', 0),
        rainChance: at('precipitation_probability_max', 0).round(),
        wind: (cur['wind_speed_10m'] as num?)?.toDouble() ?? 0,
        code: (d['weather_code'] as List?)?.firstOrNull is num
            ? ((d['weather_code'] as List).first as num).toInt()
            : code,
      ),
    };
    _cache[key] = (DateTime.now(), out);
    return out;
  }
}

/// Notification sur le téléphone via ntfy.sh (gratuit, sans compte : tu
/// t'abonnes à ton « topic » secret dans l'appli ntfy), comme ton plugin
/// mobile_bridge.
class PhoneNotify {
  PhoneNotify._();

  static Future<void> send(String topic, String title, String message, {bool urgent = false}) async {
    final t = topic.trim();
    if (t.isEmpty) throw 'Choisis ton topic ntfy dans Carnet → Réglages';
    final r = await http
        .post(
          Uri.parse('https://ntfy.sh/${Uri.encodeComponent(t)}'),
          headers: {'Title': _ascii(title), 'Priority': urgent ? 'high' : 'default', 'Tags': 'robot'},
          body: utf8.encode(message),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode >= 400) throw 'ntfy : erreur ${r.statusCode}';
  }

  /// Les en-têtes HTTP n'acceptent pas les accents.
  static String _ascii(String s) {
    const from = 'àâäéèêëîïôöùûüçÀÂÉÈÊÎÔÙÛÇ';
    const to = 'aaaeeeeiioouuucAAEEEIOUUC';
    final b = StringBuffer();
    for (final c in s.split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : (c.codeUnitAt(0) < 128 ? c : ''));
    }
    return '$b';
  }
}

/// Presse-papier gardé en mémoire (comme ton plugin clipboard_vault) :
/// désactivé par défaut ; les textes qui ressemblent à des mots de passe
/// sont ignorés.
class ClipboardVault {
  ClipboardVault._();

  static bool looksSecret(String t) {
    final s = t.trim();
    if (s.isEmpty || s.contains(' ') || s.contains('\n')) return false;
    if (s.length < 8 || s.length > 64) return false;
    final kinds = [
      RegExp(r'[a-z]'),
      RegExp(r'[A-Z]'),
      RegExp(r'\d'),
      RegExp(r'[^A-Za-z0-9]'),
    ].where((r) => r.hasMatch(s)).length;
    final looksLikeLink = s.startsWith('http') || s.contains('@') && s.contains('.');
    return kinds >= 3 && !looksLikeLink;
  }

  static Timer? _timer;
  static String _last = '';

  /// [read] lit le presse-papier (Clipboard.getData), [sensitive] dit si la
  /// fenêtre au premier plan est sensible.
  static void start(Future<String?> Function() read, {bool Function()? sensitive}) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final c = Carnet.instance;
      if (!c.setting<bool>('clipboard', false)) return;
      try {
        final t = (await read())?.trim() ?? '';
        if (t.isEmpty || t == _last) return;
        _last = t;
        if (t.length > 4000 || looksSecret(t) || (sensitive?.call() ?? false)) return;
        await c.add('clipboard', {'text': t}, max: 300);
      } catch (_) {}
    });
  }

  static void stop() => _timer?.cancel();
}

/// Ouvre une appli Windows par son nom (« discord », « vscode »…).
Future<void> openApp(String name) async {
  if (kIsWeb || !Platform.isWindows) throw 'Ouvrir une appli ne marche que sur Windows';
  final n = name.toLowerCase().trim();
  const aliases = {
    'vscode': 'code',
    'vs code': 'code',
    'visual studio code': 'code',
    'discord': 'discord:',
    'spotify': 'spotify:',
    'calculatrice': 'calc',
    'bloc-notes': 'notepad',
    'bloc notes': 'notepad',
    'explorateur': 'explorer',
    'chrome': 'chrome',
    'edge': 'msedge',
    'word': 'winword',
    'excel': 'excel',
    'powerpoint': 'powerpnt',
    'roblox studio': 'roblox-studio:',
    'roblox': 'roblox:',
    'steam': 'steam:',
    'paramètres': 'ms-settings:',
    'parametres': 'ms-settings:',
  };
  // Comme un double-clic (aucune commande interprétée), et jamais un
  // programme ou un script inconnu sans accord.
  final target = aliases[n] ?? name;
  if (SafeOpen.risky(target)) throw 'Je ne lance pas « $target » tout seul : ouvre-le toi-même.';
  await SafeOpen.launch(target);
}
