import 'package:flutter/foundation.dart';

import '../../core/hub_files.dart';
import 'games_deals.dart';
import 'money_rules.dart';

/// Un abonnement (trouvé dans les mails ou ajouté à la main).
class Subscription {
  Subscription({
    required this.service,
    this.price,
    this.yearly = false,
    this.next,
    this.trial = false,
    this.cancelled = false,
    this.cancelUrl = '',
    this.manual = false,
  });

  String service;
  double? price;
  bool yearly;
  DateTime? next;
  bool trial;
  bool cancelled;
  String cancelUrl;
  bool manual;

  double get perMonth => cancelled ? 0 : MoneyRules.monthly(price, yearly);

  /// Le prochain prélèvement (passé : on avance d'un mois ou d'un an).
  DateTime? nextFrom(DateTime now) {
    var d = next;
    if (d == null || cancelled) return d;
    final today = DateTime(now.year, now.month, now.day);
    var guard = 0;
    while (d!.isBefore(today) && !trial && guard++ < 60) {
      d = yearly ? DateTime(d.year + 1, d.month, d.day) : DateTime(d.year, d.month + 1, d.day);
    }
    return d;
  }

  Map<String, Object?> toJson() => {
    'service': service,
    'prix': price,
    'annuel': yearly,
    'prochain': next?.toIso8601String(),
    'essai': trial,
    'resilie': cancelled,
    'resilier': cancelUrl,
    'main': manual,
  };

  static Subscription fromJson(Map m) => Subscription(
    service: '${m['service']}',
    price: (m['prix'] as num?)?.toDouble(),
    yearly: m['annuel'] == true,
    next: DateTime.tryParse('${m['prochain']}'),
    trial: m['essai'] == true,
    cancelled: m['resilie'] == true,
    cancelUrl: '${m['resilier'] ?? ''}',
    manual: m['main'] == true,
  );
}

/// Un colis suivi.
class Parcel {
  Parcel({
    required this.carrier,
    required this.number,
    required this.status,
    this.link = '',
    this.shop = '',
    DateTime? updated,
  }) : updated = updated ?? DateTime.now();

  String carrier;
  String number;
  String status;
  String link;
  String shop;
  DateTime updated;

  String get key => number.isNotEmpty ? '$carrier:$number' : 'lien:$link';

  Map<String, Object> toJson() => {
    'transporteur': carrier,
    'numero': number,
    'etat': status,
    'lien': link,
    'boutique': shop,
    'maj': updated.toIso8601String(),
  };

  static Parcel fromJson(Map m) => Parcel(
    carrier: '${m['transporteur']}',
    number: '${m['numero'] ?? ''}',
    status: '${m['etat']}',
    link: '${m['lien'] ?? ''}',
    shop: '${m['boutique'] ?? ''}',
    updated: DateTime.tryParse('${m['maj']}'),
  );
}

/// Les données de « Mon argent » (fichier chiffré `argent.json`).
class MoneyStore extends ChangeNotifier {
  MoneyStore();

  final _file = JsonFile<Map<String, dynamic>>(
    'argent.json',
    empty: () => {},
    decode: (j) => j is Map ? j.cast<String, dynamic>() : {},
    encode: (v) => v,
  );

  List<Subscription> subs = [];
  List<Parcel> parcels = [];
  List<FreeGame> free = [];
  List<SteamDeal> deals = [];
  List<String> seenMails = [];
  String steam = '';
  DateTime? lastMails;
  DateTime? lastEpic;
  DateTime? lastSteam;

  Future<void> load() async {
    if (!await _file.reload() && subs.isNotEmpty) return;
    final v = _file.value;
    List<Map> list(String k) => [
      for (final e in (v[k] as List?) ?? const [])
        if (e is Map) e,
    ];
    subs = list('abonnements').map(Subscription.fromJson).toList();
    parcels = list('colis').map(Parcel.fromJson).toList();
    free = list('gratuits').map(FreeGame.fromJson).toList();
    deals = list('promos').map(SteamDeal.fromJson).toList();
    seenMails = [for (final e in (v['vus'] as List?) ?? const []) '$e'];
    steam = '${v['steam'] ?? ''}';
    lastMails = DateTime.tryParse('${v['mails']}');
    lastEpic = DateTime.tryParse('${v['epic']}');
    lastSteam = DateTime.tryParse('${v['steam_maj']}');
    notifyListeners();
  }

  Future<void> save() async {
    if (seenMails.length > 600) seenMails = seenMails.sublist(seenMails.length - 600);
    await _file.save({
      'abonnements': [for (final s in subs) s.toJson()],
      'colis': [for (final p in parcels) p.toJson()],
      'gratuits': [for (final g in free) g.toJson()],
      'promos': [for (final d in deals) d.toJson()],
      'vus': seenMails,
      'steam': steam,
      'mails': lastMails?.toIso8601String(),
      'epic': lastEpic?.toIso8601String(),
      'steam_maj': lastSteam?.toIso8601String(),
    });
    notifyListeners();
  }

  /// Tient compte d'un mail d'abonnement (le plus récent l'emporte).
  void applySub(SubFinding f, DateTime mailDate) {
    final s = subs.where((x) => x.service == f.service).firstOrNull;
    if (s == null) {
      if (f.kind == 'resiliation') return;
      subs.add(
        Subscription(
          service: f.service,
          price: f.price,
          yearly: f.yearly,
          next: f.date,
          trial: f.kind == 'essai',
          cancelUrl: f.cancel,
        ),
      );
      return;
    }
    if (s.manual) return;
    if (f.kind == 'resiliation') {
      s
        ..cancelled = true
        ..next = f.date ?? s.next;
      return;
    }
    s
      ..cancelled = false
      ..trial = f.kind == 'essai'
      ..price = f.price ?? s.price
      ..yearly = f.yearly || s.yearly
      ..next = f.date ?? s.next;
    if (s.cancelUrl.isEmpty) s.cancelUrl = f.cancel;
  }

  /// Tient compte d'un mail de colis (l'état ne recule jamais).
  void applyParcel(ParcelFinding f) {
    final key = f.number.isNotEmpty ? '${f.carrier}:${f.number}' : 'lien:${f.link}';
    final p = parcels.where((x) => x.key == key).firstOrNull;
    if (p == null) {
      parcels.insert(0, Parcel(carrier: f.carrier, number: f.number, status: f.status, link: f.link, shop: f.shop));
      if (parcels.length > 40) parcels.removeRange(40, parcels.length);
      return;
    }
    if (MoneyRules.later(p.status, f.status)) {
      p
        ..status = f.status
        ..updated = DateTime.now();
    }
  }

  /// Total par mois (abonnements actifs et essais qui vont devenir payants).
  double get monthly => subs.fold(0.0, (t, s) => t + s.perMonth);

  /// Les colis pas encore arrivés (ou livrés depuis moins de 3 jours).
  List<Parcel> activeParcels(DateTime now) => [
    for (final p in parcels)
      if (p.status != 'livre' || now.difference(p.updated).inDays < 3) p,
  ];
}
