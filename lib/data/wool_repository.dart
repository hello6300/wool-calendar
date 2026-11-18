import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/wool_deal.dart';

/// 本机持久化：SharedPreferences 里存 JSON 数组。
///
/// 当前阶段只做本地开发，不接云服务、不引入数据库。数据量以「个人薅羊毛记录」
/// 为量级（几十到几百条），单键 JSON 足够；以后要换 SQLite 只需替换本类。
class WoolRepository {
  WoolRepository(this._prefs);

  static const String storageKey = 'appforge.wool_deals.v1';

  /// 设备注册表单独一个键，和记录分开存，避免互相污染。
  static const String devicesKey = 'appforge.devices.v1';

  /// 用户自定义的「常用平台」。null 表示从未配置过（由 Store 用默认值初始化）；
  /// 空数组表示用户主动删光了，必须原样保留，不能再自动塞回默认值。
  static const String platformsKey = 'appforge.platforms.v1';

  /// 删除墓碑：{记录 id: 删除时刻}。同步时用它判断「删除优先于旧副本」，
  /// 否则另一台设备上的旧数据会把已删除的记录复活。
  static const String tombstonesKey = 'appforge.tombstones.v1';

  /// 设备删除墓碑：{设备 id: 删除时刻}。
  /// 设备是按 id 取并集合并的，没有墓碑的话删掉的那台会被云端并集回来。
  static const String deviceTombstonesKey = 'appforge.device_tombstones.v1';

  /// 常用平台列表的最后修改时刻（整份列表 LWW，删除才能同步出去）。
  static const String platformsUpdatedAtKey =
      'appforge.platforms_updated_at.v1';

  final SharedPreferences _prefs;

  List<WoolDeal> load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return <WoolDeal>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <WoolDeal>[];

      final result = <WoolDeal>[];
      for (final item in decoded) {
        if (item is Map) {
          final deal = WoolDeal.fromJson(Map<String, dynamic>.from(item));
          if (deal.id.isNotEmpty) result.add(deal);
        }
      }
      return result;
    } on Object {
      // 单条损坏不应导致 App 打不开，最多丢弃这批数据。
      return <WoolDeal>[];
    }
  }

  Future<bool> save(List<WoolDeal> deals) => _prefs.setString(
        storageKey,
        jsonEncode(deals.map((d) => d.toJson()).toList()),
      );

  /// 设备列表：空 / 损坏 / 缺「本机」设备时都补回兜底设备，
  /// 保证任何情况下至少有一台设备，记录不会失去归属。
  ///
  /// 判断锚点用 [Device.isDefault] 而不是固定 id：识别出身份后本机 id 是
  /// `dev-xxxxxxxx`，写死 `default` 会在每次加载时又塞回一台幽灵设备。
  List<Device> loadDevices() {
    final raw = _prefs.getString(devicesKey);
    if (raw == null || raw.isEmpty) return <Device>[Device.fallback];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Device>[Device.fallback];

      final result = <Device>[];
      for (final item in decoded) {
        if (item is Map) {
          final device = Device.fromJson(Map<String, dynamic>.from(item));
          if (device.id.isNotEmpty) result.add(device);
        }
      }
      final hasAnchor = result.any((d) => d.isDefault);
      if (!hasAnchor) return <Device>[Device.fallback, ...result];
      // 本机设备始终排第一，筛选条和下拉里顺序稳定。
      result.sort((a, b) {
        final ai = a.isDefault ? 0 : 1;
        final bi = b.isDefault ? 0 : 1;
        return ai.compareTo(bi);
      });
      return result;
    } on Object {
      return <Device>[Device.fallback];
    }
  }

  /// 本机身份缓存：设备 id 与机型名。
  ///
  /// 缓存的用处是「原生读不到时不至于把用户已经识别好的设备搞丢」——
  /// 个别 ROM 的通道异常、或系统繁忙超时，读缓存比退回 `default` 更好。
  static const String thisDeviceKey = 'appforge.this_device.v1';

  ({String id, String label})? loadThisDevice() {
    final raw = _prefs.getString(thisDeviceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final id = (decoded['id'] as String? ?? '').trim();
      if (id.isEmpty) return null;
      return (id: id, label: (decoded['label'] as String? ?? '').trim());
    } on Object {
      return null;
    }
  }

  Future<bool> saveThisDevice(String id, String label) => _prefs.setString(
        thisDeviceKey,
        jsonEncode(<String, dynamic>{'id': id, 'label': label}),
      );

  Future<bool> saveDevices(List<Device> devices) => _prefs.setString(
        devicesKey,
        jsonEncode(devices.map((d) => d.toJson()).toList()),
      );

  /// 读常用平台。返回 null = 从未配置（用默认值初始化），[] = 用户删光了。
  List<String>? loadPlatforms() {
    final raw = _prefs.getString(platformsKey);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;

      final result = <String>[];
      for (final item in decoded) {
        if (item is String) {
          final name = item.trim();
          // 去空、去重，避免坏数据在 chip 里出现空壳。
          if (name.isNotEmpty && !result.contains(name)) result.add(name);
        }
      }
      return result;
    } on Object {
      return null;
    }
  }

  Future<bool> savePlatforms(List<String> platforms) =>
      _prefs.setString(platformsKey, jsonEncode(platforms));

  DateTime? loadPlatformsUpdatedAt() {
    final micros = _prefs.getInt(platformsUpdatedAtKey);
    return micros == null ? null : DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  Future<bool> savePlatformsUpdatedAt(DateTime at) =>
      _prefs.setInt(platformsUpdatedAtKey, at.microsecondsSinceEpoch);

  /// 读删除墓碑；坏数据当作没有墓碑，不让同步因为一条脏数据整体失败。
  Map<String, DateTime> loadTombstones() => _loadTombstones(tombstonesKey);

  Map<String, DateTime> loadDeviceTombstones() =>
      _loadTombstones(deviceTombstonesKey);

  Future<bool> saveTombstones(Map<String, DateTime> tombstones) =>
      _saveTombstones(tombstonesKey, tombstones);

  Future<bool> saveDeviceTombstones(Map<String, DateTime> tombstones) =>
      _saveTombstones(deviceTombstonesKey, tombstones);

  Map<String, DateTime> _loadTombstones(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String, DateTime>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, DateTime>{};

      final result = <String, DateTime>{};
      decoded.forEach((key, value) {
        if (key is String && key.isNotEmpty && value is num) {
          result[key] = DateTime.fromMicrosecondsSinceEpoch(value.toInt());
        }
      });
      return result;
    } on Object {
      return <String, DateTime>{};
    }
  }

  Future<bool> _saveTombstones(String key, Map<String, DateTime> tombstones) =>
      _prefs.setString(
        key,
        jsonEncode(tombstones.map(
          (id, at) => MapEntry<String, int>(id, at.microsecondsSinceEpoch),
        )),
      );
}
