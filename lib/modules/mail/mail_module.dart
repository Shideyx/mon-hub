import 'package:enough_mail/enough_mail.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/google_auth.dart';
import '../../core/scam_shield.dart';
import '../../core/hub_module.dart';
import '../../ui/file_viewer.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';

/// Un mail ouvert : son texte et ses pièces jointes.
class MailContent {
  const MailContent(this.text, this.files);
  final String text;
  final List<MailFile> files;
}

/// Une pièce jointe d'un mail (déjà téléchargée avec le mail).
class MailFile {
  MailFile(this.name, this.size, this.bytes);
  final String name;
  final int? size;
  final Future<List<int>> Function() bytes;
}

class MailSummary {
  MailSummary(this.account, this.uid, this.from, this.fromEmail, this.subject, this.date, this.seen, this.header);
  final String account;
  final int? uid;
  final String from;
  final String fromEmail;
  final String subject;
  final DateTime? date;
  bool seen;

  /// En-têtes du message (servent à construire une réponse correcte).
  final MimeMessage header;
}

/// Serveurs IMAP connus, déduits de l'adresse mail.
String imapHostFor(String email) {
  final domain = email.split('@').last.toLowerCase();
  return switch (domain) {
    'gmail.com' || 'googlemail.com' => 'imap.gmail.com',
    'yahoo.com' || 'yahoo.fr' => 'imap.mail.yahoo.com',
    'icloud.com' || 'me.com' => 'imap.mail.me.com',
    'orange.fr' || 'wanadoo.fr' => 'imap.orange.fr',
    'free.fr' => 'imap.free.fr',
    'sfr.fr' => 'imap.sfr.fr',
    'laposte.net' => 'imap.laposte.net',
    'outlook.com' || 'hotmail.com' || 'hotmail.fr' || 'live.fr' || 'live.com' => 'outlook.office365.com',
    _ => 'imap.$domain',
  };
}

/// Serveur d'envoi (SMTP) et port, déduits du serveur IMAP.
(String, int) smtpFor(String imapHost) => switch (imapHost) {
  'imap.gmail.com' => ('smtp.gmail.com', 465),
  'imap.mail.yahoo.com' => ('smtp.mail.yahoo.com', 465),
  'imap.mail.me.com' => ('smtp.mail.me.com', 587),
  'outlook.office365.com' => ('smtp.office365.com', 587),
  _ => (imapHost.replaceFirst('imap.', 'smtp.'), 465),
};

/// Boîte(s) mail complète(s) : lire, répondre, écrire, via IMAP/SMTP
/// (les protocoles standard du mail, utilisés par Outlook, Thunderbird…).
class MailModule extends HubModule {
  List<MailSummary> _cache = [];
  Future<List<MailSummary>>? _loading;
  final errors = <String, String>{};

  @override
  String get id => 'mail';
  @override
  String get name => 'Mails';
  @override
  String get description => 'Lire, répondre et écrire tes mails';
  @override
  IconData get icon => Icons.mail_rounded;
  @override
  Color get color => const Color(0xFFEA4335);
  @override
  ApiAccess get access => ApiAccess.official;

  List<String> get accounts => (store.getJson<List<dynamic>>('accounts') ?? const []).cast<String>();

  String hostOf(String email) => store.getJson<String>('host.$email') ?? imapHostFor(email);

  /// Boîte connectée avec « Se connecter avec Google ».
  bool isGoogle(String email) => store.getJson<bool>('google.$email') == true;

  Future<T> _withImap<T>(String email, Future<T> Function(ImapClient c) action) async {
    final client = ImapClient();
    try {
      if (isGoogle(email)) {
        final token = await GoogleAuth.accessToken(email);
        await client.connectToServer('imap.gmail.com', 993, isSecure: true);
        await client.authenticateWithOAuth2(email, token);
      } else {
        final pass = await store.readSecret('pw.$email');
        if (pass == null) throw 'Mot de passe manquant';
        await client.connectToServer(hostOf(email), 993, isSecure: true);
        await client.login(email, pass);
      }
      await client.selectInbox();
      return await action(client);
    } finally {
      try {
        await client.logout();
      } catch (_) {}
    }
  }

