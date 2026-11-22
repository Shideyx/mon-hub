// **Les yeux et les oreilles de Clicky** (v1.58) : il voit ton écran et
// entend le son de ton PC **en continu**, mais tout se passe sur le PC :
// - les yeux : quand la fenêtre au premier plan change, il en lit le texte
//   (lecture de texte de Windows, sans internet) ;
// - les oreilles : quand une vidéo ou un site joue du son, il le transcrit
//   (Whisper, sur le PC) — **jamais pendant un appel** (enregistrer les
//   paroles des autres sans leur accord est interdit), ni la musique.
// Ce qu'il a vu et entendu va dans la mémoire de l'écran (7 jours, chiffrée,
// jamais synchronisée). L'IA n'est appelée que quand il remarque quelque
// chose d'utile (une erreur, une date limite, une vidéo en anglais…), ou
// quand tu lui parles. Jamais : tes messageries, tes mails, ta banque, tes
// mots de passe, la navigation privée, Mon Hub.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import '../../core/claude_bridge.dart';
import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import '../../core/module_store.dart';
import '../../core/prompt_shield.dart';
import '../../core/screen_memory.dart';
import '../../core/screen_time.dart';
import 'autonomy.dart';
import 'habits.dart';
import 'initiatives.dart' show DateSpotter, SpottedDate;
import 'life.dart' show BeatDetector;
import 'live_captions.dart' show LiveCaptions;
import 'loopback.dart';
import 'ocr.dart';
import 'shot_encode.dart';
import 'tutor.dart' show isSensitiveTitle, normalize;
import 'whisper.dart' show Whisper;
import 'win.dart';

/// Les règles (testables, sans Windows).
class SenseRules {
  SenseRules._();

  static String exeName(String exe) => exe.toLowerCase().trim().replaceFirst(RegExp(r'\.exe$'), '');

  static final _privateTitle = RegExp(
    r'discord|whatsapp|messenger|instagram|snapchat|telegram|signal|teams|gmail|outlook|courrier|boite de reception|'
    r'inbox|mon hub|banque|bank|paypal|lydia|revolut|boursorama|mot de passe|password|bitwarden|1password|keepass|'
    r'lastpass|dashlane|authenticator|ecole ?directe|pronote|inprivate|navigation privee|incognito|private browsing|'
    r'fenetre privee|onglet prive|\bmail\b|messagerie',
  );

  static const _privateExe = {
    'hub', 'discord', 'whatsapp', 'telegram', 'signal', 'teams', 'ms-teams', 'outlook', 'olk', 'hxoutlook', 'keepass',
    'keepassxc', 'bitwarden', '1password', 'zoom', 'skype', 'slack', 'messenger', 'lockapp', 'logonui', 'consent',
    'credentialuibroker', 'thunderbird', 'mailspring',
  };

  /// Fenêtre qu'il ne regarde **jamais** (messageries, mails, banque, mots
  /// de passe, navigation privée, Mon Hub).
  static bool privateWindow(String exe, String title) {
    if (_privateExe.contains(exeName(exe))) return true;
    if (isSensitiveTitle(title)) return true;
    return _privateTitle.hasMatch(normalize(title));
  }

  /// Programmes d'appel : pendant qu'ils font du son, il n'écoute pas.
  static const callExes = {
    'discord', 'teams', 'ms-teams', 'zoom', 'skype', 'whatsapp', 'telegram', 'signal', 'slack', 'webex', 'ciscowebex',
    'facetime', 'messenger', 'phoneexperiencehost', 'yourphone', 'hub',
  };

  static const browsers = {'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi', 'arc', 'msedgewebview2'};

  static final _callTitle = RegExp(
    r'\b(?:meet|google meet|zoom|teams|jitsi|whereby|webex|discord|whatsapp|messenger|appel|visio|visioconference|facetime|skype)\b',
  );

  /// Un appel est (peut-être) en cours : un programme d'appel fait du son,
  /// ou un navigateur qui fait du son a un onglet d'appel (Meet, Discord…).
  static bool callLikely(List<String> audioApps, List<(String, String)> windows) {
    final apps = {for (final a in audioApps) exeName(a)};
    if (apps.any(callExes.contains)) return true;
    if (apps.any(browsers.contains)) {
      for (final (title, exe) in windows) {
        if (browsers.contains(exeName(exe)) && _callTitle.hasMatch(normalize(title))) return true;
      }
    }
    return false;
  }

