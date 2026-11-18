import '../models/wool_deal.dart';
import '../models/wool_time.dart';
import '../utils/calendar_grid.dart';
import 'calendar_probe.dart';

/// 从手机系统日历读到的一个活动。
///
/// 这是 App 内部的中立数据结构，字段已统一成「设备本地时间」，不暴露
/// device_calendar 的 TZDateTime / Event，方便替换实现、也方便单元测试。
class CalendarEventEntry {
  const CalendarEventEntry({
    required this.sourceId,
    required this.title,
    required this.start,
    required this.end,
    required this.calendarName,
    this.description = '',
    this.location = '',
    this.url = '',
    this.allDay = false,
  });

  /// 稳定的跨平台去重键：'device_calendar:<日历ID>:<事件ID>:<开始时刻>'。
  /// 带上开始时刻是为了让重复活动的每次实例都能分别导入。
  final String sourceId;

  final String title;
  final DateTime start;
  final DateTime end;
  final String calendarName;
  final String description;
  final String location;
  final String url;
  final bool allDay;

  /// 列表副标题：2026-11-14 10:00-11:30 / 2026-11-14 · All-day。
  /// 文案由调用方从 l10n 传入，避免纯数据层硬编码中文。
  String timeText(String allDayLabel) {
    String hhmm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final day = dateKey(start);
    if (allDay) return '$day · $allDayLabel';
    if (dateKey(end) == day) return '$day ${hhmm(start)}-${hhmm(end)}';
    return '$day ${hhmm(start)} → ${dateKey(end)} ${hhmm(end)}';
  }
}

/// 系统日历读取边界。真实 App 注入 [DeviceCalendarService]，测试注入 Fake，
/// 这样 widget test 不需要真实插件也能覆盖「权限 / 列表 / 导入」全流程。
abstract class DeviceCalendarSource {
  Future<bool> hasPermissions();

  Future<bool> requestPermissions();

  /// 读取 [from, to) 区间内所有日历的活动；单个日历失败时跳过而不是整体抛错。
  Future<List<CalendarEventEntry>> fetchEvents({
    required DateTime from,
    required DateTime to,
  });

  /// 「一条都读不到」时做的体检：权限、日历账户、Instances / Events 行数。
  ///
  /// 默认返回 null —— 测试里的 Fake 不需要实现，页面对 null 也有降级文案。
  Future<CalendarDiagnosis?> diagnose({
    required DateTime from,
    required DateTime to,
  }) async =>
      null;
}

/// 映射时用到的本地化文案。由页面从 AppLocalizations 构造后传入，
/// 纯 Dart 转换函数因此不需要依赖 Flutter / BuildContext。
class CalendarImportLabels {
  const CalendarImportLabels({
    required this.fallbackPlatform,
    required this.fallbackTitle,
    required this.allDayTag,
    required this.endsAt,
    required this.location,
    required this.source,
  });

  final String fallbackPlatform;
  final String fallbackTitle;
  final String allDayTag;

  /// 例如「结束：2026-11-16 18:00」。
  final String Function(String value) endsAt;

  /// 例如「地点：xx 门店」。
  final String Function(String value) location;

  /// 例如「来源：手机日历 · xxx」。
  final String Function(String value) source;
}

String _stamp(DateTime d) => '${dateKey(d)} '
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// Calendars 表里的 `calendar_displayName` 未必是人类可读的名字。
///
/// AOSP 与 MIUI 都会把「本地 / 厂商账户」日历的名字存成**资源键**
/// （`calendar_displayname_local`、`calendar_displayname_xiaomi`），由日历 App
/// 自己翻译。第三方 App 拿到的是键本身，直接当平台名写进记录就会变成一串
/// 英文，用户看到的是 `calendar_displayname_xiaomi`。
///
/// 认不出来时退回调用方给的兜底名（一般是本地化的「系统日历」），
/// 宁可信息少一点，也不要往用户数据里塞资源键。
String displayCalendarName(String raw, String fallback) {
  final name = raw.trim();
  if (name.isEmpty) return fallback.trim();
  if (RegExp(r'^calendar_displayname(_|$)').hasMatch(name)) return fallback.trim();
  return name;
}

