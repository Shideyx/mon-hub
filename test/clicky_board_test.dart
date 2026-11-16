import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/board.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/ears.dart';
import 'package:material_ui/material_ui.dart';

const sample = '''Regarde le schéma, c'est un cycle. [TABLEAU]
{"titre":"Le cycle de l'eau","blocs":[
 {"type":"schema","forme":"cycle","noeuds":["Mer","Nuages","Pluie","Rivière"],
  "liens":[[0,1,"évaporation"],[1,2,"condensation"],[2,3,"ruissellement"],[3,0,""]]},
 {"type":"etapes","items":[{"titre":"Évaporation","texte":"Le soleil chauffe l'eau."},"La vapeur monte"]},
 {"type":"comparaison","colonnes":["","Solide","Liquide"],"lignes":[["Exemple","glace","eau"]]},
 {"type":"frise","items":[{"date":"1789","texte":"Révolution"}]},
 {"type":"graphique","titre":"Pluie","unite":"mm","valeurs":[{"label":"Jan","valeur":80},{"label":"Fév","valeur":"40.5"}]},
 {"type":"formule","formule":"v = d ÷ t","legende":[{"terme":"v","sens":"vitesse"}]},
 {"type":"vocabulaire","items":[{"mot":"rain","sens":"pluie"}]},
 {"type":"retenir","items":["L'eau tourne en rond"]},
 {"type":"exemple","titre":"Exemple","texte":"Une flaque sèche au soleil."},
 {"type":"quiz","question":"D'où vient la pluie ?","choix":["Des nuages","Du sol"],"reponse":0,"explication":"La vapeur se condense."}
]}
[/TABLEAU] [POINT:none]''';

void main() {
  test('Clicky sépare la réponse orale et le tableau', () {
    final (text, board) = ClickyBoard.extract(sample);
    expect(text, 'Regarde le schéma, c\'est un cycle. [POINT:none]');
    expect(board, isNotNull);
    expect(board!.title, 'Le cycle de l\'eau');
    expect(board.blocks.length, 10);
    expect(board.hasQuiz, isTrue);
    expect(ClickyController.parsePoint(text).$1, 'Regarde le schéma, c\'est un cycle.');
  });

  test('tableau à moitié écrit : caché, et signalé', () {
    const partial = 'Regarde ! [TABLEAU]{"titre":"Les fra';
    expect(ClickyBoard.writing(partial), isTrue);
    expect(ClickyBoard.strip(partial), 'Regarde !');
    expect(ClickyBoard.writing(sample), isFalse);
  });

  test('tableau illisible ou entouré de ```json', () {
    expect(ClickyBoard.extract('Oups [TABLEAU]pas du json[/TABLEAU]').$2, isNull);
    final b = ClickyBoard.parse('```json\n{"blocs":[{"type":"texte","texte":"ok"}]}\n```');
    expect(b?.blocks.single.s('texte'), 'ok');
  });

  test('schéma : étages, liens par nom, et enchaînement par défaut', () {
    final g = SchemaGraph.from(
      const BoardBlock('schema', {
        'noeuds': ['Soleil', 'Feuille', 'Sucre', 'Oxygène'],
        'liens': [
          ['Soleil', 'Feuille', 'lumière'],
          [1, 2, ''],
          [1, 3, ''],
        ],
      }),
    );
    expect(g.layers(), [0, 1, 2, 2]);
    expect(g.edges.first.$3, 'lumière');

    final chain = SchemaGraph.from(
      const BoardBlock('schema', {
        'forme': 'cycle',
        'noeuds': ['A', 'B', 'C'],
      }),
    );
    expect(chain.cycle, isTrue);
    expect(chain.edges.length, 3);
    // Une boucle ne fait pas planter le calcul des étages.
    expect(chain.layers(), [0, 1, 2]);
  });

  test('micro Windows : erreurs expliquées avec le bon réglage', () {
    expect(windowsProblem('0x80045509', '').fixUri, 'ms-settings:privacy-speech');
    expect(windowsProblem('0x80070005', '').fixUri, 'ms-settings:privacy-microphone');
    expect(windowsProblem('MicrophoneUnavailable', '').fixUri, 'ms-settings:sound');
    expect(windowsProblem('TopicLanguageNotSupported', '').fixUri, 'ms-settings:regionlanguage');
    expect(windowsProblem('0x1234', 'bizarre').message, contains('Win + H'));
  });

  test('script de reconnaissance vocale Windows', () {
    const s = WindowsEars.windowsScript;
    expect(s, contains('Windows.Media.SpeechRecognition.SpeechRecognizer'));
    expect(s, contains('SpeechRecognitionScenario]::Dictation'));
    expect(s, contains('ContinuousRecognitionSession'));
    expect(s, contains("'fr-FR'"));
    // Aucun caractère accentué : le fichier est lu sans souci d'encodage.
    expect(s.runes.every((r) => r < 128), isTrue);
  });

  testWidgets('le tableau se dessine sans erreur', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final board = ClickyBoard.extract(sample).$2!;
    String? asked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              child: RepaintBoundary(
                key: const ValueKey('board'),
                child: ClickyBoardView(board: board, onClose: () {}, onAsk: (q) => asked = q),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Le cycle de l\'eau'), findsOneWidget);
    expect(find.text('Mer'), findsOneWidget);
    await tester.ensureVisible(find.text('Des nuages'));
    await tester.tap(find.text('Des nuages'));
    await tester.pump();
    expect(find.text('Bravo, c\'est juste !'), findsOneWidget);
    await tester.tap(find.text('Teste-moi'));
    expect(asked, contains('quiz'));
  });
}
