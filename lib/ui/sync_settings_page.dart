import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/sync_service.dart';
import '../data/sync_settings.dart';
import '../data/sync_snapshot.dart';
import '../data/webdav_transport.dart';
import '../state/sync_controller.dart';
import '../state/wool_store.dart';
import 'backup_picker_dialog.dart';
import 'remote_browse_dialog.dart';
import 'sync_failure_text.dart';

/// WebDAV 同步设置：填地址 / 账号 / 远端路径，测试连接，立即同步。
///
/// 密码只写系统加密存储，界面上也不再回显（保存后留空就是沿用旧密码）。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _remotePath;
  final _scroll = ScrollController();

  bool _autoSync = false;
  bool _dailyBackup = true;
  bool _obscure = true;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController();
    _username = TextEditingController();
    _password = TextEditingController();
    _remotePath = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final settings = context.read<SyncController>().settings;
    _baseUrl.text = settings.baseUrl;
    _username.text = settings.username;
    _password.text = settings.password;
    _remotePath.text = settings.remotePath;
    _autoSync = settings.autoSync;
    _dailyBackup = settings.dailyBackup;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _baseUrl,
      _username,
      _password,
      _remotePath,
    ]) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _persist(SyncController controller) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      // 「立即同步」已经固定在屏幕底部，校验失败的红字可能落在看不见的输入框上，
      // 光靠表单提示用户会以为按钮坏了，所以再补一条 snackbar 并把列表滚回顶部。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.syncErrorBadConfig),
          ),
        );
        if (_scroll.hasClients) {
          await _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
      return false;
    }
    final path = _remotePath.text.trim();
    await controller.save(
      SyncSettings(
        baseUrl: _baseUrl.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        remotePath: path.isEmpty ? SyncSettings.defaultRemotePath : path,
        autoSync: _autoSync,
        dailyBackup: _dailyBackup,
      ),
    );
    return true;
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await _persist(controller)) return;

    final ok = await controller.testConnection();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.syncTestOk : _failureText(l10n, controller),
        ),
      ),
    );
  }

  Future<void> _sync() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await _persist(controller)) return;

    await controller.syncNow();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          controller.hasError
              ? _failureText(l10n, controller)
              : syncResultText(l10n, controller),
        ),
      ),
    );
  }

  Future<void> _saveOnly() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await _persist(controller)) return;
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.syncSaved)));
  }

  /// 浏览账号里真实的目录结构，选中后直接拼出远端文件路径。
  ///
  /// 为什么非要有这个功能：各家 WebDAV 的「根」映射完全不同 ——
  /// 飞牛 fnOS 的团队文件夹在 `/团队文件-dav/` 下、坚果云在 `/dav/` 下，
  /// 光靠填写框猜前缀，用户只会反复撞 405 / 404。
  Future<void> _browse() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final messenger = ScaffoldMessenger.of(context);

    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty ||
        (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://'))) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.syncServerInvalid)),
      );
      return;
    }

    final current = _remotePath.text.trim();
    final slash = current.lastIndexOf('/');
    final startDir = slash > 0 ? current.substring(0, slash) : '';
    final settings = SyncSettings(
      baseUrl: baseUrl,
      username: _username.text.trim(),
      password: _password.text,
      remotePath: current.isEmpty ? SyncSettings.defaultRemotePath : current,
      autoSync: _autoSync,
      dailyBackup: _dailyBackup,
    );

    final picked = await showRemoteBrowseDialog(
      context: context,
      loader: (path) => controller.browse(settings, path),
      initialPath: startDir,
    );
    if (picked == null || !mounted) return;

    // 文件名沿用用户原来写的；原来是空 / 只有目录时用默认文件名。
    final fileName = _fileNameOf(current);
    final next = picked.isEmpty ? fileName : '$picked/$fileName';
    setState(() => _remotePath.text = next);
  }

  static String _fileNameOf(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return 'wool-sync.json';
    final name = trimmed.split('/').last.trim();
    return name.contains('.') ? name : 'wool-sync.json';
  }

  /// 只读盘点云端文件：条数 / 大小 / 生成时间 / 前几条标题。
  ///
  /// 「同步成功了但云端到底有没有我的羊毛」这个问题，光看计数回答不了，
  /// 所以直接把远端文件的内容摊开给用户看。
  Future<void> _inspect() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final store = context.read<WoolStore>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await _persist(controller)) return;

    final RemoteInspection info;
    try {
      info = await controller.inspectRemote();
    } on SyncException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            syncFailureText(l10n, error.failure, statusCode: error.statusCode),
          ),
        ),
      );
      return;
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.syncInspectTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _inspectLines(l10n, info, store.deals.length),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.syncInspectClose),
          ),
        ],
      ),
    );
  }

  List<Widget> _inspectLines(
    AppLocalizations l10n,
    RemoteInspection info,
    int localDeals,
  ) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final lines = <Widget>[];

    void add(String text) {
      lines.add(Text(text, style: style));
      lines.add(const SizedBox(height: 6));
    }

    if (!info.exists) {
      add(l10n.syncInspectMissing);
      add(l10n.syncInspectLocal('$localDeals'));
      return lines;
    }

    if (!info.recognized) {
      add(l10n.syncErrorUnrecognized);
      add(l10n.syncInspectSize(_formatBytes(info.bytes)));
      add(l10n.syncInspectLocal('$localDeals'));
      return lines;
    }

    add(
      l10n.syncInspectCounts(
        '${info.deals}',
        '${info.devices}',
        '${info.platforms}',
      ),
    );
    if (info.generatedAt != null) {
      add(
        l10n.syncInspectGenerated(
          DateFormat('yyyy-MM-dd HH:mm').format(info.generatedAt!),
        ),
      );
    }
    add(l10n.syncInspectSize(_formatBytes(info.bytes)));
    add(l10n.syncInspectLocal('$localDeals'));
    if (info.sampleTitles.isNotEmpty) {
      final head = info.sampleTitles.take(5).join('、');
      final more = info.sampleTitles.length > 5
          ? ' ${l10n.syncInspectMore('${info.sampleTitles.length - 5}')}'
          : '';
      add('${l10n.syncInspectSample(head)}$more');
    }
    return lines;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  /// 用云端某份备份覆盖本机与云端。
  ///
  /// 这是**覆盖性**操作，所以走三步：选（只列文件名）→ 预览（真读一次，
  /// 给出条数对比）→ 确认（讲清会发生什么、会把云端现状存到哪）。
  /// 恢复前的那份云端数据由服务层自动另存，用户选错日期也回得去。
  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await _persist(controller)) return;

    final List<RemoteBackup> backups;
    try {
      backups = await controller.listBackups();
    } on SyncException catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(_syncError(l10n, error))),
      );
      return;
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!mounted) return;
    if (backups.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.syncRestoreEmpty)));
      return;
    }

    final picked = await showBackupPickerDialog(
      context: context,
      backups: backups,
    );
    if (picked == null || !mounted) return;

    final SyncSnapshot preview;
    try {
      preview = await controller.previewBackup(picked.path);
    } on SyncException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(_syncError(l10n, error))));
      return;
    }
    if (!mounted) return;

    // 安全副本名要和真正写出去的一模一样：这个时刻一路传到 restoreBackup，
    // 中间不再各取一次 now()，否则跨分钟时提示的文件名会与实际不符。
    final at = DateTime.now();
    final safety = WoolSyncService.safetyBackupPath(
      controller.settings.remotePath,
      at,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.syncRestoreConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.syncRestoreConfirmDay(
                DateFormat('yyyy-MM-dd').format(picked.day),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.syncRestoreConfirmCounts(
                '${preview.deals.length}',
                '${controller.localDeals}',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.syncRestoreConfirmWarn(safety),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.syncRestoreOtherDevice,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('syncRestoreConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.syncRestoreConfirmOk),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final outcome = await controller.restoreBackup(picked.path, at: at);
      final done = l10n.syncRestoreDone('${outcome.snapshot.deals.length}');
      final safetyPath = outcome.safetyPath;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            safetyPath == null
                ? done
                : '$done · ${l10n.syncRestoreSafetySaved(safetyPath)}',
          ),
        ),
      );
    } on SyncException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${_syncError(l10n, error)}\n${l10n.syncRestoreAborted}'),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('$error\n${l10n.syncRestoreAborted}')),
      );
    }
  }

  static String _syncError(AppLocalizations l10n, SyncException error) =>
      syncFailureText(l10n, error.failure, statusCode: error.statusCode);

  Future<void> _clear() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.read<SyncController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.syncClear),
        content: Text(l10n.syncClearBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('syncClearConfirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.clear();
    if (!mounted) return;
    _baseUrl.clear();
    _username.clear();
    _password.clear();
    _remotePath.clear();
    setState(() {
      _autoSync = false;
      _dailyBackup = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = context.watch<SyncController>();
    final busy = controller.busy;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncSettings)),
      body: Form(
        key: _formKey,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            // 已经配好时收起说明卡：进页面第一眼要看到状态和输入框，
            // 而不是三段要往下翻才看得完的帮助文字。
            _HelpCard(l10n: l10n, configured: controller.configured),
            const SizedBox(height: 12),
            _StatusCard(l10n: l10n, controller: controller),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('syncBaseUrlField'),
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.syncServerUrl,
                hintText: l10n.syncServerHint,
                prefixIcon: const Icon(Icons.cloud_outlined),
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return l10n.syncServerRequired;
                if (!text.startsWith('http://') &&
                    !text.startsWith('https://')) {
                  return l10n.syncServerInvalid;
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('syncUsernameField'),
              controller: _username,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.syncUsername,
                prefixIcon: const Icon(Icons.person_outline),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('syncPasswordField'),
              controller: _password,
              obscureText: _obscure,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.syncPassword,
                helperText: l10n.syncPasswordNote,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip:
                      _obscure ? l10n.syncShowPassword : l10n.syncHidePassword,
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('syncRemotePathField'),
              controller: _remotePath,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.syncRemotePath,
                hintText: SyncSettings.defaultRemotePath,
                helperText: l10n.syncRemotePathNote,
                prefixIcon: const Icon(Icons.folder_outlined),
                suffixIcon: IconButton(
                  key: const Key('syncBrowseButton'),
                  tooltip: l10n.syncBrowse,
                  icon: const Icon(Icons.account_tree_outlined),
                  onPressed: busy ? null : _browse,
                ),
                border: const OutlineInputBorder(),
              ),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? l10n.syncRemotePathRequired
                  : null,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('syncAutoSwitch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.syncAuto),
              subtitle: Text(l10n.syncAutoHint),
              value: _autoSync,
              onChanged: (value) => setState(() => _autoSync = value),
            ),
            SwitchListTile(
              key: const Key('syncBackupSwitch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.syncDailyBackup),
              subtitle: Text(l10n.syncDailyBackupHint),
              value: _dailyBackup,
              onChanged: (value) => setState(() => _dailyBackup = value),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('syncTestButton'),
                    onPressed: busy ? null : _test,
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(l10n.syncTest),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('syncSaveButton'),
                    onPressed: busy ? null : _saveOnly,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(l10n.syncSave),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const Key('syncInspectButton'),
              onPressed: busy ? null : _inspect,
              icon: const Icon(Icons.visibility_outlined),
              label: Text(l10n.syncInspect),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('syncRestoreButton'),
              onPressed: busy ? null : _restore,
              icon: const Icon(Icons.settings_backup_restore),
              label: Text(l10n.syncRestore),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('syncClearButton'),
              onPressed: busy ? null : _clear,
              child: Text(l10n.syncClear),
            ),
          ],
        ),
      ),
      // 「立即同步」钉在屏幕底部：以前它在列表最末端，要一路往下翻才看得到，
      // 而这正是进这个页面十次里有九次想按的那个键。
      bottomNavigationBar: _SyncActionBar(
        l10n: l10n,
        busy: busy,
        onSync: _sync,
      ),
    );
  }
}

