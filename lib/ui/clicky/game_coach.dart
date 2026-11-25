import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../core/claude_api.dart';
import '../../core/error_log.dart';
import '../../core/game_pal.dart';
import '../../core/hub_module.dart';
import 'game_agent.dart';
import 'live.dart';
import 'pcm_player.dart';
import 'shot_encode.dart';
import 'win.dart';

/// **Le coach de jeu en direct** : quand tu joues, Nexo voit ton jeu **en
/// continu** et te guide à voix haute, comme un coéquipier.
///
/// Comment il voit : pas de captures envoyées à Claude (lent et gourmand en
/// jetons). L'image du jeu part **en flux vidéo** vers Gemini Live (ta clé
/// gratuite) : une petite image (768 px, qualité basse) toutes les
/// 2 secondes, comme une vidéo à très bas débit. Gemini garde le fil de la
/// partie et répond au tac au tac.
///
/// * Il donne un conseil **de lui-même** quand c'est utile (toutes les ~25 s
///   il regarde ; s'il n'y a rien d'important, il se tait : « RIEN »).
/// * Tu lui parles avec Ctrl + Alt (ou « Nexo… »), comme d'habitude : ta
///   question part dans la même conversation, avec ce qu'il voit.
/// * Vie privée : l'image ne part que quand le **jeu** est au premier plan
///   (tu passes sur Discord ou ton navigateur : plus rien n'est envoyé).
/// * Pas de triche : il conseille (stratégie, objectifs, astuces), il ne
///   joue jamais à ta place.
class GameCoach extends ChangeNotifier {
  GameCoach._();
  static final instance = GameCoach._();

  static bool get supported => Win.supportedHere && PcmPlayer.supported;

  static const frameEvery = Duration(seconds: 2);
  static const tipEvery = Duration(seconds: 25);

  /// Plus de jeu au premier plan depuis ce temps : le coach s'arrête.
  static const idleStop = Duration(minutes: 4);

  /// Largeur des images envoyées (en pixels).
  static const frameWidth = 768;

  GeminiLive? _live;
  PcmPlayer? _player;
  Timer? _frames, _tips;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _mic;

  bool get active => _live != null;

  /// Le jeu coaché.
  String game = '';

  /// Le dernier conseil (texte).
  String lastTip = '';

  /// Tu lui parles en ce moment.
  bool talking = false;

  DateTime _seenGame = DateTime.now();
  bool _sending = false;

  // Le conseil « de lui-même » : on attend ses premiers mots avant de jouer
  // le son (s'il répond « RIEN », on n'entend rien du tout).
  bool _hold = false, _decided = false;
  final _held = <Uint8List>[];
  final _turn = StringBuffer();

  /// Prévenir (bulle de Nexo). Branché par le contrôleur.
  void Function(String text)? say;

  /// L'agent de jeu (« craft-moi une pioche ») : le coach peut lui confier une
  /// action. Branché par le contrôleur.
  HubTool? actTool;

  /// Démarre le coach (le jeu au premier plan, ou [forGame]).
  Future<String> start({String? forGame}) async {
    if (!supported) return 'Le coach de jeu marche sur le PC.';
    if (active) return 'Je te coache déjà${game.isEmpty ? '' : ' sur $game'}.';
    final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    if (key.isEmpty) {
      return 'Pour te coacher en direct, il me faut ta clé Gemini gratuite (aistudio.google.com) : Réglages de Nexo → Voix.';
    }
    final g = (forGame ?? _foregroundGame() ?? '').trim();
    game = g;
    final info = g.isEmpty ? null : await GamePal.instance.cached(g);
    final act = actTool;
    final live = GeminiLive(
      key: key,
      system: CoachRules.system(g, info?.summary ?? '', canAct: act != null),
      tools: [?act],
      autoVad: false,
      mediaResolution: 'MEDIA_RESOLUTION_LOW',
    );
    final player = PcmPlayer();
    live
      ..onAudio = (pcm) {
        if (_hold && !_decided) {
          _held.add(pcm);
        } else {
          player.write(pcm);
        }
      }
      ..onOutputText = (t) {
        _turn.write(t);
        if (!_hold || _decided) return;
        final s = _turn.toString();
        if (CoachRules.silent(s)) return;
        if (s.trim().length >= 8) {
          _decided = true;
          for (final c in _held) {
            player.write(c);
          }
          _held.clear();
        }
      }
      ..onTurnComplete = _endTurn
      // « Craft-moi une pioche » : le coach confie la tâche à l'agent de jeu
      // (il joue vraiment à ta place) et prévient quand c'est fini.
      ..onToolCall = (name, args) async {
        if (act == null || name != act.name) return 'Action inconnue.';
        unawaited(act.run(args).then((r) => say?.call('$r')).catchError((Object e) => say?.call('$e')));
        return 'Nexo s\'en occupe maintenant (il joue à sa place). Dis seulement « Je m\'en occupe. »';
      }
      ..onClosed = (_) {};
    try {
      await live.connect();
    } catch (e) {
      player.close();
      return 'Je n\'arrive pas à joindre Gemini Live : $e';
    }
    _live = live;
    _player = player;
    _seenGame = DateTime.now();
    _frames = Timer.periodic(frameEvery, (_) => unawaited(_sendFrame()));
    _tips = Timer.periodic(tipEvery, (_) => unawaited(_tip()));
    notifyListeners();
    await _sendFrame();
    live.sendText(CoachRules.hello(g));
    return g.isEmpty
        ? 'Coach activé : je regarde ton écran et je te guide. Dis « arrête le coach » pour finir.'
        : 'Coach activé sur $g : je regarde ta partie et je te guide. Dis « arrête le coach » pour finir.';
  }