  Future<List<MailSummary>> _fetch(String email) => _withImap(email, (client) async {
    final r = await client.fetchRecentMessages(messageCount: 30, criteria: '(UID FLAGS BODY.PEEK[HEADER])');
    return [
      for (final m in r.messages.reversed)
        MailSummary(
          email,
          m.uid,
          m.from?.isNotEmpty == true
              ? (m.from!.first.personalName?.isNotEmpty == true ? m.from!.first.personalName! : m.from!.first.email)
              : '?',
          m.from?.firstOrNull?.email ?? '',
          m.decodeSubject() ?? '(sans objet)',
          m.decodeDate(),
          m.isSeen,
          m,
        ),
    ];
  });

  /// Contenu complet d'un mail (texte seulement).
  Future<String> readBody(MailSummary s) async => (await readMail(s)).text;

  /// Contenu complet d'un mail, avec ses pièces jointes (et le marque comme
  /// lu).
  Future<MailContent> readMail(MailSummary s) => _withImap(s.account, (client) async {
    final uid = s.uid;
    if (uid == null) return const MailContent('', []);
    final r = await client.uidFetchMessage(uid, 'BODY.PEEK[]');
    await client.uidMarkSeen(MessageSequence.fromId(uid, isUid: true));
    s.seen = true;
    badge.value = _cache.where((m) => !m.seen).length;
    final m = r.messages.firstOrNull;
    if (m == null) return const MailContent('', []);
    return MailContent(_textOf(m), attachmentsOf(m));
  });

  /// Les pièces jointes d'un mail (fichiers joints, et images ou documents
  /// « en ligne » qui ont un nom de fichier).
  static List<MailFile> attachmentsOf(MimeMessage m) {
    final out = <MailFile>[];
    final seen = <String>{};
    final infos = [
      ...m.findContentInfo(disposition: ContentDisposition.attachment),
      ...m.findContentInfo(disposition: ContentDisposition.inline),
    ];
    for (final info in infos) {
      final name = info.fileName?.trim() ?? '';
      if (info.fetchId.isEmpty || !seen.add(info.fetchId)) continue;
      // Le texte du mail lui-même n'est pas une pièce jointe.
      if (name.isEmpty && (info.isText || !info.isImage)) continue;
      out.add(
        MailFile(
          name.isEmpty ? 'image-${out.length + 1}.${info.mediaType?.sub.name ?? 'png'}' : name,
          info.size,
          () async {
            final data = m.getPart(info.fetchId)?.decodeContentBinary();
            if (data == null || data.isEmpty) throw 'Pièce jointe vide ou illisible';
            return data;
          },
        ),
      );
    }
    return out;
  }

  static String _textOf(MimeMessage m) {
    final text = m.decodeTextPlainPart();
    if (text != null && text.trim().isNotEmpty) return text.trim();
    final html = m.decodeTextHtmlPart() ?? '';
    return html
        .replaceAll(RegExp(r'<(style|script)[^>]*>.*?</\1>', dotAll: true), '')
        .replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</tr>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
        .trim();
  }

  /// Envoie un mail (nouveau ou réponse).
  Future<void> send({
    required String from,
    required String to,
    required String subject,
    required String body,
    MimeMessage? replyTo,
  }) async {
    final google = isGoogle(from);
    final pass = google ? await GoogleAuth.accessToken(from) : await store.readSecret('pw.$from');
    if (pass == null) throw 'Mot de passe manquant';
    final (host, port) = google ? ('smtp.gmail.com', 465) : smtpFor(hostOf(from));
    final message = MessageBuilder.buildSimpleTextMessage(
      MailAddress(null, from),
      to
          .split(RegExp(r'[,;]'))
          .map((e) => e.trim())
          .where((e) => e.contains('@'))
          .map((e) => MailAddress(null, e))
          .toList(),
      body,
      subject: subject,
      replyToMessage: replyTo,
    );
    final client = SmtpClient('mon-hub.local');
    try {
      await client.connectToServer(host, port, isSecure: port == 465);
      await client.ehlo();
      if (port != 465) {
        await client.startTls();
        await client.ehlo();
      }
      await client.authenticate(from, pass, google ? AuthMechanism.xoauth2 : AuthMechanism.login);
      await client.sendMessage(message);
    } finally {
      try {
        await client.quit();
      } catch (_) {}
    }
  }