/// 底部常驻操作条：只有「立即同步」一个键，全宽、拇指够得到。
///
/// 键盘弹出时收起来 —— 否则它会被顶到输入框正上方，把表单挤成一条缝。
class _SyncActionBar extends StatelessWidget {
  const _SyncActionBar({
    required this.l10n,
    required this.busy,
    required this.onSync,
  });

  final AppLocalizations l10n;
  final bool busy;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              key: const Key('syncNowButton'),
              onPressed: busy ? null : onSync,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(busy ? l10n.syncRunning : l10n.syncNow),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.l10n, required this.configured});

  final AppLocalizations l10n;

  /// 已经填过服务器地址就默认收起，把首屏留给状态和输入框。
  final bool configured;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 展开时那条横线，卡片里看着像破了个口子。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('syncHelpTile'),
          initiallyExpanded: !configured,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: Icon(Icons.info_outline, size: 18, color: scheme.primary),
          title: Text(l10n.syncHelpTitle, style: textTheme.titleSmall),
          children: <Widget>[
            Text(l10n.syncHelp, style: textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(
              l10n.syncHelpEndpoints,
              style: textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 6),
            Text(l10n.syncHelpMkdir, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.l10n, required this.controller});

  final AppLocalizations l10n;
  final SyncController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = controller.lastSyncAt;
    final stats = controller.stats;
    final hasError = controller.hasError;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasError ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                hasError ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: hasError ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasError
                      ? _failureText(l10n, controller)
                      : (last == null
                          ? l10n.syncNever
                          : l10n.syncLastAt(
                              DateFormat('yyyy-MM-dd HH:mm').format(last),
                            )),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (!hasError && stats != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              syncResultText(l10n, controller),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (!hasError && controller.backupPathToday != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              l10n.syncBackupDone(controller.backupPathToday!),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else if (!hasError && controller.backedUpToday) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              l10n.syncBackupDoneToday,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (hasError && controller.detail != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              controller.detail!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

String _failureText(AppLocalizations l10n, SyncController controller) =>
    syncFailureText(
      l10n,
      controller.failure,
      statusCode: controller.statusCode,
    );