  /// Arrête le coach.
  Future<String> stop() async {
    if (!active) return 'Le coach n\'était pas lancé.';
    _frames?.cancel();
    _tips?.cancel();
    _frames = _tips = null;
    await talkEnd(send: false);
    final live = _live;
    _live = null;
    _player?.close();
    _player = null;
    _held.clear();
    _turn.clear();
    await live?.close();
    notifyListeners();
    return 'Coach arrêté. Bien joué !';
  }

  /// Tu commences à lui parler (Ctrl + Alt) : ta voix part dans la même
  /// conversation que l'image du jeu.
  Future<bool> talkStart() async {
    final live = _live;
    if (live == null || talking) return false;
    talking = true;
    _hold = false;
    await _ensureConnected();
    await _sendFrame();
    try {
      final rec = AudioRecorder();
      if (!await rec.hasPermission()) {
        await rec.dispose();
        talking = false;
        return false;
      }
      final stream = await rec.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      _rec = rec;
      live.activityStart();
      _mic = stream.listen(live.sendAudio, onError: (Object e) => ErrorLog.record(e, null, where: 'micro coach'));
      notifyListeners();
      return true;
    } catch (e) {
      talking = false;
      ErrorLog.record(e, null, where: 'micro coach');
      return false;
    }
  }

  /// Tu as fini de parler : il répond tout de suite.
  Future<void> talkEnd({bool send = true}) async {
    if (!talking) return;
    talking = false;
    await _mic?.cancel();
    _mic = null;
    final rec = _rec;
    _rec = null;
    try {
      await rec?.stop();
      await rec?.dispose();
    } catch (_) {}
    if (send) _live?.activityEnd();
    notifyListeners();
  }

  /// Une question écrite (ou entendue par Nexo) pendant la partie.
  Future<void> ask(String question) async {
    final live = _live;
    if (live == null) return;
    _hold = false;
    await _ensureConnected();
    await _sendFrame();
    live.sendText(question);
  }

  String? _foregroundGame() {
    try {
      return GamePal.instance.detect(exe: Win.foregroundExe(), path: Win.foregroundPath(), title: Win.foregroundTitle());
    } catch (_) {
      return null;
    }
  }

  /// Le jeu est au premier plan (sinon : rien n'est envoyé).
  bool _gameInFront() {
    final g = _foregroundGame();
    if (g == null) return false;
    return game.isEmpty || g.toLowerCase() == game.toLowerCase();
  }

  Future<void> _ensureConnected() async {
    final live = _live;
    if (live == null || live.connected || live.connecting) return;
    try {
      // Gemini coupe de temps en temps : on reprend la même conversation.
      await live.connect();
    } catch (_) {}
  }

  Future<void> _sendFrame() async {
    final live = _live;
    if (live == null || _sending) return;
    if (!_gameInFront()) {
      if (DateTime.now().difference(_seenGame) > idleStop) {
        final t = await stop();
        say?.call('Tu ne joues plus : $t');
      }
      return;
    }
    _seenGame = DateTime.now();
    _sending = true;
    try {
      await _ensureConnected();
      final r = Win.foregroundRect();
      if (r == null) return;
      final (x, y, w, h) = r;
      if (w < 200 || h < 150) return;
      final (tw, th) = CoachRules.frameSize(w, h, frameWidth);
      final px = Win.captureScaled(x, y, w, h, tw, th);
      final jpeg = await Isolate.run(() => encodeShot(px, tw, th, quality: 60));
      live.sendVideo(base64Encode(jpeg));
    } catch (_) {
    } finally {
      _sending = false;
    }
  }

  /// Toutes les ~25 s : un conseil s'il y en a un d'utile maintenant.
  Future<void> _tip() async {
    final live = _live;
    if (live == null || talking || _hold || !_gameInFront() || GameAgent.instance.active) return;
    await _ensureConnected();
    _hold = true;
    _decided = false;
    _held.clear();
    _turn.clear();
    live.sendText(CoachRules.tipPrompt);
  }

