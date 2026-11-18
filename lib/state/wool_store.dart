import 'package:flutter/foundation.dart';

import '../data/deal_reminder.dart';
import '../data/device_calendar_source.dart';
import '../data/device_identity.dart';
import '../data/sync_snapshot.dart';
import '../data/wool_repository.dart';
import '../models/device.dart';
import '../models/wool_deal.dart';
import '../utils/calendar_grid.dart';

/// 羊毛记录的单一数据源（Provider / ChangeNotifier）。
///
/// [reminder] / [calendarSource] 都是可注入的边界：真实 App 传原生实现，
/// 单元测试传 Fake，避免测试依赖通知插件或系统日历。
/// 设备注册表同样只走 [WoolRepository]，不引入额外依赖。
class WoolStore extends ChangeNotifier {
  // SharedPreferences 实例已在 main() 里 await 过，因此加载是同步的，
  // 首帧就能拿到数据，不需要 loading 分支。
  WoolStore(
    this._repository, {
    DealReminder? reminder,
    DeviceCalendarSource? calendarSource,
    List<String> defaultPlatforms = const <String>[],
    DeviceIdentity? identity,
  })  : _reminder = reminder,
        _calendarSource = calendarSource,
        _devices = _repository.loadDevices(),
        _deals = _repository.load(),
        // null = 从未配置过 → 用默认常用平台初始化；
        // [] = 用户主动删光了，必须保持为空，不能再塞回默认值。
        _platforms =
            _repository.loadPlatforms() ?? List<String>.of(defaultPlatforms),
        _platformsUpdatedAt = _repository.loadPlatformsUpdatedAt() ??
            DateTime.fromMicrosecondsSinceEpoch(0),
        _tombstones = _repository.loadTombstones(),
        _deviceTombstones = _repository.loadDeviceTombstones() {
    // 认本机：内存里立刻生效，首帧就能显示正确的设备名；
    // 落盘走 persistIdentity()，由 main() 在 runApp 前 await 一次。
    _adoptThisDevice(identity);
  }

  final WoolRepository _repository;
  final DealReminder? _reminder;
  final DeviceCalendarSource? _calendarSource;

  List<WoolDeal> _deals;
  List<Device> _devices;
  List<String> _platforms;
  DateTime _platformsUpdatedAt;
  Map<String, DateTime> _tombstones;
  Map<String, DateTime> _deviceTombstones;

  /// 本机设备的 id：识别成功时是原生派生的 `dev-xxxxxxxx`，
  /// 拿不到身份时才退回 [Device.defaultId]（旧行为）。
  late String _thisDeviceId;

  /// 本机机型名（Redmi K30 Pro）。识别失败为空串。
  String _thisDeviceLabel = '';

  /// 识别结果还没落盘。构造时只改内存，由 [persistIdentity] 统一写。
  bool _identityDirty = false;

  /// 空字符串表示「全部设备」；否则只展示该设备的记录。
  String _activeDeviceId = '';

  DateTime _month = monthStart(DateTime.now());
  DateTime _selectedDay = dayOnly(DateTime.now());

  List<WoolDeal> get deals => List<WoolDeal>.unmodifiable(_deals);
  List<Device> get devices => List<Device>.unmodifiable(_devices);

  /// 用户自定义的常用平台（编辑器里的快捷 chip）。
  List<String> get platforms => List<String>.unmodifiable(_platforms);

  DateTime get month => _month;
  DateTime get selectedDay => _selectedDay;

  bool get isAllDevices => _activeDeviceId.isEmpty;
  String get activeDeviceId => _activeDeviceId;

  /// 本机设备的 id（识别失败时是 `default`）。
  String get thisDeviceId => _thisDeviceId;

  /// 兼容旧调用点：以前「默认设备」就是本机。
  String get defaultDeviceId => _thisDeviceId;

  /// 原生识别到的机型名，没识别出来是空串。
  String get thisDeviceLabel => _thisDeviceLabel;

  /// 是否真的认出了这台手机（而不是退回共用的 `default`）。
  bool get hasDeviceIdentity => _thisDeviceId != Device.defaultId;

  /// 新增记录 / 导入活动默认归属：当前筛选了某台设备就归它，否则归本机。
  String get deviceForNew =>
      _activeDeviceId.isEmpty ? _thisDeviceId : _activeDeviceId;

