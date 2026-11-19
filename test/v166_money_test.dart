import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hub/core/pwned.dart';
import 'package:hub/core/tool_router.dart';
import 'package:hub/modules/money/games_deals.dart';
import 'package:hub/modules/money/money_rules.dart';
import 'package:hub/modules/money/money_store.dart';
import 'package:hub/ui/clicky/quick.dart';

void main() {
  final mailDate = DateTime(2026, 11, 19, 10);

  group('Abonnements dans les mails', () {
    test('reçu Spotify : prix et prochain mois', () {
      final f = MoneyRules.subscription(
        fromEmail: 'no-reply@spotify.com',
        subject: 'Votre reçu Spotify',
        text: 'Merci ! Montant payé : 11,12 €. Spotify Premium Individual.',
        mailDate: mailDate,
      )!;
      expect(f.service, 'Spotify');
      expect(f.price, 11.12);
      expect(f.kind, 'paiement');
      expect(f.date, DateTime(2026, 12, 19));
    });

    test('essai Netflix qui se termine', () {
      final f = MoneyRules.subscription(
        fromEmail: 'info@mailer.netflix.com',
        subject: 'Votre essai gratuit se termine bientôt',
        text: 'Votre période d\'essai prend fin le 3 décembre. Vous serez ensuite facturé 7,99 € par mois.',
        mailDate: mailDate,
      )!;
      expect(f.service, 'Netflix');
      expect(f.kind, 'essai');
      expect(f.date, DateTime(2026, 12, 3));
      expect(f.price, 7.99);
    });

    test('anglais, annuel, renouvellement', () {
      final f = MoneyRules.subscription(
        fromEmail: 'billing@discord.com',
        subject: 'Your Nitro subscription will renew',
        text: 'Your yearly plan will renew on January 15, 2027 for €99.99.',
        mailDate: mailDate,
      )!;
      expect(f.service, 'Discord Nitro');
      expect(f.kind, 'renouvellement');
      expect(f.yearly, isTrue);
      expect(f.price, 99.99);
      expect(f.date, DateTime(2027, 1, 15));
      expect(MoneyRules.monthly(f.price, f.yearly), closeTo(8.33, 0.01));
    });

    test('résiliation, mails sans rapport', () {
      final f = MoneyRules.subscription(
        fromEmail: 'noreply@deezer.com',
        subject: 'Votre abonnement a été résilié',
        text: 'Vous profitez de Deezer Premium jusqu\'au 30/11/2026.',
        mailDate: mailDate,
      )!;
      expect(f.kind, 'resiliation');
      expect(f.date, DateTime(2026, 11, 30));
      // Apple / Google envoient de tout : il faut le nom d'un abonnement.
      expect(
        MoneyRules.subscription(fromEmail: 'news@apple.com', subject: 'Découvrez le nouvel iPhone', text: 'Paiement en 3 fois', mailDate: mailDate),
        isNull,
      );
      expect(
        MoneyRules.subscription(fromEmail: 'ami@gmail.com', subject: 'Reçu ta photo', text: 'cool', mailDate: mailDate),
        isNull,
      );
      expect(MoneyRules.serviceOf('no_reply@email.apple.com', 'Votre reçu pour Apple Music'), isNotNull);
    });

    test('montants et dates', () {
      expect(MoneyRules.amount('Total : €9.99'), 9.99);
      expect(MoneyRules.amount('9,99 EUR'), 9.99);
      expect(MoneyRules.amount('pas de prix'), isNull);
      expect(MoneyRules.date('le 12 décembre 2026', mailDate), DateTime(2026, 12, 12));
      expect(MoneyRules.date('12/01/27', mailDate), DateTime(2027, 1, 12));
      // Sans année, une date passée = l'an prochain.
      expect(MoneyRules.date('le 2 janvier', mailDate), DateTime(2027, 1, 2));
      expect(MoneyRules.date('Dec 24th', mailDate), DateTime(2026, 12, 24));
    });
  });

  group('Colis dans les mails', () {
    test('Colissimo à retirer', () {
      final p = MoneyRules.parcel(
        fromEmail: 'noreply@notif-colissimo-laposte.info',
        fromName: 'Colissimo',
        subject: 'Votre colis est disponible en point relais',
        text: 'Votre colis 6A12345678901 vous attend au bureau de poste.',
      )!;
      expect(p.carrier, 'Colissimo');
      expect(p.number, '6A12345678901');
      expect(p.status, 'a_retirer');
      expect(p.link, contains('6A12345678901'));
    });

    test('boutique + UPS, puis livré', () {
      final p = MoneyRules.parcel(
        fromEmail: 'commande@zalando.fr',
        fromName: 'Zalando',
        subject: 'Ta commande a été expédiée',
        text: 'Suivi UPS : 1Z999AA10123456784',
      )!;
      expect(p.carrier, 'UPS');
      expect(p.shop, 'Zalando');
      expect(p.status, 'expedie');
      expect(MoneyRules.later('expedie', 'livre'), isTrue);
      expect(MoneyRules.later('livre', 'expedie'), isFalse);
    });

    test('un numéro court seulement si le mail vient du transporteur', () {
      expect(
        MoneyRules.parcel(fromEmail: 'ami@gmail.com', fromName: 'Tom', subject: 'livraison de pizza', text: 'code 12345678'),
        isNull,
      );
      final m = MoneyRules.parcel(
        fromEmail: 'noreply@mondialrelay.fr',
        fromName: 'Mondial Relay',
        subject: 'Votre colis est arrivé en Point Relais',
        text: 'Expédition n° 12345678',
      )!;
      expect(m.carrier, 'Mondial Relay');
      expect(m.number, '12345678');
    });

    test('le stockage ne fait jamais reculer un colis', () {
      final s = MoneyStore();
      s.applyParcel(const ParcelFinding(carrier: 'UPS', number: '1Z999AA10123456784', status: 'a_retirer'));
      s.applyParcel(const ParcelFinding(carrier: 'UPS', number: '1Z999AA10123456784', status: 'expedie'));
      expect(s.parcels.single.status, 'a_retirer');
      s.applyParcel(const ParcelFinding(carrier: 'UPS', number: '1Z999AA10123456784', status: 'livre'));
      expect(s.parcels.single.status, 'livre');
    });

    test('abonnements : total et prochain prélèvement', () {
      final s = MoneyStore();
      s.applySub(const SubFinding(service: 'Spotify', price: 11.12, kind: 'paiement'), mailDate);
      s.applySub(SubFinding(service: 'Nitro', price: 99.99, yearly: true, kind: 'renouvellement', date: DateTime(2027, 1, 15)), mailDate);
      expect(s.monthly, closeTo(11.12 + 8.33, 0.01));
      s.applySub(const SubFinding(service: 'Spotify', kind: 'resiliation'), mailDate);
      expect(s.monthly, closeTo(8.33, 0.01));
      final monthly = Subscription(service: 'X', price: 5, next: DateTime(2026, 9, 10));
      expect(monthly.nextFrom(mailDate), DateTime(2026, 12, 10));
    });
  });

  group('Jeux', () {
    test('Epic : gratuit maintenant et bientôt', () {
      final json = {
        'data': {
          'Catalog': {
            'searchStore': {
              'elements': [
                {
                  'title': 'Jeu Gratuit',
                  'id': 'a1',
                  'productSlug': 'jeu-gratuit/home',
                  'keyImages': [{'type': 'OfferImageWide', 'url': 'https://img/a.jpg'}],
                  'promotions': {
                    'promotionalOffers': [
                      {
                        'promotionalOffers': [
                          {'startDate': '2026-11-19T16:00:00.000Z', 'endDate': '2026-11-26T16:00:00.000Z', 'discountSetting': {'discountPercentage': 0}},
                        ],
                      },
                    ],
                    'upcomingPromotionalOffers': [],
                  },
                },
                {
                  'title': 'Bientôt',
                  'id': 'b2',
                  'catalogNs': {'mappings': [{'pageSlug': 'bientot'}]},
                  'promotions': {
                    'promotionalOffers': [],
                    'upcomingPromotionalOffers': [
                      {'promotionalOffers': [{'startDate': '2026-11-26T16:00:00.000Z', 'discountSetting': {'discountPercentage': 0}}]},
                    ],
                  },
                },
                {'title': 'Simple promo', 'id': 'c3', 'promotions': {'promotionalOffers': [{'promotionalOffers': [{'discountSetting': {'discountPercentage': 50}}]}]}},
                {'title': 'Sans promo', 'id': 'd4', 'promotions': null},
              ],
            },
          },
        },
      };
      final g = GameDeals.parseEpic(json);
      expect(g.map((x) => x.title), ['Jeu Gratuit', 'Bientôt']);
      expect(g.first.now, isTrue);
      expect(g.first.url, 'https://store.epicgames.com/fr/p/jeu-gratuit');
      expect(g.first.image, 'https://img/a.jpg');
      expect(g.last.now, isFalse);
      expect(g.last.url, endsWith('/p/bientot'));
    });

    test('Steam : liste et promos', () {
      expect(GameDeals.parseWishlist({'response': {'items': [{'appid': 10}, {'appid': 20}, {'x': 1}]}}), [10, 20]);
      final deals = GameDeals.parsePrices({
        '10': {'success': true, 'data': {'price_overview': {'discount_percent': 75, 'final_formatted': '4,99€', 'initial_formatted': '19,99€'}}},
        '20': {'success': true, 'data': {'price_overview': {'discount_percent': 10}}},
        '30': {'success': true, 'data': []},
      }, 20);
      expect(deals, [(10, 75, '4,99€', '19,99€')]);
    });

    test('Steam : numéro de profil', () async {
      expect(await GameDeals.steamId('https://steamcommunity.com/profiles/76561198000000000/'), '76561198000000000');
      final c = MockClient((r) async => http.Response('<profile><steamID64>76561198012345678</steamID64></profile>', 200));
      expect(await GameDeals.steamId('https://steamcommunity.com/id/monpseudo', client: c), '76561198012345678');
    });
  });

  group('Mots de passe fuités', () {
    test('seul le début de l\'empreinte part', () async {
      final h = PwnedPasswords.hash('password');
      expect(h, '5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8');
      Uri? asked;
      final c = MockClient((r) async {
        asked = r.url;
        expect(r.headers['Add-Padding'], 'true');
        return http.Response('0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9659365\r\nAAAA:0', 200);
      });
      expect(await PwnedPasswords.count('password', client: c), 9659365);
      expect(asked.toString(), 'https://api.pwnedpasswords.com/range/5BAA6');
      // Le reste de l'empreinte (et donc le mot de passe) ne part jamais.
      expect(asked.toString(), isNot(contains(h.substring(5))));
      expect(await PwnedPasswords.count('un-mot-de-passe-tres-long-et-unique', client: c), 0);
      expect(PwnedPasswords.advice(9659365), contains('9,7 million'));
      expect(PwnedPasswords.advice(0), startsWith('✅'));
    });
  });

  group('Clicky sans IA', () {
    final calls = <String>[];
    Future<Object?> fake(String name, Map<String, dynamic> a) async {
      calls.add(name);
      return switch (name) {
        'argent_abonnements' => {
          'total_par_mois': '19,11 €',
          'abonnements': [
            {'service': 'Spotify', 'prix': '11,12 € par mois', 'prochain': '2026-12-19'},
            {'service': 'Netflix', 'prix': '7,99 € par mois', 'prochain': '2026-12-03'},
          ],
        },
        'argent_colis' => [
          {'boutique': 'Zalando', 'etat': 'À retirer'},
        ],
        'argent_jeux' => {
          'gratuits': [
            {'titre': 'Jeu Gratuit', 'maintenant': true},
          ],
        },
        _ => null,
      };
    }

    Future<String?> ask(String q) async =>
        (await QuickAnswers.answer(q, call: fake, tools: const {'argent_abonnements', 'argent_colis', 'argent_jeux'}, now: mailDate))?.text;

    test('phrases', () async {
      expect(await ask('mes abonnements'), contains('2 abonnements : Spotify (11,12 € par mois), Netflix'));
      expect(await ask('combien je dépense en abonnements ?'), contains('19,11 € par mois'));
      expect(await ask('Où est mon colis ?'), '📦 Zalando : À retirer');
      expect(await ask('jeux gratuits'), contains('Jeu Gratuit'));
      calls.clear();
      expect(await ask('c\'est quoi un abonnement ?'), isNull);
      expect(calls, isEmpty);
    });

    test('Claude reçoit les outils', () {
      expect(ToolRouter.groupsFor('mon essai gratuit de netflix'), contains('argent'));
      expect(ToolRouter.groupOf('argent_colis'), 'argent');
      expect(ToolRouter.groupsFor('il arrive quand mon colis'), contains('argent'));
    });
  });
}
