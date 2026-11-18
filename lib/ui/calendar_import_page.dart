import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../data/calendar_probe.dart';
import '../data/device_calendar_source.dart';
import '../state/wool_store.dart';
import '../utils/calendar_grid.dart';
import '../utils/import_range.dart';

/// 从手机系统日历「提取活动」的页面。
///
/// 全程手动：进页面只检查权限，不读取任何日历数据；用户先选提取范围，
/// 再点「提取活动」才真正扫描系统日历，最后人工勾选要导入的活动。
/// 只读，不写回系统日历；已导入过的事件按 sourceId 置灰，避免重复。
class CalendarImportPage extends StatefulWidget {
  const CalendarImportPage({
    super.key,
    required this.source,
    this.initialMonth,
    this.now,
  });

  final DeviceCalendarSource source;

  /// 默认范围跟随日历页所在月份（仅预填，不触发读取）。
  final DateTime? initialMonth;

  /// 测试注入的「今天」，让快捷范围可预测。
  final DateTime? now;

  @override
  State<CalendarImportPage> createState() => _CalendarImportPageState();
}

class _CalendarImportPageState extends State<CalendarImportPage> {
  late ImportRange _range;
  bool? _permitted;
  bool _granting = false;
  bool _extracting = false;
  bool _importing = false;
  bool _extracted = false;
  bool _rangeChanged = false;
  String? _error;
  String? _extractedRangeLabel;

  /// 这批活动导入后归到哪台设备；null = 用 store.deviceForNew。
  String? _deviceId;

  List<CalendarEventEntry> _events = <CalendarEventEntry>[];
  Set<String> _imported = <String>{};
  final Set<String> _selected = <String>{};

  /// 一条都没读到时做的体检结果，用来把「真没有」和「读不到」分开说。
  CalendarDiagnosis? _diagnosis;

  DateTime get _anchor => widget.now ?? DateTime.now();

  bool get _busy => _granting || _extracting || _importing;

