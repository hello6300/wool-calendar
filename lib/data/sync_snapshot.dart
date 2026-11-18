import 'dart:convert';

import '../models/device.dart';
import '../models/wool_deal.dart';

/// 一次同步的完整数据快照：既用于写远端文件，也用于本地内存导出。
///
/// 远端是一个**单 JSON 文件**（不是数据库），换来的是实现简单、任何 WebDAV
/// 服务都能用（坚果云 / Nextcloud / 群晖 / 自建）。代价是每次同步要下载整份、
/// 合并后再整份上传；羊毛记录是几十到几百条的量级，完全够用。
class SyncSnapshot {
  const SyncSnapshot({
    required this.deals,
    required this.devices,
    required this.platforms,
    required this.platformsUpdatedAt,
    required this.tombstones,
    this.deviceTombstones = const <String, DateTime>{},
  });

  /// 当前文件格式版本。读到更高版本时仍按已知字段尽量解析，不直接报错。
  static const int schemaVersion = 1;
  static const String appTag = 'appforge-wool';

  final List<WoolDeal> deals;
  final List<Device> devices;
  final List<String> platforms;

  /// 常用平台列表的最后修改时刻。平台是「整份列表」语义，
  /// 用 LWW（新的整份覆盖旧的）而不是并集，删除才能传播出去。
  final DateTime platformsUpdatedAt;

  /// 删除墓碑：记录 id → 删除时刻。让「删除」也能同步。
  final Map<String, DateTime> tombstones;

  /// 设备删除墓碑：设备 id → 删除时刻。
  ///
  /// 设备是按 id 取并集合并的（不像平台那样整份 LWW），没有墓碑的话，
  /// 本机删掉一台设备，下次同步会被云端那份原样并集回来 —— 删了又活。
  /// 设备没有 updatedAt（改名不参与冲突解决），所以规则更简单：
  /// 只要墓碑存在，该设备在合并结果里就不存在。
  final Map<String, DateTime> deviceTombstones;

  static SyncSnapshot empty() => SyncSnapshot(
        deals: const <WoolDeal>[],
        devices: const <Device>[],
        platforms: const <String>[],
        platformsUpdatedAt: DateTime.fromMicrosecondsSinceEpoch(0),
        tombstones: const <String, DateTime>{},
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'app': appTag,
        'schema': schemaVersion,
        'generatedAt': DateTime.now().microsecondsSinceEpoch,
        'platformsUpdatedAt': platformsUpdatedAt.microsecondsSinceEpoch,
        'deals': deals.map((d) => d.toJson()).toList(),
        'devices': devices.map((d) => d.toJson()).toList(),
        'platforms': platforms,
        'tombstones': tombstones.map(
          (id, at) => MapEntry<String, int>(id, at.microsecondsSinceEpoch),
        ),
        'deviceTombstones': deviceTombstones.map(
          (id, at) => MapEntry<String, int>(id, at.microsecondsSinceEpoch),
        ),
      };

  String encode() => jsonEncode(toJson());

  /// 判断一份文本是不是本 App 写的同步文件。
  /// 用户可能把远端路径指到了别的文件，覆盖前必须先确认归属。
  static bool looksLikeOurs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['app'] == appTag;
    } on Object {
      return false;
    }
  }

  /// 解析远端文件。任何结构问题都降级成「空的那部分」，不让一条脏数据
  /// 导致整次同步失败（宁可少同步，也不要覆盖用户数据）。
  factory SyncSnapshot.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return SyncSnapshot.empty();
    final map = Map<String, dynamic>.from(decoded);

    final deals = <WoolDeal>[];
    final rawDeals = map['deals'];
    if (rawDeals is List) {
      for (final item in rawDeals) {
        if (item is Map) {
          final deal = WoolDeal.fromJson(Map<String, dynamic>.from(item));
          if (deal.id.isNotEmpty) deals.add(deal);
        }
      }
    }

    final devices = <Device>[];
    final rawDevices = map['devices'];
    if (rawDevices is List) {
      for (final item in rawDevices) {
        if (item is Map) {
          final device = Device.fromJson(Map<String, dynamic>.from(item));
          if (device.id.isNotEmpty) devices.add(device);
        }
      }
    }

    final platforms = <String>[];
    final rawPlatforms = map['platforms'];
    if (rawPlatforms is List) {
      for (final item in rawPlatforms) {
        if (item is String) {
          final name = item.trim();
          if (name.isNotEmpty && !platforms.contains(name)) platforms.add(name);
        }
      }
    }

    final tombstones = _parseTombstones(map['tombstones']);
    // 老文件没有这个字段 → 空 map，行为与之前完全一致，不影响升级。
    final deviceTombstones = _parseTombstones(map['deviceTombstones']);

    return SyncSnapshot(
      deals: deals,
      devices: devices,
      platforms: platforms,
      platformsUpdatedAt: _parseTime(map['platformsUpdatedAt']),
      tombstones: tombstones,
      deviceTombstones: deviceTombstones,
    );
  }

  static Map<String, DateTime> _parseTombstones(Object? raw) {
    final result = <String, DateTime>{};
    if (raw is! Map) return result;
    raw.forEach((key, value) {
      if (key is String && key.isNotEmpty && value is num) {
        result[key] = DateTime.fromMicrosecondsSinceEpoch(value.toInt());
      }
    });
    return result;
  }

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
}

