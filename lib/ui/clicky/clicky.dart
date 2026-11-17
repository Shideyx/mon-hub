import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai_text.dart';
import '../../core/claude_api.dart';
import '../../modules/carnet/carnet_module.dart';
import '../../modules/carnet/carnet_store.dart';
import '../../core/claude_bridge.dart';
import '../../core/error_log.dart';
import '../../core/hub_controller.dart';
import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../core/session.dart';
import '../../core/version.dart';
import '../chat_history.dart';
import '../widgets.dart';
import 'act.dart';
import 'board.dart';
import 'buddies.dart';
import 'capture.dart';
import 'clicky_desktop.dart';
import 'claude_code.dart';
import 'documents.dart';
import 'drive.dart';
import 'ears.dart';
import 'extensions.dart';
import 'holo.dart';
import 'hud.dart';
import 'assistant.dart';
import 'flight.dart';
import 'journal.dart';
import 'mind.dart';
import 'live.dart';
import 'pcm_player.dart';
import 'marks.dart';
import 'neural_voice.dart';
import 'ocr.dart';
import 'pc.dart';
import 'quick.dart';
import 'ollama.dart';
import 'pointer.dart';
import 'routines.dart';
import 'tutor.dart';
import 'voice.dart';
import 'wake.dart';
import 'whisper.dart';
import 'mic_test.dart' show openMicFix;
import 'win.dart';

/// « Clicky » : un petit compagnon IA qui vit à côté de ton curseur.
///
/// * Maintiens **Ctrl + Alt** et parle, relâche pour envoyer (appui court =
///   écrire). Sur téléphone : la bulle bleue.
/// * Il voit ton écran (capture envoyée avec ta question ; sur Windows, avec
///   « Clicky partout », tous tes écrans et toutes tes applis).
/// * Il répond à voix haute, le texte s'écrit à côté du curseur, et son
///   curseur bleu **vole jusqu'au bouton** dont il parle.
/// * « Agent, … » : il lance une tâche de fond avec tes modules (agenda,
///   notes, messages…) et te prévient quand c'est fini.
/// * Cerveau au choix : Claude (clé API) ou un modèle **local et gratuit**
///   avec Ollama (rien ne sort du PC).
enum ClickyState { idle, listening, thinking, speaking, pointing }

/// Une capture envoyée à l'IA, et comment ramener ses pixels à l'écran.
class ClickyShot {
  const ClickyShot({
    required this.png64,
    required this.label,
    required this.width,
    required this.height,
    this.origin = Offset.zero,
    required this.logicalPerPx,
  });

  final String png64;
  final String label;
  final int width;
  final int height;

  /// Coin haut-gauche de la capture, en coordonnées de la couche Clicky.
  final Offset origin;

  /// Taille d'un pixel de la capture, en coordonnées de la couche Clicky.
  final double logicalPerPx;

  Offset toLayer(Offset px) => origin + px * logicalPerPx;
}

class ClickyController extends ChangeNotifier {
  ClickyController._();
  static final instance = ClickyController._();

  /// Modules de Mon Hub (dans l'appli).
  HubController? hub;

  /// « Clicky partout » (Windows) : actions lues via le pont local, capture
  /// de tous les écrans, et bascule clics traversants / cliquable.
  List<HubTool> Function()? toolsOverride;
  Future<List<ClickyShot>> Function()? captureOverride;
  void Function(bool interactive)? onInteractive;
  bool desktopMode = false;

  /// Alerte système (agent terminé…).
  void Function(String title, String body)? notify;

  ClickyState state = ClickyState.idle;
  String status = '';
  String reply = '';
  String transcript = '';
  bool panelOpen = false;
  int agentsRunning = 0;

  /// Niveaux sonores récents (0..1) pour l'onde pendant l'écoute.
  final levels = List<double>.filled(7, 0);

  /// Position du curseur (coordonnées de la couche Clicky).
  Offset? cursor;

  /// Cible montrée par l'IA (coordonnées de la couche) et son libellé.
  Offset? target;
  String targetLabel = '';

  /// Là où Clicky regarde de lui-même (il y vole sans « pointer »), et ce
  /// qu'il en pense (petite bulle). Sa « présence ».
  Offset? gaze;
  String gazeNote = '';

  /// Pendant un vol : orientation (radians) et taille (1 → 1,3 au milieu).
  final flightPose = ValueNotifier<(double, double)>((0, 1));
  double get flightAngle => flightPose.value.$1;
  double get flightScale => flightPose.value.$2;
  void setFlight(double angle, double scale) {
    if (flightPose.value != (angle, scale)) flightPose.value = (angle, scale);
  }

  /// Dernier mouvement de la souris (pour savoir si on est là).
  DateTime _lastMove = DateTime.now();
  DateTime _sessionStart = DateTime.now();

  /// Annotations dessinées à l'écran (coordonnées de la couche), et un
  /// numéro qui change à chaque nouveau dessin.
  List<ClickyMark> marks = const [];
  int marksId = 0;

  void clearMarks() {
    if (marks.isEmpty) return;
    marks = const [];
    notifyListeners();
  }

  /// Tableau visuel ouvert (schéma, étapes, frise, quiz…), et s'il est en
  /// train de s'écrire.
  ClickyBoard? board;
  bool drawing = false;

  /// Hologramme 3D affiché (molécule, planète, solide…).
  HoloScene? holo;

  void closeHolo() {
    holo = null;
    if (!panelOpen && board == null) onInteractive?.call(false);
    notifyListeners();
  }

  /// Démarrage (animation « CLICKY EN LIGNE »).
  DateTime? bootAt;

  /// Déplacement de la boîte à la souris : (décalage, début du geste).
  void Function(Offset delta, bool start)? onDragBox;

  void closeBoard() {
    board = null;
    if (!panelOpen) onInteractive?.call(false);
    _fadeSoon();
    notifyListeners();
  }

  void _showBoard(ClickyBoard b) {
    board = b;
    // Le tableau se clique (quiz, boutons) : la fenêtre doit rester là.
    onInteractive?.call(true);
  }

  /// « Apprends-moi un truc » et « Montre-moi en schéma ».
  static const teachPrompt =
      'Apprends-moi un truc intéressant et utile pour mon niveau (si tu peux, en lien avec mes '
      'cours, mes devoirs ou ce qu\'il y a à l\'écran), avec un tableau visuel et un petit quiz à la fin.';
  static const visualPrompt =
      'Je n\'ai pas bien compris. Réexplique-moi autrement, plus simplement, avec un tableau visuel '
      '(schéma ou étapes) et une comparaison de la vie de tous les jours.';
  static const explainScreenPrompt =
      'Explique-moi ce qu\'il y a à l\'écran comme un prof : de quoi ça parle, les notions '
      'importantes, avec un tableau visuel.';

  /// « Briefing » : le topo du matin complet.
  static const briefingPrompt = Routine.topoMorningPrompt;

  bool get hasHistory => _memory().isNotEmpty;

  /// Mode discret : Clicky n'apparaît que pendant un échange.
  bool _recent = false;
  Timer? _fade;

  final shotKey = GlobalKey();
  final input = TextEditingController();

  // ---------- Réglages ----------

  T _opt<T>(String k, T d) {
    final v = _shared?[k];
    if (v is T) return v;
    if (v is num && d is double) return v.toDouble() as T;
    final s = ClaudeApi.store.getJson<Object>('clicky.$k');
    if (s is T) return s;
    if (s is num && d is double) return s.toDouble() as T;
    return d;
  }

  // Réglages partagés avec « Clicky partout » (Windows). Les deux programmes
  // gardent leurs préférences en mémoire sans relire le disque : on passe
  // donc par un petit fichier commun, relu toutes les 2 secondes.
  static const _sharedKeys = [
    'enabled',
    'voice',
    'mic',
    'follow',
    'show',
    'provider',
    'everywhere',
    'look',
    'callName',
    'greet',
    'wake',
    'ttsVoice',
    'ttsRate',
    'ttsPitch',
    'narrate',
    'slow',
    'quiz',
    'codeMode',
    'multilang',
    'ocr',
    'privacy',
    'precise',
    'steps',
    'web',
    'annotate',
    'dictation',
    'drive',
    'journal',
    'perApp',
    'alive',
    'geminiVoice',
    'pc',
    'micEngine',
    'instant',
    'quick',
  ];
  Map<String, dynamic>? _shared;
  DateTime? _sharedStamp;
  Timer? _sharedTimer;

  static File? get _sharedFile {
    final d = ClaudeBridge.folder;
    return d == null ? null : File('$d${Platform.pathSeparator}clicky.json');
  }

  /// Ce que Clicky sait de toi (Carnet → Mémoire).
  List<String> get _facts => Carnet.instance.facts.take(60).toList();

  /// Recharge l'historique et le journal (démarrage, compte changé).
  Future<void> loadMemory() async {
    await history.load();
    await Journal.instance.load();
    await Carnet.instance.load();
    notifyListeners();
  }

  /// Mon Hub (Windows) : publie les réglages du compte ouvert et suit ceux
  /// que « Clicky partout » modifie.
  Future<void> shareOptions() async {
    if (!everywhereSupported) return;
    _shared = null;
    _shared = {for (final k in _sharedKeys) k: ClaudeApi.store.getJson<Object>('clicky.$k')}
      ..removeWhere((_, v) => v == null);
    await _writeShared();
    _watchShared();
  }

  /// « Clicky partout » : lit les réglages publiés par Mon Hub.
  Future<void> followSharedOptions() async {
    await _readShared();
    _watchShared();
  }

  void _watchShared() {
    _sharedTimer?.cancel();
    _sharedTimer = Timer.periodic(const Duration(seconds: 2), (_) => _readShared());
  }

