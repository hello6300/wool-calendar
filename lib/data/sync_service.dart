import 'dart:convert';

import 'sync_snapshot.dart';
import 'webdav_transport.dart';

/// 一次同步的结果：合并后的快照 + 变化统计 + 远端原本是否为空。
class SyncOutcome {
  const SyncOutcome({
    required this.snapshot,
    required this.stats,
    required this.remoteWasEmpty,
  });

  final SyncSnapshot snapshot;
  final SyncMergeStats stats;

  /// true = 远端还没有同步文件（首次同步），此时合并不涉及冲突。
  final bool remoteWasEmpty;
}

/// 云端一条可恢复的备份。
///
/// 两种来源，靠 [at] 区分：
/// - **每日备份** `wool-sync-2026-11-16.json`（同步前自动留的）
/// - **恢复前快照** `wool-sync-2026-11-16-1432.json`（每次恢复前自动留的）
class RemoteBackup {
  const RemoteBackup({
    required this.path,
    required this.name,
    required this.day,
    this.at,
  });

  /// 相对 baseUrl 的完整路径，GET 用这个。
  final String path;

  /// 只有文件名，界面标题用。
  final String name;

  /// 文件名里的年月日。
  final DateTime day;

  /// 恢复前快照的时分；每日备份为 null。
  final DateTime? at;

  bool get isSafetyCopy => at != null;
}

/// 一次恢复的结果：被恢复成什么样、恢复前把云端存到了哪个文件。
class RestoreOutcome {
  const RestoreOutcome({required this.snapshot, this.safetyPath});

  /// 从备份文件里读出来的快照，已原样写回本机与云端。
  final SyncSnapshot snapshot;

  /// 恢复前那份云端数据的落点；云端本来就没有文件时为 null。
  final String? safetyPath;
}

/// 「云端那份文件里到底有什么」的只读盘点。
///
/// 存在的意义：同步成功与否，用户只能看到一个计数，很容易怀疑
/// 「到底传上去了没」。这里直接把远端文件的条数、大小、生成时间摊开，
/// 不写任何数据，纯读。
class RemoteInspection {
  const RemoteInspection({
    required this.exists,
    required this.bytes,
    required this.recognized,
    this.deals = 0,
    this.devices = 0,
    this.platforms = 0,
    this.generatedAt,
    this.sampleTitles = const <String>[],
  });

  /// 远端还没有这个文件（首次同步前）。
  const RemoteInspection.missing()
      : exists = false,
        bytes = 0,
        recognized = false,
        deals = 0,
        devices = 0,
        platforms = 0,
        generatedAt = null,
        sampleTitles = const <String>[];

  final bool exists;

  /// 文件字节数（按 UTF-8 计），用来对比「有没有内容」。
  final int bytes;

  /// 文件带 `app: appforge-wool` 标记。false = 这是别人的文件。
  final bool recognized;

  final int deals;
  final int devices;
  final int platforms;

  /// 文件里记录的生成时刻；缺字段时为空。
  final DateTime? generatedAt;

  /// 前几条记录的标题，用来肉眼确认「是不是我的羊毛」。
  final List<String> sampleTitles;
}

/// 一次完整同步：建目录 → 下载远端 → 合并 → 上传合并结果。
///
/// 顺序很重要：先上传「合并结果」而不是「本地数据」，否则会把另一台设备
/// 的记录覆盖掉。合并是纯函数（[mergeSnapshots]），本类只负责 IO 时序。
class WoolSyncService {
  const WoolSyncService({
    required this.transport,
    this.tombstoneRetention = const Duration(days: 365),
  });

  final SyncTransport transport;
  final Duration tombstoneRetention;

  Future<SyncOutcome> run({
    required String remotePath,
    required SyncSnapshot local,
  }) async {
    await transport.ensureDirectory(remotePath);

    final raw = await transport.download(remotePath);
    final remoteWasEmpty = raw == null || raw.trim().isEmpty;

    final remote =
        remoteWasEmpty ? SyncSnapshot.empty() : SyncSnapshot.decode(raw);

    // 远端文件不是本 App 的格式（用户指错了路径 / 指向了别的文件）时中止：
    // 宁可这次同步失败，也不能用我们的数据覆盖掉别人的文件。
    if (!remoteWasEmpty && !SyncSnapshot.looksLikeOurs(raw)) {
      throw const SyncException(SyncFailure.unrecognized);
    }

    final merged = mergeSnapshots(
      local: local,
      remote: remote,
      tombstoneRetention: tombstoneRetention,
    );

    await transport.upload(remotePath, merged.merged.encode());

    return SyncOutcome(
      snapshot: merged.merged,
      stats: merged.stats,
      remoteWasEmpty: remoteWasEmpty,
    );
  }

