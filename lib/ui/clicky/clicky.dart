import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/claude_api.dart';
import '../../core/claude_bridge.dart';
import '../../core/hub_controller.dart';
import '../../core/hub_module.dart';
import '../../core/nav.dart';
import 'board.dart';
import 'claude_code.dart';
import 'ears.dart';
import 'ollama.dart';
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

  /// Tableau visuel ouvert (schéma, étapes, frise, quiz…), et s'il est en
  /// train de s'écrire.
  ClickyBoard? board;
  bool drawing = false;

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

  bool get hasHistory => _memory.isNotEmpty;

  /// Mode discret : Clicky n'apparaît que pendant un échange.
  bool _recent = false;
  Timer? _fade;

  final shotKey = GlobalKey();
  final input = TextEditingController();

  // ---------- Réglages ----------

  T _opt<T>(String k, T d) {
    final v = _shared?[k];
    if (v is T) return v;
    return ClaudeApi.store.getJson<T>('clicky.$k') ?? d;
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
  ];
  Map<String, dynamic>? _shared;
  DateTime? _sharedStamp;
  Timer? _sharedTimer;

  static File? get _sharedFile {
    final d = ClaudeBridge.folder;
    return d == null ? null : File('$d${Platform.pathSeparator}clicky.json');
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

  /// 'claude' (clé API) ou 'ollama' (local, gratuit).
  /// 'claudecode' (ton abonnement Claude Pro via Claude Code), 'claude'
  /// (clé API) ou 'ollama' (local, gratuit).
  String get provider => _opt('provider', ClaudeCode.supported ? 'claudecode' : 'claude');

  /// Windows : Clicky au-dessus de tout l'écran et de toutes les applis.
  bool get everywhere => _opt('everywhere', true);

  static bool get everywhereSupported => !kIsWeb && Platform.isWindows;

  /// Clicky de l'appli désactivé car « Clicky partout » s'en charge.
  bool get handledElsewhere => !desktopMode && everywhereSupported && everywhere;

  Future<void> setOption(String k, Object v) async {
    // « Clicky partout » n'écrit jamais dans les préférences (ça écraserait
    // celles de Mon Hub) : seulement dans le fichier partagé.
    if (!desktopMode) await ClaudeApi.store.setJson('clicky.$k', v);
    if (_shared != null || desktopMode) {
      (_shared ??= {})[k] = v;
      await _writeShared();
    }
    await refreshReady();
    notifyListeners();
  }

  /// Clicky a un cerveau (clé Claude, ou Ollama choisi). Tant que ce n'est
  /// pas le cas, il reste complètement invisible et ne fait rien : le reste
  /// de Mon Hub marche exactement pareil sans lui.
  bool ready = false;

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
    // Windows : prépare le micro à l'avance pour ne pas rater le début.
    if (r && enabled && mic && (desktopMode || !handledElsewhere)) ears.warmUp();
    if (r != ready) {
      ready = r;
      notifyListeners();
    }
    return r;
  }

  /// Clicky doit s'afficher et écouter le clavier.
  bool get active => enabled && ready;

  bool get buddyVisible =>
      alwaysShow ||
      _recent ||
      panelOpen ||
      board != null ||
      state != ClickyState.idle ||
      agentsRunning > 0;

  void moveCursor(Offset p) {
    if (cursor == p) return;
    cursor = p;
    if (follow && active && state != ClickyState.pointing && buddyVisible) notifyListeners();
  }

  // ---------- Voix ----------

  final ClickyEars ears = ClickyEars.create();
  FlutterTts? _tts;

  bool get _voicePlatform => ClickyEars.supported;

  /// Dernier souci de micro (affiché dans la boîte, avec un bouton pour
  /// ouvrir le bon réglage).
  EarsProblem? micProblem;

  Timer? _autoSend;

  Future<void> startListening() async {
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
    transcript = '';
    target = null;
    micProblem = null;
    levels.fillRange(0, levels.length, 0);
    _set(ClickyState.listening, status: '', reply: '');
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
        // Sans Ctrl + Alt maintenus (bouton micro) : on envoie après un
        // petit silence.
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
    if (problem != null) _micFailed(problem);
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
    if (!send) {
      await ears.cancel();
      _set(ClickyState.idle, status: '');
      return;
    }
    _set(ClickyState.listening, status: 'Je finis d\'écouter…');
    final starting = _micStarting;
    if (starting != null && await starting != null) return;
    final heard = await ears.stop();
    if (state != ClickyState.listening) return;
    if (heard.trim().isNotEmpty) transcript = heard.trim();
    await _sendTranscript();
  }

  Future<void> _sendTranscript() async {
    if (state != ClickyState.listening) return;
    final t = transcript.trim();
    if (t.isEmpty) {
      _set(
        ClickyState.idle,
        status:
            'Je n\'ai rien entendu. Parle un peu plus fort, ou teste ton micro '
            'dans Réglages → Clicky.',
      );
      _fadeSoon();
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

  Future<void> speak(String text) async {
    if (!voice || !_voicePlatform || text.isEmpty) return;
    try {
      final tts = _tts ??= FlutterTts();
      await tts.setLanguage('fr-FR');
      await tts.setSpeechRate(Platform.isAndroid || Platform.isIOS ? 0.5 : 0.55);
      await tts.awaitSpeakCompletion(true);
      await tts.speak(text);
    } catch (_) {}
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  // ---------- Clavier : maintenir Ctrl + Alt ----------

  bool _holding = false;
  bool _cancelled = false;
  DateTime? _holdStart;
  Timer? _holdTimer;

  /// Appelé quand Ctrl + Alt (sans AltGr) est enfoncé ou relâché, ou quand
  /// une autre touche est tapée pendant l'appui ([other]).
  void hotkey({required bool down, bool other = false}) {
    if (!active) return;
    if (_holding && other) {
      // Ctrl + Alt + une touche = un raccourci clavier, pas Clicky.
      _cancelled = true;
      _holdTimer?.cancel();
      if (state == ClickyState.listening) unawaited(stopListening(send: false));
      return;
    }
    if (down && !_holding) {
      _holding = true;
      _cancelled = false;
      _holdStart = DateTime.now();
      _recent = true;
      // Appui long = on parle. Appui court = on écrit.
      _holdTimer = Timer(const Duration(milliseconds: 350), () {
        if (_holding && !_cancelled) unawaited(startListening());
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
      if (boxOpen) {
        closeBox();
      } else if (board != null) {
        closeBoard();
      }
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
      hotkey(down: true);
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
      micProblem != null;

  /// Ferme la boîte (et efface la réponse).
  void closeBox() {
    reply = '';
    status = '';
    micProblem = null;
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
    // La bulle de réponse s'efface après quelques secondes.
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 8), () {
      if (state == ClickyState.idle && !panelOpen && (reply.isNotEmpty || status.isNotEmpty)) {
        reply = '';
        status = '';
        notifyListeners();
      }
    });
  }

  Timer? _clear;

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

  // ---------- Question → IA ----------

  /// Courte mémoire (texte seulement) des derniers échanges.
  final _memory = <(String, String)>[];

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

  List<HubTool> get _tools =>
      toolsOverride?.call() ?? [for (final m in hub?.enabled ?? const <HubModule>[]) ...m.tools];

  String _system(List<ClickyShot> shots, {bool agent = false}) {
    final modules = hub?.enabled ?? const <HubModule>[];
    final now = DateTime.now();
    final where = desktopMode
        ? 'Tu vois une capture de chaque écran de l\'ordinateur (toutes les applis, pas seulement Mon Hub).'
        : 'Tu vois une capture de la fenêtre de l\'appli Mon Hub.';
    final screens = [
      for (var i = 0; i < shots.length; i++)
        'Image ${i + 1} = écran ${i + 1} (${shots[i].label}, ${shots[i].width} × ${shots[i].height} pixels)',
    ].join(' ; ');
    final base =
        '''
Tu es Clicky, un petit compagnon IA qui vit à côté du curseur de la personne, dans « Mon Hub », l'appli personnelle d'un·e élève (emploi du temps, École Directe, mails, Discord, Instagram, Roblox, livres, Google Drive…). $where
${modules.isEmpty ? '' : 'Modules de Mon Hub : ${modules.map((m) => '${m.name} (${m.description})').join(' ; ')}.'}
Nous sommes le ${now.day}/${now.month}/${now.year}, il est ${now.hour}h${now.minute.toString().padLeft(2, '0')}.''';
    if (agent) {
      return '''$base

Tu travailles en arrière-plan comme agent : fais la tâche demandée jusqu'au bout avec les actions disponibles (lire l'agenda, les notes, les devoirs, les messages, chercher dans Drive, envoyer un message…). Les actions qui envoient ou modifient quelque chose demandent la permission. Termine par un compte rendu en français de 1 à 3 phrases simples, lisible à voix haute, sans markdown.''';
    }
    return '''$base

Ta réponse est lue à voix haute :
- réponds en français, comme à l'oral, chaleureux et clair, en 1 à 4 phrases courtes ;
- pas de markdown, pas de listes à puces, pas d'émojis ;
- si on te demande d'expliquer quelque chose (un devoir, une notion, un logiciel), explique simplement, étape par étape, sans faire le travail à la place de l'élève : tu es un prof patient qui aide à comprendre (comparaisons de la vie de tous les jours, exemples concrets), et tu vérifies que c'est compris.
${_tools.isEmpty ? '' : 'Tu peux utiliser les actions de Mon Hub pour lire les vraies données (agenda, notes, devoirs, messages…) ou agir ; celles qui envoient ou modifient quelque chose demandent la permission.'}

$_boardGuide

Montrer à l'écran : quand c'est utile de montrer où cliquer ou de quoi tu parles, termine ta réponse par une balise [POINT:x,y:libellé court${shots.length > 1 ? ':screenN' : ''}] où x,y sont en pixels sur l'image (origine en haut à gauche) et visent le centre de l'élément${shots.length > 1 ? ', et N le numéro de l\'écran' : ''}. ${screens.isEmpty ? '' : '$screens.'} Une seule balise, à la toute fin. Si rien n'est à montrer, termine par [POINT:none].''';
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

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty) return;
    await stopSpeaking();
    input.clear();
    transcript = q;
    target = null;
    final agent = _agentRe.firstMatch(q);
    if (agent != null) {
      unawaited(_runAgent(q.substring(agent.end).trim()));
      return;
    }
    _set(ClickyState.thinking, status: 'Je regarde…', reply: '');
    final useOllama = provider == 'ollama';
    final usePro = provider == 'claudecode';
    if (usePro ? await ClaudeCode.find() == null : (!useOllama && !await ClaudeApi.hasKey())) {
      _needsSetup();
      return;
    }
    final shots = await (captureOverride ?? _captureApp)();
    try {
      final String raw;
      void streamed(String t) {
        final clean = _stripTag(ClickyBoard.strip(t));
        final d = ClickyBoard.writing(t);
        if (clean != reply || d != drawing) {
          drawing = d;
          _set(state, status: d ? 'Je dessine au tableau…' : '', reply: clean);
        }
      }

      if (usePro) {
        // Ton abonnement Claude, via ton Claude Code.
        raw = await ClaudeCode.ask(
          system: _system(shots),
          question: _withMemory(q),
          imagesB64: [for (final s in shots) s.png64],
          imageLabels: [
            for (var i = 0; i < shots.length; i++) 'Écran ${i + 1} (${shots[i].label}) :',
          ],
          onText: streamed,
          onStatus: (s) => _set(ClickyState.thinking, status: s),
        );
      } else if (useOllama) {
        raw = await Ollama.chat(
          system: _system(shots),
          memory: _memory,
          question: q,
          imagesB64: [for (final s in shots) s.png64],
          onText: streamed,
        );
      } else {
        final history = <Map<String, dynamic>>[
          for (final (u, a) in _memory) ...[
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
              {'type': 'text', 'text': q},
            ],
          },
        ];
        raw = await ClaudeApi.chat(
          system: _system(shots),
          history: history,
          tools: _tools,
          confirm: confirmAction,
          onStatus: (s) => _set(ClickyState.thinking, status: s),
          onText: streamed,
        );
      }
      drawing = false;
      final (spoken, newBoard) = ClickyBoard.extract(raw);
      final (text, point, label, screen) = parsePoint(spoken);
      if (newBoard != null) _showBoard(newBoard);
      _memory.add((
        q,
        [
          text.isEmpty ? '(je t\'ai montré à l\'écran)' : text,
          if (newBoard != null) '(tableau affiché : ${newBoard.summary})',
        ].join(' '),
      ));
      if (_memory.length > 6) _memory.removeAt(0);
      final shot = shots.isEmpty ? null : shots[(screen - 1).clamp(0, shots.length - 1)];
      if (point != null && shot != null) {
        target = shot.toLayer(point);
        targetLabel = label;
        _set(ClickyState.pointing, status: '', reply: text);
      } else {
        _set(ClickyState.speaking, status: '', reply: text);
      }
      await speak(text);
      if (state == ClickyState.speaking) {
        _set(ClickyState.idle);
        _fadeSoon();
      }
      if (state == ClickyState.pointing) {
        // On laisse la flèche le temps de voir, puis Clicky revient.
        Timer(const Duration(seconds: 4), () {
          if (state == ClickyState.pointing) {
            target = null;
            _set(ClickyState.idle);
            _fadeSoon();
          }
        });
      }
    } catch (e) {
      drawing = false;
      panelOpen = true;
      onInteractive?.call(true);
      _set(ClickyState.idle, status: '', reply: '$e');
    }
  }

  /// Claude Code ne garde pas la conversation : on lui rappelle les
  /// derniers échanges dans la question.
  String _withMemory(String q) {
    if (_memory.isEmpty) return q;
    final past = [for (final (u, a) in _memory) 'Toi : $u\nClicky : $a'].join('\n\n');
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
    final usePro = provider == 'claudecode';
    if (usePro
        ? await ClaudeCode.find() == null
        : (provider != 'claude' || !await ClaudeApi.hasKey())) {
      _set(
        ClickyState.idle,
        reply:
            'Le mode agent a besoin de Claude (ton abonnement Claude Pro ou une clé API) '
            'pour utiliser tes modules.',
      );
      return;
    }
    agentsRunning++;
    _set(ClickyState.idle, status: '', reply: 'C\'est parti, je m\'en occupe en arrière-plan.');
    unawaited(speak('C\'est parti, je m\'en occupe.'));
    _fadeSoon();
    try {
      final r = usePro
          ? await ClaudeCode.ask(
              system: _system(const [], agent: true),
              question: task,
              effort: 'high',
            )
          : await ClaudeApi.chat(
              system: _system(const [], agent: true),
              history: [
                {'role': 'user', 'content': task},
              ],
              tools: _tools,
              confirm: confirmAction,
              effort: 'high',
            );
      final text = parsePoint(ClickyBoard.strip(r)).$1;
      agentsRunning--;
      _set(state, reply: 'Agent : $text');
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

  static final _tagRe = RegExp(r'\[POINT:\s*([^\]]*)\]', caseSensitive: false);

  /// Retire la balise (même à moitié écrite) du texte affiché en direct.
  static String _stripTag(String t) =>
      t.replaceAll(_tagRe, '').replaceFirst(RegExp(r'\[[^\]]*$'), '').trim();

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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final mobile = size.width < 600;
    final cursor = c.follow ? c.cursor : null;
    final home = cursor == null
        ? Offset(size.width - 44, size.height - (mobile ? 150 : 60))
        : cursor + const Offset(18, 16);
    final at = c.target ?? home;

    final open = c.boxOpen;
    if (open && !_wasOpen) _anchor = cursor;
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
        // Le petit curseur bleu de Clicky (suit la souris, vole vers la cible).
        AnimatedOpacity(
          opacity: c.buddyVisible ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Stack(
            children: [
              _Flight(
                to: at,
                flying: c.target != null,
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
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Pointer(c: c),
      if (c.state == ClickyState.pointing && c.targetLabel.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(left: 4, top: 14),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: clickyBlue,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(blurRadius: 8, color: Color(0x33000000))],
          ),
          child: Text(
            c.targetLabel,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
    ],
  );
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
  const ClickyFollower({super.key, required this.c, required this.interactive});
  final ClickyController c;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: IgnorePointer(child: _PointerWithLabel(c: c)),
        ),
        Positioned(
          left: 22,
          top: 22,
          right: 4,
          bottom: c.board != null ? 4 : null,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
  const _Flight({required this.to, required this.flying, required this.child});
  final Offset to;
  final bool flying;
  final Widget child;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late Offset _from = widget.to;
  late Offset _pos = widget.to;

  @override
  void initState() {
    super.initState();
    _a.addListener(() {
      final t = Curves.easeInOutCubic.transform(_a.value);
      final a = _from, b = widget.to;
      // Point de contrôle au-dessus du milieu : joli arc.
      final mid = Offset((a.dx + b.dx) / 2, math.min(a.dy, b.dy) - (b - a).distance * 0.3 - 30);
      final u = 1 - t;
      setState(() => _pos = a * (u * u) + mid * (2 * u * t) + b * (t * t));
    });
  }

  @override
  void didUpdateWidget(_Flight old) {
    super.didUpdateWidget(old);
    if (old.to == widget.to) return;
    final arc = widget.flying != old.flying || (widget.to - _pos).distance > 300;
    if (arc) {
      _from = _pos;
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

class _Pointer extends StatelessWidget {
  const _Pointer({required this.c});
  final ClickyController c;

  @override
  Widget build(BuildContext context) {
    final thinking = c.state == ClickyState.thinking;
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
          color: listening ? Colors.redAccent : clickyBlue,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => c.panelOpen ? c.closePanel() : c.openPanel(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                color: Colors.white,
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
/// tour. On peut aussi y taper sa question.
class ClickyBox extends StatelessWidget {
  const ClickyBox({super.key, required this.c, this.compact = false});
  final ClickyController c;

  /// Plus petite (le tableau prend déjà de la place au-dessus).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final listening = c.state == ClickyState.listening;
    final busy = c.state == ClickyState.thinking;
    final problem = c.micProblem;
    final title = switch (c.state) {
      _ when problem != null => 'Souci de micro',
      ClickyState.listening => 'Je t\'écoute…',
      ClickyState.thinking => c.reply.isEmpty ? 'Je réfléchis…' : 'Clicky',
      _ => 'Clicky',
    };
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compact ? 520 : 360, maxHeight: compact ? 220 : 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Barre du haut : état, voix, fermer.
            Container(
              color: clickyBlue.withValues(alpha: 0.12),
              padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
              child: Row(
                children: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2, color: clickyBlue),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        listening ? Icons.mic_rounded : Icons.auto_awesome_rounded,
                        color: listening ? Colors.redAccent : clickyBlue,
                        size: 16,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      c.agentsRunning > 0
                          ? '$title · ${c.agentsRunning} agent${c.agentsRunning > 1 ? 's' : ''} au travail'
                          : title,
                      style: text.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (c.voice &&
                      (c.state == ClickyState.speaking || c.state == ClickyState.pointing))
                    IconButton(
                      tooltip: 'Arrêter de parler',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      onPressed: c.stopSpeaking,
                    ),
                  IconButton(
                    tooltip: c.voice ? 'Couper la voix de Clicky' : 'Remettre la voix de Clicky',
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
            Flexible(
              child: SingleChildScrollView(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Ce que tu dis, écrit en direct.
                    if (listening) ...[
                      _Wave(levels: c.levels),
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
                          '«\u00a0${c.transcript}\u00a0»',
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
                            const Icon(Icons.draw_rounded, size: 16, color: clickyBlue),
                            const SizedBox(width: 6),
                            Text('Je dessine au tableau…', style: text.bodySmall),
                          ],
                        ),
                      ),
                    if (!listening && c.status.isNotEmpty && !c.drawing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(c.status, style: text.bodySmall),
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
            // Raccourcis pour apprendre.
            if ((c.panelOpen || c.reply.isNotEmpty) &&
                c.state == ClickyState.idle &&
                problem == null &&
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
                        onTap: () => c.ask(ClickyController.visualPrompt),
                      ),
                    _QuickChip(
                      icon: Icons.school_rounded,
                      label: 'Apprends-moi un truc',
                      onTap: () => c.ask(ClickyController.teachPrompt),
                    ),
                    if (!c.hasHistory)
                      _QuickChip(
                        icon: Icons.screen_search_desktop_rounded,
                        label: 'Explique mon écran',
                        onTap: () => c.ask(ClickyController.explainScreenPrompt),
                      ),
                  ],
                ),
              ),
            // Écrire (ou parler) une question.
            if (c.panelOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: c.input,
                        focusNode: c.inputFocus,
                        autofocus: true,
                        enabled: !busy,
                        textInputAction: TextInputAction.send,
                        onSubmitted: c.ask,
                        decoration: const InputDecoration(
                          hintText: 'Demande-moi quelque chose…',
                          isDense: true,
                          border: OutlineInputBorder(),
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
            else if (c.state == ClickyState.idle && c.reply.isNotEmpty)
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
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: Icon(icon, size: 16, color: clickyBlue),
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
            if (problem.fixUri != null)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: Text(problem.fixLabel ?? 'Ouvrir les réglages'),
                onPressed: () => launchUrl(Uri.parse(problem.fixUri!)),
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
