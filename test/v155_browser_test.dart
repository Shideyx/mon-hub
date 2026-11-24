import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/browser_link.dart';
import 'package:hub/core/claude_bridge.dart';
import 'package:hub/core/hub_module.dart';
import 'package:hub/core/prompt_shield.dart';
import 'package:hub/ui/clicky/background_tasks.dart';
import 'package:hub/ui/clicky/clicky.dart';

void main() {
  test('seule l\'extension Mon Hub peut se brancher', () {
    expect(BrowserLink.allowedOrigin('chrome-extension://${BrowserLink.extensionId}'), isTrue);
    expect(BrowserLink.allowedOrigin('extension://${BrowserLink.extensionId}'), isTrue);
    expect(BrowserLink.allowedOrigin('https://site-piege.com'), isFalse);
    expect(BrowserLink.allowedOrigin('chrome-extension://autreextensionaaaaaaaaaaaaaaaaaaa'), isFalse);
    expect(BrowserLink.allowedOrigin(null), isFalse);
  });

  test('les clics qui envoient, publient, paient ou suppriment', () {
    for (final l in ['Envoyer', 'Publier', 'Payer 12 €', 'Supprimer le fichier', 'Valider la commande', 'Rendre le devoir', 'Submit']) {
      expect(BrowserLink.risky.hasMatch(l), isTrue, reason: l);
    }
    for (final l in ['Suivant', 'Ouvrir', 'Rechercher', 'Mes cours', 'Ajouter une diapositive']) {
      expect(BrowserLink.risky.hasMatch(l), isFalse, reason: l);
    }
  });

  test('permissions : écrire dans une page demande l\'accord, lire est étiqueté « données »', () {
    HubTool t(String n) => HubTool(name: n, description: '', run: (_) async => null);
    expect(ClaudeBridge.isWriteAction(t('nav_cliquer')), isTrue);
    expect(ClaudeBridge.isWriteAction(t('nav_ecrire')), isTrue);
    expect(ClaudeBridge.isWriteAction(t('nav_lire')), isFalse);
    expect(PromptShield.readsOutside('nav_lire'), isTrue);
  });

  test('« fais-le à ma place » reconnu', () {
    final re = ClickyController.forMeRe;
    String? rest(String q) {
      final m = re.firstMatch(q);
      return m == null ? null : q.substring(m.end).trim();
    }

    expect(rest('Fais-le à ma place : crée un Google Form pour le sondage'), 'crée un Google Form pour le sondage');
    expect(rest('Smily, fais ça pour moi, range mes devoirs dans un doc'), 'range mes devoirs dans un doc');
    expect(rest('en arrière-plan, prépare ma fiche d\'histoire'), 'prépare ma fiche d\'histoire');
    expect(rest('fais à ma place'), '');
    expect(rest('comment je fais pour moi-même'), isNull);
    expect(rest('fais un exposé'), isNull);
  });

  test('tâche de fond : étapes, fin, arrêt', () async {
    final b = BackgroundTasks.instance;
    final done = <String>[];
    final gate = Completer<String>();
    b
      ..runner = (p) async {
        expect(p, contains('EN ARRIÈRE-PLAN'));
        BrowserLink.instance.step.value = 'ouvre classroom.google.com';
        return gate.future;
      }
      ..onDone = (t, body) => done.add('$t|$body');
    final say = b.start('Rendre le devoir de maths sur Classroom');
    expect(say, contains('en arrière-plan'));
    expect(b.current?.goal, 'Rendre le devoir de maths sur Classroom');
    expect(BrowserLink.instance.trusted, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(b.current!.steps, ['ouvre classroom.google.com']);
    gate.complete('Devoir rendu ✓');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(b.current, isNull);
    expect(done.single, startsWith('Smily a fini'));
    expect(BrowserLink.instance.trusted, isFalse);
    // Arrêter une tâche.
    b.runner = (_) => Completer<String>().future;
    b.start('Une longue tâche');
    final t = b.current!;
    b.cancel(t);
    expect(t.status, 'arrêté');
    expect(BrowserLink.instance.stopped, isTrue);
    expect(b.start(''), contains('Dis-moi'));
  });

  test('le lien avec l\'extension (vraie connexion locale)', () async {
    final link = BrowserLink.instance;
    link.stopped = false;
    await link.start();
    // Une page web (mauvaise origine) est refusée.
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${BrowserLink.port}/navigateur', headers: {'origin': 'https://piege.com'}),
      throwsA(isA<WebSocketException>()),
    );
    // La vraie extension : elle répond aux commandes.
    final ext = await WebSocket.connect(
      'ws://127.0.0.1:${BrowserLink.port}/navigateur',
      headers: {'origin': 'chrome-extension://${BrowserLink.extensionId}'},
    );
    ext.listen((data) {
      final m = jsonDecode('$data') as Map;
      if (m['cmd'] == 'tabs') ext.add(jsonEncode({'id': m['id'], 'ok': true, 'result': [{'id': 7, 'titre': 'Classroom'}]}));
      if (m['cmd'] == 'read') ext.add(jsonEncode({'id': m['id'], 'ok': false, 'error': 'Page protégée'}));
    });
    ext.add(jsonEncode({'hello': 'monhub-chrome', 'version': '1.0.0'}));
    for (var i = 0; i < 50 && !link.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(link.connected, isTrue);
    expect(await link.call('tabs', {}), [{'id': 7, 'titre': 'Classroom'}]);
    await expectLater(link.call('read', {'tab': 7}), throwsA('Page protégée'));
    await ext.close();
    for (var i = 0; i < 50 && link.connected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(link.connected, isFalse);
    await link.stop();
  });
}
