import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';

/// Un document joint à Nexo : il s'en sert pour tes prochaines questions
/// (cours en PDF, exercice en Word, tableau Excel, photo d'un livre…).
class ClickyDoc {
  ClickyDoc({required this.name, this.text = '', this.pdf64, this.image64, this.mime = 'image/png'});

  final String name;

  /// Texte extrait (vide pour une image).
  final String text;

  /// PDF complet (Claude le lit lui-même, mise en page comprise).
  final String? pdf64;

  /// Image jointe.
  final String? image64;
  final String mime;

  static const maxChars = 60000;

  String get kind => pdf64 != null
      ? 'PDF'
      : image64 != null
      ? 'image'
      : 'texte';

  /// Blocs de contenu pour Claude (Claude Pro ou clé API).
  List<Map<String, dynamic>> blocks() => [
    {'type': 'text', 'text': 'Document joint « $name » :'},
    if (pdf64 != null)
      {
        'type': 'document',
        'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': pdf64},
      }
    else if (image64 != null)
      {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': mime, 'data': image64},
      }
    else
      {'type': 'text', 'text': text},
  ];

  /// Version texte (Ollama).
  String asText() => image64 != null
      ? '(image « $name » jointe)'
      : 'Document « $name » :\n${text.isEmpty ? '(texte illisible)' : text}';

  static const types = [
    XTypeGroup(
      label: 'Documents',
      extensions: [
        'pdf',
        'docx',
        'xlsx',
        'pptx',
        'txt',
        'md',
        'csv',
        'json',
        'html',
        'htm',
        'xml',
        'rtf',
        'py',
        'js',
        'ts',
        'dart',
        'java',
        'c',
        'cpp',
        'cs',
        'lua',
        'css',
        'sql',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
      ],
    ),
  ];

  /// Demande un ou plusieurs fichiers et les lit.
  static Future<List<ClickyDoc>> pick() async {
    final files = await openFiles(acceptedTypeGroups: types);
    final out = <ClickyDoc>[];
    for (final f in files) {
      out.add(await read(f.name, await f.readAsBytes()));
    }
    return out;
  }

  static Future<ClickyDoc> fromPath(String path) async =>
      read(path.split(RegExp(r'[\\/]')).last, await File(path).readAsBytes());

  /// Lit un fichier d'après son extension.
  static Future<ClickyDoc> read(String name, List<int> bytes) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    String cap(String t) => t.length > maxChars ? '${t.substring(0, maxChars)}\n[… document coupé]' : t;
    switch (ext) {
      case 'png' || 'jpg' || 'jpeg' || 'webp' || 'gif':
        if (bytes.length > 5 * 1024 * 1024) throw 'Image trop lourde (5 Mo au plus) : $name';
        return ClickyDoc(
          name: name,
          image64: base64Encode(bytes),
          mime: switch (ext) {
            'jpg' || 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/png',
          },
        );
      case 'pdf':
        if (bytes.length > 25 * 1024 * 1024) throw 'PDF trop lourd (25 Mo au plus) : $name';
        return ClickyDoc(name: name, pdf64: base64Encode(bytes), text: cap(pdfText(bytes)));
      case 'docx':
        return ClickyDoc(name: name, text: cap(docxText(bytes)));
      case 'pptx':
        return ClickyDoc(name: name, text: cap(pptxText(bytes)));
      case 'xlsx':
        return ClickyDoc(name: name, text: cap(xlsxText(bytes)));
      case 'html' || 'htm':
        return ClickyDoc(name: name, text: cap(_xmlText(utf8.decode(bytes, allowMalformed: true))));
      default:
        return ClickyDoc(name: name, text: cap(utf8.decode(bytes, allowMalformed: true)));
    }
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  static String _xmlText(String xml) => _unescape(
    xml
        .replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</li>|</tr>|</h\d>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ''),
  ).replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n').trim();

  static Archive _zip(List<int> bytes) => ZipDecoder().decodeBytes(bytes);

  static String _entry(Archive a, String name) {
    final f = a.findFile(name);
    return f == null ? '' : utf8.decode(f.content, allowMalformed: true);
  }

  /// Word : paragraphes et tableaux (une ligne par rangée).
  static String docxText(List<int> bytes) {
    final xml = _entry(_zip(bytes), 'word/document.xml');
    final b = StringBuffer();
    for (final p in RegExp(r'<w:(p|tr)\b[\s\S]*?</w:\1>').allMatches(xml)) {
      final cells = p.group(1) == 'tr'
          ? [for (final c in RegExp(r'<w:tc\b[\s\S]*?</w:tc>').allMatches(p.group(0)!)) _runs(c.group(0)!)].join(' | ')
          : _runs(p.group(0)!);
      if (cells.trim().isNotEmpty) b.writeln(cells.trim());
    }
    return '$b'.trim();
  }

  static String _runs(String xml) => _unescape(
    [
      for (final t in RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:tab/>|<w:br/>').allMatches(xml))
        t.group(1) ?? (t.group(0) == '<w:tab/>' ? '\t' : '\n'),
    ].join(),
  );

  /// PowerPoint : texte de chaque diapositive.
  static String pptxText(List<int> bytes) {
    final a = _zip(bytes);
    final slides = [
      for (final f in a.files)
        if (RegExp(r'^ppt/slides/slide(\d+)\.xml$').hasMatch(f.name)) f.name,
    ]..sort((x, y) => _n(x).compareTo(_n(y)));
    return [
      for (final (i, s) in slides.indexed)
        'Diapo ${i + 1} : ${_unescape([for (final t in RegExp(r'<a:t>([^<]*)</a:t>').allMatches(_entry(a, s))) t.group(1)].join(' '))}',
    ].join('\n');
  }

  static int _n(String s) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(s)?.group(1) ?? '') ?? 0;

  /// Excel : cellules des feuilles (valeurs et formules), limité.
  static String xlsxText(List<int> bytes) {
    final a = _zip(bytes);
    final shared = [
      for (final si in RegExp(r'<si>([\s\S]*?)</si>').allMatches(_entry(a, 'xl/sharedStrings.xml')))
        _unescape([for (final t in RegExp(r'<t[^>]*>([^<]*)</t>').allMatches(si.group(1)!)) t.group(1)].join()),
    ];
    final sheets = [
      for (final f in a.files)
        if (RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').hasMatch(f.name)) f.name,
    ]..sort((x, y) => _n(x).compareTo(_n(y)));
    final b = StringBuffer();
    var cells = 0;
    for (final s in sheets) {
      b.writeln('Feuille ${_n(s)} :');
      for (final row in RegExp(r'<row\b[\s\S]*?</row>').allMatches(_entry(a, s))) {
        final vals = <String>[];
        for (final c in RegExp(r'<c\b([^>]*)>([\s\S]*?)</c>').allMatches(row.group(0)!)) {
          if (++cells > 4000) break;
          final attrs = c.group(1)!;
          final ref = RegExp(r'r="([A-Z]+\d+)"').firstMatch(attrs)?.group(1) ?? '';
          final f = RegExp(r'<f>([^<]*)</f>').firstMatch(c.group(2)!)?.group(1);
          var v =
              RegExp(r'<v>([^<]*)</v>').firstMatch(c.group(2)!)?.group(1) ??
              RegExp(r'<t[^>]*>([^<]*)</t>').firstMatch(c.group(2)!)?.group(1) ??
              '';
          if (attrs.contains('t="s"')) {
            final i = int.tryParse(v);
            v = i != null && i < shared.length ? shared[i] : v;
          }
          if (v.isEmpty && f == null) continue;
          vals.add('$ref=${_unescape(v)}${f == null ? '' : ' (formule =${_unescape(f)})'}');
        }
        if (vals.isNotEmpty) b.writeln(vals.join(' ; '));
      }
    }
    return '$b'.trim();
  }

  /// PDF : lecture simple du texte (pour Ollama ; Claude lit le PDF entier).
  static String pdfText(List<int> bytes) {
    final raw = latin1.decode(bytes, allowInvalid: true);
    final b = StringBuffer();
    for (final m in RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream').allMatches(raw)) {
      var content = m.group(1)!;
      try {
        content = latin1.decode(ZLibDecoder().decodeBytes(latin1.encode(content)), allowInvalid: true);
      } catch (_) {}
      for (final t in RegExp(r'\((?:[^()\\]|\\.)*\)\s*Tj|\[((?:[^\]])*)\]\s*TJ').allMatches(content)) {
        final s = t.group(0)!;
        for (final part in RegExp(r'\(((?:[^()\\]|\\.)*)\)').allMatches(s)) {
          b.write(
            part
                .group(1)!
                .replaceAllMapped(
                  RegExp(r'\\(.)'),
                  (x) => switch (x[1]) {
                    'n' => '\n',
                    't' => '\t',
                    _ => x[1]!,
                  },
                ),
          );
        }
        b.write(' ');
      }
      if (b.length > maxChars) break;
    }
    return '$b'.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }
}