  Future<void> _writeShared() async {
    final f = _sharedFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_shared ?? const {}));
      _sharedStamp = (await f.stat()).modified;
    } catch (_) {}
  }

  Future<void> _readShared() async {
    final f = _sharedFile;
    if (f == null) return;
    try {
      final stamp = (await f.stat()).modified;
      if (stamp == _sharedStamp) return;
      _sharedStamp = stamp;
      final m = jsonDecode(await f.readAsString());
      if (m is! Map) return;
      final next = m.cast<String, dynamic>();
      if (!desktopMode) {
        // Changé depuis « Clicky partout » : on le garde pour ce compte.
        for (final e in next.entries) {
          if (_shared?[e.key] != e.value) await ClaudeApi.store.setJson('clicky.${e.key}', e.value);
        }
      }
      _shared = next;
      if (!voice) await stopSpeaking();
      await refreshReady();
      notifyListeners();
    } catch (_) {}
  }

  bool get enabled => _opt('enabled', true);

  /// Clicky lit ses réponses à voix haute (sinon : texte seulement).
  bool get voice => _opt('voice', true);

  /// On peut parler à Clicky au micro (sinon : Ctrl + Alt ouvre la saisie).
  bool get mic => _opt('mic', true);

  /// Coupe / remet la voix de Clicky (et se tait tout de suite).
  Future<void> toggleVoice() async {
    if (voice) await stopSpeaking();
    await setOption('voice', !voice);
  }

  bool get follow => _opt('follow', true);

  /// Toujours afficher le curseur bleu (sinon seulement pendant un échange).
  bool get alwaysShow => _opt('show', true);

  /// 'claudecode' (ton abonnement Claude Pro via Claude Code), 'claude'
  /// (clé API) ou 'ollama' (local, gratuit).
  String get provider => _opt('provider', ClaudeCode.supported ? 'claudecode' : 'claude');

  /// Windows : Clicky au-dessus de tout l'écran et de toutes les applis.
  bool get everywhere => _opt('everywhere', true);

  /// Apparence : 'hud' (réacteur animé, fenêtres tête haute) ou 'classic'
  /// (le petit curseur bleu d'origine).
  String get look => _opt('look', 'hud');
  bool get hud => look != 'classic';

  /// Comment Clicky t'appelle (vide : ton prénom de compte Mon Hub).
  String get callName {
    final n = _opt('callName', '').trim();
    if (n.isNotEmpty) return n;
    return (AppSession.instance.current?.name ?? '').split(' ').first;
  }

  bool get greet => _opt('greet', true);
  bool get wakeOn => _opt('wake', false);
  String get ttsVoice => _opt('ttsVoice', '');
  double get ttsRate => _opt('ttsRate', 1.0);
  double get ttsPitch => _opt('ttsPitch', 1.0);

  /// Commencer à parler pendant que la réponse s'écrit.
  bool get narrate => _opt('narrate', true);

  // Modes « prof ».
  bool get slow => _opt('slow', false);
  bool get quizMode => _opt('quiz', false);
  bool get codeMode => _opt('codeMode', true);
  bool get multilang => _opt('multilang', false);
  bool get ocr => _opt('ocr', true);
  bool get privacy => _opt('privacy', true);
  bool get precise => _opt('precise', false);
  bool get stepsMode => _opt('steps', true);
  bool get annotate => _opt('annotate', true);

  /// Recherche sur internet (outil officiel de Claude).
  bool get webSearch => _opt('web', true);

  /// Ctrl + Alt + Maj : dictée dans n'importe quelle appli.
  bool get dictation => _opt('dictation', true);

  /// Clicky peut proposer de cliquer / taper à ta place (après relecture).
  bool get driveOn => _opt('drive', true);

  /// Contrôle du PC : 'ask' (permission à chaque commande), 'auto' (sans
  /// demander, sauf commandes dangereuses) ou 'off'.
  String get pcControl {
    if (!PcControl.supported) return 'off';
    final v = _opt('pc', 'ask');
    return const ['ask', 'auto', 'off'].contains(v) ? v : 'ask';
  }

  /// Journal des connaissances.
  bool get journalOn => _opt('journal', true);

  /// Une mémoire séparée par appli (Clicky partout).
  bool get perApp => _opt('perApp', true);

  /// Clicky bouge tout seul autour du curseur (vivant).
  bool get alive => _opt('alive', true);

  static bool get everywhereSupported => !kIsWeb && Platform.isWindows;

  /// Clicky de l'appli désactivé car « Clicky partout » s'en charge.
  bool get handledElsewhere => !desktopMode && everywhereSupported && everywhere;

  Future<void> setOption(String k, Object v) async {
    if (const ['instant', 'geminiVoice', 'callName'].contains(k)) {
      // La voix et les consignes sont fixées à la connexion : on reconnecte.
      unawaited(_live?.close());
      _live = null;
      _liveDownUntil = null;
    }
    // « Clicky partout » n'écrit jamais dans les préférences (ça écraserait
    // celles de Mon Hub) : seulement dans le fichier partagé.
    if (!desktopMode) await ClaudeApi.store.setJson('clicky.$k', v);
    if (_shared != null || desktopMode) {
      (_shared ??= {})[k] = v;
      await _writeShared();
    }
    _applyVoice();
    await refreshReady();
    notifyListeners();
  }

  /// Clicky a un cerveau (clé Claude, ou Ollama choisi). Tant que ce n'est
  /// pas le cas, il reste complètement invisible et ne fait rien : le reste
  /// de Mon Hub marche exactement pareil sans lui.
  bool ready = false;
  bool _greeted = false;

  Future<bool> refreshReady() async {
    bool r;
    try {
      r = switch (provider) {
        'ollama' => true,
        'claudecode' => await ClaudeCode.find() != null,
        _ => await ClaudeApi.hasKey(),
      };
    } catch (_) {
      r = false;
    }
    final here = desktopMode || !handledElsewhere;
    try {
      voiceOut.geminiKey = await ClaudeApi.store.readSecret('gemini.key') ?? '';
    } catch (_) {}
    // Windows : prépare le micro à l'avance pour ne pas rater le début.
    if (r && enabled && mic && here) {
      ears.warmUp();
      warmUpLive();
    }
    // Mot d'activation (« Clicky »).
    if (r && enabled && mic && here && wakeOn && WakeWord.supported) {
      unawaited(_wake.start());
    } else if (_wake.running) {
      unawaited(_wake.stop());
    }
    if (r != ready) {
      ready = r;
      notifyListeners();
    }
    if (r && enabled && here && bootAt == null) {
      bootAt = DateTime.now();
      notifyListeners();
    }
    if (r && enabled && here && !_greeted) {
      _greeted = true;
      unawaited(_greetOnce());
    }
    if (r && enabled && here) {
      _startPresence();
    } else {
      _presence?.cancel();
      _presence = null;
    }
    return r;
  }

  /// Clicky te salue au premier démarrage de la journée.
  Future<void> _greetOnce() async {
    if (!greet || !voice || !_voicePlatform) return;
    try {
      final saved = await _stateFile.load();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      if (saved['greeted'] == today) return;
      await _stateFile.save({...saved, 'greeted': today});
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 2));
    if (state != ClickyState.idle) return;
    unawaited(ClickyChime.play());
    final mind = ClickyMind.instance;
    try {
      await mind.load();
    } catch (_) {}
    final now = DateTime.now();
    if (!mind.on) return speak(clickyGreeting(callName, now));
    // Il se souvient, et prend des nouvelles.
    final hello = mind.greeting(now: now, name: callName);
    final loop = mind.dueLoops(now).firstOrNull;
    if (loop != null && hello.contains(loop.text)) unawaited(mind.markAsked(loop));
    _set(ClickyState.speaking, status: '', reply: hello);
    await speak(hello);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
    _fadeSoon();
  }

  final _stateFile = JsonFile<Map<String, dynamic>>(
    'clicky-state.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  /// Clicky doit s'afficher et écouter le clavier.
  bool get active => enabled && ready;

  bool get buddyVisible =>
      alwaysShow ||
      _recent ||
      panelOpen ||
      board != null ||
      holo != null ||
      marks.isNotEmpty ||
      state != ClickyState.idle ||
      agentsRunning > 0;

  void moveCursor(Offset p) {
    if (cursor == p) return;
    final old = cursor;
    cursor = p;
    if (old == null || (old - p).distance > 3) {
      final now = DateTime.now();
      // Revenu après une longue absence : nouvelle séance.
      if (now.difference(_lastMove).inMinutes >= 15) _sessionStart = now;
      _lastMove = now;
      // On bouge la souris : Clicky revient tout de suite à côté.
      if (gaze != null && !_gazeHold) {
        gaze = null;
        gazeNote = '';
        notifyListeners();
      }
    }
    if (follow && active && state != ClickyState.pointing && buddyVisible) notifyListeners();
  }

  // ---------- Voix ----------

  late final ClickyEars ears = Whisper.supported
      ? SmartEars(ClickyEars.create(), WhisperEars(), GeminiEars(() => voiceOut.geminiKey), () => micEngine)
      : ClickyEars.create();

  /// Reconnaissance vocale : 'auto' (Windows, et Whisper dès que Windows ne
  /// marche pas), 'windows' ou 'whisper' (sur le PC, sans internet).
  String get micEngine {
    final v = _opt('micEngine', 'auto');
    return const ['auto', 'windows', 'whisper', 'gemini'].contains(v) ? v : 'auto';
  }
  final voiceOut = ClickyVoice();
  late final WakeWord _wake = WakeWord(_onWake);

  bool get _voicePlatform => ClickyEars.supported;

  /// Une seule voix : celle de Gemini (clé gratuite AI Studio). Les voix de
  /// Windows et de Microsoft (Edge) ont été retirées.
  String get geminiVoice => _opt('geminiVoice', 'Charon');

  /// Clé Gemini (gratuite), gardée chiffrée.
  Future<void> setGeminiKey(String? key) async {
    await ClaudeApi.store.writeSecret(
      'gemini.key',
      key == null || key.trim().isEmpty ? null : key.trim(),
    );
    voiceOut.geminiKey = key?.trim() ?? '';
  }

  void _applyVoice({String? lang}) {
    voiceOut.geminiVoice = geminiVoice;
    voiceOut
      ..rate = ttsRate
      ..pitch = ttsPitch
      ..language = lang ?? voiceOut.language;
  }

  /// Dernier souci de micro (affiché dans la boîte, avec un bouton pour
  /// ouvrir le bon réglage).
  EarsProblem? micProblem;

  Timer? _autoSend;

  /// « Clicky ! » entendu : il écoute ta question.
  void _onWake() {
    if (!active || state != ClickyState.idle) {
      _wake.resume();
      return;
    }
    unawaited(ClickyChime.play());
    _recent = true;
    unawaited(startListening());
  }

  /// La dictée (Ctrl + Alt + Maj) : le texte sera tapé dans cette appli.
  bool _dictating = false;
  Object? _dictationTarget;

  Future<void> startListening({bool dictate = false}) async {
    await stopSpeaking();
    if (state == ClickyState.thinking || state == ClickyState.listening) return;
    if (!mic) {
      // Micro désactivé : on écrit à la place.
      openPanel();
      return;
    }
    if (!_voicePlatform) {
      openPanel();
      _set(ClickyState.idle, status: 'Micro indisponible ici : écris ta question.');
      return;
    }
    _wake.pause();
    _dictating = dictate && dictation && DriveRunner.supported;
    _dictationTarget = _dictating ? Win.foreground().address : null;
    transcript = '';
    target = null;
    micProblem = null;
    clearMarks();
    levels.fillRange(0, levels.length, 0);
    _set(
      ClickyState.listening,
      status: _dictating ? 'Dictée : parle, je tape le texte.' : '',
      reply: '',
    );
    // Réponse instantanée (Gemini Live, comme JARVIS) : le micro part en
    // direct, la réponse revient en voix tout de suite.
    if (!_dictating && liveReady) {
      if (await _liveListen()) return;
      // Tu as déjà lâché pendant l'essai de connexion : rien à écouter.
      if (state != ClickyState.listening) return;
    }
    final starting = ears.start(
      onText: (t) {
        if (state != ClickyState.listening) return;
        transcript = t;
        _autoSend?.cancel();
        notifyListeners();
      },
      onLevel: (l) {
        if (state != ClickyState.listening) return;
        levels.setRange(0, levels.length - 1, levels.skip(1));
        levels[levels.length - 1] = l;
        notifyListeners();
      },
      onProblem: _micFailed,
      onFinalPhrase: () {
        // Sans Ctrl + Alt maintenus (bouton micro, mot d'activation) : on
        // envoie après un petit silence.
        if (_holding || state != ClickyState.listening) return;
        _autoSend?.cancel();
        _autoSend = Timer(const Duration(milliseconds: 1800), () {
          if (!_holding && state == ClickyState.listening) unawaited(stopListening());
        });
      },
    );
    _micStarting = starting;
    final problem = await starting;
    _micStarting = null;
    if (problem == null) return;
    // Panne de lancement (PowerShell bloqué, planté…) : Clicky se répare
    // tout seul une fois, au lieu de juste afficher l'erreur.
    if (isLaunchProblem(problem) && !_autoRepaired) {
      _autoRepaired = true;
      await repairMic(auto: true);
      return;
    }
    _micFailed(problem);
  }

  /// Clicky a déjà tenté de se réparer tout seul depuis le démarrage.
  bool _autoRepaired = false;

  /// Une réparation est en cours.
  bool repairing = false;

  /// « Clicky répare » : remet le micro à zéro, essaie toutes les façons de
  /// le lancer et vérifie qu'il s'ouvre. S'il reste bloqué, l'IA explique
  /// quoi faire en sachant ce qui a déjà été essayé.
  Future<void> repairMic({bool auto = false}) async {
    if (repairing || !_voicePlatform) return;
    repairing = true;
    final before = micProblem;
    micProblem = null;
    openPanel();
    _set(
      ClickyState.thinking,
      status: auto ? 'Le micro a calé, je le répare…' : 'Je répare le micro…',
      reply: '',
    );
    EarsRepair r;
    try {
      r = await ears.repair();
    } catch (e) {
      r = EarsRepair(
        problem: EarsProblem('La réparation du micro a échoué : $e', code: 'repair'),
        steps: const [],
      );
    } finally {
      repairing = false;
    }
    lastRepair = r;
    if (r.ok) {
      _set(ClickyState.idle, status: 'Micro réparé ✓', reply: '');
      await startListening();
      return;
    }
    micProblem = r.problem;
    _set(ClickyState.idle, status: '', reply: '');
    // Réparation manuelle : l'IA explique la panne. Automatique : on
    // affiche le souci (bouton « Clicky répare » pour aller plus loin).
    if (!auto) {
      await _askAi(
        micRepairPrompt(before ?? r.problem!, r, system: kIsWeb ? '' : Platform.operatingSystem),
        shown: 'Répare mon micro',
        withScreen: false,
      );
    }
  }

  /// Le micro est en train de démarrer (premier lancement : 1 à 2 s).
  Future<EarsProblem?>? _micStarting;

  void _micFailed(EarsProblem p) {
    micProblem = p;
    panelOpen = true;
    onInteractive?.call(true);
    _set(ClickyState.idle, status: '', reply: '');
  }

  Future<void> stopListening({bool send = true}) async {
    if (state != ClickyState.listening) return;
    _autoSend?.cancel();
    if (_liveMic != null) return _liveStop(send: send);
    if (!send) {
      await ears.cancel();
      _dictating = false;
      _set(ClickyState.idle, status: '');
      _wake.resume();
      return;
    }
    _set(ClickyState.listening, status: 'Je finis d\'écouter…');
    final starting = _micStarting;
    if (starting != null && await starting != null) return;
    final heard = await ears.stop();
    if (state != ClickyState.listening) return;
    if (heard.trim().isNotEmpty) transcript = heard.trim();
    if (_dictating) return _finishDictation();
    await _sendTranscript();
  }

  /// Dictée : tape le texte dans l'appli où tu étais (si elle a toujours
  /// le focus), sinon le montre pour le copier.
  Future<void> _finishDictation() async {
    _dictating = false;
    final t = transcript.trim();
    if (t.isEmpty) {
      _set(ClickyState.idle, status: 'Je n\'ai rien entendu.');
      _fadeSoon();
      _wake.resume();
      return;
    }
    final same = DriveRunner.supported && Win.foreground().address == _dictationTarget;
    final sensitive = DriveRunner.supported && isSensitiveTitle(Win.foregroundTitle());
    if (same && !sensitive) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      Win.releaseModifiers();
      Win.typeText(t);
      _set(ClickyState.idle, status: 'Dictée tapée ✓', reply: '');
    } else {
      await Clipboard.setData(ClipboardData(text: t));
      _set(
        ClickyState.idle,
        status: sensitive
            ? 'Fenêtre sensible : je n\'ai pas tapé le texte, il est copié (Ctrl + V).'
            : 'La fenêtre a changé : le texte est copié, colle-le avec Ctrl + V.',
        reply: t,
      );
    }
    _fadeSoon();
    _wake.resume();
  }

  Future<void> _sendTranscript() async {
    if (state != ClickyState.listening) return;
    final t = transcript.trim();
    final e = ears;
    final failed = e is SmartEars && e.active is RecordingEars ? (e.active as RecordingEars).lastError : null;
    if (t.isEmpty && failed != null) {
      // La transcription (Whisper / Gemini) a échoué : on dit pourquoi.
      _micFailed(EarsProblem('Je n\'ai pas pu transcrire ce que tu as dit : $failed', code: 'transcription'));
      _wake.resume();
      return;
    }
    if (t.isEmpty) {
      _set(
        ClickyState.idle,
        status:
            'Je n\'ai rien entendu. Parle un peu plus fort, ou teste ton micro '
            'dans Réglages → Clicky.',
      );
      _fadeSoon();
      _wake.resume();
      return;
    }
    await ask(t);
  }

  /// Secours Windows : la dictée de Windows (Win + H) écrit dans la zone
  /// de texte de Clicky.
  final inputFocus = FocusNode();
  Future<void> windowsDictation() async {
    micProblem = null;
    openPanel();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    inputFocus.requestFocus();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!kIsWeb && Platform.isWindows) {
      try {
        Win.voiceTyping();
      } catch (_) {}
    }
  }

  /// Lit un texte à voix haute. [force] : même si la voix de Clicky est
  /// coupée (les briefings sont toujours lus).
  Future<void> speak(String text, {bool force = false}) async {
    if ((!voice && !force) || !_voicePlatform || text.isEmpty) return;
    _applyVoice();
    _wake.pause();
    try {
      await voiceOut.say(text);
    } catch (_) {}
    if (state != ClickyState.listening) _wake.resume();
  }

  Future<void> stopSpeaking() async {
    voiceOut.stop();
  }

  /// Arrête tout : la réponse en cours, la voix, l'écoute (Échap, « stop »).
  Future<void> cancel() async {
    _askId++;
    ClaudeCode.cancelAll();
    await stopSpeaking();
    // Gemini Live : on coupe la voix et on ignore la fin de la réponse.
    _livePlayer.stop();
    if (_liveTurn) _liveIgnore = true;
    if (state == ClickyState.listening) await stopListening(send: false);
    steps = const [];
    drawing = false;
    target = null;
    clearMarks();
    _set(ClickyState.idle, status: 'Arrêté.', reply: reply);
    _fadeSoon();
    _wake.resume();
  }

  // ---------- Clavier : maintenir Ctrl + Alt ----------

  bool _holding = false;
  bool _cancelled = false;
  bool _holdDictate = false;
  DateTime? _holdStart;
  Timer? _holdTimer;

  /// Appelé quand Ctrl + Alt (sans AltGr) est enfoncé ou relâché, ou quand
  /// une autre touche est tapée pendant l'appui ([other]). [dictate] : Maj
  /// est aussi enfoncé (Ctrl + Alt + Maj = dictée).
  void hotkey({required bool down, bool other = false, bool dictate = false}) {
    if (!active) return;
    if (_holding && other) {
      // Ctrl + Alt + une touche = un raccourci clavier, pas Clicky.
      _cancelled = true;
      _holdTimer?.cancel();
      if (state == ClickyState.listening) unawaited(stopListening(send: false));
      return;
    }
    if (_holding && dictate) _holdDictate = true;
    if (down && !_holding) {
      _holding = true;
      _cancelled = false;
      _holdDictate = dictate;
      _holdStart = DateTime.now();
      _recent = true;
      // Appui long = on parle. Appui court = on écrit.
      _holdTimer = Timer(const Duration(milliseconds: 350), () {
        if (_holding && !_cancelled) unawaited(startListening(dictate: _holdDictate));
      });
    } else if (!down && _holding) {
      _holding = false;
      _holdTimer?.cancel();
      if (_cancelled) return;
      final short =
          DateTime.now().difference(_holdStart ?? DateTime.now()) <
          const Duration(milliseconds: 350);
      if (short) {
        panelOpen ? closePanel() : openPanel();
      } else {
        unawaited(stopListening());
      }
    }
  }

  /// Échap : arrête la réponse, puis ferme la boîte, puis le tableau.
  void escape() {
    if (state == ClickyState.thinking || voiceOut.speaking || steps.isNotEmpty) {
      unawaited(cancel());
    } else if (boxOpen) {
      closeBox();
    } else if (board != null) {
      closeBoard();
    } else {
      clearMarks();
    }
  }

  static final _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.altGraph,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  /// Clavier de l'appli (quand Clicky vit dans la fenêtre de Mon Hub).
  bool onKey(KeyEvent e) {
    try {
      return _onKey(e);
    } catch (_) {
      return false; // Clicky ne doit jamais gêner le clavier de l'appli
    }
  }

  bool _onKey(KeyEvent e) {
    if (!active || handledElsewhere) return false;
    final k = HardwareKeyboard.instance;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      escape();
      return false;
    }
    // AltGr (claviers français : @, €, #…) envoie aussi Ctrl + Alt : on
    // l'ignore pour ne pas ouvrir Clicky en tapant une adresse mail.
    final altGr =
        k.physicalKeysPressed.contains(PhysicalKeyboardKey.altRight) ||
        k.logicalKeysPressed.contains(LogicalKeyboardKey.altGraph);
    final both = k.isControlPressed && k.isAltPressed && !altGr;
    if (_holding && e is KeyDownEvent && !_modifiers.contains(e.logicalKey)) {
      hotkey(down: true, other: true);
    } else if (both && !_holding && e is KeyDownEvent) {
      hotkey(down: true, dictate: k.isShiftPressed);
    } else if (_holding && both && k.isShiftPressed) {
      hotkey(down: true, dictate: true);
    } else if (_holding && !both) {
      hotkey(down: false);
    }
    return false;
  }

  // ---------- Boîte de texte ----------

  /// La boîte de texte est ouverte : saisie, écoute, réflexion, réponse
  /// (elle se referme toute seule quelques secondes après la réponse).
  bool get boxOpen =>
      panelOpen ||
      state != ClickyState.idle ||
      reply.isNotEmpty ||
      status.isNotEmpty ||
      micProblem != null ||
      showHistory;

  /// Ferme la boîte (et efface la réponse).
  void closeBox() {
    _keepReply = false;
    reply = '';
    status = '';
    micProblem = null;
    showHistory = false;
    steps = const [];
    closePanel();
  }

  void openPanel() {
    panelOpen = true;
    _recent = true;
    onInteractive?.call(true);
    notifyListeners();
  }

  void closePanel() {
    panelOpen = false;
    showHistory = false;
    unawaited(stopSpeaking());
    if (state == ClickyState.listening) unawaited(stopListening(send: false));
    if (state == ClickyState.speaking || state == ClickyState.pointing) {
      state = ClickyState.idle;
    }
    target = null;
    onInteractive?.call(board != null);
    _fadeSoon();
    notifyListeners();
  }

  /// Mode discret : Clicky disparaît 1 s après la fin de l'échange.
  void _fadeSoon() {
    _fade?.cancel();
    _fade = Timer(const Duration(seconds: 1), () {
      if (state == ClickyState.idle && !panelOpen) {
        _recent = false;
        notifyListeners();
      }
    });
    // La bulle de réponse s'efface après quelques secondes (pas pendant une
    // leçon en plusieurs étapes).
    _clear?.cancel();
    _clear = Timer(Duration(seconds: slow ? 14 : 8), () {
      if (state == ClickyState.idle &&
          !panelOpen &&
          steps.isEmpty &&
          !showHistory &&
          !_keepReply &&
          (reply.isNotEmpty || status.isNotEmpty)) {
        reply = '';
        status = '';
        notifyListeners();
      }
    });
  }

  Timer? _clear;

  /// La réponse reste affichée jusqu'à ce qu'on ferme la boîte (topos).
  bool _keepReply = false;

  /// Affiche un topo (matin / soir) en grand, le lit et le range dans
  /// l'historique.
  Future<void> presentTopo(String title, String text, {bool speakIt = true}) async {
    _keepReply = true;
    steps = const [];
    target = null;
    _recent = true;
    _set(ClickyState.speaking, status: title.toUpperCase(), reply: text);
    unawaited(ClickyChime.play());
    final id = 'topo-${DateTime.now().millisecondsSinceEpoch}';
    unawaited(
      history
          .add(id, ChatMsg(mine: true, text: title))
          .then((_) => history.add(id, ChatMsg(mine: false, text: text)))
          .then((_) => history.rename(id, '$title · ${dayLabel(DateTime.now())}')),
    );
    if (speakIt) await speak(withoutEmoji(text), force: true);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
  }

  // ---------- Présence (sa « conscience » qui bouge) ----------

  Timer? _presence;
  bool _gazeHold = false;
  Timer? _gazeEnd;
  DateTime _nextGlance = DateTime.now().add(const Duration(seconds: 40));
  DateTime _nextNotice = DateTime.now().add(const Duration(minutes: 6));
  bool _noticing = false;

  /// Pour les regards autour (mode « partout ») : là où il peut aller voir.
  /// Donné par Clicky partout (coordonnées de l'écran).
  List<Offset> Function()? lookSpots;

  /// L'appli au premier plan est en plein écran (jeu, vidéo) : il se fait
  /// discret.
  bool Function()? fullscreenNow;

  /// Contexte pour ses pensées (fenêtre, musique, prochain cours…), relu
  /// toutes les 5 minutes.
  Map<String, Object?> _ctx = const {};
  DateTime? _ctxAt;

  void _startPresence() {
    if (_presence != null) return;
    _presence = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_presenceTick()));
  }

  bool get _calm =>
      state == ClickyState.idle && !panelOpen && board == null && holo == null && marks.isEmpty && target == null && !_keepReply;

  Future<void> _presenceTick() async {
    final mind = ClickyMind.instance;
    if (!active || !mind.on || !_calm || (fullscreenNow?.call() ?? false)) return;
    if (desktopMode && DriveRunner.supported && privacy && isSensitiveTitle(Win.foregroundTitle())) return;
    final now = DateTime.now();
    final idle = now.difference(_lastMove);
    // Une remarque spontanée sur l'écran (on est là, souris qui bouge).
    if (mind.notice && idle.inSeconds < 90 && now.isAfter(_nextNotice) && !_noticing) {
      _nextNotice = now.add(Duration(minutes: 22 + math.Random().nextInt(18)));
      unawaited(noticeSomething());
      return;
    }
    // Souris immobile : il part regarder autour, comme quelqu'un d'autre.
    if (mind.wander && gaze == null && idle.inSeconds >= 20 && idle.inMinutes < 30 && now.isAfter(_nextGlance)) {
      _nextGlance = now.add(Duration(seconds: 45 + math.Random().nextInt(70)));
      final spots = lookSpots?.call() ?? const <Offset>[];
      final base = cursor;
      if (spots.isEmpty && base == null) return;
      final r = math.Random();
      final at = spots.isNotEmpty
          ? spots[r.nextInt(spots.length)]
          : base! + Offset(r.nextDouble() * 260 - 130, r.nextDouble() * 180 - 110);
      // Une fois sur trois, il pense à voix haute (ou en bulle).
      String note = '';
      if (r.nextInt(3) == 0) {
        await _refreshCtx(now);
        note = mind.thought(_ctx, now: now) ?? '';
      }
      glance(at, note: note, hold: Duration(milliseconds: 2600 + r.nextInt(2400)));
      if (note.isNotEmpty && voice && await mind.spendVoice()) unawaited(speak(note));
    }
  }

  Future<void> _refreshCtx(DateTime now) async {
    if (_ctxAt != null && now.difference(_ctxAt!).inMinutes < 5) return;
    _ctxAt = now;
    Future<Object?> call(String name, [Map<String, dynamic> args = const {}]) async {
      try {
        return await _tools.where((t) => t.name == name).firstOrNull?.run(args);
      } catch (_) {
        return null;
      }
    }

    final ctx = <String, Object?>{
      'session_min': now.difference(_sessionStart).inMinutes,
      if (desktopMode && DriveRunner.supported) 'fenetre': Win.foregroundTitle(),
    };
    final music = await call('musique_en_cours');
    if (music is Map && music['en_lecture'] == true) {
      ctx['musique'] = music['titre'];
      ctx['artiste'] = music['artiste'];
    }
    final events = await call('agenda_lire', {'jours': 1});
    if (events is List) {
      for (final e in events) {
        if (e is! Map || e['annule'] == true) continue;
        final at = e['debut'] is DateTime ? e['debut'] as DateTime : DateTime.tryParse('${e['debut']}');
        if (at == null || !at.isAfter(now)) continue;
        ctx['cours'] = e['titre'];
        ctx['cours_min'] = at.difference(now).inMinutes;
        break;
      }
    }
    final hw = await call('ecole_devoirs');
    if (hw is List) {
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      for (final h in hw) {
        if (h is! Map || h['controle'] != true) continue;
        final d = h['pour_le'] is DateTime ? h['pour_le'] as DateTime : DateTime.tryParse('${h['pour_le']}');
        if (d != null && d.year == tomorrow.year && d.month == tomorrow.month && d.day == tomorrow.day) {
          ctx['controle_demain'] = h['matiere'];
        }
      }
    }
    _ctx = ctx;
  }

  /// Clicky va regarder quelque part tout seul (puis revient).
  void glance(Offset at, {String note = '', Duration hold = const Duration(seconds: 3)}) {
    gaze = at;
    gazeNote = note;
    _gazeHold = true;
    _recent = true;
    notifyListeners();
    // Le temps de partir : un petit mouvement de souris ne le rappelle pas.
    Timer(const Duration(milliseconds: 900), () => _gazeHold = false);
    _gazeEnd?.cancel();
    _gazeEnd = Timer(hold + Duration(milliseconds: note.length * 45), () {
      if (gaze == at) {
        gaze = null;
        gazeNote = '';
        notifyListeners();
        _fadeSoon();
      }
    });
  }

  /// Une pensée à partager (rappel de l'assistant…) : bulle à côté de lui,
  /// et à voix haute si la voix est là (4 fois par jour au plus).
  Future<void> think(String text, {bool aloud = true}) async {
    if (!active || text.trim().isEmpty) return;
    if (handledElsewhere) {
      await ClickyDesktop.send('think64 ${base64Encode(utf8.encode(text))}');
      return;
    }
    if (!_calm) return;
    final at = cursor;
    if (at == null) return;
    glance(at + const Offset(40, -30), note: text, hold: const Duration(seconds: 5));
    if (aloud && voice && await ClickyMind.instance.spendVoice()) unawaited(speak(withoutEmoji(text)));
  }

  /// Applis où il ne regarde jamais de lui-même (messages, mails, comptes).
  static final privateApp = RegExp(
    r'discord|whatsapp|messenger|instagram|snapchat|telegram|signal|teams|gmail|outlook|mail|courrier|'
    r'mon hub|banque|bank|paypal|lydia|mot de passe|password|bitwarden|1password|ecole ?directe|pronote',
  );

  /// Il remarque quelque chose à l'écran, vole dessus et en dit un mot
  /// (Gemini seulement, jamais Claude ; 8 fois par jour au plus).
  Future<void> noticeSomething({bool force = false}) async {
    final mind = ClickyMind.instance;
    // C'est Clicky partout (sur tout l'écran) qui regarde.
    if (handledElsewhere) {
      await ClickyDesktop.send('notice');
      return;
    }
    if (_noticing || (!force && (!mind.notice || !_calm))) return;
    // Vie privée : jamais de lui-même sur Mon Hub (tes messages y sont), ni
    // quand une messagerie, tes mails ou ta banque sont au premier plan.
    if (!force) {
      if (!desktopMode || !DriveRunner.supported) return;
      if (privateApp.hasMatch(Win.foregroundTitle().toLowerCase())) return;
    }
    if (!await AiText.hasGemini()) return;
    if (!force && !await mind.spendNotice()) return;
    _noticing = true;
    try {
      final (shots, _, hidden) = await _look();
      if (hidden || shots.isEmpty) return;
      // L'écran où est la souris.
      final cur = cursor;
      final shot = shots.firstWhere(
        (s) => cur == null || Rect.fromLTWH(s.origin.dx, s.origin.dy, s.width * s.logicalPerPx, s.height * s.logicalPerPx).contains(cur),
        orElse: () => shots.first,
      );
      final r = await AiText.ask(
        ClickyMind.noticePrompt(name: callName, mood: mind.moodLabel(DateTime.now())),
        system: 'Tu es Clicky, un compagnon curieux et sympa. Tu réponds en français, très court.',
        images: [shot.png64],
        geminiOnly: true,
      );
      if (!force && !_calm) return;
      final (text, p, _, _) = parsePoint(r);
      final say = stripClickyTags(text).trim();
      if (p == null || say.isEmpty || say.length > 90) return;
      target = shot.toLayer(p);
      targetLabel = say;
      _set(ClickyState.pointing, status: '', reply: '');
      if (voice && await mind.spendVoice()) {
        await speak(say);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 3200));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (state == ClickyState.pointing && targetLabel == say) {
        target = null;
        targetLabel = '';
        _set(ClickyState.idle);
        _fadeSoon();
      }
    } catch (_) {
    } finally {
      _noticing = false;
    }
  }

  /// Affiche un petit message dans la boîte.
  void showStatus(String s) {
    status = s;
    panelOpen = true;
    onInteractive?.call(true);
    notifyListeners();
  }

  void _set(ClickyState s, {String? status, String? reply}) {
    state = s;
    if (status != null) this.status = status;
    if (reply != null) this.reply = reply;
    if (s != ClickyState.idle) {
      _recent = true;
      _clear?.cancel();
    }
    notifyListeners();
  }

  // ---------- Historique (une conversation par appli) ----------

  final history = ChatHistory.clicky;

  /// Historique ouvert dans la boîte.
  bool showHistory = false;

  void toggleHistory() {
    showHistory = !showHistory;
    if (showHistory) {
      panelOpen = true;
      onInteractive?.call(true);
      unawaited(history.load().then((_) => notifyListeners()));
    }
    notifyListeners();
  }

  /// Appli au premier plan (Clicky partout) : chaque appli a sa mémoire.
  String currentApp = '';
  final _threadFor = <String, String>{};

  String get _appKey => perApp && desktopMode ? currentApp : '';

  /// Conversation en cours pour l'appli au premier plan.
  String get threadId {
    final key = _appKey;
    final id = _threadFor[key];
    final t = history.byId(id);
    // Plus de 45 minutes sans échange : nouvelle conversation.
    bool fresh(ChatThread x) => DateTime.now().difference(x.updated).inMinutes < 45;
    if (id != null && (t == null || fresh(t))) return id;
    // Après un redémarrage : on reprend la conversation récente de cette appli.
    final recent = history.threads.where((x) => x.app == key && fresh(x)).firstOrNull;
    return _threadFor[key] = recent?.id ?? ChatThread.newId();
  }

  /// Repart de zéro (« nouvelle conversation »).
  void newConversation() {
    _threadFor[_appKey] = ChatThread.newId();
    steps = const [];
    showHistory = false;
    _set(ClickyState.idle, status: 'Nouvelle conversation.', reply: '');
    _fadeSoon();
  }

  /// Reprend une conversation de l'historique.
  void continueThread(ChatThread t) {
    _threadFor[_appKey] = t.id;
    showHistory = false;
    final last = t.messages.where((m) => !m.mine).lastOrNull;
    reply = last?.text ?? '';
    transcript = t.messages.where((m) => m.mine).lastOrNull?.text ?? '';
    panelOpen = true;
    onInteractive?.call(true);
    _set(ClickyState.idle, status: 'Conversation reprise : continue quand tu veux.');
  }

  /// Derniers échanges de la conversation en cours (texte seulement).
  List<(String, String)> _memory() {
    final t = history.byId(_threadFor[_appKey]);
    if (t == null) return const [];
    final out = <(String, String)>[];
    String? q;
    for (final m in t.messages) {
      if (m.mine) {
        q = m.text;
      } else if (q != null) {
        out.add((q, [m.text, ?m.note].join(' ')));
        q = null;
      }
    }
    return out.length > 8 ? out.sublist(out.length - 8) : out;
  }

  // ---------- Leçon en plusieurs étapes ----------

  /// Étapes de la leçon en cours (vide si la réponse tient en une fois).
  List<String> steps = const [];
  int stepIndex = 0;
  List<ClickyShot> _stepShots = const [];

  bool get hasNextStep => steps.isNotEmpty && stepIndex < steps.length - 1;

  /// Étape suivante (« suivant »), sans redemander à l'IA.
  Future<void> nextStep() async {
    if (!hasNextStep) {
      steps = const [];
      _set(ClickyState.idle, status: 'La leçon est terminée. Bravo !');
      _fadeSoon();
      return;
    }
    stepIndex++;
    await _present(steps[stepIndex], _stepShots, step: true);
  }

  // ---------- Documents joints ----------

  final docs = <ClickyDoc>[];

  Future<void> attachDocuments() async {
    try {
      final picked = await ClickyDoc.pick();
      if (picked.isEmpty) return;
      docs.addAll(picked);
      _set(
        state,
        status:
            '${picked.length == 1 ? '« ${picked.first.name} » est joint' : '${picked.length} documents joints'} : '
            'pose ta question.',
      );
      openPanel();
    } catch (e) {
      _set(state, status: '$e');
    }
  }

  void removeDoc(ClickyDoc d) {
    docs.remove(d);
    notifyListeners();
  }

  // ---------- Question → IA ----------

  /// Capture de la fenêtre de Mon Hub (Clicky dans l'appli).
  Future<List<ClickyShot>> _captureApp() async {
    try {
      final b = shotKey.currentContext?.findRenderObject();
      if (b is! RenderRepaintBoundary) return const [];
      final size = b.size;
      if (size.isEmpty) return const [];
      final ratio = math.min(1.0, 1280 / math.max(size.width, size.height));
      final img = await b.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null) return const [];
      return [
        ClickyShot(
          png64: base64Encode(data.buffer.asUint8List()),
          label: 'fenêtre de Mon Hub',
          width: w,
          height: h,
          logicalPerPx: 1 / ratio,
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Actions des modules de Mon Hub (dans l'appli).
  List<HubTool> get hubTools => _tools;

  List<HubTool> get _tools {
    final local = localTools;
    final names = {for (final t in local) t.name};
    return [
      ...[
        ...toolsOverride?.call() ??
            [for (final m in hub?.enabled ?? const <HubModule>[]) ...m.tools],
        if (toolsOverride == null) ...McpTools.cached,
      ].where((t) => !names.contains(t.name)),
      ...local,
    ];
  }

  /// Outils de Clicky lui-même (exécutés dans ce programme) : dépannage et
  /// contrôle du PC. Aussi servis à Claude Code par le pont local.
  List<HubTool> get localTools => [
    if (_voicePlatform) ...repairTools,
    if (pcControl != 'off') ...PcControl.tools(),
    // L'assistant personnel vit dans Mon Hub (qui a les modules).
    if (hub != null && toolsOverride == null) ...Assistant.instance.tools,
  ];

  /// Les outils de dépannage de Clicky : l'IA peut voir ce qui ne va pas
  /// et réparer le micro elle-même (« mon micro ne marche pas »).
  List<HubTool> get repairTools => [
    HubTool(
      name: 'clicky_diagnostic',
      description:
          'Diagnostic de Clicky : état du micro (dernière panne, façon de lancer la reconnaissance '
          'vocale), du mot d\'activation, de la voix et du cerveau (Claude). À utiliser quand la '
          'personne dit que Clicky, le micro ou la voix ne marche pas.',
      run: (_) async => diagnostic(),
    ),
    HubTool(
      name: 'clicky_reparer_micro',
      description:
          'Répare le micro de Clicky : arrête l\'écoute bloquée, relance la reconnaissance vocale en '
          'essayant toutes les façons de la démarrer, et vérifie que le micro s\'ouvre. Renvoie ce '
          'qui a été fait et le souci qui reste (avec le réglage à ouvrir).',
      run: (_) async {
        final r = await ears.repair();
        lastRepair = r;
        micProblem = r.problem;
        notifyListeners();
        return {
          'repare': r.ok,
          'etapes': r.steps,
          if (r.problem != null) 'souci': r.problem!.message,
          if (r.problem?.code.isNotEmpty ?? false) 'code': r.problem!.code,
          if (r.problem?.fixUri != null) 'reglage': '${r.problem!.fixLabel} (${r.problem!.fixUri})',
        };
      },
    ),
  ];

  /// Dernière réparation du micro (pour le diagnostic).
  EarsRepair? lastRepair;

  /// État de Clicky, lisible par l'IA (outil clicky_diagnostic).
  Map<String, Object?> diagnostic() {
    final e = ears;
    return {
      'version': appVersion,
      'systeme': kIsWeb ? 'web' : Platform.operatingSystem,
      'micro_active': mic,
      'micro_panne': micProblem?.message,
      'micro_code': micProblem?.code,
      if (e is SmartEars) 'micro_moteur': e.active is RecordingEars ? (e.active as RecordingEars).name : 'Windows',
      if (e is SmartEars && e.active is RecordingEars && (e.active as RecordingEars).lastError != null)
        'micro_derniere_erreur': (e.active as RecordingEars).lastError,
      if (e is SmartEars && e.windows is WindowsEars) 'micro_lancement': (e.windows as WindowsEars).launch.label,
      'micro_reglage': micEngine,
      'micro_langue': e.language,
      'derniere_reparation': lastRepair == null
          ? null
          : {'reussie': lastRepair!.ok, 'etapes': lastRepair!.steps},
      'mot_activation': _wake.running,
      'voix': voice,
      'cerveau': provider,
      'etat': state.name,
      'dernieres_erreurs': () {
        final log = ErrorLog.read();
        return log.length > 2500 ? log.substring(log.length - 2500) : log;
      }(),
    };
  }

  String _system(
    List<ClickyShot> shots, {
    bool agent = false,
    String foreground = '',
    bool hiddenScreen = false,
  }) {
    final modules = hub?.enabled ?? const <HubModule>[];
    final now = DateTime.now();
    final where = hiddenScreen
        ? 'Pas de capture d\'écran cette fois : une fenêtre sensible (mots de passe, banque…) est ouverte, par sécurité tu ne la vois pas.'
        : shots.isEmpty && !agent
        ? 'Pas de capture d\'écran pour cette question (question générale) : réponds directement, sans parler de l\'écran.'
        : desktopMode
        ? 'Tu vois une capture de chaque écran de l\'ordinateur (toutes les applis, pas seulement Mon Hub).'
        : 'Tu vois une capture de la fenêtre de l\'appli Mon Hub.';
    final screens = [
      for (var i = 0; i < shots.length; i++)
        'Image ${i + 1} = écran ${i + 1} (${shots[i].label}, ${shots[i].width} × ${shots[i].height} pixels)',
    ].join(' ; ');
    final base =
        '''
Tu es Clicky, un compagnon IA qui vit à côté du curseur de la personne, dans « Mon Hub », l'appli personnelle d'un·e élève (emploi du temps, École Directe, mails, Discord, Instagram, Roblox, livres, Google Drive…). $where
${modules.isEmpty ? '' : 'Modules de Mon Hub : ${modules.map((m) => '${m.name} (${m.description})').join(' ; ')}.'}
${foreground.isEmpty ? '' : 'Fenêtre au premier plan : « $foreground ».'}
Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.
${clickyPersona(callName)}
${ClickyMind.instance.promptBlock(name: callName)}
${_facts.isEmpty ? '' : 'Ce que tu sais de la personne (sa mémoire, à utiliser naturellement) :\n${_facts.map((f) => '- $f').join('\n')}'}
${_voicePlatform ? 'Si la personne dit que tu ne l\'entends pas, que le micro ou Clicky ne marche pas : lance clicky_diagnostic, puis clicky_reparer_micro, et dis-lui en une phrase ce qui a été réparé ou le réglage précis à ouvrir.\n' : ''}${pcControl != 'off' ? '${PcControl.guide}\n' : ''}Le Carnet (outils carnet_…) : « retiens que… » → carnet_memoire ; « note ça », une idée en passant → carnet_idees ; tâches et notes → carnet_taches_notes ; « j'ai dépensé… » → carnet_budget ; sport, jeux, poèmes, météo et tenue, bilan du soir, protocoles, presse-papier, notification sur le téléphone : outils carnet_ correspondants.
Google Docs (outils doc_…, le vrai Google Docs de son Drive, ouvert dans Mon Hub) : « écris-moi un exposé / une lettre / une fiche sur… » → doc_creer (texte complet et bien structuré en Markdown, il s'ouvre à l'écran) ; « ouvre un document » → doc_nouveau ou doc_ouvrir ; relire ou compléter → doc_lire, doc_ecrire ; en Word ou PDF sur le PC → doc_exporter.
Les révisions (outils revision_…) : « fais-moi des cartes sur… », « transforme mon cours en fiches » → revision_generer ou revision_ajouter_cartes ; « interroge-moi », « quiz », « minuteur » → revision_lancer ; « organise mes révisions avant le contrôle » → revision_planifier (montre d'abord le plan) ; revision_paquets pour la série et ce qu'il reste à revoir. Pendant un devoir noté, aide à comprendre sans faire le travail à sa place.
Ranger : « range mes téléchargements / mon bureau / mon Drive » → pc_ranger_apercu ou drive_ranger_apercu, dis en une phrase ce qui va bouger, puis pc_ranger ou drive_ranger ; « annule le rangement » → pc_ranger_annuler ou drive_ranger_annuler.''';
    if (agent) {
      return '''$base

Tu travailles en arrière-plan comme agent : fais la tâche demandée jusqu'au bout avec les actions disponibles (lire l'agenda, les notes, les devoirs, les messages, chercher dans Drive, envoyer un message…). Les actions qui envoient ou modifient quelque chose demandent la permission. Termine par un compte rendu en français de 1 à 5 phrases simples, lisible à voix haute, sans markdown.''';
    }
    final code = codeMode && isCodeEditorTitle(foreground);
    final shotsNote = shots.length > 1 ? ':screenN' : '';
    return '''$base

Ta réponse est lue à voix haute :
- ${multilang ? 'réponds dans la langue de la question (français par défaut)' : 'réponds en français'}, comme à l'oral, clair et précis, en 1 à 4 phrases courtes ;
- pas de markdown, pas de listes à puces, pas d'émojis ;
- si on te demande d'expliquer quelque chose (un devoir, une notion, un logiciel), explique simplement, étape par étape, sans faire le travail à la place de l'élève : tu es un prof patient qui aide à comprendre (comparaisons de la vie de tous les jours, exemples concrets), et tu vérifies que c'est compris ;
- « où est… ? » : montre-le et explique en une phrase à quoi il sert.
${_tools.isEmpty ? '' : 'Tu peux utiliser les actions de Mon Hub pour lire les vraies données (agenda, notes, devoirs, messages…) ou agir ; celles qui envoient ou modifient quelque chose demandent la permission.'}
${webSearch && provider != 'ollama' ? 'Tu peux chercher sur internet quand la question porte sur l\'actualité ou des faits récents ; cite brièvement la source à l\'oral (« d\'après … »).' : ''}
${quizMode ? 'MODE QUIZ : au lieu de donner la réponse, pose une question à la personne pour la faire réfléchir (une seule à la fois), puis évalue sa réponse en une phrase quand elle répond.' : ''}
${code ? 'MODE CODE : un éditeur de code est ouvert. Tu peux mettre de courts extraits de code dans le tableau (bloc "exemple"), donner le langage, expliquer l\'algorithme pas à pas, et pointer la ligne concernée.' : ''}
${stepsMode ? 'Leçon en plusieurs étapes : si la personne demande comment faire quelque chose qui prend plusieurs manipulations, découpe ta réponse en étapes séparées par [ETAPE] (au plus 8). Chaque étape est une ou deux phrases avec, si utile, sa propre balise [POINT…] ; la première étape commence tout de suite, et la dernière phrase de la première étape dit « dis suivant quand c\'est fait ». Clicky montre une étape à la fois.' : ''}

$_boardGuide

${HoloScene.guide}
${annotate ? '''
Dessiner sur l'écran (comme au tableau) : tu peux ajouter des annotations, en pixels de la capture$shotsNote : [ARROW:x1,y1->x2,y2:légende] (flèche), [CIRCLE:x,y,rayon:légende] (entoure un élément), [UNDERLINE:x,y,largeur] (souligne un texte, y = bas du texte), [LABEL:x,y:texte] (étiquette). Au plus 4, seulement si ça aide à comprendre.''' : ''}
${driveOn && DriveRunner.supported ? actGuide : ''}

Montrer à l'écran : montre dès que ça aide (mieux vaut montrer que ne pas montrer : un menu, un bouton, une zone, la chose dont tu parles) ; quand c'est utile de montrer où cliquer ou de quoi tu parles, termine ta réponse (ou chaque étape) par une balise [POINT:x,y:libellé court$shotsNote] où x,y sont en pixels sur l'image (origine en haut à gauche) et visent le centre de l'élément${shots.length > 1 ? ', et N le numéro de l\'écran' : ''}. ${screens.isEmpty ? '' : '$screens.'} Une seule balise par étape, à la fin. Si rien n'est à montrer, termine par [POINT:none].''';
  }

  /// Comment écrire un tableau visuel (voir board.dart).
  static const _boardGuide = '''
Tableau visuel : quand la personne dit qu'elle ne comprend pas, demande une explication, veut apprendre, réviser ou être interrogée, ou quand un dessin aide (étapes, schéma, cycle, comparaison, chronologie, chiffres, formule, vocabulaire), ajoute après ta réponse orale un tableau entre [TABLEAU] et [/TABLEAU], en JSON valide :
[TABLEAU]{"titre":"…","blocs":[…]}[/TABLEAU]
Blocs possibles (2 à 5 par tableau, textes très courts, adaptés à un·e élève) :
- {"type":"texte","titre":"…","texte":"…"} : l'idée clé
- {"type":"etapes","items":[{"titre":"…","texte":"…"}]}
- {"type":"schema","forme":"fleches","noeuds":["A","B","C"],"liens":[[0,1,"légende"],[1,2,""]]} : liens = [numéro du nœud de départ, numéro d'arrivée, légende courte] ; "forme":"cycle" pour un cycle (ex. cycle de l'eau)
- {"type":"comparaison","colonnes":["","Animal","Plante"],"lignes":[["Respire","oui","oui"]]}
- {"type":"frise","items":[{"date":"1789","texte":"…"}]}
- {"type":"graphique","titre":"…","unite":"…","valeurs":[{"label":"…","valeur":12}]}
- {"type":"formule","formule":"v = d ÷ t","legende":[{"terme":"v","sens":"vitesse (km/h)"}]}
- {"type":"exemple","titre":"…","texte":"…"} : un exemple résolu pas à pas
- {"type":"vocabulaire","items":[{"mot":"…","sens":"…"}]}
- {"type":"retenir","items":["…"]} : à retenir
- {"type":"quiz","question":"…","choix":["…","…","…"],"reponse":0,"explication":"…"} : pour vérifier que c'est compris (reponse = numéro du bon choix, à partir de 0) ; plusieurs blocs quiz pour un quiz de plusieurs questions
Le tableau n'est pas lu à voix haute : ta réponse orale le présente en une phrase (« regarde le schéma »). Pas de tableau pour une simple question pratique.''';

  static final _agentRe = RegExp(
    r'^\s*(?:(?:hey|ok|dis|eh)\s+)?(?:clicky[\s,]+)?agent\b[\s,:]*',
    caseSensitive: false,
  );

  /// Numéro de la question en cours (une réponse arrêtée est ignorée).
  int _askId = 0;

  /// Dernière question envoyée (pour « répète » et l'historique).
  String _lastQuestion = '';

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    _keepReply = false;
    await stopSpeaking();
    input.clear();
    transcript = q;
    target = null;
    showHistory = false;
    clearMarks();
    // « Prends la main et … » : Clicky agit tout de suite.
    final take = RegExp(
      r'^\s*(?:(?:hey|ok|dis)\s+)?(?:clicky[\s,]+)?(?:prends la main|prend la main|pilote|agis)\b[\s,:]*(?:et\s+|pour\s+)?(.+)$',
      caseSensitive: false,
    ).firstMatch(q);
    if (take != null && DriveRunner.supported) {
      unawaited(act(take.group(1)!.trim()));
      return;
    }
    final agent = _agentRe.firstMatch(q);
    if (agent != null) {
      unawaited(_runAgent(q.substring(agent.end).trim()));
      return;
    }
    // Sa « conscience » : humeur, souvenirs, choses dont prendre des nouvelles.
    unawaited(ClickyMind.instance.onUserMessage(q).catchError((Object _) {}));
    // Mémoire de l'assistant : un projet, une décision, un objectif.
    unawaited(
      Assistant.instance.remember(q).then((m) {
        if (m != null) notify?.call('Clicky s\'en souviendra', m);
      }).catchError((Object _) {}),
    );
    try {
      if (await _handleCommand(q)) return;
      if (await _handleSelf(q)) return;
      if (await _handleSkill(q)) return;
      // Tout ce qu'un algorithme sait faire : réponse immédiate, sans l'IA.
      if (await _handleQuick(q)) return;
      if (liveReady && !needsClassic(q) && await _liveAsk(q)) return;
      await _askAi(q);
    } finally {
      // Le mot d'activation se remet à écouter après chaque échange.
      if (state != ClickyState.listening && !voiceOut.speaking) _wake.resume();
    }
  }

  /// « Ça va ? », « tu te souviens de moi ? », « es-tu conscient ? » : il
  /// répond lui-même (sans IA), avec son humeur et ses souvenirs.
  Future<bool> _handleSelf(String q) async {
    if (!quick) return false;
    final mind = ClickyMind.instance;
    await mind.load();
    final r = mind.selfAnswer(q, now: DateTime.now(), name: callName);
    if (r == null) return false;
    unawaited(history.add(threadId, ChatMsg(mine: true, text: q), app: _appKey));
    unawaited(history.add(threadId, ChatMsg(mine: false, text: r), app: _appKey));
    _set(ClickyState.speaking, status: '', reply: r);
    await speak(r);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
    _fadeSoon();
    return true;
  }

  /// Commandes comprises sans l'IA.
  Future<bool> _handleCommand(String q) async {
    final cmd = parseCommand(q);
    if (cmd == null) return false;
    final (c, rest) = cmd;
    switch (c) {
      case ClickyCommand.next:
        if (steps.isEmpty) return false;
        await nextStep();
      case ClickyCommand.repeat:
        final last = voiceOut.lastSpoken.isNotEmpty ? voiceOut.lastSpoken : reply;
        if (last.isEmpty) return false;
        _set(ClickyState.speaking, status: '', reply: reply.isEmpty ? last : reply);
        await speak(last);
        if (state == ClickyState.speaking) _set(ClickyState.idle);
        _fadeSoon();
      case ClickyCommand.stop:
        await cancel();
      case ClickyCommand.newChat:
        newConversation();
      case ClickyCommand.history:
        toggleHistory();
      case ClickyCommand.repair:
        if (!_voicePlatform) return false;
        await repairMic();
      case ClickyCommand.protocol:
        final tool = _tools.where((t) => t.name == 'carnet_protocole').firstOrNull;
        if (tool == null) return false;
        _set(ClickyState.thinking, status: 'Protocole $rest…', reply: '');
        unawaited(ClickyChime.play());
        final r = '${await tool.run({'action': 'lancer', 'nom': rest})}';
        _set(ClickyState.idle, status: '', reply: r);
        _fadeSoon();
      case ClickyCommand.briefing:
        final a = Assistant.instance;
        if (!a.briefingOn) {
          await _askAi(briefingPrompt, shown: q, withScreen: false);
          return true;
        }
        // Préparé par Mon Hub (rapide, sans Claude).
        final tools = _tools;
        a.useTools(
          call: (name, args) async => tools.where((t) => t.name == name).firstOrNull?.run(args),
          tools: () => {for (final t in tools) t.name},
        );
        _set(ClickyState.thinking, status: 'Je prépare ton briefing…', reply: '');
        unawaited(ClickyChime.play());
        // Le briefing est toujours lu à voix haute.
        await presentTopo('Briefing', await a.morningBriefing(name: callName));
      case ClickyCommand.today || ClickyCommand.week:
        final j = Journal.instance;
        await j.load();
        final l = c == ClickyCommand.today ? j.today() : j.week();
        if (l.isEmpty) {
          _set(
            ClickyState.idle,
            reply: c == ClickyCommand.today
                ? 'On n\'a encore rien vu ensemble aujourd\'hui.'
                : 'On n\'a rien vu ensemble cette semaine.',
          );
          await speak(reply);
          _fadeSoon();
          return true;
        }
        await _askAi(
          'Voici ce qu\'on a vu ensemble ${c == ClickyCommand.today ? 'aujourd\'hui' : 'cette semaine'} '
          '(mon journal) :\n${Journal.digest(l)}\n\nFais-m\'en un résumé clair, avec un tableau « à retenir ».',
          shown: q,
          withScreen: false,
        );
      case ClickyCommand.review:
        final j = Journal.instance;
        await j.load();
        final due = j.due().take(6).toList();
        if (due.isEmpty) {
          _set(ClickyState.idle, reply: 'Rien à réviser pour l\'instant, tout est à jour.');
          await speak(reply);
          _fadeSoon();
          return true;
        }
        await reviewQuiz(due, shown: q);
      case ClickyCommand.quiz:
        await _askAi(
          'Interroge-moi${rest.isEmpty ? ' sur ce qu\'il y a à l\'écran ou ce qu\'on vient de voir' : ' sur $rest'} : '
          'fais un tableau avec 3 questions de quiz.',
          shown: q,
        );
      case ClickyCommand.whatDidIDo:
        final cap = WorkflowCapture.instance;
        final log = cap.on ? cap.stop() : cap.summary;
        if (log.isEmpty) {
          _set(
            ClickyState.idle,
            reply: WorkflowCapture.supported
                ? 'Je n\'ai rien enregistré. Lance « Capturer mes gestes » dans la boîte de Clicky, fais ta manip, puis redemande-moi.'
                : 'La capture des gestes ne marche que sur Windows.',
          );
          await speak(reply);
          _fadeSoon();
          return true;
        }
        await _askAi(
          'Voici ce que je viens de faire (gestes enregistrés, sans le texte tapé) :\n$log\n\n'
          'Raconte-moi étape par étape ce que j\'ai fait, et comment le refaire plus vite si possible.',
          shown: q,
          withScreen: false,
        );
      case ClickyCommand.changeVoice:
        // « Change de voix pour Kore » : une des voix Gemini.
        final wanted = normalize(rest);
        final gem = GeminiVoice.voices.where((v) => wanted.isNotEmpty && normalize(v) == wanted).firstOrNull;
        if (gem != null) {
          await setOption('geminiVoice', gem);
          _set(ClickyState.idle, reply: 'Voilà, j\'utilise maintenant la voix $gem.');
        } else {
          _set(
            ClickyState.idle,
            reply: 'Je ne trouve pas cette voix. Voix possibles : ${GeminiVoice.voices.join(', ')}.',
          );
        }
        await speak(reply);
        _fadeSoon();
    }
    return true;
  }

  /// Minuteurs lancés par « mets un minuteur de 10 minutes ».
  final _quickTimers = <Timer>[];

  /// Réponses instantanées sans l'IA (heure, calcul, devoirs, musique…).
  Future<bool> _handleQuick(String q) async {
    if (!quick) return false;
    final tools = _tools;
    final QuickReply? r;
    try {
      r = await QuickAnswers.answer(
        q,
        tools: {for (final t in tools) t.name},
        call: (name, args) async {
          final t = tools.where((x) => x.name == name).firstOrNull;
          if (t == null) return null;
          if (ClaudeBridge.isWriteAction(t) && !await confirmAction(t, args)) throw 'D\'accord, je ne touche à rien.';
          return t.run(args);
        },
      );
    } catch (e) {
      _set(ClickyState.idle, status: '', reply: '$e');
      _fadeSoon();
      return true;
    }
    if (r == null) return false;
    final media = r.media;
    if (media != null && DriveRunner.supported) Win.mediaKey(media);
    final d = r.timer;
    if (d != null) {
      final label = r.timerLabel;
      _quickTimers.add(Timer(d, () {
        unawaited(ClickyChime.play());
        final say = label.isEmpty ? 'C\'est l\'heure ! Ton minuteur est terminé.' : 'C\'est l\'heure : $label.';
        notify?.call('Clicky : minuteur', say);
        _set(ClickyState.speaking, status: '', reply: say);
        unawaited(speak(say).then((_) {
          if (state == ClickyState.speaking) _set(ClickyState.idle);
          _fadeSoon();
        }));
      }));
    }
    unawaited(history.add(threadId, ChatMsg(mine: true, text: q), app: _appKey));
    unawaited(history.add(threadId, ChatMsg(mine: false, text: r.text), app: _appKey));
    _set(ClickyState.speaking, status: '', reply: r.text);
    await speak(r.text);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
    _fadeSoon();
    return true;
  }

  /// Raccourcis vocaux à toi.
  Future<bool> _handleSkill(String q) async {
    final m = VoiceSkill.match(q);
    if (m == null) return false;
    final (skill, rest) = m;
    try {
      final (say, question) = await skill.run(rest);
      if (question != null) {
        await _askAi(question, shown: q);
      } else if (say != null) {
        _set(ClickyState.speaking, status: '', reply: say);
        await speak(say);
        if (state == ClickyState.speaking) _set(ClickyState.idle);
        _fadeSoon();
      }
    } catch (e) {
      _set(ClickyState.idle, reply: 'Le raccourci « ${skill.phrase} » n\'a pas marché : $e');
    }
    return true;
  }

  /// Quiz de révision sur des notions du journal.
  Future<void> reviewQuiz(List<JournalEntry> due, {String? shown}) async {
    await _askAi(
      'Fais-moi réviser ces notions (répétition espacée). Pose-moi un quiz dans un tableau '
      '(une question par notion, avec l\'explication) :\n${Journal.digest(due)}',
      shown: shown ?? 'Révisions',
      withScreen: false,
    );
    for (final e in due) {
      await Journal.instance.grade(e.id, true);
    }
  }

  /// Captures (avec la protection de la vie privée) et appli au premier plan.
  Future<(List<ClickyShot>, String, bool)> _look() async {
    var fg = '';
    var hidden = false;
    if (desktopMode && DriveRunner.supported) {
      fg = Win.foregroundTitle();
      currentApp = appFromTitle(fg);
      if (privacy && Win.visibleTitles().any(isSensitiveTitle)) hidden = true;
    }
    if (hidden) return (const <ClickyShot>[], fg, true);
    return (await (captureOverride ?? _captureApp)(), fg, false);
  }

  /// Le cœur : question → captures → IA → réponse parlée, pointée, dessinée.
  Future<void> _askAi(String q, {String? shown, bool withScreen = true}) async {
    final id = ++_askId;
    _lastQuestion = shown ?? q;
    steps = const [];
    _set(ClickyState.thinking, status: 'Je regarde…', reply: '');
    final useOllama = provider == 'ollama';
    final usePro = provider == 'claudecode';
    if (usePro ? await ClaudeCode.find() == null : (!useOllama && !await ClaudeApi.hasKey())) {
      _needsSetup();
      return;
    }
    final lang = multilang ? detectLanguage(q) : 'fr-FR';
    _applyVoice(lang: lang);
    // Pas de capture pour une question générale : beaucoup plus rapide.
    final look = withScreen && needsScreen(q);
    final (shots0, fg, hidden) = look ? await _look() : (const <ClickyShot>[], '', false);
    final shots = shots0;
    if (id != _askId) return;

    // Petit texte à lire : la reconnaissance de texte de Windows aide l'IA.
    var question = q;
    if (ocr && shots.isNotEmpty && ClickyOcr.supported && wantsOcr(q)) {
      _set(ClickyState.thinking, status: 'Je lis le texte de l\'écran…');
      final texts = <String>[];
      for (final s in shots) {
        final t = await ClickyOcr.read(base64Decode(s.png64));
        if (t.isNotEmpty) texts.add('Écran ${shots.indexOf(s) + 1} :\n$t');
      }
      if (texts.isNotEmpty) {
        final all = texts.join('\n\n');
        question =
            '$q\n\n(Texte lu à l\'écran par reconnaissance de caractères :\n'
            '${all.length > 6000 ? all.substring(0, 6000) : all})';
      }
    }
    if (id != _askId) return;
    final memory = _memory();
    final system = _system(shots, foreground: fg, hiddenScreen: hidden);
    final docBlocks = [for (final d in docs) ...d.blocks()];
    try {
      voiceOut.resetLive();
      final live = narrate && voice && _voicePlatform;
      void streamed(String t) {
        if (id != _askId) return;
        final noBoard = HoloScene.strip(ClickyBoard.strip(t));
        // Leçon en étapes : on n'affiche et ne lit que la première.
        final clean = stripClickyTags(stepsMode ? splitSteps(noBoard).first : noBoard);
        final d = ClickyBoard.writing(t) || HoloScene.writing(t);
        if (live) voiceOut.feed(clean);
        if (clean != reply || d != drawing) {
          drawing = d;
          _set(
            state,
            status: d
                ? (HoloScene.writing(t) ? 'Je projette l\'hologramme…' : 'Je dessine au tableau…')
                : '',
            reply: clean,
          );
        }
      }

      final String raw;
      if (usePro) {
        // Ton abonnement Claude, via ton Claude Code.
        raw = await ClaudeCode.ask(
          system: system,
          question: _withMemory(question, memory),
          imagesB64: [for (final s in shots) s.png64],
          imageLabels: [
            for (var i = 0; i < shots.length; i++) 'Écran ${i + 1} (${shots[i].label}) :',
          ],
          extraBlocks: docBlocks,
          web: webSearch,
          onText: streamed,
          onStatus: (s) => id == _askId ? _set(ClickyState.thinking, status: s) : null,
        );
      } else if (useOllama) {
        raw = await Ollama.chat(
          system: system,
          memory: memory,
          question: [for (final d in docs) d.asText(), question].join('\n\n'),
          imagesB64: [
            for (final s in shots) s.png64,
            for (final d in docs)
              if (d.image64 != null) d.image64!,
          ],
          onText: streamed,
        );
      } else {
        final msgs = <Map<String, dynamic>>[
          for (final (u, a) in memory) ...[
            {'role': 'user', 'content': u},
            {'role': 'assistant', 'content': a},
          ],
          {
            'role': 'user',
            'content': [
              for (final s in shots) ...[
                {'type': 'text', 'text': 'Écran ${shots.indexOf(s) + 1} (${s.label}) :'},
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': s.png64},
                },
              ],
              ...docBlocks,
              {'type': 'text', 'text': question},
            ],
          },
        ];
        raw = await ClaudeApi.chat(
          system: system,
          history: msgs,
          tools: _tools,
          confirm: confirmAction,
          webSearch: webSearch,
          onStatus: (s) => id == _askId ? _set(ClickyState.thinking, status: s) : null,
          onText: streamed,
        );
      }
      if (id != _askId) return;
      drawing = false;
      final (spokenBoard, newBoard) = ClickyBoard.extract(raw);
      final (spokenAll, newHolo) = HoloScene.extract(spokenBoard);
      if (newHolo != null) {
        holo = newHolo;
        onInteractive?.call(true);
      }
      final (noAct, actGoal) = extractAct(spokenAll);
      final (noPlan, plan) = DrivePlan.extract(noAct);
      final parts = stepsMode ? splitSteps(noPlan) : [noPlan.replaceAll(stepRe, ' ')];
      if (newBoard != null) _showBoard(newBoard);
      // Historique + journal + leçon enregistrée.
      final clean = [for (final p in parts) _plain(p)].join('\n');
      final app = _appKey;
      final tid = threadId;
      unawaited(history.add(tid, ChatMsg(mine: true, text: _lastQuestion), app: app));
      unawaited(
        history.add(
          tid,
          ChatMsg(
            mine: false,
            text: clean.isEmpty ? '(je t\'ai montré à l\'écran)' : clean,
            note: newBoard == null ? null : '(tableau affiché : ${newBoard.summary})',
          ),
          app: app,
        ),
      );
      if (journalOn) {
        unawaited(
          Journal.instance.add(
            question: _lastQuestion,
            answer: clean,
            board: newBoard?.title,
            app: currentApp,
          ),
        );
      }
      if (LessonRecorder.instance.on) {
        unawaited(
          LessonRecorder.instance.add(
            _lastQuestion,
            clean,
            png64: shots.firstOrNull?.png64,
            board: newBoard?.summary,
          ),
        );
      }
      steps = parts.length > 1 ? parts : const [];
      stepIndex = 0;
      _stepShots = shots;
      await _present(parts.first, shots, liveSpoken: live);
      if (actGoal != null && id == _askId) {
        await act(actGoal);
      } else if (plan != null && id == _askId) {
        await _drive(plan, shots);
      }
    } on ClaudeCodeCancelled {
      return;
    } catch (e) {
      if (id != _askId) return;
      drawing = false;
      panelOpen = true;
      onInteractive?.call(true);
      _set(ClickyState.idle, status: '', reply: '$e');
    }
  }

  /// Texte sans aucune balise.
  static String _plain(String part) => stripClickyTags(ClickyMark.extract(parsePoint(part).$1).$1);

  /// Montre une réponse (ou une étape) : texte, pointage, dessins, voix.
  Future<void> _present(
    String part,
    List<ClickyShot> shots, {
    bool step = false,
    bool liveSpoken = false,
  }) async {
    final id = _askId;
    final (noPoint, point, label, screen) = parsePoint(part);
    final (text0, rawMarks) = ClickyMark.extract(noPoint);
    final text = stripClickyTags(text0);
    final shot = shots.isEmpty ? null : shots[(screen - 1).clamp(0, shots.length - 1)];
    // Dessins à l'écran.
    final drawn = <ClickyMark>[];
    for (final m in rawMarks) {
      if (shots.isEmpty) break;
      final s = shots[(m.screen - 1).clamp(0, shots.length - 1)];
      drawn.add(m.map(s.toLayer, s.logicalPerPx));
    }
    marks = drawn;
    marksId++;
    var p = point;
    if (p != null && shot != null && precise) {
      // Il s'envole tout de suite vers l'endroit, puis ajuste son tir.
      target = shot.toLayer(p);
      targetLabel = label;
      _set(ClickyState.pointing, status: 'Je vise…', reply: text);
      p = await _refine(shot, p, label) ?? p;
      if (id != _askId) return;
    }
    final status = steps.isEmpty
        ? ''
        : 'Étape ${stepIndex + 1} sur ${steps.length}${hasNextStep ? ' · dis « suivant »' : ''}';
    if (p != null && shot != null) {
      target = shot.toLayer(p);
      targetLabel = label;
      _set(ClickyState.pointing, status: status, reply: text);
    } else {
      target = null;
      _set(ClickyState.speaking, status: status, reply: text);
    }
    if (liveSpoken && !step) {
      voiceOut.finish(text);
      _wake.pause();
      await voiceOut.done();
    } else {
      await speak(text);
    }
    if (id != _askId) return;
    if (state == ClickyState.speaking) {
      _set(ClickyState.idle);
      _fadeSoon();
    }
    if (state == ClickyState.pointing) {
      // On laisse la flèche le temps de voir, puis Clicky revient.
      Timer(Duration(seconds: slow ? 7 : 4), () {
        if (state == ClickyState.pointing && id == _askId) {
          target = null;
          _set(ClickyState.idle);
          _fadeSoon();
        }
      });
    }
    if (state != ClickyState.listening) _wake.resume();
  }

  /// Pointage précis : zoom + grille, une seconde question à l'IA.
  Future<Offset?> _refine(ClickyShot shot, Offset p, String label) async {
    try {
      final zone = PrecisePointer.zone(p, shot.width, shot.height);
      final img = await PrecisePointer.gridImage(shot.png64, zone);
      if (img == null) return null;
      const sys =
          'Tu aides à viser précisément un élément sur une capture d\'écran. Réponds uniquement par une case.';
      final String a;
      if (provider == 'claudecode') {
        a = await ClaudeCode.ask(
          system: sys,
          question: PrecisePointer.question(label),
          imagesB64: [img],
          withTools: false,
        );
      } else if (provider == 'ollama') {
        a = await Ollama.chat(
          system: sys,
          memory: const [],
          question: PrecisePointer.question(label),
          imagesB64: [img],
        );
      } else {
        a = await ClaudeApi.chat(
          system: sys,
          history: [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': img},
                },
                {'type': 'text', 'text': PrecisePointer.question(label)},
              ],
            },
          ],
        );
      }
      return PrecisePointer.cellCenter(a, zone);
    } catch (_) {
      return null;
    }
  }

  /// « Clicky pilote » : relecture du plan, puis clics / frappe.
  Future<void> _drive(DrivePlan plan, List<ClickyShot> shots) async {
    if (!desktopMode || !DriveRunner.supported || shots.isEmpty) return;
    onInteractive?.call(true);
    final ok = await DriveRunner.review(plan);
    onInteractive?.call(panelOpen || board != null);
    if (!ok) {
      _set(ClickyState.idle, status: 'D\'accord, je ne touche à rien.');
      _fadeSoon();
      return;
    }
    // La fenêtre de Clicky ne doit pas recevoir les clics.
    closePanel();
    final r = await DriveRunner.run(
      plan,
      (pt, screen) => shots[(screen - 1).clamp(0, shots.length - 1)].toLayer(pt),
      onStatus: (s) => _set(ClickyState.thinking, status: s),
    );
    _set(ClickyState.idle, status: '', reply: r);
    await speak(r);
    _fadeSoon();
  }

  // ---------- Réponse instantanée : Gemini Live (comme JARVIS) ----------

  /// Réglage « Réponse instantanée » (activé par défaut quand il y a une
  /// clé Gemini).
  bool get instant => _opt('instant', true);

  /// Réponses instantanées sans l'IA (heure, calculs, devoirs, musique…).
  bool get quick => _opt('quick', true);

  /// Gemini Live peut servir maintenant.
  bool get liveReady =>
      instant &&
      voice &&
      PcmPlayer.supported &&
      voiceOut.geminiKey.trim().isNotEmpty &&
      (_liveDownUntil == null || DateTime.now().isAfter(_liveDownUntil!));

  /// Questions qui ont besoin de Claude (montrer où cliquer, dessiner…).
  static bool needsClassic(String q) => RegExp(
    r"\b(montre|montrez|o[uù] (est|se trouve|cliquer)|clique|pointe|tableau|sch[ée]ma|dessine|hologramme|quiz|interroge|le[cç]on|[ée]tape par [ée]tape)\b",
    caseSensitive: false,
  ).hasMatch(q);

  GeminiLive? _live;
  final _livePlayer = PcmPlayer();
  AudioRecorder? _liveRec;
  StreamSubscription<Uint8List>? _liveMic;
  DateTime? _liveDownUntil;
  String _liveIn = '';
  String _liveOut = '';
  bool _liveTurn = false;
  bool _liveIgnore = false;
  bool _liveSpoke = false;
  DateTime? _liveQuiet;
  Timer? _liveWatch;

  /// Dernier souci de Gemini Live (affiché dans les réglages).
  String? liveError;

  String _liveSystem() {
    final modules = hub?.enabled ?? const <HubModule>[];
    final now = DateTime.now();
    return '''
${clickyPersona(callName)}
${ClickyMind.instance.promptBlock(name: callName)}
Tu es Clicky, l'assistant personnel façon JARVIS qui vit dans « Mon Hub » sur l'ordinateur de la personne. Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.
Tu réponds À L'ORAL et TOUT DE SUITE : en français, naturel, 1 à 3 phrases courtes (plus seulement si on te le demande), sans liste ni symbole.
${modules.isEmpty ? '' : 'Modules de Mon Hub : ${modules.map((m) => m.name).join(', ')}.'}
Utilise les fonctions pour les vraies données (agenda, cours, devoirs, notes, messages, mails, musique, carnet…) et pour agir ; dis en une phrase ce que tu as fait. Celles qui envoient ou modifient quelque chose demandent la permission à la personne.
Ce qu'il y a à l'écran : regarder_ecran. Faire quelque chose à l'écran à sa place (ouvrir, cliquer, écrire dans une appli) : agir_sur_ordinateur. Une explication avec tableau, schéma ou hologramme, ou montrer où cliquer : expliquer_au_tableau (puis ne dis presque rien, le tableau arrive).
${_facts.isEmpty ? '' : 'Ce que tu sais de la personne :\n${_facts.map((f) => '- $f').join('\n')}'}''';
  }

  static const _liveExtras = [
    {
      'name': 'regarder_ecran',
      'description': 'Regarde l\'écran de la personne (toutes les fenêtres) et décrit ce qu\'il y a, pour répondre à une question sur l\'écran.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'question': {'type': 'STRING', 'description': 'Ce qu\'il faut chercher ou comprendre à l\'écran.'},
        },
        'required': ['question'],
      },
    },
    {
      'name': 'agir_sur_ordinateur',
      'description': 'Clicky prend la souris et le clavier pour faire une tâche à l\'écran (ouvrir un site et y chercher, cliquer, faire défiler, écrire dans une appli…).',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'but': {'type': 'STRING', 'description': 'Le but précis, avec tous les détails.'},
        },
        'required': ['but'],
      },
    },
    {
      'name': 'expliquer_au_tableau',
      'description': 'Explication détaillée avec tableau visuel, schéma, hologramme 3D ou en montrant où cliquer à l\'écran.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'question': {'type': 'STRING', 'description': 'La question complète de la personne.'},
        },
        'required': ['question'],
      },
    },
  ];

  Future<GeminiLive> _liveSession() async {
    final current = _live;
    if (current != null) {
      if (current.connected) return current;
      // Déjà en train de se connecter (préparée au démarrage) : on attend.
      if (current.connecting) {
        await current.connect();
        return current;
      }
      await current.close();
    }
    late final GeminiLive l;
    l = GeminiLive(
      key: voiceOut.geminiKey,
      system: _liveSystem(),
      voice: voiceOut.geminiVoice,
      tools: [for (final t in _tools) if (!t.name.startsWith('mcp_')) t],
      extraDeclarations: _liveExtras,
    )
      ..onAudio = _liveAudio
      ..onOutputText = (t) {
        if (_liveIgnore) return;
        _liveOut = '$_liveOut$t';
        reply = _liveOut.trim();
        notifyListeners();
      }
      ..onInputText = (t) {
        _liveIn = '$_liveIn$t';
        transcript = _liveIn.trim();
        notifyListeners();
      }
      ..onInterrupted = _livePlayer.stop
      ..onTurnComplete = () {
        unawaited(_liveDone());
      }
      ..onToolCall = _liveTool
      ..onToolStatus = (name) {
        if (!_liveIgnore) _set(ClickyState.thinking, status: 'J\'utilise ${name.replaceAll('_', ' ')}…');
      }
      ..onClosed = (why) {
        if (identical(_live, l)) _live = null;
        // Quota atteint au milieu d'une question : Claude et la voix
        // Microsoft répondent à la place, sans rien perdre.
        if (isQuotaError(why)) {
          _liveFailed(why);
          if (_liveTurn && !_liveIgnore) {
            _liveTurn = false;
            _liveWatch?.cancel();
            final q = _liveIn.trim();
            if (q.isNotEmpty) unawaited(_askAi(q));
          }
        }
      };
    _live = l;
    await l.connect();
    liveError = null;
    return l;
  }

  /// Prépare la connexion à l'avance (la première réponse est aussi
  /// instantanée).
  void warmUpLive() {
    if (!liveReady) return;
    unawaited(_liveConnect());
  }

  Future<GeminiLive?> _liveConnect() async {
    try {
      return await _liveSession();
    } catch (e) {
      _liveFailed(e);
      return null;
    }
  }

  /// Le quota gratuit de Gemini est épuisé (ou la clé refusée) ?
  static bool isQuotaError(Object e) =>
      RegExp(r'RESOURCE_EXHAUSTED|quota|rate.?limit|\b429\b|exceeded', caseSensitive: false).hasMatch('$e');

  /// Gemini Live ne marche plus : relais par la voix Microsoft (illimitée)
  /// pendant un moment — une heure si c'est le quota gratuit.
  void _liveFailed(Object e) {
    final quota = isQuotaError(e);
    liveError = quota ? 'Quota gratuit de Gemini atteint : voix Microsoft (illimitée) en attendant.' : '$e';
    _liveDownUntil = DateTime.now().add(quota ? const Duration(hours: 1) : const Duration(minutes: 10));
    ErrorLog.record(e, null, where: 'Gemini Live');
  }

  void _liveBegin(String shown) {
    _livePlayer.stop();
    voiceOut.stop();
    _liveIgnore = false;
    _liveIn = shown;
    _liveOut = '';
    _liveSpoke = false;
    _liveQuiet = null;
  }

  /// Connexion en cours pendant que tu parles déjà (le son est gardé).
  Future<GeminiLive?>? _liveConn;
  final _liveBuffer = <Uint8List>[];
  GeminiLive? _liveTarget;

  /// Écoute en direct : chaque morceau du micro part vers Gemini. Le micro
  /// démarre tout de suite ; si la connexion n'est pas encore prête, le son
  /// est gardé puis envoyé (aucun mot perdu).
  Future<bool> _liveListen() async {
    _liveBegin('');
    _liveBuffer.clear();
    _liveTarget = null;
    final ready = _live != null && _live!.connected ? _live : null;
    try {
      final rec = _liveRec ??= AudioRecorder();
      final stream = await rec.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      if (ready != null) {
        ready.activityStart();
        _liveTarget = ready;
      }
      _liveMic = stream.listen((chunk) {
        final t = _liveTarget;
        t == null ? _liveBuffer.add(chunk) : t.sendAudio(chunk);
        final lv = PcmPlayer.rms(chunk);
        levels.setRange(0, levels.length - 1, levels.skip(1));
        levels[levels.length - 1] = lv;
        notifyListeners();
        // Sans Ctrl + Alt maintenus : la question part après un silence.
        if (lv > 0.12) {
          _liveSpoke = true;
          _liveQuiet = null;
        } else if (_liveSpoke && !_holding) {
          _liveQuiet ??= DateTime.now();
          if (DateTime.now().difference(_liveQuiet!) > const Duration(milliseconds: 900)) {
            _liveSpoke = false;
            unawaited(stopListening());
          }
        }
      }, onError: (Object e) => ErrorLog.record(e, null, where: 'micro Gemini Live'));
    } catch (e) {
      ErrorLog.record(e, null, where: 'micro Gemini Live');
      return false;
    }
    _set(ClickyState.listening, status: '', reply: '');
    if (ready == null) {
      // Connexion pendant que tu parles.
      final conn = _liveConn = _liveConnect();
      final l = await conn;
      if (identical(_liveConn, conn)) _liveConn = null;
      if (l == null) {
        // Gemini indisponible : on repasse sur l'écoute classique.
        final sub = _liveMic;
        _liveMic = null;
        await sub?.cancel();
        try {
          await _liveRec?.stop();
        } catch (_) {}
        _liveBuffer.clear();
        return false;
      }
      _liveFlush(l);
    }
    return true;
  }

  /// Envoie le son gardé pendant la connexion.
  void _liveFlush(GeminiLive l) {
    if (_liveTarget != null) return;
    l.activityStart();
    for (final b in _liveBuffer) {
      l.sendAudio(b);
    }
    _liveBuffer.clear();
    _liveTarget = l;
  }

  /// Fin de ta question : Gemini répond tout de suite.
  Future<void> _liveStop({bool send = true}) async {
    final sub = _liveMic;
    _liveMic = null;
    await sub?.cancel();
    try {
      await _liveRec?.stop();
    } catch (_) {}
    if (!send) {
      _liveTarget?.activityEnd();
      _liveIgnore = true;
      _liveBuffer.clear();
      _set(ClickyState.idle, status: '');
      _wake.resume();
      return;
    }
    _set(ClickyState.thinking, status: '', reply: '');
    // Tu as lâché avant la fin de la connexion : on attend, puis on envoie.
    var l = _liveTarget;
    if (l == null) {
      final conn = _liveConn;
      final got = conn == null ? null : await conn;
      if (got == null) {
        _set(ClickyState.idle, status: 'Gemini Live ne répond pas : réessaie.');
        _fadeSoon();
        return;
      }
      _liveFlush(got);
      l = got;
    }
    l.activityEnd();
    _liveTurn = true;
    _liveWatchdog();
  }

  /// Une question écrite, par Gemini Live.
  Future<bool> _liveAsk(String q) async {
    final l = await _liveConnect();
    if (l == null) return false;
    _liveBegin(q);
    _lastQuestion = q;
    transcript = q;
    _liveTurn = true;
    _set(ClickyState.thinking, status: '', reply: '');
    l.sendText(q);
    _liveWatchdog();
    return true;
  }

  void _liveWatchdog() {
    _liveWatch?.cancel();
    _liveWatch = Timer(const Duration(seconds: 20), () {
      if (_liveTurn && _liveOut.isEmpty && !_livePlayer.playing) {
        _liveTurn = false;
        unawaited(_live?.close());
        _live = null;
        _set(ClickyState.idle, status: 'Gemini ne répond pas, réessaie (ou je repasse sur Claude).');
        _liveDownUntil = DateTime.now().add(const Duration(minutes: 2));
        _fadeSoon();
      }
    });
  }

  void _liveAudio(Uint8List pcm) {
    if (_liveIgnore) return;
    _livePlayer.write(pcm);
    if (state != ClickyState.speaking && state != ClickyState.listening) {
      _set(ClickyState.speaking, status: '');
    }
  }

  Future<void> _liveDone() async {
    _liveWatch?.cancel();
    _liveTurn = false;
    if (_liveIgnore) {
      _liveIgnore = false;
      return;
    }
    // Attend la fin de la voix (le son arrive plus vite qu'il ne se joue).
    for (var i = 0; i < 600 && _livePlayer.playing && !_liveIgnore; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final q = _liveIn.trim(), a = _liveOut.trim();
    if (q.isNotEmpty || a.isNotEmpty) {
      final app = _appKey;
      unawaited(history.add(threadId, ChatMsg(mine: true, text: q.isEmpty ? '(question à voix haute)' : q), app: app));
      if (a.isNotEmpty) unawaited(history.add(threadId, ChatMsg(mine: false, text: a), app: app));
    }
    if (state == ClickyState.speaking || state == ClickyState.thinking) {
      _set(ClickyState.idle, status: '', reply: a);
      _fadeSoon();
    }
    _wake.resume();
  }

  /// Gemini Live utilise une action de Mon Hub.
  Future<Object?> _liveTool(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'regarder_ecran':
        final (shots, _, hidden) = await _look();
        if (hidden) return 'Une fenêtre sensible est ouverte : je ne regarde pas l\'écran.';
        if (shots.isEmpty) return 'Je ne vois pas l\'écran.';
        return GeminiVision.look(voiceOut.geminiKey, [for (final s in shots) s.png64], '${args['question'] ?? ''}');
      case 'agir_sur_ordinateur':
        final goal = '${args['but'] ?? ''}'.trim();
        if (goal.isEmpty) return 'Quel est le but ?';
        // Après la phrase de Gemini (« je m'en occupe »).
        unawaited(Future<void>.delayed(const Duration(seconds: 2), () => act(goal)));
        return 'D\'accord : je prends la souris dans un instant. Dis-le en quelques mots.';
      case 'expliquer_au_tableau':
        final question = '${args['question'] ?? _liveIn}'.trim();
        unawaited(() async {
          for (var i = 0; i < 80 && (_liveTurn || _livePlayer.playing); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await _askAi(question);
        }());
        return 'Clicky prépare l\'explication au tableau : dis juste « je te montre ».';
    }
    final tool = _tools.where((t) => t.name == name).firstOrNull;
    if (tool == null) return 'Action inconnue : $name';
    if (ClaudeBridge.isWriteAction(tool) && !await confirmAction(tool, args)) {
      return 'La personne a refusé cette action.';
    }
    return tool.run(args);
  }

  // ---------- Clicky agit : il prend la souris et le clavier ----------

  /// Une tâche « Clicky agit » est en cours.
  bool acting = false;

  /// Journal de la tâche en cours (montré dans la boîte).
  List<ActLog> actLog = const [];

  static final _actRe = RegExp(r'\[AGIR\]([\s\S]*?)\[/AGIR\]', caseSensitive: false);

  /// Sépare la réponse et le but [AGIR]…[/AGIR].
  static (String, String?) extractAct(String raw) {
    final m = _actRe.firstMatch(raw);
    if (m == null) return (raw, null);
    final goal = m.group(1)!.trim();
    return (raw.replaceAll(_actRe, '').trim(), goal.isEmpty ? null : goal);
  }

  /// Comment l'IA déclenche « Clicky agit ».
  static const actGuide = '''
Agir sur l'ordinateur : quand la personne te demande de FAIRE quelque chose à l'écran à sa place (ouvrir un site et y chercher quelque chose, cliquer, remplir, faire défiler, ranger des fenêtres, regarder une vidéo, écrire un message dans une appli…), dis en une phrase ce que tu vas faire, puis ajoute à la fin [AGIR]le but précis, avec tous les détails utiles[/AGIR]. Tu prendras alors la souris et le clavier toi-même, étape par étape, en regardant l'écran. Pour une simple commande système (son, fichiers, logiciels), préfère les outils pc_.''';

  /// Une question rapide à l'IA (sans outils), avec les captures.
  Future<String> _askRaw(String system, String prompt, List<ClickyShot> shots) async {
    final labels = [for (var i = 0; i < shots.length; i++) 'Écran ${i + 1} (${shots[i].label}, ${shots[i].width} × ${shots[i].height} px) :'];
    switch (provider) {
      case 'claudecode':
        return ClaudeCode.ask(
          system: system,
          question: prompt,
          imagesB64: [for (final s in shots) s.png64],
          imageLabels: labels,
          withTools: false,
        );
      case 'ollama':
        return Ollama.chat(
          system: system,
          memory: const [],
          question: prompt,
          imagesB64: [for (final s in shots) s.png64],
        );
      default:
        return ClaudeApi.chat(
          system: system,
          history: [
            {
              'role': 'user',
              'content': [
                for (var i = 0; i < shots.length; i++) ...[
                  {'type': 'text', 'text': labels[i]},
                  {
                    'type': 'image',
                    'source': {'type': 'base64', 'media_type': 'image/png', 'data': shots[i].png64},
                  },
                ],
                {'type': 'text', 'text': prompt},
              ],
            },
          ],
        );
    }
  }

  /// Clicky prend la main pour atteindre [goal] : il regarde l'écran, fait
  /// une action (en volant jusqu'à l'endroit), regarde de nouveau…
  /// Échap ou bouger la souris l'arrête.
  Future<void> act(String goal) async {
    if (!DriveRunner.supported || goal.trim().isEmpty) return;
    if (!desktopMode) {
      // Dans la fenêtre Mon Hub : c'est Clicky partout qui agit (il voit
      // tout l'écran et passe au-dessus des fenêtres).
      await ClickyDesktop.launch();
      final sent = await ClickyDesktop.send('act64 ${base64Encode(utf8.encode(goal))}');
      if (!sent) {
        _set(ClickyState.idle, reply: 'Pour que je prenne la souris, active « Clicky partout » dans mes réglages.');
      }
      return;
    }
    if (acting) return;
    // Permission (sauf réglage « Contrôle du PC : sans demander »).
    if (pcControl == 'off') {
      _set(ClickyState.idle, reply: 'Le contrôle du PC est désactivé dans mes réglages.');
      return;
    }
    if (pcControl == 'ask') {
      onInteractive?.call(true);
      final ok = await _confirmAct(goal);
      onInteractive?.call(panelOpen || board != null);
      if (!ok) {
        _set(ClickyState.idle, status: 'D\'accord, je ne touche à rien.');
        _fadeSoon();
        return;
      }
    }
    acting = true;
    actLog = const [];
    final id = ++_askId;
    closePanel();
    unawaited(ClickyChime.play());
    _set(ClickyState.thinking, status: 'Je prends la main… (Échap pour m\'arrêter)', reply: '');
    final log = <ActLog>[];
    var result = '';
    (int, int)? expected;
    try {
      Win.releaseModifiers();
      for (var i = 1; i <= 30; i++) {
        if (id != _askId) {
          result = 'Arrêté.';
          break;
        }
        if (Win.down(0x1B)) {
          result = 'Arrêté (Échap).';
          break;
        }
        final now = Win.cursor();
        if (expected != null && now != null && ((now.$1 - expected.$1).abs() > 12 || (now.$2 - expected.$2).abs() > 12)) {
          result = 'Tu as bougé la souris : je te rends la main.';
          break;
        }
        _set(ClickyState.thinking, status: 'Étape $i : je regarde l\'écran…');
        final (shots, _, hidden) = await _look();
        if (hidden) {
          result = 'Une fenêtre sensible (mots de passe, banque) est ouverte : je m\'arrête par sécurité.';
          break;
        }
        if (shots.isEmpty) {
          result = 'Je ne vois pas l\'écran.';
          break;
        }
        final windows = Win.windowList().take(25).map((w) => '- id ${w.$1} : ${w.$2}${w.$3.isEmpty ? '' : ' (${w.$3})'}').join('\n');
        final prompt = [
          'But : $goal',
          'Fenêtre au premier plan : « ${Win.foregroundTitle()} ».',
          'Fenêtres ouvertes :\n$windows',
          if (log.isNotEmpty) 'Déjà fait :\n${[for (final (k, l) in log.indexed) '${k + 1}. $l'].join('\n')}',
          'Étape $i : quelle est la prochaine action ? (JSON seul)',
        ].join('\n\n');
        String raw;
        try {
          raw = await _askRaw(ActStep.guide(screens: shots.length), prompt, shots);
        } on ClaudeCodeCancelled {
          result = 'Arrêté.';
          break;
        }
        if (id != _askId) {
          result = 'Arrêté.';
          break;
        }
        final step = ActStep.parse(raw);
        if (step == null) {
          log.add(ActLog(const ActStep('?', {}), 'réponse illisible'));
          if (log.where((l) => l.step.action == '?').length >= 3) {
            result = 'Je n\'arrive pas à décider quoi faire.';
            break;
          }
          continue;
        }
        if (step.done) {
          result = step.s('message').isEmpty ? 'C\'est fait.' : step.s('message');
          break;
        }
        _set(ClickyState.pointing, status: 'Étape $i : ${step.thought.isEmpty ? step.describe : step.thought}');
        final r = await _doStep(step, shots);
        log.add(ActLog(step, r));
        actLog = List.of(log);
        expected = Win.cursor();
        // Laisse l'appli réagir (page qui charge, menu qui s'ouvre).
        await Future<void>.delayed(Duration(milliseconds: step.action == 'ouvrir' ? 1800 : 700));
      }
      if (result.isEmpty) result = 'J\'ai fait 30 actions sans finir : je m\'arrête là.';
    } catch (e) {
      result = 'Je me suis arrêté : $e';
    } finally {
      acting = false;
      target = null;
    }
    actLog = List.of(log);
    notify?.call('Clicky a agi', '$goal\n$result');
    _set(ClickyState.speaking, status: '', reply: result);
    await speak(result);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
    _fadeSoon();
  }

  /// Fait une action : Clicky vole jusqu'au point, la vraie souris suit.
  Future<String> _doStep(ActStep s, List<ClickyShot> shots) async {
    Future<(int, int)?> flyTo((Offset, int)? pt, String label) async {
      if (pt == null || shots.isEmpty) return null;
      final shot = shots[(pt.$2 - 1).clamp(0, shots.length - 1)];
      final p = shot.toLayer(pt.$1);
      target = p;
      targetLabel = label;
      notifyListeners();
      final x = p.dx.round(), y = p.dy.round();
      await Win.glide(x, y);
      return (x, y);
    }

    switch (s.action) {
      case 'clic' || 'double_clic' || 'clic_droit' || 'deplacer':
        final at = await flyTo(s.point, s.s('libelle'));
        if (at == null) return 'pas de point';
        if (s.action == 'deplacer') return 'ok';
        Win.click(at.$1, at.$2, right: s.action == 'clic_droit', double: s.action == 'double_clic');
        return 'ok';
      case 'ecrire':
        if (isSensitiveTitle(Win.foregroundTitle())) return 'refusé : fenêtre sensible';
        Win.releaseModifiers();
        Win.typeText(s.s('texte'));
        return 'ok';
      case 'touches':
        Win.releaseModifiers();
        return Win.pressCombo(s.s('touches')) ? 'ok' : 'touche inconnue';
      case 'defiler':
        if (s.point != null) await flyTo(s.point, '');
        final n = (s.n('crans') ?? -3).toInt().clamp(-25, 25);
        s.args['horizontal'] == true ? Win.hscroll(n) : Win.scroll(n);
        return 'ok';
      case 'glisser':
        final a = s.point;
        final x2 = s.n('x2'), y2 = s.n('y2');
        if (a == null || x2 == null || y2 == null || shots.isEmpty) return 'points manquants';
        final shot = shots[(a.$2 - 1).clamp(0, shots.length - 1)];
        final p1 = shot.toLayer(a.$1), p2 = shot.toLayer(Offset(x2.toDouble(), y2.toDouble()));
        target = p1;
        notifyListeners();
        await Win.drag(p1.dx.round(), p1.dy.round(), p2.dx.round(), p2.dy.round());
        target = p2;
        notifyListeners();
        return 'ok';
      case 'ouvrir':
        return PcControl.open(s.s('cible'));
      case 'fenetre':
        final wid = s.n('id')?.toInt();
        if (wid == null) return 'id manquant';
        return Win.windowAction(wid, s.s('faire').isEmpty ? 'activer' : s.s('faire')) ? 'ok' : 'fenêtre introuvable';
      case 'commande':
        final tool = PcControl.tools().where((t) => t.name == 'pc_commande').firstOrNull;
        if (tool == null) return 'commandes indisponibles';
        final args = {'commande': s.s('commande'), 'pourquoi': s.s('pourquoi')};
        if (!await confirmAction(tool, args)) return 'refusé par la personne';
        return jsonEncode(await tool.run(args));
      case 'attendre':
        await Future<void>.delayed(Duration(milliseconds: (s.n('ms') ?? 1000).toInt().clamp(200, 8000)));
        return 'ok';
      default:
        return 'action inconnue';
    }
  }

  Future<bool> _confirmAct(String goal) async {
    final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
    if (ctx == null || !ctx.mounted) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.mouse_rounded),
        title: const Text('Clicky prend la main'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(goal, style: Theme.of(c).textTheme.titleSmall),
              const SizedBox(height: 10),
              const Text(
                'Je vais bouger la souris, cliquer, faire défiler et écrire tout seul, en regardant l\'écran. '
                'Échap ou bouger la souris m\'arrête tout de suite. Je ne tape rien dans une fenêtre de mot de '
                'passe ou de banque.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Non')),
          FilledButton.icon(
            icon: const Icon(Icons.check_rounded),
            onPressed: () => Navigator.pop(c, true),
            label: const Text('Oui, vas-y'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Claude Code ne garde pas la conversation : on lui rappelle les
  /// derniers échanges dans la question.
  static String _withMemory(String q, List<(String, String)> memory) {
    if (memory.isEmpty) return q;
    final past = [for (final (u, a) in memory) 'Moi : $u\nToi : $a'].join('\n\n');
    return 'Nos derniers échanges :\n$past\n\nNouvelle question : $q';
  }

  void _needsSetup() {
    panelOpen = true;
    onInteractive?.call(true);
    _set(
      ClickyState.idle,
      status: '',
      reply: provider == 'claudecode'
          ? 'Pour utiliser ton abonnement Claude, installe Claude Code puis connecte-toi : '
                'module Claude → Réglages (icône clé).'
          : 'Pour que je puisse t\'aider, choisis mon cerveau dans le module Claude '
                '→ Réglages (icône clé) : ton abonnement Claude Pro, une clé API, ou Ollama.',
    );
  }

  /// Une tâche faite par l'agent (mode « Agent, … » et routines). Renvoie le
  /// compte rendu.
  Future<String> runTask(String task) async =>
      _plain(ClickyBoard.strip(DrivePlan.extract(await runTaskRaw(task)).$1));

  /// Un compagnon travaille : compté dans « agents au travail ».
  Future<String> runBuddyTask(String task) async {
    agentsRunning++;
    notifyListeners();
    try {
      return await runTaskRaw(task);
    } finally {
      agentsRunning--;
      notifyListeners();
    }
  }

  /// Le travail d'un agent, texte brut (avec les outils de Mon Hub).
  Future<String> runTaskRaw(String task) async {
    final usePro = provider == 'claudecode';
    if (usePro
        ? await ClaudeCode.find() == null
        : (provider != 'claude' || !await ClaudeApi.hasKey())) {
      throw 'Le mode agent a besoin de Claude (ton abonnement Claude Pro ou une clé API).';
    }
    final r = usePro
        ? await ClaudeCode.ask(
            system: _system(const [], agent: true),
            question: task,
            effort: 'high',
            web: webSearch,
          )
        : await ClaudeApi.chat(
            system: _system(const [], agent: true),
            history: [
              {'role': 'user', 'content': task},
            ],
            tools: _tools,
            confirm: confirmAction,
            webSearch: webSearch,
            effort: 'high',
          );
    return r;
  }

  /// Tâche de fond : Clicky reste disponible pendant que l'agent travaille.
  Future<void> _runAgent(String task) async {
    if (task.isEmpty) {
      _set(
        ClickyState.idle,
        reply:
            'Dis-moi ce que l\'agent doit faire, par exemple : '
            '« agent, résume mes devoirs de la semaine ».',
      );
      return;
    }
    agentsRunning++;
    _set(ClickyState.idle, status: '', reply: 'C\'est parti, je m\'en occupe en arrière-plan.');
    unawaited(speak('C\'est parti, je m\'en occupe.'));
    _fadeSoon();
    try {
      final text = await runTask(task);
      agentsRunning--;
      _set(state, reply: 'Agent : $text');
      unawaited(history.add(threadId, ChatMsg(mine: true, text: 'Agent, $task'), app: _appKey));
      unawaited(history.add(threadId, ChatMsg(mine: false, text: text), app: _appKey));
      notify?.call('Clicky : tâche terminée', text);
      if (state == ClickyState.idle) await speak('Ton agent a fini. $text');
    } catch (e) {
      agentsRunning--;
      _set(state, reply: 'L\'agent n\'a pas pu finir : $e');
    }
    _fadeSoon();
  }

  /// Demande la permission avant une action qui envoie ou modifie quelque
  /// chose (aussi utilisée par le pont quand Claude Code agit).
  Future<bool> confirmAction(HubTool tool, Map<String, dynamic> args) async {
    final pc = PcControl.isWrite(tool.name);
    if (pc) {
      if (pcControl == 'off') return false;
      final cmd = '${args['commande'] ?? ''}';
      if (pcControl == 'auto' && !PcControl.dangerous(cmd) && args['admin'] != true) return true;
      return _confirmPc(tool, args);
    }
    onInteractive?.call(true);
    try {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
      if (ctx == null || !ctx.mounted) return false;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.auto_awesome_rounded),
          title: const Text('Clicky veut agir'),
          content: SingleChildScrollView(
            child: Text(
              '${tool.description}\n\n'
              '${args.entries.map((e) => '• ${e.key} : ${e.value}').join('\n')}',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Refuser')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Autoriser')),
          ],
        ),
      );
      return ok == true;
    } finally {
      if (!panelOpen && board == null) onInteractive?.call(false);
    }
  }

  /// Permission pour une commande ou un fichier sur le PC : on montre
  /// exactement ce qui va être lancé.
  Future<bool> _confirmPc(HubTool tool, Map<String, dynamic> args) async {
    onInteractive?.call(true);
    try {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
      if (ctx == null || !ctx.mounted) return false;
      final command = tool.name == 'pc_commande';
      final why = '${args['pourquoi'] ?? ''}'.trim();
      final body = command
          ? '${args['commande'] ?? ''}'
          : '${args['chemin'] ?? ''}\n\n${'${args['contenu'] ?? ''}'.characters.take(1500)}';
      final danger = command && PcControl.dangerous('${args['commande'] ?? ''}');
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: Icon(
            danger ? Icons.warning_amber_rounded : Icons.terminal_rounded,
            color: danger ? Colors.orange : null,
          ),
          title: Text(
            command
                ? (args['admin'] == true
                      ? 'Clicky veut lancer une commande (administrateur)'
                      : 'Clicky veut lancer une commande')
                : (args['ajouter'] == true ? 'Clicky veut compléter un fichier' : 'Clicky veut écrire un fichier'),
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (why.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(why)),
                  if (danger)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Attention : cette commande peut effacer des données ou changer le système. '
                        'Autorise seulement si c\'est bien ce que tu as demandé.',
                        style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      body,
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Refuser')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Autoriser')),
          ],
        ),
      );
      return ok == true;
    } finally {
      if (!panelOpen && board == null) onInteractive?.call(false);
    }
  }

  static final _tagRe = RegExp(r'\[POINT:\s*([^\]]*)\]', caseSensitive: false);

  /// Sépare le texte et la balise [POINT:x,y:libellé(:screenN)].
  /// Renvoie (texte, point, libellé, numéro d'écran à partir de 1).
  static (String, Offset?, String, int) parsePoint(String raw) {
    final m = _tagRe.allMatches(raw).lastOrNull;
    final text = raw.replaceAll(_tagRe, '').trim();
    if (m == null) return (text, null, '', 1);
    final inner = m.group(1)!.trim();
    final c = RegExp(r'^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(?::\s*(.*))?$')
        .firstMatch(inner);
    if (c == null) return (text, null, '', 1);
    var label = (c.group(3) ?? '').trim();
    var screen = 1;
    final s = RegExp(r':?\s*screen\s*(\d+)\s*$', caseSensitive: false).firstMatch(label);
    if (s != null) {
      screen = int.parse(s.group(1)!);
      label = label.substring(0, s.start).trim();
    }
    return (text, Offset(double.parse(c.group(1)!), double.parse(c.group(2)!)), label, screen);
  }
}

