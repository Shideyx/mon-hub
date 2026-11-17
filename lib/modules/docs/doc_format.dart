import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

/// Un morceau de texte avec son style (gras, couleur…), ou une image.
class DocRun {
  DocRun(this.text, [Map<String, dynamic>? attrs, this.embed]) : attrs = attrs ?? {};
  final String text;
  final Map<String, dynamic> attrs;
  final Map<String, dynamic>? embed;
}

/// Une ligne (un paragraphe) : ses morceaux, et sa forme (titre, liste,
/// alignement…).
class DocLine {
  DocLine([List<DocRun>? runs, Map<String, dynamic>? block]) : runs = runs ?? [], block = block ?? {};
  final List<DocRun> runs;
  Map<String, dynamic> block;

  String get text => runs.map((r) => r.text).join();
}

/// Conversions du contenu des documents (format « Delta » de l'éditeur) :
/// texte de Clicky (Markdown), Word (.docx), texte brut.
class DocFormat {
  DocFormat._();

  static const _blockKeys = {'header', 'list', 'align', 'indent', 'blockquote', 'code-block', 'direction'};

  static List<DocLine> lines(List<dynamic> ops) {
    final out = <DocLine>[];
    var cur = DocLine();
    for (final op in ops) {
      if (op is! Map) continue;
      final ins = op['insert'];
      final attrs = ((op['attributes'] as Map?) ?? const {}).cast<String, dynamic>();
      if (ins is String) {
        final parts = ins.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) {
            cur.runs.add(DocRun(parts[i], {
              for (final e in attrs.entries)
                if (!_blockKeys.contains(e.key)) e.key: e.value,
            }));
          }
          if (i < parts.length - 1) {
            cur.block = {
              for (final e in attrs.entries)
                if (_blockKeys.contains(e.key)) e.key: e.value,
            };
            out.add(cur);
            cur = DocLine();
          }
        }
      } else if (ins is Map) {
        cur.runs.add(DocRun('', null, ins.cast<String, dynamic>()));
      }
    }
    if (cur.runs.isNotEmpty) out.add(cur);
    return out;
  }

  static List<Map<String, dynamic>> ops(List<DocLine> lines) {
    final out = <Map<String, dynamic>>[];
    void text(String t, Map<String, dynamic> a) {
      if (t.isEmpty) return;
      final last = out.lastOrNull;
      if (last != null &&
          last['insert'] is String &&
          !(last['insert'] as String).contains('\n') &&
          _same((last['attributes'] as Map?) ?? const {}, a)) {
        last['insert'] = '${last['insert']}$t';
        return;
      }
      out.add({'insert': t, if (a.isNotEmpty) 'attributes': {...a}});
    }

    for (final l in lines) {
      for (final r in l.runs) {
        if (r.embed != null) {
          out.add({'insert': r.embed});
        } else {
          text(r.text, r.attrs);
        }
      }
      out.add({'insert': '\n', if (l.block.isNotEmpty) 'attributes': {...l.block}});
    }
    if (out.isEmpty) out.add({'insert': '\n'});
    return out;
  }

  static bool _same(Map a, Map b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Texte brut.
  static String plain(List<dynamic> ops) => lines(ops).map((l) => l.text).join('\n').trim();

  static int words(List<dynamic> ops) =>
      RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’-]*", unicode: true).allMatches(plain(ops)).length;

  // ---------------------------------------------------------------- Markdown

  /// Le texte de Clicky (Markdown simple) en document.
  static List<Map<String, dynamic>> fromMarkdown(String md) {
    final out = <DocLine>[];
    var code = false;
    var blank = false;
    for (final raw in md.replaceAll('\r', '').split('\n')) {
      if (raw.trim().startsWith('```')) {
        code = !code;
        continue;
      }
      if (code) {
        out.add(DocLine([DocRun(raw)], {'code-block': true}));
        continue;
      }
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        blank = true;
        continue;
      }
      if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
        blank = true;
        continue;
      }
      Map<String, dynamic> block = {};
      var body = line;
      final indent = (RegExp(r'^\s*').firstMatch(line)!.group(0)!.replaceAll('\t', '  ').length ~/ 2).clamp(0, 6);
      RegExpMatch? m;
      if ((m = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line.trim())) != null) {
        block = {'header': m!.group(1)!.length.clamp(1, 3)};
        body = m.group(2)!;
      } else if ((m = RegExp(r'^\s*[-*+]\s+\[( |x|X)\]\s+(.*)$').firstMatch(line)) != null) {
        block = {'list': m!.group(1) == ' ' ? 'unchecked' : 'checked'};
        body = m.group(2)!;
      } else if ((m = RegExp(r'^\s*[-*+•]\s+(.*)$').firstMatch(line)) != null) {
        block = {'list': 'bullet'};
        body = m!.group(1)!;
      } else if ((m = RegExp(r'^\s*\d+[.)]\s+(.*)$').firstMatch(line)) != null) {
        block = {'list': 'ordered'};
        body = m!.group(1)!;
      } else if ((m = RegExp(r'^>\s?(.*)$').firstMatch(line.trim())) != null) {
        block = {'blockquote': true};
        body = m!.group(1)!;
      } else {
        body = line.trim();
      }
      if (block.containsKey('list') && indent > 0) block['indent'] = indent;
      // Une ligne vide entre deux paragraphes (pas entre les points d'une
      // liste) garde l'aération du texte.
      final prev = out.lastOrNull;
      if (blank && prev != null && !(prev.block.containsKey('list') && block.containsKey('list'))) {
        out.add(DocLine());
      }
      blank = false;
      out.add(DocLine(inline(body), block));
    }
    return ops(out);
  }

  static final _inline = RegExp(
    r'\[([^\]]+)\]\(([^)\s]+)\)|(\*\*\*|\*\*|__|~~|==|\*|_|`)(?=\S)(.+?)(?<=\S)\3',
  );

  /// Gras, italique, barré, code, liens du Markdown.
  static List<DocRun> inline(String s, [Map<String, dynamic> base = const {}]) {
    final out = <DocRun>[];
    var i = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start < i) continue;
      // « _ » au milieu d'un mot (nom_de_fichier) : ce n'est pas de l'italique.
      if (m.group(3) == '_' &&
          ((m.start > 0 && RegExp(r'\w').hasMatch(s[m.start - 1])) ||
              (m.end < s.length && RegExp(r'\w').hasMatch(s[m.end])))) {
        continue;
      }
      if (m.start > i) out.add(DocRun(s.substring(i, m.start), {...base}));
      if (m.group(1) != null) {
        out.addAll(inline(m.group(1)!, {...base, 'link': m.group(2)}));
      } else {
        final style = switch (m.group(3)) {
          '***' => {'bold': true, 'italic': true},
          '**' || '__' => {'bold': true},
          '~~' => {'strike': true},
          '==' => {'background': '#fff59d'},
          '`' => {'code': true},
          _ => {'italic': true},
        };
        if (m.group(3) == '`') {
          out.add(DocRun(m.group(4)!, {...base, ...style}));
        } else {
          out.addAll(inline(m.group(4)!, {...base, ...style}));
        }
      }
      i = m.end;
    }
    if (i < s.length) out.add(DocRun(s.substring(i), {...base}));
    return out;
  }

  /// Le document en Markdown (pour que Clicky le lise).
  static String toMarkdown(List<dynamic> ops) {
    final b = StringBuffer();
    var n = 0;
    var inCode = false;
    for (final l in lines(ops)) {
      final bl = l.block;
      if (bl['code-block'] == true) {
        if (!inCode) b.writeln('```');
        inCode = true;
        b.writeln(l.text);
        continue;
      }
      if (inCode) {
        b.writeln('```');
        inCode = false;
      }
      final list = bl['list'];
      n = list == 'ordered' ? n + 1 : 0;
      final pad = '  ' * ((bl['indent'] as num?)?.toInt() ?? 0);
      final prefix = switch (bl) {
        {'header': final num h} => '${'#' * h.toInt()} ',
        {'list': 'bullet'} => '$pad- ',
        {'list': 'ordered'} => '$pad$n. ',
        {'list': 'checked'} => '$pad- [x] ',
        {'list': 'unchecked'} => '$pad- [ ] ',
        {'blockquote': true} => '> ',
        _ => '',
      };
      final text = l.runs.map((r) {
        if (r.embed != null) return r.embed!.containsKey('image') ? '[image]' : '';
        var t = r.text;
        if (t.trim().isEmpty) return t;
        final a = r.attrs;
        if (a['code'] == true) t = '`$t`';
        if (a['bold'] == true) t = '**$t**';
        if (a['italic'] == true) t = '*$t*';
        if (a['strike'] == true) t = '~~$t~~';
        if (a['link'] is String) t = '[$t](${a['link']})';
        return t;
      }).join();
      b.writeln('$prefix$text');
    }
    if (inCode) b.writeln('```');
    return b.toString().trimRight();
  }

  // -------------------------------------------------------------------- Word

  static String _x(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static const _sizes = {'small': 9, 'large': 14, 'huge': 20};

  static const _w =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';

  /// Le document en fichier Word (.docx), lisible par Word, Google Docs,
  /// LibreOffice.
  static Uint8List toDocx(List<dynamic> ops, {String title = ''}) {
    final rels = <String>[];
    final media = <String, Uint8List>{};
    var relId = 10;
    var picId = 1;
    String rel(String type, String target, {bool external = false}) {
      final id = 'rId${relId++}';
      rels.add(
        '<Relationship Id="$id" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/$type" '
        'Target="${_x(target)}"${external ? ' TargetMode="External"' : ''}/>',
      );
      return id;
    }

    String runXml(DocRun r) {
      final a = r.attrs;
      final p = StringBuffer();
      final font = a['font'];
      if (font is String && font.isNotEmpty) {
        p.write('<w:rFonts w:ascii="${_x(font)}" w:hAnsi="${_x(font)}" w:cs="${_x(font)}"/>');
      }
      if (a['bold'] == true) p.write('<w:b/>');
      if (a['italic'] == true) p.write('<w:i/>');
      if (a['strike'] == true) p.write('<w:strike/>');
      if (a['color'] is String) p.write('<w:color w:val="${_hex(a['color'] as String)}"/>');
      final size = a['size'];
      final pt = size is num ? size.toDouble() : (_sizes[size] ?? double.tryParse('$size'))?.toDouble();
      if (pt != null) p.write('<w:sz w:val="${(pt * 2).round()}"/>');
      if (a['underline'] == true || a['link'] != null) p.write('<w:u w:val="single"/>');
      if (a['background'] is String) {
        p.write('<w:shd w:val="clear" w:color="auto" w:fill="${_hex(a['background'] as String)}"/>');
      }
      if (a['script'] == 'super') p.write('<w:vertAlign w:val="superscript"/>');
      if (a['script'] == 'sub') p.write('<w:vertAlign w:val="subscript"/>');
      if (a['code'] == true) p.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>');
      final parts = r.text.split('\t');
      final body = [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) '<w:tab/>',
          if (parts[i].isNotEmpty) '<w:t xml:space="preserve">${_x(parts[i])}</w:t>',
        ],
      ].join();
      final run = '<w:r>${p.isEmpty ? '' : '<w:rPr>$p</w:rPr>'}$body</w:r>';
      final link = a['link'];
      if (link is String && link.isNotEmpty) {
        return '<w:hyperlink r:id="${rel('hyperlink', link, external: true)}">$run</w:hyperlink>';
      }
      return run;
    }

    String imageXml(String src) {
      final bytes = _imageBytes(src);
      if (bytes == null) return '';
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return '';
      final png = Uint8List.fromList(img.encodePng(decoded));
      final name = 'image$picId.png';
      media['word/media/$name'] = png;
      final id = rel('image', 'media/$name');
      // 6 pouces de large au plus.
      const maxW = 5486400;
      var cx = decoded.width * 9525;
      var cy = decoded.height * 9525;
      if (cx > maxW) {
        cy = (cy * maxW / cx).round();
        cx = maxW;
      }
      final n = picId++;
      return '<w:r><w:drawing><wp:inline><wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$n" name="Image $n"/>'
          '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
          '<pic:pic><pic:nvPicPr><pic:cNvPr id="$n" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
          '<pic:blipFill><a:blip r:embed="$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
          '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
          '</wp:inline></w:drawing></w:r>';
    }

    final body = StringBuffer();
    for (final l in lines(ops)) {
      final bl = l.block;
      final pPr = StringBuffer();
      final h = bl['header'];
      if (h is num) pPr.write('<w:pStyle w:val="Heading${h.toInt()}"/>');
      if (bl['blockquote'] == true) pPr.write('<w:pStyle w:val="Quote"/>');
      if (bl['code-block'] == true) pPr.write('<w:pStyle w:val="Code"/>');
      final list = bl['list'];
      final indent = (bl['indent'] as num?)?.toInt() ?? 0;
      if (list == 'bullet' || list == 'ordered') {
        pPr.write('<w:numPr><w:ilvl w:val="${indent.clamp(0, 8)}"/><w:numId w:val="${list == 'bullet' ? 1 : 2}"/></w:numPr>');
      } else if (indent > 0) {
        pPr.write('<w:ind w:left="${indent * 720}"/>');
      }
      final align = bl['align'];
      if (align is String) pPr.write('<w:jc w:val="${align == 'justify' ? 'both' : align}"/>');
      final runs = StringBuffer();
      if (list == 'checked' || list == 'unchecked') {
        runs.write(runXml(DocRun(list == 'checked' ? '☑ ' : '☐ ')));
      }
      for (final r in l.runs) {
        final src = r.embed?['image'];
        runs.write(src is String ? imageXml(src) : runXml(r));
      }
      body.write('<w:p>${pPr.isEmpty ? '' : '<w:pPr>$pPr</w:pPr>'}$runs</w:p>');
    }

    final document =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document $_w><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417" w:header="708" w:footer="708" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>';

    final docRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
        '${rels.join()}</Relationships>';

    final archive = Archive();
    void add(String name, List<int> data) => archive.add(ArchiveFile.bytes(name, data));
    add('[Content_Types].xml', utf8.encode(_contentTypes));
    add('_rels/.rels', utf8.encode(_rootRels));
    add('docProps/core.xml', utf8.encode(_core(title)));
    add('word/document.xml', utf8.encode(document));
    add('word/styles.xml', utf8.encode(_styles));
    add('word/numbering.xml', utf8.encode(_numbering));
    add('word/_rels/document.xml.rels', utf8.encode(docRels));
    for (final e in media.entries) {
      add(e.key, e.value);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String _hex(String c) {
    var h = c.replaceFirst('#', '').toUpperCase();
    if (h.length == 8) h = h.substring(2);
    if (h.length == 3) h = h.split('').map((x) => '$x$x').join();
    return RegExp(r'^[0-9A-F]{6}$').hasMatch(h) ? h : '000000';
  }

  /// Les octets d'une image du document (data:…;base64,…).
  static Uint8List? _imageBytes(String src) {
    final m = RegExp(r'^data:image/[a-z+]+;base64,(.*)$', dotAll: true).firstMatch(src);
    if (m == null) return null;
    try {
      return base64Decode(m.group(1)!.trim());
    } catch (_) {
      return null;
    }
  }

  static const _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '</Types>';

  static const _rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '</Relationships>';

  static String _core(String title) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>${_x(title)}</dc:title><dc:creator>Mon Hub</dc:creator></cp:coreProperties>';

  static String _heading(int n, int size, String color) =>
      '<w:style w:type="paragraph" w:styleId="Heading$n"><w:name w:val="heading $n"/><w:basedOn w:val="Normal"/>'
      '<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="${n == 1 ? 360 : 240}" w:after="120"/>'
      '<w:outlineLvl w:val="${n - 1}"/></w:pPr><w:rPr><w:b/><w:color w:val="$color"/><w:sz w:val="$size"/></w:rPr></w:style>';

  static final _styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
      '<w:sz w:val="22"/><w:lang w:val="fr-FR"/></w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
      '${_heading(1, 36, '2F5496')}${_heading(2, 28, '2F5496')}${_heading(3, 24, '1F3763')}'
      '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:ind w:left="720"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="A5A5A5"/></w:pBdr></w:pPr>'
      '<w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:after="0"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/></w:rPr></w:style>'
      '</w:styles>';

  static String _levels(bool bullet) => [
    for (var i = 0; i < 9; i++)
      '<w:lvl w:ilvl="$i"><w:start w:val="1"/><w:numFmt w:val="${bullet ? 'bullet' : (i.isOdd ? 'lowerLetter' : 'decimal')}"/>'
          '<w:lvlText w:val="${bullet ? ['•', '◦', '▪'][i % 3] : '%${i + 1}.'}"/><w:lvlJc w:val="left"/>'
          '<w:pPr><w:ind w:left="${720 + i * 360}" w:hanging="360"/></w:pPr></w:lvl>',
  ].join();

  static final _numbering =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:abstractNum w:abstractNumId="0">${_levels(true)}</w:abstractNum>'
      '<w:abstractNum w:abstractNumId="1">${_levels(false)}</w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
      '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
      '</w:numbering>';

  /// Lit un fichier Word (.docx) : texte, gras/italique/souligné, couleurs,
  /// tailles, titres, listes, alignement, liens, images, tableaux (en
  /// lignes).
  static List<Map<String, dynamic>> fromDocx(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    String? read(String name) {
      final f = zip.findFile(name);
      return f == null ? null : utf8.decode(f.content, allowMalformed: true);
    }

    final docXml = read('word/document.xml');
    if (docXml == null) throw 'Ce fichier n\'est pas un document Word (.docx)';
    final rels = <String, String>{};
    final relXml = read('word/_rels/document.xml.rels');
    if (relXml != null) {
      for (final r in XmlDocument.parse(relXml).findAllElements('Relationship')) {
        rels[r.getAttribute('Id') ?? ''] = r.getAttribute('Target') ?? '';
      }
    }
    // Listes à puces ou numérotées (d'après numbering.xml).
    final bulletNums = <String>{};
    final numXml = read('word/numbering.xml');
    if (numXml != null) {
      final n = XmlDocument.parse(numXml);
      final abstractBullet = <String>{
        for (final a in n.findAllElements('w:abstractNum'))
          if (a.findAllElements('w:numFmt').firstOrNull?.getAttribute('w:val') == 'bullet')
            a.getAttribute('w:abstractNumId') ?? '',
      };
      for (final num in n.findAllElements('w:num')) {
        final abs = num.findElements('w:abstractNumId').firstOrNull?.getAttribute('w:val');
        if (abstractBullet.contains(abs)) bulletNums.add(num.getAttribute('w:numId') ?? '');
      }
    }
    // Titres : styles « Heading1 », « Titre1 », « Title »… (par leur nom).
    final headingOf = <String, int>{};
    final stylesXml = read('word/styles.xml');
    if (stylesXml != null) {
      for (final s in XmlDocument.parse(stylesXml).findAllElements('w:style')) {
        final id = s.getAttribute('w:styleId') ?? '';
        final name = (s.findElements('w:name').firstOrNull?.getAttribute('w:val') ?? id).toLowerCase();
        final m = RegExp(r'(?:heading|titre)\s*(\d)').firstMatch(name);
        if (m != null) headingOf[id] = int.parse(m.group(1)!).clamp(1, 3);
        if (name == 'title' || name == 'titre') headingOf[id] = 1;
        if (name == 'subtitle' || name == 'sous-titre') headingOf[id] = 2;
      }
    }

    final out = <DocLine>[];
    void para(XmlElement p) {
      final line = DocLine();
      final pPr = p.findElements('w:pPr').firstOrNull;
      if (pPr != null) {
        final style = pPr.findElements('w:pStyle').firstOrNull?.getAttribute('w:val');
        final h = headingOf[style] ?? (style == null ? null : int.tryParse(RegExp(r'^Heading(\d)$').firstMatch(style)?.group(1) ?? ''));
        if (h != null) line.block['header'] = h.clamp(1, 3);
        final numPr = pPr.findElements('w:numPr').firstOrNull;
        if (numPr != null) {
          final id = numPr.findElements('w:numId').firstOrNull?.getAttribute('w:val') ?? '';
          if (id != '0') {
            line.block['list'] = bulletNums.contains(id) ? 'bullet' : 'ordered';
            final lvl = int.tryParse(numPr.findElements('w:ilvl').firstOrNull?.getAttribute('w:val') ?? '') ?? 0;
            if (lvl > 0) line.block['indent'] = lvl;
          }
        }
        final jc = pPr.findElements('w:jc').firstOrNull?.getAttribute('w:val');
        if (jc == 'center' || jc == 'right') line.block['align'] = jc;
        if (jc == 'both' || jc == 'distribute') line.block['align'] = 'justify';
      }

      void run(XmlElement r, Map<String, dynamic> base) {
        final a = <String, dynamic>{...base};
        final rPr = r.findElements('w:rPr').firstOrNull;
        if (rPr != null) {
          bool on(String tag) {
            final e = rPr.findElements(tag).firstOrNull;
            if (e == null) return false;
            final v = e.getAttribute('w:val');
            return v == null || (v != '0' && v != 'false' && v != 'none');
          }

          if (on('w:b')) a['bold'] = true;
          if (on('w:i')) a['italic'] = true;
          if (on('w:u')) a['underline'] = true;
          if (on('w:strike')) a['strike'] = true;
          final color = rPr.findElements('w:color').firstOrNull?.getAttribute('w:val');
          if (color != null && color != 'auto' && color != '000000') a['color'] = '#${color.toLowerCase()}';
          final sz = int.tryParse(rPr.findElements('w:sz').firstOrNull?.getAttribute('w:val') ?? '');
          if (sz != null && sz != 22 && sz != 24) a['size'] = '${(sz / 2).round()}';
          final hl = rPr.findElements('w:highlight').firstOrNull?.getAttribute('w:val');
          if (hl == 'yellow') a['background'] = '#fff59d';
          final shd = rPr.findElements('w:shd').firstOrNull?.getAttribute('w:fill');
          if (shd != null && shd != 'auto' && shd.toUpperCase() != 'FFFFFF') a['background'] = '#${shd.toLowerCase()}';
          final va = rPr.findElements('w:vertAlign').firstOrNull?.getAttribute('w:val');
          if (va == 'superscript') a['script'] = 'super';
          if (va == 'subscript') a['script'] = 'sub';
        }
        for (final c in r.childElements) {
          switch (c.name.qualified) {
            case 'w:t':
              line.runs.add(DocRun(c.innerText, {...a}));
            case 'w:tab':
              line.runs.add(DocRun('\t', {...a}));
            case 'w:br' || 'w:cr':
              line.runs.add(DocRun(' ', {...a}));
            case 'w:drawing' || 'w:pict':
              final blip = c.findAllElements('a:blip').firstOrNull?.getAttribute('r:embed') ??
                  c.findAllElements('v:imagedata').firstOrNull?.getAttribute('r:id');
              final target = rels[blip];
              if (target != null) {
                final path = target.startsWith('/') ? target.substring(1) : 'word/$target';
                final f = zip.findFile(path);
                if (f != null) {
                  final data = Uint8List.fromList(f.content);
                  final mime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
                  line.runs.add(DocRun('', null, {'image': 'data:$mime;base64,${base64Encode(data)}'}));
                }
              }
          }
        }
      }

      for (final c in p.childElements) {
        if (c.name.qualified == 'w:r') run(c, const {});
        if (c.name.qualified == 'w:hyperlink') {
          final target = rels[c.getAttribute('r:id')];
          for (final r in c.findElements('w:r')) {
            run(r, {'link': ?target});
          }
        }
        if (c.name.qualified == 'w:ins' || c.name.qualified == 'w:smartTag') {
          for (final r in c.findElements('w:r')) {
            run(r, const {});
          }
        }
      }
      out.add(line);
    }

    final body = XmlDocument.parse(docXml).findAllElements('w:body').firstOrNull;
    if (body == null) return ops(const []);
    for (final e in body.childElements) {
      if (e.name.qualified == 'w:p') para(e);
      if (e.name.qualified == 'w:tbl') {
        // Un tableau : chaque ligne devient « case | case | case ».
        for (final tr in e.findElements('w:tr')) {
          final cells = [
            for (final tc in tr.findElements('w:tc'))
              tc.findAllElements('w:t').map((t) => t.innerText).join(' ').trim(),
          ];
          out.add(DocLine([DocRun(cells.join('  |  '))]));
        }
      }
    }
    // Les paragraphes vides en fin de document ne servent à rien.
    while (out.length > 1 && out.last.runs.isEmpty) {
      out.removeLast();
    }
    return ops(out);
  }
}