  /// 结果条要尽量矮，把高度留给活动列表。
  static ButtonStyle get _compactButtonStyle => TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      );

  @override
  void initState() {
    super.initState();
    _range = ImportRange.initialMonth(widget.initialMonth ?? _anchor);
    _checkPermission();
  }

  CalendarImportLabels _labels(AppLocalizations l10n) => CalendarImportLabels(
        fallbackPlatform: l10n.importFallbackPlatform,
        fallbackTitle: l10n.importUntitled,
        allDayTag: l10n.importAllDay,
        endsAt: l10n.importEndsAt,
        location: l10n.importLocation,
        source: l10n.importSource,
      );

  /// 进页面只查状态，不弹系统权限框，更不读取日历。
  Future<void> _checkPermission() async {
    final granted = await widget.source.hasPermissions();
    if (!mounted) return;
    setState(() => _permitted = granted);
  }

  /// 权限页上的按钮：只授权，不自动提取，下一步仍由用户点「提取活动」。
  Future<void> _grant() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _granting = true);
    final granted = await widget.source.requestPermissions();
    if (!mounted) return;
    setState(() {
      _permitted = granted;
      _granting = false;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(granted
            ? l10n.importPermissionReady
            : l10n.calendarPermissionDenied),
      ),
    );
  }

  /// 唯一的读取入口：必须由用户点「提取活动 / 重新提取 / 重试提取」触发。
  Future<void> _extract() async {
    if (_busy) return;
    // context 相关对象一律在 await 之前取出。
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<WoolStore>();

    // 用户主动点了提取，若尚未授权就先申请；授权后接着完成这一次提取，
    // 不额外要求再点一次。单独点权限页的按钮则只授权、不读取。
    if (_permitted != true) {
      setState(() => _granting = true);
      final granted = await widget.source.requestPermissions();
      if (!mounted) return;
      setState(() {
        _permitted = granted;
        _granting = false;
      });
      if (!granted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.calendarPermissionDenied)),
        );
        return;
      }
    }

    // 快照范围：读取途中用户改了范围，列表仍与「本次提取」的摘要一致。
    final range = _range;
    setState(() {
      _extracting = true;
      _error = null;
      _extracted = false;
      _events = <CalendarEventEntry>[];
      _selected.clear();
      _diagnosis = null;
    });
    try {
      final events = await widget.source.fetchEvents(
        from: range.from,
        to: range.toExclusive,
      );
      // 一条都没读到时做一次体检：只有诊断结果才能说明是权限、是 ROM 限制，
      // 还是这个区间真的没有活动。
      CalendarDiagnosis? diagnosis;
      if (events.isEmpty) {
        try {
          diagnosis = await widget.source.diagnose(
            from: range.from,
            to: range.toExclusive,
          );
        } on Object {
          diagnosis = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _events = events;
        _diagnosis = diagnosis;
        _imported = store.importedSourceIds;
        _extracted = true;
        _extractedRangeLabel = range.label;
        _rangeChanged = false;
        _extracting = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _extracting = false;
      });
    }
  }

  /// 改范围只清结果，绝不自动重新读取。
  void _applyRange(ImportRange next) {
    if (next == _range) return;
    setState(() {
      _range = next;
      _events = <CalendarEventEntry>[];
      _selected.clear();
      _extracted = false;
      _error = null;
      _diagnosis = null;
      _rangeChanged = true;
    });
  }

  Future<void> _pickDate(bool isStart) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _range.start : _range.end,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: isStart ? l10n.importStartDate : l10n.importEndDate,
    );
    if (picked == null || !mounted) return;
    _applyRange(isStart ? _range.withStart(picked) : _range.withEnd(picked));
  }

  List<String> get _selectableIds => _events
      .where((e) => !_imported.contains(e.sourceId))
      .map((e) => e.sourceId)
      .toList(growable: false);

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleAll() {
    final ids = _selectableIds;
    final allSelected = ids.isNotEmpty && ids.every(_selected.contains);
    setState(() {
      _selected.clear();
      if (!allSelected) _selected.addAll(ids);
    });
  }

  Future<void> _import() async {
    if (_selected.isEmpty || _busy || !_extracted) return;
    // context 相关对象一律在 await 之前取出。
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final labels = _labels(l10n);
    final chosen = _events
        .where((e) => _selected.contains(e.sourceId))
        .toList(growable: false);

    setState(() => _importing = true);
    final count = await store.importEvents(
      chosen,
      labels: labels,
      deviceId: _deviceId ?? store.deviceForNew,
    );
    if (!mounted) return;

    setState(() {
      _imported = store.importedSourceIds;
      _selected.clear();
      _importing = false;
    });

    if (count == 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.importAllImported)),
      );
      return;
    }

    // 导入完直接把日历定位到第一条活动那天，省得用户再翻月。
    store.selectDay(chosen.first.start);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.importSuccess(count)),
        action: SnackBarAction(
          label: l10n.importViewCalendar,
          onPressed: () => navigator.pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<WoolStore>();
    final selectable = _selectableIds;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.deviceCalendarTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 矮屏 / 横屏时顶部设置区最多占 48%，且自身可滚动，
          // 保证下方结果列表和授权按钮始终有可用高度。
          final available =
              constraints.maxHeight.isFinite ? constraints.maxHeight : 600.0;
          final topMaxHeight = (available * 0.48).clamp(140.0, 300.0);
          return Column(
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: topMaxHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _helpCard(l10n, scheme),
                      _rangeCard(l10n, scheme),
                    ],
                  ),
                ),
              ),
              _extractBar(l10n),
              const Divider(height: 1),
              Expanded(child: _body(l10n, scheme, selectable)),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              // 「归入设备」跟导入按钮绑在一起，语义最准，且固定在底部栏，
              // 不会像放在可滚动设置区里那样被 ClipRect 裁到点不到。
              Expanded(
                flex: 2,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.deviceAssign,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    DropdownButton<String>(
                      key: const Key('importDevicePicker'),
                      value: _deviceId ?? store.deviceForNew,
                      isExpanded: true,
                      isDense: true,
                      underline: const SizedBox.shrink(),
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
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: FilledButton.icon(
                  onPressed: (_busy || !_extracted || _selected.isEmpty)
                      ? null
                      : _import,
                  icon: _importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(
                    l10n.importSelected(_selected.length),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 帮助卡默认折叠：矮屏上不占用结果列表的高度，点开才看只读与权限说明。
  Widget _helpCard(AppLocalizations l10n, ColorScheme scheme) => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        color: scheme.primaryContainer.withOpacity(0.4),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.info_outline, size: 20, color: scheme.primary),
          title: Text(
            l10n.deviceCalendarHelp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.deviceCalendarHelp),
                const SizedBox(height: 6),
                Text(
                  l10n.calendarPermissionHint,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _rangeCard(AppLocalizations l10n, ColorScheme scheme) => Card(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.date_range_outlined,
                      size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    l10n.importRangeLabel,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    l10n.importRangeDays(_range.dayCount),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 单行横向滚动，避免窄屏换行把结果列表挤没。
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (final preset in ImportRangePreset.values)
                      if (preset != ImportRangePreset.custom)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: Key('importPreset_${preset.name}'),
                            label: Text(_presetLabel(l10n, preset)),
                            selected: _range.preset == preset,
                            visualDensity: VisualDensity.compact,
                            onSelected: _busy
                                ? null
                                : (_) => _applyRange(
                                      ImportRange.fromPreset(preset, _anchor),
                                    ),
                          ),
                        ),
                    if (_range.preset == ImportRangePreset.custom)
                      Chip(
                        label: Text(l10n.importPresetCustom),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: scheme.secondaryContainer,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _dateButton(l10n, isStart: true),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _dateButton(l10n, isStart: false),
                  ),
                ],
              ),
              if (_range.isMaxLength)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l10n.importRangeMaxHint,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ),
            ],
          ),
        ),
      );

  /// 主操作固定在这里，不放进上面可滚动的设置区：矮屏也不会被裁掉。
  Widget _extractBar(AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('importExtractButton'),
            onPressed: _busy ? null : _extract,
            icon: _extracting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.manage_search_outlined),
            label: Text(l10n.importExtractAction),
          ),
        ),
      );

  String _presetLabel(AppLocalizations l10n, ImportRangePreset preset) {
    switch (preset) {
      case ImportRangePreset.today:
        return l10n.importPresetToday;
      case ImportRangePreset.next7Days:
        return l10n.importPresetNext7;
      case ImportRangePreset.thisMonth:
        return l10n.importPresetThisMonth;
      case ImportRangePreset.next30Days:
        return l10n.importPresetNext30;
      case ImportRangePreset.custom:
        return l10n.importPresetCustom;
    }
  }

  Widget _dateButton(AppLocalizations l10n, {required bool isStart}) =>
      OutlinedButton(
        key: Key(isStart ? 'importRangeStart' : 'importRangeEnd'),
        onPressed: _busy ? null : () => _pickDate(isStart),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              isStart ? l10n.importStartDate : l10n.importEndDate,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 2),
            Text(
              dateKey(isStart ? _range.start : _range.end),
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );

  Widget _body(
    AppLocalizations l10n,
    ColorScheme scheme,
    List<String> selectable,
  ) {
    if (_permitted == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_extracting) {
      return _centeredContent(<Widget>[
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(l10n.importLoading, style: TextStyle(color: scheme.outline)),
      ]);
    }
    if (_permitted != true) return _permissionView(l10n, scheme);
    if (_error != null) return _errorView(l10n, scheme);
    if (!_extracted) return _idleView(l10n, scheme);
    if (_events.isEmpty) return _emptyView(l10n, scheme);

    final allSelected =
        selectable.isNotEmpty && selectable.every(_selected.contains);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.importExtractedRange(_extractedRangeLabel ?? ''),
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('importReExtractButton'),
                    style: _compactButtonStyle,
                    onPressed: _busy ? null : _extract,
                    icon: const Icon(Icons.refresh, size: 15),
                    label: Text(l10n.importReExtract),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  Text(l10n.importEventCount(_events.length),
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  TextButton(
                    style: _compactButtonStyle,
                    onPressed: _toggleAll,
                    child: Text(allSelected
                        ? l10n.importClearSelection
                        : l10n.importSelectAll),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: _events.length,
            itemBuilder: (_, i) => _eventTile(l10n, scheme, _events[i]),
          ),
        ),
      ],
    );
  }

  Widget _eventTile(
    AppLocalizations l10n,
    ColorScheme scheme,
    CalendarEventEntry event,
  ) {
    final imported = _imported.contains(event.sourceId);
    final selected = _selected.contains(event.sourceId);
    final title =
        event.title.trim().isEmpty ? l10n.importUntitled : event.title.trim();
    final calendar = event.calendarName.trim().isEmpty
        ? l10n.importFallbackPlatform
        : event.calendarName.trim();

    return ListTile(
      leading: Checkbox(
        value: selected,
        onChanged: imported ? null : (_) => _toggle(event.sourceId),
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${event.timeText(l10n.importAllDay)}  ·  $calendar',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: imported
          ? Chip(
              label: Text(l10n.importImported),
              visualDensity: VisualDensity.compact,
              backgroundColor: scheme.surfaceContainerHighest,
            )
          : (event.url.trim().isNotEmpty
              ? Icon(Icons.link, size: 16, color: scheme.primary)
              : null),
      onTap: imported ? null : () => _toggle(event.sourceId),
    );
  }

  /// 空结果不能一句话打发：是「权限被接管」「日历里有事件但系统读不出来」
  /// 还是「这个区间确实没有」，对应的操作完全不同，必须分开说。
  Widget _emptyView(AppLocalizations l10n, ColorScheme scheme) {
    final diagnosis = _diagnosis;
    final headline = diagnosis == null
        ? l10n.importEmpty
        : diagnosis.noCalendars
            ? l10n.importEmptyNoCalendar
            : diagnosis.instancesFiltered
                ? l10n.importEmptyFiltered
                : diagnosis.noEventsAtAll
                    ? l10n.importEmptyNoEvents
                    : l10n.importEmpty;
    final suspicious = diagnosis != null &&
        (diagnosis.noCalendars ||
            diagnosis.instancesFiltered ||
            diagnosis.noEventsAtAll);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(
            suspicious ? Icons.privacy_tip_outlined : Icons.event_busy,
            size: 40,
            color: scheme.outline,
          ),
          const SizedBox(height: 10),
          Text(headline, textAlign: TextAlign.center),
          if (diagnosis != null) ...<Widget>[
            const SizedBox(height: 12),
            _diagnosisCard(l10n, scheme, diagnosis),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('importRetryButton'),
            onPressed: _busy ? null : _extract,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.importRetry),
          ),
        ],
      ),
    );
  }

  Widget _diagnosisCard(
    AppLocalizations l10n,
    ColorScheme scheme,
    CalendarDiagnosis d,
  ) {
    final names = d.calendars
        .take(5)
        .map((c) => c.displayName)
        .join(' · ');

    final String? problem;
    if (d.noCalendars) {
      problem = l10n.importDiagNoCalendar;
    } else if (d.instancesFiltered) {
      problem = l10n.importDiagFiltered(d.eventRowCount);
    } else if (d.noEventsAtAll) {
      problem = l10n.importDiagNoEvents;
    } else if (d.genuinelyEmpty) {
      problem = l10n.importDiagRangeEmpty(d.tableRowCount);
    } else {
      problem = null;
    }

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.fact_check_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  l10n.importDiagTitle,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                // 放在标题行而不是卡片底部：矮屏或诊断内容偏长时，底部的按钮
                // 会被推出视口，用户根本看不到这个入口。
                TextButton.icon(
                  key: const Key('importDiagCopyButton'),
                  onPressed: () => _copyDiagnosis(l10n, d),
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: Text(l10n.importDiagCopy),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _diagLine(
              l10n.importDiagDevice(
                d.deviceLabel.trim().isEmpty ? '—' : d.deviceLabel.trim(),
                d.sdkInt,
              ),
              scheme,
            ),
            _diagLine(
              l10n.importDiagPermission(d.readPermission
                  ? l10n.importDiagPermissionOk
                  : l10n.importDiagPermissionNo),
              scheme,
            ),
            _diagLine(
              l10n.importDiagCounts(
                d.calendars.length,
                d.instanceCount,
                d.eventRowCount,
              ),
              scheme,
            ),
            if (d.recurringCount > 0)
              _diagLine(l10n.importDiagRecurring(d.recurringCount), scheme),
            if (d.tableRowCount > 0)
              _diagLine(l10n.importDiagTableTotal(d.tableRowCount), scheme),
            if (d.calendars.isNotEmpty)
              _diagLine(
                l10n.importDiagPerCalendar(
                  _perCalendarText(l10n, d),
                ),
                scheme,
              ),
            if (names.isNotEmpty)
              _diagLine(l10n.importDiagCalendarList(d.calendars.length, names), scheme),
            for (final error in d.errors) _diagLine(l10n.importDiagError(error), scheme),
            if (problem != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                problem,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
            // 区间里有重复日程、展开后却是 0 次：这是「真的没有」，不是读不到。
            // 不写清楚的话，用户看到「原始事件 109 条」会以为 App 挂了。
            if (d.eventRowCount > 0 && d.expandedCount == 0) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                l10n.importDiagRecurringNoHit(d.eventRowCount),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (d.isXiaomi &&
                (d.noCalendars || d.instancesFiltered || d.noEventsAtAll)) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                l10n.importDiagXiaomiHint,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 每个日历各自读到多少条：一眼看出是「全都没读到」还是「只有某个日历被过滤」。
  String _perCalendarText(AppLocalizations l10n, CalendarDiagnosis d) {
    // 日历存在但一条实例都没有时，也要把它们列出来各 0 条 —— 只写「无」的话，
    // 看不出本机到底注册了哪些日历，排查等于没线索。
    if (d.calendars.isEmpty) return l10n.importDiagPerCalendarEmpty;
    final byId = <String, int>{
      for (final item in d.perCalendar) item.calendarId: item.count,
    };
    return d.calendars
        .map((c) => l10n.importDiagPerCalendarItem(
              c.displayName,
              byId[c.id] ?? 0,
            ))
        .join(' · ');
  }

  /// 诊断信息纯文本版：用户复制后可以直接发过来，不必截图。
  Future<void> _copyDiagnosis(
    AppLocalizations l10n,
    CalendarDiagnosis d,
  ) async {
    final buffer = StringBuffer()
      ..writeln('羊毛日历 诊断信息')
      ..writeln('设备: ${d.deviceLabel} (API ${d.sdkInt})')
      ..writeln('权限: read=${d.readPermission} write=${d.writePermission}')
      ..writeln('日历数: ${d.calendars.length}')
      ..writeln(
        '实例 ${d.instanceCount} · 原始事件 ${d.eventRowCount} · 重复规则 ${d.recurringCount}',
      )
      ..writeln('本机日程总数 ${d.tableRowCount} · 直读展开 ${d.expandedCount} 条')
      ..writeln(
        '按日历: '
        '${d.perCalendar.map((e) => '${e.calendarId}=${e.count}').join(', ')}',
      );
    for (final c in d.calendars) {
      buffer.writeln(
        '日历 ${c.id} | ${c.displayName} | acct=${c.account} | type=${c.accountType}'
        ' | visible=${c.visible} | sync=${c.syncEvents} | access=${c.accessLevel}',
      );
    }
    for (final e in d.errors) {
      buffer.writeln('错误: $e');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.importDiagCopied)));
  }

  Widget _diagLine(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );

  /// 空态 / 权限 / 错误页统一走可滚动容器：矮屏上按钮不会被挤出可视区域。
  Widget _centeredContent(List<Widget> children) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      );

  Widget _idleView(AppLocalizations l10n, ColorScheme scheme) =>
      _centeredContent(<Widget>[
        Icon(Icons.touch_app_outlined, size: 44, color: scheme.outline),
        const SizedBox(height: 12),
        Text(
          _rangeChanged ? l10n.importRangeChanged : l10n.importNotExtracted,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          _range.label,
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      ]);

  Widget _permissionView(AppLocalizations l10n, ColorScheme scheme) =>
      _centeredContent(<Widget>[
        Icon(Icons.event_busy, size: 48, color: scheme.outline),
        const SizedBox(height: 12),
        Text(
          l10n.calendarPermissionDenied,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _grant,
          icon: const Icon(Icons.lock_open_outlined),
          label: Text(l10n.grantCalendarPermission),
        ),
      ]);

  Widget _errorView(AppLocalizations l10n, ColorScheme scheme) =>
      _centeredContent(<Widget>[
        Icon(Icons.error_outline, size: 40, color: scheme.error),
        const SizedBox(height: 12),
        Text(
          l10n.importLoadFailed(_error!),
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.error),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _extract,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.importRetry),
        ),
      ]);
}
