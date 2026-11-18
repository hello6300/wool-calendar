import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:intl/intl.dart';

import '../data/sync_service.dart';

/// 打开「选择备份」，返回用户选中的那条；取消返回 null。
///
/// 只做展示：列表由调用方先取好（PROPFIND 一次目录）。这样失败提示
/// 能统一走设置页的 SnackBar，弹窗里不必再维护一套加载 / 重试状态。
Future<RemoteBackup?> showBackupPickerDialog({
  required BuildContext context,
  required List<RemoteBackup> backups,
}) {
  return showDialog<RemoteBackup>(
    context: context,
    builder: (ctx) => _BackupPickerDialog(backups: backups),
  );
}

class _BackupPickerDialog extends StatelessWidget {
  const _BackupPickerDialog({required this.backups});

  final List<RemoteBackup> backups;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final contentHeight =
        (MediaQuery.of(context).size.height * 0.46).clamp(200.0, 360.0);

    return AlertDialog(
      title: Text(l10n.syncRestoreTitle),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: contentHeight,
        child: ListView.separated(
          itemCount: backups.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, index) {
            final backup = backups[index];
            final at = backup.at;
            return ListTile(
              key: Key('backupItem_$index'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                backup.isSafetyCopy
                    ? Icons.history_toggle_off
                    : Icons.event_available_outlined,
                color: theme.colorScheme.primary,
              ),
              title: Text(DateFormat('yyyy-MM-dd').format(backup.day)),
              subtitle: Text(
                at == null
                    ? l10n.syncRestoreDaily
                    : l10n.syncRestoreSafety(
                        DateFormat('HH:mm').format(at),
                      ),
                style: theme.textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(ctx).pop(backup),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
