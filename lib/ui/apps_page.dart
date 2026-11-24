import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/pc_apps.dart';
import 'hud/hud.dart';

/// **Mes applis** : toutes les applis du PC (celles du menu Démarrer), à
/// lancer d'un clic depuis Mon Hub. Clic droit (ou appui long) : épingler.
class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(PcApps.instance.load());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _launch(PcApp a) async {
    final ok = await PcApps.instance.launch(a);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('Windows n\'a pas pu ouvrir « ${a.name} ».')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    if (!PcApps.supported) return const HudEmpty('Les applis du PC sont sur la version Windows de Mon Hub.');
    return ListenableBuilder(
      listenable: PcApps.instance,
      builder: (context, _) {
        final p = PcApps.instance;
        final list = p.search(_q.text, max: 400);
        final pinned = p.pinned;
        final frequent = _q.text.isEmpty ? p.frequent(max: 8).where((a) => !p.isPinned(a)).toList() : const <PcApp>[];
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TOUT LE MENU DÉMARRER // ${p.apps.length} APPLIS', style: hudLabel(context)),
                    const SizedBox(height: 6),
                    Text('MES APPLIS', style: hudTitle(context, size: 34)),
                    const SizedBox(height: 14),
                    HudPanel(
                      hot: true,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                      child: Row(
                        children: [
                          Text(
                            '>_',
                            style: hudMono(context, color: c.accentText, weight: FontWeight.w700),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _q,
                              autofocus: true,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (_) {
                                if (list.isNotEmpty) unawaited(_launch(list.first));
                              },
                              style: hudMono(context, size: 15),
                              decoration: const InputDecoration(
                                hintText: 'Tape le nom d\'une appli, Entrée pour l\'ouvrir',
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                              ),
                            ),
                          ),
                          if (p.loading)
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          IconButton(
                            tooltip: 'Relire la liste',
                            icon: Icon(Icons.refresh_rounded, color: c.muted),
                            onPressed: () => p.load(force: true),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Partout sur le PC : Ctrl + Alt + Espace, puis le nom de l\'appli.',
                      style: hudLabel(context, size: 10, color: c.dim),
                    ),
                  ],
                ),
              ),
            ),
            if (pinned.isNotEmpty && _q.text.isEmpty) ..._group(context, 'Épinglées', pinned),
            if (frequent.isNotEmpty) ..._group(context, 'Souvent utilisées', frequent),
            if (p.error != null && p.apps.isEmpty)
              SliverToBoxAdapter(child: HudEmpty('Je n\'ai pas pu lire la liste des applis : ${p.error}')),
            ..._group(context, _q.text.isEmpty ? 'Toutes' : 'Résultats', list),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        );
      },
    );
  }

  List<Widget> _group(BuildContext context, String title, List<PcApp> apps) => [
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      sliver: SliverToBoxAdapter(child: HudSectionLabel(title)),
    ),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 128,
          mainAxisExtent: 112,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: apps.length,
        itemBuilder: (context, i) => AppTile(app: apps[i], onOpen: _launch),
      ),
    ),
  ];
}

/// Une appli : hexagone + nom. Clic : ouvrir ; clic droit / appui long :
/// épingler.
class AppTile extends StatelessWidget {
  const AppTile({super.key, required this.app, required this.onOpen, this.small = false});
  final PcApp app;
  final ValueChanged<PcApp> onOpen;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = HudColors.of(context);
    final p = PcApps.instance;
    final pinned = p.isPinned(app);
    return Tooltip(
      message: '${app.name}\nClic droit : ${pinned ? 'désépingler' : 'épingler'}',
      waitDuration: const Duration(milliseconds: 700),
      child: GestureDetector(
        onSecondaryTap: () => p.togglePin(app),
        child: InkWell(
          onTap: () => onOpen(app),
          onLongPress: () => p.togglePin(app),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    HexAvatar(app.initials, size: small ? 40 : 50, color: HexAvatar.colorFor(app.name)),
                    if (pinned)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Icon(Icons.push_pin_rounded, size: 14, color: c.accentText),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  app.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: small ? 11 : 12, height: 1.2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
