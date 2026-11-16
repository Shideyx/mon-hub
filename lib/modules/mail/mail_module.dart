import 'package:enough_mail/enough_mail.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/hub_module.dart';
import '../../ui/widgets.dart';

class MailSummary {
  MailSummary(this.account, this.from, this.subject, this.date, this.seen);
  final String account;
  final String from;
  final String subject;
  final DateTime? date;
  final bool seen;
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
    'outlook.com' || 'hotmail.com' || 'hotmail.fr' || 'live.fr' || 'live.com' =>
      'outlook.office365.com',
    _ => 'imap.$domain',
  };
}

/// Boîte(s) mail via IMAP (protocole standard).
///
/// Gmail : active la validation en deux étapes puis crée un « mot de passe
/// d'application » sur https://myaccount.google.com/apppasswords et
/// utilise-le ici à la place de ton vrai mot de passe.
class MailModule extends HubModule {
  List<MailSummary> _cache = [];
  Future<List<MailSummary>>? _loading;
  final errors = <String, String>{};

  @override
  String get id => 'mail';
  @override
  String get name => 'Mails';
  @override
  String get description => 'Tes derniers mails (Gmail, Yahoo, Orange…)';
  @override
  IconData get icon => Icons.mail_outline;
  @override
  Color get color => const Color(0xFFEA4335);
  @override
  ApiAccess get access => ApiAccess.official;

  List<String> get accounts =>
      (store.getJson<List<dynamic>>('accounts') ?? const []).cast<String>();

  Future<List<MailSummary>> _fetch(String email) async {
    final pass = await store.readSecret('pw.$email');
    if (pass == null) throw 'Mot de passe manquant';
    final host = store.getJson<String>('host.$email') ?? imapHostFor(email);
    final client = ImapClient();
    try {
      await client.connectToServer(host, 993, isSecure: true);
      await client.login(email, pass);
      await client.selectInbox();
      final r = await client.fetchRecentMessages(
          messageCount: 15, criteria: '(FLAGS BODY.PEEK[HEADER])');
      return [
        for (final m in r.messages.reversed)
          MailSummary(
            email,
            m.from?.isNotEmpty == true
                ? (m.from!.first.personalName?.isNotEmpty == true
                    ? m.from!.first.personalName!
                    : m.from!.first.email)
                : '?',
            m.decodeSubject() ?? '(sans objet)',
            m.decodeDate(),
            m.isSeen,
          )
      ];
    } finally {
      try {
        await client.logout();
      } catch (_) {}
    }
  }

  Future<List<MailSummary>> load({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    return _loading = () async {
      errors.clear();
      final all = <MailSummary>[];
      await Future.wait(accounts.map((a) async {
        try {
          all.addAll(await _fetch(a));
        } catch (e) {
          errors[a] = '$e';
        }
      }));
      all.sort((a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
      return _cache = all;
    }();
  }

  Future<void> _addAccount(BuildContext context) async {
    final r = await askFields(context,
        title: 'Ajouter une boîte mail',
        labels: [
          'Adresse mail',
          'Mot de passe (d\'application pour Gmail)',
          'Serveur IMAP (laisser vide = auto)',
        ],
        obscure: {1});
    if (r == null || r[0].isEmpty || r[1].isEmpty) return;
    await store.writeSecret('pw.${r[0]}', r[1]);
    if (r[2].isNotEmpty) await store.setJson('host.${r[0]}', r[2]);
    await store.setJson('accounts', {...accounts, r[0]}.toList());
    await load(force: true);
    store.changed();
  }

  Widget _tile(MailSummary m, {bool dense = false}) => ListTile(
        dense: dense,
        leading: Icon(m.seen ? Icons.drafts_outlined : Icons.mark_email_unread,
            color: m.seen ? null : color),
        title: Text(m.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: m.seen ? null : const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
            '${m.from}${m.date == null ? '' : ' · ${dayLabel(m.date!)}'}'
            '${dense ? '' : '\n${m.account}'}',
            maxLines: dense ? 1 : 2),
      );

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (accounts.isEmpty) {
            return const EmptyHint('Connecte ta boîte mail', icon: Icons.add);
          }
          return FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) {
              final list = snap.data ?? [];
              if (list.isEmpty && snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (list.isEmpty) {
                return EmptyHint(errors.values.firstOrNull ?? 'Aucun mail');
              }
              final unread = list.where((m) => !m.seen).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text('$unread non lu(s)',
                        style: Theme.of(context).textTheme.labelLarge),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [for (final m in list.take(4)) _tile(m, dense: true)],
                    ),
                  ),
                ],
              );
            },
          );
        },
      );

  @override
  Widget buildPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(name), actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => load(force: true).then((_) => store.changed()),
          ),
        ]),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton(
            onPressed: () => _addAccount(context),
            child: const Icon(Icons.add),
          ),
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => FutureBuilder(
            future: load(),
            initialData: _cache,
            builder: (context, snap) => ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final a in accounts)
                  ListTile(
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(a),
                    subtitle: errors[a] == null ? null : Text(errors[a]!,
                        style: const TextStyle(color: Colors.red)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await store.writeSecret('pw.$a', null);
                        await store.setJson(
                            'accounts', accounts.where((x) => x != a).toList());
                        await load(force: true);
                        store.changed();
                      },
                    ),
                  ),
                const Divider(),
                for (final m in snap.data ?? <MailSummary>[]) _tile(m),
              ],
            ),
          ),
        ),
      );
}