/// Couche posée au-dessus de toute l'appli (voir `MaterialApp.builder`).
class ClickyLayer extends StatefulWidget {
  const ClickyLayer({super.key, required this.child, this.hub});
  final Widget child;
  final HubController? hub;

  @override
  State<ClickyLayer> createState() => _ClickyLayerState();
}

class _ClickyLayerState extends State<ClickyLayer> {
  final c = ClickyController.instance;
  late final OverlayEntry _entry = OverlayEntry(builder: _build);

  @override
  void initState() {
    super.initState();
    c.hub = widget.hub;
    HardwareKeyboard.instance.addHandler(c.onKey);
    ClaudeApi.store.addListener(_settingsChanged);
    _settingsChanged();
    // Compagnons : ils travaillent avec les actions de Mon Hub (directement,
    // ou par le pont local pour Clicky partout).
    Buddies.instance
      ..runner = c.runBuddyTask
      ..onDone = (title, body) {
        c.notify?.call(title, body);
        if (c.state == ClickyState.idle) unawaited(c.speak('$title. ${body.split('\n').first}'));
      };
    if (widget.hub != null) {
      // Routines (briefing du matin…) : faites par Mon Hub, qui a les modules.
      // L'assistant personnel : il prend les devants (avec ton accord).
      Assistant.instance
        ..notify = ((title, body) {
          c.notify?.call(title, body);
          // Clicky le dit lui-même, à côté de la souris (il est « présent »).
          unawaited(c.think(title));
        })
        ..present = ((title, text) => c.presentTopo(title, text))
        ..start(
          call: (name, args) async => c.hubTools.where((t) => t.name == name).firstOrNull?.run(args),
          tools: () => {for (final t in c.hubTools) t.name},
        );
      final r = Routines.instance
        // Le briefing du matin est préparé par Mon Hub (sans Claude) ; les
        // autres routines par le cerveau de Clicky.
        ..runner = ((task) => task == Routine.topoMorningPrompt && Assistant.instance.briefingOn
            ? Assistant.instance.morningBriefing(name: c.callName)
            : c.runTask(task))
        ..onDone = (routine, run) async {
          c.notify?.call(routine.name, run.text);
          if (routine.isTopo && run.ok) {
            // Le topo s'affiche en grand chez Clicky (partout ou dans l'appli),
            // et part sur le téléphone si ntfy est configuré.
            final topic = Carnet.instance.setting<String>('ntfy', '');
            if (topic.isNotEmpty) {
              unawaited(PhoneNotify.send(topic, routine.name, run.text).catchError((Object _) {}));
            }
            if (c.handledElsewhere) {
              await ClickyDesktop.launch();
              await ClickyDesktop.send(
                'show64 ${base64Encode(utf8.encode(jsonEncode({'t': routine.name, 'x': run.text, 'v': true})))}',
              );
            } else {
              // Les briefings sont toujours lus à voix haute.
              await c.presentTopo(routine.name, run.text);
            }
          } else if (run.ok && routine.speak && c.state == ClickyState.idle) {
            unawaited(c.speak('${routine.name}. ${run.text}'));
          }
        };
      r.start();
      unawaited(c.loadMemory());
      // Le Carnet (protocoles) parle et utilise les outils de Mon Hub.
      CarnetModule.say = c.speak;
      CarnetModule.callTool = (name, args) async {
        final t = c.hubTools.where((x) => x.name == name).firstOrNull;
        if (t == null) throw 'Outil introuvable : $name';
        return t.run(args);
      };
      // Historique du presse-papier (si activé dans le Carnet).
      ClipboardVault.start(
        () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        sensitive: () => Win.supportedHere && isSensitiveTitle(Win.foregroundTitle()),
      );
      // Outils des serveurs MCP ajoutés dans les réglages.
      unawaited(McpTools.refresh(force: true));
    }
  }

