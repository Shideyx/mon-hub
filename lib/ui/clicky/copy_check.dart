import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ai_text.dart';
import '../../core/nav.dart';
import '../../core/phone_link.dart';
import '../../core/photo.dart';

/// Une faute repérée sur la photo.
class CopyMistake {
  const CopyMistake({required this.box, required this.type, required this.wrong, required this.fix, required this.why});

  /// [haut, gauche, bas, droite] entre 0 et 1 (part de l'image).
  final List<double> box;
  final String type;
  final String wrong;
  final String fix;
  final String why;
}

/// Ce que Nexo pense de la copie.
class CopyReport {
  const CopyReport({this.grade, this.summary = '', this.mistakes = const [], this.good = const [], this.tips = const []});
  final double? grade;
  final String summary;
  final List<CopyMistake> mistakes;
  final List<String> good;
  final List<String> tips;
}

/// **Correction de copie sur la photo** : Nexo entoure chaque faute à
/// l'endroit exact de la feuille, comme un prof, avec l'explication.
class CopyCheck {
  CopyCheck._();

  static const subjects = ['Français', 'Anglais', 'Espagnol', 'Allemand', 'Maths', 'Physique-chimie', 'Autre'];

  static String prompt(String subject) {
    final maths = subject == 'Maths' || subject == 'Physique-chimie';
    return 'Tu es un professeur bienveillant qui corrige la copie d\'un lycéen ($subject), prise en photo.\n'
        'Repère ${maths ? 'les erreurs de calcul, de raisonnement, de notation et de rédaction' : 'les fautes d\'orthographe, de grammaire, de conjugaison, d\'accord, de ponctuation, de vocabulaire et de style'}. '
        'Pour CHAQUE faute, donne sa position exacte sur l\'image : "box_2d" = [ymin, xmin, ymax, xmax] '
        'en millièmes de la hauteur et de la largeur (0 à 1000), qui entoure juste le mot ou le passage fautif.\n'
        'Réponds UNIQUEMENT avec un objet JSON, sans texte autour :\n'
        '{"note_sur_20": nombre ou null, "resume": "2 phrases en français", '
        '"fautes": [{"box_2d": [ymin, xmin, ymax, xmax], "type": "orthographe|grammaire|conjugaison|accord|ponctuation|'
        'vocabulaire|style|calcul|raisonnement|redaction", "faux": "ce qui est écrit", "correction": "la bonne version", '
        '"explication": "la règle, en une phrase simple"}], "points_forts": ["…"], "conseils": ["…"]}\n'
        'Au plus 40 fautes, de haut en bas. Si l\'écriture est illisible à un endroit, ne l\'invente pas.';
  }

  /// La réponse de l'IA, vérifiée (positions bornées, champs nettoyés).
  static CopyReport? parse(String answer) {
    final a = answer.indexOf('{');
    final b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    Object? data;
    try {
      data = jsonDecode(answer.substring(a, b + 1));
    } catch (_) {
      return null;
    }
    if (data is! Map) return null;
    String str(Object? v, [int max = 300]) {
      final t = '${v ?? ''}'.trim();
      return t.length > max ? '${t.substring(0, max)}…' : t;
    }

    List<String> strs(Object? v) => [for (final e in (v is List ? v : const [])) if (str(e).isNotEmpty) str(e)].take(6).toList();
    final mistakes = <CopyMistake>[];
    for (final f in (data['fautes'] is List ? data['fautes'] as List : const [])) {
      if (f is! Map) continue;
      final raw = f['box_2d'];
      if (raw is! List || raw.length != 4 || raw.any((x) => x is! num)) continue;
      final v = [for (final x in raw) ((x as num).toDouble() / 1000).clamp(0.0, 1.0)];
      // [haut, gauche, bas, droite], dans le bon ordre.
      final box = [v[0] < v[2] ? v[0] : v[2], v[1] < v[3] ? v[1] : v[3], v[0] < v[2] ? v[2] : v[0], v[1] < v[3] ? v[3] : v[1]];
      if (box[2] - box[0] < 0.003 || box[3] - box[1] < 0.003) continue;
      mistakes.add(
        CopyMistake(box: box, type: str(f['type'], 30), wrong: str(f['faux'], 120), fix: str(f['correction'], 160), why: str(f['explication'])),
      );
      if (mistakes.length >= 40) break;
    }
    final g = data['note_sur_20'];
    return CopyReport(
      grade: g is num && g >= 0 && g <= 20 ? g.toDouble() : null,
      summary: str(data['resume'], 600),
      mistakes: mistakes,
      good: strs(data['points_forts']),
      tips: strs(data['conseils']),
    );
  }

  static Future<CopyReport> check(Uint8List photo, String subject) async {
    final (jpg, _, _) = await Photo.toJpeg(photo, maxSide: 1800, quality: 90);
    final answer = await AiText.ask(
      prompt(subject),
      images: [base64Encode(jpg)],
      system: 'Tu es un correcteur précis. Tu réponds seulement en JSON valide.',
    );
    final r = parse(answer);
    if (r == null) throw 'Je n\'ai pas réussi à lire la copie. Reprends la photo bien à plat, avec de la lumière.';
    return r;
  }
}

