import 'package:flutter/foundation.dart';

import '../data/sync_service.dart';
import '../data/sync_settings.dart';
import '../data/sync_snapshot.dart';
import '../data/webdav_transport.dart';
import 'wool_store.dart';

/// 同步的界面状态与流程编排。
///
/// 单独一个 ChangeNotifier，而不是塞进 [WoolStore]：同步有忙碌态、上次结果、
/// 错误类型这些「界面状态」，和账本数据是两件事。合并结果最终仍写回 [WoolStore]，
/// 保证 UI 只有一个数据源。
class SyncController extends ChangeNotifier {
  SyncController({
    required WoolStore store,
    required SyncSettingsStore settingsStore,
    SyncTransport Function(SyncSettings settings)? transportFactory,
  })  : _store = store,
        _settingsStore = settingsStore,
        _transportFactory = transportFactory ?? _defaultTransport;

  static SyncTransport _defaultTransport(SyncSettings settings) =>
      WebDavTransport(
        baseUrl: settings.baseUrl,
        username: settings.username,
        password: settings.password,
      );

  final WoolStore _store;
  final SyncSettingsStore _settingsStore;
  final SyncTransport Function(SyncSettings settings) _transportFactory;

  SyncSettings _settings = const SyncSettings();
  bool _loaded = false;
  bool _busy = false;
  SyncFailure? _failure;
  String? _detail;
  int? _statusCode;
  SyncMergeStats? _stats;
  DateTime? _lastSyncAt;
  DateTime? _lastBackupAt;

  /// 本次同步实际写出的备份文件（相对路径）；没备份就是 null。
  String? _backupPath;

  /// 最近一次备份写出的文件，用来在「今天已经备份过」时继续给用户看。
  String? _lastBackupPath;

  SyncSettings get settings => _settings;
  bool get isLoaded => _loaded;
  bool get busy => _busy;
  bool get configured => _settings.isConfigured;
  SyncFailure? get failure => _failure;
  String? get detail => _detail;
  int? get statusCode => _statusCode;
  SyncMergeStats? get stats => _stats;
  DateTime? get lastSyncAt => _lastSyncAt;
  DateTime? get lastBackupAt => _lastBackupAt;
  String? get backupPath => _backupPath;

  /// 今天是否已经备份过（含只记了时间、没记文件名的旧数据）。
  bool get backedUpToday {
    final at = _lastBackupAt;
    if (at == null) return false;
    return !WoolSyncService.needsDailyBackup(at, DateTime.now());
  }

  /// 界面上要显示的「今日备份」：本次刚写的不说，今天早先备份过的也继续显示，
  /// 否则第二次同步做完提示就消失了，用户会以为今天没备份。
  String? get backupPathToday {
    if (_backupPath != null) return _backupPath;
    final at = _lastBackupAt;
    if (at == null) return null;
    final sameDay = !WoolSyncService.needsDailyBackup(at, DateTime.now());
    return sameDay ? _lastBackupPath : null;
  }
  bool get hasError => _failure != null;

  /// 本机现有记录条数。恢复确认框要用它和备份里的条数对比，
  /// 页面因此不必再自己去读一次 [WoolStore]。
  int get localDeals => _store.deals.length;

  Future<void> load() async {
    _settings = await _settingsStore.load();
    _lastSyncAt = _settingsStore.lastSyncAt();
    _lastBackupAt = _settingsStore.lastBackupAt();
    _lastBackupPath = _settingsStore.lastBackupPath();
    _loaded = true;
    notifyListeners();
  }

  Future<void> save(SyncSettings settings) async {
    _settings = settings;
    await _settingsStore.save(settings);
    _failure = null;
    _detail = null;
    _statusCode = null;
    notifyListeners();
  }

  /// 断开同步但**不删除本地账本**。
  Future<void> clear() async {
    await _settingsStore.clear();
    _settings = const SyncSettings();
    _lastSyncAt = null;
    _lastBackupAt = null;
    _backupPath = null;
    _lastBackupPath = null;
    _stats = null;
    _failure = null;
    _detail = null;
    _statusCode = null;
    notifyListeners();
  }

