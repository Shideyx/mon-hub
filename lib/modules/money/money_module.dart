import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/browser.dart';
import '../../core/hub_module.dart';
import '../../ui/summary.dart';
import '../../ui/widgets.dart';
import '../mail/mail_module.dart';
import 'games_deals.dart';
import 'money_rules.dart';
import 'money_store.dart';

/// **Mon argent** : abonnements et essais gratuits (repérés dans les mails,
/// rappel la veille du prélèvement), colis (suivi d'après les mails des
/// boutiques et transporteurs), jeux gratuits (Epic) et promos de ta liste
/// de souhaits Steam. Tout est lu sur l'appareil, sans IA.
class MoneyModule extends HubModule {
  MoneyModule({required this.mail});

  final MailModule mail;
  final data = MoneyStore();

  @override
  String get id => 'argent';
  @override
  String get name => 'Mon argent';
  @override
  String get description => 'Abonnements et essais gratuits, colis, jeux gratuits et promos';
  @override
  IconData get icon => Icons.savings_rounded;
  @override
  Color get color => const Color(0xFF16A34A);
  @override
  ApiAccess get access => ApiAccess.local;

  bool _scanning = false;

  /// Lit les nouveaux mails (abonnements, colis). [force] : même si c'est récent.
  Future<int> scanMails({bool force = false}) async {
    await data.load();
    final now = DateTime.now();
    if (_scanning || mail.accounts.isEmpty) return 0;
    if (!force && data.lastMails != null && now.difference(data.lastMails!) < const Duration(minutes: 30)) return 0;
    _scanning = true;
    var found = 0;
    try {
      final list = await mail.load();
      var reads = 0;
      for (final m in list.take(80)) {
        final key = '${m.account}|${m.uid ?? m.date?.millisecondsSinceEpoch}|${m.subject.hashCode}';
        if (data.seenMails.contains(key)) continue;
        data.seenMails.add(key);
        final subject = foldText(m.subject);
        final maybeSub = MoneyRules.serviceOf(m.fromEmail, m.subject) != null;
        final maybeParcel = RegExp(r'colis|livr|exped|suivi|track|ship|deliver|commande|order|point relais|retrait')
            .hasMatch(subject);
        if (!maybeSub && !maybeParcel) continue;
        if (reads >= 15) {
          // Trop d'un coup : on le relira la prochaine fois.
          data.seenMails.remove(key);
          continue;
        }
        reads++;
        String text = '';
        try {
          text = (await mail.readMail(m)).text;
        } catch (_) {}
        final date = m.date ?? now;
        if (maybeSub) {
          final f = MoneyRules.subscription(fromEmail: m.fromEmail, subject: m.subject, text: text, mailDate: date);
          if (f != null) {
            data.applySub(f, date);
            found++;
          }
        }
        if (maybeParcel) {
          final p = MoneyRules.parcel(fromEmail: m.fromEmail, fromName: m.from, subject: m.subject, text: text);
          if (p != null) {
            data.applyParcel(p);
            found++;
          }
        }
      }
      data.lastMails = now;
      await data.save();
    } catch (_) {
      // Boîte injoignable : on réessaiera.
    } finally {
      _scanning = false;
    }
    return found;
  }

  Future<void> refreshGames({bool force = false}) async {
    await data.load();
    final now = DateTime.now();
    if (force || data.lastEpic == null || now.difference(data.lastEpic!) > const Duration(hours: 6)) {
      try {
        data.free = await GameDeals.epic();
        data.lastEpic = now;
      } catch (_) {}
    }
    final id = data.steam;
    if (id.isNotEmpty &&
        (force || data.lastSteam == null || now.difference(data.lastSteam!) > const Duration(hours: 12))) {
      try {
        data.deals = await GameDeals.steamDeals(id);
        data.lastSteam = now;
      } catch (_) {}
    }
    await data.save();
  }

