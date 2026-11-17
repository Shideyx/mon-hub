import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/modules/docs/doc_format.dart';
import 'package:hub/modules/docs/doc_pdf.dart';

void main() {
  const md = '''# Exposé sur la photosynthèse

*Léa — 1re*

## Introduction
La **photosynthèse** permet aux plantes de fabriquer du _glucose_ avec la [lumière](https://fr.wikipedia.org/wiki/Photosynth%C3%A8se).

- Chlorophylle
  - dans les chloroplastes
- Eau et CO₂

1. Absorption
2. Transformation

- [ ] relire
- [x] plan

> Citation importante
''';

  test('Markdown → document → Markdown', () {
    final ops = DocFormat.fromMarkdown(md);
    final lines = DocFormat.lines(ops);
    expect(lines.first.block, {'header': 1});
    expect(lines.first.text, 'Exposé sur la photosynthèse');
    final intro = lines.firstWhere((l) => l.text.startsWith('La '));
    expect(intro.runs.firstWhere((r) => r.text == 'photosynthèse').attrs, {'bold': true});
    expect(intro.runs.firstWhere((r) => r.text == 'glucose').attrs, {'italic': true});
    expect(intro.runs.firstWhere((r) => r.text == 'lumière').attrs['link'], startsWith('https://'));
    expect(lines.firstWhere((l) => l.text == 'dans les chloroplastes').block, {'list': 'bullet', 'indent': 1});
    expect(lines.firstWhere((l) => l.text == 'Absorption').block, {'list': 'ordered'});
    expect(lines.firstWhere((l) => l.text == 'plan').block, {'list': 'checked'});
    expect(lines.firstWhere((l) => l.text == 'Citation importante').block, {'blockquote': true});
    final back = DocFormat.toMarkdown(ops);
    expect(back, contains('# Exposé sur la photosynthèse'));
    expect(back, contains('**photosynthèse**'));
    expect(back, contains('[lumière](https://'));
    expect(back, contains('  - dans les chloroplastes'));
    expect(back, contains('2. Transformation'));
    expect(back, contains('- [x] plan'));
    expect(DocFormat.words(ops), greaterThan(20));
    // Un nom_de_fichier n'est pas de l'italique.
    expect(DocFormat.inline('mon_fichier_final').single.attrs, isEmpty);
  });

  test('Word (.docx) : écrit puis relu, sans rien perdre d\'important', () {
    final ops = DocFormat.fromMarkdown(md);
    final docx = DocFormat.toDocx(ops, title: 'Exposé');
    final dir = Directory.systemTemp.createTempSync('docx');
    File('${dir.path}/expose.docx').writeAsBytesSync(docx);
    final again = DocFormat.lines(DocFormat.fromDocx(docx));
    expect(again.first.block['header'], 1);
    expect(again.first.text, 'Exposé sur la photosynthèse');
    final intro = again.firstWhere((l) => l.text.startsWith('La '));
    expect(intro.runs.firstWhere((r) => r.text == 'photosynthèse').attrs['bold'], true);
    expect(intro.runs.firstWhere((r) => r.text == 'lumière').attrs['link'], startsWith('https://fr.wikipedia.org'));
    expect(again.firstWhere((l) => l.text == 'Chlorophylle').block['list'], 'bullet');
    expect(again.firstWhere((l) => l.text == 'dans les chloroplastes').block['indent'], 1);
    expect(again.firstWhere((l) => l.text == 'Absorption').block['list'], 'ordered');
    expect(again.any((l) => l.text == '☑ plan'), isTrue);
    expect(() => DocFormat.fromDocx(DocFormat.toDocx([{'insert': '\n'}]).sublist(0, 10)), throwsA(anything));
  });

  test('PDF : fabriqué avec une vraie police (accents)', () async {
    final pdf = await DocPdf.build(DocFormat.fromMarkdown(md), title: 'Exposé');
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    File('${Directory.systemTemp.path}/expose_test.pdf').writeAsBytesSync(pdf);
  });
}
