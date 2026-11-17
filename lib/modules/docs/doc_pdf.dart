import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'doc_format.dart';

/// Le document en PDF (A4), avec une vraie police (Arial sur Windows) pour
/// les accents et les symboles.
class DocPdf {
  DocPdf._();

  static Future<pw.ThemeData> _theme() async {
    final dirs = <String>[
      if (Platform.isWindows) '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts',
      '/usr/share/fonts/truetype/dejavu',
      '/System/Library/Fonts/Supplemental',
    ];
    const sets = [
      ['arial.ttf', 'arialbd.ttf', 'ariali.ttf', 'arialbi.ttf'],
      ['DejaVuSans.ttf', 'DejaVuSans-Bold.ttf', 'DejaVuSans-Oblique.ttf', 'DejaVuSans-BoldOblique.ttf'],
      ['Arial.ttf', 'Arial Bold.ttf', 'Arial Italic.ttf', 'Arial Bold Italic.ttf'],
    ];
    for (final d in dirs) {
      for (final set in sets) {
        final files = [for (final f in set) File('$d${Platform.pathSeparator}$f')];
        if (!files.first.existsSync()) continue;
        pw.Font load(File f) => pw.Font.ttf(ByteData.sublistView(
              (f.existsSync() ? f : files.first).readAsBytesSync(),
            ));
        return pw.ThemeData.withFont(
          base: load(files[0]),
          bold: load(files[1]),
          italic: load(files[2]),
          boldItalic: load(files[3]),
        );
      }
    }
    return pw.ThemeData.base();
  }

  static PdfColor? _color(Object? c) {
    if (c is! String) return null;
    var h = c.replaceFirst('#', '');
    if (h.length == 8) h = h.substring(2);
    if (h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : PdfColor.fromInt(0xFF000000 | v);
  }

  static const _sizes = {'small': 9.0, 'large': 14.0, 'huge': 20.0};

  static Future<Uint8List> build(List<dynamic> ops, {String title = ''}) async {
    final theme = await _theme();
    final doc = pw.Document(title: title, author: 'Mon Hub', theme: theme);
    final out = <pw.Widget>[];
    var n = 0;
    for (final l in DocFormat.lines(ops)) {
      final b = l.block;
      final h = (b['header'] as num?)?.toInt();
      final base = pw.TextStyle(
        fontSize: switch (h) {
          1 => 20,
          2 => 16,
          3 => 13,
          _ => 11,
        },
        fontWeight: h != null ? pw.FontWeight.bold : null,
        color: h != null ? PdfColor.fromHex('#2F5496') : null,
        lineSpacing: 2,
      );
      final spans = <pw.InlineSpan>[];
      final images = <pw.Widget>[];
      for (final r in l.runs) {
        final src = r.embed?['image'];
        if (src is String) {
          final m = RegExp(r'^data:image/[a-z+]+;base64,(.*)$', dotAll: true).firstMatch(src);
          if (m != null) {
            try {
              images.add(pw.Image(pw.MemoryImage(base64Decode(m.group(1)!.trim())), fit: pw.BoxFit.contain));
            } catch (_) {}
          }
          continue;
        }
        final a = r.attrs;
        final size = a['size'];
        spans.add(
          pw.TextSpan(
            text: r.text,
            style: pw.TextStyle(
              fontWeight: a['bold'] == true ? pw.FontWeight.bold : null,
              fontStyle: a['italic'] == true ? pw.FontStyle.italic : null,
              decoration: pw.TextDecoration.combine([
                if (a['underline'] == true || a['link'] != null) pw.TextDecoration.underline,
                if (a['strike'] == true) pw.TextDecoration.lineThrough,
              ]),
              color: _color(a['color']) ?? (a['link'] != null ? PdfColors.blue700 : null),
              background: _color(a['background']) == null ? null : pw.BoxDecoration(color: _color(a['background'])),
              fontSize: size is num ? size.toDouble() : (_sizes[size] ?? double.tryParse('$size')),
              font: a['code'] == true ? pw.Font.courier() : null,
            ),
          ),
        );
      }
      final align = switch (b['align']) {
        'center' => pw.TextAlign.center,
        'right' => pw.TextAlign.right,
        'justify' => pw.TextAlign.justify,
        _ => pw.TextAlign.left,
      };
      pw.Widget text = pw.RichText(
        text: pw.TextSpan(style: base, children: spans.isEmpty ? [const pw.TextSpan(text: ' ')] : spans),
        textAlign: align,
      );
      final list = b['list'];
      n = list == 'ordered' ? n + 1 : 0;
      final indent = ((b['indent'] as num?)?.toInt() ?? 0) * 18.0;
      if (list != null) {
        final mark = switch (list) {
          'ordered' => pw.Text('$n.', style: base),
          'checked' || 'unchecked' => pw.Container(
            width: 9,
            height: 9,
            margin: const pw.EdgeInsets.only(top: 2),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(width: 0.8),
              color: list == 'checked' ? PdfColors.grey700 : null,
            ),
          ),
          _ => pw.Container(
            width: 4,
            height: 4,
            margin: const pw.EdgeInsets.only(top: 5),
            decoration: const pw.BoxDecoration(shape: pw.BoxShape.circle, color: PdfColors.black),
          ),
        };
        text = pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 14 + indent),
            pw.SizedBox(width: 16, child: mark),
            pw.Expanded(child: text),
          ],
        );
      } else if (b['blockquote'] == true) {
        text = pw.Container(
          padding: const pw.EdgeInsets.only(left: 10),
          decoration: const pw.BoxDecoration(
            border: pw.Border(left: pw.BorderSide(color: PdfColors.grey500, width: 2)),
          ),
          child: text,
        );
      } else if (b['code-block'] == true) {
        text = pw.Container(color: PdfColors.grey200, padding: const pw.EdgeInsets.all(4), child: text);
      } else if (indent > 0) {
        text = pw.Padding(padding: pw.EdgeInsets.only(left: indent), child: text);
      }
      out.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(top: h != null ? 10 : 0, bottom: list != null ? 2 : 6),
          child: text,
        ),
      );
      for (final i in images) {
        out.add(pw.Padding(padding: const pw.EdgeInsets.only(bottom: 6), child: pw.ConstrainedBox(
          constraints: const pw.BoxConstraints(maxHeight: 400),
          child: i,
        )));
      }
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(2.5 * PdfPageFormat.cm),
        build: (_) => out,
        footer: (c) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        ),
      ),
    );
    return doc.save();
  }

}