  /// 只验证地址 / 账号 / 权限，不读写业务数据。
  Future<bool> testConnection() async {
    if (!_settings.isConfigured) {
      _failure = SyncFailure.badConfig;
      notifyListeners();
      return false;
    }

    _busy = true;
    _failure = null;
    _detail = null;
    _statusCode = null;
    notifyListeners();
    try {
      await _transportFactory(_settings).probe(_settings.remotePath);
      return true;
    } on SyncException catch (error) {
      _failure = error.failure;
      _detail = error.detail;
      _statusCode = error.statusCode;
      return false;
    } on Object catch (error) {
      _failure = SyncFailure.network;
      _detail = error.toString();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 拉取 → 合并 → 落盘 → 上传。失败时本地数据保持不变（不会半途覆盖）。
  Future<void> syncNow() async {
    if (!_settings.isConfigured) {
      _failure = SyncFailure.badConfig;
      notifyListeners();
      return;
    }
    if (_busy) return;

    _busy = true;
    _failure = null;
    _detail = null;
    _statusCode = null;
    _stats = null;
    _backupPath = null;
    notifyListeners();

    final now = DateTime.now();
    try {
      final service = WoolSyncService(transport: _transportFactory(_settings));

      // 同步会用合并结果覆盖云端，所以备份必须发生在 run() 之前。
      // 备份失败就中止：宁可不改云端，也不能让用户失去「回到昨天」的机会。
      if (_settings.dailyBackup &&
          WoolSyncService.needsDailyBackup(_lastBackupAt, now)) {
        try {
          _backupPath = await service.backupRemote(
            remotePath: _settings.remotePath,
            day: now,
          );
        } on SyncException catch (error) {
          throw SyncException(
            SyncFailure.backupFailed,
            statusCode: error.statusCode,
            detail: error.detail,
          );
        }
        await _settingsStore.markBackedUp(now, path: _backupPath);
        _lastBackupAt = now;
        _lastBackupPath = _backupPath;
      }

      final outcome = await service.run(
        remotePath: _settings.remotePath,
        local: _store.syncSnapshot(),
      );
      await _store.applySyncSnapshot(outcome.snapshot);
      await _settingsStore.markSynced(now);
      _lastSyncAt = now;
      _stats = outcome.stats;
    } on SyncException catch (error) {
      _failure = error.failure;
      _detail = error.detail;
      _statusCode = error.statusCode;
    } on Object catch (error) {
      _failure = SyncFailure.network;
      _detail = error.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 只读看一遍云端文件里有什么，不做写入、不建目录。
  ///
  /// 走**当前已保存**的配置：诊断要看的是「同步真正在读的那个文件」，
  /// 而不是表单里还没保存的草稿。
  Future<RemoteInspection> inspectRemote() async {
    if (!_settings.isConfigured) {
      throw const SyncException(SyncFailure.badConfig);
    }
    final service = WoolSyncService(transport: _transportFactory(_settings));
    return service.inspect(remotePath: _settings.remotePath);
  }

  /// 列远端目录，给「选择远端文件夹」用。  ///
  /// 有意用**传入的**配置而不是已保存的那份：用户往往还没保存就先想看看
  /// 账号里有什么，此时表单值才是他刚敲进去的。也不改动 `_failure` 等状态，
  /// 浏览失败只影响浏览弹窗自己。
  Future<List<RemoteEntry>> browse(SyncSettings settings, String path) {
    if (!settings.isConfigured) {
      throw const SyncException(SyncFailure.badConfig);
    }
    return _transportFactory(settings).list(path);
  }

  // ---------------------------------------------------------------------------
  // 备份恢复
  // ---------------------------------------------------------------------------

  /// 云端有哪些备份。走**已保存**的配置：恢复要动真数据，不该用还没保存的草稿。
  Future<List<RemoteBackup>> listBackups() async {
    if (!_settings.isConfigured) {
      throw const SyncException(SyncFailure.badConfig);
    }
    return WoolSyncService(transport: _transportFactory(_settings))
        .listBackups(remotePath: _settings.remotePath);
  }

  /// 只读预览：把备份读出来看有多少条，**不写本机也不写云端**。
  Future<SyncSnapshot> previewBackup(String path) async {
    if (!_settings.isConfigured) {
      throw const SyncException(SyncFailure.badConfig);
    }
    return WoolSyncService(transport: _transportFactory(_settings))
        .readSnapshot(path: path);
  }

  /// 用某个备份覆盖云端与本机。
  ///
  /// [at] 由调用方传入并一路用到底：确认框里给用户看的安全副本名，
  /// 要和真正写出去的文件名一模一样，不能各取一次 `DateTime.now()`。
  Future<RestoreOutcome> restoreBackup(String backupPath, {DateTime? at}) async {
    if (!_settings.isConfigured) {
      throw const SyncException(SyncFailure.badConfig);
    }

    final moment = at ?? DateTime.now();
    _busy = true;
    _failure = null;
    _detail = null;
    _statusCode = null;
    notifyListeners();
    try {
      final service = WoolSyncService(transport: _transportFactory(_settings));
      final outcome = await service.restore(
        remotePath: _settings.remotePath,
        backupPath: backupPath,
        at: moment,
      );
      await _store.applySyncSnapshot(outcome.snapshot);
      await _settingsStore.markSynced(moment);
      _lastSyncAt = moment;
      // 恢复不是合并，别把上一次的「新增/更新/删除」继续挂在状态卡上误导人。
      _stats = null;
      return outcome;
    } on SyncException catch (error) {
      _failure = error.failure;
      _detail = error.detail;
      _statusCode = error.statusCode;
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 冷启动时自动同步一次；未开启或未配置就直接返回，不打扰用户。
  Future<void> autoSyncIfEnabled() async {
    if (!_settings.autoSync || !_settings.isConfigured) return;
    await syncNow();
  }
}
