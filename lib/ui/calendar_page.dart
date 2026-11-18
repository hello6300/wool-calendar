import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../data/local_deal_reminder.dart';
import '../models/wool_deal.dart';
import '../state/sync_controller.dart';
import '../state/wool_store.dart';
import '../utils/calendar_grid.dart';
import 'calendar_import_page.dart';
import 'device_settings_page.dart';
import 'reminder_settings_page.dart';
import 'sync_failure_text.dart';
import 'sync_settings_page.dart';
import 'wool_editor.dart';
import 'wool_status.dart';
import 'wool_tile.dart';

/// 月历主页面：上半部 6×7 网格，下半部是选中日期的记录列表。
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key, this.reminder, this.syncController});

  /// 真实 App 里传入；widget test 里为 null（不依赖原生通知插件）。
  final LocalDealReminder? reminder;

  /// 传入后 AppBar 出现「数据同步」入口；为 null 时不显示（测试里也不依赖它）。
  final SyncController? syncController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<WoolStore>(
      builder: (context, store, _) {
        final byDay = store.dealsByDay;
        final selected = store.selectedDay;
        final dayDeals = byDay[dateKey(selected)] ?? <WoolDeal>[];
        final reward = store.dayReward(selected);

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.woolCalendarTitle),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            actions: <Widget>[
              if (store.canImportFromDevice)
                IconButton(
                  tooltip: l10n.importFromCalendar,
                  icon: const Icon(Icons.event_available_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CalendarImportPage(
                        source: store.calendarSource!,
                        initialMonth: store.month,
                      ),
                    ),
                  ),
                ),
              if (syncController != null)
                IconButton(
                  tooltip: l10n.syncSettings,
                  icon: const Icon(Icons.cloud_sync_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ChangeNotifierProvider<SyncController>.value(
                        value: syncController!,
                        child: const SyncSettingsPage(),
                      ),
                    ),
                  ),
                ),
              if (reminder != null)
                IconButton(
                  tooltip: l10n.notificationSettings,
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReminderSettingsPage(
                        reminder: reminder!,
                      ),
                    ),
                  ),
                ),
              TextButton.icon(
                onPressed: store.goToday,
                icon: const Icon(Icons.today, size: 18),
                label: Text(l10n.today),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: l10n.addDeal,
            onPressed: () => _openEditor(context, selected),
            child: const Icon(Icons.add),
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              // 矮屏（如 MuMu 960×540）下按剩余高度收缩日历行高，
              // 保证当日列表至少有约 140dp，而不是只剩一条记录的高度。
              final rowHeight = _gridRowHeight(
                constraints.maxHeight,
                MediaQuery.of(context).size.width,
              );
              return Column(
                children: <Widget>[
                  _DeviceBar(l10n: l10n, store: store),
                  _MonthBar(l10n: l10n, store: store),
                  _WeekHeader(l10n: l10n),
                  _MonthGrid(
                    store: store,
                    byDay: byDay,
                    rowHeight: rowHeight,
                  ),
                  const Divider(height: 1),
                  _DayHeader(
                    l10n: l10n,
                    day: selected,
                    count: dayDeals.length,
                    reward: reward,
                  ),
                  Expanded(
                    child: _DayList(
                      emptyText: store.isAllDevices
                          ? l10n.emptyDay
                          : l10n.emptyDayDevice(
                              store.deviceName(
                                store.activeDeviceId,
                                l10n.defaultDeviceName,
                              ),
                            ),
                      deals: dayDeals,
                      // 配了同步才给下拉刷新：没配置时下拉只会弹一句「请先填地址」。
                      onRefresh: syncController == null
                          ? null
                          : () => _pullSync(context, l10n),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openEditor(BuildContext context, DateTime date) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WoolEditorPage(date: date),
      ),
    );
  }

  /// 下拉即同步：在主界面往下一拉就合并一次，不用先钻进设置页按按钮。
  Future<void> _pullSync(BuildContext context, AppLocalizations l10n) async {
    final sync = syncController;
    if (sync == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!sync.configured) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.syncErrorBadConfig)),
      );
      return;
    }
    await sync.syncNow();
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(syncResultText(l10n, sync))),
    );
  }
}

/// 当日记录列表，可带下拉刷新。
///
/// 空态也做成可滚动的 ListView：`RefreshIndicator` 只认能滚的 child，
/// 用 Center 包 Text 的话有记录能下拉、没记录反而拉不动，手感不一致。
class _DayList extends StatelessWidget {
  const _DayList({
    required this.emptyText,
    required this.deals,
    this.onRefresh,
  });

  final String emptyText;
  final List<WoolDeal> deals;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final physics = onRefresh == null
        ? null
        : const AlwaysScrollableScrollPhysics();
    final Widget list;
    if (deals.isEmpty) {
      list = LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: physics,
          padding: const EdgeInsets.only(bottom: 88),
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    constraints.maxHeight > 88 ? constraints.maxHeight - 88 : 0,
              ),
              child: Center(
                child: Padding(
                  // 矮屏下结果区可能只剩几十 dp，竖向 padding 太大会把文案裁掉。
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(
                    emptyText,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      list = ListView.builder(
        physics: physics,
        padding: const EdgeInsets.only(bottom: 88),
        // 视口很矮时也要预构建相邻记录，滚动不闪、测试可见。
        cacheExtent: 300,
        itemCount: deals.length,
        itemBuilder: (_, i) => WoolTile(deal: deals[i]),
      );
    }

    final refresh = onRefresh;
    if (refresh == null) return list;
    return RefreshIndicator(onRefresh: refresh, child: list);
  }
}

/// 设备筛选条：单行横向滚动，固定高度，避免在矮屏 / 横屏上把日历撑溢出。
class _DeviceBar extends StatelessWidget {
  const _DeviceBar({required this.l10n, required this.store});