  /// Les rappels à faire maintenant (les doublons sont filtrés par le centre de notifications).
  List<HubNotification> reminders(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    String ymd(DateTime d) => '${d.year}-${d.month}-${d.day}';
    return [
      for (final s in data.subs)
        if (!s.cancelled)
          if (s.nextFrom(now) case final d? when !d.isBefore(today) && d.difference(today).inDays <= 1 && now.hour >= 9)
            HubNotification(
              id: 'abo:${s.service}:${ymd(d)}',
              title: s.trial
                  ? '⏰ Ton essai ${s.service} devient payant ${d == today ? 'aujourd\'hui' : 'demain'}'
                  : '💳 ${s.service} : prélèvement ${d == today ? 'aujourd\'hui' : 'demain'}',
              body: [
                if (s.price != null) MoneyRules.euros(s.price!),
                s.trial ? 'Résilie avant si tu ne veux pas payer.' : 'Pas d\'action à faire si tu le gardes.',
              ].join(' · '),
            ),
      for (final p in data.activeParcels(now))
        if (const {'en_livraison', 'a_retirer', 'livre'}.contains(p.status))
          HubNotification(
            id: 'colis:${p.key}:${p.status}',
            title: switch (p.status) {
              'a_retirer' => '📦 Colis ${p.shop} à retirer',
              'en_livraison' => '🚚 Colis ${p.shop} livré aujourd\'hui',
              _ => '✅ Colis ${p.shop} livré',
            },
            body: p.number.isEmpty ? p.carrier : '${p.carrier} · ${p.number}',
          ),
      for (final g in data.free)
        if (g.now && (g.to == null || g.to!.isAfter(now)))
          HubNotification(
            id: 'epic:${g.id}:${g.from == null ? '' : ymd(g.from!)}',
            title: '🎮 Gratuit sur Epic : ${g.title}',
            body: g.to == null ? 'À récupérer sur l\'Epic Games Store.' : 'Jusqu\'au ${g.to!.day}/${g.to!.month}.',
          ),
      for (final d in data.deals)
        HubNotification(
          id: 'steam:${d.appId}:${d.discount}',
          title: '🔥 -${d.discount} % sur ${d.name}',
          body: '${d.price} au lieu de ${d.before} (liste de souhaits Steam)',
        ),
    ];
  }

  @override
  Future<List<HubNotification>> poll() async {
    await scanMails();
    await refreshGames();
    final now = DateTime.now();
    badge.value = data.activeParcels(now).where((p) => p.status == 'a_retirer').length;
    return reminders(now);
  }

  @override
  List<HubTool> get tools => [
    HubTool(
      name: 'argent_abonnements',
      description:
          'Abonnements et essais gratuits de la personne (repérés dans ses mails ou ajoutés à la main) : prix, prochain '
          'prélèvement, total par mois, lien pour résilier.',
      run: (a) async {
        await data.load();
        final now = DateTime.now();
        return {
          'total_par_mois': MoneyRules.euros(data.monthly),
          'abonnements': [
            for (final s in data.subs)
              {
                'service': s.service,
                if (s.price != null) 'prix': '${MoneyRules.euros(s.price!)}${s.yearly ? ' par an' : ' par mois'}',
                if (s.nextFrom(now) != null) 'prochain': s.nextFrom(now)!.toIso8601String().substring(0, 10),
                if (s.trial) 'essai_gratuit': true,
                if (s.cancelled) 'resilie': true,
                if (s.cancelUrl.isNotEmpty) 'resilier': s.cancelUrl,
              },
          ],
        };
      },
    ),
    HubTool(
      name: 'argent_colis',
      description: 'Colis en cours (d\'après les mails des boutiques et transporteurs) : état, transporteur, numéro, lien de suivi.',
      run: (a) async {
        await data.load();
        return [
          for (final p in data.activeParcels(DateTime.now()))
            {
              'boutique': p.shop,
              'transporteur': p.carrier,
              'numero': p.number,
              'etat': MoneyRules.statusLabels[p.status] ?? p.status,
              'suivi': p.link,
            },
        ];
      },
    ),
    HubTool(
      name: 'argent_jeux',
      description:
          'Jeux gratuits sur l\'Epic Games Store (maintenant et bientôt) et promos de la liste de souhaits Steam.',
      run: (a) async {
        await refreshGames();
        return {
          'gratuits': [for (final g in data.free) g.toJson()],
          'promos_steam': [for (final d in data.deals) d.toJson()],
        };
      },
    ),
  ];

  @override
  Widget buildSummary(BuildContext context) => ListenableBuilder(
    listenable: data,
    builder: (context, _) {
      final now = DateTime.now();
      final parcels = data.activeParcels(now).where((p) => p.status != 'livre').length;
      final games = data.free.where((g) => g.now).length;
      if (data.subs.isEmpty && parcels == 0 && games == 0) {
        return const EmptyHint('Tes abonnements, colis et jeux gratuits apparaîtront ici', icon: Icons.savings_rounded);
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.autorenew_rounded,
                value: MoneyRules.euros(data.monthly).replaceAll(',00', ''),
                label: 'par mois',
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatTile(
                icon: Icons.local_shipping_rounded,
                value: '$parcels',
                label: parcels > 1 ? 'colis en route' : 'colis en route',
                color: const Color(0xFFEA580C),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StatTile(
                icon: Icons.sports_esports_rounded,
                value: '$games',
                label: games > 1 ? 'jeux gratuits' : 'jeu gratuit',
                color: const Color(0xFF7C3AED),
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget buildPage(BuildContext context) => _MoneyPage(module: this);
}

class _MoneyPage extends StatefulWidget {
  const _MoneyPage({required this.module});
  final MoneyModule module;

  @override
  State<_MoneyPage> createState() => _MoneyPageState();
}

class _MoneyPageState extends State<_MoneyPage> {
  MoneyModule get m => widget.module;
  MoneyStore get data => m.data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(data.load());
  }

  String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  Future<void> _scan() async {
    setState(() => _busy = true);
    final n = await m.scanMails(force: true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          m.mail.accounts.isEmpty
              ? 'Connecte d\'abord ta boîte mail (module Mails) pour que je trouve tes abonnements et colis.'
              : n == 0
              ? 'Rien de nouveau dans tes derniers mails.'
              : '$n nouveauté${n > 1 ? 's' : ''} trouvée${n > 1 ? 's' : ''} dans tes mails.',
        ),
      ),
    );
  }

  Future<void> _editSub([Subscription? s]) async {
    final name = TextEditingController(text: s?.service ?? '');
    final price = TextEditingController(text: s?.price?.toStringAsFixed(2).replaceAll('.', ',') ?? '');
    var yearly = s?.yearly ?? false;
    var trial = s?.trial ?? false;
    DateTime? next = s?.next;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(s == null ? 'Ajouter un abonnement' : s.service),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Service (ex. Netflix)'),
              ),
              TextField(
                controller: price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Prix (€)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Payé une fois par an'),
                value: yearly,
                onChanged: (v) => set(() => yearly = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Essai gratuit'),
                value: trial,
                onChanged: (v) => set(() => trial = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(next == null ? 'Prochain prélèvement : ?' : 'Prochain prélèvement : ${_date(next!)}'),
                trailing: const Icon(Icons.event_rounded),
                onTap: () async {
                  final d = await showDatePicker(
                    context: c,
                    initialDate: next ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 400)),
                    lastDate: DateTime.now().add(const Duration(days: 800)),
                  );
                  if (d != null) set(() => next = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final p = double.tryParse(price.text.replaceAll(',', '.').replaceAll('€', '').trim());
    final known = knownServices.where((k) => foldText(k.name) == foldText(name.text.trim())).firstOrNull;
    final target = s ?? Subscription(service: name.text.trim(), cancelUrl: known?.cancel ?? '');
    target
      ..service = name.text.trim()
      ..price = p
      ..yearly = yearly
      ..trial = trial
      ..next = next
      ..manual = true;
    if (s == null) data.subs.add(target);
    await data.save();
  }

  Widget _subs() {
    final now = DateTime.now();
    final list = [...data.subs]
      ..sort((a, b) => (a.nextFrom(now) ?? DateTime(9999)).compareTo(b.nextFrom(now) ?? DateTime(9999)));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.autorenew_rounded),
            title: Text('${MoneyRules.euros(data.monthly)} par mois'),
            subtitle: Text(
              'soit ${MoneyRules.euros(data.monthly * 12)} par an · rappel la veille de chaque prélèvement',
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: _busy
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.mark_email_read_rounded),
              label: const Text('Chercher dans mes mails'),
            ),
            OutlinedButton.icon(
              onPressed: () => _editSub(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter à la main'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Aucun abonnement trouvé pour l\'instant. Je lis tes mails de Spotify, Netflix, Deezer, Disney+, '
              'Game Pass, Nitro, Apple, Google Play… et je te préviens la veille de chaque prélèvement ou fin d\'essai.',
            ),
          ),
        for (final s in list)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(s.service.characters.first)),
              title: Text(s.service + (s.trial ? ' · essai gratuit' : '') + (s.cancelled ? ' · résilié' : '')),
              subtitle: Text(
                [
                  if (s.price != null) '${MoneyRules.euros(s.price!)}${s.yearly ? ' / an' : ' / mois'}',
                  if (s.nextFrom(now) case final d?)
                    '${s.cancelled
                        ? 'jusqu\'au'
                        : s.trial
                        ? 'payant le'
                        : 'prochain le'} ${_date(d)}',
                ].join(' · '),
              ),
              trailing: Wrap(
                children: [
                  if (s.cancelUrl.isNotEmpty && !s.cancelled)
                    TextButton(onPressed: () => Browser.open(s.cancelUrl), child: const Text('Résilier')),
                  IconButton(tooltip: 'Modifier', icon: const Icon(Icons.edit_rounded), onPressed: () => _editSub(s)),
                  IconButton(
                    tooltip: 'Retirer',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      data.subs.remove(s);
                      await data.save();
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _addParcel() async {
    final c = TextEditingController();
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suivre un colis'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Numéro de suivi'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Ajouter')),
        ],
      ),
    );
    if (n == null || n.isEmpty) return;
    final f = MoneyRules.parcel(fromEmail: '', fromName: 'colis', subject: 'colis expédié', text: n.toUpperCase());
    data.applyParcel(
      f ??
          ParcelFinding(
            carrier: 'Colis',
            number: n,
            status: 'expedie',
            link: 'https://www.google.com/search?q=suivi+colis+$n',
            shop: 'Colis',
          ),
    );
    await data.save();
  }

  Widget _parcels() {
    final now = DateTime.now();
    final list = data.activeParcels(now);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.mark_email_read_rounded),
              label: const Text('Chercher dans mes mails'),
            ),
            OutlinedButton.icon(
              onPressed: _addParcel,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter un numéro'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Aucun colis en cours. Quand une boutique ou un transporteur t\'écrit (Colissimo, Chronopost, '
              'Mondial Relay, UPS, DHL, Amazon…), je le suis et te préviens quand il arrive ou qu\'il est à retirer.',
            ),
          ),
        for (final p in list)
          Card(
            child: ListTile(
              leading: Icon(switch (p.status) {
                'livre' => Icons.check_circle_rounded,
                'a_retirer' => Icons.storefront_rounded,
                'en_livraison' => Icons.local_shipping_rounded,
                _ => Icons.inventory_2_rounded,
              }, color: p.status == 'a_retirer' ? Colors.orange : null),
              title: Text('${p.shop} · ${MoneyRules.statusLabels[p.status] ?? p.status}'),
              subtitle: Text([p.carrier, if (p.number.isNotEmpty) p.number].join(' · ')),
              trailing: Wrap(
                children: [
                  if (p.link.isNotEmpty) TextButton(onPressed: () => Browser.open(p.link), child: const Text('Suivre')),
                  IconButton(
                    tooltip: 'Reçu, retirer',
                    icon: const Icon(Icons.done_all_rounded),
                    onPressed: () async {
                      data.parcels.remove(p);
                      await data.save();
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _steam() async {
    final c = TextEditingController(text: data.steam);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ma liste de souhaits Steam'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Colle le lien de ton profil Steam (ex. https://steamcommunity.com/id/monpseudo). Ta liste de souhaits '
              'doit être publique (Steam → Modifier le profil → Paramètres de confidentialité).',
            ),
            TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Profil Steam'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (v == null) return;
    setState(() => _busy = true);
    String? id;
    try {
      id = v.isEmpty ? '' : await GameDeals.steamId(v);
    } catch (_) {}
    if (!mounted) return;
    if (id == null) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profil Steam introuvable : vérifie le lien.')));
      return;
    }
    data.steam = id;
    data.deals = [];
    await data.save();
    await m.refreshGames(force: true);
    if (mounted) setState(() => _busy = false);
  }

  Widget _games() {
    final theme = Theme.of(context);
    final now = data.free.where((g) => g.now).toList();
    final soon = data.free.where((g) => !g.now).toList();
    Widget game(FreeGame g) => Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Browser.open(g.url),
        child: SizedBox(
          width: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (g.image.isNotEmpty)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    g.image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.title, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      g.now
                          ? (g.to == null ? 'Gratuit maintenant' : 'Gratuit jusqu\'au ${_date(g.to!.toLocal())}')
                          : (g.from == null ? 'Bientôt gratuit' : 'Gratuit à partir du ${_date(g.from!.toLocal())}'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: Text('Gratuits sur Epic Games', style: theme.textTheme.titleMedium)),
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      await m.refreshGames(force: true);
                      if (mounted) setState(() => _busy = false);
                    },
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (data.free.isEmpty) const Text('Rien pour l\'instant (ou pas d\'internet).'),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final g in now) game(g)]),
        if (soon.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Bientôt', style: theme.textTheme.titleSmall),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final g in soon) game(g)]),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Text('Promos de ma liste de souhaits Steam', style: theme.textTheme.titleMedium)),
            TextButton.icon(
              onPressed: _busy ? null : _steam,
              icon: const Icon(Icons.link_rounded),
              label: Text(data.steam.isEmpty ? 'Relier Steam' : 'Changer'),
            ),
          ],
        ),
        if (data.steam.isEmpty)
          const Text(
            'Relie ton profil Steam : je te préviens quand un jeu de ta liste de souhaits est en promo (-20 % ou plus).',
          )
        else if (data.deals.isEmpty)
          const Text('Aucun jeu de ta liste en promo pour l\'instant.'),
        for (final d in data.deals)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF16A34A),
              foregroundColor: Colors.white,
              child: Text('-${d.discount}'),
            ),
            title: Text(d.name),
            subtitle: Text('${d.price} au lieu de ${d.before}'),
            onTap: () => Browser.open(d.url),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mon argent'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.autorenew_rounded), text: 'Abonnements'),
              Tab(icon: Icon(Icons.local_shipping_rounded), text: 'Colis'),
              Tab(icon: Icon(Icons.sports_esports_rounded), text: 'Jeux'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: data,
          builder: (context, _) => TabBarView(children: [_subs(), _parcels(), _games()]),
        ),
      ),
    );
  }
}