  void _endTurn() {
    final s = _turn.toString().trim();
    final quiet = CoachRules.silent(s);
    if (_hold && !_decided && !quiet && s.isNotEmpty) {
      for (final c in _held) {
        _player?.write(c);
      }
    }
    _held.clear();
    _hold = false;
    _decided = false;
    _turn.clear();
    if (!quiet && s.isNotEmpty) {
      lastTip = s;
      notifyListeners();
    }
  }

  /// Les outils (pour Nexo : « coach-moi », « arrête le coach »).
  List<HubTool> tools() => [
    HubTool(
      name: 'jeu_coach',
      description:
          'Coach de jeu en direct : Nexo voit le jeu en continu (flux vidéo léger vers Gemini Live, gratuit) et guide '
          'la personne à voix haute pendant sa partie. action = lancer ou arreter. À utiliser pour « coach-moi », '
          '« aide-moi dans ce jeu », « guide-moi », « arrête le coach ».',
      params: {
        'action': ('string', 'lancer (défaut) ou arreter'),
        'jeu': ('string', 'le nom du jeu (facultatif : celui au premier plan)'),
      },
      run: (a) async {
        final stopIt = '${a['action'] ?? ''}'.toLowerCase().startsWith('arr');
        final g = '${a['jeu'] ?? ''}'.trim();
        final text = stopIt ? await stop() : await start(forGame: g.isEmpty ? null : g);
        return {'resume': text, 'actif': active, if (game.isNotEmpty) 'jeu': game};
      },
    ),
  ];
}

/// Les règles du coach, **sans Windows** : testables.
class CoachRules {
  CoachRules._();

  /// Ses consignes (Gemini Live).
  static String system(String game, String about, {bool canAct = false}) =>
      'Tu es Nexo, le coach de jeu vidéo de la personne, en direct et à voix haute, en français. Tu reçois en continu '
      'des images de son écran de jeu (environ une toutes les 2 secondes).'
      '${game.isEmpty ? '' : ' Le jeu : $game.'}${about.isEmpty ? '' : ' Ce qu\'on en sait : $about'}\n'
      'Ton rôle : l\'aider à progresser et à gagner comme un bon coéquipier — stratégie, objectifs, ressources, '
      'dangers, erreurs à éviter, astuces de contrôles, où aller. Parle comme dans un vocal entre potes : une ou deux '
      'phrases très courtes, concrètes, sur ce que tu vois MAINTENANT. Jamais de triche ni de logiciel interdit. '
      'Si tu ne vois pas assez bien pour être sûr, dis-le en trois mots au lieu d\'inventer. '
      'Quand on te demande « un conseil maintenant ? » et qu\'il n\'y a rien d\'important à dire, réponds exactement '
      'RIEN et rien d\'autre.'
      '${canAct ? ' Si la personne te demande de FAIRE quelque chose dans le jeu à sa place (ouvrir l\'inventaire, '
                'crafter un objet, poser un bloc, une commande…), appelle jeu_agir avec le but, puis dis juste « Je m\'en '
                'occupe. ». Jamais dans un jeu en ligne compétitif.' : ''}';

  /// La question posée de lui-même, régulièrement.
  static const tipPrompt =
      '(Coach) Regarde la dernière image. Un conseil vraiment utile maintenant (danger, objectif, ressource, erreur) ? '
      'Une phrase courte. Sinon réponds seulement : RIEN';

  /// Ce qu'il dit au démarrage.
  static String hello(String game) =>
      'Le coach démarre${game.isEmpty ? '' : ' sur $game'}. Dis bonjour en une phrase très courte, puis dis ce que tu '
      'vois sur l\'écran en une phrase.';

  /// Il n'a rien à dire (« RIEN »).
  static bool silent(String said) {
    final t = said.trim().toLowerCase().replaceAll(RegExp(r'[^a-zàâäéèêëîïôöùûü ]'), '').trim();
    return t.isEmpty || t == 'rien' || t.startsWith('rien ') || t == 'r' || t == 'ri' || t == 'rie';
  }

  /// Taille de l'image envoyée (largeur [maxW], proportions gardées, nombres
  /// pairs).
  static (int, int) frameSize(int w, int h, int maxW) {
    if (w <= maxW) return (w & ~1, h & ~1);
    final th = (h * maxW / w).round();
    return (maxW & ~1, th & ~1);
  }

  /// « Coach-moi », « arrête le coach » (phrase nettoyée) → lancer / arreter.
  static String? command(String n) {
    if (RegExp(
      r'^(?:arrete|stop|coupe|termine|desactive|ferme)(?: le)? (?:coach|coaching|mode coach)$|^plus de coach$',
    ).hasMatch(n)) {
      return 'arreter';
    }
    if (RegExp(
      r'^(?:coach(?:e|es)? moi|mode coach|lance le coach|active le coach|coache moi|sois mon coach|'
      r'aide moi (?:dans|a) (?:ce|mon|le) jeu|guide moi (?:dans|pendant) (?:ce|mon|le) jeu|guide moi en jouant)$',
    ).hasMatch(n)) {
      return 'lancer';
    }
    return null;
  }
}