/// La page : choisir la photo, puis la copie corrigée en rouge.
class CopyCheckPage extends StatefulWidget {
  const CopyCheckPage({super.key, this.path});
  final String? path;

  static Future<void> open({String? path}) async {
    final nav = hubNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(MaterialPageRoute<void>(builder: (_) => CopyCheckPage(path: path)));
  }

  @override
  State<CopyCheckPage> createState() => _CopyCheckPageState();
}

class _CopyCheckPageState extends State<CopyCheckPage> {
  Uint8List? _photo;
  String _subject = 'Français';
  CopyReport? _report;
  String? _error;
  bool _busy = false;
  int? _selected;
  int _phoneSeen = 0;

  @override
  void initState() {
    super.initState();
    if (widget.path != null) unawaited(_load(widget.path!));
    _phoneSeen = PhoneLink.instance.received.length;
    PhoneLink.instance.addListener(_fromPhone);
  }

  @override
  void dispose() {
    PhoneLink.instance.removeListener(_fromPhone);
    super.dispose();
  }

  /// Une photo envoyée depuis le téléphone (page Mon téléphone) s'ouvre ici.
  void _fromPhone() {
    final list = PhoneLink.instance.received;
    if (list.length == _phoneSeen) return;
    _phoneSeen = list.length;
    final f = list.first;
    final ext = f.name.split('.').last.toLowerCase();
    if (Photo.extensions.contains(ext) && mounted) unawaited(_load(f.path));
  }

