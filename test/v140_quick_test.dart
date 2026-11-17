import 'package:flutter_test/flutter_test.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  // Mardi 17 novembre 2026, 18 h 05.
  final now = DateTime(2026, 11, 17, 18, 5);
  final calls = <String>[];

  Future<Object?> fake(String name, Map<String, dynamic> args) async {
    calls.add('$name ${args.isEmpty ? '' : args}'.trim());
    switch (name) {
      case 'ecole_devoirs':
        return [
          {'pour_le': DateTime(2026, 11, 18), 'matiere': 'Mathématiques', 'contenu': 'Exercices 3 et 4 page 52', 'fait': false},
          {'pour_le': DateTime(2026, 11, 18), 'matiere': 'Anglais', 'contenu': 'Apprendre le vocabulaire', 'fait': true},
          {'pour_le': DateTime(2026, 11, 19), 'matiere': 'SVT', 'contenu': 'Chapitre 3 : la génétique', 'fait': false, 'controle': true},
        ];
      case 'agenda_lire':
        return [
          {'titre': 'Mathématiques', 'debut': DateTime(2026, 11, 18, 8), 'fin': DateTime(2026, 11, 18, 9), 'lieu': 'B12'},
          {'titre': 'Anglais', 'debut': DateTime(2026, 11, 18, 9), 'fin': DateTime(2026, 11, 18, 10)},
          {'titre': 'Sport', 'debut': DateTime(2026, 11, 18, 14), 'fin': DateTime(2026, 11, 18, 16)},
        ];
      case 'ecole_notes':
        return [
          {'matiere': 'Physique', 'note': '15/20'},
          {'matiere': 'Français', 'note': '12/20'},
        ];
      case 'carnet_meteo':
        return {'ville': 'Lyon', 'maintenant': '9 °C, nuageux', 'icone': '☁️', 'min': 6, 'max': 12, 'pluie_pourcent': 30, 'tenue': 'Prends une veste.'};
      case 'musique_en_cours':
        return {'titre': 'Blinding Lights', 'artiste': 'The Weeknd'};
      case 'pc_ranger_apercu':
        return {'fichiers': 12};
      case 'pc_ranger':
        return {'ranges': 12};
      case 'revision_paquets':
        return {'a_revoir_aujourdhui': 8, 'serie_jours': 4};
    }
    return {'ok': true};
  }

  const tools = {
    'ecole_devoirs', 'agenda_lire', 'ecole_notes', 'carnet_meteo', 'musique_commande', 'musique_en_cours',
    'pc_ranger', 'pc_ranger_apercu', 'pc_ranger_annuler', 'youtube_lire', 'doc_nouveau', 'carnet_taches_notes',
    'pc_ouvrir', 'revision_lancer', 'revision_paquets',
  };

  Future<String?> ask(String q) async => (await QuickAnswers.answer(q, call: fake, tools: tools, now: now))?.text;

  test('heure, date, politesse', () async {
    expect(await ask('Quelle heure est-il ?'), 'Il est 18 h 05.');
    expect(await ask('Clicky, on est quel jour aujourd\'hui ?'), 'Nous sommes mardi 17 novembre 2026.');
    expect(await ask('merci !'), 'Avec plaisir !');
  });

  test('calculs', () async {
    expect(await ask('combien font 12 fois 7'), 'Ça fait 84.');
    expect(await ask('(3+4)*2'), 'Ça fait 14.');
    expect(await ask('15 % de 80'), '15 % de 80, ça fait 12.');
    expect(await ask('racine carrée de 144'), 'Ça fait 12.');
    expect(await ask('calcule 10 divisé par 4'), 'Ça fait 2,5.');
    expect(await ask('2 puissance 10'), 'Ça fait 1024.');
    expect(Calc.fromSentence('12/11'), isNull); // une date
    expect(Calc.fromSentence('42'), isNull);
  });

  test('minuteur et rappel', () async {
    final r = await QuickAnswers.answer('mets un minuteur de 10 minutes', call: fake, tools: tools, now: now);
    expect(r!.timer, const Duration(minutes: 10));
    final r2 = await QuickAnswers.answer('rappelle-moi dans 2 heures de sortir le chien', call: fake, tools: tools, now: now);
    expect(r2!.timer, const Duration(hours: 2));
    expect(r2.timerLabel, 'sortir le chien');
  });

  test('musique et son', () async {
    calls.clear();
    expect(await ask('musique suivante'), 'Suivante !');
    expect(calls.single, 'musique_commande {action: suivant}');
    expect(await ask('c\'est quoi cette musique ?'), 'C\'est « Blinding Lights » de The Weeknd.');
    final v = await QuickAnswers.answer('monte le son', call: fake, tools: tools, now: now);
    expect(v!.media, 'volup');
  });

  test('devoirs, contrôle, emploi du temps, notes, météo', () async {
    expect(await ask('mes devoirs pour demain'), 'Pour demain (1) : Mathématiques : Exercices 3 et 4 page 52.');
    expect(await ask('c\'est quand mon prochain contrôle ?'), 'Ton prochain contrôle : SVT jeudi 19 novembre (Chapitre 3 : la génétique).');
    expect(await ask('j\'ai quoi demain'), 'Demain : 8 h Mathématiques, 9 h Anglais, 14 h Sport. Tu finis à 16 h.');
    expect(await ask('mon prochain cours'), 'Ton prochain cours : Mathématiques, demain à 8 h (salle B12).');
    expect(await ask('mes notes'), 'Tes dernières notes : Physique 15/20, Français 12/20.');
    expect(await ask('quel temps fait-il ?'), '☁️ 9 °C, nuageux à Lyon. Entre 6 et 12 °C, 30 % de risque de pluie. Prends une veste.');
  });

  test('actions : ranger, YouTube, document, liste, ouvrir, révisions', () async {
    calls.clear();
    expect(await ask('range mes téléchargements'), contains('12 fichiers'));
    expect(calls, ['pc_ranger_apercu {dossier: telechargements}', 'pc_ranger {dossier: telechargements}']);
    expect(await ask('mets lofi hip hop sur youtube'), 'Je lance « lofi hip hop » sur YouTube.');
    expect(await ask('crée un nouveau document'), 'Voilà un nouveau document.');
    expect(await ask('ajoute acheter du pain à ma liste'), 'Ajouté à ta liste : acheter du pain.');
    expect(await ask('ouvre discord'), 'C\'est ouvert.');
    expect(await ask('combien de cartes à réviser'), '8 cartes à revoir aujourd\'hui, série de 4 jours 🔥');
  });

  test('tout le reste part vers l\'IA', () async {
    for (final q in [
      'explique-moi la photosynthèse',
      'combien de temps pour aller à Paris',
      'range ta chambre',
      'ouvre le fichier exposé que j\'ai fait hier',
      'quelle heure est-il à Tokyo',
      'mes devoirs de maths sont trop durs, aide-moi',
      'écris un poème sur la pluie',
      'il fait quoi Léo ce soir',
    ]) {
      expect(await ask(q), isNull, reason: q);
    }
  });
}
