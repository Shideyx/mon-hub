import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../core/error_log.dart';
import '../../core/hub_module.dart';
import 'live.dart';
import 'pcm_player.dart';
import 'tutor.dart' show normalize;

/// Où en est la conversation.
enum TalkState { off, connecting, listening, thinking, speaking }

/// Que faire d'un morceau du micro.
enum MicGate {
  /// L'envoyer à Gemini.
  send,

  /// Le garder pour soi (Nexo parle : sinon il s'entendrait lui-même).
  silence,

  /// Tu parles par-dessus Nexo : il se tait et t'écoute.
  bargeIn,
}

/// Les règles de la conversation mains libres, **sans micro ni réseau**
/// (testables).
class TalkRules {
  TalkRules._();

  /// Rien dit pendant ce temps : la conversation s'arrête toute seule.
  static const idle = Duration(seconds: 45);

  /// Juste après sa voix, l'écho de la pièce : le micro attend encore un peu.
  static const echoTail = Duration(milliseconds: 350);

  /// Pour lui couper la parole : une voix nettement plus forte que la sienne,
  /// plusieurs morceaux de suite (pas un bruit, pas son écho).
  static const bargeLevel = 0.45;
  static const bargeChunks = 3;

  static final _start = RegExp(
    r'^(?:(?:passe en |active le |lance le |on passe en |mets le )?mode (?:conversation|jarvis|discussion)|'
    r'on discute|on peut discuter|discutons|parlons|on parle un peu|on papote|parle avec moi|discute avec moi|'
    r'(?:lance |commence |demarre )?(?:une |la )?conversation(?: en direct| continue)?)$',
  );

  static final _end = RegExp(
    r'^(?:merci(?: beaucoup)?(?: c est tout| ca ira| c est bon)?|c est tout(?: merci)?|au revoir|a plus(?: tard)?|'
    r'bye|bonne nuit|fin de (?:la )?conversation|arrete(?: la conversation| de m ecouter| d ecouter)?|stop|'
    r'tu peux arreter|on arrete(?: la)?|c est bon(?: merci)?|ca ira(?: merci)?|laisse moi|chut|termine)$',
  );

  static final _stopPhrase = RegExp(
    r'^(?:arrete|stoppe|termine|coupe|quitte|ferme) (?:la |le |le mode )?(?:conversation|discussion|mode jarvis|jarvis)$|'
    r'^fin de (?:la )?conversation$',
  );

