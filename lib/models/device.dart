/// 一台「设备」是一个分类标签：本机 / 平板 / 备用机 / 工作机…
///
/// 使用场景：同一个羊毛活动常常「每台设备各领一次」，需要按设备分别记账。
/// 它**不读取其它设备的系统日历，也不联网同步**：手机上的 App 无法直接访问
/// 另一台平板的 CalendarContract / EventKit，这里只是给记录打一个本地标签。
///
/// 「本机」这台设备（[isDefault]）由原生识别得出：id 从 `ANDROID_ID` 派生，
/// 名字默认取机型（Redmi K30 Pro）。因此两台手机装同一个 App 不会互相冒充，
/// 同步到云端时也能分清楚记录是谁的。拿不到身份时才退回 [defaultId]。
///
/// 旧数据缺 `deviceId` 时统一归到本机设备，保证升级后历史记录不会「消失」。
class Device {
  const Device({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.autoNamed = false,
  });

  /// 默认设备（本机）的稳定 ID。
  ///
  /// 只在拿不到设备身份时使用（老系统 / 通道异常）：所有手机共用这一个 id，
  /// 云端无法区分谁是谁。能识别时设备 id 是原生派生的 `dev-xxxxxxxx`。
  static const String defaultId = 'default';

  /// 首次启动 / 存储损坏时的兜底设备列表里唯一的设备。
  static const Device fallback = Device(
    id: defaultId,
    name: '',
    isDefault: true,
  );

  final String id;
  final String name;
  final bool isDefault;

  /// [name] 是自动识别出来的机型名（不是用户自己起的）。
  ///
  /// 只有自动命名才允许在机型变化时被覆盖；用户改过名之后这里就是 false，
  /// 绝不拿机型名去盖用户自己写的「主力机」。
  final bool autoNamed;

  /// 展示名：`name` 为空时说明还没重命名过，用当前语言的默认设备名。
  String displayName(String defaultLabel) => name.isEmpty ? defaultLabel : name;

  Device copyWith({String? name, bool? isDefault, bool? autoNamed}) => Device(
        id: id,
        name: name ?? this.name,
        isDefault: isDefault ?? this.isDefault,
        autoNamed: autoNamed ?? this.autoNamed,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'isDefault': isDefault,
        'autoNamed': autoNamed,
      };

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isDefault: json['isDefault'] as bool? ?? false,
        autoNamed: json['autoNamed'] as bool? ?? false,
      );
}