  Future<List<MailSummary>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      errors.clear();
      final all = <MailSummary>[];
      await Future.wait(
        accounts.map((a) async {
          try {
            all.addAll(await _fetch(a));
          } catch (e) {
            errors[a] = '$e';
          }
        }),
      );
      all.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
      badge.value = all.where((m) => !m.seen).length;
      return _cache = all;
    }();
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'mails_lister',
      description: 'Derniers mails reçus (toutes les boîtes connectées).',
      params: {'nombre': ('integer', 'Combien (défaut 15)')},
      run: (a) async {
        final list = await load();
        return [
          for (final m in list.take((a['nombre'] as num?)?.toInt() ?? 15))
            {
              'boite': m.account,
              'uid': m.uid,
              'de': '${m.from} <${m.fromEmail}>',
              'objet': m.subject,
              'date': m.date,
              'lu': m.seen,
            },
        ];
      },
    ),
    HubTool(
      name: 'mail_lire',
      description: 'Texte complet d\'un mail (uid et boîte donnés par mails_lister).',
      params: {'boite': ('string', 'Adresse de la boîte'), 'uid': ('integer', 'uid du mail')},
      required: ['boite', 'uid'],
      run: (a) async {
        final m = (await load())
            .where((x) => x.account == a['boite'] && x.uid == (a['uid'] as num).toInt())
            .firstOrNull;
        if (m == null) throw 'Mail introuvable';
        final c = await readMail(m);
        if (c.files.isEmpty) return c.text;
        return {
          'texte': c.text,
          'pieces_jointes': [for (final f in c.files) f.name],
        };
      },
    ),
    HubTool(
      name: 'mail_envoyer',
      description: 'Envoie un mail depuis une des boîtes connectées.',
      params: {
        'a': ('string', 'Destinataire(s), séparés par des virgules'),
        'objet': ('string', 'Objet'),
        'texte': ('string', 'Contenu'),
        'de': ('string', 'Boîte d\'envoi (défaut : la première)'),
      },
      required: ['a', 'objet', 'texte'],
      run: (a) async {
        if (accounts.isEmpty) throw 'Aucune boîte mail connectée';
        await send(
          from: a['de'] as String? ?? accounts.first,
          to: a['a'] as String,
          subject: a['objet'] as String,
          body: a['texte'] as String,
        );
        return {'ok': true};
      },
    ),
  ];

  @override
  Future<List<HubNotification>> poll() async {
    if (accounts.isEmpty) return const [];
    final list = await load(force: true);
    store.changed();
    return [
      for (final m in list)
        if (!m.seen) ...[
          HubNotification(
            id: '${m.account}|${m.uid ?? m.date?.millisecondsSinceEpoch}|${m.subject}',
            title: '✉️ ${m.from}',
            body: m.subject,
          ),
          // Faux expéditeur (support@dlscord.com…) ou sujet piège.
          if (MailModule.scamOf(m) case final v when v.suspect)
            HubNotification(
              id: 'arnaque:mail:${m.account}|${m.uid}',
              title: '⚠️ Mail louche : ${m.from}',
              body: '${v.reasons.join(' ; ')}. N\'ouvre pas ses liens.',
            ),
        ],
    ];
  }

  /// Un mail qui se fait passer pour Discord, Roblox, Steam… (adresse de
  /// l'expéditeur sosie, ou sujet piège).
  static ScamVerdict scamOf(MailSummary m) {
    final domain = m.fromEmail.contains('@') ? m.fromEmail.split('@').last : '';
    final byDomain = domain.isEmpty ? const ScamVerdict(ScamLevel.ok, []) : ScamShield.checkUrl('https://$domain');
    final bySubject = ScamShield.checkMessage(m.subject);
    return byDomain.level.index >= bySubject.level.index ? byDomain : bySubject;
  }

  Future<void> _addAccount(BuildContext context) async {
    if (GoogleAuth.available) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Ajouter une boîte mail'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'google'),
              child: const ListTile(
                leading: Icon(Icons.g_mobiledata_rounded, size: 36),
                title: Text('Se connecter avec Google'),
                subtitle: Text('Gmail : une page Google s\'ouvre, tu acceptes, c\'est tout'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'other'),
              child: const ListTile(
                leading: Icon(Icons.alternate_email_rounded),
                title: Text('Autre boîte mail'),
                subtitle: Text('Orange, Free, SFR, iCloud… (adresse + mot de passe)'),
              ),
            ),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      if (choice == 'google') {
        try {
          final email = await GoogleAuth.signIn();
          await store.setJson('google.$email', true);
          await store.setJson('accounts', {...accounts, email}.toList());
          await load(force: true);
          store.changed();
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
        return;
      }
      return _addOther(context, gmailHelp: false);
    }
    return _addOther(context);
  }

  Future<void> _addOther(BuildContext context, {bool gmailHelp = true}) async {
    final open = !gmailHelp
        ? false
        : await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Boîte Gmail ?'),
              content: const Text(
                'Pour Gmail, Google demande un « mot de passe d\'application » (16 lettres) '
                'au lieu de ton vrai mot de passe. Je t\'ouvre la page qui le crée : '
                'donne-lui le nom « Mon Hub », copie le code, puis reviens ici.\n\n'
                '(La validation en 2 étapes doit être activée sur ton compte Google.)',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Pas Gmail')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ouvrir la page Google')),
              ],
            ),
          );
    if (!context.mounted) return;
    if (open == true) await openLink(context, 'https://myaccount.google.com/apppasswords');
    if (!context.mounted) return;
    final r = await askFields(
      context,
      title: 'Ajouter une boîte mail',
      labels: ['Adresse mail', 'Mot de passe (d\'application pour Gmail)', 'Serveur IMAP (laisser vide = auto)'],
      obscure: {1},
    );
    if (r == null || r[0].isEmpty || r[1].isEmpty) return;
    await store.writeSecret('pw.${r[0]}', r[1]);
    if (r[2].isNotEmpty) await store.setJson('host.${r[0]}', r[2]);
    await store.setJson('accounts', {...accounts, r[0]}.toList());
    await load(force: true);
    store.changed();
  }

  Widget _tile(BuildContext context, MailSummary m, {bool dense = false}) => ListTile(
    dense: dense,
    visualDensity: dense ? VisualDensity.compact : null,
    leading: HubAvatar(label: m.from, color: m.seen ? Colors.blueGrey : color, size: dense ? 30 : 40),
    title: Text(
      m.from,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontWeight: m.seen ? FontWeight.w500 : FontWeight.w800),
    ),
    subtitle: Text(
      m.subject,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: m.seen ? null : const TextStyle(fontWeight: FontWeight.w600),
    ),
    trailing: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (m.date != null) Text(timeAgo(m.date!), style: Theme.of(context).textTheme.labelSmall),
        if (!m.seen) ...[const SizedBox(height: 4), Dot(color: color)],
      ],
    ),
    onTap: () async {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _MailReadPage(module: this, mail: m),
        ),
      );
      store.changed();
    },
  );

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (accounts.isEmpty) {
        return EmptyHint(
          'Connecte ta boîte mail',
          icon: Icons.mail_outline_rounded,
          action: ('Ajouter', () => _addAccount(context)),
        );
      }
      return FutureBuilder(
        future: load(),
        initialData: _cache,
        builder: (context, snap) {
          final list = snap.data ?? [];
          if (list.isEmpty && snap.connectionState == ConnectionState.waiting) {
            return const LoadingHint();
          }
          if (list.isEmpty) return EmptyHint(errors.values.firstOrNull ?? 'Aucun mail');
          return ChatsSummary(
            color: color,
            items: [
              for (final m in list.take(8))
                ChatItem(
                  name: m.from,
                  preview: m.subject,
                  unread: !m.seen,
                  at: m.date,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _MailReadPage(module: this, mail: m),
                      ),
                    );
                    store.changed();
                  },
                ),
            ],
          );
        },
      );
    },
  );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => load(force: true).then((_) => store.changed()),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.manage_accounts_rounded),
          tooltip: 'Comptes',
          itemBuilder: (_) => [
            const PopupMenuItem(value: '+', child: Text('Ajouter une boîte mail')),
            for (final a in accounts) PopupMenuItem(value: a, child: Text('Retirer $a')),
          ],
          onSelected: (v) async {
            if (v == '+') return _addAccount(context);
            await store.writeSecret('pw.$v', null);
            await store.setJson('google.$v', null);
            await store.setJson('accounts', accounts.where((x) => x != v).toList());
            await load(force: true);
            store.changed();
          },
        ),
      ],
    ),
    floatingActionButton: Builder(
      builder: (context) => FloatingActionButton.extended(
        icon: const Icon(Icons.edit_rounded),
        label: const Text('Écrire'),
        onPressed: accounts.isEmpty
            ? () => _addAccount(context)
            : () => Navigator.push(context, MaterialPageRoute(builder: (_) => MailComposePage(module: this))),
      ),
    ),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (accounts.isEmpty) {
          return EmptyHint(
            'Ajoute ta boîte mail pour lire et envoyer tes mails ici.',
            icon: icon,
            action: ('Ajouter une boîte mail', () => _addAccount(context)),
          );
        }
        return FutureBuilder(
          future: load(),
          initialData: _cache,
          builder: (context, snap) => RefreshIndicator(
            onRefresh: () => load(force: true).then((_) => store.changed()),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 90),
              children: [
                for (final e in errors.entries) ErrorBanner('${e.key} : ${e.value}'),
                if (snap.connectionState == ConnectionState.waiting && _cache.isEmpty)
                  const Padding(padding: EdgeInsets.all(32), child: LoadingHint()),
                for (final m in snap.data ?? <MailSummary>[]) _tile(context, m),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _MailReadPage extends StatefulWidget {
  const _MailReadPage({required this.module, required this.mail});
  final MailModule module;
  final MailSummary mail;

  @override
  State<_MailReadPage> createState() => _MailReadPageState();
}

class _MailReadPageState extends State<_MailReadPage> {
  MailModule get module => widget.module;
  MailSummary get mail => widget.mail;

  /// Téléchargé une seule fois (avant : à chaque redessin de la page, une
  /// nouvelle connexion à la boîte mail).
  late Future<MailContent> _content = module.readMail(mail);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.reply_rounded),
        label: const Text('Répondre'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MailComposePage(
              module: module,
              from: mail.account,
              to: mail.fromEmail,
              subject: mail.subject.toLowerCase().startsWith('re:') ? mail.subject : 'Re: ${mail.subject}',
              replyTo: mail.header,
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
            children: [
              Text(mail.subject, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Row(
                children: [
                  HubAvatar(label: mail.from, color: module.color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(mail.from, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(mail.fromEmail, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (mail.date != null)
                    Text('${dayLabel(mail.date!)} ${hhmm(mail.date!)}', style: theme.textTheme.labelMedium),
                ],
              ),
              const Divider(height: 32),
              FutureBuilder(
                future: _content,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Column(
                      children: [
                        ErrorBanner('${snap.error}'),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Réessayer'),
                          onPressed: () => setState(() => _content = module.readMail(mail)),
                        ),
                      ],
                    );
                  }
                  if (!snap.hasData) return const LoadingHint();
                  final d = snap.data!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (d.files.isNotEmpty) ...[
                        Text(
                          '📎 ${d.files.length} pièce${d.files.length > 1 ? 's' : ''} jointe${d.files.length > 1 ? 's' : ''}',
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [for (final f in d.files) AttachmentChip(name: f.name, load: f.bytes)],
                        ),
                        const Divider(height: 28),
                      ],
                      SelectableText(
                        d.text.isEmpty ? '(mail vide)' : d.text,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MailComposePage extends StatefulWidget {
  const MailComposePage({super.key, required this.module, this.from, this.to = '', this.subject = '', this.replyTo});

  final MailModule module;
  final String? from;
  final String to;
  final String subject;
  final MimeMessage? replyTo;

  @override
  State<MailComposePage> createState() => _MailComposePageState();
}

class _MailComposePageState extends State<MailComposePage> {
  late String from = widget.from ?? widget.module.accounts.first;
  late final to = TextEditingController(text: widget.to);
  late final subject = TextEditingController(text: widget.subject);
  final body = TextEditingController();
  bool sending = false;

  Future<void> _send() async {
    if (!to.text.contains('@')) {
      showError(context, 'Ajoute au moins un destinataire');
      return;
    }
    setState(() => sending = true);
    try {
      await widget.module.send(
        from: from,
        to: to.text,
        subject: subject.text,
        body: body.text,
        replyTo: widget.replyTo,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mail envoyé ✉️')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, 'Envoi impossible : $e');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.replyTo == null ? 'Nouveau mail' : 'Répondre'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              icon: sending
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_rounded),
              label: const Text('Envoyer'),
              onPressed: sending ? null : _send,
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.module.accounts.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: from,
                  decoration: const InputDecoration(labelText: 'De'),
                  items: [for (final a in widget.module.accounts) DropdownMenuItem(value: a, child: Text(a))],
                  onChanged: (v) => setState(() => from = v ?? from),
                )
              else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_rounded),
                  title: Text('De : $from'),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: to,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'À (séparer par des virgules)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'Objet'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: body,
                autofocus: widget.replyTo != null,
                minLines: 12,
                maxLines: null,
                decoration: const InputDecoration(hintText: 'Ton message…'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
