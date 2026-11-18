import 'calendar_grid.dart';

/// 「从手机日历提取活动」时用户可自选的时间范围。
///
/// 纯 Dart 值对象，不依赖 Flutter：页面只负责把用户操作翻译成
/// [withStart] / [withEnd] / [ImportRange.fromPreset]，读取层只消费
/// [from] 与 [toExclusive]。这样「范围怎么算」可以脱离 UI 单独测试。
enum ImportRangePreset {
  today,
  next7Days,
  thisMonth,
  next30Days,
  custom,
}

class ImportRange {
  ImportRange({
    required this.start,
    required this.end,
    this.preset = ImportRangePreset.custom,
  }) : assert(!start.isAfter(end), 'start 不能晚于 end');

  /// 一次最多提取 366 天，避免误选超大范围把系统日历全量扫一遍。
  static const int maxDays = 366;

  /// 起止日期都只保留到「天」（含首尾两天）。
  final DateTime start;
  final DateTime end;
  final ImportRangePreset preset;

  /// 默认进页面时跟随日历页所在月份，仍是整月，但**不会自动读取**。
  /// 标记为 custom：日历页可能翻到别的月份，不该谎称当前选中的是「本月」。
  factory ImportRange.initialMonth(DateTime month) {
    final first = monthStart(month);
    return ImportRange(
      start: first,
      end: _addDays(addMonths(first, 1), -1),
      preset: ImportRangePreset.custom,
    );
  }

  factory ImportRange.fromPreset(ImportRangePreset preset, DateTime anchor) {
    final today = dayOnly(anchor);
    switch (preset) {
      case ImportRangePreset.today:
        return ImportRange(start: today, end: today, preset: preset);
      case ImportRangePreset.next7Days:
        return ImportRange(
          start: today,
          end: _addDays(today, 6),
          preset: preset,
        );
      case ImportRangePreset.thisMonth:
        final first = monthStart(today);
        return ImportRange(
          start: first,
          end: _addDays(addMonths(first, 1), -1),
          preset: preset,
        );
      case ImportRangePreset.next30Days:
        return ImportRange(
          start: today,
          end: _addDays(today, 29),
          preset: preset,
        );
      case ImportRangePreset.custom:
        return ImportRange(start: today, end: today, preset: preset);
    }
  }

  /// 左闭右开的查询区间：结束日当天的活动也要包含，所以上界是次日零点。
  DateTime get from => dayOnly(start);

  DateTime get toExclusive => _addDays(dayOnly(end), 1);

  /// 含首尾，例如 11-14 ~ 11-14 算 1 天。
  int get dayCount => (end.difference(start).inHours / 24).round() + 1;

  bool get isMaxLength => dayCount >= maxDays;

  /// 结果条上展示的范围摘要，避免本地化文案里再拼日期。
  String get label => '${dateKey(start)} ~ ${dateKey(end)}';

  bool contains(DateTime dateTime) =>
      !dateTime.isBefore(from) && dateTime.isBefore(toExclusive);

  /// 用户改开始日期：晚于原结束日时把结束日一起挪过去，不弹错误框打断操作。
  ImportRange withStart(DateTime picked) {
    final s = dayOnly(picked);
    var e = dayOnly(end);
    if (s.isAfter(e)) e = s;
    if (_daysBetween(s, e) > maxDays) e = _addDays(s, maxDays - 1);
    return ImportRange(start: s, end: e);
  }

  /// 用户改结束日期：早于原开始日时把开始日一起挪回来。
  ImportRange withEnd(DateTime picked) {
    final e = dayOnly(picked);
    var s = dayOnly(start);
    if (e.isBefore(s)) s = e;
    if (_daysBetween(s, e) > maxDays) s = _addDays(e, -(maxDays - 1));
    return ImportRange(start: s, end: e);
  }

  @override
  bool operator ==(Object other) =>
      other is ImportRange &&
      dateKey(other.start) == dateKey(start) &&
      dateKey(other.end) == dateKey(end) &&
      other.preset == preset;

  @override
  int get hashCode => Object.hash(dateKey(start), dateKey(end), preset);

  static DateTime _addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  static int _daysBetween(DateTime a, DateTime b) =>
      (b.difference(a).inHours / 24).round();
}
