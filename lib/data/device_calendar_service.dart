import 'package:device_calendar/device_calendar.dart';

import 'calendar_probe.dart';
import 'device_calendar_source.dart';

/// 读取系统日历失败时抛出，由导入页展示成可操作的错误提示。
class CalendarReadException implements Exception {
  const CalendarReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [DeviceCalendarSource] 的真实实现：Android CalendarContract / iOS EventKit。
///
/// 只读：全程只调用 retrieveCalendars / retrieveEvents 与原生只读查询，
/// 不创建、不修改、不删除任何系统日历数据。插件自身的权限检查是读写绑定的，
/// Manifest 里因此声明了 WRITE_CALENDAR，但这里从不调用写入接口。
///
/// 两条通道：
/// 1. `device_calendar` 插件（逐个日历查 Instances）—— 标准路径，跨平台；
/// 2. [CalendarProbe] 原生直查（不逐个日历回查、可带最小投影降级）—— 兜底。
///
/// 部分 ROM（小米/红米实测）上插件会一条都读不到却又不报错：它查事件前要先
/// 用 `Calendars/<id>` 回查日历，返回 null 就整段跳过；Instances 视图也可能被
/// ROM 内部条件过滤。所以这里再补一条原生通道，两边按 sourceId 去重合并。
class DeviceCalendarService implements DeviceCalendarSource {
  DeviceCalendarService({DeviceCalendarPlugin? plugin, CalendarProbe? probe})
      // LocalDealReminder.init() 已初始化 timezone 数据库，这里不要重复初始化。
      : _plugin = plugin ?? DeviceCalendarPlugin(shouldInitTimezone: false),
        _probe = probe ?? const PlatformCalendarProbe();

  final DeviceCalendarPlugin _plugin;
  final CalendarProbe _probe;

  @override
  Future<bool> hasPermissions() => _boolResult(_plugin.hasPermissions);

  @override
  Future<bool> requestPermissions() => _boolResult(_plugin.requestPermissions);

  Future<bool> _boolResult(Future<Result<bool>> Function() call) async {
    try {
      final result = await call();
      return result.isSuccess && (result.data ?? false);
    } on Object {
      return false;
    }
  }

  @override
  Future<List<CalendarEventEntry>> fetchEvents({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!to.isAfter(from)) return <CalendarEventEntry>[];

    final entries = <CalendarEventEntry>[];
    final seen = <String>{};

    String? pluginError;
    try {
      await _readViaPlugin(from, to, entries, seen);
    } on CalendarReadException catch (e) {
      // 插件整体失败（例如日历列表读不出来）不应该直接判死：原生通道还能试。
      pluginError = e.message;
    }

    // 原生兜底。插件已经读到内容时也跑一遍：它可能只读到部分日历，
    // 而这边按 sourceId 去重，多读到的才会加进来。
    try {
      final fallback = await _probe.queryInstances(from: from, to: to);
      for (final entry in fallback) {
        if (seen.add(entry.sourceId)) entries.add(entry);
      }
    } on Object {
      // 兜底不可用时保持插件结果，不额外制造错误。
    }

    // 最后一道：Instances 视图被 ROM 过滤成 0 行时（小米等机型有过这种表现），
    // 改从 Events 表读原始行并自行展开重复规则。只有真的一条都没有才走这里，
    // 避免每次提取都多查一张大表。
    if (entries.isEmpty) {
      try {
        final raw = await _probe.queryEvents(from: from, to: to);
        for (final entry in raw) {
          if (seen.add(entry.sourceId)) entries.add(entry);
        }
      } on Object {
        // 同样不制造错误，交给诊断解释。
      }
    }

    entries.sort((a, b) => a.start.compareTo(b.start));

    // 一条都没有，且插件是明确报错（不是「真的空」）：把原因交给页面，
    // 但先看看是不是连权限都没有——那种情况要显示可操作的授权引导。
    if (entries.isEmpty && pluginError != null) {
      final diagnosis = await diagnose(from: from, to: to);
      if (diagnosis == null || !diagnosis.readPermission) {
        throw CalendarReadException(pluginError);
      }
    }

    return entries;
  }

  @override
  Future<CalendarDiagnosis?> diagnose({
    required DateTime from,
    required DateTime to,
  }) =>
      _probe.diagnose(from: from, to: to);

  Future<void> _readViaPlugin(
    DateTime from,
    DateTime to,
    List<CalendarEventEntry> entries,
    Set<String> seen,
  ) async {
    final calendars = await _plugin.retrieveCalendars();
    if (!calendars.isSuccess) {
      throw CalendarReadException(_errorsOf(calendars));
    }
    final list = calendars.data;
    if (list == null || list.isEmpty) {
      // 一个日历都没有：不在这里判死，交给原生通道和诊断。
      return;
    }

    // 插件要求 calendarId 非空，不能一次查全部日历，只能逐个日历读取再合并。
    for (final calendar in list) {
      final calendarId = calendar.id;
      if (calendarId == null || calendarId.isEmpty) continue;
      // name 可能是 ROM 塞的资源键（calendar_displayname_xiaomi）；这种情况下
      // 退回账户名，但账户名如果只是个数字 id（小米账户就是这样）就干脆留空，
      // 交给映射层用本地化的「系统日历」，别把数字当平台名写进记录。
      final account = calendar.accountName?.trim() ?? '';
      final accountFallback = RegExp(r'^\d+$').hasMatch(account) ? '' : account;
      final calendarName = displayCalendarName(
        calendar.name ?? '',
        accountFallback,
      );

      try {
        final result = await _plugin.retrieveEvents(
          calendarId,
          RetrieveEventsParams(startDate: from, endDate: to),
        );
        if (!result.isSuccess || result.data == null) continue;

        for (final event in result.data!) {
          final start = event.start;
          final end = event.end;
          if (start == null || end == null) continue;

          // Event.start / end 是 TZDateTime。用绝对毫秒重建 DateTime，
          // 直接得到设备本地时间，不依赖 timezone 包的 local 是否被设过。
          final startMs = start.millisecondsSinceEpoch;
          final endMs = end.millisecondsSinceEpoch;
          final sourceId = calendarSourceId(
            calendarId: calendarId,
            eventId: event.eventId ?? '',
            title: event.title ?? '',
            startMs: startMs,
          );
          if (!seen.add(sourceId)) continue;

          entries.add(CalendarEventEntry(
            sourceId: sourceId,
            title: event.title ?? '',
            start: DateTime.fromMillisecondsSinceEpoch(startMs),
            end: DateTime.fromMillisecondsSinceEpoch(endMs),
            calendarName: calendarName,
            description: event.description ?? '',
            location: event.location ?? '',
            url: resolveCalendarEventUrl(event.url, event.description ?? ''),
            allDay: event.allDay ?? false,
          ));
        }
      } on Object {
        // 隐藏日历 / 厂商 ROM 限制 / 单个日历被拒，不应中断其它日历的读取。
        continue;
      }
    }
  }

  static String _errorsOf<T>(Result<T> result) => result.errors.isEmpty
      ? 'unknown calendar error'
      : result.errors.map((e) => e.errorMessage).join('; ');
}