/// 两条读取通道（device_calendar 插件 / 原生 CalendarProvider）共用的去重键。
///
/// 必须严格一致：同一个活动若因 eventId 缺失而在两边生成不同的键，
/// 就会出现「一次提取把同一条日程导入两遍」。带开始时刻是为了让重复活动的
/// 每次实例各自成为一条，而不是被当成同一条。
String calendarSourceId({
  required String calendarId,
  required String eventId,
  required String title,
  required int startMs,
}) {
  final id = eventId.trim();
  // 拿不到 eventId 时退回标题，加 `t:` 前缀避免与真实数字 id 撞车。
  final key = id.isNotEmpty ? id : 't:${title.trim()}';
  return 'device_calendar:$calendarId:$key:$startMs';
}

/// 纯函数：把一条系统日历活动映射成羊毛记录。
///
/// 时间映射规则（与 WoolDeal 的既有语义对齐）：
/// - 日期取活动的**开始日**；全天活动不填时间、不排提醒。
/// - 同日结束 → startTime / endTime 都填上。
/// - 次日结束且结束时刻早于开始时刻 → 正好命中 WoolDeal 的「跨天」规则。
/// - 其它跨多日情况模型表达不了，只保留开始时间，把完整结束时刻写进详情，
///   避免排出一个错误的结束提醒。
WoolDeal calendarEventToDeal(
  CalendarEventEntry event, {
  required String id,
  required DateTime createdAt,
  required CalendarImportLabels labels,
}) {
  final start = event.start;
  final end = event.end;
  final date = dayOnly(start);
  final allDay = event.allDay;

  WoolTime? startTime;
  WoolTime? endTime;
  String? endsNote;

  if (!allDay) {
    startTime = WoolTime(start.hour, start.minute);
    final startMinutes = startTime.inMinutes;
    final endMinutes = end.hour * 60 + end.minute;
    final sameDay = dateKey(end) == dateKey(date);
    final nextDay =
        dateKey(end) == dateKey(DateTime(date.year, date.month, date.day + 1));

    if (sameDay) {
      endTime = WoolTime(end.hour, end.minute);
    } else if (nextDay && endMinutes < startMinutes) {
      // WoolDeal.crossesMidnight 会把「结束早于开始」算成次日，语义天然吻合。
      endTime = WoolTime(end.hour, end.minute);
    } else {
      endsNote = labels.endsAt(_stamp(end));
    }
  }

  // 名字是资源键时按「无名字」处理，退回本地化的兜底平台名。
  final calendarName = displayCalendarName(
    event.calendarName,
    labels.fallbackPlatform,
  );

  final detailParts = <String>[];
  if (event.description.trim().isNotEmpty) {
    detailParts.add(event.description.trim());
  }
  if (allDay) detailParts.add(labels.allDayTag);
  if (event.location.trim().isNotEmpty) {
    detailParts.add(labels.location(event.location.trim()));
  }
  if (endsNote != null) detailParts.add(endsNote);
  detailParts.add(labels.source(calendarName));

  return WoolDeal(
    id: id,
    platform: calendarName,
    title:
        event.title.trim().isEmpty ? labels.fallbackTitle : event.title.trim(),
    detail: detailParts.join('\n'),
    url: event.url.trim(),
    notes: '',
    date: date,
    status: WoolStatus.planned,
    amount: null,
    startTime: startTime,
    endTime: endTime,
    // 全天活动没有具体时刻，开了提醒也不会排通知，直接关掉更诚实。
    remind: !allDay,
    createdAt: createdAt,
    sourceId: event.sourceId,
    sourceName: calendarName,
  );
}

/// 插件把 eventURL 包装成了 data: URI（见 Event.fromJson 的 Uri.dataFromString），
/// 直接 toString() 会得到「data:,https%3A...」这类不可用文本。只有真正的
/// http(s) 才直接采用；否则从描述里提取第一条链接——活动链接通常写在日历备注里。
/// 放在纯 Dart 层是为了能脱离原生插件单独测试。
String resolveCalendarEventUrl(Uri? uri, String description) {
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return uri.toString();
  }
  final match = RegExp(r'''https?://[^\s<>"']+''').firstMatch(description);
  return match?.group(0) ?? '';
}
