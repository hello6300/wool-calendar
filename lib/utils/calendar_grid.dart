/// 日历相关的纯 Dart 工具函数。不依赖 Flutter，便于单元测试。
library;

/// 去掉时分秒，避免时区与毫秒影响「按天」分组。
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 统一的日期键：yyyy-MM-dd。持久化与日历分组都用它。
String dateKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime parseDateKey(String key) => DateTime(
      int.parse(key.substring(0, 4)),
      int.parse(key.substring(5, 7)),
      int.parse(key.substring(8, 10)),
    );

bool isSameDay(DateTime a, DateTime b) => dateKey(a) == dateKey(b);

DateTime monthStart(DateTime d) => DateTime(d.year, d.month, 1);

/// 月份加减，自动处理跨年（含负数 delta）。
DateTime addMonths(DateTime d, int delta) {
  final total = d.year * 12 + (d.month - 1) + delta;
  return DateTime(total ~/ 12, total % 12 + 1, 1);
}

/// 周一为一周第一天，固定 6 行 × 7 列 = 42 格。
/// 上/下月的补位日期也在列表里，由 UI 置灰，保证网格高度稳定不跳动。
List<DateTime> calendarGrid(DateTime month) {
  final first = monthStart(month);
  final start = first.subtract(Duration(days: first.weekday - 1));
  return List<DateTime>.generate(
    42,
    (i) => DateTime(start.year, start.month, start.day + i),
    growable: false,
  );
}