  void _settingsChanged() => unawaited(c.refreshReady());

  @override
  void didUpdateWidget(ClickyLayer old) {
    super.didUpdateWidget(old);
    c.hub = widget.hub;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_entry.mounted) _entry.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(c.onKey);
    ClaudeApi.store.removeListener(_settingsChanged);
    if (widget.hub != null) {
      Routines.instance.stop();
      Assistant.instance.stop();
      ClipboardVault.stop();
    }
    super.dispose();
  }

  Widget _build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) => _move(e.position, e.kind),
      onPointerMove: (e) => _move(e.position, e.kind),
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(key: c.shotKey, child: widget.child),
          ),
          if (widget.hub != null)
            Positioned.fill(
              child: ListenableBuilder(
                listenable: Listenable.merge([c, ClaudeApi.store]),
                // Sans cerveau configuré (ou désactivé) : aucun Clicky.
                builder: (context, _) =>
                    c.active && !c.handledElsewhere ? ClickyBuddy(c: c) : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }

  void _move(Offset p, PointerDeviceKind kind) {
    if (kind == PointerDeviceKind.mouse) c.moveCursor(p);
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

const clickyBlue = Color(0xFF3B82F6);

/// Le curseur bleu, la petite boîte de texte et le bouton.
class ClickyBuddy extends StatefulWidget {
  const ClickyBuddy({super.key, required this.c});
  final ClickyController c;

  @override
  State<ClickyBuddy> createState() => _ClickyBuddyState();
}

class _ClickyBuddyState extends State<ClickyBuddy> {
  ClickyController get c => widget.c;

  /// Endroit où la boîte s'est ouverte : elle reste là (au lieu de suivre la
  /// souris) pour qu'on puisse cliquer dedans et écrire.
  Offset? _anchor;
  bool _wasOpen = false;
  Offset _holoAt = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final mobile = size.width < 600;
    final cursor = c.follow ? c.cursor : null;
    final home = cursor == null
        ? Offset(size.width - 44, size.height - (mobile ? 150 : 60))
        : cursor + (c.alive ? const Offset(10, 10) : const Offset(18, 16));
    final at = c.target ?? c.gaze ?? home;

    final open = c.boxOpen;
    if (open && !_wasOpen) _anchor = cursor;
    // On attrape la barre du haut de la boîte pour la déplacer.
    c.onDragBox = (d, start) {
      if (mobile) return;
      setState(() => _anchor = (_anchor ?? cursor ?? Offset(size.width / 2, size.height / 2)) + d);
    };
    _wasOpen = open;
    final nearMouse = !mobile && _anchor != null;
    const boxW = 320.0;
    final a = _anchor ?? Offset.zero;
    // À droite et sous la souris, sans sortir de la fenêtre.
    final left = (a.dx + 30 + boxW > size.width ? a.dx - boxW - 10 : a.dx + 30)
        .clamp(8.0, math.max(8.0, size.width - boxW - 8))
        .toDouble();
    final top = (a.dy + 34).clamp(8.0, math.max(8.0, size.height - 300)).toDouble();

    return Stack(
      children: [
        // Les dessins de Clicky (flèches, cercles…), sur toute la fenêtre.
        if (c.marks.isNotEmpty)
          Positioned.fill(
            child: ClickyMarksView(
              key: ValueKey(c.marksId),
              marks: c.marks,
              color: c.hud ? hudCyan : clickyBlue,
              hold: Duration(seconds: c.slow ? 7 : 4),
              onDone: c.clearMarks,
            ),
          ),
        // Le petit curseur bleu de Clicky (suit la souris, vole vers la cible).
        AnimatedOpacity(
          opacity: c.buddyVisible ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Stack(
            children: [
              _Flight(
                to: at,
                flying: c.target != null || c.gaze != null,
                slow: c.slow,
                c: c,
                child: IgnorePointer(child: _PointerWithLabel(c: c)),
              ),
            ],
          ),
        ),
        // La boîte de texte, là où est la souris (en bas sur téléphone).
        Positioned(
          left: nearMouse ? left : (mobile ? 16 : null),
          right: nearMouse ? null : 16,
          top: nearMouse ? top : null,
          bottom: nearMouse ? null : (mobile ? 150 : 76),
          width: mobile ? null : boxW,
          child: ClickyPopIn(
            open: open,
            alignment: nearMouse ? Alignment.topLeft : Alignment.bottomRight,
            child: ClickyBox(c: c),
          ),
        ),
        // L'hologramme 3D, en haut à gauche (déplaçable).
        if (c.holo != null)
          Positioned(
            left: 16 + _holoAt.dx,
            right: mobile ? 16 : null,
            top: 16 + _holoAt.dy,
            width: mobile ? null : math.min(440, size.width - 32),
            child: GestureDetector(
              onPanUpdate: (d) => setState(() => _holoAt += d.delta),
              child: HoloView(key: ValueKey(c.holo), scene: c.holo!, onClose: c.closeHolo),
            ),
          ),
        // Le tableau visuel, sur le côté (en haut sur téléphone).
        if (c.board != null)
          Positioned(
            right: 16,
            left: mobile ? 16 : null,
            top: 16,
            bottom: mobile ? size.height * 0.45 : 76,
            width: mobile ? null : math.min(500, size.width - 32),
            child: Align(
              alignment: Alignment.topRight,
              child: ClickyBoardView(
                key: ValueKey(c.board),
                board: c.board!,
                busy: c.state == ClickyState.thinking || c.state == ClickyState.listening,
                onClose: c.closeBoard,
                onAsk: c.ask,
              ),
            ),
          ),
        // Bouton toujours accessible dans l'appli (indispensable sur téléphone).
        Positioned(
          right: 16,
          bottom: mobile ? 88 : 16,
          child: _Fab(c: c),
        ),
      ],
    );
  }
}

class _PointerWithLabel extends StatelessWidget {
  const _PointerWithLabel({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: c.flightPose,
    builder: (context, _, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final label = c.state == ClickyState.pointing && c.targetLabel.isNotEmpty
        ? c.targetLabel
        : (c.gaze != null && c.gazeNote.isNotEmpty ? c.gazeNote : '');
    final flying = c.flightScale != 1 || c.flightAngle != 0;
    return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ClickyAlive(
        moving: c.alive && c.state != ClickyState.pointing && !flying,
        bootAt: c.bootAt,
        base: c.state == ClickyState.pointing || !c.alive ? Offset.zero : const Offset(8, 6),
        // En vol : la pointe suit le sens du vol et il grossit un peu.
        child: Transform.rotate(
          angle: c.flightAngle,
          alignment: Alignment.topLeft,
          child: Transform.scale(scale: c.flightScale, alignment: Alignment.topLeft, child: _Pointer(c: c)),
        ),
      ),
      if (label.isNotEmpty && !flying)
        TweenAnimationBuilder<double>(
          key: ValueKey(label),
          tween: Tween(begin: 0.5, end: 1),
          duration: const Duration(milliseconds: 380),
          curve: Curves.elasticOut,
          builder: (context, s, child) => Transform.scale(scale: s, alignment: Alignment.centerLeft, child: child),
          child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          margin: EdgeInsets.only(left: 4, top: c.hud ? 22 : 14),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.hud ? hudGlass : clickyBlue,
            borderRadius: BorderRadius.circular(c.hud ? 4 : 12),
            border: c.hud ? Border.all(color: hudCyan) : null,
            boxShadow: [
              BoxShadow(
                blurRadius: 8,
                color: c.hud ? hudCyan.withValues(alpha: 0.4) : const Color(0x33000000),
              ),
            ],
          ),
          child: TypedText(
            c.hud ? label.toUpperCase() : label,
            key: ValueKey('typed-$label'),
            style: TextStyle(
              color: c.hud ? hudCyan : Colors.white,
              fontWeight: FontWeight.w600,
              letterSpacing: c.hud ? 1.2 : null,
            ),
          ),
        ),
        ),
    ],
  );
  }
}

