import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../data/local_deal_reminder.dart';
import '../state/wool_store.dart';

/// 提醒设置 / 自检页：看权限状态、发测试通知、手动重排全部提醒。
///
/// 模拟器与国产 ROM 上通知权限、精确闹钟经常被默认关掉，这一页用来
/// 现场确认「提醒到底有没有排上」，不用翻系统设置或看 logcat。
class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({super.key, required this.reminder});

  final LocalDealReminder reminder;

  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage> {
  bool? _notifications;
  bool? _exactAlarms;
  int _pending = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final notifications = await widget.reminder.notificationsEnabled();
    final exact = await widget.reminder.exactAlarmsEnabled();
    final pending = await widget.reminder.pendingCount();
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _exactAlarms = exact;
      _pending = pending;
    });
  }

  Future<void> _run(Future<void> Function() action, {String? message}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _status(AppLocalizations l10n, bool? value) => value == null
      ? l10n.statusUnknown
      : (value ? l10n.statusOn : l10n.statusOff);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.notificationSettings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          Card(
            color: scheme.primaryContainer.withOpacity(0.4),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.notificationHelp)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: Text(l10n.notificationStatus),
            trailing: Text(_status(l10n, _notifications)),
          ),
          ListTile(
            leading: const Icon(Icons.alarm),
            title: Text(l10n.exactAlarmStatus),
            trailing: Text(_status(l10n, _exactAlarms)),
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(l10n.timeZoneLabel),
            trailing: Text(widget.reminder.timeZoneName),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text(l10n.pendingReminders),
            trailing: Text(l10n.pendingRemindersValue(_pending)),
          ),
          if (widget.reminder.lastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '${l10n.lastReminderError}: ${widget.reminder.lastError}',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          const Divider(height: 24),
          FilledButton.tonalIcon(
            onPressed: _busy
                ? null
                : () => _run(() => widget.reminder.ensurePermissions()),
            icon: const Icon(Icons.notifications_active_outlined),
            label: Text(l10n.grantNotification),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                      () => widget.reminder.ensurePermissions(
                        requestExactAlarm: true,
                      ),
                    ),
            icon: const Icon(Icons.settings_outlined),
            label: Text(l10n.grantExactAlarm),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                _busy ? null : () => _run(widget.reminder.sendTestNotification),
            icon: const Icon(Icons.send_outlined),
            label: Text(l10n.sendTestNotification),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                _busy ? null : () => _run(widget.reminder.scheduleTestReminder),
            icon: const Icon(Icons.alarm_add_outlined),
            label: Text(l10n.scheduleTestReminder),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                      () => context.read<WoolStore>().syncReminders(),
                      message: l10n.remindersResynced,
                    ),
            icon: const Icon(Icons.sync),
            label: Text(l10n.resyncReminders),
          ),
        ],
      ),
    );
  }
}
