import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/cam_blur.dart';
import 'package:hub/core/camera_guard.dart';
import 'package:hub/core/module_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Mode caméra privée', () {
    final now = DateTime(2026, 11, 24, 18);
    PrivateStep step({
      bool on = true,
      bool blocked = true,
      String? call,
      bool asked = false,
      DateTime? openedAt,
      bool sawCall = false,
    }) => PrivateCamRules.step(
      on: on,
      blocked: blocked,
      call: call,
      asked: asked,
      openedAt: openedAt,
      sawCall: sawCall,
      now: now,
    );

    test('appel avec caméra coupée : il demande une fois', () {
      expect(step(call: 'Discord'), PrivateStep.ask);
      expect(step(call: 'Discord', asked: true), PrivateStep.none);
      expect(step(call: 'Discord', blocked: false), PrivateStep.none);
      expect(step(on: false, call: 'Discord'), PrivateStep.none);
    });

    test('après l\'appel : recoupée', () {
      final opened = now.subtract(const Duration(minutes: 3));
      expect(step(blocked: false, openedAt: opened, sawCall: true), PrivateStep.reblock);
      // Pendant l'appel : rien.
      expect(step(blocked: false, openedAt: opened, sawCall: true, call: 'Discord'), PrivateStep.none);
    });

    test('rallumée hors appel : 20 minutes de répit', () {
      expect(step(blocked: false, openedAt: now.subtract(const Duration(minutes: 5))), PrivateStep.none);
      expect(step(blocked: false, openedAt: now.subtract(const Duration(minutes: 21))), PrivateStep.reblock);
      // Rallumée sans Nexo (avant le mode) : on n'y touche pas.
      expect(step(blocked: false), PrivateStep.none);
    });

    test('la question dit qu\'il recoupe', () {
      expect(PrivateCamRules.askText('Discord'), contains('recoupe'));
    });
  });

  group('Flou de la caméra', () {
    test('phrases', () {
      expect(CamBlur.modeFrom('floute mon visage'), 'visage');
      expect(CamBlur.modeFrom('Floute mon visage pendant l\'appel'), 'visage');
      expect(CamBlur.modeFrom('cache mon visage'), 'visage');
      expect(CamBlur.modeFrom('floute tout'), 'tout');
      expect(CamBlur.modeFrom('enlève le flou'), 'non');
      expect(CamBlur.modeFrom('Pourquoi mon visage est flou sur les photos ?'), isNull);
      expect(CamBlur.modeFrom('floute mon arrière-plan'), isNull);
    });

    test('script : mode choisi, filtre branché, jamais d\'image nette si le flou rate', () {
      final js = CamBlur.script('visage');
      expect(js, contains("window.__monhubFlou = 'visage'"));
      expect(js, contains('MediaStreamTrackProcessor'));
      expect(js, contains('FaceDetector'));
      expect(js, contains('Flou impossible'));
      expect(CamBlur.script('nimporte'), contains("window.__monhubFlou = 'non'"));
      expect(CamBlur.liveScript('tout'), "window.__monhubFlou = 'tout';");
    });

    test('arguments du navigateur ajoutés sans doublon', () {
      expect(CamBlur.withArgs(null), CamBlur.browserArgs);
      expect(CamBlur.withArgs('--foo'), '--foo ${CamBlur.browserArgs}');
      expect(CamBlur.withArgs(CamBlur.browserArgs), CamBlur.browserArgs);
    });

    test('la façon choisie est gardée', () async {
      SharedPreferences.setMockInitialValues({});
      await ModuleStore.init();
      final sent = <String>[];
      CamBlur.instance.apply = (js) async => sent.add(js);
      addTearDown(() => CamBlur.instance.apply = null);
      expect(CamBlur.instance.mode, 'non');
      await CamBlur.instance.setMode('visage');
      expect(CamBlur.instance.mode, 'visage');
      expect(sent.single, contains('visage'));
      expect(CamBlur.say('visage', faces: false), contains('toute l\'image'));
    });
  });
}