  final AppLocalizations l10n;
  final WoolStore store;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      ChoiceChip(
                        key: const Key('deviceFilter_all'),
                        label: Text(l10n.allDevices),
                        selected: store.isAllDevices,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => store.selectDevice(''),
                      ),
                      for (final d in store.devices)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ChoiceChip(
                            key: Key('deviceFilter_${d.id}'),
                            label: Text(d.displayName(l10n.defaultDeviceName)),
                            selected: store.activeDeviceId == d.id,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => store.selectDevice(d.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const Key('deviceManageButton'),
                tooltip: l10n.manageDevices,
                icon: const Icon(Icons.tune, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DeviceSettingsPage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _MonthBar extends StatelessWidget {
  const _MonthBar({required this.l10n, required this.store});

  final AppLocalizations l10n;
  final WoolStore store;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: l10n.previousMonth,
              icon: const Icon(Icons.chevron_left),
              onPressed: () => store.shiftMonth(-1),
            ),
            Expanded(
              child: Center(
                child: Text(
                  l10n.monthLabel(store.month.year, store.month.month),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.nextMonth,
              icon: const Icon(Icons.chevron_right),
              onPressed: () => store.shiftMonth(1),
            ),
          ],
        ),
      );
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      l10n.weekMon,
      l10n.weekTue,
      l10n.weekWed,
      l10n.weekThu,
      l10n.weekFri,
      l10n.weekSat,
      l10n.weekSun,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 12,
                    color: i >= 5
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 日历行高：宽屏按宽度算，矮屏再按 body 剩余高度收缩。
///
/// 固定 6 行，不用 GridView + childAspectRatio：宽屏/横屏时格子会被拉到 100+dp 高，
/// 6 行直接把页面撑溢出（widget test 在 800dp 宽上实测溢出 212px）。
/// 顶部多了 38dp 设备筛选条，所以这里给当日列表预留至少 140dp。
double _gridRowHeight(double bodyHeight, double width) {
  final byWidth = ((width - 16) / 7 * 0.92).clamp(28.0, 44.0).toDouble();
  if (!bodyHeight.isFinite) return byWidth;
  // 设备条 38 + 月历栏 52 + 周标题 17 + 网格 padding 8 + 分隔 1 + 当日头 38
  const fixed = 154.0;
  const minListHeight = 140.0;
  final byHeight =
      ((bodyHeight - fixed - minListHeight) / 6).clamp(28.0, 44.0).toDouble();
  return byHeight < byWidth ? byHeight : byWidth;
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.store,
    required this.byDay,
    required this.rowHeight,
  });

  final WoolStore store;
  final Map<String, List<WoolDeal>> byDay;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final today = dayOnly(DateTime.now());
    final days = calendarGrid(store.month);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: <Widget>[
          for (var row = 0; row < 6; row++)
            SizedBox(
              height: rowHeight,
              child: Row(
                children: <Widget>[
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: _DayCell(
                        day: days[row * 7 + col],
                        month: store.month,
                        selected: store.selectedDay,
                        today: today,
                        deals: byDay[dateKey(days[row * 7 + col])] ??
                            const <WoolDeal>[],
                        scheme: scheme,
                        onTap: () => store.selectDay(days[row * 7 + col]),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.month,
    required this.selected,
    required this.today,
    required this.deals,
    required this.scheme,
    required this.onTap,
  });

  final DateTime day;
  final DateTime month;
  final DateTime selected;
  final DateTime today;
  final List<WoolDeal> deals;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final inMonth = day.year == month.year && day.month == month.month;
    final isSelected = isSameDay(day, selected);
    final isToday = isSameDay(day, today);
    final textColor = isSelected
        ? scheme.onPrimary
        : (!inMonth
            ? scheme.outline
            : (isToday ? scheme.primary : scheme.onSurface));

    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isSelected
                ? scheme.primary
                : (isToday ? scheme.primaryContainer.withOpacity(0.45) : null),
            border: isToday && !isSelected
                ? Border.all(color: scheme.primary, width: 1.2)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 13,
                  color: textColor,
                  fontWeight: (isToday || isSelected)
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              // 矮屏下自适应行高可能收到 ~28dp，间距必须留够余量，
              // 否则日期文字 + 间距 + 圆点会溢出 1~2px（widget test 实测 1.3px）。
              const SizedBox(height: 2),
              SizedBox(
                height: 5,
                child: deals.isEmpty
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (final deal in deals.take(3))
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelected
                                    ? scheme.onPrimary
                                    : statusColor(deal.status),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.l10n,
    required this.day,
    required this.count,
    required this.reward,
  });

  final AppLocalizations l10n;
  final DateTime day;
  final int count;
  final double reward;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.event_note,
                size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            // 窄屏（含 320dp 宽的小屏）下三个数字必须能各自收缩，
            // 用 Spacer + 固定 Text 会横向溢出；Expanded/Flexible + ellipsis 才稳。
            Expanded(
              child: Text(
                dateKey(day),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.dealCount(count),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.totalReward(reward.toStringAsFixed(2)),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          ],
        ),
      );
}