/// Ouverture / fermeture animée : la boîte grandit depuis le curseur en
/// rebondissant légèrement, et se replie en s'effaçant.
class ClickyPopIn extends StatelessWidget {
  const ClickyPopIn({
    super.key,
    required this.open,
    required this.child,
    this.alignment = Alignment.topLeft,
  });

  final bool open;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 170),
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    // Le rebond (qui dépasse 1) ne s'applique qu'à la taille, jamais au
    // fondu : l'animation reste entre 0 et 1.
    transitionBuilder: (child, anim) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: const Interval(0, 0.6)),
      child: ScaleTransition(
        alignment: alignment,
        scale: Tween(begin: 0.55, end: 1.0).animate(
          CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutBack,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    ),
    child: open
        ? KeyedSubtree(key: const ValueKey('ouverte'), child: child)
        : const SizedBox.shrink(key: ValueKey('fermée')),
  );
}

/// Contenu de la petite fenêtre de « Clicky partout » : la fenêtre elle-même
/// suit la souris, le bout du curseur bleu est dans son coin haut-gauche, et
/// la boîte de texte s'ouvre juste à côté.
class ClickyFollower extends StatelessWidget {
  const ClickyFollower({
    super.key,
    required this.c,
    required this.interactive,
    this.pointerAt = Offset.zero,
    this.marks = const [],
  });
  final ClickyController c;
  final bool interactive;

