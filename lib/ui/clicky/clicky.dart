import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform, pid;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../party_page.dart';
import 'copy_check.dart';
import 'interpreter.dart';
import 'live_captions.dart';
import 'mind_map.dart';
import 'oral_coach.dart';
import 'video_notes.dart';
import '../../core/ai_text.dart';
import '../../core/claude_api.dart';
import '../../modules/carnet/carnet_module.dart';
import '../../modules/carnet/carnet_store.dart';
import '../../core/claude_bridge.dart';
import '../../core/error_log.dart';
import '../../core/hub_controller.dart';
import '../../core/hub_feed.dart';
import '../../core/hub_files.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import '../../core/prompt_shield.dart';
import '../../core/session.dart';
import '../../core/tool_router.dart';
import '../../core/version.dart';
import '../chat_history.dart';
import '../widgets.dart';
import 'act.dart';
import 'alive.dart';
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
import 'autonomy.dart';
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
import 'thrift.dart';
import 'tutor.dart';
import 'voice.dart';
import 'wake.dart';
import 'whisper.dart';
import 'mic_test.dart' show openMicFix;
import 'win.dart';
import '../../core/freeze_watch.dart';
import 'course_listener.dart';
import 'course_page.dart';
import 'jarvis.dart';
import 'life.dart';
import 'senses.dart';
import 'pc_watch.dart';
import 'watchers.dart';
import 'life_view.dart';
import 'loopback.dart';
import 'shot_encode.dart';
import 'text_fix.dart';
import '../../core/browser_link.dart';
import 'background_tasks.dart';
import '../../core/scam_shield.dart';
import '../../core/browser.dart';
import '../../core/security_check.dart';
import 'catch_up.dart';
import '../../core/screen_time.dart';
import '../../core/everywhere_search.dart';
import '../../core/hub_home.dart';
import '../../core/phone_link.dart';

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
  ClickyController._() {
    // Ouvrir un programme, un script ou un partage réseau : on demande.
    PcControl.confirmRisky = _confirmOpen;
  }
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
    'helpOnly',
    'followUp',
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
    'thrift',
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

  /// « Aider sans faire à ma place » : il explique et guide au lieu de faire
  /// les devoirs (désactivé par défaut : il fait ce qu'on lui demande).
  bool get helpOnly => _opt('helpOnly', false);
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

  /// Conversation continue : après avoir répondu à voix haute, il réécoute
  /// quelques secondes pour la suite (sans raccourci, comme JARVIS).
  bool get followUp => _opt('followUp', true);

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
      agentsRunning > 0 ||
      // Sa vie à lui : une bulle, ou il dort / est assis quelque part.
      lifeNote.isNotEmpty ||
      _lifeHold;

  void moveCursor(Offset p) {
    if (cursor == p) return;
    final old = cursor;
    cursor = p;
    // Sa vie à lui : réveil, caresse, souris secouée…
    if (old != null) _lifeMove(old, p);
    if (old == null || (old - p).distance > 3) {
      final now = DateTime.now();
      // Revenu après une longue absence : nouvelle séance.
      if (now.difference(_lastMove).inMinutes >= 15) _sessionStart = now;
      _lastMove = now;
      // On bouge la souris : Clicky revient tout de suite à côté (sauf s'il
      // dort dans son coin ou s'il est assis sur ta fenêtre).
      if (gaze != null && !_gazeHold && !_lifeHold) {
        gaze = null;
        gazeNote = '';
        notifyListeners();
      }
    }
    // Clicky partout : c'est Windows qui déplace sa fenêtre avec la souris,
    // rien à redessiner (avant : tout Clicky était redessiné 60 fois par
    // seconde dès que la souris bougeait).
    if (!desktopMode && follow && active && state != ClickyState.pointing && buddyVisible) notifyListeners();
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

  /// Il écoute la suite de la conversation (sans raccourci).
  bool following = false;
  Timer? _followTimer;
  bool _followSpoke = false;
  int _followChain = 0;

  /// L'échange en cours a commencé à la voix (la suite s'écoute aussi).
  bool _voiceTurn = false;

  Future<void> startListening({bool dictate = false, bool followUp = false}) async {
    await stopSpeaking();
    if (state == ClickyState.thinking || state == ClickyState.listening) return;
    if (!followUp) _followChain = 0;
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
    _followSpoke = false;
    _set(
      ClickyState.listening,
      status: _dictating
          ? 'Dictée : parle, je tape le texte.'
          : (followUp ? 'Je t\'écoute encore… (sinon, ne dis rien)' : ''),
      reply: '',
    );
    following = followUp && !_dictating;
    if (following) _armFollowTimer();
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
        if (t.trim().isNotEmpty) _followSpoke = true;
        transcript = t;
        _autoSend?.cancel();
        notifyListeners();
      },
      onLevel: (l) {
        if (state != ClickyState.listening) return;
        if (l > 0.4) _followSpoke = true;
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

  /// Conversation continue : sans un mot dans les 6 s, il arrête d'écouter
  /// (rien n'est envoyé, rien ne coûte) ; on ne l'écoute pas plus de 20 s.
  void _armFollowTimer() {
    _followTimer?.cancel();
    bool spoke() => _followSpoke || _liveSpoke || transcript.trim().isNotEmpty;
    _followTimer = Timer(const Duration(seconds: 6), () {
      if (!following || state != ClickyState.listening) return;
      // Ctrl + Alt maintenus : c'est une écoute normale maintenant.
      if (_holding) {
        following = false;
        return;
      }
      if (!spoke()) return _endFollow();
      _followTimer = Timer(const Duration(seconds: 14), () {
        if (!following || state != ClickyState.listening || _holding) return;
        spoke() ? unawaited(stopListening()) : _endFollow();
      });
    });
  }

  void _endFollow() {
    _followChain = 0;
    unawaited(stopListening(send: false).then((_) => _fadeSoon()));
  }

  /// Après une réponse à voix haute : il attend la fin de sa phrase et
  /// réécoute (5 fois de suite au plus, puis il faut le rappeler).
  Future<void> _followUpSoon() async {
    if (_followChain >= 5 || !mic || !_voicePlatform || !active) {
      _followChain = 0;
      return;
    }
    for (var i = 0; i < 600 && (voiceOut.speaking || _livePlayer.playing); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // Un petit temps : il ne s'entend pas lui-même.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (state != ClickyState.idle || _holding || voiceOut.speaking || acting) return;
    _followChain++;
    await startListening(followUp: true);
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
    _voiceTurn = false;
    _followChain = 0;
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
    if (t.isEmpty && following) {
      // La suite de la conversation : rien dit, il arrête sans rien afficher.
      _followChain = 0;
      _set(ClickyState.idle, status: '');
      _fadeSoon();
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
    _spokenAsk = true;
    await ask(t);
  }

  /// La prochaine question vient du micro.
  bool _spokenAsk = false;

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
    _voiceTurn = false;
    _followChain = 0;
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
      idea != null ||
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
      state == ClickyState.idle &&
      !panelOpen &&
      board == null &&
      holo == null &&
      marks.isEmpty &&
      target == null &&
      !_keepReply &&
      idea == null &&
      // Mode concentration ou mode jeu : il ne dit rien de lui-même.
      !FocusMode.instance.active &&
      !GameMode.instance.active;

  int _presenceN = 0;

  Future<void> _presenceTick() async {
    _presenceN++;
    // Toutes les 10 s : le mode concentration (lancé ailleurs ?) et les
    // rappels liés à une appli (« quand j'ouvre Discord »).
    if (_presenceN % 5 == 0) {
      await FocusMode.instance.sync();
      if (DriveRunner.supported) await _checkAppReminder();
    }
    // Ce qu'il voit et entend (préparé en avance).
    if (_presenceN % 15 == 7) unawaited(_refreshSenses());
    // Le point de la situation se prépare en avance (réponse plus rapide).
    if (_presenceN % 30 == 0 && state == ClickyState.idle && active) unawaited(_refreshSituation());
    // Batterie faible : il prévient de lui-même (à 20 % puis à 10 %).
    if (_presenceN % 30 == 15) _checkBattery();
    // Sa vie à lui : sommeil, danse, accessoires, bâillements…
    try {
      await _lifeTick(DateTime.now());
    } catch (_) {}
    if (_lifeHold) return;
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
      // Une fois sur quatre : il va s'asseoir sur ta fenêtre (et tombe si tu
      // la fermes ou la bouges).
      if (mind.life && mind.lifePerch && perchSpot != null && math.Random().nextInt(4) == 0 && _perch()) return;
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
    // Il dormait ou était assis sur ta fenêtre : il se lève d'abord.
    if (_lifeHold) _endRest(quiet: true);
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

  /// « Rappelle-moi de … quand j'ouvre … » : l'appli vient d'arriver au
  /// premier plan, il le dit (une seule fois).
  String _lastFront = '';
  int? _batteryAlerted;

  void _checkBattery() {
    final b = SystemStatus.batteryNow();
    if (b == null) return;
    final (pct, charging) = b;
    if (charging) {
      _batteryAlerted = null;
      return;
    }
    final level = SystemStatus.batteryAlert(pct, charging, _batteryAlerted);
    if (level == null) return;
    _batteryAlerted = level;
    final text = pct <= 10
        ? 'Batterie à $pct %, branche le chargeur tout de suite.'
        : 'Batterie à $pct %, pense à brancher le chargeur.';
    notify?.call('Batterie faible', text);
    final at = cursor;
    if (at != null && state == ClickyState.idle) glance(at + const Offset(40, -30), note: text, hold: const Duration(seconds: 6));
    if (voice && state == ClickyState.idle) unawaited(speak(text));
  }

  Future<void> _checkAppReminder() async {
    if (!active || state != ClickyState.idle) return;
    String title = '';
    try {
      title = Win.foregroundTitle();
    } catch (_) {}
    if (title.trim().isEmpty || title == 'Clicky') return;
    // Seulement quand l'appli **arrive** au premier plan (pas si elle y était
    // déjà quand on a demandé le rappel).
    final changed = title != _lastFront;
    _lastFront = title;
    if (!changed) return;
    final r = await AppReminders.instance.due(title);
    if (r == null) return;
    final text = 'Rappel : ${r.text}';
    notify?.call('Rappel de Clicky', r.text);
    final at = cursor;
    if (at != null) glance(at + const Offset(40, -30), note: text, hold: const Duration(seconds: 8));
    if (voice) unawaited(speak(withoutEmoji(text)));
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

  // ---------- Ses yeux et ses oreilles (v1.58) ----------

  /// Ce qu'il voit et entend en ce moment, pour les consignes de l'IA
  /// (préparé en avance, toutes les 30 s).
  String _sensesBlock = '';

  Future<void> _refreshSenses() async {
    try {
      _sensesBlock = await ClickySenses.promptBlock();
    } catch (_) {
      _sensesBlock = '';
    }
  }

  /// Il ouvre sa boîte et répond à une question sur l'écran (Clicky partout
  /// s'il est là).
  void _explainScreen(String question) {
    if (handledElsewhere) {
      unawaited(ClickyDesktop.send('ask $question'));
      return;
    }
    openPanel();
    unawaited(ask(question));
  }

  // ---------- Sa vie à lui (v1.57) : il dort, rêve, danse, réagit ----------

  /// Clicky partout : son coin pour dormir (en bas de l'écran où est la
  /// souris), et où s'asseoir sur la fenêtre au premier plan (avec le
  /// rectangle de la fenêtre : il tombe si elle bouge ou se ferme).
  Offset? Function()? restSpot;
  (Offset, Rect)? Function()? perchSpot;

  final _shake = WiggleDetector.shake();
  final _pet = WiggleDetector.pet();
  final _rage = RageClickDetector();
  final _beatDetector = BeatDetector();
  StreamSubscription<Uint8List>? _beatSub;
  DateTime _lastAsk = DateTime.now();
  DateTime? _perchUntil;
  DateTime? _nearSince;
  DateTime? _coffeeUntil;
  DateTime? _dreamAt;
  double _wakeMoves = 0;
  int _lifeN = 0;
  bool _lifeLoaded = false;
  Map? _weather;
  DateTime _nextAntic = DateTime.now().add(const Duration(minutes: 40));
  int _anticsToday = 0;
  String _anticDay = '';
  Timer? _restNoteEnd;

  /// Il dort dans son coin, ou il est assis sur ta fenêtre.
  bool get _lifeHold => ClickyLife.instance.asleep || ClickyLife.instance.perched;

  bool get _lifeOn => active && ClickyMind.instance.on && ClickyMind.instance.life;

  String _lifeBlock() {
    final m = ClickyMind.instance;
    if (!m.on || !m.life) return '';
    return ClickyLife.instance.promptBlock(DateTime.now());
  }

  /// Une phrase de lui-même, en bulle **muette**, seulement si les garde-fous
  /// le permettent (rare, jamais en plein écran ni quand il est occupé).
  bool _lifeSay(String text, {int seconds = 5, bool force = false}) {
    final life = ClickyLife.instance;
    final now = DateTime.now();
    if (!_calm || (fullscreenNow?.call() ?? false)) return false;
    if (!force && !life.mayTalk(now)) return false;
    life.talked(now);
    // Assis ou endormi : la bulle s'affiche là où il est, sans le déplacer.
    if (_lifeHold) {
      gazeNote = text;
      notifyListeners();
      _restNoteEnd?.cancel();
      _restNoteEnd = Timer(Duration(seconds: seconds) + Duration(milliseconds: text.length * 45), () {
        if (gazeNote == text) {
          gazeNote = '';
          notifyListeners();
        }
      });
      return true;
    }
    // Sinon, une petite bulle qui le suit (elle ne s'en va pas dès qu'on
    // bouge la souris).
    lifeNote = text;
    notifyListeners();
    _lifeNoteEnd?.cancel();
    _lifeNoteEnd = Timer(Duration(seconds: seconds) + Duration(milliseconds: text.length * 45), () {
      if (lifeNote == text) {
        lifeNote = '';
        notifyListeners();
      }
    });
    return true;
  }

  /// Sa petite bulle à lui (suit la souris).
  String lifeNote = '';
  Timer? _lifeNoteEnd;

  /// La souris bouge : réveil, caresse, ou tête qui tourne.
  void _lifeMove(Offset old, Offset p) {
    final life = ClickyLife.instance;
    if (!_lifeOn) return;
    final ms = DateTime.now().millisecondsSinceEpoch;
    if (life.asleep) {
      _wakeMoves += (p - old).distance;
      if (_wakeMoves >= 160) _wakeUp();
      return;
    }
    if (life.perched) {
      final at = gaze;
      if (at == null) {
        _endRest(quiet: true);
        return;
      }
      if ((p - at).distance < 70) {
        if (_pet.add(ms, p.dx)) {
          _petted();
          return;
        }
        final since = _nearSince ??= DateTime.now();
        // La souris vient le chercher : il saute dessus.
        if (DateTime.now().difference(since) > const Duration(milliseconds: 1600)) {
          life.show('😊', seconds: 2);
          _endRest(quiet: true);
        }
      } else {
        _nearSince = null;
      }
      return;
    }
    if (ClickyMind.instance.lifeReact &&
        state == ClickyState.idle &&
        _shake.add(ms, p.dx) &&
        // Dans un jeu, la souris bouge vite exprès.
        !(DriveRunner.supported && ClickyLife.gameLike(Win.foregroundExe(), Win.foregroundTitle()))) {
      _dizzy();
    }
  }

  void _petted() {
    final life = ClickyLife.instance;
    final now = DateTime.now();
    life.show('🥰', seconds: 3);
    _nearSince = now;
    _perchUntil = now.add(const Duration(seconds: 20));
    unawaited(ClickyMind.instance.petted(now: now));
    if (life.mayEmoji('caresse-texte', now, const Duration(minutes: 30))) {
      _lifeSay(const ['rrr… ♥', 'Hé, ça chatouille !', 'Encore, encore !'][now.second % 3], seconds: 2);
    }
  }

  void _dizzy() {
    final life = ClickyLife.instance;
    final now = DateTime.now();
    life.wobble.value++;
    life.show('😵‍💫', seconds: 3);
    if (life.mayEmoji('tournis-texte', now, const Duration(minutes: 20))) {
      _lifeSay(
        const ['Ouh là… la tête qui tourne !', 'Doucement, j\'ai le mal de mer !', 'Waouh, on est où là ?'][now.second % 3],
        seconds: 3,
      );
    }
  }

  /// Un clic (Clicky partout) : il se réveille, ou s'inquiète si tu
  /// cliques comme un fou (sauf dans un jeu).
  void userClicked() {
    final life = ClickyLife.instance;
    if (!_lifeOn) return;
    if (life.asleep) {
      _wakeUp();
      return;
    }
    final p = cursor;
    if (!ClickyMind.instance.lifeReact || state != ClickyState.idle || p == null) return;
    if (!_rage.add(DateTime.now().millisecondsSinceEpoch, p.dx, p.dy)) return;
    if (DriveRunner.supported && ClickyLife.gameLike(Win.foregroundExe(), Win.foregroundTitle())) return;
    final now = DateTime.now();
    life.show('😬', seconds: 3);
    if (life.mayEmoji('clics-texte', now, const Duration(minutes: 30))) {
      _lifeSay('Ça bloque ? Maintiens Ctrl + Alt et dis-moi ce qui se passe, je regarde.', seconds: 6);
    }
  }

  /// Toutes les 2 secondes : sommeil, bâillements, danse, accessoire, ennui.
  Future<void> _lifeTick(DateTime now) async {
    final life = ClickyLife.instance;
    final mind = ClickyMind.instance;
    if (!_lifeLoaded) {
      _lifeLoaded = true;
      try {
        await mind.load();
      } catch (_) {}
      life.restore(mind.lifeState);
    }
    if (!_lifeOn) {
      if (_lifeHold) _endRest(quiet: true);
      life.refreshAccessory(now, off: true);
      if (_beatSub != null) await _stopDance();
      return;
    }
    _lifeN++;
    // Réglages changés dans Mon Hub (fichier partagé) : relus toutes les 30 s.
    if (_lifeN % 15 == 0) unawaited(mind.load().catchError((Object _) {}));
    life.pace = mind.lifePace;
    final windows = DriveRunner.supported;
    final idleSecs = windows ? Win.idleSeconds() : now.difference(_lastMove).inSeconds;
    final fullscreen = fullscreenNow?.call() ?? false;
    // La vraie météo (toutes les 30 min) et les fêtes : son accessoire.
    if (_lifeN % 900 == 1 || (_weather == null && _lifeN % 150 == 10)) unawaited(_refreshWeather());
    final day = now.toIso8601String().substring(0, 10);
    // Le matin, au premier signe de vie : son café (et un rêve à raconter).
    if (now.hour >= 5 && now.hour < 11 && idleSecs < 30 && life.once('cafe:$day')) {
      _coffeeUntil = now.add(const Duration(minutes: 25));
      if (life.dreamDue(const Duration(hours: 8), now)) _dreamAt = now.add(const Duration(seconds: 50));
    }
    final coffee = _coffeeUntil != null && now.isBefore(_coffeeUntil!);
    final said = life.refreshAccessory(now, weather: _weather, coffee: coffee);
    // Sa musique (toutes les 16 s) : il danse. Pas en plein écran, ni en
    // mode concentration ou mode jeu.
    final quietMode = fullscreen || FocusMode.instance.active || GameMode.instance.active;
    if (_lifeN % 8 == 3) unawaited(_checkDance(quietMode).catchError((Object _) {}));
    if (!_calm || fullscreen) return;
    if (said != null && !life.asleep) _lifeSay('${life.accessory} $said', seconds: 6);
    final dreamAt = _dreamAt;
    if (dreamAt != null && now.isAfter(dreamAt) && !_lifeHold) {
      _dreamAt = null;
      unawaited(_tellDream());
      return;
    }
    if (life.perched) {
      _perchCheck(now);
      return;
    }
    if (life.asleep) {
      // Tu tapes au clavier (sans toucher la souris) : il se réveille aussi.
      final slept = now.difference(life.sleptAt ?? now);
      if (windows && idleSecs <= 2 && slept > const Duration(seconds: 10)) _wakeUp();
      return;
    }
    // 4 minutes sans toi (et pas de musique) : il s'endort dans son coin.
    if (idleSecs >= 240 && !life.dancing) {
      _fallAsleep();
      return;
    }
    if (idleSecs >= 60) return;
    // Il est tard : il bâille (émoji), et le dit une fois par soir.
    if (ClickyLife.sleepyAt(now) && life.mayEmoji('baille', now, const Duration(minutes: 20))) {
      life.show('🥱', seconds: 3);
      final night = now.hour < 6 ? now.subtract(const Duration(days: 1)) : now;
      if (life.once('nuit:${night.toIso8601String().substring(0, 10)}')) {
        final when = now.hour == 0 ? 'minuit passé' : '${now.hour} h passées';
        _lifeSay('Il est $when… moi je commence à fatiguer. Et toi ?', seconds: 5);
      }
      return;
    }
    // Il s'ennuie (pas un mot depuis 1 h 30) : il s'occupe, sans un mot.
    if (day != _anticDay) {
      _anticDay = day;
      _anticsToday = 0;
    }
    if (now.difference(_lastAsk).inMinutes >= 90 && now.isAfter(_nextAntic) && _anticsToday < (life.discreet ? 2 : 4)) {
      _nextAntic = now.add(Duration(minutes: 40 + math.Random().nextInt(40)));
      _anticsToday++;
      life.show(ClickyLife.antics[math.Random().nextInt(ClickyLife.antics.length)], seconds: 4);
    }
  }

  Future<Object?> _lifeCall(String name, [Map<String, dynamic> args = const {}]) async {
    try {
      return await _tools.where((t) => t.name == name).firstOrNull?.run(args);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshWeather() async {
    final w = await _lifeCall('carnet_meteo');
    if (w is Map && w['temperature'] != null) _weather = w;
  }

  void _fallAsleep() {
    final life = ClickyLife.instance;
    life.show('🥱', seconds: 2);
    Timer(const Duration(milliseconds: 1800), () {
      if (!_lifeOn || !_calm || _lifeHold) return;
      if (DriveRunner.supported && Win.idleSeconds() < 200) return;
      life.fallAsleep();
      _wakeMoves = 0;
      final spot = restSpot?.call();
      if (spot != null) {
        _gazeEnd?.cancel();
        gaze = spot;
        gazeNote = '';
        notifyListeners();
      }
    });
  }

  /// Réveillé par la souris ou le clavier : sursaut, bâillement, et parfois
  /// le rêve qu'il a fait.
  void _wakeUp() {
    final life = ClickyLife.instance;
    if (!life.asleep) return;
    final slept = life.wake();
    final now = DateTime.now();
    life.wokeNow(now);
    _wakeMoves = 0;
    if (gaze != null) {
      gaze = null;
      gazeNote = '';
      notifyListeners();
    }
    unawaited(ClickyMind.instance.saveLife(life.toJson()));
    if (slept < const Duration(seconds: 30)) return;
    life.show('😮', seconds: 1.2);
    Timer(const Duration(milliseconds: 1300), () {
      if (!life.asleep) life.show('🥱', seconds: 2.5);
    });
    if (life.dreamDue(slept, now)) _dreamAt = now.add(const Duration(seconds: 8));
  }

  /// Il raconte le rêve qu'il a fait (une fois par jour, en bulle muette).
  Future<void> _tellDream() async {
    final life = ClickyLife.instance;
    final now = DateTime.now();
    if (!_lifeOn || !life.dreamDue(const Duration(hours: 1), now)) return;
    var app = '', artist = '';
    final st = await _lifeCall('temps_ecran', {'periode': 'hier'});
    if (st is Map && st['applis'] is List) {
      for (final a in st['applis'] as List) {
        final name = a is Map ? '${a['appli'] ?? ''}' : '';
        if (name.isNotEmpty && name != 'Mon Hub' && !name.startsWith('Navigateur') && name != 'Explorateur') {
          app = name;
          break;
        }
      }
    }
    final m = await _lifeCall('musique_joue');
    if (m is Map) artist = '${m['artiste'] ?? ''}'.trim();
    var memory = ClickyMind.instance.episodes.where((e) => e.kind != 'attente').firstOrNull?.text ?? '';
    if (memory.length > 70) memory = '';
    var dream = ClickyLife.dreamFrom(app: app, artist: artist, memory: memory);
    if (await AiText.hasGemini()) {
      try {
        final r = await AiText.ask(
          ClickyLife.dreamPrompt(name: callName, app: app, artist: artist, memory: memory),
          system: 'Tu es Clicky, un petit curseur vivant, drôle et tendre. Français, très court.',
          geminiOnly: true,
        ).timeout(const Duration(seconds: 12));
        dream = ClickyLife.cleanDream(r) ?? dream;
      } catch (_) {}
    }
    // Occupé entre-temps (briefing, question…) : ce sera dans 2 minutes.
    if (!_calm || _lifeHold) {
      _dreamAt = DateTime.now().add(const Duration(minutes: 2));
      return;
    }
    life.dreamt(dream, now);
    unawaited(ClickyMind.instance.saveLife(life.toJson()));
    life.show('🌙', seconds: 4);
    _lifeSay(dream, seconds: 7, force: true);
  }

  /// Il va s'asseoir sur la fenêtre que tu regardes.
  bool _perch() {
    final p = perchSpot?.call();
    if (p == null) return false;
    final (spot, rect) = p;
    final life = ClickyLife.instance;
    life.perch(rect);
    _perchUntil = DateTime.now().add(Duration(seconds: 40 + math.Random().nextInt(50)));
    _nearSince = null;
    _gazeEnd?.cancel();
    gaze = spot;
    gazeNote = '';
    _gazeHold = true;
    _recent = true;
    Timer(const Duration(milliseconds: 900), () => _gazeHold = false);
    notifyListeners();
    life.show('👀', seconds: 2.5);
    return true;
  }

  void _perchCheck(DateTime now) {
    final life = ClickyLife.instance;
    final cur = perchSpot?.call();
    // La fenêtre a bougé, s'est fermée, ou tu es passé à une autre : il tombe !
    if (cur == null || cur.$2 != life.perchedOn) {
      _fall();
      return;
    }
    final until = _perchUntil;
    if (until != null && now.isAfter(until)) _endRest(quiet: true);
  }

  void _fall() {
    final life = ClickyLife.instance;
    final at = gaze;
    life.unperch();
    life.show('😱', seconds: 1.4);
    if (at == null) return;
    glance(at + const Offset(0, 260), hold: const Duration(milliseconds: 700));
    Timer(const Duration(milliseconds: 1700), () => life.show('😅', seconds: 2.5));
  }

  /// Il se lève (réveil discret, ou il descend de ta fenêtre).
  void _endRest({bool quiet = false}) {
    final life = ClickyLife.instance;
    if (life.asleep) {
      if (!quiet) {
        _wakeUp();
        return;
      }
      life.wake();
      life.wokeNow(DateTime.now());
      unawaited(ClickyMind.instance.saveLife(life.toJson()));
    }
    if (life.perched) life.unperch();
    _perchUntil = null;
    _nearSince = null;
    _wakeMoves = 0;
    if (gaze != null) {
      gaze = null;
      gazeNote = '';
      notifyListeners();
    }
  }

  /// Ta musique joue (Clicky partout) : il écoute le son du PC et danse en
  /// rythme (seulement sur une vraie musique, au rythme régulier).
  Future<void> _checkDance(bool quietMode) async {
    final life = ClickyLife.instance;
    var want = !quietMode && desktopMode && LoopbackCapture.supported && ClickyMind.instance.lifeDance && !life.asleep;
    if (want) {
      final r = await _lifeCall('musique_joue');
      want = r is Map && r['en_lecture'] == true;
    }
    if (want && _beatSub == null) {
      _beatDetector.reset();
      life.setDancing(true);
      _beatSub = LoopbackCapture.start().listen(
        (pcm) {
          if (_beatDetector.push(pcm) > 0 && state == ClickyState.idle && !life.asleep) {
            life.onBeat(steady: _beatDetector.steady);
          }
        },
        onError: (Object _) => unawaited(_stopDance()),
      );
    } else if (!want && _beatSub != null) {
      await _stopDance();
    }
  }

  Future<void> _stopDance() async {
    final s = _beatSub;
    _beatSub = null;
    ClickyLife.instance.setDancing(false);
    await s?.cancel();
  }

  /// Une notification de Mon Hub arrive : il réagit (un émoji ; une phrase
  /// seulement pour une note).
  void reactTo(HubNotification n) {
    final mind = ClickyMind.instance;
    if (!active || !mind.on || !mind.life || !mind.lifeReact) return;
    final f = ClickyLife.feelingFor(n.id, n.title, n.body);
    if (f == null) return;
    unawaited(feel(f.$1, text: f.$2));
  }

  /// Ce qu'il ressent, à côté de lui (envoyé à Clicky partout s'il est là).
  Future<void> feel(String emoji, {String? text}) async {
    if (handledElsewhere) {
      await ClickyDesktop.send('feel64 ${base64Encode(utf8.encode(jsonEncode({'e': emoji, 't': text})))}');
      return;
    }
    final life = ClickyLife.instance;
    final now = DateTime.now();
    if (!_lifeOn || life.asleep || !_calm || (fullscreenNow?.call() ?? false)) return;
    if (!life.mayEmoji('notif', now, const Duration(seconds: 20))) return;
    life.show(emoji, seconds: 4);
    // Une très bonne note : il saute de joie.
    if (emoji == '🤩') {
      for (var i = 0; i < 3; i++) {
        Timer(Duration(milliseconds: 260 * i), () => life.beat.value++);
      }
    }
    if (text != null && text.isNotEmpty) _lifeSay(text, seconds: 6);
  }

  // ---------- Autonomie : il décide, propose, et fait après ton accord ----------

  /// L'idée en attente de ta réponse.
  ClickyIdea? idea;
  Timer? _ideaTimeout;
  Timer? _autonomy;
  bool _deciding = false;
  int _lastIdle = 0;
  DateTime _startedAt = DateTime.now();

  /// Il propose une idée (à l'oral et dans sa boîte, avec Oui / Non).
  Future<void> proposeIdea(ClickyIdea i) async {
    if (handledElsewhere) {
      await ClickyDesktop.send('idea64 ${base64Encode(utf8.encode(jsonEncode(i.toJson())))}');
      return;
    }
    if (!active || !_calm) return;
    idea = i;
    _keepReply = true;
    onInteractive?.call(true);
    unawaited(ClickyChime.play());
    _set(ClickyState.speaking, status: 'Une idée', reply: i.say);
    if (voice) await speak(i.say);
    if (idea == i && state == ClickyState.speaking) _set(ClickyState.idle);
    // Sans réponse au bout d'une minute et demie : « plus tard ».
    _ideaTimeout?.cancel();
    _ideaTimeout = Timer(const Duration(seconds: 90), () {
      if (idea == i) unawaited(answerIdea(null));
    });
  }

  /// Ta réponse : oui (il le fait), non (il retient), null (plus tard).
  Future<void> answerIdea(bool? yes) async {
    final i = idea;
    if (i == null) return;
    idea = null;
    _ideaTimeout?.cancel();
    _keepReply = false;
    if (!panelOpen && board == null) onInteractive?.call(false);
    final mind = ClickyMind.instance;
    if (yes != null) unawaited(mind.recordDecision(i.tool, yes));
    if (yes != true) {
      final r = yes == false ? 'D\'accord, je laisse tomber.' : '';
      _set(ClickyState.idle, status: '', reply: r);
      if (r.isNotEmpty) unawaited(speak(r));
      _fadeSoon();
      return;
    }
    await _runIdea(i);
  }

  Future<void> _runIdea(ClickyIdea i) async {
    if (i.tool == 'agent') {
      unawaited(_runAgent('${i.args['tache'] ?? ''}'.trim()));
      return;
    }
    final tool = _tools.where((t) => t.name == i.tool).firstOrNull;
    if (tool == null) {
      _set(ClickyState.idle, status: '', reply: 'Je n\'ai finalement pas accès à ça. Désolé !');
      _fadeSoon();
      return;
    }
    _set(ClickyState.thinking, status: 'C\'est parti…', reply: '');
    try {
      final r = await tool.run(i.args);
      // Le briefing : en grand, et lu à voix haute.
      if (i.tool == 'assistant_briefing' && r is String) {
        await presentTopo('Briefing', r);
        return;
      }
      var say = Autonomy.plainResult(r);
      if ((r is Map || r is List) && say == 'C\'est fait.' && await AiText.hasGemini()) {
        try {
          say = (await AiText.ask(
            'Tu viens de faire ceci pour la personne : ${i.say}\nRésultat (données) : ${jsonEncode(ClaudeBridge.plain(r))}\n'
            'Dis-lui le résultat en une ou deux phrases courtes, à l\'oral, sans liste.',
            system: 'Tu es Clicky, un assistant chaleureux. Français, très court.',
            geminiOnly: true,
          )).trim();
        } catch (_) {}
      }
      _set(ClickyState.speaking, status: '', reply: say);
      await speak(say);
      if (state == ClickyState.speaking) _set(ClickyState.idle);
      _fadeSoon();
    } catch (e) {
      _set(ClickyState.idle, status: '', reply: 'Ça n\'a pas marché : $e');
      _fadeSoon();
    }
  }

  /// Mon Hub (qui a les modules) réfléchit toutes les minutes : faut-il
  /// prendre une initiative ? (Il ne fait rien sans ton accord.)
  void startAutonomy() {
    _autonomy?.cancel();
    _startedAt = DateTime.now();
    _autonomy = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(autonomyTick()));
  }

  void stopAutonomy() {
    _autonomy?.cancel();
    _autonomy = null;
  }

  /// Un tour de réflexion. [now]/[idleSeconds] : pour les tests.
  // ---------- Proactif : le fil de Mon Hub ----------

  final _nudged = <String>{};
  DateTime? _lastNudge;
  var _nudgeDay = '';
  var _nudgesToday = 0;

  /// Relit le fil de Mon Hub (au plus toutes les 3 minutes).
  void _refreshFeed() {
    final h = hub;
    if (h == null) return;
    final tools = {for (final m in h.enabled) for (final t in m.tools) t.name: t};
    unawaited(
      HubFeed.instance
          .refresh(
            call: (name, args) async => tools[name]?.run(args),
            tools: tools.keys.toSet(),
            badges: {for (final m in h.enabled) m.id: m.badge.value},
            names: {for (final m in h.enabled) m.id: m.name},
          )
          .catchError((Object _) {}),
    );
  }

  /// Dit l'info la plus importante du fil, une seule fois par info, au plus
  /// 6 fois par jour et pas plus d'une fois toutes les 45 minutes.
  bool feedNudge(DateTime n) {
    final i = HubFeed.instance.top;
    final line = HubFeed.say(i);
    if (i == null || line == null || i.priority < 75 || _nudged.contains(i.id)) return false;
    final day = '${n.year}-${n.month}-${n.day}';
    if (day != _nudgeDay) {
      _nudgeDay = day;
      _nudgesToday = 0;
    }
    final last = _lastNudge;
    if (_nudgesToday >= 6 || (last != null && n.difference(last) < const Duration(minutes: 45))) return false;
    _nudged.add(i.id);
    _lastNudge = n;
    _nudgesToday++;
    unawaited(think(line));
    return true;
  }

  Future<ClickyIdea?> autonomyTick({DateTime? now, int? idleSeconds, bool propose = true}) async {
    final n = now ?? DateTime.now();
    final mind = ClickyMind.instance;
    // Mode concentration : rien pendant la séance, le bilan à la fin.
    final focus = FocusMode.instance;
    await focus.sync();
    if (focus.endedUnannounced && propose && toolsOverride == null) {
      final text = await focus.stop();
      if (text != null) {
        notify?.call('Concentration terminée', text);
        unawaited(think(text));
      }
      return null;
    }
    if (focus.active || GameMode.instance.active) return null;
    if (_deciding || !active || idea != null) return null;
    final windows = DriveRunner.supported;
    final idle = idleSeconds ?? (windows ? Win.idleSeconds() : 0);
    final away = _lastIdle;
    final back = _lastIdle >= 20 * 60 && idle < 60;
    _lastIdle = idle;
    try {
      await mind.load();
    } catch (_) {}
    if (!mind.on || !mind.autonomy) return null;
    // Le fil de Mon Hub (cours, contrôles, devoirs…) reste à jour, même
    // quand l'accueil n'est pas affiché.
    _refreshFeed();
    // Tu reviens après une absence : il te le dit (et prend des nouvelles),
    // avec ce qui compte maintenant.
    if (back) {
      final hello = mind.welcomeBack(now: n, name: callName);
      final loop = mind.dueLoops(n).firstOrNull;
      if (loop != null && hello.contains(loop.text)) unawaited(mind.markAsked(loop));
      final top = HubFeed.instance.top;
      final extra = HubFeed.say(top);
      if (top != null && extra != null) _nudged.add(top.id);
      // Ce que tu as raté pendant ton absence (messages, mentions, mails).
      var missed = '';
      if (propose && toolsOverride == null) {
        try {
          missed = CatchUp.short(await _catchUp(Duration(seconds: away + 120)).timeout(const Duration(seconds: 10)));
        } catch (_) {}
      }
      if (propose) unawaited(think([hello, missed, ?extra].where((t) => t.isNotEmpty).join(' ')));
      return null;
    }
    // Quelque chose d'important arrive (cours dans 30 min, contrôle demain) :
    // il prévient de lui-même, sans IA (jamais en plein écran).
    final busy = windows && (Win.foregroundFullscreen() || isSensitiveTitle(Win.foregroundTitle()));
    if (propose && idle < 120 && !busy && feedNudge(n)) return null;
    if (idle > 120 || n.difference(_startedAt).inMinutes < 8 || !mind.ideaAllowed(n)) return null;
    if (windows && (Win.foregroundFullscreen() || isSensitiveTitle(Win.foregroundTitle()))) return null;
    _deciding = true;
    try {
      final i = await decideIdea(n);
      if (i == null) return null;
      final key = '${i.tool}|${jsonEncode(i.args)}';
      if (mind.ideaSeen(key)) return null;
      await mind.ideaProposed(key, n);
      if (propose) await proposeIdea(i);
      return i;
    } catch (_) {
      return null;
    } finally {
      _deciding = false;
    }
  }

  /// Il décide : Gemini (gratuit) regarde la situation ; sans clé, des
  /// règles simples.
  Future<ClickyIdea?> decideIdea(DateTime n) async {
    final mind = ClickyMind.instance;
    final tools = _tools;
    final names = {for (final t in tools) t.name};
    final skip = mind.skipTools(n);
    if (await AiText.hasGemini()) {
      final a = Assistant.instance..useTools(
        call: (name, args) async => tools.where((t) => t.name == name).firstOrNull?.run(args),
        tools: () => names,
      );
      final situation = Assistant.briefingText(await a.collect(n), name: callName);
      final fg = DriveRunner.supported ? Win.foregroundTitle() : '';
      final r = await AiText.ask(
        Autonomy.prompt(
          situation: situation,
          tools: [for (final t in tools) if (!skip.contains(t.name)) t],
          name: callName,
          window: ClickyController.privateApp.hasMatch(fg.toLowerCase()) ? '' : fg,
          memory: [
            for (final e in mind.episodes.take(4)) '- souvenir : ${e.text}',
          ].join('\n'),
          likes: mind.likes,
          dislikes: mind.dislikes,
          now: n,
        ),
        system: 'Tu es Clicky, un assistant personnel autonome, prudent et utile. Tu réponds seulement en JSON.',
        geminiOnly: true,
      );
      final i = Autonomy.parse(AiText.json(r), names);
      if (i != null && !skip.contains(i.tool)) return i;
      return null;
    }
    // Sans IA : quelques décisions évidentes.
    final ctx = <String, Object?>{};
    Future<Object?> call(String name, [Map<String, dynamic> args = const {}]) async {
      try {
        return await tools.where((t) => t.name == name).firstOrNull?.run(args);
      } catch (_) {
        return null;
      }
    }

    final rev = await call('revision_paquets');
    if (rev is Map) {
      ctx['cartes'] = rev['a_revoir_aujourdhui'];
      final decks = [for (final d in (rev['paquets'] as List?) ?? const []) if (d is Map) '${d['nom']}'];
      for (final t in (rev['controles'] as List?) ?? const []) {
        if (t is! Map) continue;
        final d = t['date'] is DateTime ? t['date'] as DateTime : DateTime.tryParse('${t['date']}');
        final subject = '${t['matiere'] ?? ''}';
        if (d == null || subject.isEmpty) continue;
        final days = DateTime(d.year, d.month, d.day).difference(DateTime(n.year, n.month, n.day)).inDays;
        if (days >= 0 && days <= 3 && !decks.any((x) => x.contains(subject))) {
          ctx['controle'] = subject;
          break;
        }
      }
    }
    final pr = await call('assistant_priorites');
    if (pr is Map) ctx['trop'] = pr['trop_de_choses'] == true;
    return Autonomy.rules(ctx, n, available: names, skip: skip);
  }

  /// Affiche un petit message dans la boîte.
  void showStatus(String s) {
    status = s;
    // Il avance : le garde-fou repart de zéro.
    _armStuck(state);
    panelOpen = true;
    onInteractive?.call(true);
    notifyListeners();
  }

  /// Garde-fou : Clicky resté coincé sur « j'écoute » ou « je réfléchis »
  /// (réseau qui ne répond plus, micro bloqué…) n'acceptait plus rien. Sans
  /// nouvelle pendant trop longtemps, il se débloque tout seul.
  Timer? _stuck;
  void _armStuck(ClickyState s) {
    _stuck?.cancel();
    final limit = switch (s) {
      ClickyState.listening => const Duration(minutes: 2),
      ClickyState.thinking => const Duration(minutes: 4),
      ClickyState.pointing => const Duration(minutes: 3),
      _ => null,
    };
    if (limit == null) return;
    _stuck = Timer(limit, () {
      if (state != s) return;
      ErrorLog.record('Clicky est resté bloqué sur « ${s.name} » ($status)', StackTrace.current, where: 'Clicky');
      unawaited(
        cancel().then((_) => _set(ClickyState.idle, status: 'Je m\'étais coincé : c\'est reparti, redemande-moi.')),
      );
    });
  }

  void _set(ClickyState s, {String? status, String? reply}) {
    _armStuck(s);
    final was = state;
    if (s != ClickyState.listening && following) {
      following = false;
      _followTimer?.cancel();
    }
    // La réponse à une question posée à la voix est finie : il écoute la suite.
    if (s == ClickyState.idle &&
        _voiceTurn &&
        (was == ClickyState.speaking || was == ClickyState.thinking || was == ClickyState.pointing)) {
      _voiceTurn = false;
      if (followUp) unawaited(_followUpSoon());
    }
    state = s;
    // On l'appelle pendant qu'il dort ou qu'il est assis : il revient.
    if (s != ClickyState.idle && _lifeHold) _endRest(quiet: true);
    FreezeWatch.note('Clicky : ${s.name}${status == null || status.isEmpty ? '' : ' ($status)'}');
    if (status != null) this.status = status;
    if (reply != null) this.reply = reply;
    if (s != ClickyState.idle) {
      _recent = true;
      _clear?.cancel();
    }
    notifyListeners();
  }

  /// Les fonctions « JARVIS » (sans IA) : état du PC, fenêtres, mode
  /// concentration, rappels d'appli, point de situation.
  List<HubTool> get jarvisTools => [
    if (SystemStatus.supported) ...[
      HubTool(
        name: 'pc_etat',
        description:
            'État du PC : batterie, mémoire, processeur, disque, internet, et les applis qui prennent le plus de mémoire '
            '(« mon PC rame », « il me reste combien de batterie »).',
        params: {'applis': ('boolean', 'Aussi les applis les plus gourmandes (pour « pourquoi ça rame »)')},
        run: (a) async => (await SystemStatus.read(apps: a['applis'] == true)).toJson(),
      ),
      HubTool(
        name: 'pc_fenetres',
        description:
            'Range les fenêtres : « bureau » (tout réduire), « agrandir », « reduire », « activer », « gauche » ou '
            '« droite » (moitié de l\'écran). Sans appli : la fenêtre au premier plan.',
        params: {
          'action': ('string', 'bureau, agrandir, reduire, activer, gauche ou droite'),
          'appli': ('string', 'Nom de l\'appli ou mot du titre (facultatif)'),
        },
        required: ['action'],
        run: (a) async => windowCommand('${a['action'] ?? ''}', '${a['appli'] ?? ''}'),
      ),
    ],
    if (DriveRunner.supported)
      HubTool(
        name: 'clicky_corriger_selection',
        description:
            'Corrige (ou reformule, ou traduit) le texte surligné dans l\'appli ouverte et le remplace, comme Ctrl + Alt + C.',
        params: {'mode': ('string', 'corriger (défaut), reformuler, ou traduire:anglais (ou une autre langue)')},
        run: (a) async => fixSelection(mode: '${a['mode'] ?? 'corriger'}'),
      ),
    if (SecurityCheck.supported)
      HubTool(
        name: 'securite_bilan',
        description:
            'Bilan de sécurité du PC et des comptes : antivirus, pare-feu, mises à jour de Windows, contrôle des comptes, '
            'double authentification (Discord, Google, Roblox…).',
        run: (_) async {
          final items = await SecurityCheck.run(discord: _discord2fa, pcControl: pcControl);
          return {
            'resume': SecurityCheck.say(items),
            'points': [
              for (final i in items) {'quoi': i.title, 'ok': i.ok, 'detail': i.detail},
            ],
          };
        },
      ),
    HubTool(
      name: 'clicky_rate',
      description:
          '« Qu\'est-ce que j\'ai raté ? » : messages privés Discord, mentions dans les serveurs, mails importants (sans '
          'les pubs), messages École Directe, et qui attend une réponse.',
      params: {'heures': ('integer', 'Sur combien d\'heures (défaut 12)')},
      run: (a) async {
        final text = await _catchUp(Duration(hours: (a['heures'] as num?)?.toInt() ?? 12));
        return text.isEmpty ? 'Rien de nouveau : personne ne t\'a écrit.' : text;
      },
    ),
    HubTool(
      name: 'securite_lien',
      description:
          'Bouclier anti-arnaque : vérifie un lien ou un message (faux Nitro/Robux, faux site, espion d\'IP, .exe…). '
          'Sans rien : vérifie ce qui est copié dans le presse-papier.',
      params: {'texte': ('string', 'Le lien ou le message à vérifier (facultatif)')},
      run: (a) async {
        var t = '${a['texte'] ?? ''}'.trim();
        if (t.isEmpty) t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
        if (t.isEmpty) return {'resume': 'Copie le lien (clic droit → Copier le lien), puis redemande-moi.'};
        final v = ScamShield.links(t).length == 1 && t.split(RegExp(r'\s+')).length == 1
            ? ScamShield.checkUrl(t)
            : ScamShield.checkMessage(t);
        return {'niveau': v.level.name, 'raisons': v.reasons, 'resume': v.say()};
      },
    ),
    HubTool(
      name: 'clicky_concentration',
      description:
          'Mode concentration : pendant la séance, Clicky ne dérange plus (pas d\'idées ni de remarques), les '
          'notifications de Mon Hub attendent la fin, et il annonce la fin avec le bilan.',
      params: {
        'minutes': ('integer', 'Durée (défaut 45)'),
        'arreter': ('boolean', 'Arrêter la séance en cours'),
      },
      run: (a) async {
        final f = FocusMode.instance;
        if (a['arreter'] == true) {
          final text = await f.stop();
          return {'ok': true, 'bilan': text ?? 'Pas de séance en cours.'};
        }
        final m = ((a['minutes'] as num?)?.toInt() ?? 45).clamp(5, 480);
        await f.start(Duration(minutes: m));
        return {'ok': true, 'minutes': m, 'fin': '${f.until!.hour} h ${f.until!.minute.toString().padLeft(2, '0')}'};
      },
    ),
    HubTool(
      name: 'clicky_rappel_appli',
      description:
          'Rappel lié à une appli : Clicky le dit la prochaine fois que l\'appli est ouverte (« rappelle-moi de '
          'répondre à Léo quand j\'ouvre Discord »). Sans texte : liste les rappels ; supprimer=true : les retire.',
      params: {
        'appli': ('string', 'L\'appli ou le site (Discord, Chrome, YouTube, Word…)'),
        'texte': ('string', 'Ce qu\'il faudra rappeler'),
        'supprimer': ('boolean', 'Retirer les rappels de cette appli'),
      },
      run: (a) async {
        final r = AppReminders.instance;
        final app = '${a['appli'] ?? ''}'.trim();
        final text = '${a['texte'] ?? ''}'.trim();
        if (a['supprimer'] == true) return {'ok': await r.remove(app)};
        if (app.isEmpty || text.isEmpty) {
          return [for (final x in await r.list()) {'appli': x.app, 'rappel': x.text}];
        }
        await r.add(app, text);
        return {'ok': true, 'appli': app};
      },
    ),
    HubTool(
      name: 'clicky_situation',
      description: 'Le point de la situation en ce moment (prochain cours, devoirs, contrôles, révisions, musique).',
      run: (_) async => await _refreshSituation(force: true),
    ),
  ];

  /// Une correction de texte est en cours.
  bool _fixing = false;

  /// Une petite bulle à côté de Clicky (sans bouger la boîte).
  void _bubble(String text, {int seconds = 5}) {
    final at = cursor;
    if (at != null) glance(at + const Offset(40, -30), note: text, hold: Duration(seconds: seconds));
  }

  /// **Ctrl + Alt + C** : corrige le texte surligné dans l'appli ouverte
  /// (Word, Discord, un mail, un site…) et le remplace. [mode] : corriger,
  /// reformuler, traduire:anglais. Renvoie ce qui s'est passé (en une phrase).
  Future<String> fixSelection({String mode = 'corriger'}) async {
    if (!DriveRunner.supported) return 'Ça marche sur le PC (Windows).';
    if (_fixing) return 'Je suis déjà en train de corriger.';
    _fixing = true;
    // Mon Hub ne doit pas prendre cette copie pour la tienne (presse-papier malin).
    PcWatch.markClipboardUse();
    String done(String msg) {
      _set(ClickyState.idle, status: '');
      _bubble(msg);
      _fadeSoon();
      return msg;
    }

    ClipboardData? before;
    try {
      // On attend que tu lâches le raccourci (sinon l'appli reçoit Ctrl+Alt+C).
      for (var i = 0; i < 40 && (Win.down(0x11) || Win.down(0x12) || Win.down(0x43)); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final target = Win.foreground().address;
      if (privacy && isSensitiveTitle(Win.foregroundTitle())) {
        return done('Fenêtre sensible : je ne touche pas à ce texte.');
      }
      before = await Clipboard.getData(Clipboard.kTextPlain);
      await Clipboard.setData(const ClipboardData(text: ''));
      Win.releaseModifiers();
      Win.pressCombo('ctrl+c');
      String? selected;
      for (var i = 0; i < 14; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final d = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
        if (d.isNotEmpty) {
          selected = d;
          break;
        }
      }
      if (selected == null || selected.trim().isEmpty) {
        return done('Surligne d\'abord le texte, puis Ctrl + Alt + C.');
      }
      if (selected.length > 8000) return done('C\'est trop long d\'un coup : surligne un morceau plus court.');
      _set(ClickyState.thinking, status: mode == 'corriger' ? 'Je corrige…' : 'J\'écris…');
      final answer = await AiText.ask(TextFix.prompt(selected, mode: mode), system: TextFix.system);
      final fixed = TextFix.clean(answer, selected);
      final n = TextFix.changes(selected, fixed);
      if (fixed == selected) return done('Aucune faute, c\'est parfait ✓');
      await Clipboard.setData(ClipboardData(text: fixed));
      if (Win.foreground().address != target) {
        before = null; // on laisse le texte corrigé dans le presse-papier
        return done('La fenêtre a changé : le texte corrigé est copié, colle-le avec Ctrl + V.');
      }
      Win.releaseModifiers();
      Win.pressCombo('ctrl+v');
      // Le temps que l'appli colle, puis on remet ton presse-papier.
      await Future<void>.delayed(const Duration(milliseconds: 450));
      return done(mode == 'corriger' ? 'Corrigé ✓ ($n mot${n > 1 ? 's' : ''} changé${n > 1 ? 's' : ''})' : 'C\'est fait ✓');
    } catch (e) {
      ErrorLog.record(e, null, where: 'Correction du texte surligné');
      return done('Je n\'ai pas pu corriger ce texte ($e).');
    } finally {
      _fixing = false;
      final b = before;
      if (b != null && b.text != null) {
        try {
          await Clipboard.setData(b);
        } catch (_) {}
      }
    }
  }

  /// Ce qui est arrivé pendant [since] (messages, mentions, mails…).
  Future<String> _catchUp(Duration since) {
    final byName = {for (final t in _tools) t.name: t};
    return CatchUp.gather((n, a) async => byName[n]?.run(a), byName.keys.toSet(), since: since);
  }

  /// Temps d'écran, recherche partout, anniversaires (dans Mon Hub).
  List<HubTool> get lifeTools => [
    // Ses yeux et ses oreilles : la mémoire de l'écran, ce qu'il voit et
    // entend en ce moment.
    ...ClickySenses.instance.tools(explain: _explainScreen),
    // Le presse-papier malin et les réactions du PC.
    if (DriveRunner.supported) ...PcWatch.instance.tools(),
    // « Préviens-moi quand… » et les réponses toutes prêtes.
    ...Watchers.instance.tools(
      clipUrl: () async {
        final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
        return t.isNotEmpty && !t.contains(RegExp(r'\s')) && ScamShield.links(t).length == 1 ? t : null;
      },
    ),
    ...Replies.tools(),
    HubTool(
      name: 'temps_ecran',
      description:
          'Temps d\'écran sur ce PC (compté seulement quand la personne est devant) : par appli et par site '
          '(Roblox, YouTube, Discord…), aujourd\'hui, hier ou sur la semaine, et les limites fixées.',
      params: {
        'periode': ('string', 'jour (défaut), hier ou semaine'),
        'appli': ('string', 'Une appli ou un site précis (facultatif)'),
      },
      run: (a) async {
        final st = ScreenTime.instance;
        await st.load();
        if (!st.on) return {'resume': 'Le temps d\'écran n\'est pas suivi (Réglages → Temps d\'écran pour l\'activer).'};
        final now = DateTime.now();
        final p = ToolRouter.normalize('${a['periode'] ?? 'jour'}');
        final (m, label) = p.startsWith('sem')
            ? (st.week(now), 'Ces 7 derniers jours')
            : p.startsWith('hier')
            ? (st.day(now.subtract(const Duration(days: 1))), 'Hier')
            : (st.day(now), 'Aujourd\'hui');
        final app = '${a['appli'] ?? ''}'.trim();
        if (app.isNotEmpty) {
          final key = ScreenTime.matchApp(app, m.keys);
          final secs = key == null ? 0 : m[key]!;
          final limit = key == null ? null : st.limits[key];
          return {
            'resume': '$label : ${ScreenTime.say(secs)} sur ${key ?? app}'
                '${limit == null ? '' : ' (limite : ${ScreenTime.say(limit * 60)} par jour)'}.',
          };
        }
        return {
          'resume': ScreenTime.summary(m, when: label),
          'applis': [for (final e in ScreenTime.sorted(m).take(10)) {'appli': e.key, 'temps': ScreenTime.say(e.value)}],
          'limites': {for (final e in st.limits.entries) e.key: ScreenTime.say(e.value * 60)},
        };
      },
    ),
    HubTool(
      name: 'temps_ecran_limite',
      description:
          'Fixe une limite douce de temps par jour pour une appli ou un site (prévenu quand elle est atteinte, rien '
          'n\'est bloqué). 0 minute = enlever la limite.',
      params: {
        'appli': ('string', 'L\'appli ou le site (Roblox, YouTube, TikTok…)'),
        'minutes': ('integer', 'Minutes par jour (0 pour enlever)'),
      },
      required: ['appli', 'minutes'],
      run: (a) async {
        final st = ScreenTime.instance;
        await st.load();
        final raw = '${a['appli'] ?? ''}'.trim();
        final app = ScreenTime.matchApp(raw, {...st.week(DateTime.now()).keys, ...ScreenTime.knownApps}) ?? raw;
        final mins = (a['minutes'] as num?)?.toInt() ?? 0;
        await st.setLimit(app, mins);
        return mins <= 0
            ? 'Plus de limite pour $app.'
            : 'D\'accord : je te préviens après ${ScreenTime.say(mins * 60)} de $app par jour.';
      },
    ),
    HubTool(
      name: 'recherche_partout',
      description:
          'Cherche un mot partout : fichiers du PC (noms et contenu), Drive, Google Docs, mails, Discord, École Directe '
          '(messages, devoirs), Carnet, presse-papier, comptes rendus de cours, révisions et livres.',
      params: {'texte': ('string', 'Ce qu\'il faut retrouver')},
      required: ['texte'],
      run: (a) async {
        final q = '${a['texte'] ?? ''}'.trim();
        final hits = await search(q);
        return {
          'resume': EverywhereSearch.say(q, hits),
          'resultats': [for (final h in hits.take(15)) h.toJson()],
        };
      },
    ),
    HubTool(
      name: 'recherche_ouvrir',
      description: 'Ouvre la recherche partout de Mon Hub (Ctrl + Espace), avec un texte déjà tapé si besoin.',
      params: {'texte': ('string', 'Le texte à chercher (facultatif)')},
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        HubHome.instance.onSearchText?.call('${a['texte'] ?? ''}');
        return 'Recherche ouverte.';
      },
    ),
    HubTool(
      name: 'copie_corriger',
      description:
          'Ouvre la correction de copie : la personne prend sa copie (rédaction, exercice) en photo et Clicky entoure '
          'chaque faute à sa place sur la feuille, avec la correction et la règle, et une note estimée.',
      params: {'chemin': ('string', 'Chemin d\'une photo déjà sur le PC (facultatif)')},
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        final p = '${a['chemin'] ?? ''}'.trim();
        unawaited(CopyCheckPage.open(path: p.isEmpty ? null : p));
        return p.isEmpty
            ? 'Correction ouverte : choisis la photo de ta copie (ou envoie-la depuis ton téléphone).'
            : 'Je corrige ta copie…';
      },
    ),
    HubTool(
      name: 'oral_coach',
      description:
          'Ouvre le coach d\'oral (exposé, Grand oral) : la personne répète à voix haute, chrono, tics de langage, débit, '
          'blancs, plan respecté, note sur 20, puis questions du jury lues à voix haute.',
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        unawaited(OralCoachPage.open());
        return 'Coach d\'oral ouvert : écris ton sujet, puis « Commencer la répétition ».';
      },
    ),
    HubTool(
      name: 'video_fiche',
      description: 'Transforme une vidéo YouTube de cours en fiche : résumé, chapitres cliquables, à retenir et quiz.',
      params: {'lien': ('string', 'Lien de la vidéo YouTube')},
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        final l = '${a['lien'] ?? ''}'.trim();
        unawaited(VideoNotesPage.open(url: l.isEmpty ? null : l));
        return l.isEmpty ? 'Colle le lien de la vidéo dans la page qui s\'ouvre.' : 'Je regarde la vidéo et je fais la fiche…';
      },
    ),
    HubTool(
      name: 'carte_mentale',
      description: 'Fait une carte mentale animée (branches qui se déplient) sur un sujet ou à partir du texte d\'un cours.',
      params: {'sujet': ('string', 'Le sujet, ou le texte du cours')},
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        final t = '${a['sujet'] ?? ''}'.trim();
        unawaited(MindMapPage.open(input: t.isEmpty ? null : t));
        return t.isEmpty ? 'Carte mentale ouverte.' : 'Je dessine la carte mentale…';
      },
    ),
    HubTool(
      name: 'interprete_ouvrir',
      description:
          'Ouvre l\'interprète en direct : la personne parle avec quelqu\'un dans une autre langue, Clicky traduit à voix '
          'haute dans les deux sens (français ⇄ la langue choisie).',
      params: {'langue': ('string', 'Anglais, Espagnol, Allemand, Italien, Portugais, Arabe, Chinois, Japonais…')},
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        final want = ToolRouter.normalize('${a['langue'] ?? 'anglais'}').trim();
        final lang = Interpreter.languages.keys.where((k) => ToolRouter.normalize(k) == want).firstOrNull ?? 'Anglais';
        unawaited(InterpreterPage.open(language: lang));
        return 'Interprète français ⇄ ${lang.toLowerCase()} ouvert : appuie sur « Commencer » et parlez chacun votre tour.';
      },
    ),
    HubTool(
      name: 'soustitres_lancer',
      description:
          'Affiche les sous-titres en direct (traduits en français) de tout ce qui passe sur le PC : vidéo, série, jeu, appel. '
          'Une petite fenêtre toujours au premier plan, en bas de l\'écran.',
      run: (a) async {
        if (!LiveCaptions.supported) return 'Les sous-titres en direct marchent sur le PC (Windows).';
        await LiveCaptions.launch();
        return 'Sous-titres lancés : lance ta vidéo, la traduction s\'écrit en bas de l\'écran (quelques secondes de décalage).';
      },
    ),
    HubTool(
      name: 'soiree_ouvrir',
      description:
          'Lance la playlist de soirée : un QR code que les invités scannent pour chercher et ajouter des sons '
          '(YouTube) et voter ; le PC les joue dans l\'ordre des votes.',
      run: (a) async {
        if (Win.supportedHere) Win.raiseMain(pid);
        unawaited(PartyPage.open());
        return 'Soirée lancée 🎉 : tes amis scannent le QR code affiché pour ajouter leurs sons.';
      },
    ),
    HubTool(
      name: 'telephone_envoyer',
      description:
          'Envoie un fichier du PC sur le téléphone de la personne (page « Mon téléphone », par le Wi-Fi) : il apparaît '
          'dans l\'onglet « Du PC » du téléphone. Les fichiers reçus du téléphone sont dans Téléchargements\\Depuis mon '
          'téléphone.',
      params: {'chemin': ('string', 'Chemin complet du fichier sur le PC')},
      required: ['chemin'],
      run: (a) async {
        final link = PhoneLink.instance;
        if (!link.running) {
          return 'Le téléphone n\'est pas relié : Réglages → Mes appareils → Mon téléphone (un QR code à scanner).';
        }
        final f = await link.share('${a['chemin'] ?? ''}'.trim());
        return f == null
            ? 'Fichier introuvable.'
            : '« ${f.name} » est prêt sur ton téléphone : onglet « Du PC » de la page Mon PC.';
      },
    ),
  ];

  /// La recherche partout, avec les outils de lecture de Mon Hub.
  Future<List<SearchHit>> search(String query, {void Function(List<SearchHit>)? onPart}) {
    final byName = {for (final t in _tools) t.name: t};
    return EverywhereSearch.run(query, (n, a) async => byName[n]?.run(a), byName.keys.toSet(), onPart: onPart);
  }

  /// Ctrl + Alt + Espace (Clicky partout) ou Ctrl + Espace (Mon Hub).
  Future<void> openSearch([String text = '']) async {
    if (hub != null && !desktopMode) {
      HubHome.instance.onSearchText?.call(text);
      return;
    }
    final t = _tools.where((t) => t.name == 'recherche_ouvrir').firstOrNull;
    if (t == null) return;
    try {
      await t.run({'texte': text});
    } catch (_) {}
  }

  /// Discord : la double authentification (null si Discord n'est pas branché).
  Future<bool?> _discord2fa() async {
    final t = _tools.where((t) => t.name == 'discord_securite').firstOrNull;
    if (t == null) return null;
    final r = await t.run(const {}).timeout(const Duration(seconds: 10));
    return r is Map ? r['double_authentification'] == true : null;
  }

  /// Range les fenêtres de Windows (sans IA).
  static Map<String, dynamic> windowCommand(String action, String app) {
    final what = ToolRouter.normalize(action.trim());
    if (what == 'bureau') {
      Win.pressCombo('win+d');
      return {'ok': true};
    }
    final want = ToolRouter.normalize(AppReminders.appKey(app));
    final all = Win.windowList().where((w) => !w.$2.toLowerCase().contains('mon hub - clicky')).toList();
    final w = want.isEmpty
        ? all.firstOrNull
        : all.where((w) => ToolRouter.normalize('${w.$2} ${w.$3}').contains(want)).firstOrNull;
    if (w == null) return {'ok': false, 'message': 'Je ne trouve pas de fenêtre « $app » ouverte.'};
    switch (what) {
      case 'gauche' || 'droite':
        Win.windowAction(w.$1, 'restaurer');
        Win.pressCombo(what == 'gauche' ? 'win+left' : 'win+right');
      case 'agrandir' || 'reduire':
        Win.windowAction(w.$1, what);
      default:
        Win.windowAction(w.$1, 'activer');
    }
    return {'ok': true, 'fenetre': w.$2};
  }

  /// Le point de la situation (pour les consignes de l'IA), gardé 4 minutes.
  String _situation = '';
  DateTime? _situationAt;
  Future<String>? _situationLoading;

  Future<String> _refreshSituation({bool force = false}) {
    final at = _situationAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(minutes: 4)) {
      return Future.value(_situation);
    }
    return _situationLoading ??= () async {
      try {
        final tools = _tools;
        final byName = {for (final t in tools) t.name: t};
        _situation = await ClickySituation.build((n, a) async => byName[n]?.run(a), byName.keys.toSet());
        _situationAt = DateTime.now();
      } catch (_) {
      } finally {
        _situationLoading = null;
      }
      return _situation;
    }();
  }

  /// Écouter un cours en entier et en faire le compte rendu.
  List<HubTool> get courseTools => [
    HubTool(
      name: 'cours_ecouter',
      description:
          'Clicky écoute le cours en entier au micro (transcription au fur et à mesure), pour en faire un compte '
          'rendu à la fin. Matière et heure de fin trouvées dans l\'emploi du temps si possible.',
      params: {
        'matiere': ('string', 'Matière ou thème (facultatif)'),
        'google_doc': ('boolean', 'Écrire les notes en direct dans un Google Doc (oui par défaut si Google est connecté)'),
      },
      run: (a) async {
        final l = CourseListener.instance;
        if (l.recording) return {'ok': true, 'deja': true, 'matiere': l.current?.subject};
        final lesson = await currentLesson();
        final subject = '${a['matiere'] ?? ''}'.trim().isNotEmpty ? '${a['matiere']}'.trim() : (lesson?.$1 ?? '');
        final err = await l.start(subject: subject, stopAt: lesson?.$2, liveDoc: a['google_doc'] != false);
        if (err != null) return {'ok': false, 'message': err};
        unawaited(CoursePage.show());
        return {
          'ok': true,
          'matiere': subject,
          if (lesson != null) 'fin': '${lesson.$2.hour} h ${lesson.$2.minute.toString().padLeft(2, '0')}',
        };
      },
    ),
    HubTool(
      name: 'cours_arreter',
      description: 'Arrête l\'écoute du cours et rédige le compte rendu (affiché dans Mon Hub).',
      run: (_) async {
        final l = CourseListener.instance;
        if (!l.recording) return {'ok': false, 'message': 'Je n\'écoutais pas de cours.'};
        unawaited(l.stop().then((n) {
          if (n != null && n.done) {
            notify?.call('Compte rendu prêt', n.title);
            unawaited(CoursePage.show());
          }
        }));
        return {'ok': true};
      },
    ),
    HubTool(
      name: 'cours_comptes_rendus',
      description: 'Les comptes rendus des cours écoutés par Clicky (les plus récents d\'abord).',
      params: {'recherche': ('string', 'Matière ou mot (facultatif)')},
      run: (a) async {
        final q = '${a['recherche'] ?? ''}'.toLowerCase().trim();
        final all = await CourseListener.instance.list();
        return [
          for (final n in all.where((n) => q.isEmpty || '${n.subject} ${n.summary}'.toLowerCase().contains(q)).take(5))
            {
              'matiere': n.title,
              'date': n.start,
              'minutes': n.length.inMinutes,
              'compte_rendu': n.summary.length > 6000 ? '${n.summary.substring(0, 6000)}…' : n.summary,
            },
        ];
      },
    ),
  ];

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
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null) return const [];
      // JPEG fabriqué à côté : plus léger à envoyer, l'appli ne fige pas.
      final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final jpeg = await Isolate.run(() => encodeShot(pixels, w, h, rgba: true));
      return [
        ClickyShot(
          png64: base64Encode(jpeg),
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
    // Le navigateur (extension) et les tâches de fond vivent dans Mon Hub.
    if (hub != null && toolsOverride == null && !desktopMode) ...[
      ...BrowserLink.instance.tools,
      HubTool(
        name: 'clicky_a_ma_place',
        description:
            'Fais une tâche à la place de la personne, en arrière-plan (modules, Google Docs, PC sans la souris, et '
            'navigateur avec l\'extension). Elle peut continuer à utiliser son PC ; elle est prévenue à la fin.',
        params: {'but': ('string', 'Ce qu\'il faut faire, en détail')},
        required: ['but'],
        run: (a) async => BackgroundTasks.instance.start('${a['but'] ?? ''}'),
      ),
    ],
    if (toolsOverride == null) ...jarvisTools,
    // Temps d'écran, recherche partout, anniversaires : dans Mon Hub.
    if (hub != null && toolsOverride == null && !desktopMode) ...lifeTools,
    if (hub != null && toolsOverride == null && CourseListener.supported) ...courseTools,
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
    Set<String>? groups,
  }) {
    // Consignes d'un groupe d'actions : seulement s'il est envoyé.
    bool has(String g) => groups == null || groups.contains(g);
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
${clickyPersona(callName, helpOnly: helpOnly)}
${PromptShield.rule}
${ClickyMind.instance.promptBlock(name: callName)}
${_lifeBlock()}${_facts.isEmpty ? '' : 'Ce que tu sais de la personne (sa mémoire, à utiliser naturellement) :\n${_facts.map((f) => '- $f').join('\n')}'}
${_situation.isEmpty ? '' : 'En ce moment (données à jour de Mon Hub : sers-t\'en directement, sans relancer d\'action pour les relire) :\n$_situation'}
$_sensesBlock
$thinkingRules
${groups == null ? '' : 'Tu as les actions utiles à cette question ; pour une autre action de Mon Hub, mon_hub_outils (liste un groupe) puis mon_hub_action.\n'}${_voicePlatform && has('clicky') ? 'Si la personne dit que tu ne l\'entends pas, que le micro ou Clicky ne marche pas : lance clicky_diagnostic, puis clicky_reparer_micro, et dis-lui en une phrase ce qui a été réparé ou le réglage précis à ouvrir.\n' : ''}${pcControl != 'off' && has('pc') ? '${PcControl.guide}\n' : ''}Le Carnet (outils carnet_…) : « retiens que… » → carnet_memoire ; « note ça », une idée en passant → carnet_idees ; tâches et notes → carnet_taches_notes ; « j'ai dépensé… » → carnet_budget ; sport, jeux, poèmes, météo et tenue, bilan du soir, protocoles, presse-papier, notification sur le téléphone : outils carnet_ correspondants.
Google Docs (outils doc_…, le vrai Google Docs de son Drive, ouvert dans Mon Hub) : « écris-moi un exposé / une lettre / une fiche sur… » → doc_creer (texte complet et bien structuré en Markdown, il s'ouvre à l'écran) ; « ouvre un document » → doc_nouveau ou doc_ouvrir ; relire ou compléter → doc_lire, doc_ecrire ; en Word ou PDF sur le PC → doc_exporter.
Les révisions (outils revision_…) : « fais-moi des cartes sur… », « transforme mon cours en fiches » → revision_generer ou revision_ajouter_cartes ; « interroge-moi », « quiz », « minuteur » → revision_lancer ; « organise mes révisions avant le contrôle » → revision_planifier (montre d'abord le plan) ; revision_paquets pour la série et ce qu'il reste à revoir.
${homeworkRules(helpOnly)}
Ranger : « range mes téléchargements / mon bureau / mon Drive » → pc_ranger_apercu ou drive_ranger_apercu, dis en une phrase ce qui va bouger, puis pc_ranger ou drive_ranger ; « annule le rangement » → pc_ranger_annuler ou drive_ranger_annuler.''';
    if (agent) {
      return '''$base

${BrowserLink.instance.connected ? '${BrowserLink.guide}\n' : ''}Tu travailles en arrière-plan comme agent : fais la tâche demandée jusqu'au bout avec les actions disponibles (lire l'agenda, les notes, les devoirs, les messages, chercher dans Drive, envoyer un message…). Les actions qui envoient ou modifient quelque chose demandent la permission. Termine par un compte rendu en français de 1 à 5 phrases simples, lisible à voix haute, sans markdown.''';
    }
    final code = codeMode && isCodeEditorTitle(foreground);
    final shotsNote = shots.length > 1 ? ':screenN' : '';
    return '''$base

Ta réponse est lue à voix haute :
- ${multilang ? 'réponds dans la langue de la question (français par défaut)' : 'réponds en français'}, comme à l'oral, clair et précis, en 1 à 4 phrases courtes ;
- pas de markdown, pas de listes à puces, pas d'émojis ;
- si on te demande d'EXPLIQUER quelque chose (une notion, un logiciel, une méthode), explique simplement, étape par étape, comme un prof patient (comparaisons de la vie de tous les jours, exemples concrets) ;
- si on te demande de FAIRE un devoir ou un exercice, fais-le (voir « Devoirs ») : à l'oral, dis juste le résultat en une phrase et où trouver le travail complet (le Google Doc ou le tableau) ;
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

  /// « Fais mes devoirs », « fais mon DM de maths pour lundi » : (matière,
  /// quand), ou null. « Fais cet exercice » (à l'écran) n'en est pas un.
  static (String?, String?)? homeworkRequest(String q) {
    final n = QuickAnswers.clean(q);
    final m = RegExp(
      r'^(?:fais|fait|termine|finis|fini|resous|redige|complete|occupe toi de)(?: moi)? (?:mon|ma|mes|le|la|les|tous mes) '
      r'(?:devoirs?|dm|exercices?|exos?|travail|redaction|expose|dissertation|commentaire|fiche d exercices)'
      r'(?: (?:de|d|en|du) ([a-z0-9 ]+?))?'
      r'(?: (?:pour|a rendre pour|a faire pour) (demain|apres demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|ce soir|la semaine prochaine))?$',
    ).firstMatch(n);
    if (m == null) return null;
    return (m.group(1)?.trim(), m.group(2));
  }

  /// La tâche donnée à l'agent pour faire les devoirs.
  static String homeworkTask(String? subject, String? when, {String request = ''}) {
    final what = subject == null || subject.isEmpty ? 'mes devoirs à faire' : 'mon devoir de $subject';
    final due = when == null ? 'les plus proches (pas encore faits)' : 'pour $when';
    return '${request.isEmpty ? '' : 'La demande : « $request ». '}'
        'Fais $what ($due), en entier, comme le demandent les consignes « Devoirs ». '
        'Lis-les dans le cahier de texte (ecole_devoirs) et lis aussi l\'énoncé complet des fichiers joints '
        '(ecole_fichier_lire avec mode=enonce). Pour chaque devoir : toutes les réponses, justes et détaillées, au niveau '
        'de la classe, avec « Comment j\'ai fait » après chaque exercice. Écris tout dans un Google Doc par matière '
        '(doc_creer, titre « Matière — devoir pour le … ») et donne les liens à la fin. Si un énoncé est introuvable '
        '(ni dans le cahier de texte ni dans un fichier), dis-le au lieu d\'inventer.';
  }

  /// « Fais-le à ma place », « fais ça pour moi », « en arrière-plan ».
  static final forMeRe = RegExp(
    r'^\s*(?:(?:hey|ok|dis|eh)\s+)?(?:clicky[\s,]+)?(?:fais|fait)(?:[\s-]+(?:le|la|les|ça|ca|tout))?\s+(?:(?:à|a)\s+ma\s+place|pour\s+moi)\b[\s,:]*'
    r'|^\s*(?:(?:hey|ok|dis|eh)\s+)?(?:clicky[\s,]+)?en\s+arri[eè]re[\s-]plan\b[\s,:]*',
    caseSensitive: false,
  );

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
    // Posée à la voix : la suite de la conversation s'écoute aussi.
    _voiceTurn = _spokenAsk;
    _spokenAsk = false;
    if (q.isEmpty) return;
    _lastAsk = DateTime.now();
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
    // « Fais mes devoirs de maths » : il lit le cahier de texte et les
    // fichiers joints, fait tout, et le range dans un Google Doc (en
    // arrière-plan).
    final hw = helpOnly ? null : homeworkRequest(q);
    if (hw != null) {
      unawaited(doForMe(homeworkTask(hw.$1, hw.$2, request: q)));
      return;
    }
    // « Agent, … », « Fais-le à ma place : … » : une tâche en arrière-plan.
    final agent = _agentRe.firstMatch(q) ?? forMeRe.firstMatch(q);
    if (agent != null) {
      unawaited(doForMe(q.substring(agent.end).trim()));
      return;
    }
    // « Oui », « vas-y », « non merci » : c'est la réponse à son idée.
    final pending = idea;
    if (pending != null) {
      final yes = Autonomy.answer(q);
      if (yes != null) {
        await answerIdea(yes);
        return;
      }
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
      if (await _handleQuick(q)) {
        unawaited(ClaudeUsage.saved());
        return;
      }
      if (liveReady && !needsClassic(q) && await _liveAsk(q)) {
        unawaited(ClaudeUsage.saved());
        return;
      }
      // Question simple : Gemini (gratuit) avant Claude.
      if (await _thriftAnswer(q)) return;
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
    var r = mind.selfAnswer(q, now: DateTime.now(), name: callName) ??
        (mind.on && mind.life
            ? ClickyLife.instance.answer(
                q,
                now: DateTime.now(),
                setPace: mind.setLifePace,
                setDance: (v) => mind.set('life.dance', v),
              )
            : null);
    // « J'habite à Lyon » : la ville de la météo (et de ses accessoires).
    final city = r == null ? ClickyLife.cityFrom(q) : null;
    if (city != null) {
      final name = QuickAnswers.original(q, city);
      await Carnet.instance.setSetting('city', name);
      _weather = null;
      unawaited(_refreshWeather());
      r = 'C\'est noté : tu habites à $name. Je regarderai la météo de là-bas, et je m\'habillerai en conséquence.';
    }
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
    // Le point de la situation (préparé en avance ; la toute première fois,
    // on l'attend un peu, pas plus de 2,5 s).
    if (_situationAt == null) {
      await _refreshSituation().timeout(const Duration(milliseconds: 2500), onTimeout: () => '');
    } else {
      unawaited(_refreshSituation());
    }
    if (id != _askId) return;
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
    // Clicky économe : seulement les actions utiles à cette question (les
    // autres restent accessibles par mon_hub_outils), et un effort adapté.
    final groups = thrift ? ToolRouter.groupsOrDefault(q) : null;
    final allTools = _tools;
    final sent = groups == null
        ? allTools
        : ToolRouter.forGroups(groups, [...allTools, ...ToolRouter.metaTools(allTools)]);
    final deep = ClaudeThrift.deep(q);
    final effort = thrift ? ClaudeThrift.effort(q) : (deep ? 'high' : 'low');
    if (deep) _set(ClickyState.thinking, status: 'Je réfléchis à fond…');
    final system = _system(shots, foreground: fg, hiddenScreen: hidden, groups: groups);
    final docBlocks = [for (final d in docs) ...d.blocks()];
    if (!useOllama) unawaited(ClaudeUsage.claude());
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
          groups: groups,
          effort: thrift || deep ? effort : null,
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
                  'source': {'type': 'base64', 'media_type': imageMime(s.png64), 'data': s.png64},
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
          tools: sent,
          allTools: allTools,
          effort: effort,
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
                  'source': {'type': 'base64', 'media_type': imageMime(img), 'data': img},
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

  /// Clicky économe : Claude seulement pour les demandes lourdes (les
  /// questions simples de culture générale vont à Gemini, gratuit).
  bool get thrift => _opt('thrift', true);

  /// Une question simple sans Claude : Gemini répond (gratuit).
  Future<bool> _thriftAnswer(String q) async {
    if (!thrift || docs.isNotEmpty) return false;
    if (!ClaudeThrift.light(q, screen: needsScreen(q))) return false;
    if (!await AiText.hasGemini()) return false;
    final id = ++_askId;
    _lastQuestion = q;
    _set(ClickyState.thinking, status: 'Je réfléchis…', reply: '');
    String r;
    try {
      final memory = _memory();
      final context = [
        for (final (u, a) in memory.length > 3 ? memory.sublist(memory.length - 3) : memory) 'Personne : $u\nToi : $a',
      ].join('\n');
      r = (await AiText.ask(
        '${context.isEmpty ? '' : 'Début de la conversation :\n$context\n\n'}Question : $q',
        system:
            '${clickyPersona(callName, helpOnly: helpOnly)}\n${PromptShield.rule}\nRéponds en français, à l\'oral : 1 à 4 phrases courtes, '
            'sans markdown ni liste. Si la question demande des données de Mon Hub (agenda, notes, messages) ou d\'agir, '
            'réponds seulement : CLAUDE',
        geminiOnly: true,
      )).trim();
    } catch (_) {
      if (id == _askId) _set(ClickyState.thinking, status: '');
      return false;
    }
    if (id != _askId) return true;
    if (r.isEmpty || r.toUpperCase().startsWith('CLAUDE')) return false;
    unawaited(ClaudeUsage.saved());
    unawaited(history.add(threadId, ChatMsg(mine: true, text: q), app: _appKey));
    unawaited(history.add(threadId, ChatMsg(mine: false, text: r), app: _appKey));
    _set(ClickyState.speaking, status: '', reply: r);
    await speak(r);
    if (state == ClickyState.speaking) _set(ClickyState.idle);
    _fadeSoon();
    return true;
  }

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
${clickyPersona(callName, helpOnly: helpOnly)}
${ClickyMind.instance.promptBlock(name: callName)}
${_lifeBlock()}Tu es Clicky, l'assistant personnel façon JARVIS qui vit dans « Mon Hub » sur l'ordinateur de la personne. Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.
Tu réponds À L'ORAL et TOUT DE SUITE : en français, naturel, 1 à 3 phrases courtes (plus seulement si on te le demande), sans liste ni symbole.
${modules.isEmpty ? '' : 'Modules de Mon Hub : ${modules.map((m) => m.name).join(', ')}.'}
Utilise les fonctions pour les vraies données (agenda, cours, devoirs, notes, messages, mails, musique, carnet…) et pour agir ; dis en une phrase ce que tu as fait. Celles qui envoient ou modifient quelque chose demandent la permission à la personne.
${PromptShield.rule}
Ce qu'il y a à l'écran : regarder_ecran. Faire quelque chose à l'écran à sa place (ouvrir, cliquer, écrire dans une appli) : agir_sur_ordinateur. Une explication avec tableau, schéma ou hologramme, ou montrer où cliquer : expliquer_au_tableau (puis ne dis presque rien, le tableau arrive).
${_facts.isEmpty ? '' : 'Ce que tu sais de la personne :\n${_facts.map((f) => '- $f').join('\n')}'}
${_situation.isEmpty ? '' : 'En ce moment (données de Mon Hub) :\n$_situation'}
$_sensesBlock
$thinkingRules''';
  }

  /// Ce que Clicky fait quand on lui demande ses devoirs.
  static String homeworkRules(bool helpOnly) => helpOnly
      ? 'Devoirs : la personne a choisi « Aider sans faire à ma place » dans tes réglages : explique la méthode, donne '
            'des pistes et corrige ce qu\'elle propose, mais ne donne pas la réponse complète.'
      : '''Devoirs : quand la personne te demande de faire un devoir, un exercice, un DM, une rédaction, un commentaire, une dissertation ou de répondre à des questions, FAIS-LE vraiment et en entier : c'est son choix, ne refuse pas et ne fais pas la morale.
- Trouve l'énoncé : à l'écran, dans le cahier de texte (ecole_devoirs), dans un fichier joint (ecole_fichier_lire avec mode=enonce), un PDF, une photo ou un Google Doc.
- Fais un travail juste et complet, au niveau de la classe (lycée, programme français) : toutes les questions, les calculs détaillés, les justifications, une vraie rédaction avec introduction et conclusion quand il en faut. Vérifie tes résultats.
- Après chaque exercice, une ou deux phrases « Comment j'ai fait » pour qu'elle puisse comprendre et refaire seule au contrôle.
- Où écrire : un travail long (rédaction, plusieurs exercices, exposé) va dans un Google Doc (doc_creer, titre « Matière — devoir pour le … ») ; un exercice court va dans le tableau (bloc « etapes » ou « exemple »). Si la personne écrit dans un document ouvert, tu peux aussi le compléter (doc_ecrire).''';

  /// Comment Clicky réfléchit (comme un vrai assistant personnel).
  static const thinkingRules = '''Ta façon de penser :
- Comprends le vrai besoin derrière la question et réponds à celui-là ; si c'est ambigu, prends l'interprétation la plus probable d'après la situation et la mémoire, et ne pose une question que si c'est vraiment indispensable.
- Pour un calcul, un raisonnement ou un problème en plusieurs étapes : réfléchis étape par étape en silence, vérifie le résultat, puis donne la réponse claire.
- Ne devine jamais un fait que tu ignores (une note, un horaire, un message) : va le lire avec l'action qui convient. Si tu n'es pas sûr, dis-le en une phrase.
- Anticipe comme un vrai JARVIS : si la situation rend une info utile (un contrôle demain, un cours dans 20 minutes, une batterie faible), glisse-la en une phrase à la fin, sans en faire trop.
- Enchaîne les actions toi-même quand la demande en demande plusieurs (lire puis organiser puis proposer), au lieu de t'arrêter au milieu.''';

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
    _voiceTurn = true;
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
        // Juste après avoir lu un message d'un inconnu : on vérifie que
        // c'est bien la personne qui veut que Clicky prenne la souris.
        if (PromptShield.tainted &&
            !await _confirmOpen(
              goal,
              title: 'Clicky veut prendre la souris',
              note: 'Clicky va cliquer et écrire à ta place pour ce but :',
            )) {
          return 'La personne a refusé.';
        }
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
    final out = await tool.run(args);
    PromptShield.touched(name);
    if (!PromptShield.readsOutside(name)) return out;
    final plain = ClaudeBridge.plain(out);
    return PromptShield.wrap(name, plain is String ? plain : jsonEncode(plain));
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
                    'source': {'type': 'base64', 'media_type': imageMime(shots[i].png64), 'data': shots[i].png64},
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

  /// **Fais-le à ma place** : la tâche part en arrière-plan dans Mon Hub
  /// (qui a les modules et l'extension du navigateur) ; Clicky reste
  /// disponible.
  Future<void> doForMe(String task) async {
    // « Fais-le à ma place » tout court : ce dont on vient de parler.
    if (task.trim().isEmpty && _lastQuestion.trim().isNotEmpty) {
      task = 'Ce que la personne vient de demander : « $_lastQuestion »'
          '${reply.trim().isEmpty ? '' : ' (ta dernière réponse : « ${reply.length > 600 ? reply.substring(0, 600) : reply} »)'}';
    }
    String say;
    if (hub != null && toolsOverride == null) {
      say = BackgroundTasks.instance.start(task);
    } else {
      // Clicky partout : c'est Mon Hub qui fait le travail.
      final t = _tools.where((t) => t.name == 'clicky_a_ma_place').firstOrNull;
      if (t == null) return _runAgent(task);
      try {
        say = '${await t.run({'but': task})}';
      } catch (e) {
        say = 'Je n\'ai pas pu lancer la tâche : $e';
      }
    }
    _set(ClickyState.idle, status: '', reply: say);
    unawaited(speak(say.split(':').first.split('.').first));
    _fadeSoon();
  }

  /// Un lien piège qu'on allait ouvrir : « ouvrir quand même ? » (non par
  /// défaut).
  Future<bool> confirmScamLink(String url, ScamVerdict v) async {
    final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
    if (ctx == null || !ctx.mounted) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.gpp_bad_rounded, color: Colors.red, size: 36),
        title: const Text('Ce lien ressemble à une arnaque'),
        content: Text(
          '${v.reasons.join('\n')}\n\n$url\n\nCes faux sites volent les comptes (Discord, Roblox, Steam…). '
          'Ne te connecte pas et ne télécharge rien.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ouvrir quand même')),
          FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('Ne pas ouvrir')),
        ],
      ),
    );
    return ok == true;
  }

  /// Une action dans le navigateur qui envoie, publie, paie ou supprime.
  Future<bool> confirmBrowser(String what) async {
    notify?.call('Clicky attend ton accord', 'Il veut $what dans ton navigateur.');
    onInteractive?.call(true);
    try {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
      if (ctx == null || !ctx.mounted) return false;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.public_rounded, color: Colors.orange),
          title: const Text('Clicky veut agir dans ton navigateur'),
          content: Text(
            'Il veut $what.\n\nAutorise seulement si c\'est bien ce que tu lui as demandé'
            '${PromptShield.tainted ? ' (il vient de lire une page écrite par quelqu\'un d\'autre : méfie-toi des pièges)' : ''}.',
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
    // Pendant « fais-le à ma place », le navigateur est permis (les clics qui
    // envoient, publient, paient ou suppriment demandent quand même).
    if (tool.name.startsWith('nav_') && BrowserLink.instance.trusted) return true;
    final pc = PcControl.isWrite(tool.name);
    if (pc) {
      if (pcControl == 'off') return false;
      final cmd = '${args['commande'] ?? ''}';
      // Mode auto : seulement pour les actions sans risque, et jamais juste
      // après avoir lu des messages ou des pages écrits par d'autres (un
      // message piégé ne doit pas pouvoir commander le PC).
      final risky =
          PcControl.dangerous(cmd) ||
          args['admin'] == true ||
          (tool.name == 'pc_ecrire_fichier' && PcControl.riskyWrite('${args['chemin'] ?? ''}'));
      if (pcControl == 'auto' && !risky && !PromptShield.tainted) return true;
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

  /// Permission avant d'ouvrir quelque chose qui peut lancer un programme
  /// (« .exe », script, raccourci, partage réseau…).
  Future<bool> _confirmOpen(
    String target, {
    String title = 'Clicky veut ouvrir un programme',
    String note = 'Ouvrir ceci peut lancer un programme ou un script. Autorise seulement si c\'est bien ce que '
        'tu as demandé.',
  }) async {
    if (pcControl == 'off') return false;
    onInteractive?.call(true);
    try {
      final ctx = await hubDialogContext(timeout: const Duration(seconds: 5));
      if (ctx == null || !ctx.mounted) return false;
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.shield_outlined, color: Colors.orange),
          title: Text(title),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(note),
                if (PromptShield.tainted)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Clicky vient de lire des messages ou une page écrits par quelqu\'un d\'autre : '
                      'méfie-toi, c\'est peut-être un piège.',
                      style: TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 10),
                SelectableText(target, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Refuser')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ouvrir')),
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
                  if (PromptShield.tainted)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Clicky vient de lire des messages ou une page écrits par quelqu\'un d\'autre. '
                        'Si ce n\'est pas toi qui as demandé cette action, refuse : c\'est peut-être un piège.',
                        style: TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w600),
                      ),
                    ),
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
      // Clicky autonome : il réfléchit et propose (rien sans ton accord).
      c.startAutonomy();
      // « Fais-le à ma place » : les tâches de fond, et le navigateur.
      BackgroundTasks.instance
        ..runner = c.runTask
        ..onDone = (title, body) {
          c.notify?.call(title, body);
          unawaited(c.think(body.length > 220 ? '${body.substring(0, 220)}…' : body));
        };
      BrowserLink.confirm = c.confirmBrowser;
      // Bouclier anti-arnaque sur les liens ouverts depuis Mon Hub.
      Browser.confirmScam = c.confirmScamLink;
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
      c.stopAutonomy();
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
        : (c.gaze != null && c.gazeNote.isNotEmpty ? c.gazeNote : c.lifeNote);
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
          child: Transform.scale(
            scale: c.flightScale,
            alignment: Alignment.topLeft,
            // Sa vie à lui : émoji de ce qu'il ressent, accessoire, danse.
            child: ClickyLifeBody(hud: c.hud, child: _Pointer(c: c)),
          ),
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

