import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/modules/ecoledirecte/ed_client.dart';
import 'package:hub/modules/schedule/schedule_module.dart';

void main() {
  test('évènement perso hebdomadaire', () {
    final e = PersonalEvent(
      id: '1',
      title: 'Foot',
      start: DateTime(2026, 11, 4, 18),
      end: DateTime(2026, 11, 4, 19, 30),
      weekly: true,
    );
    final occ = e.occurrences(DateTime(2026, 11, 16), DateTime(2026, 11, 30)).toList();
    expect(occ.map((o) => o.$1), [DateTime(2026, 11, 18, 18), DateTime(2026, 11, 25, 18)]);
    expect(occ.first.$2, DateTime(2026, 11, 18, 19, 30));
    final once = PersonalEvent.fromJson({...e.toJson(), 'weekly': false});
    expect(once.occurrences(DateTime(2026, 11, 16), DateTime(2026, 11, 30)), isEmpty);
  });

  test('connexion École Directe avec question de sécurité', () async {
    final seen = <String, Map<String, String>>{};
    final client = MockClient((req) async {
      final path = req.url.path + (req.url.queryParameters['verbe'] ?? '');
      seen[path] = req.headers;
      Map<String, dynamic> data() =>
          jsonDecode(Uri.decodeComponent(req.body.substring(5))) as Map<String, dynamic>;
      if (req.method == 'GET') {
        return http.Response('{"code":200}', 200,
            headers: {'set-cookie': 'GTK=abc; Path=/,other=1; expires=Wed, 21 Oct 2026 07:28:00 GMT'});
      }
      if (req.url.path.endsWith('login.awp')) {
        final d = data();
        if (d['fa'] == null) {
          return http.Response('{"code":250,"token":"tmp","message":"","data":{}}', 200,
              headers: {'2fa-token': 'f2a'});
        }
        expect((d['fa'] as List).first['cn'], 'CN');
        return http.Response(
            jsonEncode({
              'code': 200,
              'token': 'final',
              'data': {
                'accounts': [
                  {'id': 42, 'prenom': 'Erik', 'nom': 'M', 'typeCompte': 'E'}
                ]
              }
            }),
            200);
      }
      if (req.url.queryParameters['verbe'] == 'get') {
        return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'question': base64.encode(utf8.encode('Année ?')),
                'propositions': [base64.encode(utf8.encode('2010')), base64.encode(utf8.encode('2011'))],
              }
            }),
            200);
      }
      return http.Response('{"code":200,"data":{"cn":"CN","cv":"CV"}}', 200);
    });
    final ed = EdClient(client);
    await ed.login('erik', 'p@ss&+', answerQuestion: (q, c) async {
      expect(q, 'Année ?');
      return c.last;
    });
    expect(ed.accountId, 42);
    expect(ed.token, 'final');
    final dbl = seen['/v3/connexion/doubleauth.awpget']!;
    expect(dbl['x-token'] ?? dbl['X-Token'], 'tmp');
    expect(dbl['2fa-token'], 'f2a');
    expect(dbl['Cookie'], contains('GTK=abc'));
    expect(dbl['X-Gtk'], 'abc');
    expect(ed.lastFa, [
      {'cn': 'CN', 'cv': 'CV'}
    ]);
  });
}
