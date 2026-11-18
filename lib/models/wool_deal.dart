import '../utils/calendar_grid.dart';
import 'device.dart';
import 'wool_time.dart';

/// 一条羊毛记录的状态。
enum WoolStatus { planned, done, received, expired }

WoolStatus woolStatusFromName(String? value) => WoolStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => WoolStatus.planned,
    );

/// 已经参与 / 到账 / 过期的记录不再提醒，避免事后还弹通知。
bool isReminderStatus(WoolStatus status) => status == WoolStatus.planned;

/// 一条「羊毛」记录。
///
/// 字段设计：平台 / 标题 / 活动日期为必填，链接 / 详情 / 攻略备注 / 收益 /
/// 活动时间段 / 到点提醒为选填，这样快速记一笔不会负担太重，需要复盘时又能写满。
///
/// 时间只存 HH:mm 字符串（[WoolTime]），日期单独存 yyyy-MM-dd：
/// 换时区或跨夏令时都不会让日历里的「哪天」发生漂移。
/// [deviceId] 是本机设备标签的外键（见 [Device]），旧数据缺字段时归到默认设备。
class WoolDeal {
  const WoolDeal({
    required this.id,
    required this.platform,
    required this.title,
    required this.date,
    required this.createdAt,
    this.detail = '',
    this.url = '',
    this.notes = '',
    this.status = WoolStatus.planned,
    this.amount,
    this.startTime,
    this.endTime,
    this.remind = true,
    this.sourceId,
    this.sourceName,
    this.deviceId = Device.defaultId,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String platform;
  final String title;
  final String detail;
  final String url;
  final String notes;
  final DateTime date;
  final WoolStatus status;
  final double? amount;
  final DateTime createdAt;

  /// 最后一次修改时刻，用于多设备同步时判断「谁的副本更新」。
  /// 旧数据没有这个字段，读出时回退成 [createdAt]。
  final DateTime updatedAt;

  /// 活动开始时间；null 表示「没填」（例如只抢到截止时间的券）。
  final WoolTime? startTime;

  /// 活动结束时间；null 表示「没填」。
  final WoolTime? endTime;

  /// 是否在开始 / 结束时间弹出系统通知。
  final bool remind;

  /// 外部来源的稳定去重键（目前来自手机系统日历）。
  /// 手工记的记录为 null；导入时用它避免同一个系统活动被重复导入。
  final String? sourceId;

  /// 来源名称（例如系统日历账户名），仅用于展示。
  final String? sourceName;

  /// 这条活动记在哪台设备名下（本机标签，非跨设备同步）。
  final String deviceId;

  bool get isFromDeviceCalendar => sourceId != null;

  String get dateText => dateKey(date);

  bool get hasTime => startTime != null || endTime != null;

  /// 结束时间早于开始时间视为跨天（例如 20:00-01:00 的秒杀）。
  bool get crossesMidnight =>
      startTime != null &&
      endTime != null &&
      endTime!.inMinutes < startTime!.inMinutes;

  /// 用于列表展示：10:00-12:00 / 10:00 / 23:00 / ''。
  String get timeRangeText {
    final s = startTime?.text;
    final e = endTime?.text;
    if (s != null && e != null) return '$s-$e';
    return s ?? e ?? '';
  }

  /// 排通知时才把「日期 + 时间」合成成本地 DateTime。
  DateTime? get startDateTime {
    final s = startTime;
    if (s == null) return null;
    return DateTime(date.year, date.month, date.day, s.hour, s.minute);
  }

  /// 跨天活动的结束时刻落在次日。
  DateTime? get endDateTime {
    final e = endTime;
    if (e == null) return null;
    return DateTime(
      date.year,
      date.month,
      date.day + (crossesMidnight ? 1 : 0),
      e.hour,
      e.minute,
    );
  }

  WoolDeal copyWith({
    String? platform,
    String? title,
    String? detail,
    String? url,
    String? notes,
    DateTime? date,
    WoolStatus? status,
    double? amount,
    bool clearAmount = false,
    WoolTime? startTime,
    WoolTime? endTime,
    bool clearStartTime = false,
    bool clearEndTime = false,
    bool? remind,
    String? deviceId,
    DateTime? updatedAt,
  }) =>
      WoolDeal(
        id: id,
        platform: platform ?? this.platform,
        title: title ?? this.title,
        detail: detail ?? this.detail,
        url: url ?? this.url,
        notes: notes ?? this.notes,
        date: date ?? this.date,
        status: status ?? this.status,
        amount: clearAmount ? null : (amount ?? this.amount),
        startTime: clearStartTime ? null : (startTime ?? this.startTime),
        endTime: clearEndTime ? null : (endTime ?? this.endTime),
        remind: remind ?? this.remind,
        createdAt: createdAt,
        // 来源标记不随编辑丢失，否则用户改过标题后会被重复导入。
        sourceId: sourceId,
        sourceName: sourceName,
        deviceId: deviceId ?? this.deviceId,
        // 默认保留原时刻；只有 Store 里的「用户改动」才会显式传新时间。
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 标记为「刚刚修改过」，同步时用这个时间做胜负判定。
  WoolDeal touch([DateTime? now]) => copyWith(updatedAt: now ?? DateTime.now());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'platform': platform,
        'title': title,
        'detail': detail,
        'url': url,
        'notes': notes,
        // 只存 yyyy-MM-dd，不存时间戳，避免换时区后日期漂移
        'date': dateKey(date),
        'status': status.name,
        'amount': amount,
        // 时间只存 HH:mm；缺失字段直接省略，旧版本 App 也能读这份 JSON
        'startTime': startTime?.text,
        'endTime': endTime?.text,
        'remind': remind,
        'createdAt': createdAt.microsecondsSinceEpoch,
        // 同步用：旧版本 App 读这份 JSON 会忽略该字段，不影响兼容。
        'updatedAt': updatedAt.microsecondsSinceEpoch,
        // 来源字段可缺省：旧数据没有，读出后就是手工记录。
        'sourceId': sourceId,
        'sourceName': sourceName,
        // 旧数据没有 deviceId，读出后统一归到默认设备。
        'deviceId': deviceId,
      };

  factory WoolDeal.fromJson(Map<String, dynamic> json) => WoolDeal(
        id: json['id'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        title: json['title'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        url: json['url'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        date: _parseDate(json['date']),
        status: woolStatusFromName(json['status'] as String?),
        amount: (json['amount'] as num?)?.toDouble(),
        startTime: WoolTime.tryParse(json['startTime']),
        endTime: WoolTime.tryParse(json['endTime']),
        // 旧数据没有这两个字段：默认开提醒，但没有时间也不会排通知。
        remind: json['remind'] as bool? ?? true,
        createdAt: _parseTime(json['createdAt']),
        // 旧数据没有 updatedAt：退回 createdAt，保证「老记录」在同步里不会莫名胜出。
        updatedAt: _parseTime(json['updatedAt'] ?? json['createdAt']),
        sourceId: json['sourceId'] as String?,
        sourceName: json['sourceName'] as String?,
        deviceId: _parseDeviceId(json['deviceId']),
      );

  /// 时间戳兼容数字 / 数字字符串，坏值回退 epoch 0（不会抛异常）。
  static DateTime _parseTime(Object? value) {
    if (value is num) {
      return DateTime.fromMicrosecondsSinceEpoch(value.toInt());
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        return DateTime.fromMicrosecondsSinceEpoch(parsed);
      }
    }
    return DateTime.fromMicrosecondsSinceEpoch(0);
  }

  // 兼容旧数据 / 脏数据：日期解析失败时退回今天，不让整个列表读不出来。
  static DateTime _parseDate(Object? value) {
    if (value is String && value.length >= 10) {
      try {
        return parseDateKey(value);
      } on Object {
        // fall through
      }
    }
    return dayOnly(DateTime.now());
  }

  static String _parseDeviceId(Object? value) =>
      (value is String && value.isNotEmpty) ? value : Device.defaultId;
}
