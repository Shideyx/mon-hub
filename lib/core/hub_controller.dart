import 'package:flutter/foundation.dart';

import 'hub_module.dart';
import 'module_store.dart';

/// Gère quels modules sont actifs et dans quel ordre ils s'affichent.
class HubController extends ChangeNotifier {
  HubController(this.available) {
    for (final m in available) {
      m.attach();
    }
    final prefs = ModuleStore.prefs;
    final savedOrder = prefs.getStringList('hub.order');
    final savedDisabled = prefs.getStringList('hub.disabled') ?? const [];
    final byId = {for (final m in available) m.id: m};
    _order = [
      ...?savedOrder?.where(byId.containsKey),
      // Les nouveaux modules apparaissent à la fin.
      ...available.map((m) => m.id).where((id) => !(savedOrder ?? []).contains(id)),
    ];
    _disabled = savedDisabled.toSet();
  }

  final List<HubModule> available;
  late List<String> _order;
  late Set<String> _disabled;

  HubModule _byId(String id) => available.firstWhere((m) => m.id == id);

  /// Tous les modules, dans l'ordre choisi.
  List<HubModule> get ordered => _order.map(_byId).toList();

  /// Modules actifs, dans l'ordre choisi.
  List<HubModule> get enabled =>
      ordered.where((m) => !_disabled.contains(m.id)).toList();

  bool isEnabled(HubModule m) => !_disabled.contains(m.id);

  void setEnabled(HubModule m, bool value) {
    value ? _disabled.remove(m.id) : _disabled.add(m.id);
    _save();
  }

  void reorder(int oldIndex, int newIndex) {
    final id = _order.removeAt(oldIndex);
    _order.insert(newIndex, id);
    _save();
  }

  void _save() {
    final prefs = ModuleStore.prefs;
    prefs.setStringList('hub.order', _order);
    prefs.setStringList('hub.disabled', _disabled.toList());
    notifyListeners();
  }
}