  Future<void> _load(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _report = null;
        _error = null;
        _selected = null;
      });
      await _run();
    } catch (e) {
      if (mounted) setState(() => _error = 'Photo illisible.');
    }
  }

  Future<void> _pick() async {
    final f = await openFile(
      acceptedTypeGroups: const [XTypeGroup(label: 'Photos', extensions: Photo.extensions)],
    );
    if (f != null) await _load(f.path);
  }

  Future<void> _run() async {
    final p = _photo;
    if (p == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    try {
      final r = await CopyCheck.check(p, _subject);
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.contains('clé') || '$e'.contains('Pas de') ? 'Il faut le cerveau de Nexo (clé Gemini conseillée) et internet.' : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _color(String type) => switch (type) {
    'orthographe' || 'accord' || 'conjugaison' => const Color(0xFFE11D48),
    'grammaire' || 'ponctuation' => const Color(0xFFEA580C),
    'calcul' || 'raisonnement' => const Color(0xFF7C3AED),
    _ => const Color(0xFF2563EB),
  };

  Widget _sheet() {
    final photo = _photo!;
    final r = _report;
    return InteractiveViewer(
      maxScale: 6,
      child: LayoutBuilder(
        builder: (context, c) => Center(
          child: Stack(
            children: [
              Image.memory(photo, fit: BoxFit.contain),
              if (r != null)
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, box) => Stack(
                      children: [
                        for (var i = 0; i < r.mistakes.length; i++)
                          Positioned(
                            top: r.mistakes[i].box[0] * box.maxHeight - 3,
                            left: r.mistakes[i].box[1] * box.maxWidth - 3,
                            width: (r.mistakes[i].box[3] - r.mistakes[i].box[1]) * box.maxWidth + 6,
                            height: (r.mistakes[i].box[2] - r.mistakes[i].box[0]) * box.maxHeight + 6,
                            child: GestureDetector(
                              onTap: () => setState(() => _selected = i),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: _color(r.mistakes[i].type).withValues(alpha: _selected == i ? 0.22 : 0.08),
                                        border: Border.all(color: _color(r.mistakes[i].type), width: _selected == i ? 3 : 2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: -10,
                                    right: -10,
                                    child: CircleAvatar(
                                      radius: 10,
                                      backgroundColor: _color(r.mistakes[i].type),
                                      child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(ThemeData theme) {
    final r = _report;
    if (_busy) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Je corrige ta copie…')],
        ),
      );
    }
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!)));
    if (r == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(
              radius: 24,
              child: Text(r.grade == null ? '✓' : r.grade!.toStringAsFixed(r.grade! % 1 == 0 ? 0 : 1)),
            ),
            title: Text(r.grade == null ? '${r.mistakes.length} faute${r.mistakes.length > 1 ? 's' : ''}' : 'Note estimée : ${r.grade!.toStringAsFixed(1).replaceAll('.0', '')} / 20'),
            subtitle: Text(r.summary),
          ),
        ),
        for (var i = 0; i < r.mistakes.length; i++)
          Card(
            color: _selected == i ? _color(r.mistakes[i].type).withValues(alpha: 0.10) : null,
            child: ListTile(
              onTap: () => setState(() => _selected = i),
              leading: CircleAvatar(
                radius: 13,
                backgroundColor: _color(r.mistakes[i].type),
                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              title: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: r.mistakes[i].wrong, style: const TextStyle(decoration: TextDecoration.lineThrough)),
                    const TextSpan(text: '  →  '),
                    TextSpan(text: r.mistakes[i].fix, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              subtitle: Text('${r.mistakes[i].type} · ${r.mistakes[i].why}'),
            ),
          ),
        if (r.good.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('👍 Ce qui est réussi', style: theme.textTheme.titleSmall),
          for (final g in r.good) Text('• $g'),
        ],
        if (r.tips.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('💡 Pour progresser', style: theme.textTheme.titleSmall),
          for (final t in r.tips) Text('• $t'),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = _photo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Corriger ma copie'),
        actions: [
          DropdownButton<String>(
            value: _subject,
            underline: const SizedBox.shrink(),
            items: [for (final s in CopyCheck.subjects) DropdownMenuItem(value: s, child: Text(s))],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _subject = v);
              if (_photo != null && !_busy) unawaited(_run());
            },
          ),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Une autre photo', onPressed: _busy ? null : _pick, icon: const Icon(Icons.add_photo_alternate_rounded)),
        ],
      ),
      body: photo == null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fact_check_rounded, size: 56),
                      const SizedBox(height: 12),
                      Text('Prends ta copie en photo, bien à plat', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      const Text(
                        'Nexo entoure chaque faute à sa place sur la feuille, avec la correction et la règle. '
                        'Envoie la photo depuis ton téléphone (page « Mon téléphone ») : elle s\'ouvre ici toute seule.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.image_rounded), label: const Text('Choisir la photo')),
                    ],
                  ),
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, c) => c.maxWidth > 900
                  ? Row(
                      children: [
                        Expanded(flex: 3, child: _sheet()),
                        SizedBox(width: 400, child: _details(theme)),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(flex: 3, child: _sheet()),
                        Expanded(flex: 2, child: _details(theme)),
                      ],
                    ),
            ),
    );
  }
}
