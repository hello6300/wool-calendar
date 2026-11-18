import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../state/wool_store.dart';
import 'device_name_dialog.dart';

/// 设备管理：自定义「手机 / 平板 / 备用机」等本地标签。
///
/// 「本机」这台是自动识别出来的（id 由设备标识派生、名字取机型），恒存在、
/// 不可删除；删除其它设备时记录不删除，统一迁回本机，避免历史羊毛失去归属。
class DeviceSettingsPage extends StatelessWidget {
  const DeviceSettingsPage({super.key});

  Future<void> _add(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final name = await showDeviceNameDialog(
      context,
      l10n: l10n,
      store: store,
      title: l10n.newDeviceTitle,
    );
    if (name == null) return;
    final device = await store.addDevice(
      name,
      defaultLabel: l10n.defaultDeviceName,
    );
    if (device != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.saved)));
    }
  }

  Future<void> _rename(BuildContext context, Device device) async {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final name = await showDeviceNameDialog(
      context,
      l10n: l10n,
      store: store,
      title: l10n.renameDeviceTitle,
      initial: device.displayName(l10n.defaultDeviceName),
      exceptId: device.id,
    );
    if (name == null) return;
    await store.renameDevice(
      device.id,
      name,
      defaultLabel: l10n.defaultDeviceName,
    );
  }

  Future<void> _delete(BuildContext context, Device device) async {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final messenger = ScaffoldMessenger.of(context);
    final name = device.displayName(l10n.defaultDeviceName);
    final count = store.dealCountOf(device.id);
    final target = store.deviceName(store.thisDeviceId, l10n.defaultDeviceName);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deviceDeleteTitle(name)),
        content: Text(l10n.deviceDeleteBody(count, target)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('deviceDeleteConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final moved = await store.removeDevice(device.id);
    if (moved >= 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.deviceRemoved(moved))),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.deviceCantDeleteDefault)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Consumer<WoolStore>(
      builder: (context, store, _) => Scaffold(
        appBar: AppBar(title: Text(l10n.manageDevices)),
        body: Column(
          children: <Widget>[
            Card(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              color: scheme.primaryContainer.withOpacity(0.4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.info_outline, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.deviceHelp,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: <Widget>[
                              Icon(
                                store.hasDeviceIdentity
                                    ? Icons.verified_outlined
                                    : Icons.help_outline,
                                size: 14,
                                color: scheme.outline,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  store.hasDeviceIdentity
                                      ? l10n.deviceIdentityDetected(
                                          store.thisDeviceLabel.isEmpty
                                              ? store.deviceName(
                                                  store.thisDeviceId,
                                                  l10n.defaultDeviceName,
                                                )
                                              : store.thisDeviceLabel,
                                        )
                                      : l10n.deviceIdentityUnknown,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: scheme.outline),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: store.devices.length,
                itemBuilder: (_, index) {
                  final d = store.devices[index];
                  final name = d.displayName(l10n.defaultDeviceName);
                  final isThis = d.id == store.thisDeviceId;
                  return ListTile(
                    key: Key('deviceRow_${d.id}'),
                    leading: Icon(
                      isThis ? Icons.phone_iphone : Icons.devices_other_outlined,
                      color: scheme.primary,
                    ),
                    title: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(name, overflow: TextOverflow.ellipsis),
                        ),
                        if (isThis) ...<Widget>[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              l10n.deviceThisDeviceBadge,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onPrimaryContainer),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(l10n.deviceDealCount(store.dealCountOf(d.id))),
                    trailing: PopupMenuButton<String>(
                      key: Key('deviceMenu_${d.id}'),
                      onSelected: (value) {
                        if (value == 'rename') {
                          _rename(context, d);
                        } else {
                          _delete(context, d);
                        }
                      },
                      itemBuilder: (_) => <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'rename',
                          child: Text(l10n.renameDevice),
                        ),
                        // 本机设备必须保留，直接从菜单里去掉删除项。
                        if (!isThis)
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text(l10n.deleteDevice),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              key: const Key('deviceAddButton'),
              onPressed: () => _add(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.addDevice),
            ),
          ),
        ),
      ),
    );
  }
}