  /// Position du curseur dans la fenêtre (elle s'agrandit pendant un dessin).
  final Offset pointerAt;

  /// Dessins, déjà ramenés dans le repère de la fenêtre.
  final List<ClickyMark> marks;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (marks.isNotEmpty)
          Positioned.fill(
            // Un clic dans la zone efface les dessins (ils ne gênent pas).
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => c.clearMarks(),
              child: ClickyMarksView(
                key: ValueKey(c.marksId),
                marks: marks,
                color: c.hud ? hudCyan : clickyBlue,
                hold: Duration(seconds: c.slow ? 7 : 4),
                onDone: c.clearMarks,
              ),
            ),
          ),
        Positioned(
          left: pointerAt.dx,
          top: pointerAt.dy,
          child: IgnorePointer(child: _PointerWithLabel(c: c)),
        ),
        Positioned(
          left: pointerAt.dx + 22,
          top: pointerAt.dy + 22,
          right: marks.isEmpty ? 4 : null,
          width: marks.isEmpty ? null : 380,
          bottom: c.board != null || c.holo != null ? 4 : null,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.holo != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: HoloView(
                      key: ValueKey(c.holo),
                      scene: c.holo!,
                      onClose: c.closeHolo,
                      compact: c.board != null,
                    ),
                  ),
                if (c.board != null)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ClickyBoardView(
                        key: ValueKey(c.board),
                        board: c.board!,
                        busy: c.state == ClickyState.thinking || c.state == ClickyState.listening,
                        onClose: c.closeBoard,
                        onAsk: c.ask,
                      ),
                    ),
                  ),
                ClickyPopIn(
                  open: c.boxOpen && c.state != ClickyState.pointing,
                  child: ClickyBox(c: c, compact: c.board != null),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Vol du curseur : suit la souris de près, et fait un arc (courbe de
/// Bézier) quand il part montrer quelque chose.
class _Flight extends StatefulWidget {
  const _Flight({required this.to, required this.flying, required this.child, required this.c, this.slow = false});
  final Offset to;
  final bool flying;
  final Widget child;
  final ClickyController c;

  /// Mode lent : vol 1,7 × plus lent (plus facile à suivre).
  final bool slow;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  ClickyFlight? _fl;
  late Offset _pos = widget.to;

  @override
  void initState() {
    super.initState();
    _a.addListener(() {
      final fl = _fl;
      if (fl == null) return;
      final t = _a.value;
      setState(() => _pos = fl.positionAt(t));
      widget.c.setFlight(t >= 1 ? 0 : fl.angleAt(t), t >= 1 ? 1 : fl.scaleAt(t));
    });
  }

  @override
  void didUpdateWidget(_Flight old) {
    super.didUpdateWidget(old);
    if (old.to == widget.to) return;
    final arc = widget.flying != old.flying || (widget.to - _pos).distance > 300;
    if (arc) {
      final fl = _fl = ClickyFlight(_pos, widget.to, DateTime.now());
      _a.duration = fl.duration * (widget.slow ? 1.7 : 1);
      _a.forward(from: 0);
    } else if (!_a.isAnimating) {
      _pos = widget.to;
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Positioned(left: _pos.dx - 2, top: _pos.dy - 2, child: widget.child);
}

/// Un texte qui s'écrit lettre par lettre (30 à 60 ms), comme s'il parlait.
class TypedText extends StatefulWidget {
  const TypedText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<TypedText> {
  int _n = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _next();
  }

  void _next() {
    if (_n >= widget.text.length) return;
    _t = Timer(Duration(milliseconds: 30 + math.Random().nextInt(30)), () {
      if (!mounted) return;
      setState(() => _n++);
      _next();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.text.substring(0, _n), style: widget.style);
}

class _Pointer extends StatelessWidget {
  const _Pointer({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final thinking = c.state == ClickyState.thinking;
    if (c.hud) {
      final mode = switch (c.state) {
        ClickyState.listening => HudMode.listening,
        ClickyState.thinking => HudMode.thinking,
        ClickyState.speaking => HudMode.speaking,
        ClickyState.pointing => HudMode.pointing,
        _ => HudMode.idle,
      };
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // Le bout du réacteur reste au même endroit que la pointe du curseur.
          Transform.translate(
            offset: Offset(
              mode == HudMode.pointing ? -27 : -4,
              mode == HudMode.pointing ? -27 : -4,
            ),
            child: HudReactor(mode: mode, levels: c.levels, size: 34),
          ),
          if (c.agentsRunning > 0)
            Positioned(
              left: 24,
              top: 22,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(color: hudAmber, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  '${c.agentsRunning}',
                  style: const TextStyle(color: Colors.black, fontSize: 10),
                ),
              ),
            ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 26,
          height: 26,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (thinking)
                const Positioned(
                  left: -6,
                  top: -6,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(strokeWidth: 2, color: clickyBlue),
                  ),
                ),
              CustomPaint(size: const Size(22, 22), painter: _TrianglePainter()),
              if (c.agentsRunning > 0)
                Positioned(
                  right: -4,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${c.agentsRunning}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Petite onde qui bouge avec ta voix.
class _Wave extends StatelessWidget {
  const _Wave({required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 2, top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: clickyBlue, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final l in levels)
            AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              width: 3,
              height: 4.0 + 14 * l,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, s.height * 0.42)
      ..lineTo(s.width * 0.45, s.height * 0.55)
      ..lineTo(s.width * 0.32, s.height)
      ..close();
    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(path, Paint()..color = clickyBlue);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Fab extends StatelessWidget {
  const _Fab({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final listening = c.state == ClickyState.listening;
    return Tooltip(
      message: 'Clicky (maintiens Ctrl + Alt pour parler)',
      child: GestureDetector(
        onLongPressStart: (_) => c.startListening(),
        onLongPressEnd: (_) => c.stopListening(),
        child: Material(
          color: listening ? Colors.redAccent : (c.hud ? hudGlass : clickyBlue),
          shape: CircleBorder(side: c.hud ? const BorderSide(color: hudCyan) : BorderSide.none),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => c.panelOpen ? c.closePanel() : c.openPanel(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                color: c.hud && !listening ? hudCyan : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La petite boîte de texte de Clicky, ouverte là où est la souris : ce que
/// tu dis s'y écrit pendant que tu parles, puis la réponse s'y écrit à son
/// tour. On peut aussi y taper sa question, joindre un document, revoir
/// l'historique, passer à l'étape suivante d'une leçon.
class ClickyBox extends StatelessWidget {
  const ClickyBox({super.key, required this.c, this.compact = false});
  final ClickyController c;

  /// Plus petite (le tableau prend déjà de la place au-dessus).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    if (!c.hud) return _content(context, base);
    return Theme(
      data: hudTheme(base),
      child: Builder(builder: (context) => HudFrame(child: _content(context, Theme.of(context)))),
    );
  }

  Widget _content(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final hud = c.hud;
    final accent = hud ? hudCyan : clickyBlue;
    final listening = c.state == ClickyState.listening;
    final busy = c.state == ClickyState.thinking;
    final problem = c.micProblem;
    final name = hud ? 'CLICKY' : 'Clicky';
    final title = switch (c.state) {
      _ when problem != null => 'Souci de micro',
      _ when c.showHistory => 'Historique',
      ClickyState.listening => 'Je t\'écoute…',
      ClickyState.thinking => c.reply.isEmpty ? 'Je réfléchis…' : name,
      _ => name,
    };
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Barre du haut : état, historique, outils, voix, fermer. On
        // l'attrape pour déplacer la boîte.
        GestureDetector(
          onPanStart: (_) => c.onDragBox?.call(Offset.zero, true),
          onPanUpdate: (d) => c.onDragBox?.call(d.delta, false),
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Container(
              color: accent.withValues(alpha: hud ? 0.10 : 0.12),
              padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
              child: Row(
                children: [
                  if (busy)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                        color: listening ? Colors.redAccent : accent,
                        size: 16,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      c.agentsRunning > 0
                          ? '$title · ${c.agentsRunning} agent${c.agentsRunning > 1 ? 's' : ''} au travail'
                          : title,
                      style: text.labelLarge?.copyWith(
                        letterSpacing: hud ? 1.6 : null,
                        color: hud ? hudCyan : null,
                        fontWeight: hud ? FontWeight.w700 : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (LessonRecorder.instance.on)
                    const Tooltip(
                      message: 'Leçon en cours d\'enregistrement',
                      child: Icon(
                        Icons.fiber_manual_record_rounded,
                        color: Colors.redAccent,
                        size: 14,
                      ),
                    ),
                  if (WorkflowCapture.instance.on)
                    const Tooltip(
                      message: 'Gestes en cours de capture',
                      child: Icon(Icons.gesture_rounded, color: Colors.orange, size: 16),
                    ),
                  if (busy || c.voiceOut.speaking)
                    IconButton(
                      tooltip: 'Arrêter (Échap)',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      onPressed: c.cancel,
                    ),
                  IconButton(
                    tooltip: 'Historique des conversations',
                    visualDensity: VisualDensity.compact,
                    isSelected: c.showHistory,
                    icon: const Icon(Icons.history_rounded, size: 18),
                    onPressed: c.toggleHistory,
                  ),
                  _ToolsMenu(c: c),
                  IconButton(
                    tooltip: c.voice ? 'Couper la voix' : 'Remettre la voix',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      c.voice ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      size: 18,
                    ),
                    onPressed: c.toggleVoice,
                  ),
                  IconButton(
                    tooltip: 'Fermer (Échap)',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: c.closeBox,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (hud && !c.showHistory) _HudStrip(c: c),
        if (c.showHistory)
          Flexible(child: _HistoryPeek(c: c))
        else
          Flexible(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Ce que tu dis, écrit en direct.
                  if (listening) ...[
                    if (!hud) _Wave(levels: c.levels) else _HudWave(levels: c.levels),
                    const SizedBox(height: 8),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 120),
                      alignment: Alignment.topLeft,
                      child: Text(
                        c.transcript.isEmpty ? 'Parle, j\'écris…' : c.transcript,
                        style: text.titleMedium?.copyWith(
                          color: c.transcript.isEmpty ? scheme.onSurfaceVariant : null,
                        ),
                      ),
                    ),
                  ] else if (c.transcript.isNotEmpty && c.state != ClickyState.idle)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '« ${c.transcript} »',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  if (problem != null) _MicHelp(c: c, problem: problem),
                  if (c.drawing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(Icons.draw_rounded, size: 16, color: accent),
                          const SizedBox(width: 6),
                          Text('Je dessine au tableau…', style: text.bodySmall),
                        ],
                      ),
                    ),
                  if (!listening && c.status.isNotEmpty && !c.drawing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        c.status,
                        style: text.bodySmall?.copyWith(color: hud ? hudCyan : null),
                      ),
                    ),
                  // La réponse, écrite au fur et à mesure.
                  if (!listening && c.reply.isNotEmpty)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 120),
                      alignment: Alignment.topLeft,
                      child: SelectableText(
                        c.reply,
                        style: text.bodyMedium?.copyWith(height: 1.35),
                      ),
                    ),
                ],
              ),
            ),
          ),
        // Leçon en plusieurs étapes.
        if (c.steps.isNotEmpty && !c.showHistory)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Row(
              children: [
                for (var i = 0; i < c.steps.length; i++)
                  Expanded(
                    child: Container(
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: i <= c.stepIndex ? accent : accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  icon: Icon(
                    c.hasNextStep ? Icons.skip_next_rounded : Icons.check_rounded,
                    size: 18,
                  ),
                  label: Text(c.hasNextStep ? 'Suivant' : 'Terminé'),
                  onPressed: busy ? null : c.nextStep,
                ),
              ],
            ),
          ),
        // Documents joints.
        if (c.docs.isNotEmpty && !c.showHistory)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                for (final d in c.docs)
                  InputChip(
                    avatar: Icon(
                      d.image64 != null ? Icons.image_rounded : Icons.description_rounded,
                      size: 16,
                    ),
                    label: Text(d.name, overflow: TextOverflow.ellipsis),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => c.removeDoc(d),
                  ),
              ],
            ),
          ),
        // Raccourcis pour apprendre.
        if ((c.panelOpen || c.reply.isNotEmpty) &&
            c.state == ClickyState.idle &&
            problem == null &&
            c.steps.isEmpty &&
            !c.showHistory &&
            !compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (c.hasHistory)
                  _QuickChip(
                    icon: Icons.draw_rounded,
                    label: 'Montre-moi en schéma',
                    color: accent,
                    onTap: () => c.ask(ClickyController.visualPrompt),
                  ),
                if (hud)
                  _QuickChip(
                    icon: Icons.dashboard_rounded,
                    label: 'Briefing',
                    color: accent,
                    onTap: () => c.ask('briefing'),
                  ),
                _QuickChip(
                  icon: Icons.school_rounded,
                  label: 'Apprends-moi un truc',
                  color: accent,
                  onTap: () => c.ask(ClickyController.teachPrompt),
                ),
                if (!c.hasHistory)
                  _QuickChip(
                    icon: Icons.screen_search_desktop_rounded,
                    label: 'Explique mon écran',
                    color: accent,
                    onTap: () => c.ask(ClickyController.explainScreenPrompt),
                  ),
                if (Journal.instance.due().isNotEmpty)
                  _QuickChip(
                    icon: Icons.psychology_rounded,
                    label: 'Mes révisions (${Journal.instance.due().length})',
                    color: accent,
                    onTap: () => c.ask('qu\'est-ce que je dois réviser'),
                  ),
              ],
            ),
          ),
        // Écrire (ou parler) une question.
        if (c.panelOpen && !c.showHistory)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Joindre un document (PDF, Word, Excel, image…)',
                  icon: const Icon(Icons.attach_file_rounded),
                  onPressed: busy ? null : c.attachDocuments,
                ),
                Expanded(
                  child: TextField(
                    controller: c.input,
                    focusNode: c.inputFocus,
                    autofocus: true,
                    enabled: !busy,
                    textInputAction: TextInputAction.send,
                    onSubmitted: c.ask,
                    decoration: InputDecoration(
                      hintText: 'Demande-moi quelque chose…',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                if (c.mic)
                  IconButton(
                    tooltip: listening ? 'J\'ai fini' : 'Parler',
                    icon: Icon(listening ? Icons.stop_rounded : Icons.mic_rounded),
                    color: listening ? Colors.redAccent : null,
                    onPressed: busy
                        ? null
                        : () => listening ? c.stopListening() : c.startListening(),
                  ),
                IconButton(
                  tooltip: 'Envoyer',
                  icon: const Icon(Icons.send_rounded),
                  onPressed: busy ? null : () => c.ask(c.input.text),
                ),
              ],
            ),
          )
        else if (c.state == ClickyState.idle && c.reply.isNotEmpty && !c.showHistory)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 6, 6),
              child: TextButton.icon(
                icon: const Icon(Icons.reply_rounded, size: 16),
                label: const Text('Répondre'),
                onPressed: c.openPanel,
              ),
            ),
          ),
      ],
    );
    final box = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: compact ? 520 : 380,
        maxHeight: c.showHistory ? 420 : (compact ? 220 : 400),
      ),
      child: body,
    );
    if (hud) return Material(type: MaterialType.transparency, child: box);
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: box,
    );
  }
}

