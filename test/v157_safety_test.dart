import 'package:flutter_test/flutter_test.dart';
import 'package:hub/core/scam_shield.dart';
import 'package:hub/core/security_check.dart';
import 'package:hub/modules/mail/mail_module.dart';
import 'package:hub/ui/clicky/quick.dart';
import 'package:enough_mail/enough_mail.dart';

void main() {
  group('bouclier anti-arnaque', () {
    test('les vrais sites passent', () {
      for (final u in [
        'https://discord.com/channels/123/456',
        'https://discord.gg/abc',
        'https://www.roblox.com/games/123',
        'https://store.steampowered.com/app/1',
        'https://cdn.discordapp.com/attachments/1/2/image.png',
        'https://lh3.googleusercontent.com/abc',
        'https://www.youtube.com/watch?v=x',
        'https://docs.google.com/document/d/1',
        'https://www.ecoledirecte.com',
        'https://fr.wikipedia.org/wiki/Paris',
        'https://www.lemonde.fr/article',
        'https://pineapple-recipes.com',
        'https://www.nintendo.com/switch',
      ]) {
        expect(ScamShield.checkUrl(u).level, ScamLevel.ok, reason: u);
      }
    });

    test('les faux sites et pièges sont repérés', () {
      for (final u in [
        'https://dlscord.com/nitro',
        'https://discord-nitro.gift/claim',
        'https://steamcommunnity.com/gift/123',
        'https://free-robux-generator.xyz',
        'https://grabify.link/ABC123',
        'https://roblox.com.free-items.ru/login',
        'https://xn--dscord-6va.com',
        'https://rob1ox.com/users/1',
        'https://discord.com/ra/abcdef',
        'https://example.com/setup.exe',
      ]) {
        expect(ScamShield.checkUrl(u).danger, isTrue, reason: '$u → ${ScamShield.checkUrl(u).reasons}');
      }
      expect(ScamShield.checkUrl('https://bit.ly/3abc').level, ScamLevel.suspect);
    });

    test('messages : arnaques classiques, et messages normaux', () {
      expect(
        ScamShield.checkMessage('Yo regarde, Nitro gratuit pendant 3 mois : discord-gifts.com/claim').danger,
        isTrue,
      );
      expect(
        ScamShield.checkMessage('Hey sorry I accidentally reported your account, contact support here').suspect,
        isTrue,
      );
      expect(ScamShield.checkMessage('salut, tu peux tester mon jeu ?', files: ['MonJeu.exe']).danger, isTrue);
      expect(ScamShield.checkMessage('envoie moi le code que tu as reçu par sms stp').danger, isTrue);
      expect(ScamShield.checkMessage('scanne ce QR code pour avoir le badge').danger, isTrue);
      final ok = ScamShield.checkMessage(
        'On se retrouve à 14h au parc ? Regarde la vidéo https://www.youtube.com/watch?v=abc',
      );
      expect(ok.level, ScamLevel.ok, reason: '${ok.reasons}');
      expect(
        ScamShield.checkMessage('t\'as fait le devoir de maths ? c\'est sur ecoledirecte.com').level,
        ScamLevel.ok,
      );
      expect(ScamShield.checkMessage('voilà mes photos', files: ['vacances.zip']).level, ScamLevel.ok);
      expect(ScamShield.checkMessage('Nitro gratuit ici discord-nitro.gift').say(), startsWith('Attention'));
    });
  });

  test('mails : faux expéditeur Discord repéré', () {
    MailSummary m(String from, String subject) =>
        MailSummary('moi@x.fr', 1, 'Discord', from, subject, DateTime(2026), false, MimeMessage());
    expect(MailModule.scamOf(m('support@dlscord.com', 'Ton compte va être supprimé')).danger, isTrue);
    expect(MailModule.scamOf(m('noreply@discord.com', 'Nouvelle connexion')).level, ScamLevel.ok);
    expect(MailModule.scamOf(m('prof@lycee-hugo.fr', 'Devoir pour lundi')).level, ScamLevel.ok);
  });

  test('« ce lien est sûr ? » (le lien copié)', () async {
    final r = await QuickAnswers.answer(
      'Nexo, est-ce que ce lien est sûr ?',
      call: (n, a) async => n == 'securite_lien' ? {'resume': 'Attention, arnaque.'} : null,
      tools: const {'securite_lien'},
    );
    expect(r?.text, 'Attention, arnaque.');
  });

  group('bilan de sécurité', () {
    test('tout va bien', () {
      final items = SecurityCheck.build(
        {
          'av': [
            {'nom': 'Microsoft Defender Antivirus', 'etat': 397568},
          ],
          'defender': {'actif': true, 'tempsReel': true, 'signaturesJours': 0},
          'parefeu': [
            {'nom': 'Domain', 'actif': true},
            {'nom': 'Private', 'actif': true},
            {'nom': 'Public', 'actif': true},
          ],
          'majJours': 12,
          'redemarrage': false,
          'uac': 1,
        },
        discord2fa: true,
        done: {'google'},
      );
      expect(items.where((i) => i.ok == false), isEmpty);
      expect(items.firstWhere((i) => i.id == 'antivirus').detail, contains('Microsoft Defender Antivirus'));
      expect(items.firstWhere((i) => i.id == 'google').ok, isTrue);
      expect(items.firstWhere((i) => i.id == 'roblox').ok, isNull);
      expect(SecurityCheck.say(items), startsWith('Ton PC est bien protégé'));
    });

    test('les soucis sont repérés', () {
      final items = SecurityCheck.build(
        {
          'av': [
            {'nom': 'Microsoft Defender Antivirus', 'etat': 393472},
          ], // éteint
          'defender': {'actif': false, 'tempsReel': false, 'signaturesJours': 20},
          'parefeu': [
            {'nom': 'Public', 'actif': false},
          ],
          'majJours': 90,
          'redemarrage': true,
          'uac': 0,
        },
        discord2fa: false,
        pcControl: 'auto',
      );
      final bad = {
        for (final i in items)
          if (i.ok == false) i.id,
      };
      expect(bad, containsAll(['antivirus', 'signatures', 'parefeu', 'maj', 'uac', 'discord', 'clicky']));
      expect(items.firstWhere((i) => i.id == 'maj').detail, contains('redémarrage'));
      expect(SecurityCheck.say(items), startsWith('À régler'));
    });

    test('« mon PC est protégé ? »', () async {
      final r = await QuickAnswers.answer(
        'est-ce que mon PC est bien protégé',
        call: (n, a) async => n == 'securite_bilan' ? {'resume': 'Ton PC est bien protégé.'} : null,
        tools: const {'securite_bilan'},
      );
      expect(r?.text, 'Ton PC est bien protégé.');
    });
  });
}
