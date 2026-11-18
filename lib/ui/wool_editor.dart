import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/wool_deal.dart';
import '../models/wool_time.dart';
import '../state/wool_store.dart';
import '../utils/calendar_grid.dart';
import 'device_name_dialog.dart';
import 'platform_settings_page.dart';
import 'wool_status.dart';

/// 新增 / 编辑一条羊毛记录。
///
/// 传入 [date] 作为新增时的默认活动日期；传入 [deal] 即为编辑模式。
class WoolEditorPage extends StatefulWidget {
  const WoolEditorPage({super.key, required this.date, this.deal});

  final DateTime date;
  final WoolDeal? deal;

  @override
  State<WoolEditorPage> createState() => _WoolEditorPageState();
}

class _WoolEditorPageState extends State<WoolEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _platform;
  late final TextEditingController _title;
  late final TextEditingController _detail;
  late final TextEditingController _url;
  late final TextEditingController _notes;
  late final TextEditingController _amount;
  late DateTime _date;
  late WoolStatus _status;
  WoolTime? _startTime;
  WoolTime? _endTime;
  late bool _remind;

  /// null = 还没手动改过，新增时用 store.deviceForNew（当前筛选 / 默认设备）。
  String? _deviceId;

  bool get _editing => widget.deal != null;
  bool get _hasTime => _startTime != null || _endTime != null;
  bool get _crossDay =>
      _startTime != null &&
      _endTime != null &&
      _endTime!.inMinutes < _startTime!.inMinutes;

  @override
  void initState() {
    super.initState();
    final d = widget.deal;
    _platform = TextEditingController(text: d?.platform ?? '');
    _title = TextEditingController(text: d?.title ?? '');
    _detail = TextEditingController(text: d?.detail ?? '');
    _url = TextEditingController(text: d?.url ?? '');
    _notes = TextEditingController(text: d?.notes ?? '');
    _amount = TextEditingController(
      text: d?.amount == null ? '' : d!.amount!.toStringAsFixed(2),
    );
    _date = d?.date ?? dayOnly(widget.date);
    _status = d?.status ?? WoolStatus.planned;
    _startTime = d?.startTime;
    _endTime = d?.endTime;
    _remind = d?.remind ?? true;
    _deviceId = d?.deviceId;
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _platform,
      _title,
      _detail,
      _url,
      _notes,
      _amount,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _date = dayOnly(picked));
    }
  }

  Future<void> _pickTime({required bool isStart}) async {
    final current = isStart ? _startTime : _endTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null
          ? TimeOfDay.now()
          : TimeOfDay(hour: current.hour, minute: current.minute),
      // 统一 24 小时制，和 HH:mm 存储格式一致，避免 AM/PM 误读。
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    final time = WoolTime(picked.hour, picked.minute);
    setState(() {
      if (isStart) {
        _startTime = time;
      } else {
        _endTime = time;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 所有 BuildContext 相关对象都在 await 之前取出，避免跨异步间隙使用 context。
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // 第一次打开「到点提醒」时申请 Android 13+ 通知权限。
    if (_remind && _hasTime) await store.enableReminders();

    final amountText = _amount.text.trim();
    final existing = widget.deal;
    final deal = WoolDeal(
      id: existing?.id ?? store.newId(),
      platform: _platform.text.trim(),
      title: _title.text.trim(),
      detail: _detail.text.trim(),
      url: _url.text.trim(),
      notes: _notes.text.trim(),
      date: _date,
      status: _status,
      amount: amountText.isEmpty ? null : double.tryParse(amountText),
      startTime: _startTime,
      endTime: _endTime,
      remind: _remind,
      createdAt: existing?.createdAt ?? DateTime.now(),
      deviceId: _deviceId ?? store.deviceForNew,
      // 编辑器是「重新构造对象」，来源标记必须原样带回：
      // 否则编辑过标题的系统日历导入记录会被再次导入一遍。
      sourceId: existing?.sourceId,
      sourceName: existing?.sourceName,
    );

    if (_editing) {
      await store.update(deal);
    } else {
      await store.add(deal);
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.saved)));
    navigator.pop();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteConfirmTitle),
        content: Text(l10n.deleteConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await store.remove(widget.deal!.id);
    messenger.showSnackBar(SnackBar(content: Text(l10n.deleted)));
    navigator.pop();
  }

  /// 就地新增一台设备并立刻选中，不用先退出编辑页去「设备管理」。
  Future<void> _quickAddDevice(
    AppLocalizations l10n,
    WoolStore store,
  ) async {
    final name = await showDeviceNameDialog(
      context,
      l10n: l10n,
      store: store,
      title: l10n.newDeviceTitle,
    );
    if (name == null || !mounted) return;
    final device = await store.addDevice(
      name,
      defaultLabel: l10n.defaultDeviceName,
    );
    if (device != null && mounted) {
      setState(() => _deviceId = device.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final store = context.watch<WoolStore>();
    final selectedDeviceId = _deviceId ?? store.deviceForNew;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? l10n.editDeal : l10n.addDeal),
        actions: <Widget>[
          if (_editing)
            IconButton(
              tooltip: l10n.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        // 表单字段数量固定且不多：用 SingleChildScrollView + Column 一次性构建，
        // 软键盘弹出后不会像 ListView 那样回收不可见字段（焦点/输入更稳）。
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(l10n.dateLabel),
                subtitle: Text(dateKey(_date)),
                trailing: const Icon(Icons.calendar_month),
                onTap: _pickDate,
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const Key('editorDeviceField'),
                      value: selectedDeviceId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.deviceLabel,
                        prefixIcon: const Icon(Icons.devices_other_outlined),
                        border: const OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        for (final d in store.devices)
                          DropdownMenuItem<String>(
                            value: d.id,
                            child: Text(
                              d.displayName(l10n.defaultDeviceName),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _deviceId = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const Key('editorAddDevice'),
                    tooltip: l10n.addDevice,
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => _quickAddDevice(l10n, store),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _TimeField(
                      label: l10n.startTimeLabel,
                      value: _startTime,
                      notSetText: l10n.timeNotSet,
                      clearTooltip: l10n.clearTime,
                      onPick: () => _pickTime(isStart: true),
                      onClear: () => setState(() => _startTime = null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TimeField(
                      label: l10n.endTimeLabel,
                      value: _endTime,
                      notSetText: l10n.timeNotSet,
                      clearTooltip: l10n.clearTime,
                      onPick: () => _pickTime(isStart: false),
                      onClear: () => setState(() => _endTime = null),
                    ),
                  ),
                ],
              ),
              if (_crossDay)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l10n.crossDayHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.notifications_active_outlined),
                title: Text(l10n.remindLabel),
                subtitle: Text(
                  !_remind
                      ? l10n.remindHint
                      : (!_hasTime
                          ? l10n.remindNoTime
                          : (!isReminderStatus(_status)
                              ? l10n.remindDoneHint
                              : l10n.remindHint)),
                ),
                value: _remind,
                onChanged: (v) => setState(() => _remind = v),
              ),
              const Divider(height: 8),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('editorPlatformField'),
                controller: _platform,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.platform,
                  hintText: l10n.platformHint,
                  prefixIcon: const Icon(Icons.storefront),
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? l10n.platformRequired
                    : null,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.quickPlatforms,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: <Widget>[
                  for (final p in store.platforms)
                    ActionChip(
                      key: Key('platformChip_$p'),
                      label: Text(p),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _platform.text = p,
                    ),
                  // 常驻入口：随时增删常用平台，不用退出编辑页。
                  ActionChip(
                    key: const Key('managePlatformsChip'),
                    avatar: const Icon(Icons.tune, size: 16),
                    label: Text(l10n.managePlatforms),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PlatformSettingsPage(),
                      ),
                    ),
                  ),
                ],
              ),
              if (store.platforms.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.platformEmptyHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('editorTitleField'),
                controller: _title,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.dealTitle,
                  hintText: l10n.dealTitleHint,
                  prefixIcon: const Icon(Icons.title),
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? l10n.dealTitleRequired
                    : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<WoolStatus>(
                value: _status,
                decoration: InputDecoration(
                  labelText: l10n.statusLabel,
                  border: const OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<WoolStatus>>[
                  for (final s in WoolStatus.values)
                    DropdownMenuItem<WoolStatus>(
                      value: s,
                      child: Text(statusText(l10n, s)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _status = v);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: l10n.amountLabel,
                  prefixIcon: const Icon(Icons.payments_outlined),
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final text = v?.trim() ?? '';
                  if (text.isEmpty) return null;
                  return double.tryParse(text) == null
                      ? l10n.amountInvalid
                      : null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.dealUrl,
                  hintText: l10n.dealUrlHint,
                  prefixIcon: const Icon(Icons.link),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _detail,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.dealDetail,
                  hintText: l10n.dealDetailHint,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notes,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l10n.notes,
                  hintText: l10n.notesHint,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.save),
          ),
        ),
      ),
    );
  }
}

/// 一个紧凑的 HH:mm 选择框：点整体选时间，点 x 清空。
class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.notSetText,
    required this.clearTooltip,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final WoolTime? value;
  final String notSetText;
  final String clearTooltip;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onPick,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(
                    value?.text ?? notSetText,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: value == null ? scheme.outline : null,
                        ),
                  ),
                ],
              ),
            ),
            if (value != null)
              Semantics(
                button: true,
                label: clearTooltip,
                child: GestureDetector(
                  onTap: onClear,
                  child: Icon(Icons.close, size: 16, color: scheme.outline),
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.access_time, size: 16, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
