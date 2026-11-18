import 'dart:async';

import 'package:flutter/services.dart';

/// 「这是哪台手机」——由原生读机型与设备标识后算出来的稳定身份。
///
/// 为什么需要它：设备以前是纯手工标签，每台手机都可以随手叫「手机」，
/// 同一份 AndroidManifest 装到两台手机上，云端就无法分辨记录属于谁。
/// 现在用 `ANDROID_ID` 派生一个不重复的 id（`dev-xxxxxxxx`），
/// 用 `Build.MODEL` 派生一个好认的名字（Redmi K30 Pro）。
///
/// id 只取 `ANDROID_ID` 的哈希：远端 JSON 里不出现原始系统标识，
/// 同时保证「同机重装 = 同一个 id」「不同手机 = 不同 id」。
class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.label,
    required this.model,
    required this.manufacturer,
  });

  /// 形如 `dev-1a2b3c4d`，稳定且不重复。
  final String id;

  /// 展示用机型名，可能为空（机型信息缺失时）。
  final String label;

  final String model;
  final String manufacturer;

  /// 机型名最长保留多少字符：设备 chip 是单行，太长会把日历挤变形。
  static const int maxLabelLength = 24;

  static const MethodChannel _channel = MethodChannel('appforge/device_info');

  /// 读本机身份。读不到（通道缺失 / 系统异常 / 没有 ANDROID_ID）返回 null，
  /// 调用方应退回「所有人都是默认设备」的旧行为，而不是报错卡住启动。
  static Future<DeviceIdentity?> read({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('identity')
          .timeout(timeout);
      return fromRaw(raw);
    } on Object {
      return null;
    }
  }

  /// 把原生返回的原始字段解析成身份。抽成静态方法，单测不需要平台通道。
  static DeviceIdentity? fromRaw(Map<String, dynamic>? raw) {
    if (raw == null) return null;

    final androidId = (raw['androidId'] as String? ?? '').trim();
    // 没有设备标识就只能退回旧行为：造出来的 id 不唯一，反而会把两台手机
    // 合并成一台，比「不识别」更糟。
    if (androidId.isEmpty) return null;

    final model = (raw['model'] as String? ?? '').trim();
    final manufacturer = (raw['manufacturer'] as String? ?? '').trim();
    final codename = (raw['device'] as String? ?? '').trim();

    return DeviceIdentity(
      id: 'dev-${_fnv1a(androidId)}',
      label: buildLabel(
        model: model,
        manufacturer: manufacturer,
        codename: codename,
      ),
      model: model,
      manufacturer: manufacturer,
    );
  }

  /// 机型名整理：`Build.MODEL` 在部分机器上是内部代号（`M2007J3SC`、`SM-G9910`），
  /// 加厂商名才认得出；正常机型（`Redmi K30 Pro`）原样保留。
  static String buildLabel({
    required String model,
    required String manufacturer,
    required String codename,
  }) {
    var name = model.trim();
    if (name.isEmpty) name = codename.trim();
    if (name.isEmpty) name = manufacturer.trim();
    if (name.isEmpty) return '';

    // 纯代号：只有大写字母 / 数字 / 连字符，没有小写字母也没有空格。
    final looksLikeCode = RegExp(r'^[A-Z0-9\-]+$').hasMatch(name);
    if (looksLikeCode &&
        manufacturer.isNotEmpty &&
        !name.toLowerCase().startsWith(manufacturer.toLowerCase())) {
      name = '$manufacturer $name';
    }

    if (name.length > maxLabelLength) {
      name = name.substring(0, maxLabelLength).trimRight();
    }
    return name;
  }

  /// FNV-1a 32 位：够短（8 位十六进制）、够散，不引入 crypto 依赖。
  static String _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
      hash ^= (unit >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
