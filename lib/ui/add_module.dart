import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/custom_modules.dart';
import '../core/hub_controller.dart';
import 'motion.dart';

/// La carte « + Ajouter un module », à la fin de l'accueil.
class AddModuleCard extends StatefulWidget {
  const AddModuleCard({super.key, required this.controller});
  final HubController controller;

  @override
  State<AddModuleCard> createState() => _AddModuleCardState();
}

class _AddModuleCardState extends State<AddModuleCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => AddModuleSheet.show(context, widget.controller),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: accent.withValues(alpha: hover ? 0.10 : 0.05),
            border: Border.all(color: accent.withValues(alpha: hover ? 0.55 : 0.28), width: 1.6),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: hover ? 0.25 : 0,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: hover ? 64 : 56,
                    height: hover ? 64 : 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [Color(0xFF6D4AFF), Color(0xFFE0457B)]),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF7C5CFF).withValues(alpha: hover ? 0.45 : 0.2),
                          blurRadius: hover ? 22 : 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.add_rounded, color: Colors.white, size: 32),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Ajouter un module', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'WhatsApp, Netflix, Pronote, ton site préféré…',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// « Ajouter un module » : catalogue en un clic, ou ton propre site, ou une
/// liste de liens. Tout reste sur ton PC.
class AddModuleSheet extends StatefulWidget {
  const AddModuleSheet({super.key, required this.controller});
  final HubController controller;

  static Future<void> show(BuildContext context, HubController controller) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AddModuleSheet(controller: controller),
  );

  @override
  State<AddModuleSheet> createState() => _AddModuleSheetState();
}

class _AddModuleSheetState extends State<AddModuleSheet> with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 3, vsync: this);
  final name = TextEditingController();
  final url = TextEditingController();
  String icon = 'public';
  int color = CustomModules.colors.first;
  String? error;
  final added = <String>{};

  @override
  void dispose() {
    tabs.dispose();
    name.dispose();
    url.dispose();
    super.dispose();
  }

  bool _has(String u) => widget.controller.available.any((m) => m is CustomWebModule && m.spec.url == u);

  Future<void> _add(CustomModuleSpec spec) async {
    await CustomModules.add(spec);
    widget.controller.add(spec.build());
    if (!mounted) return;
    setState(() => added.add(spec.url.isEmpty ? spec.name : spec.url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('« ${spec.name} » est sur ton accueil'), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _addOwn({required bool links}) async {
    final n = name.text.trim();
    final u = CustomModules.cleanUrl(url.text);
    if (n.isEmpty) return setState(() => error = 'Donne-lui un nom.');
    if (!links && u == null) return setState(() => error = 'Cette adresse ne marche pas (exemple : www.exemple.fr).');
    setState(() => error = null);
    await _add(
      CustomModuleSpec(
        id: CustomModules.newId(n),
        name: n,
        kind: links ? 'liens' : 'web',
        url: links ? '' : u!,
        icon: links && icon == 'public' ? 'link' : icon,
        color: color,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: math.min(MediaQuery.of(context).size.height * 0.85, 720),
        child: Column(
          children: [
            Text('Ajouter un module', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Il apparaît sur ton accueil, comme les autres (et Nexo sait l\'ouvrir).',
              style: theme.textTheme.bodySmall,
            ),
            TabBar(
              controller: tabs,
              tabs: const [
                Tab(icon: Icon(Icons.auto_awesome_rounded), text: 'Prêts à l\'emploi'),
                Tab(icon: Icon(Icons.public_rounded), text: 'Mon site'),
                Tab(icon: Icon(Icons.link_rounded), text: 'Mes liens'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [_catalog(context), _own(context, links: false), _own(context, links: true)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalog(BuildContext context) {
    final theme = Theme.of(context);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisExtent: 140,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: CustomModules.catalog.length,
      itemBuilder: (context, i) {
        final c = CustomModules.catalog[i];
        final done = added.contains(c.url) || _has(c.url);
        final col = Color(c.color);
        return EnterAnimation(
          index: i,
          step: 25,
          child: PressScale(
            child: Material(
              color: col.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: done
                    ? null
                    : () => _add(
                        CustomModuleSpec(
                          id: CustomModules.newId(c.name),
                          name: c.name,
                          kind: 'web',
                          url: c.url,
                          icon: c.icon,
                          color: c.color,
                          description: c.description,
                        ),
                      ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(11),
                              gradient: LinearGradient(colors: [col, Color.lerp(col, Colors.black, 0.3)!]),
                            ),
                            child: Icon(CustomModules.icons[c.icon], color: Colors.white, size: 20),
                          ),
                          const Spacer(),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (w, a) => ScaleTransition(scale: a, child: w),
                            child: Icon(
                              done ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                              key: ValueKey(done),
                              color: done ? Colors.green : col,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Flexible(
                        child: Text(
                          c.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _own(BuildContext context, {required bool links}) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Aperçu de la carte, en direct.
        Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 260,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Color(color).withValues(alpha: 0.1),
              border: Border.all(color: Color(color).withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(colors: [Color(color), Color.lerp(Color(color), Colors.black, 0.3)!]),
                  ),
                  child: Icon(CustomModules.icons[icon], color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ListenableBuilder(
                    listenable: name,
                    builder: (context, _) => Text(
                      name.text.trim().isEmpty ? (links ? 'Mes liens' : 'Mon site') : name.text.trim(),
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Nom', prefixIcon: Icon(Icons.edit_rounded)),
        ),
        if (!links) ...[
          const SizedBox(height: 12),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Adresse du site',
              hintText: 'www.exemple.fr',
              prefixIcon: Icon(Icons.public_rounded),
            ),
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Text('Icône', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in CustomModules.icons.entries)
              ChoiceChip(
                label: Icon(e.value, size: 18),
                selected: icon == e.key,
                onSelected: (_) => setState(() => icon = e.key),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Couleur', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in CustomModules.colors)
              GestureDetector(
                onTap: () => setState(() => color = c),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: color == c ? 34 : 28,
                  height: color == c ? 34 : 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: color == c ? theme.colorScheme.onSurface : Colors.transparent, width: 2),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: Text(links ? 'Créer ma liste de liens' : 'Ajouter ce site'),
          onPressed: () => _addOwn(links: links),
        ),
        const SizedBox(height: 8),
        Text(
          links
              ? 'Une carte où tu ranges tes liens (cours, outils, jeux…).'
              : 'Le site s\'ouvre dans Mon Hub et ta connexion est gardée. Seuls les sites web (https) sont acceptés.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