/// 一次合并里发生了什么，用来在 UI 上给用户一句人话总结。
class SyncMergeStats {
  const SyncMergeStats({
    this.remoteAdded = 0,
    this.localOnly = 0,
    this.conflicts = 0,
    this.deleted = 0,
    this.remoteDeleted = 0,
  });

  /// 远端有、本机没有 → 拉到本机。
  final int remoteAdded;

  /// 本机新增、远端没有 → 本次推上去。
  final int localOnly;

  /// 两边都改过，按 updatedAt 取较新的一方。
  final int conflicts;

  /// 远端删除在本机生效（墓碑比本地副本新）。
  final int deleted;

  /// 本机删除要传到远端（墓碑比远端副本新）。
  ///
  /// 单独记一笔而不是并进 [deleted]：两个方向都可能发生，
  /// 分开统计才能在测试里看清「删除到底是哪边发起的」。
  final int remoteDeleted;

  int get totalDeleted => deleted + remoteDeleted;

  int get totalChanges =>
      remoteAdded + localOnly + conflicts + totalDeleted;
}

class SyncMergeResult {
  const SyncMergeResult({required this.merged, required this.stats});

  final SyncSnapshot merged;
  final SyncMergeStats stats;
}

/// 本机设备（`isDefault`）：合并时它是记录归属的锚点。
///
/// 旧版本里每台手机的本机都叫 `default`，所以它是默认值；新版识别出台手机后
/// 是本机自己的 `dev-xxxxxxxx`。本地列表为空时退回 [Device.fallback]，
/// 保证合并后的快照永远有一台可归属的设备。
Device _anchorDevice(SyncSnapshot local) {
  for (final device in local.devices) {
    if (device.isDefault) return device;
  }
  if (local.devices.isNotEmpty) return local.devices.first;
  return Device.fallback;
}