  static String _clean(String s) =>
      normalize(s)
          .replaceFirst(RegExp(r'^(?:hey|ok|dis|eh) (?=nexo|nekso)'), '')
          .replaceAll(RegExp(r'\b(?:nexo|nexos|nekso|nexou|clicky)\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  /// « Mode conversation », « on discute », « parlons ».
  static bool isStart(String said) => _start.hasMatch(_clean(said));

  /// « Arrête la conversation ».
  static bool isStop(String said) => _stopPhrase.hasMatch(_clean(said));

  /// Dans la conversation : « merci Nexo, c'est tout », « au revoir ».
  static bool isGoodbye(String said) {
    final c = _clean(said);
    return _end.hasMatch(c) || _stopPhrase.hasMatch(c);
  }

  /// Ce que devient un morceau du micro. [level] : son volume ; [nexoLevel] :
  /// celui de sa voix en ce moment ; [loudChunks] : morceaux forts juste avant.
  static MicGate gate({
    required double level,
    required bool nexoSpeaking,
    required int loudChunks,
    required Duration sinceSpoke,
    double nexoLevel = 0,
  }) {
    if (nexoSpeaking) {
      final loud = level >= bargeLevel && level > nexoLevel + 0.15;
      return loud && loudChunks + 1 >= bargeChunks ? MicGate.bargeIn : MicGate.silence;
    }
    if (sinceSpoke < echoTail) return MicGate.silence;
    return MicGate.send;
  }

  /// Le morceau est-il « fort » (compte pour couper la parole) ?
  static bool loud(double level, double nexoLevel) => level >= bargeLevel && level > nexoLevel + 0.15;

  /// Les consignes de la conversation (ajoutées à celles de Nexo).
  static String system(String base) =>
      '''$base
${GeminiLive.voiceStyle}
CONVERSATION EN DIRECT (mode JARVIS) : la personne te parle à voix haute, mains libres, comme à un vrai assistant. Réponds tout de suite, à l'oral, en 1 à 3 phrases naturelles (plus seulement si elle le demande), sans liste ni symbole. Garde le fil de toute la conversation. Pour lire ses données ou agir, utilise les fonctions de Mon Hub (agenda, cours, devoirs, notes, messages, musique, carnet…) ; n'utilise « expliquer_au_tableau » que si elle veut vraiment un schéma. Si elle dit au revoir, « c'est tout » ou « merci, ça ira », réponds en trois mots (« À plus tard. ») puis tais-toi. Si tu n'as pas compris, demande de répéter, en une phrase courte.''';

  /// Le premier message : il dit juste qu'il écoute (dans sa voix à lui).
  static const hello =
      '(La personne vient d\'ouvrir la conversation à voix haute. Dis seulement « Je t\'écoute. » ou une salutation '
      'de trois mots, rien d\'autre.)';

  /// La phrase de fin, dite selon la raison.
  static String endNote(String why) => switch (why) {
    'silence' => 'Je coupe la conversation (plus rien entendu). Dis « on discute » pour reprendre.',
    'au revoir' => 'Conversation terminée.',
    'quota' =>
      'Le quota gratuit de Gemini est atteint pour le moment : on reprendra plus tard (Ctrl + Alt marche toujours).',
    '' => 'Conversation terminée.',
    _ => why,
  };
}

/// **La conversation mains libres façon JARVIS** : une seule connexion
/// Gemini Live (gratuite avec ta clé), le micro ouvert, Gemini repère tout
/// seul quand tu parles et quand tu as fini, et répond tout de suite avec la
/// voix de Nexo — toujours la même voix ([GeminiLive.voiceStyle]). Aucun jeton
/// Claude : les actions de Mon Hub passent par Gemini.
///
/// Garde-fous : le micro se tait pendant que Nexo parle (il ne s'entend pas
/// lui-même), sauf si tu lui coupes la parole franchement ; tout s'arrête après
/// 45 s de silence, un « merci Nexo, c'est tout » ou Échap.
class JarvisTalk {
  JarvisTalk({
    required this.key,
    required this.system,
    this.tools = const [],
    this.extra = const [],
    this.onTool,
    this.voice = 'Charon',
  });

  final String key;
  final String system;
  final List<HubTool> tools;
  final List<Map<String, dynamic>> extra;
  final Future<Object?> Function(String name, Map<String, dynamic> args)? onTool;
  final String voice;

  final state = ValueNotifier<TalkState>(TalkState.off);

  /// Volume du micro (0..1), pour l'animation.
  double level = 0;

  /// Ce que tu dis / ce qu'il répond (tour en cours).
  String heard = '';
  String said = '';

  /// Un tour fini (pour l'historique).
  void Function(String question, String answer)? onTurn;

  /// Le texte a changé (bulle de Nexo).
  void Function()? onChanged;

  /// C'est fini (raison : 'silence', 'au revoir', 'quota', '' ou l'erreur).
  void Function(String why)? onEnd;

  GeminiLive? _live;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _mic;
  final _player = PcmPlayer();
  int _loud = 0;
  DateTime _spokeAt = DateTime(2000);
  Timer? _idle;
  bool _ending = false;
  int _reconnects = 0;

  bool get active => state.value != TalkState.off;

  Future<void> start() async {
    if (active) return;
    if (!PcmPlayer.supported) throw 'La conversation en direct marche sur le PC (Windows).';
    if (key.trim().isEmpty) {
      throw 'Il me faut ta clé Gemini gratuite (Réglages de Nexo → Voix) pour discuter en direct.';
    }
    _ending = false;
    state.value = TalkState.connecting;
    try {
      await _open();
      final rec = _rec = AudioRecorder();
      if (!await rec.hasPermission()) {
        throw 'Windows empêche Mon Hub d\'utiliser le micro (Paramètres → Confidentialité → Microphone).';
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
      _mic = stream.listen(_onMic, onError: (Object e) => ErrorLog.record(e, null, where: 'micro conversation'));
      state.value = TalkState.listening;
      _live?.sendText(TalkRules.hello);
      _armIdle();
    } catch (e) {
      await stop(why: '$e');
      rethrow;
    }
  }

  Future<void> _open() async {
    final l = _live ??=
        GeminiLive(
            key: key,
            system: system,
            tools: tools,
            extraDeclarations: extra,
            voice: voice,
            autoVad: true,
            temperature: 0.6,
          )
          ..onAudio = _onAudio
          ..onOutputText = (t) {
            said += t;
            onChanged?.call();
          }
          ..onInputText = (t) {
            if (said.isNotEmpty && !_player.playing) {
              // Tu reparles après sa réponse : nouveau tour.
              said = '';
            }
            heard += t;
            if (state.value != TalkState.speaking) state.value = TalkState.listening;
            _armIdle();
            onChanged?.call();
          }
          ..onInterrupted = _player.stop
          ..onTurnComplete = (() {
            unawaited(_turnDone());
          })
          ..onToolCall = onTool
          ..onToolStatus = ((_) {
            state.value = TalkState.thinking;
          })
          ..onGoAway = (() {
            unawaited(_reconnect());
          })
          ..onClosed = ((why) {
            unawaited(_closed(why));
          });
    await l.connect();
  }

  void _onAudio(Uint8List pcm) {
    if (!active) return;
    _player.write(pcm);
    _spokeAt = DateTime.now();
    if (state.value != TalkState.speaking) state.value = TalkState.speaking;
    _armIdle();
  }

  void _onMic(Uint8List chunk) {
    final live = _live;
    if (live == null || !live.connected) return;
    final lv = PcmPlayer.rms(chunk);
    level = lv;
    final speaking = _player.playing;
    if (speaking) _spokeAt = DateTime.now();
    final g = TalkRules.gate(
      level: lv,
      nexoSpeaking: speaking,
      loudChunks: _loud,
      sinceSpoke: DateTime.now().difference(_spokeAt),
      nexoLevel: _player.level,
    );
    _loud = speaking && TalkRules.loud(lv, _player.level) ? _loud + 1 : 0;
    switch (g) {
      case MicGate.send:
        live.sendAudio(chunk);
      case MicGate.silence:
        break;
      case MicGate.bargeIn:
        // Tu lui coupes la parole : il se tait et t'écoute.
        _player.stop();
        _spokeAt = DateTime(2000);
        _loud = 0;
        live.sendAudio(chunk);
        state.value = TalkState.listening;
    }
    if (lv > 0.12 && !speaking) _armIdle();
  }

  Future<void> _turnDone() async {
    _player.flush();
    final q = heard.trim(), a = said.trim();
    heard = '';
    if (q.isNotEmpty || a.isNotEmpty) onTurn?.call(q, a);
    if (q.isNotEmpty && TalkRules.isGoodbye(q)) {
      // Il finit sa petite phrase, puis s'arrête.
      for (var i = 0; i < 60 && _player.playing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await stop(why: 'au revoir');
      return;
    }
    if (active) {
      // Sa voix finit de se jouer, puis il réécoute.
      for (var i = 0; i < 300 && _player.playing && active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (active && state.value != TalkState.listening) state.value = TalkState.listening;
    }
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    if (!active) return;
    _idle = Timer(TalkRules.idle, () {
      if (_player.playing) return _armIdle();
      unawaited(stop(why: 'silence'));
    });
  }

  /// Le serveur coupe au bout de quelques minutes : on rouvre, la
  /// conversation reprend là où elle en était (même session).
  Future<void> _reconnect() async {
    if (!active || _ending) return;
    if (_reconnects >= 5) {
      return stop(why: 'La connexion à Gemini s\'est coupée trop souvent. Réessaie dans un moment.');
    }
    _reconnects++;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      await _live?.connect();
    } catch (e) {
      await stop(why: _quota(e) ? 'quota' : 'La connexion à Gemini s\'est coupée ($e).');
    }
  }

  Future<void> _closed(Object why) async {
    if (!active || _ending) return;
    if (_quota(why)) return stop(why: 'quota');
    await _reconnect();
  }

  static bool _quota(Object e) =>
      RegExp(r'RESOURCE_EXHAUSTED|quota|rate.?limit|\b429\b|exceeded', caseSensitive: false).hasMatch('$e');

  /// Une question écrite pendant la conversation : même fil, même voix.
  void sendText(String text) {
    final t = text.trim();
    if (t.isEmpty || _live == null) return;
    heard = t;
    said = '';
    state.value = TalkState.thinking;
    _live!.sendText(t);
    _armIdle();
    onChanged?.call();
  }

  /// Arrête tout (micro, voix, connexion).
  Future<void> stop({String why = ''}) async {
    if (state.value == TalkState.off && _live == null) return;
    _ending = true;
    _idle?.cancel();
    final mic = _mic;
    _mic = null;
    await mic?.cancel();
    final rec = _rec;
    _rec = null;
    try {
      await rec?.stop();
    } catch (_) {}
    try {
      await rec?.dispose();
    } catch (_) {}
    _player.stop();
    final l = _live;
    _live = null;
    await l?.close();
    _player.close();
    final was = state.value;
    state.value = TalkState.off;
    if (was != TalkState.off) onEnd?.call(why);
  }
}