  // ---------------------------------------------------------------------------
  // 每日备份
  // ---------------------------------------------------------------------------

  /// 备份文件的相对路径：**与原文件同目录**，名字后面挂日期。
  ///
  /// `yangmao/wool-sync.json` + 2026-11-16 → `yangmao/wool-sync-2026-11-16.json`
  ///
  /// 为什么不放进 `backup/` 子目录：飞牛 fnOS 之类不允许客户端 MKCOL 建目录，
  /// 一旦要建子目录，备份就会天天失败、连带把同步卡死。同目录不建目录，
  /// 任何 WebDAV 服务都能落地。
  static String dailyBackupPath(String remotePath, DateTime day) {
    final clean = remotePath.trim().replaceAll(RegExp(r'/+$'), '');
    final slash = clean.lastIndexOf('/');
    final dir = slash < 0 ? '' : clean.substring(0, slash + 1);
    final name = slash < 0 ? clean : clean.substring(slash + 1);

    final dot = name.lastIndexOf('.');
    final base = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    return '$dir$base-${backupStamp(day)}$ext';
  }

  /// `2026-11-16` 这种可按文件名排序的日期戳（本地时区）。
  static String backupStamp(DateTime day) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${day.year}-${two(day.month)}-${two(day.day)}';
  }

  /// 今天还没备份过 → 该备份了。按**本地日历日**比较，不是按 24 小时。
  static bool needsDailyBackup(DateTime? lastBackupAt, DateTime now) {
    if (lastBackupAt == null) return true;
    return lastBackupAt.year != now.year ||
        lastBackupAt.month != now.month ||
        lastBackupAt.day != now.day;
  }

  /// 把云端**当前这份**复制成当天的备份文件。
  ///
  /// 备份的是远端而不是本机：同步会用合并结果覆盖远端，本机数据本来就在本地，
  /// 真出事时缺的是「被覆盖之前的云端版本」。
  ///
  /// 返回备份文件的路径；远端还没有文件（首次同步）时返回 null —— 没什么可备份，
  /// 调用方照常记下「今天处理过」，免得每次同步都白跑一趟 GET。
  Future<String?> backupRemote({
    required String remotePath,
    required DateTime day,
  }) async {
    final raw = await transport.download(remotePath);
    if (raw == null || raw.trim().isEmpty) return null;

    final path = dailyBackupPath(remotePath, day);
    // 用 GET + PUT 而不是 WebDAV 的 COPY：COPY 是可选动词，飞牛之类的实现并不全，
    // 而 GET/PUT 是所有服务都有的。
    await transport.upload(path, raw);
    return path;
  }

  // ---------------------------------------------------------------------------
  // 备份恢复
  // ---------------------------------------------------------------------------

  /// 恢复**之前**把云端现状另存一份，名字带时分，避免和当天每日备份撞名。
  ///
  /// `yangmao/wool-sync.json` + 2026-11-16 14:32 → `yangmao/wool-sync-2026-11-16-1432.json`
  ///
  /// 为什么恢复也要留备份：恢复是**覆盖性**操作，本机和云端都会被换成旧内容。
  /// 万一选错了日期，这份快照就是唯一的退路。
  static String safetyBackupPath(String remotePath, DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    final clean = remotePath.trim().replaceAll(RegExp(r'/+$'), '');
    final slash = clean.lastIndexOf('/');
    final dir = slash < 0 ? '' : clean.substring(0, slash + 1);
    final name = slash < 0 ? clean : clean.substring(slash + 1);

    final dot = name.lastIndexOf('.');
    final base = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    final stamp = '${backupStamp(at)}-${two(at.hour)}${two(at.minute)}';
    return '$dir$base-$stamp$ext';
  }

  /// 把一个远端文件名解析成备份；不是备份（主文件本身、别的文件）就返回 null。
  ///
  /// 只认「主文件名 + `-日期` (+ `-时分`) + 主扩展名」这种形态，
  /// 所以 `wool-sync.json` 自己不会被当备份，`wool-sync-notes.json` 也不会。
  static RemoteBackup? parseBackupName(String remotePath, String name) {
    final clean = remotePath.trim().replaceAll(RegExp(r'/+$'), '');
    final slash = clean.lastIndexOf('/');
    final dir = slash < 0 ? '' : clean.substring(0, slash + 1);
    final mainName = slash < 0 ? clean : clean.substring(slash + 1);
    if (name == mainName) return null;

    final dot = mainName.lastIndexOf('.');
    final base = dot <= 0 ? mainName : mainName.substring(0, dot);
    final ext = dot <= 0 ? '' : mainName.substring(dot);
    if (base.isEmpty || !name.startsWith('$base-')) return null;

    final pattern = RegExp(
      '^${RegExp.escape(base)}-'
      r'(\d{4})-(\d{2})-(\d{2})'
      r'(?:-(\d{2})(\d{2}))?'
      '${RegExp.escape(ext)}\$',
    );
    final match = pattern.firstMatch(name);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final date = DateTime(year, month, day);
    // DateTime 会把 2 月 31 日进位成 3 月 3 日，进过位就是非法日期。
    if (date.month != month || date.day != day) return null;

    DateTime? at;
    if (match.group(4) != null) {
      final hour = int.parse(match.group(4)!);
      final minute = int.parse(match.group(5)!);
      if (hour > 23 || minute > 59) return null;
      at = DateTime(year, month, day, hour, minute);
    }

    return RemoteBackup(
      path: dir.isEmpty ? name : '$dir$name',
      name: name,
      day: date,
      at: at,
    );
  }

  /// 列出主文件同目录下所有备份，新的在前。
  ///
  /// 只 PROPFIND 一次目录，不逐个下载 —— 备份攒一年也就几百个文件，
  /// 但每个都 GET 一遍就太慢了，条数等用户真选中再读。
  Future<List<RemoteBackup>> listBackups({required String remotePath}) async {
    final clean = remotePath.trim().replaceAll(RegExp(r'/+$'), '');
    final slash = clean.lastIndexOf('/');
    final dir = slash < 0 ? '' : clean.substring(0, slash);

    final entries = await transport.list(dir);
    final backups = <RemoteBackup>[];
    for (final entry in entries) {
      if (entry.isCollection) continue;
      final parsed = parseBackupName(remotePath, entry.name);
      if (parsed != null) backups.add(parsed);
    }
    // 文件名里的日期是补零的，直接按名字倒序就是「新 → 旧」；
    // 同一天里 `-1432.json` 会排在 `-2026-11-16.json` 前面，正好是操作记录顺序。
    backups.sort((a, b) => b.name.compareTo(a.name));
    return backups;
  }

  /// 把某个备份文件读成快照；内容不是本 App 的格式就中止，绝不拿去覆盖本机。
  Future<SyncSnapshot> readSnapshot({required String path}) async {
    final raw = await transport.download(path);
    if (raw == null || raw.trim().isEmpty) {
      throw SyncException(
        SyncFailure.notFound,
        detail: 'GET $path → 文件里没有内容',
      );
    }
    if (!SyncSnapshot.looksLikeOurs(raw)) {
      throw const SyncException(SyncFailure.unrecognized);
    }
    return SyncSnapshot.decode(raw);
  }

  /// 用某个备份覆盖云端与本机。
  ///
  /// 顺序：读备份 → 存一份恢复前快照 → 覆盖主文件。
  /// 放到最后才写主文件，前面任何一步失败，云端和本机都还是原样。
  Future<RestoreOutcome> restore({
    required String remotePath,
    required String backupPath,
    required DateTime at,
  }) async {
    final snapshot = await readSnapshot(path: backupPath);

    final current = await transport.download(remotePath);
    String? safetyPath;
    if (current != null && current.trim().isNotEmpty) {
      safetyPath = safetyBackupPath(remotePath, at);
      await transport.upload(safetyPath, current);
    }

    await transport.upload(remotePath, snapshot.encode());
    return RestoreOutcome(snapshot: snapshot, safetyPath: safetyPath);
  }

  /// 只读盘点远端文件，不做任何写入；也不建目录（诊断不该有副作用）。
  Future<RemoteInspection> inspect({required String remotePath}) async {
    final raw = await transport.download(remotePath);
    if (raw == null || raw.trim().isEmpty) {
      return const RemoteInspection.missing();
    }

    final bytes = utf8.encode(raw).length;
    if (!SyncSnapshot.looksLikeOurs(raw)) {
      return RemoteInspection(
        exists: true,
        bytes: bytes,
        recognized: false,
      );
    }

    final snapshot = SyncSnapshot.decode(raw);
    final titles = <String>[
      for (final deal in snapshot.deals)
        if (deal.title.trim().isNotEmpty) deal.title.trim(),
    ];

    return RemoteInspection(
      exists: true,
      bytes: bytes,
      recognized: true,
      deals: snapshot.deals.length,
      devices: snapshot.devices.length,
      platforms: snapshot.platforms.length,
      generatedAt: _readGeneratedAt(raw),
      sampleTitles: titles,
    );
  }

  static DateTime? _readGeneratedAt(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded['generatedAt'];
      if (value is! num) return null;
      return DateTime.fromMicrosecondsSinceEpoch(value.toInt());
    } on Object {
      return null;
    }
  }
}