/// 双向合并：按记录 id 做并集，同一 id 取 `updatedAt` 较新的副本；
/// 墓碑比某一侧副本新时，该副本视为已删除（删除优先，不会被旧数据复活）。
///
/// 纯函数，不碰 IO，方便单测覆盖各种冲突场景。
SyncMergeResult mergeSnapshots({
  required SyncSnapshot local,
  required SyncSnapshot remote,
  Duration tombstoneRetention = const Duration(days: 365),
  DateTime? now,
}) {
  final tombstones = <String, DateTime>{...remote.tombstones};
  local.tombstones.forEach((id, at) {
    final existing = tombstones[id];
    if (existing == null || at.isAfter(existing)) tombstones[id] = at;
  });

  final deviceTombstones = <String, DateTime>{...remote.deviceTombstones};
  local.deviceTombstones.forEach((id, at) {
    final existing = deviceTombstones[id];
    if (existing == null || at.isAfter(existing)) deviceTombstones[id] = at;
  });

  final localById = <String, WoolDeal>{
    for (final deal in local.deals) deal.id: deal,
  };

  // 本机设备是记录归属的锚点：升级前它是老 id `default`，识别出台手机之后
  // 变成 `dev-xxxxxxxx`。远端那个 `default` 只是历史的「本机」，不能当第三
  // 台设备并进来，否则每台手机都会多出一台幽灵设备。
  final anchor = _anchorDevice(local);
  final remapLegacy = anchor.id != Device.defaultId;

  final remoteById = <String, WoolDeal>{
    for (final deal in remote.deals)
      deal.id: remapLegacy &&
              (deal.deviceId.isEmpty || deal.deviceId == Device.defaultId)
          ? deal.copyWith(deviceId: anchor.id)
          : deal,
  };
  final ids = <String>{...localById.keys, ...remoteById.keys};

  final mergedDeals = <WoolDeal>[];
  var remoteAdded = 0;
  var localOnly = 0;
  var conflicts = 0;
  var deleted = 0;
  var remoteDeleted = 0;

  for (final id in ids) {
    final mine = localById[id];
    final theirs = remoteById[id];
    final deadAt = tombstones[id];

    // 墓碑比副本新 → 这条已经被删掉；墓碑更旧则说明删除之后又被编辑过，应保留。
    final mineAlive =
        mine != null && (deadAt == null || mine.updatedAt.isAfter(deadAt));
    final theirsAlive =
        theirs != null && (deadAt == null || theirs.updatedAt.isAfter(deadAt));

    if (mine != null && !mineAlive) deleted++;
    // 本机记了墓碑、远端还留着副本 → 这次上传会把远端那条也删掉。
    if (theirs != null && !theirsAlive) remoteDeleted++;

    if (!mineAlive && !theirsAlive) continue;

    if (mineAlive && theirsAlive) {
      if (!mine.updatedAt.isAtSameMomentAs(theirs.updatedAt)) conflicts++;
      mergedDeals.add(
        theirs.updatedAt.isAfter(mine.updatedAt) ? theirs : mine,
      );
      continue;
    }
    if (mineAlive) {
      mergedDeals.add(mine);
      localOnly++;
      continue;
    }
    mergedDeals.add(theirs!);
    remoteAdded++;
  }

  // 排序稳定：按活动日期 → 开始时间 → 创建时间，便于肉眼 diff 与测试断言。
  mergedDeals.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byStart = (a.startTime?.inMinutes ?? 24 * 60)
        .compareTo(b.startTime?.inMinutes ?? 24 * 60);
    if (byStart != 0) return byStart;
    return a.createdAt.compareTo(b.createdAt);
  });

  // 设备：按 id 并集，本机顺序优先；同 id 名字冲突时保留本机（用户可能刚改过名）。
  // 但有墓碑的设备必须排除，否则「本机删掉 → 云端那份又并集回来」。
  final devices = <Device>[];
  final seenDevices = <String>{};
  for (final device in local.devices) {
    if (deviceTombstones.containsKey(device.id)) continue;
    // 本机已经换成真身份，本地残留的旧 `default` 行当作历史丢弃。
    if (remapLegacy && device.id == Device.defaultId) continue;
    if (seenDevices.add(device.id)) devices.add(device);
  }
  final remoteDevices = <String, Device>{
    for (final device in remote.devices) device.id: device,
  };
  for (final device in remote.devices) {
    if (deviceTombstones.containsKey(device.id)) continue;
    if (remapLegacy && device.id == Device.defaultId) continue;
    if (!seenDevices.add(device.id)) continue;
    devices.add(device);
  }
  // 同一台手机重装后，本机名字是自动起的机型名，而远端那份可能是用户以前
  // 改过的名字 —— 自动命名的别把用户改过的名字顶掉。
  for (var i = 0; i < devices.length; i++) {
    final local = devices[i];
    final copy = remoteDevices[local.id];
    if (copy != null && local.autoNamed && !copy.autoNamed && copy.name.isNotEmpty) {
      devices[i] = local.copyWith(name: copy.name, autoNamed: false);
    }
  }

  // 保证锚点设备一定在列表里，否则所有记录都会失去归属。
  if (!devices.any((d) => d.id == anchor.id)) {
    devices.insert(0, anchor);
    deviceTombstones.remove(anchor.id);
  }
  // 「本机」只有一台：远端带来的 isDefault 只是它自己的本机标记，
  // 不应该在本机生效（否则会出现两台「本机」）。
  for (var i = 0; i < devices.length; i++) {
    if (devices[i].isDefault != (devices[i].id == anchor.id)) {
      devices[i] = devices[i].copyWith(isDefault: devices[i].id == anchor.id);
    }
  }

  // 平台：整份 LWW，删除才能传播；本机时间戳更新则以本机为准。
  final useRemotePlatforms =
      remote.platformsUpdatedAt.isAfter(local.platformsUpdatedAt);
  final platforms = <String>[];
  for (final name in useRemotePlatforms ? remote.platforms : local.platforms) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty && !platforms.contains(trimmed)) {
      platforms.add(trimmed);
    }
  }
  final platformsUpdatedAt =
      useRemotePlatforms ? remote.platformsUpdatedAt : local.platformsUpdatedAt;

  // 墓碑只保留一段时间，避免文件无限膨胀；离线超过保留期的设备回来时
  // 可能把旧删除复活，这是有意的折衷（正常使用远小于这个窗口）。
  final cutoff = (now ?? DateTime.now()).subtract(tombstoneRetention);
  tombstones.removeWhere((_, at) => at.isBefore(cutoff));
  deviceTombstones.removeWhere((_, at) => at.isBefore(cutoff));
  // 本机设备是「记录归属」的最后兜底，任何情况下都不允许被墓碑删掉。
  deviceTombstones.remove(anchor.id);

  return SyncMergeResult(
    merged: SyncSnapshot(
      deals: mergedDeals,
      devices: devices,
      platforms: platforms,
      platformsUpdatedAt: platformsUpdatedAt,
      tombstones: tombstones,
      deviceTombstones: deviceTombstones,
    ),
    stats: SyncMergeStats(
      remoteAdded: remoteAdded,
      localOnly: localOnly,
      conflicts: conflicts,
      deleted: deleted,
      remoteDeleted: remoteDeleted,
    ),
  );
}
