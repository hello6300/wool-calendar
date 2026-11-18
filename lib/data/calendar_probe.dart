import 'package:flutter/services.dart';

import 'device_calendar_source.dart';

/// 一个系统日历账户（对应 CalendarProvider 里 Calendars 表的一行）。
///
/// 诊断用：能看出 ROM 里到底注册了哪些日历、是否被隐藏（visible=0）、
/// 是否允许同步事件（syncEvents=0 的日历通常读不到活动）。
class CalendarAccountInfo {
  const CalendarAccountInfo({
    required this.id,
    required this.name,
    required this.account,
    required this.visible,
    required this.syncEvents,
    required this.accessLevel,
    this.accountType = '',
  });

  final String id;
  final String name;
  final String account;
  final String accountType;
  final bool visible;
  final bool syncEvents;
  final int accessLevel;

  bool get readable => visible || syncEvents;

  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final a = account.trim();
    return a.isNotEmpty ? a : 'ID $id';
  }

  static CalendarAccountInfo fromMap(Map<Object?, Object?> map) =>
      CalendarAccountInfo(
        id: '${map['id'] ?? ''}',
        name: '${map['name'] ?? ''}',
        account: '${map['account'] ?? ''}',
        accountType: '${map['accountType'] ?? ''}',
        visible: (map['visible'] as num?)?.toInt() == 1,
        syncEvents: (map['syncEvents'] as num?)?.toInt() == 1,
        accessLevel: (map['accessLevel'] as num?)?.toInt() ?? 0,
      );
}

/// 某个日历在本区间内的实例条数。用来分辨「一条都没有」和「只有某个日历被过滤」。
class CalendarInstanceCount {
  const CalendarInstanceCount({required this.calendarId, required this.count});

  final String calendarId;
  final int count;

