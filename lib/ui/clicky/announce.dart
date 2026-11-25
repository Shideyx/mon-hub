import '../../core/notifications.dart';

/// **Nexo t'annonce tes messages**, comme un majordome : « Léa sur Discord :
/// t'es là ? ». Une petite bulle à côté de ta souris dès que le message
/// arrive (et à voix haute si tu le veux), sans IA.
///
/// Garde-fous : jamais pendant un appel, un jeu ou le mode concentration
/// (c'est `think` qui vérifie que Nexo est « calme ») ; au plus une annonce
/// toutes les 20 secondes (une rafale = une seule bulle : « 3 nouveaux
/// messages ») ; jamais le texte d'un message qui ressemble à un code ou un
/// mot de passe.
class MessageAnnounce {
  MessageAnnounce._();

  /// Les notifications qui sont des **messages** de quelqu'un, et d'où :
  /// (appli, qui, texte) ; null sinon. Sans IA : testable.
  static (String, String, String)? messageOf(HubNotification n) {
    final id = n.id;
    final title = n.title.trim();
    final body = n.body.trim();
    if (id.startsWith('arnaque:')) return null;
    // Un appel Discord qui sonne dans Mon Hub.
    if (id.startsWith('discord-appel')) return ('appel', body.replaceFirst(RegExp(r" t'appelle$"), '').trim(), '');
    // Discord : « Discord · Léa » (l'id est celui du message).
    if (n.moduleId == 'discord' && title.startsWith('Discord · ')) {
      return ('Discord', title.substring('Discord · '.length).trim(), body);
    }
    // Instagram (la veille des messages) : « 📸 Léa » ou « 📸 Instagram ».
    if (id.startsWith('insta:')) {
      final who = title.replaceFirst(RegExp(r'^📸\s*'), '').trim();
      return ('Instagram', who == 'Instagram' ? '' : who, body);
    }
    // Espaces partagés : « 💬 Léa » ou « 💬 Léa · Exposé ».
    if (id.startsWith('espace:')) {
      final who = title.replaceFirst(RegExp(r'^💬\s*'), '').split(' · ').first.trim();
      return ('Mon Hub', who, body);
    }
    // Mails : « ✉️ Expéditeur », le sujet en texte.
    if (n.moduleId == 'mail') return ('mail', title.replaceFirst(RegExp(r'^✉️\s*'), '').trim(), body);
    // École Directe : « 📨 École Directe · Expéditeur » (id « msg: »).
    if (id.startsWith('msg:') && title.contains(' · ')) {
      return ('École Directe', title.substring(title.indexOf(' · ') + 3).trim(), body);
    }
    return null;
  }

  /// Un texte qui ne doit pas être lu tout haut (code, mot de passe…).
  static bool secretLike(String text) =>
      RegExp(r'\b\d{4,8}\b').hasMatch(text) &&
          RegExp(r'code|v[ée]rification|connexion|login|otp|2fa|mot de passe|password', caseSensitive: false)
              .hasMatch(text) ||
      RegExp(r'mot de passe|password', caseSensitive: false).hasMatch(text);

  /// Ce que Nexo dit pour ce message (court). null : rien à annoncer.
  static String? line(HubNotification n) {
    final m = messageOf(n);
    if (m == null) return null;
    final (app, who, body) = m;
    if (app == 'appel') {
      final from = who.isEmpty || who.startsWith('On t') ? 'Appel Discord' : '$who t\'appelle sur Discord';
      return '📞 $from. Dis « décroche » ou « refuse l\'appel ».';
    }
    var text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (secretLike(text)) text = '';
    if (text.length > 90) text = '${_cut(text, 87)}…';
    if (app == 'mail') {
      final from = who.isEmpty ? 'Nouveau mail' : 'Un mail ${_de(who)}';
      return text.isEmpty ? '$from.' : '$from : $text';
    }
    final from = who.isEmpty ? 'Nouveau message sur $app' : '$who sur $app';
    if (app == 'Instagram' && who.isEmpty) return text.isEmpty ? 'Nouveau message sur Instagram.' : _dot(text);
    return text.isEmpty ? '$from.' : '$from : $text';
  }

  /// « de Léa », « d'Amazon ».
  static String _de(String who) => RegExp(r'^[aeiouyhàâäéèêëîïôöûüAEIOUYHÀÂÉÈÊÎÔÛ]').hasMatch(who) ? 'd\'$who' : 'de $who';

  /// Un point à la fin, sans en mettre deux.
  static String _dot(String s) => RegExp(r'[.!?…]$').hasMatch(s) ? s : '$s.';

  /// Un appel (toujours annoncé tout de suite, et à voix haute si Nexo parle).
  static bool isCall(HubNotification n) => n.id.startsWith('discord-appel');

  /// Couper sans casser un émoji (deux morceaux UTF-16).
  static String _cut(String s, int n) {
    var cut = n.clamp(0, s.length);
    if (cut > 0 && cut < s.length) {
      final u = s.codeUnitAt(cut - 1);
      if (u >= 0xD800 && u <= 0xDBFF) cut--;
    }
    return s.substring(0, cut).trimRight();
  }
}

/// Le rythme des annonces (au plus une toutes les [gap]) : les messages
/// arrivés pendant l'attente sont regroupés.
class AnnouncePacer {
  AnnouncePacer({this.gap = const Duration(seconds: 20)});
  final Duration gap;

  DateTime? _last;
  int _waiting = 0;

  /// Un message arrive à [now] : ce qu'il faut dire maintenant (null : on
  /// attend, il sera compté dans la prochaine annonce).
  String? onMessage(String line, DateTime now) {
    final last = _last;
    if (last != null && now.difference(last) < gap) {
      _waiting++;
      return null;
    }
    _last = now;
    final extra = _waiting;
    _waiting = 0;
    return extra == 0 ? line : '$line (et ${extra == 1 ? 'un autre message' : '$extra autres messages'} avant).';
  }
}
