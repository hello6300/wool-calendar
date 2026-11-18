import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../state/wool_store.dart';
import 'platform_name_dialog.dart';

/// 常用平台管理：新增 / 重命名 / 删除。
///
/// 这些只影响编辑器里的快捷 chip，**不改任何历史记录**的 platform 字段。
/// 删除时也照此说明，避免用户误以为会改动旧账。
class PlatformSettingsPage extends StatelessWidget {
  const PlatformSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<WoolStore>(
      builder: (context, store, _) {
        final platforms = store.platforms;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.platformsTitle),
            actions: <Widget>[
              IconButton(
                key: const Key('addPlatformAction'),
                tooltip: l10n.addPlatform,
                icon: const Icon(Icons.add),
                onPressed: () => _add(context, store),
              ),
            ],
          ),
          body: platforms.isEmpty
              ? _EmptyPlatforms(
                  l10n: l10n,
                  onAdd: () => _add(context, store),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: platforms.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final name = platforms[index];
                    return ListTile(
                      leading: const Icon(Icons.sell_outlined),
                      title: Text(name),
                      trailing: PopupMenuButton<String>(
                        key: Key('platformMenu_$name'),
                        onSelected: (value) {
                          if (value == 'rename') {
                            _rename(context, store, name);
                          } else if (value == 'delete') {
                            _delete(context, store, name);
                          }
                        },
                        itemBuilder: (_) => <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text(l10n.renamePlatform),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text(l10n.deletePlatform),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  Future<void> _add(BuildContext context, WoolStore store) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showPlatformNameDialog(
      context,
      title: l10n.newPlatformTitle,
      existingNames: store.platforms,
    );
    if (name == null) return;
    await store.addPlatform(name);
  }

  Future<void> _rename(
    BuildContext context,
    WoolStore store,
    String current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showPlatformNameDialog(
      context,
      title: l10n.renamePlatformTitle,
      existingNames: store.platforms,
      initialName: current,
    );
    if (name == null) return;
    await store.renamePlatform(current, name);
  }

  Future<void> _delete(
    BuildContext context,
    WoolStore store,
    String name,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deletePlatform),
        content: Text(l10n.platformDeleteBody(name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('platformDeleteConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.removePlatform(name);
  }
}

class _EmptyPlatforms extends StatelessWidget {
  const _EmptyPlatforms({required this.l10n, required this.onAdd});

  final AppLocalizations l10n;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.sell_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.platformEmptyHint,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('addPlatformEmpty'),
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(l10n.addPlatform),
              ),
            ],
          ),
        ),
      );
}
