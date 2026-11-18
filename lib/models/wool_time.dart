/// 活动时间的纯 Dart 值对象：只存「时:分」，不带日期、不带时区。
///
/// 与 [WoolDeal.date] 分开存，是为了让日历分组、跨时区、夏令时都不影响
/// 「这天有哪几条羊毛」；只有排通知时才把日期和时间合成一个本地 DateTime。
library;

class WoolTime {
  const WoolTime(this.hour, this.minute)
      : assert(hour >= 0 && hour < 24, 'hour must be 0..23'),
        assert(minute >= 0 && minute < 60, 'minute must be 0..59');

  final int hour;
  final int minute;

  /// 距当天 00:00 的分钟数，用于比较先后与判断跨天。
  int get inMinutes => hour * 60 + minute;

  /// 24 小时制 HH:mm，同时也是持久化格式。
  String get text =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  String toString() => text;

  /// 兼容旧数据 / 脏数据：只接受 HH:mm，其它一律当「没填」。
  /// 也接受 H:mm（例如 9:05），但要求分钟必须是两位，避免歧义。
  static WoolTime? tryParse(Object? value) {
    if (value is! String) return null;
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    if (match == null) return null;
    final h = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return WoolTime(h, m);
  }

  @override
  bool operator ==(Object other) =>
      other is WoolTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}