  /// Une petite image de la fenêtre (cases de luminosité) pour savoir si
  /// elle a changé sans tout relire.
  static List<int> thumb(Uint8List bgra, int w, int h, {int cols = 16, int rows = 9}) {
    final out = List<int>.filled(cols * rows, 0);
    final counts = List<int>.filled(cols * rows, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        if (i + 2 >= bgra.length) break;
        final lum = (bgra[i] * 29 + bgra[i + 1] * 150 + bgra[i + 2] * 77) >> 8;
        final k = (y * rows ~/ h) * cols + (x * cols ~/ w);
        out[k] += lum;
        counts[k]++;
      }
    }
    return [for (var k = 0; k < out.length; k++) counts[k] == 0 ? 0 : out[k] ~/ counts[k]];
  }

  /// La fenêtre a changé (écart moyen de luminosité des cases).
  static bool changed(List<int> a, List<int> b, {int threshold = 5}) {
    if (a.length != b.length || a.isEmpty) return true;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d += (a[i] - b[i]).abs();
    }
    return d / a.length > threshold;
  }

  /// Le texte lu à l'écran, nettoyé (lignes vides et bouts illisibles).
  static String cleanOcr(String raw, {int max = ScreenMemory.maxText}) {
    final lines = <String>[];
    for (final l in raw.split('\n')) {
      final t = l.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.length < 3 || RegExp(r'^[^A-Za-zÀ-ÿ0-9]+$').hasMatch(t)) continue;
      lines.add(t);
    }
    final s = lines.join('\n');
    return s.length > max ? s.substring(0, max) : s;
  }

  /// Presque rien à entendre (silence, bruit très faible).
  static bool quiet(Uint8List pcm, {double threshold = 0.01}) {
    final d = ByteData.sublistView(pcm);
    var s = 0.0;
    var n = 0;
    for (var i = 0; i + 1 < pcm.length; i += 8) {
      final v = d.getInt16(i, Endian.little) / 32768;
      s += v * v;
      n++;
    }
    return n == 0 || math.sqrt(s / n) < threshold;
  }

  /// Ce qu'il a entendu, nettoyé ([Musique], (applaudissements)…).
  static String cleanHeard(String raw) => raw
      .replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)|♪'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final _errorWords = RegExp(
    r'\b(?:error|erreur|exception|traceback|failed|failure|echec|echoue|introuvable|not found|syntaxerror|typeerror|'
    r'nameerror|valueerror|indexerror|keyerror|undefined|nullpointerexception|segmentation fault|fatal|cannot find|'
    r'impossible de|a cesse de fonctionner|ne repond pas|stack trace|uncaught)\b',
  );

  static final _devApps = RegExp(
    r'\b(?:code|visual studio|devenv|pycharm|intellij|android studio|cmd|powershell|terminal|windowsterminal|python|'
    r'idle|thonny|eclipse|netbeans|unity|roblox ?studio|robloxstudiobeta|replit|jupyter|colab|scratch|arduino|godot|'
    r'excel|edupython|spyder|geogebra|capytale|basthon)\b',
  );

  /// Une erreur est affichée (dans un éditeur de code, un terminal, ou une
  /// boîte « Erreur »).
  static bool errorShown(String exe, String title, String text) {
    final t = normalize(text);
    final hits = _errorWords.allMatches(t).length;
    if (hits == 0) return false;
    final where = normalize('${exeName(exe)} $title');
    if (_devApps.hasMatch(where) && hits >= 2) return true;
    return text.length < 500 && RegExp(r'\b(?:erreur|error)\b').hasMatch(normalize(title));
  }

  static final _mine = RegExp(r"\b(?:j|je|mon|ma|mes|on|nous|tu|ton|ta|tes|vous|votre|vos|a rendre|rendre)\b");

  /// Une date limite (ou un rendez-vous qui te concerne) vue à l'écran.
  static SpottedDate? deadline(String text, DateTime now) {
    for (final d in DateSpotter.find(text, now)) {
      if (!d.at.isAfter(now) || d.at.difference(now).inDays > 60) continue;
      if (d.kind == 'limite' || _mine.hasMatch(normalize(d.sentence))) return d;
    }
    return null;
  }

  static const _en = {'the', 'and', 'you', 'is', 'are', 'what', 'this', 'that', 'with', 'have', 'it', 'of', 'to', 'we', 'they', 'was', 'for', 'not'};
  static const _fr = {'le', 'la', 'les', 'et', 'est', 'une', 'des', 'que', 'qui', 'pas', 'pour', 'dans', 'on', 'je', 'tu', 'nous', 'vous', 'du', 'ce'};

  /// C'est de l'anglais (ce qu'il entend dans la vidéo).
  static bool english(String text) {
    final ws = text.toLowerCase().split(RegExp(r"[^a-z']+")).where((w) => w.isNotEmpty).toList();
    if (ws.length < 12) return false;
    final en = ws.where(_en.contains).length, fr = ws.where(_fr.contains).length;
    return en >= 5 && en > fr * 3;
  }

  static final _important = RegExp(
    r"\b(?:a retenir|c est important|c est tres important|tres important|retenez bien|retenez|notez bien|notez ca|"
    r"ca tombera|ca va tomber|ca tombe|au controle|pour le controle|pour l examen|au bac|pour le bac|n oubliez pas|"
    r"par coeur|la definition|le theoreme|la formule)\b",
  );

  /// Une phrase importante dans ce qu'il entend (« retenez bien que… »).
  static String? importantLine(String heard) {
    for (final s in heard.split(RegExp(r'(?<=[.!?])\s+'))) {
      if (s.trim().length >= 12 && _important.hasMatch(normalize(s))) {
        final t = s.trim();
        return t.length > 220 ? '${t.substring(0, 220)}…' : t;
      }
    }
    return null;
  }

  /// Les applis et sites qui font perdre du temps.
  static const distractions = {
    'YouTube', 'Roblox', 'TikTok', 'Instagram', 'Netflix', 'Twitch', 'Snapchat', 'Reddit', 'X', 'Crunchyroll',
    'Disney+', 'Prime Video', 'Minecraft', 'Fortnite', 'Valorant', 'League of Legends', 'Steam', 'Rocket League', 'GTA V',
    'Counter-Strike 2', 'Apex Legends', 'Overwatch', 'Genshin Impact', 'Discord',
  };

  /// Minutes de distraction sur les [window] dernières minutes (tours de
  /// 15 s), et l'appli la plus présente.
  static (int, String) distraction(List<(DateTime, String)> ticks, DateTime now, {Duration window = const Duration(minutes: 50)}) {
    final by = <String, int>{};
    for (final (at, app) in ticks) {
      if (now.difference(at) > window || !distractions.contains(app)) continue;
      by[app] = (by[app] ?? 0) + 1;
    }
    if (by.isEmpty) return (0, '');
    final total = by.values.fold<int>(0, (a, b) => a + b);
    final top = (by.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    return ((total * 15 / 60).round(), top);
  }

  static String pretty(String subject) {
    final s = subject.trim();
    if (s.isEmpty) return s;
    if (s.length > 4 && s == s.toUpperCase()) return s[0] + s.substring(1).toLowerCase();
    return s;
  }

  /// Le coup de pouce du soir : un devoir (ou un contrôle) pour demain pas
  /// encore fait, et déjà [minutes] min de [app]. Null : pas besoin.
  static String? procrastinationLine({
    required int minutes,
    required String app,
    required List<Map> homework,
    required DateTime now,
  }) {
    if (minutes < 40 || now.hour < 16 || now.hour >= 22) return null;
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    bool isTomorrow(Object? v) {
      final d = v is DateTime ? v : DateTime.tryParse('$v');
      return d != null && d.year == tomorrow.year && d.month == tomorrow.month && d.day == tomorrow.day;
    }

    final due = [for (final h in homework) if (h['fait'] != true && isTomorrow(h['pour_le'])) h];
    if (due.isEmpty) return null;
    due.sort((a, b) => (b['controle'] == true ? 1 : 0).compareTo(a['controle'] == true ? 1 : 0));
    final h = due.first;
    final what = h['controle'] == true ? 'un contrôle de ${pretty('${h['matiere']}')}' : 'le devoir de ${pretty('${h['matiere']}')}';
    return 'Ça fait $minutes minutes de $app, et t\'as $what pour demain. On fait 25 minutes et je te laisse tranquille ?';
  }
}

