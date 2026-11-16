import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../widgets.dart';
import 'win.dart';

/// Capture de tes gestes (Windows) : clics, raccourcis, changements de
/// fenêtre, pour que Clicky raconte « ce que tu viens de faire » ou
/// t'explique comment refaire une manip. **Les lettres tapées ne sont
/// jamais gardées**, seulement « a tapé du texte (12 touches) ».
class WorkflowCapture extends ChangeNotifier {
  WorkflowCapture._();
  static final instance = WorkflowCapture._();

  static bool get supported => !kIsWeb && Platform.isWindows;

  Timer? _timer;
  final events = <String>[];
  DateTime? started;
  final _was = <int, bool>{};
  String _title = '';
  int _typing = 0;

  bool get on => _timer != null;

  void start() {
    if (!supported || on) return;
    events.clear();
    _was.clear();
    _typing = 0;
    _title = Win.foregroundTitle();
    started = DateTime.now();
    _add('Début dans « $_title »');
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) => _tick());
    notifyListeners();
  }

  /// Arrête et renvoie le déroulé.
  String stop() {
    _timer?.cancel();
    _timer = null;
    _flushTyping();
    notifyListeners();
    return summary;
  }

  String get summary => events.isEmpty ? '' : events.join('\n');

  void _add(String e) {
    final at = DateTime.now();
    events.add('${hhmm(at)}:${two(at.second)} $e');
    if (events.length > 400) events.removeAt(1);
  }

  void _flushTyping() {
    if (_typing > 0) _add('a tapé du texte ($_typing touches)');
    _typing = 0;
  }

  static const _names = {
    0x0D: 'Entrée',
    0x09: 'Tab',
    0x08: 'Retour arrière',
    0x2E: 'Suppr',
    0x1B: 'Échap',
    0x25: 'flèche gauche',
    0x26: 'flèche haut',
    0x27: 'flèche droite',
    0x28: 'flèche bas',
    0x21: 'Page précédente',
    0x22: 'Page suivante',
  };

  bool _pressed(int vk) {
    final d = Win.down(vk);
    final before = _was[vk] ?? false;
    _was[vk] = d;
    return d && !before;
  }

  void _tick() {
    try {
      final t = Win.foregroundTitle();
      if (t != _title && t.trim().isNotEmpty) {
        _flushTyping();
        _title = t;
        _add('passe à la fenêtre « $t »');
      }
      for (final (vk, name) in const [
        (0x01, 'clic'),
        (0x02, 'clic droit'),
        (0x04, 'clic molette'),
      ]) {
        if (_pressed(vk)) {
          _flushTyping();
          final p = Win.cursor();
          _add('$name en (${p?.$1}, ${p?.$2}) dans « $_title »');
        }
      }
      final ctrl = Win.down(0x11), alt = Win.down(0x12), win = Win.down(0x5B) || Win.down(0x5C);
      for (var vk = 0x08; vk <= 0x7B; vk++) {
        if (const {0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C}.contains(vk) || vk < 0x08) continue;
        if (!_pressed(vk)) continue;
        if ((ctrl || alt || win) && (vk >= 0x30 && vk <= 0x5A || vk >= 0x70)) {
          _flushTyping();
          final key = vk >= 0x70 ? 'F${vk - 0x6F}' : String.fromCharCode(vk);
          _add(
            'raccourci ${[if (ctrl) 'Ctrl', if (alt) 'Alt', if (win) 'Windows', key].join(' + ')}',
          );
        } else if (_names[vk] case final n?) {
          _flushTyping();
          _add('touche $n');
        } else if (vk >= 0x70 && vk <= 0x7B) {
          _flushTyping();
          _add('touche F${vk - 0x6F}');
        } else {
          _typing++;
        }
      }
    } catch (_) {}
  }
}

/// Enregistrement d'une leçon : chaque question, réponse et capture d'écran
/// va dans un dossier (Documents\Mon Hub\Leçons\…), avec un compte rendu
/// `lecon.md` à relire ou à imprimer.
class LessonRecorder extends ChangeNotifier {
  LessonRecorder._();
  static final instance = LessonRecorder._();

  Directory? _dir;
  int _n = 0;
  DateTime? started;

  bool get on => _dir != null;
  String? get folder => _dir?.path;

  Future<String?> start() async {
    if (on) return folder;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final name =
          'lecon_${now.year}-${two(now.month)}-${two(now.day)}_${two(now.hour)}-${two(now.minute)}';
      final sep = Platform.pathSeparator;
      final d = Directory('${docs.path}${sep}Mon Hub${sep}Leçons$sep$name');
      await d.create(recursive: true);
      _dir = d;
      _n = 0;
      started = now;
      await File('${d.path}${sep}lecon.md')
          .writeAsString('# Leçon du ${dayLabel(now).toLowerCase()} à ${hhmm(now)}\n\n');
      notifyListeners();
      return d.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> stop() async {
    final d = _dir;
    _dir = null;
    notifyListeners();
    if (d != null) {
      await _append(d, '\n---\nFin de la leçon à ${hhmm(DateTime.now())}.\n');
    }
    return d?.path;
  }

  Future<void> _append(Directory d, String s) async {
    try {
      await File('${d.path}${Platform.pathSeparator}lecon.md')
          .writeAsString(s, mode: FileMode.append);
    } catch (_) {}
  }

  /// Ajoute un échange (avec la première capture d'écran).
  Future<void> add(String question, String answer, {String? png64, String? board}) async {
    final d = _dir;
    if (d == null) return;
    _n++;
    final sep = Platform.pathSeparator;
    String? img;
    if (png64 != null) {
      img = 'capture-$_n.png';
      try {
        await File('${d.path}$sep$img').writeAsBytes(base64Decode(png64));
      } catch (_) {
        img = null;
      }
    }
    final at = DateTime.now();
    await _append(
      d,
      '## ${hhmm(at)} · $question\n\n'
      '${img == null ? '' : '![Écran]($img)\n\n'}'
      '$answer\n\n${board == null ? '' : '_Tableau : ${board}_\n\n'}',
    );
  }
}
