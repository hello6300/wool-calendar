import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WebDAV 同步配置。
///
/// 密码**不进 SharedPreferences**：走系统加密存储（Android Keystore 保护的
/// EncryptedSharedPreferences），这是唯一需要特殊对待的字段。
class SyncSettings {
  const SyncSettings({
    this.baseUrl = '',
    this.username = '',
    this.password = '',
    this.remotePath = defaultRemotePath,
    this.autoSync = false,
    this.dailyBackup = true,
  });

  /// 坚果云 / Nextcloud / 群晖都支持这种相对路径，目录会自动逐级创建。
  static const String defaultRemotePath = 'appforge/wool-sync.json';

  /// WebDAV 根地址，例如 `https://dav.jianguoyun.com/dav/`。
  final String baseUrl;
  final String username;
  final String password;

  /// 相对 [baseUrl] 的文件路径，例如 `appforge/wool-sync.json`。
  final String remotePath;

  /// 启动时自动同步一次（失败不打扰用户，只在设置页显示状态）。
  final bool autoSync;

  /// 每天第一次同步前，先把云端现有文件复制成 `<名字>-YYYY-MM-DD.json`。
  /// 默认开：同步会用合并结果覆盖云端，没有备份就没有后悔药。
  final bool dailyBackup;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && remotePath.trim().isNotEmpty;

  SyncSettings copyWith({
    String? baseUrl,
    String? username,
    String? password,
    String? remotePath,
    bool? autoSync,
    bool? dailyBackup,
  }) =>
      SyncSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        remotePath: remotePath ?? this.remotePath,
        autoSync: autoSync ?? this.autoSync,
        dailyBackup: dailyBackup ?? this.dailyBackup,
      );
}

/// 密码等敏感字段的存储边界；测试用内存实现，不碰原生 keystore。
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 测试 / 内存场景用；不落盘。
class MemorySecretStore implements SecretStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// 同步配置的持久化：普通字段进 SharedPreferences，密码进 [SecretStore]。
class SyncSettingsStore {
  SyncSettingsStore(this._prefs, this._secrets);

  static const String baseUrlKey = 'appforge.sync.base_url';
  static const String usernameKey = 'appforge.sync.username';
  static const String remotePathKey = 'appforge.sync.remote_path';
  static const String autoSyncKey = 'appforge.sync.auto';
  static const String lastSyncKey = 'appforge.sync.last_at';

  /// 每日备份开关 + 最近一次备份的时刻（只用来判断「今天备份过没有」）。
  static const String dailyBackupKey = 'appforge.sync.backup_daily';
  static const String lastBackupKey = 'appforge.sync.last_backup_at';
  static const String lastBackupPathKey = 'appforge.sync.last_backup_path';
  static const String passwordSecretKey = 'appforge.sync.password';

  final SharedPreferences _prefs;
  final SecretStore _secrets;

  Future<SyncSettings> load() async => SyncSettings(
        baseUrl: _prefs.getString(baseUrlKey) ?? '',
        username: _prefs.getString(usernameKey) ?? '',
        password: await _secrets.read(passwordSecretKey) ?? '',
        remotePath:
            _prefs.getString(remotePathKey) ?? SyncSettings.defaultRemotePath,
        autoSync: _prefs.getBool(autoSyncKey) ?? false,
        // 没存过就是默认开：备份属于兜底保护，不该靠用户自己去发现开关。
        dailyBackup: _prefs.getBool(dailyBackupKey) ?? true,
      );

  Future<void> save(SyncSettings settings) async {
    await _prefs.setString(baseUrlKey, settings.baseUrl.trim());
    await _prefs.setString(usernameKey, settings.username.trim());
    final path = settings.remotePath.trim();
    await _prefs.setString(
      remotePathKey,
      path.isEmpty ? SyncSettings.defaultRemotePath : path,
    );
    await _prefs.setBool(autoSyncKey, settings.autoSync);
    await _prefs.setBool(dailyBackupKey, settings.dailyBackup);

    if (settings.password.isEmpty) {
      await _secrets.delete(passwordSecretKey);
    } else {
      await _secrets.write(passwordSecretKey, settings.password);
    }
  }

  DateTime? lastSyncAt() {
    final micros = _prefs.getInt(lastSyncKey);
    return micros == null ? null : DateTime.fromMillisecondsSinceEpoch(micros);
  }

  Future<void> markSynced(DateTime at) =>
      _prefs.setInt(lastSyncKey, at.millisecondsSinceEpoch);

  DateTime? lastBackupAt() {
    final millis = _prefs.getInt(lastBackupKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// 最近一次备份写到了哪个文件；云端还没有文件时没备份过，为 null。
  String? lastBackupPath() => _prefs.getString(lastBackupPathKey);

  Future<void> markBackedUp(DateTime at, {String? path}) async {
    await _prefs.setInt(lastBackupKey, at.millisecondsSinceEpoch);
    if (path == null) {
      await _prefs.remove(lastBackupPathKey);
    } else {
      await _prefs.setString(lastBackupPathKey, path);
    }
  }

  /// 清除配置（保留本地账本，只断开同步）。
  Future<void> clear() async {
    await _prefs.remove(baseUrlKey);
    await _prefs.remove(usernameKey);
    await _prefs.remove(remotePathKey);
    await _prefs.remove(autoSyncKey);
    await _prefs.remove(lastSyncKey);
    await _prefs.remove(dailyBackupKey);
    await _prefs.remove(lastBackupKey);
    await _prefs.remove(lastBackupPathKey);
    await _secrets.delete(passwordSecretKey);
  }
}