/// Les programmes qui font du son en ce moment (Windows).
class AudioSessions {
  AudioSessions._();

  static Future<List<String>> active() async {
    if (kIsWeb || !Platform.isWindows) return const [];
    try {
      return await Isolate.run(_scan);
    } catch (_) {
      return const [];
    }
  }

  static List<String> _scan() {
    CoInitializeEx(COINIT_MULTITHREADED);
    final out = <String>[];
    try {
      final en = createInstance<IMMDeviceEnumerator>(MMDeviceEnumerator);
      final dev = en.getDefaultAudioEndpoint(eRender, eConsole);
      if (dev == null) return out;
      final mgr = dev.activate<IAudioSessionManager2>(CLSCTX_ALL, null);
      final list = mgr.getSessionEnumerator();
      if (list == null) return out;
      final n = list.getCount();
      for (var i = 0; i < n; i++) {
        final s = list.getSession(i);
        if (s == null || s.getState() != AudioSessionStateActive) continue;
        final pid = IAudioSessionControl2.from(s).getProcessId();
        if (pid == 0) continue;
        final exe = _exeOf(pid);
        if (exe.isNotEmpty) out.add(exe);
      }
    } catch (_) {
    } finally {
      CoUninitialize();
    }
    return out;
  }

  static String _exeOf(int pid) => using((a) {
    final proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).value;
    if (proc.address == 0) return '';
    try {
      final buf = wsalloc(1024, a);
      final size = a<Uint32>()..value = 1024;
      if (!QueryFullProcessImageName(proc, PROCESS_NAME_WIN32, buf, size).value) return '';
      return buf.toDartString().split(RegExp(r'[\\/]')).last;
    } finally {
      CloseHandle(proc);
    }
  });
}

