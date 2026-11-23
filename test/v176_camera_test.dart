import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/camera_guard.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  group('Qui utilise la caméra', () {
    test('le nom de l\'appli vient du chemin', () {
      expect(CameraRules.appName(r'C:#Program Files#Zoom#bin#Zoom.exe'), 'Zoom');
      expect(CameraRules.appName(r'C:#Users#erik#AppData#Local#Discord#Discord.exe'), 'Discord');
      expect(CameraRules.appName(r'C:\Program Files\Google\Chrome\chrome.exe'), 'Chrome');
    });

    test('le nom de l\'appli vient du paquet Windows', () {
      expect(CameraRules.appName('Microsoft.WindowsCamera_8wekyb3d8bbwe'), 'Appareil photo');
    });

    test('une appli inconnue garde son nom, avec une majuscule', () {
      expect(CameraRules.appName(r'C:#Temp#espion.exe'), 'Espion');
      expect(CameraRules.appName(''), 'Une appli');
    });

    test('les applis d\'appel sont normales, les autres non', () {
      expect(CameraRules.unexpected('Discord'), isFalse);
      expect(CameraRules.unexpected('Zoom'), isFalse);
      expect(CameraRules.unexpected('Espion'), isTrue);
    });
  });

  group('Lecture du registre de Windows', () {
    // Windows met la fin à 0 pendant qu'une appli filme.
    final json = {
      'bloque': false,
      'apps': [
        {'cle': r'C:#Program Files#Zoom#bin#Zoom.exe', 'debut': 133000000000000000, 'fin': 0},
        {'cle': r'C:#Temp#espion.exe', 'debut': 132900000000000000, 'fin': 132900001000000000},
        {'cle': 'NonPackaged', 'debut': 0, 'fin': 0},
      ],
    };

    test('celle qui filme en ce moment est repérée', () {
      final s = CameraRules.parse(json);
      expect(s.blocked, isFalse);
      expect(s.active.length, 1);
      expect(s.active.first.app, 'Zoom');
    });

    test('la clé NonPackaged n\'est pas une appli', () {
      expect(CameraRules.parse(json).uses.any((u) => u.key == 'NonPackaged'), isFalse);
    });

    test('caméra coupée : Windows répond Deny', () {
      expect(CameraRules.parse({'bloque': true, 'apps': const []}).blocked, isTrue);
    });

    test('la plus récente d\'abord', () {
      expect(CameraRules.parse(json).recent.first.app, 'Zoom');
    });

    test('une réponse vide ne casse rien', () {
      expect(CameraRules.parse(null).uses, isEmpty);
      expect(CameraRules.parse('bizarre').blocked, isFalse);
    });

    test('les dates Windows sont converties', () {
      expect(CameraRules.fromFileTime(0), isNull);
      expect(CameraRules.fromFileTime(133000000000000000)?.year, 2022);
    });
  });

  group('Ce que Clicky dit', () {
    test('caméra coupée', () {
      final say = CameraRules.say(const SensorState(blocked: true), const SensorState());
      expect(say, contains('coupée'));
    });

    test('caméra utilisée par une appli', () {
      final cam = SensorState(
        uses: [SensorUse(key: 'a', app: 'Discord', active: true, at: DateTime(2026, 11, 23))],
      );
      expect(CameraRules.say(cam, const SensorState()), contains('Discord'));
    });

    test('personne ne s\'en sert', () {
      expect(CameraRules.say(const SensorState(), const SensorState()), contains('personne'));
    });

    test('le micro est dit aussi', () {
      final mic = SensorState(
        uses: [const SensorUse(key: 'b', app: 'Teams', active: true)],
      );
      expect(CameraRules.say(const SensorState(), mic), contains('Teams'));
    });
  });

  group('Phrases sans IA', () {
    Future<QuickReply?> ask(String phrase, {Set<String> tools = const {'camera_couper', 'camera_etat'}}) =>
        QuickAnswers.answer(
          phrase,
          tools: tools,
          call: (name, args) async => switch (name) {
            'camera_couper' => {
              'resume': args['couper'] == 'non' ? 'La caméra remarche.' : 'La caméra est coupée.',
              'fait': true,
            },
            'camera_etat' => {'resume': 'Ta caméra est utilisée en ce moment par Discord.'},
            _ => null,
          },
        );

    test('« coupe ma caméra »', () async {
      expect((await ask('coupe ma caméra'))?.text, contains('coupée'));
      expect((await ask('Clicky, éteins ma webcam'))?.text, contains('coupée'));
    });

    test('« rallume ma caméra »', () async {
      expect((await ask('rallume ma caméra'))?.text, contains('remarche'));
    });

    test('« qui utilise ma caméra ? »', () async {
      expect((await ask('qui utilise ma caméra ?'))?.text, contains('Discord'));
      expect((await ask('on me filme ?'))?.text, contains('Discord'));
    });

    test('une vraie question part vers l\'IA', () async {
      expect(await ask('explique-moi comment marche une caméra'), isNull);
      expect(await ask('pourquoi ma caméra fait une image floue sur Discord ?'), isNull);
    });

    test('sans l\'outil, rien n\'est répondu sans IA', () async {
      expect(await ask('coupe ma caméra', tools: const {}), isNull);
    });
  });
}
