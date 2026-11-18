import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../data/webdav_transport.dart';
import 'sync_failure_text.dart';

/// 打开「远端文件夹浏览」，返回选中的目录（空串表示根目录），取消返回 null。
///
/// [loader] 接收相对路径，返回该目录下的子项；错误以 [SyncException] 抛出。
Future<String?> showRemoteBrowseDialog({
  required BuildContext context,
  required Future<List<RemoteEntry>> Function(String path) loader,
  String initialPath = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _RemoteBrowseDialog(
      loader: loader,
      initialPath: initialPath,
    ),
  );
}

class _RemoteBrowseDialog extends StatefulWidget {
  const _RemoteBrowseDialog({required this.loader, required this.initialPath});

  final Future<List<RemoteEntry>> Function(String path) loader;
  final String initialPath;

  @override
  State<_RemoteBrowseDialog> createState() => _RemoteBrowseDialogState();
}

class _RemoteBrowseDialogState extends State<_RemoteBrowseDialog> {
  late String _path;
  List<RemoteEntry> _entries = const <RemoteEntry>[];
  SyncException? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _path = _clean(widget.initialPath);
    _load(_path);
  }

  static String _clean(String path) => path
      .trim()
      .split('/')
      .where((s) => s.trim().isNotEmpty)
      .map((s) => s.trim())
      .join('/');

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.loader(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
    } on SyncException catch (error) {
      if (!mounted) return;
      setState(() {
        _path = path;
        _error = error;
        _entries = const <RemoteEntry>[];
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _path = path;
        _error = SyncException(SyncFailure.network, detail: '$error');
        _entries = const <RemoteEntry>[];
        _loading = false;
      });
    }
  }

  List<String> get _segments =>
      _path.isEmpty ? const <String>[] : _path.split('/');

  void _jumpTo(int depth) {
    final target = _segments.take(depth).join('/');
    if (target == _path) return;
    _load(target);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    // 矮屏（模拟器 360×640 之类）上固定 340 会顶出边界，按屏高收缩。
    final contentHeight =
        (MediaQuery.of(context).size.height * 0.46).clamp(220.0, 340.0);

    return AlertDialog(
      title: Text(l10n.syncBrowseTitle),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Breadcrumb(
              segments: _segments,
              rootLabel: l10n.syncBrowseRoot,
              onTap: _jumpTo,
            ),
            const Divider(height: 12),
            Expanded(child: _buildBody(l10n, theme)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton.icon(
          key: const Key('syncBrowseUse'),
          onPressed: _loading ? null : () => Navigator.of(context).pop(_path),
          icon: const Icon(Icons.check),
          label: Text(l10n.syncBrowseUse),
        ),
      ],
    );
  }

  Widget _buildBody(AppLocalizations l10n, ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return ListView(
        children: <Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  syncFailureText(
                    l10n,
                    _error!.failure,
                    statusCode: _error!.statusCode,
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (_error!.detail != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _error!.detail!,
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _load(_path),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.syncBrowseRetry),
            ),
          ),
        ],
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          l10n.syncBrowseEmpty,
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final icon = entry.isCollection
            ? Icons.folder_outlined
            : Icons.description_outlined;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            icon,
            color: entry.isCollection
                ? theme.colorScheme.primary
                : theme.disabledColor,
          ),
          title: Text(
            entry.name,
            style: entry.isCollection
                ? null
                : TextStyle(color: theme.disabledColor),
          ),
          trailing: entry.isCollection ? const Icon(Icons.chevron_right) : null,
          // 只允许进入文件夹：同步文件是文件，点进去没有意义。
          onTap: entry.isCollection
              ? () => _load(_path.isEmpty ? entry.name : '$_path/${entry.name}')
              : null,
        );
      },
    );
  }
}

/// 路径面包屑：根 / a / b，点任一级直接跳回。
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.segments,
    required this.rootLabel,
    required this.onTap,
  });

  final List<String> segments;
  final String rootLabel;
  final void Function(int depth) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = <String>[rootLabel, ...segments];

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: crumbs.length,
        separatorBuilder: (_, __) => Icon(
          Icons.chevron_right,
          size: 16,
          color: theme.disabledColor,
        ),
        itemBuilder: (context, index) {
          final isLast = index == crumbs.length - 1;
          return Center(
            child: InkWell(
              onTap: isLast ? null : () => onTap(index),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  crumbs[index],
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