/// Ses yeux et ses oreilles (tournent dans Mon Hub, toutes les 15 s).
class ClickySenses extends ChangeNotifier {
  ClickySenses._();
  static final instance = ClickySenses._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  // ------------------------------------------------------------ Réglages
  // Propres à ce PC (« app. » : jamais synchronisés).

  static const _kScreen = 'app.sens.ecran', _kSound = 'app.sens.son', _kNudge = 'app.sens.recadrer';

  bool _pref(String k, bool def) {
    try {
      return ModuleStore.global.getBool(k) ?? def;
    } catch (_) {
      return def;
    }
  }

  bool get screenOn => _pref(_kScreen, false);
  bool get soundOn => _pref(_kSound, false);

  /// Le coup de pouce quand tu procrastines (oui par défaut).
  bool get nudgeOn => _pref(_kNudge, true);

  Future<void> setScreen(bool v) async {
    await ModuleStore.global.setBool(_kScreen, v);
    if (!v) {
      seeing = '';
      seeingText = '';
    }
    notifyListeners();
  }

  Future<void> setSound(bool v) async {
    await ModuleStore.global.setBool(_kSound, v);
    if (!v) await _stopEars();
    notifyListeners();
  }

  Future<void> setNudge(bool v) async {
    await ModuleStore.global.setBool(_kNudge, v);
    notifyListeners();
  }

  /// En pause (« arrête de regarder pendant 1 h »).
  DateTime? pausedUntil;
  bool get paused => pausedUntil != null && DateTime.now().isBefore(pausedUntil!);

  void pause(Duration d) {
    pausedUntil = DateTime.now().add(d);
    unawaited(_stopEars());
    notifyListeners();
  }

  void resume() {
    pausedUntil = null;
    notifyListeners();
  }

  // ------------------------------------------------- Branché par Mon Hub

  Future<void> Function(ClickyIdea idea)? propose;
  void Function(String text)? think;
  Future<Object?> Function(String tool, Map<String, dynamic> args)? call;

  /// Mode concentration, jeu… : rien proposer.
  bool Function()? busy;

  /// Un appel Discord dans Mon Hub.
  bool Function()? inCall;

  // ---------------------------------------------------------------- État

  /// La fenêtre lue en dernier et son texte.
  String seeing = '';
  String seeingText = '';

  /// Les oreilles : état (« J'écoute », « Appel en cours : je n'écoute
  /// pas »…), et ce qu'il a entendu ces 10 dernières minutes.
  String soundState = '';
  final heard = <(DateTime, String, String)>[];

  /// Les notes prises dans les vidéos (« à retenir »).
  final notes = <(DateTime, String, String)>[];

  final _apps = <(DateTime, String)>[];
  final _titles = <(DateTime, String, String)>[];
  int _ticks = 0;

  // Les yeux.
  String _lastTitle = '';
  List<int> _lastThumb = const [];
  DateTime _lastOcr = DateTime(2000);
  bool _looking = false;

  /// Un tour (toutes les 15 s) : [exe]/[title] = la fenêtre au premier plan.
  Future<void> tick({
    required String exe,
    required String title,
    required int idle,
    required bool fullscreen,
    bool game = false,
    DateTime? now,
  }) async {
    final n = now ?? DateTime.now();
    final app = ScreenTime.appName(exe, title);
    if (idle < 120 && title.trim().isNotEmpty) {
      _apps.add((n, app));
      if (!SenseRules.privateWindow(exe, title) &&
          (_titles.isEmpty || _titles.last.$3 != title)) {
        _titles.add((n, app, title));
      }
    }
    _apps.removeWhere((e) => n.difference(e.$1) > const Duration(minutes: 70));
    _titles.removeWhere((e) => n.difference(e.$1) > const Duration(minutes: 30));
    _ticks++;
    if (_ticks % 4 == 0) unawaited(_procrastination(n).catchError((Object _) {}));
    if (!supported) return;
    if (screenOn && !paused && idle < 120 && !fullscreen && !game && !SenseRules.privateWindow(exe, title)) {
      await _look(exe, title, app, n);
    }
    if (soundOn && !paused) {
      await _listenTick(n, title: title, exe: exe, game: game);
    } else if (_sub != null) {
      await _stopEars();
    }
    if (_ticks % 4 == 0 && (screenOn || soundOn)) await _writeRecent(n);
  }