  /// 找不到设备（例如脏数据）时退回默认设备，不让 UI 出现空白标签。
  String deviceName(String id, String defaultLabel) {
    for (final d in _devices) {
      if (d.id == id) return d.displayName(defaultLabel);
    }
    return defaultLabel;
  }

  /// 新增 / 重命名时做同名校验；[exceptId] 用于重命名时排除自己。
  bool deviceNameExists(
    String name, {
    required String defaultLabel,
    String? exceptId,
  }) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return _devices.any(
      (d) =>
          d.id != exceptId &&
          d.displayName(defaultLabel).toLowerCase() == normalized,
    );
  }

  int dealCountOf(String deviceId) =>
      _deals.where((d) => d.deviceId == deviceId).length;

  // ---------------------------------------------------------------------------
  // 识别本机
  // ---------------------------------------------------------------------------

  Device? _findDevice(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  /// 认本机：把识别出的设备设成唯一的「本机」，并把旧数据接到它名下。
  ///
  /// 三种情况：
  /// 1. 列表里已经有这个 id —— 同一台手机再次启动（或云端已经带回自己的行），
  ///    只修正「本机」标记，机型名仅在自动命名时刷新。
  /// 2. 有 `default` 设备 —— 升级后第一次识别，把 `default` 就地改名为真实
  ///    身份，记录跟着换 id，归属不断层。
  /// 3. 什么都没有 —— 新建一台。
  void _adoptThisDevice(DeviceIdentity? identity) {
    final cached = _repository.loadThisDevice();
    final targetId = identity?.id ?? cached?.id;
    _thisDeviceLabel = (identity?.label ?? cached?.label ?? '').trim();

    if (targetId == null || targetId.isEmpty) {
      // 认不出来就保持旧行为：所有手机共用 `default`，至少不会把数据搞丢。
      _thisDeviceId = Device.defaultId;
      return;
    }
    _thisDeviceId = targetId;
    if (cached?.id != targetId) _identityDirty = true;

    final existing = _findDevice(targetId);
    if (existing != null) {
      // 「这个名字是我们自动起的吗」不能只信 autoNamed 标记：早期版本重命名
      // 时漏了清这个标记，用户起的名字一直挂着「自动命名」，下次启动又被
      // Build.MODEL 盖回去。自动名只可能是机型字符串本身（当前的或上次记下
      // 的），两者都不像 → 认定是用户写的，就地停掉自动命名，别再动它。
      final cachedLabel = (cached?.label ?? '').trim();
      final looksAutomatic = existing.autoNamed &&
          (existing.name.isEmpty ||
              existing.name == _thisDeviceLabel ||
              existing.name == cachedLabel);
      final userNamed = existing.autoNamed && !looksAutomatic;
      final rename = looksAutomatic &&
          _thisDeviceLabel.isNotEmpty &&
          existing.name != _thisDeviceLabel;
      if (rename || userNamed || !existing.isDefault) {
        _devices = <Device>[
          for (final device in _devices)
            if (device.id == targetId)
              device.copyWith(
                name: rename ? _thisDeviceLabel : null,
                isDefault: true,
                autoNamed: userNamed ? false : null,
              )
            else
              device.copyWith(isDefault: false),
        ];
        _identityDirty = true;
      }
      // 云端可能还带着老版本写的 `default` 记录，顺手接回家。
      _remapLegacyDeals();
      return;
    }

    final legacy = _findDevice(Device.defaultId);
    if (legacy == null) {
      _devices = <Device>[
        Device(
          id: targetId,
          name: _thisDeviceLabel,
          isDefault: true,
          autoNamed: _thisDeviceLabel.isNotEmpty,
        ),
        for (final device in _devices) device.copyWith(isDefault: false),
      ];
    } else {
      // 用户给 default 起过名字（比如「k30pro」）就保留，那是他自己的叫法。
      final oldName = legacy.name.trim();
      _devices = <Device>[
        for (final device in _devices)
          if (device.id == Device.defaultId)
            Device(
              id: targetId,
              name: oldName.isNotEmpty ? oldName : _thisDeviceLabel,
              isDefault: true,
              // 只有名字是机型名才允许以后被机型更新顶掉。
              autoNamed: oldName.isEmpty && _thisDeviceLabel.isNotEmpty,
            )
          else
            device.copyWith(isDefault: false),
      ];
      // 旧 id 退场：留墓碑，否则同步时云端那台 `default` 又会被并集回来，
      // 列表里出现两台「本机」。
      _deviceTombstones = <String, DateTime>{
        ..._deviceTombstones,
        Device.defaultId: DateTime.now(),
      };
    }

    _deviceTombstones = Map<String, DateTime>.of(_deviceTombstones)
      ..remove(targetId);
    if (_activeDeviceId == Device.defaultId) _activeDeviceId = targetId;

    _remapLegacyDeals();
    _identityDirty = true;
  }

  /// 把还挂在旧 id（`default` / 空）上的记录接到本机名下。
  ///
  /// **不动 updatedAt**：这只是归属搬家，不是用户改内容；刷新时间戳会让这台
  /// 手机在 LWW 里压过另一台设备上更新的真实编辑。
  void _remapLegacyDeals() {
    if (_thisDeviceId == Device.defaultId) return;
    final stale = _deals.any(
      (d) => d.deviceId.isEmpty || d.deviceId == Device.defaultId,
    );
    if (!stale) return;
    _deals = <WoolDeal>[
      for (final deal in _deals)
        (deal.deviceId.isEmpty || deal.deviceId == Device.defaultId)
            ? deal.copyWith(deviceId: _thisDeviceId)
            : deal,
    ];
    _identityDirty = true;
  }

  /// 把识别结果落盘。main() 在 runApp 前 await 一次；没变化时几乎零成本。
  Future<void> persistIdentity() async {
    if (!_identityDirty) return;
    _identityDirty = false;
    await _repository.saveThisDevice(_thisDeviceId, _thisDeviceLabel);
    await _repository.saveDevices(_devices);
    await _repository.save(_deals);
    await _repository.saveDeviceTombstones(_deviceTombstones);
  }

  DeviceCalendarSource? get calendarSource => _calendarSource;
  bool get canImportFromDevice => _calendarSource != null;

  String newId() => 'w${DateTime.now().microsecondsSinceEpoch}';
  String newDeviceId() => 'd${DateTime.now().microsecondsSinceEpoch}';

  // ---------------------------------------------------------------------------
  // 自定义常用平台：只影响编辑器里的快捷 chip，**不碰任何历史记录**的 platform
  // 字段。重命名「京东」为「京东商城」不会把旧记录的京东改成京东商城——那是
  // 用户已经写下的内容，批量改写风险更高。
  // ---------------------------------------------------------------------------

  bool platformExists(String rawName, {String? exceptName}) {
    final name = rawName.trim().toLowerCase();
    final except = exceptName?.trim().toLowerCase();
    if (name.isEmpty) return false;
    return _platforms.any((p) {
      final value = p.toLowerCase();
      return value == name && value != except;
    });
  }

  Future<bool> addPlatform(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty || platformExists(name)) return false;
    _platforms = <String>[..._platforms, name];
    await _savePlatforms();
    return true;
  }

  Future<bool> renamePlatform(String rawOldName, String rawNewName) async {
    final oldName = rawOldName.trim();
    final newName = rawNewName.trim();
    if (newName.isEmpty || platformExists(newName, exceptName: oldName)) {
      return false;
    }
    final index = _platforms.indexOf(oldName);
    if (index < 0) return false;

    final next = List<String>.of(_platforms);
    next[index] = newName;
    _platforms = next;
    await _savePlatforms();
    return true;
  }

  Future<bool> removePlatform(String rawName) async {
    final name = rawName.trim();
    final next = _platforms.where((p) => p != name).toList();
    if (next.length == _platforms.length) return false;
    _platforms = next;
    await _savePlatforms();
    return true;
  }

  Future<void> _savePlatforms() async {
    _platformsUpdatedAt = DateTime.now();
    await _repository.savePlatforms(_platforms);
    await _repository.savePlatformsUpdatedAt(_platformsUpdatedAt);
    notifyListeners();
  }

  /// 已经从系统日历导入过的事件 ID，导入页据此把重复项置灰。
  /// 用**全部**记录判重，避免切换设备筛选后同一个事件被重复导入。
  Set<String> get importedSourceIds => _deals
      .where((d) => d.sourceId != null && d.sourceId!.isNotEmpty)
      .map((d) => d.sourceId!)
      .toSet();

  /// 当前设备筛选下可见的记录。空字符串 = 全部设备。
  List<WoolDeal> get visibleDeals => _activeDeviceId.isEmpty
      ? List<WoolDeal>.unmodifiable(_deals)
      : _deals.where((d) => d.deviceId == _activeDeviceId).toList();

  /// 从磁盘重读（外部改动或测试验证持久化时用）。
  void reload() {
    _deals = _repository.load();
    _devices = _repository.loadDevices();
    final platforms = _repository.loadPlatforms();
    if (platforms != null) _platforms = platforms;
    _platformsUpdatedAt =
        _repository.loadPlatformsUpdatedAt() ?? _platformsUpdatedAt;
    _tombstones = _repository.loadTombstones();
    notifyListeners();
  }

  /// 切换设备筛选；切回「全部设备」传空字符串。
  void selectDevice(String id) {
    if (id == _activeDeviceId) return;
    _activeDeviceId = id;
    notifyListeners();
  }

  /// 新增一台设备。名称为空或重复时返回 null，由 UI 给出提示。
  Future<Device?> addDevice(
    String rawName, {
    required String defaultLabel,
  }) async {
    final name = rawName.trim();
    if (name.isEmpty || deviceNameExists(name, defaultLabel: defaultLabel)) {
      return null;
    }
    final device = Device(id: newDeviceId(), name: name);
    _devices = <Device>[..._devices, device];
    await _repository.saveDevices(_devices);
    notifyListeners();
    return device;
  }

  Future<bool> renameDevice(
    String id,
    String rawName, {
    required String defaultLabel,
  }) async {
    final name = rawName.trim();
    if (name.isEmpty ||
        deviceNameExists(name, defaultLabel: defaultLabel, exceptId: id)) {
      return false;
    }
    final found = _devices.any((d) => d.id == id);
    if (!found) return false;
    _devices = <Device>[
      for (final d in _devices)
        // 一定要同时把 autoNamed 置 false：这名字从此是用户起的。
        // 只改 name 的话，下次冷启动「认本机」会认为它还是机型自动名，
        // 又拿 Build.MODEL 盖回去 —— 表现就是「我改的名字过一会儿/同步后就没了」。
        // 同步也依赖这个标记：只有 autoNamed=false 才算「用户命名」，
        // 才允许在合并时传到另一台设备。
        if (d.id == id) d.copyWith(name: name, autoNamed: false) else d,
    ];
    await _repository.saveDevices(_devices);
    notifyListeners();
    return true;
  }

  /// 删除设备：该设备下的记录**不删除**，统一迁回本机设备。
  /// 本机设备不可删，保证任何时刻至少有一台设备。返回迁移的记录条数。
  Future<int> removeDevice(String id) async {
    if (id == _thisDeviceId || _devices.length <= 1) return -1;
    if (!_devices.any((d) => d.id == id)) return -1;

    var moved = 0;
    _deals = _deals.map((d) {
      if (d.deviceId != id) return d;
      moved++;
      // 设备归属变了也算一次修改，否则同步时会被另一台设备的旧归属覆盖。
      return d.copyWith(
        deviceId: _thisDeviceId,
        updatedAt: DateTime.now(),
      );
    }).toList();
    _devices = _devices.where((d) => d.id != id).toList();
    if (_activeDeviceId == id) _activeDeviceId = '';
    // 设备是按 id 并集同步的，只删本地列表的话，下一次同步云端那份会原样
    // 并集回来（删了又活）。必须留一块墓碑，让合并阶段知道「这台是删掉的」。
    _deviceTombstones = <String, DateTime>{
      ..._deviceTombstones,
      id: DateTime.now(),
    };

    await _repository.saveDevices(_devices);
    await _repository.saveDeviceTombstones(_deviceTombstones);
    await _repository.save(_deals);
    notifyListeners();
    return moved;
  }

  /// App 冷启动时重排所有未来提醒：系统重启 / 应用更新会清掉闹钟。
  /// 用全量记录，不受设备筛选影响。
  Future<void> syncReminders() async {
    final r = _reminder;
    if (r == null) return;
    for (final deal in _deals) {
      await r.sync(deal);
    }
  }

  /// 用户第一次开启「到点提醒」时申请 Android 通知权限。
  Future<void> enableReminders() async => _reminder?.ensurePermissions();

  /// 批量导入系统日历活动：去重 → 一次落盘 → 逐条排提醒。
  /// [deviceId] 指定这批活动归到哪台设备，缺省用当前筛选 / 默认设备。
  /// 返回实际导入条数，UI 据此提示「导入 N 条 / 全部已导入」。
  Future<int> importEvents(
    List<CalendarEventEntry> events, {
    required CalendarImportLabels labels,
    String? deviceId,
  }) async {
    final existing = importedSourceIds;
    final target = deviceId ?? deviceForNew;
    final now = DateTime.now();
    final fresh = <WoolDeal>[];
    var index = 0;
    for (final event in events) {
      // 同一次读取里出现重复实例时也要去重，不只是和磁盘上的记录比。
      if (event.sourceId.isEmpty || !existing.add(event.sourceId)) continue;
      fresh.add(
        calendarEventToDeal(
          event,
          id: '${newId()}_$index',
          createdAt: now,
          labels: labels,
        ).copyWith(deviceId: target),
      );
      index++;
    }
    if (fresh.isEmpty) return 0;

    _deals = <WoolDeal>[..._deals, ...fresh];
    await _persist();
    for (final deal in fresh) {
      await _reminder?.sync(deal);
    }
    return fresh.length;
  }

  /// 按 yyyy-MM-dd 分组，日历画圆点、当日列表都从这里取。
  /// 只统计当前设备筛选下的记录；同一天里按活动开始时间排序，没填时间的排最后。
  Map<String, List<WoolDeal>> get dealsByDay {
    final map = <String, List<WoolDeal>>{};
    for (final deal in visibleDeals) {
      map.putIfAbsent(dateKey(deal.date), () => <WoolDeal>[]).add(deal);
    }
    for (final list in map.values) {
      list.sort((a, b) {
        final ta = a.startTime?.inMinutes ?? 24 * 60;
        final tb = b.startTime?.inMinutes ?? 24 * 60;
        final byTime = ta.compareTo(tb);
        return byTime != 0 ? byTime : a.createdAt.compareTo(b.createdAt);
      });
    }
    return map;
  }

  List<WoolDeal> dealsOn(DateTime day) =>
      dealsByDay[dateKey(day)] ?? <WoolDeal>[];

  double dayReward(DateTime day) => dealsOn(day).fold<double>(
        0,
        (sum, d) => sum + (d.amount ?? 0),
      );

  void showMonth(DateTime month) {
    _month = monthStart(month);
    notifyListeners();
  }

  void shiftMonth(int delta) => showMonth(addMonths(_month, delta));

  void selectDay(DateTime day) {
    final d = dayOnly(day);
    _selectedDay = d;
    // 点到网格里的补位日期时自动跟着切月，不用再手动翻页。
    if (d.year != _month.year || d.month != _month.month) {
      _month = monthStart(d);
    }
    notifyListeners();
  }

  void goToday() {
    final now = dayOnly(DateTime.now());
    _selectedDay = now;
    _month = monthStart(now);
    notifyListeners();
  }

  Future<void> add(WoolDeal deal) async {
    final fresh = deal.touch();
    _deals = <WoolDeal>[..._deals, fresh];
    // 同 id 曾被删除过（极少见）：撤掉墓碑，否则下次同步会把它再删掉。
    if (_tombstones.remove(fresh.id) != null) {
      await _repository.saveTombstones(_tombstones);
    }
    await _persist();
    await _reminder?.sync(fresh);
  }

  Future<void> update(WoolDeal deal) async {
    final fresh = deal.touch();
    _deals = <WoolDeal>[
      for (final d in _deals)
        if (d.id == fresh.id) fresh else d,
    ];
    await _persist();
    await _reminder?.sync(fresh);
  }

  Future<void> remove(String id) async {
    _deals = _deals.where((d) => d.id != id).toList();
    // 记墓碑：否则另一台设备的旧副本会在同步时把这条「复活」。
    _tombstones = <String, DateTime>{..._tombstones, id: DateTime.now()};
    await _repository.saveTombstones(_tombstones);
    await _persist();
    await _reminder?.cancel(id);
  }

  Future<void> setStatus(String id, WoolStatus status) async {
    WoolDeal? changed;
    final next = <WoolDeal>[];
    for (final d in _deals) {
      if (d.id == id) {
        changed = d.copyWith(status: status, updatedAt: DateTime.now());
        next.add(changed);
      } else {
        next.add(d);
      }
    }
    _deals = next;
    await _persist();
    // 标记已参与 / 已到账 / 已过期后，sync 内部会取消这条的提醒。
    if (changed != null) await _reminder?.sync(changed);
  }

  /// 导出当前全部数据，交给同步服务与远端合并。
  SyncSnapshot syncSnapshot() => SyncSnapshot(
        deals: _deals,
        devices: _devices,
        platforms: _platforms,
        platformsUpdatedAt: _platformsUpdatedAt,
        tombstones: _tombstones,
        deviceTombstones: _deviceTombstones,
      );

  /// 应用一次同步的合并结果：一次性落盘，并重排 / 清理提醒。
  Future<void> applySyncSnapshot(SyncSnapshot snapshot) async {
    final previousIds = _deals.map((d) => d.id).toSet();
    // 同步是「导出快照 → 网络往返 → 落盘」，用户完全可能在这段时间里改了
    // 设备名；合并结果里本机那行还是改名前的旧值，直接落盘就把刚改的名字
    // 抹回去了。用户自己起的名字（autoNamed=false）优先级最高，落盘前补回。
    final beforeThis = _findDevice(_thisDeviceId);

    _deals = List<WoolDeal>.of(snapshot.deals);
    _devices = snapshot.devices.isEmpty
        ? <Device>[Device.fallback]
        : List<Device>.of(snapshot.devices);
    if (beforeThis != null && !beforeThis.autoNamed) {
      _devices = <Device>[
        for (final device in _devices)
          device.id == _thisDeviceId
              ? device.copyWith(name: beforeThis.name, autoNamed: false)
              : device,
      ];
    }
    _platforms = List<String>.of(snapshot.platforms);
    _platformsUpdatedAt = snapshot.platformsUpdatedAt;
    _tombstones = Map<String, DateTime>.of(snapshot.tombstones);
    _deviceTombstones = Map<String, DateTime>.of(snapshot.deviceTombstones);

    // 另一台设备删掉了某台设备，它的记录却还留在云端：这些记录会带着一个
    // 已经不存在的 deviceId 回来，任何设备筛选都点不到它们。统一迁回本机，
    // 并刷新 updatedAt，让这次归属变更也能传回去，别下次同步又变回孤儿。
    final knownDeviceIds = _devices.map((d) => d.id).toSet();
    if (_deals.any((d) => !knownDeviceIds.contains(d.deviceId))) {
      final now = DateTime.now();
      _deals = <WoolDeal>[
        for (final deal in _deals)
          knownDeviceIds.contains(deal.deviceId)
              ? deal
              : deal.copyWith(deviceId: _thisDeviceId, updatedAt: now),
      ];
    }

    // 当前筛选的设备可能已被另一台设备删掉，退回「全部设备」避免空列表。
    if (_activeDeviceId.isNotEmpty &&
        !_devices.any((d) => d.id == _activeDeviceId)) {
      _activeDeviceId = '';
    }

    await _repository.save(_deals);
    await _repository.saveDevices(_devices);
    await _repository.savePlatforms(_platforms);
    await _repository.savePlatformsUpdatedAt(_platformsUpdatedAt);
    await _repository.saveTombstones(_tombstones);
    await _repository.saveDeviceTombstones(_deviceTombstones);

    // 同步可能删掉了本机记录：取消它们的通知，否则会在半夜弹出已不存在的活动。
    final currentIds = _deals.map((d) => d.id).toSet();
    for (final id in previousIds.difference(currentIds)) {
      await _reminder?.cancel(id);
    }
    await syncReminders();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _repository.save(_deals);
    notifyListeners();
  }
}