/// Menu « outils » de la boîte : nouvelle conversation, document, capture
/// de gestes, enregistrement de leçon, pilotage.
class _ToolsMenu extends StatelessWidget {
  const _ToolsMenu({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final cap = WorkflowCapture.instance;
    final rec = LessonRecorder.instance;
    return PopupMenuButton<String>(
      tooltip: 'Outils',
      icon: const Icon(Icons.more_vert_rounded, size: 18),
      onOpened: () => c.onInteractive?.call(true),
      onSelected: (v) async {
        switch (v) {
          case 'new':
            c.newConversation();
          case 'doc':
            await c.attachDocuments();
          case 'capture':
            if (cap.on) {
              cap.stop();
              await c.ask('qu\'est-ce que je viens de faire');
            } else {
              cap.start();
              c.showStatus(
                'Je regarde tes gestes. Fais ta manip, puis redemande « qu\'est-ce que je viens de faire ? ».',
              );
            }
          case 'record':
            if (rec.on) {
              final path = await rec.stop();
              c.showStatus(path == null ? '' : 'Leçon enregistrée dans : $path');
              if (path != null) unawaited(launchUrl(Uri.file(path)));
            } else {
              final path = await rec.start();
              c.showStatus(
                path == null
                    ? 'Impossible de créer le dossier de la leçon.'
                    : 'J\'enregistre la leçon (questions, réponses et captures).',
              );
            }
          case 'buddies':
            final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
            if (ctx != null && ctx.mounted) {
              await showDialog<void>(
                context: ctx,
                builder: (d) => Dialog(
                  child: SizedBox(
                    width: 640,
                    height: 640,
                    child: Column(
                      children: [
                        Align(
                          alignment: Alignment.topRight,
                          child: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(d)),
                        ),
                        const Expanded(child: BuddiesView()),
                      ],
                    ),
                  ),
                ),
              );
            }
          case 'review':
            await c.ask('qu\'est-ce que je dois réviser');
          case 'quiz':
            await c.setOption('quiz', !c.quizMode);
          case 'slow':
            await c.setOption('slow', !c.slow);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'buddies',
          child: ListTile(
            leading: Icon(Icons.cloud_rounded),
            title: Text('Mes compagnons'),
          ),
        ),
        const PopupMenuItem(
          value: 'new',
          child: ListTile(
            leading: Icon(Icons.add_comment_rounded),
            title: Text('Nouvelle conversation'),
          ),
        ),
        const PopupMenuItem(
          value: 'doc',
          child: ListTile(
            leading: Icon(Icons.attach_file_rounded),
            title: Text('Joindre un document'),
          ),
        ),
        const PopupMenuItem(
          value: 'review',
          child: ListTile(
            leading: Icon(Icons.psychology_rounded),
            title: Text('Réviser (journal)'),
          ),
        ),
        CheckedPopupMenuItem(value: 'quiz', checked: c.quizMode, child: const Text('Mode quiz')),
        CheckedPopupMenuItem(value: 'slow', checked: c.slow, child: const Text('Mode lent')),
        if (WorkflowCapture.supported)
          PopupMenuItem(
            value: 'capture',
            child: ListTile(
              leading: const Icon(Icons.gesture_rounded),
              title: Text(cap.on ? 'Arrêter et raconter mes gestes' : 'Capturer mes gestes'),
            ),
          ),
        PopupMenuItem(
          value: 'record',
          child: ListTile(
            leading: Icon(rec.on ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded),
            title: Text(rec.on ? 'Arrêter l\'enregistrement' : 'Enregistrer la leçon'),
          ),
        ),
      ],
    );
  }
}

