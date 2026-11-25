import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/game_agent.dart';
import 'package:hub/ui/clicky/game_input.dart';

void main() {
  group('Il comprend quand on lui demande d\'agir dans le jeu', () {
    test('avec un jeu au premier plan', () {
      for (final s in [
        'craft-moi une pioche',
        'Nexo, ouvre mon inventaire',
        'fabrique une table de craft',
        'mets le jour',
        'fais-moi une épée',
        'avance',
      ]) {
        expect(GameAgentRules.isRequest(s, gameInFront: true), isTrue, reason: s);
      }
    });

    test('sans jeu au premier plan : seulement si on parle du jeu', () {
      expect(GameAgentRules.isRequest('craft-moi une pioche'), isFalse);
      expect(GameAgentRules.isRequest('sur mc, craft-moi une pioche'), isTrue);
      expect(GameAgentRules.isRequest('dans minecraft fabrique des torches'), isTrue);
      expect(GameAgentRules.isRequest('joue à ma place'), isFalse);
    });

    test('une vraie question reste une question', () {
      expect(GameAgentRules.isRequest('comment on craft une pioche ?', gameInFront: true), isFalse);
      expect(GameAgentRules.isRequest('c\'est quoi la meilleure pioche', gameInFront: true), isFalse);
      expect(GameAgentRules.isRequest('ouvre Discord', gameInFront: true), isFalse);
      expect(GameAgentRules.isRequest('range mes téléchargements'), isFalse);
    });
  });

  group('Garde-fous', () {
    test('jamais dans un jeu en ligne avec anti-triche', () {
      for (final g in ['VALORANT', 'Fortnite', 'Counter-Strike 2', 'Roblox', 'League of Legends', 'Rocket League']) {
        expect(GameAgentRules.isBlocked(g), isTrue, reason: g);
      }
      expect(GameAgentRules.isBlocked('Minecraft'), isFalse);
      expect(GameAgentRules.isBlocked('Stardew Valley'), isFalse);
      expect(GameAgentRules.blockedText('Fortnite'), contains('banni'));
    });

    test('les réponses de Gemini sont bornées, et jamais de message dans le chat', () {
      final p = GameAgentRules.parse('''
Voilà : {"pense":"J'ouvre l'inventaire","actions":[
  {"type":"touche","touche":"e"},
  {"type":"clic","x":1400,"y":-20,"bouton":"droit","maj":true},
  {"type":"maintenir","touches":["avancer","courir"],"ms":99999},
  {"type":"commande","texte":"salut les gars"},
  {"type":"commande","texte":"/time set day"},
  {"type":"regarder","dx":9000}
]}''')!;
      expect(p.thought, 'J\'ouvre l\'inventaire');
      expect(p.actions, hasLength(4)); // 4 actions au plus
      final click = p.actions[1];
      expect(click.n('x'), 1000);
      expect(click.n('y'), 0);
      expect(click.right, isTrue);
      expect(click.b('maj'), isTrue);
      expect(click.describe, 'Maj + clic');
      expect(p.actions[2].n('ms'), 6000);
      expect(p.actions[2].describe, 'Je cours');
      // « salut les gars » (un message) est refusé : seule la commande « / » reste.
      expect(p.actions[3].type, 'commande');
      expect(p.actions[3].s('texte'), '/time set day');
      expect(GameAgentRules.parse('pas de json'), isNull);
      expect(
        GameAgentRules.parse('{"actions":[{"type":"fini","message":"Ta pioche est dans ton inventaire."}]}')!.done!
            .s('message'),
        startsWith('Ta pioche'),
      );
    });
  });

  group('Ce qu\'il sait du jeu', () {
    test('Minecraft : touches, inventaire et recettes', () {
      final g = GameAgentRules.guide(game: 'Minecraft', goal: 'craft-moi une pioche', azerty: true);
      expect(g, contains('PIOCHE = M M M en haut'));
      expect(g, contains('AZERTY'));
      expect(g, contains('« craft-moi une pioche »'));
      expect(GameAgentRules.playbook('Stardew Valley'), contains('Stardew Valley'));
    });

    test('les coordonnées de la capture vers l\'écran', () {
      expect(GameAgentRules.toScreen(500, 500, (100, 50, 1920, 1080)), (1060, 590));
      expect(GameAgentRules.toScreen(0, 1000, (0, 0, 1920, 1080)), (0, 1080));
      expect(GameAgentRules.shotSize(2560, 1440), (1280, 720));
      expect(GameAgentRules.shotSize(1024, 768), (1024, 768));
    });

    test('les touches physiques (même sur un clavier français)', () {
      expect(GameKeys.of('avancer'), (0x11, false)); // Z en AZERTY, W en QWERTY
      expect(GameKeys.of('espace'), (0x39, false));
      expect(GameKeys.of('Échap'), (0x01, false));
      expect(GameKeys.of('3'), (0x04, false)); // « " » / 3 : la case 3 de la barre
      expect(GameKeys.of('0'), (0x0B, false));
      expect(GameKeys.of('haut'), (0x48, true));
      expect(GameKeys.of('e'), isNull); // une lettre suit la langue du clavier (Windows)
    });

    test('hors de Windows : une phrase claire', () async {
      expect(await GameAgent.instance.run('craft-moi une pioche', key: 'k'), contains('PC'));
      expect(GameAgent.instance.active, isFalse);
    });
  });
}