  static CalendarInstanceCount? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return CalendarInstanceCount(
      calendarId: '${raw['calendarId'] ?? ''}',
      count: (raw['count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 「本机日历到底能不能读」的一次性体检结果。
///
/// 有这个结构，界面才能把「这个范围没有活动」和「根本读不到日历」分开说，
/// 而不是两种情况都显示同一句话。
class CalendarDiagnosis {
  const CalendarDiagnosis({
    required this.readPermission,
    required this.writePermission,
    required this.calendars,
    required this.instanceCount,
    required this.eventRowCount,
    required this.errors,
    this.perCalendar = const <CalendarInstanceCount>[],
    this.recurringCount = 0,
    this.tableRowCount = 0,
    this.expandedCount = 0,
    this.manufacturer = '',
    this.model = '',
    this.sdkInt = 0,
  });

  final bool readPermission;
  final bool writePermission;
  final List<CalendarAccountInfo> calendars;

  /// Instances 视图在范围内的行数（已展开重复活动）。
  final int instanceCount;

  /// Events 表**与区间有关联**的原始行数（未展开重复活动）。
  /// 重复日程只要 `DTSTART <= to` 就会被算进来，不等于区间内真的有实例。
  final int eventRowCount;

  /// 其中带重复规则的行数。
  final int recurringCount;

  /// Events 表的总行数（不分区间）。判断「本机到底有没有数据」只能看这个。
  final int tableRowCount;

  /// 直读 Events 表并展开重复规则后，区间内真正得到的实例数。
  final int expandedCount;

  /// Instances 按日历分组的条数。
  final List<CalendarInstanceCount> perCalendar;

  final List<String> errors;
  final String manufacturer;
  final String model;
  final int sdkInt;

  /// provider 里一条日历都没有：常见于权限被「空白通行证」之类的功能接管。
  bool get noCalendars => calendars.isEmpty;

  /// 有原始事件、但 Instances 视图是空的 **且** 直读 Events 表能展开出实例
  /// → 确实存在「ROM 过滤实例视图」这回事。
  ///
  /// 注意必须带上 `expandedCount > 0`：Events 表的区间筛选对重复日程只要求
  /// `DTSTART <= to`（因为 RRULE 可能一直重复下去），所以一年前的 `COUNT=3`
  /// 日程不管查哪个区间都会被算作「原始事件」。只看 `eventRowCount` 的话，
  /// 任何空区间都会被误报成「手机限制了日历」。
  bool get instancesFiltered =>
      eventRowCount > 0 && instanceCount == 0 && expandedCount > 0;

  /// Events 表里一条日程都没有（不分区间）→ 权限被接管、或数据根本没同步到本机。
  bool get noEventsAtAll =>
      readPermission && calendars.isNotEmpty && tableRowCount == 0;

  /// 权限、日历、数据三者都在，只是这个区间恰好没有活动。
  bool get genuinelyEmpty =>
      readPermission &&
      calendars.isNotEmpty &&
      instanceCount == 0 &&
      expandedCount == 0 &&
      tableRowCount > 0;

  /// 有日历，但一个实例都没有——日历本身不可见或被 ROM 隐藏的典型表现。
  bool get calendarsButNoInstances =>
      readPermission && calendars.isNotEmpty && instanceCount == 0;

  bool get isXiaomi {
    final m = manufacturer.toUpperCase();
    final b = model.toUpperCase();
    return m.contains('XIAOMI') || m.contains('REDMI') || b.contains('XIAOMI');
  }

  String get deviceLabel {
    final m = model.trim();
    final man = manufacturer.trim();
    if (m.isEmpty) return man;
    if (man.isEmpty) return m;
    return '$man $m';
  }

  static CalendarDiagnosis? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final list = <CalendarAccountInfo>[];
    final calendars = raw['calendars'];
    if (calendars is List) {
      for (final item in calendars) {
        if (item is Map) list.add(CalendarAccountInfo.fromMap(item));
      }
    }
    final errors = <String>[];
    final rawErrors = raw['errors'];
    if (rawErrors is List) {
      for (final e in rawErrors) {
        errors.add('$e');
      }
    }
    final perCalendar = <CalendarInstanceCount>[];
    final rawPer = raw['perCalendar'];
    if (rawPer is List) {
      for (final item in rawPer) {
        final parsed = CalendarInstanceCount.fromMap(item);
        if (parsed != null) perCalendar.add(parsed);
      }
    }
    return CalendarDiagnosis(
      readPermission: raw['readPermission'] == true,
      writePermission: raw['writePermission'] == true,
      calendars: list,
      instanceCount: (raw['instanceCount'] as num?)?.toInt() ?? 0,
      eventRowCount: (raw['eventRowCount'] as num?)?.toInt() ?? 0,
      recurringCount: (raw['recurringCount'] as num?)?.toInt() ?? 0,
      tableRowCount: (raw['tableRowCount'] as num?)?.toInt() ?? 0,
      expandedCount: (raw['expandedCount'] as num?)?.toInt() ?? 0,
      perCalendar: perCalendar,
      errors: errors,
      manufacturer: '${raw['manufacturer'] ?? ''}',
      model: '${raw['model'] ?? ''}',
      sdkInt: (raw['sdkInt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 原生兜底通道：直接读 CalendarProvider。
///
/// 只读，且只在插件读不到东西时才调用。做成了接口，测试里可以注入假实现。
abstract class CalendarProbe {
  /// 走 Instances 视图，和插件同源，但不逐个日历回查、不加额外过滤条件。
  Future<List<CalendarEventEntry>> queryInstances({
    required DateTime from,
    required DateTime to,
  });

  /// 走 Events 表（原始行）并自行展开重复规则。
  ///
  /// 当 ROM 把 Instances 视图过滤成 0 行时，这是唯一还能拿到数据的方式。
  Future<List<CalendarEventEntry>> queryEvents({
    required DateTime from,
    required DateTime to,
  });

  Future<CalendarDiagnosis?> diagnose({
    required DateTime from,
    required DateTime to,
  });
}

/// 通过 MethodChannel 调 [CalendarProbe] 的 Kotlin 实现。
class PlatformCalendarProbe implements CalendarProbe {
  const PlatformCalendarProbe({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('appforge/calendar_probe');

  final MethodChannel _channel;

  @override
  Future<List<CalendarEventEntry>> queryInstances({
    required DateTime from,
    required DateTime to,
  }) async {
    final raw = await _invokeList('queryInstances', from, to);
    return _toEntries(raw);
  }

  @override
  Future<List<CalendarEventEntry>> queryEvents({
    required DateTime from,
    required DateTime to,
  }) async {
    final raw = await _invokeList('queryEvents', from, to);
    return _toEntries(raw);
  }

  Future<List<Object?>> _invokeList(
    String method,
    DateTime from,
    DateTime to,
  ) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        method,
        <String, Object?>{
          'from': from.millisecondsSinceEpoch,
          'to': to.millisecondsSinceEpoch,
        },
      );
      return raw ?? const <Object?>[];
    } on Object {
      // 原生侧缺实现（例如旧版本包）时按「读不到」处理，由诊断解释。
      return const <Object?>[];
    }
  }

  @override
  Future<CalendarDiagnosis?> diagnose({
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'diagnose',
        <String, Object?>{
          'from': from.millisecondsSinceEpoch,
          'to': to.millisecondsSinceEpoch,
        },
      );
      return CalendarDiagnosis.fromMap(raw);
    } on Object {
      return null;
    }
  }

  List<CalendarEventEntry> _toEntries(List<Object?> raw) {
    final entries = <CalendarEventEntry>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final begin = (item['begin'] as num?)?.toInt() ?? 0;
      if (begin <= 0) continue;
      final end = (item['end'] as num?)?.toInt() ?? begin;
      final calendarId = '${item['calendarId'] ?? ''}';
      final eventId = '${item['eventId'] ?? ''}';
      final title = '${item['title'] ?? ''}';
      // 与插件路径共用同一个去重键，同一个活动不会因两条通道各导入一次。
      final sourceId = calendarSourceId(
        calendarId: calendarId,
        eventId: eventId,
        title: title,
        startMs: begin,
      );
      if (!seen.add(sourceId)) continue;
      final description = '${item['description'] ?? ''}';
      entries.add(
        CalendarEventEntry(
          sourceId: sourceId,
          title: title,
          start: DateTime.fromMillisecondsSinceEpoch(begin),
          end: DateTime.fromMillisecondsSinceEpoch(end),
          calendarName: displayCalendarName(
            '${item['calendarName'] ?? ''}',
            '',
          ),
          description: description,
          location: '${item['location'] ?? ''}',
          url: resolveCalendarEventUrl(null, description),
          allDay: item['allDay'] == true,
        ),
      );
    }
    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }
}