  Future<void> _look(String exe, String title, String app, DateTime n) async {
    if (_looking) return;
    final r = Win.foregroundRect();
    if (r == null) return;
    final (x, y, w, h) = r;
    if (w < 200 || h < 120) return;
    // Pas plus d'une lecture par minute pour la même fenêtre.
    if (title == _lastTitle && n.difference(_lastOcr) < const Duration(seconds: 60)) return;
    final small = SenseRules.thumb(Win.captureScaled(x, y, w, h, 64, 36), 64, 36);
    if (title == _lastTitle && !SenseRules.changed(small, _lastThumb)) return;
    _looking = true;
    try {
      final s = math.min(1.0, 1600 / math.max(w, h));
      final tw = math.max(1, (w * s).round()), th = math.max(1, (h * s).round());
      final px = Win.captureScaled(x, y, w, h, tw, th);
      final jpg = await Isolate.run(() => encodeShot(px, tw, th, quality: 82));
      final text = SenseRules.cleanOcr(await ClickyOcr.read(jpg, name: 'clicky-sens.jpg'));
      _lastTitle = title;
      _lastThumb = small;
      _lastOcr = n;
      seeing = title;
      seeingText = text;
      await ScreenMemory.instance.add(ScreenMoment(at: n, app: app, title: title, text: text), now: n);
      await _onScreen(exe, app, title, text, n);
      notifyListeners();
    } catch (_) {
    } finally {
      _looking = false;
    }
  }

  // ------------------------------------------------------------ Oreilles

  StreamSubscription<Uint8List>? _sub;
  final _pcm = BytesBuilder(copy: false);
  bool _transcribing = false;
  bool? _whisper;
  DateTime _whisperAt = DateTime(2000);
  String _soundTitle = '';
  String _soundApp = '';

  /// 20 s de son (PCM 16 kHz, 16 bits) par morceau.
  static const _chunkBytes = 20 * 32000;

  Future<void> _listenTick(DateTime n, {required String title, required String exe, required bool game}) async {
    if (!LoopbackCapture.supported) return;
    if (_whisper == null || n.difference(_whisperAt) > const Duration(minutes: 5)) {
      _whisper = await Whisper.ready;
      _whisperAt = n;
    }
    if (_whisper != true) {
      soundState = 'Il faut installer la reconnaissance vocale sur le PC (Whisper) pour que j\'écoute.';
      await _stopEars();
      return;
    }
    final apps = await AudioSessions.active();
    final windows = [for (final w in Win.windowList()) (w.$2, w.$3)];
    final call = (inCall?.call() ?? false) || SenseRules.callLikely(apps, windows);
    final state = call
        ? 'Un appel est en cours : je n\'écoute pas.'
        : game
        ? 'Tu joues : je n\'écoute pas.'
        : apps.isEmpty
        ? 'Rien ne joue en ce moment.'
        : 'J\'écoute le son de ton PC.';
    if (state != soundState) {
      soundState = state;
      notifyListeners();
    }
    if (!SenseRules.privateWindow(exe, title) && title.trim().isNotEmpty) {
      _soundTitle = title;
      _soundApp = ScreenTime.appName(exe, title);
    }
    if (apps.isNotEmpty && !call && !game) {
      _startEars();
    } else {
      await _stopEars();
    }
  }

  void _startEars() {
    if (_sub != null) return;
    _pcm.clear();
    _sub = LoopbackCapture.start().listen(
      (pcm) {
        _pcm.add(pcm);
        if (_pcm.length >= _chunkBytes) unawaited(_chunk());
      },
      onError: (Object _) => unawaited(_stopEars()),
    );
  }

  Future<void> _stopEars() async {
    final s = _sub;
    _sub = null;
    _pcm.clear();
    await s?.cancel();
  }