/// Historique dans la boîte : les dernières conversations, à reprendre.
class _HistoryPeek extends StatelessWidget {
  const _HistoryPeek({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final threads = c.history.threads.take(30).toList();
    if (threads.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Pas encore d\'historique : tes échanges s\'enregistrent ici.'),
      );
    }
    final text = Theme.of(context).textTheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.add_comment_rounded, size: 18),
          title: const Text('Nouvelle conversation'),
          onTap: c.newConversation,
        ),
        for (final t in threads)
          ListTile(
            dense: true,
            title: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (t.app.isNotEmpty) t.app,
                '${dayLabel(t.updated)} ${hhmm(t.updated)}',
                '${t.messages.length ~/ 2} échange${t.messages.length > 3 ? 's' : ''}',
              ].join(' · '),
              style: text.labelSmall,
            ),
            onTap: () => c.continueThread(t),
          ),
      ],
    );
  }
}

/// Onde du look tête haute (barres fines, cyan).
class _HudWave extends StatelessWidget {
  const _HudWave({required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 26,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final l in [...levels.reversed, ...levels])
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            width: 2.5,
            height: 3.0 + 22 * l,
            decoration: BoxDecoration(
              color: hudCyan,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [BoxShadow(color: hudCyan.withValues(alpha: 0.6), blurRadius: 4)],
            ),
          ),
      ],
    ),
  );
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = clickyBlue,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 16, color: color),
    label: Text(label),
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
  );
}

/// Le micro ne marche pas : ce qui se passe, et le bouton qui règle ça.
class _MicHelp extends StatelessWidget {
  const _MicHelp({required this.c, required this.problem});
  final ClickyController c;
  final EarsProblem problem;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final windows = !kIsWeb && Platform.isWindows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 8),
              child: Icon(Icons.mic_off_rounded, color: Colors.redAccent, size: 18),
            ),
            Expanded(child: Text(problem.message, style: text.bodyMedium?.copyWith(height: 1.35))),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            FilledButton.icon(
              icon: c.repairing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_high_rounded, size: 16),
              label: const Text('Clicky répare'),
              onPressed: c.repairing ? null : c.repairMic,
            ),
            if (problem.fixUri != null)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: Text(problem.fixLabel ?? 'Ouvrir les réglages'),
                onPressed: () => openMicFix(context, problem.fixUri!),
              ),
            TextButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Réessayer'),
              onPressed: () {
                c.micProblem = null;
                c.startListening();
              },
            ),
            if (windows)
              TextButton.icon(
                icon: const Icon(Icons.keyboard_voice_rounded, size: 16),
                label: const Text('Dictée Windows (Win + H)'),
                onPressed: c.windowsDictation,
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Bandeau « tête haute » sous la barre : heure, météo, état.
class _HudStrip extends StatelessWidget {
  const _HudStrip({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final city = Carnet.instance.setting<String>('city', '');
    final now = DateTime.now();
    const style = TextStyle(
      color: hudCyan,
      fontSize: 10.5,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w600,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hudCyan.withValues(alpha: 0.25))),
      ),
      child: Row(
        children: [
          Text('${hhmm(now)}  ·  ${dayLabel(now).toUpperCase()}', style: style),
          const Spacer(),
          if (city.isNotEmpty)
            FutureBuilder(
              future: Weather.forCity(city),
              builder: (context, snap) => snap.hasData
                  ? Text(
                      '${snap.data!['icone']} ${snap.data!['temperature']?.round()} °C',
                      style: style,
                    )
                  : const SizedBox.shrink(),
            ),
          if (c.agentsRunning > 0) ...[
            const SizedBox(width: 10),
            Text(
              '${c.agentsRunning} AGENT${c.agentsRunning > 1 ? 'S' : ''}',
              style: style.copyWith(color: hudAmber),
            ),
          ],
          if (c.docs.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text('${c.docs.length} DOC', style: style),
          ],
        ],
      ),
    );
  }
}