/// Oui / Non / Plus tard, sous une idée de Clicky.
class _IdeaButtons extends StatelessWidget {
  const _IdeaButtons({required this.c, required this.accent});
  final ClickyController c;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final i = c.idea!;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (i.why.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Pourquoi : ${i.why}', style: Theme.of(context).textTheme.bodySmall),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              TextButton(onPressed: () => c.answerIdea(null), child: const Text('Plus tard')),
              OutlinedButton(onPressed: () => c.answerIdea(false), child: const Text('Non')),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: accent),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Oui, vas-y'),
                onPressed: () => c.answerIdea(true),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Tu peux aussi me répondre « oui » ou « non » à voix haute.',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
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
    final mood = switch (c.state) {
      ClickyState.listening => AliveMood.listening,
      ClickyState.thinking => AliveMood.thinking,
      ClickyState.speaking => AliveMood.speaking,
      ClickyState.pointing => AliveMood.pointing,
      _ => AliveMood.idle,
    };
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
              // Rebond, halo quand il réfléchit, saut de joie quand il répond.
              ClickyBounce(
                mood: mood,
                color: clickyBlue,
                child: CustomPaint(size: const Size(22, 22), painter: _TrianglePainter()),
              ),
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
              // L'icône tourne en se changeant (étincelle ↔ micro).
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                transitionBuilder: (w, a) => RotationTransition(
                  turns: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
                  child: ScaleTransition(scale: a, child: w),
                ),
                child: Icon(
                  listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                  key: ValueKey(listening),
                  color: c.hud && !listening ? hudCyan : Colors.white,
                  size: 22,
                ),
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
                  // Son idée : il attend ton accord (ou dis « oui » / « non »).
                  if (c.idea != null) _IdeaButtons(c: c, accent: accent),
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