  Future<void> _chunk() async {
    final bytes = _pcm.takeBytes();
    if (_transcribing || bytes.isEmpty) return;
    // Silence, ou musique (un vrai rythme) : rien à transcrire.
    if (SenseRules.quiet(bytes)) return;
    final beat = BeatDetector()..push(bytes);
    if (beat.steady) return;
    final dir = ClaudeBridge.folder;
    if (dir == null) return;
    _transcribing = true;
    final n = DateTime.now();
    final title = _soundTitle.isEmpty ? 'Son du PC' : _soundTitle;
    final f = File('$dir${Platform.pathSeparator}clicky-sens.wav');
    try {
      await f.writeAsBytes(LiveCaptions.wav(bytes), flush: true);
      final text = SenseRules.cleanHeard(await Whisper.transcribe(f.path, lang: 'auto', timeout: const Duration(seconds: 60)));
      if (text.length < 8 || _sub == null) return;
      heard.add((n, title, text));
      heard.removeWhere((e) => n.difference(e.$1) > const Duration(minutes: 10));
      await ScreenMemory.instance.add(
        ScreenMoment(at: n, app: _soundApp.isEmpty ? 'Son du PC' : _soundApp, title: title, text: text, heard: true),
        now: n,
      );
      await _onHeard(title, text, n);
      notifyListeners();
    } catch (_) {
    } finally {
      _transcribing = false;
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// Ce qui a été dit ces [last] dernières minutes.
  String heardText({Duration last = const Duration(minutes: 2), DateTime? now}) {
    final n = now ?? DateTime.now();
    return [for (final (at, _, t) in heard) if (n.difference(at) <= last) t].join(' ');
  }

  // --------------------------------------------------------- Initiatives

  final _seen = <String>{};
  String _day = '';
  int _count = 0;
  DateTime? _last;
  String _procDay = '';

  /// Une idée venue d'ailleurs (presse-papier, téléchargement, clé USB…),
  /// dans le même budget.
  Future<bool> offer(ClickyIdea i, String key, {DateTime? now, Duration gap = const Duration(minutes: 15)}) =>
      _propose(i, key, now ?? DateTime.now(), gap: gap);

  /// Une idée (avec ton accord) : 8 par jour au plus, 15 min d'écart, jamais
  /// deux fois la même.
  Future<bool> _propose(ClickyIdea i, String key, DateTime n, {Duration gap = const Duration(minutes: 15)}) async {
    final p = propose;
    if (p == null || (busy?.call() ?? false)) return false;
    final day = n.toIso8601String().substring(0, 10);
    if (day != _day) {
      _day = day;
      _count = 0;
      _seen.clear();
    }
    if (_seen.contains(key) || _count >= 8) return false;
    if (_last != null && n.difference(_last!) < gap) return false;
    _seen.add(key);
    _count++;
    _last = n;
    await p(i);
    return true;
  }

  Future<void> _onScreen(String exe, String app, String title, String text, DateTime n) async {
    if (text.isEmpty) return;
    if (SenseRules.errorShown(exe, title, text)) {
      await _propose(
        ClickyIdea(
          say: 'Je vois une erreur dans $app. Je te l\'explique ?',
          tool: 'clicky_expliquer_ecran',
          args: const {'question': 'Explique-moi l\'erreur qui est à mon écran et comment la corriger, étape par étape.'},
          why: 'erreur à l\'écran',
        ),
        'erreur|$title',
        n,
      );
      return;
    }
    final d = SenseRules.deadline(text, n);
    if (d != null) {
      final sentence = d.sentence.length > 90 ? '${d.sentence.substring(0, 90)}…' : d.sentence;
      final at = d.hasTime ? d.at : DateTime(d.at.year, d.at.month, d.at.day, 8);
      await _propose(
        ClickyIdea(
          say: 'J\'ai vu « $sentence » sur ton écran. Je l\'ajoute à ton agenda, le ${d.at.day}/${d.at.month} ?',
          tool: 'agenda_ajouter',
          args: {
            'titre': sentence.length > 60 ? '${sentence.substring(0, 60)}…' : sentence,
            'debut': at.toIso8601String().substring(0, 16),
            'note': 'Vu à l\'écran dans « $title »',
          },
          why: 'date vue à l\'écran',
        ),
        'date|${normalize(d.sentence)}',
        n,
      );
    }
  }

  Future<void> _onHeard(String title, String text, DateTime n) async {
    final line = SenseRules.importantLine(text);
    if (line != null) {
      notes.add((n, title, line));
      if (notes.length > 50) notes.removeAt(0);
      final key = 'note|${normalize(line)}';
      final day = n.toIso8601String().substring(0, 10);
      if (_seen.add(key) && notes.where((e) => e.$1.toIso8601String().startsWith(day)).length <= 6) {
        think?.call('📌 Noté dans ta vidéo : « $line »');
      }
    }
    if (SenseRules.english(text)) {
      await _propose(
        ClickyIdea(
          say: 'C\'est en anglais : je te mets les sous-titres en français ?',
          tool: 'soustitres_lancer',
          why: 'vidéo en anglais',
        ),
        'anglais|$title',
        n,
      );
    }
  }

  String _habitDay = '';

  /// Juste avant une habitude de jeu ou de vidéos, s'il y a un contrôle ou
  /// un devoir demain.
  Future<void> _habitNudge(DateTime n) async {
    final day = n.toIso8601String().substring(0, 10);
    if (_habitDay == day || n.minute < 45 || n.hour < 12 || n.hour >= 21) return;
    final st = ScreenTime.instance;
    await st.load();
    final h = Habits.upcoming(Habits.find(st.hours, n), n, SenseRules.distractions);
    if (h == null) return;
    final hw = await call!('ecole_devoirs', const {});
    final line = Habits.nudge(h, [for (final x in (hw is List ? hw : const [])) if (x is Map) x], n);
    if (line == null) return;
    if (await _propose(
      ClickyIdea(say: line, tool: 'clicky_concentration', args: const {'minutes': 20}, why: 'habitude + devoir demain'),
      'habitude|$day',
      n,
    )) {
      _habitDay = day;
    }
  }

  Future<void> _procrastination(DateTime n) async {
    if (!nudgeOn || call == null) return;
    unawaited(_habitNudge(n).catchError((Object _) {}));
    final day = n.toIso8601String().substring(0, 10);
    if (_procDay == day || n.hour < 16 || n.hour >= 22) return;
    final (mins, app) = SenseRules.distraction(_apps, n);
    if (mins < 40) return;
    final hw = await call!('ecole_devoirs', const {});
    final line = SenseRules.procrastinationLine(
      minutes: mins,
      app: app,
      homework: [for (final h in (hw is List ? hw : const [])) if (h is Map) h],
      now: n,
    );
    if (line == null) return;
    if (await _propose(
      ClickyIdea(say: line, tool: 'clicky_concentration', args: const {'minutes': 25}, why: 'devoir pour demain'),
      'procrastination|$day',
      n,
    )) {
      _procDay = day;
    }
  }

  // ------------------------------------------------- Pour les consignes

  final _recent = JsonFile<Map<String, dynamic>>(
    'sens-recent.json',
    empty: () => <String, dynamic>{},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{},
    encode: (v) => v,
  );

  /// Ce qu'il voit et entend en ce moment, pour Clicky partout (petit
  /// fichier, réécrit toutes les minutes).
  Future<void> _writeRecent(DateTime n) async {
    String cut(String s, int max) => s.length > max ? '${s.substring(0, max)}…' : s;
    await _recent.save({
      'at': n.millisecondsSinceEpoch,
      if (screenOn) 'fenetres': [for (final (at, app, t) in _titles.reversed.take(6)) '${ScreenMemory.hm(at)} $app : $t'],
      if (screenOn && seeingText.isNotEmpty) 'fenetre': seeing,
      if (screenOn && seeingText.isNotEmpty) 'ecran': cut(seeingText, 700),
      if (soundOn) 'entendu': cut(heardText(now: n), 700),
      if (notes.isNotEmpty) 'notes': [for (final (_, _, l) in notes.reversed.take(3)) l],
    });
  }

  /// Le bloc « ce que tu vois et entends » des consignes de l'IA (lu dans
  /// le petit fichier, dans n'importe quel programme). Vide si rien.
  static Future<String> promptBlock({DateTime? now}) async {
    final f = instance._recent;
    try {
      await f.load();
    } catch (_) {
      return '';
    }
    final j = f.value;
    final at = j['at'] is num ? DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()) : null;
    if (at == null || (now ?? DateTime.now()).difference(at) > const Duration(minutes: 5)) return '';
    final lines = <String>[
      if (j['fenetres'] is List && (j['fenetres'] as List).isNotEmpty)
        'Fenêtres de ces dernières minutes : ${(j['fenetres'] as List).join(' | ')}',
      if ('${j['ecran'] ?? ''}'.isNotEmpty) 'Texte lu dans « ${j['fenetre']} » : ${j['ecran']}',
      if ('${j['entendu'] ?? ''}'.isNotEmpty) 'Ce qui vient d\'être dit dans le son du PC (vidéo) : ${j['entendu']}',
    ];
    if (lines.isEmpty) return '';
    return 'Tes yeux et tes oreilles (tu vois son écran et entends le son de son PC en continu, sur le PC) — '
        'sers-t\'en naturellement si ça aide (« dans ta vidéo, il vient de dire… »), sans réciter :\n'
        '${PromptShield.wrap('memoire_ecran', lines.join('\n'))}\n';
  }

  /// Arrêt (déconnexion, fermeture).
  Future<void> stop() async {
    await _stopEars();
    await ScreenMemory.instance.flush();
  }

  // --------------------------------------------------------------- Outils

  /// Les actions de Clicky sur sa mémoire et ses sens. [explain] : il
  /// ouvre sa boîte et répond sur ce qu'il y a à l'écran.
  List<HubTool> tools({required void Function(String question) explain}) => [
    HubTool(
      name: 'memoire_ecran',
      description:
          'La mémoire de l\'écran (« tu te souviens ? ») : ce que Clicky a vu à l\'écran et entendu dans les vidéos ces 7 '
          'derniers jours. texte = ce qu\'on cherche (« le site sur les volcans ») ; quand = un moment (« hier vers 16 h », '
          '« mardi », « tout à l\'heure ») ; les deux peuvent se combiner.',
      params: {
        'texte': ('string', 'Ce qu\'il faut retrouver (facultatif)'),
        'quand': ('string', 'Le moment (facultatif)'),
      },
      run: (a) async {
        final mem = ScreenMemory.instance;
        await mem.load();
        final now = DateTime.now();
        final q = '${a['texte'] ?? ''}'.trim();
        final when = '${a['quand'] ?? ''}'.trim();
        final w = TimeWindow.parse('$when $q', now);
        if (mem.moments.isEmpty) {
          return {
            'resume': screenOn || soundOn
                ? 'Je n\'ai encore rien vu : ça se remplit au fil de ta journée.'
                : 'Je ne regarde pas ton écran pour l\'instant (Réglages de Clicky → Ses yeux et ses oreilles).',
          };
        }
        if (ScreenMemory.words(q).isEmpty && w != null) {
          final list = mem.between(w.from, w.to);
          return {
            'resume': ScreenMemory.sayBetween(list, w.from, w.to, now),
            'moments': [for (final m in list.take(12)) MemoryHit(m, 0, '').toJson()],
          };
        }
        final hits = mem.search(q, from: w?.from, to: w?.to);
        return {
          'resume': ScreenMemory.say(q, hits, now),
          'resultats': [for (final h in hits) h.toJson()],
        };
      },
    ),
    HubTool(
      name: 'memoire_oublier',
      description: 'Oublie ce que Clicky a vu et entendu ces N dernières minutes (0 = tout effacer).',
      params: {'minutes': ('integer', 'Minutes à oublier (0 = tout)')},
      run: (a) async {
        final m = (a['minutes'] as num?)?.toInt() ?? 15;
        final k = await ScreenMemory.instance.forget(last: m <= 0 ? null : Duration(minutes: m));
        heard.clear();
        return m <= 0
            ? 'C\'est fait : j\'ai tout oublié ($k moments).'
            : 'C\'est fait : j\'ai oublié les $m dernières minutes ($k moments).';
      },
    ),
    HubTool(
      name: 'sens_etat',
      description:
          'Ce que Clicky voit et entend en ce moment (fenêtre lue, son du PC, ce qui vient d\'être dit dans la vidéo, '
          'notes « à retenir »), et si ses yeux et ses oreilles sont allumés.',
      run: (_) async => {
        'yeux': screenOn ? (paused ? 'en pause' : 'allumés') : 'éteints',
        'oreilles': soundOn ? (paused ? 'en pause' : soundState) : 'éteintes',
        if (seeing.isNotEmpty) 'fenetre': seeing,
        if (seeingText.isNotEmpty) 'texte': seeingText.length > 800 ? '${seeingText.substring(0, 800)}…' : seeingText,
        if (heard.isNotEmpty) 'vient_d_etre_dit': heardText(),
        if (notes.isNotEmpty) 'notes_a_retenir': [for (final (_, t, l) in notes.reversed.take(5)) '$l (dans « $t »)'],
      },
    ),
    HubTool(
      name: 'sens_regler',
      description:
          'Allume ou éteint les yeux (voir l\'écran en continu) et les oreilles (entendre le son du PC) de Clicky, ou les '
          'met en pause.',
      params: {
        'ecran': ('boolean', 'Voir l\'écran en continu'),
        'son': ('boolean', 'Entendre le son du PC'),
        'pause_minutes': ('integer', 'Mettre en pause pendant N minutes (0 = reprendre)'),
      },
      run: (a) async {
        if (a['ecran'] is bool) await setScreen(a['ecran'] as bool);
        if (a['son'] is bool) await setSound(a['son'] as bool);
        final p = (a['pause_minutes'] as num?)?.toInt();
        if (p != null) p <= 0 ? resume() : pause(Duration(minutes: p));
        return {
          'yeux': screenOn,
          'oreilles': soundOn,
          if (paused) 'pause_jusqu_a': '${pausedUntil!.hour} h ${pausedUntil!.minute.toString().padLeft(2, '0')}',
        };
      },
    ),
    HubTool(
      name: 'clicky_habitudes',
      description:
          'Ce que Clicky a remarqué sur tes habitudes (temps d\'écran par heure, sur ce PC) : « le mercredi vers 14 h, c\'est '
          'Roblox », ton heure la plus active, l\'heure où tu quittes le PC le soir, ton appli n° 1.',
      run: (_) async {
        final st = ScreenTime.instance;
        await st.load();
        final now = DateTime.now();
        final list = Habits.insights(st.hours, st.week(now), now);
        return {
          'resume': list.isEmpty
              ? 'Je ne te connais pas encore assez : il me faut quelques semaines de temps d\'écran.'
              : 'Ce que j\'ai remarqué : ${list.join(' ')}',
          'habitudes': [for (final h in Habits.find(st.hours, now).take(8)) h.toJson()],
        };
      },
    ),
    HubTool(
      name: 'clicky_expliquer_ecran',
      description: 'Clicky ouvre sa boîte, regarde l\'écran et répond à une question dessus (« explique cette erreur »).',
      params: {'question': ('string', 'La question sur l\'écran')},
      run: (a) async {
        final q = '${a['question'] ?? ''}'.trim();
        explain(q.isEmpty ? 'Explique-moi ce qu\'il y a à mon écran.' : q);
        return 'J\'ouvre ma boîte et je regarde.';
      },
    ),
  ];
}
