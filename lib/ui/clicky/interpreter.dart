import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';

import '../../core/claude_api.dart';
import '../../core/error_log.dart';
import '../../core/nav.dart';
import 'live.dart';
import 'pcm_player.dart';

/// Une phrase entendue, et sa traduction.
class InterpretLine {
  InterpretLine(this.heard);
  String heard;
  String said = '';
}

/// **Interprète en direct** : tu parles avec quelqu'un dans une autre
/// langue, Nexo traduit à voix haute dans les deux sens (Gemini Live).
class Interpreter {
  Interpreter._();

  static const languages = {
    'Anglais': 'anglais',
    'Espagnol': 'espagnol',
    'Allemand': 'allemand',
    'Italien': 'italien',
    'Portugais': 'portugais',
    'Arabe': 'arabe',
    'Chinois': 'chinois (mandarin)',
    'Japonais': 'japonais',
    'Coréen': 'coréen',
    'Russe': 'russe',
    'Turc': 'turc',
    'Ukrainien': 'ukrainien',
    'Polonais': 'polonais',
    'Néerlandais': 'néerlandais',
    'Roumain': 'roumain',
  };

  /// Les consignes : traduire, et seulement traduire.
  static String system(String language) =>
      'Tu es un interprète simultané entre le français et le $language. '
      'Pour chaque phrase que tu entends : si elle est en français, répète-la en $language ; si elle est en $language '
      '(ou dans une autre langue), répète-la en français. Traduis fidèlement, à la première personne, avec le même ton. '
      'N\'ajoute rien, ne réponds jamais aux questions, ne donne aucun avis, ne te présente pas : tu es seulement la voix '
      'de la traduction. Si tu n\'as rien compris, ne dis rien.';
}

class InterpreterPage extends StatefulWidget {
  const InterpreterPage({super.key, this.language = 'Anglais'});
  final String language;

  static Future<void> open({String language = 'Anglais'}) async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(builder: (_) => InterpreterPage(language: language)));
  }

  @override
  State<InterpreterPage> createState() => _InterpreterPageState();
}

class _InterpreterPageState extends State<InterpreterPage> {
  late String _language = Interpreter.languages.containsKey(widget.language) ? widget.language : 'Anglais';
  GeminiLive? _live;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _mic;
  PcmPlayer? _player;
  final _lines = <InterpretLine>[];
  bool _starting = false;
  String? _error;
  double _level = 0;
  final _scroll = ScrollController();

  bool get _on => _live != null;

  @override
  void dispose() {
    unawaited(_stop());
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!PcmPlayer.supported) {
      setState(() => _error = 'L\'interprète marche sur le PC (Windows).');
      return;
    }
    final key = (await ClaudeApi.store.readSecret('gemini.key') ?? '').trim();
    if (key.isEmpty) {
      setState(() => _error = 'Il faut ta clé Gemini gratuite (aistudio.google.com) : Réglages de Nexo → Voix.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    final live = GeminiLive(
      key: key,
      system: Interpreter.system(Interpreter.languages[_language]!),
      tools: const [],
      voice: 'Kore',
      language: null,
      autoVad: true,
    );
    final player = PcmPlayer();
    live
      ..onAudio = player.write
      ..onInputText = (t) {
        if (!mounted) return;
        setState(() {
          if (_lines.isEmpty || _lines.last.said.isNotEmpty) _lines.add(InterpretLine(''));
          _lines.last.heard += t;
        });
        _down();
      }
      ..onOutputText = (t) {
        if (!mounted) return;
        setState(() {
          if (_lines.isEmpty) _lines.add(InterpretLine(''));
          _lines.last.said += t;
        });
        _down();
      }
      ..onInterrupted = player.stop
      ..onClosed = (e) {
        if (mounted && _live == live) setState(() => _error = 'La connexion s\'est coupée. Relance l\'interprète.');
        unawaited(_stop());
      };
    try {
      await live.connect();
      final rec = AudioRecorder();
      if (!await rec.hasPermission()) {
        await rec.dispose();
        throw 'Windows empêche Mon Hub d\'utiliser le micro (Paramètres → Confidentialité → Microphone).';
      }
      final stream = await rec.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1, echoCancel: true, noiseSuppress: true),
      );
      _rec = rec;
      _player = player;
      _live = live;
      _mic = stream.listen((chunk) {
        // Pendant que la traduction est lue, le micro se tait : sinon
        // Nexo se traduirait lui-même.
        if (player.playing) return;
        live.sendAudio(chunk);
        final lv = PcmPlayer.rms(chunk);
        if (mounted && (lv - _level).abs() > 0.03) setState(() => _level = lv);
      }, onError: (Object e) => ErrorLog.record(e, null, where: 'micro interprète'));
    } catch (e) {
      await live.close();
      player.close();
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    final live = _live;
    _live = null;
    await _mic?.cancel();
    _mic = null;
    final rec = _rec;
    _rec = null;
    try {
      await rec?.stop();
    } catch (_) {}
    await rec?.dispose();
    _player?.close();
    _player = null;
    await live?.close();
    if (mounted) setState(() => _level = 0);
  }

  void _down() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Interprète'),
        actions: [
          DropdownButton<String>(
            value: _language,
            underline: const SizedBox.shrink(),
            items: [for (final l in Interpreter.languages.keys) DropdownMenuItem(value: l, child: Text('Français ⇄ $l'))],
            onChanged: _on || _starting ? null : (v) => setState(() => _language = v ?? _language),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _on
                            ? 'Parlez chacun votre tour : je traduis à voix haute, du français vers le ${_language.toLowerCase()} '
                                'et inversement.'
                            : 'Pour parler avec quelqu\'un dans une autre langue : choisis la langue en haut, puis « Commencer ». '
                                'Mets plutôt des écouteurs… ou laisse-moi finir de traduire avant de reparler.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) {
                      final l = _lines[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (l.heard.trim().isNotEmpty) Text('🗣️ ${l.heard.trim()}', style: theme.textTheme.bodyMedium),
                            if (l.said.trim().isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text('🔊 ${l.said.trim()}', style: theme.textTheme.titleMedium),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_on) ...[
                  SizedBox(width: 120, child: LinearProgressIndicator(value: _level.clamp(0.0, 1.0), minHeight: 6)),
                  const SizedBox(width: 16),
                ],
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                    backgroundColor: _on ? Colors.red : null,
                  ),
                  onPressed: _starting ? null : (_on ? _stop : _start),
                  icon: Icon(_on ? Icons.stop_rounded : Icons.translate_rounded),
                  label: Text(_starting ? 'Connexion…' : (_on ? 'Arrêter' : 'Commencer')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
