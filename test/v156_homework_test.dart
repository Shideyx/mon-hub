import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/clicky.dart';
import 'package:hub/ui/clicky/hud.dart';

void main() {
  test('Smily fait les devoirs quand on le lui demande (plus de refus)', () {
    final p = clickyPersona('Léa');
    expect(p, isNot(contains('sans faire le travail')));
    expect(p, contains('tu les fais vraiment, en entier'));
    final rules = ClickyController.homeworkRules(false);
    expect(rules, contains('FAIS-LE vraiment et en entier'));
    expect(rules, contains('ne refuse pas'));
    expect(rules, contains('mode=enonce'));
    expect(rules, contains('doc_creer'));
  });

  test('« Aider sans faire à ma place » (réglage) : il guide seulement', () {
    expect(clickyPersona('Léa', helpOnly: true), contains('tu guides sans faire le travail'));
    expect(ClickyController.homeworkRules(true), contains('ne donne pas la réponse complète'));
  });

  test('« fais mes devoirs » reconnu (matière, jour)', () {
    expect(ClickyController.homeworkRequest('Smily, fais mes devoirs'), (null, null));
    expect(ClickyController.homeworkRequest('fais mon devoir de maths'), ('maths', null));
    expect(ClickyController.homeworkRequest('Fais-moi mon DM de physique pour lundi'), ('physique', 'lundi'));
    expect(ClickyController.homeworkRequest('fais mes exercices d\'anglais pour demain stp'), ('anglais', 'demain'));
    expect(ClickyController.homeworkRequest('termine ma rédaction de français'), ('francais', null));
    expect(ClickyController.homeworkRequest('fais cet exercice'), isNull); // à l'écran : réponse normale
    expect(ClickyController.homeworkRequest('comment je fais mes devoirs plus vite'), isNull);
    final t = ClickyController.homeworkTask('maths', 'lundi', request: 'fais mon DM de maths pour lundi');
    expect(t, startsWith('La demande : « fais mon DM de maths pour lundi ».'));
    expect(t, contains('mon devoir de maths (pour lundi)'));
    expect(t, contains('ecole_fichier_lire avec mode=enonce'));
    expect(t, contains('Google Doc'));
  });
}
