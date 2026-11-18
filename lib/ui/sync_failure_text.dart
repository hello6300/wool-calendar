import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../data/webdav_transport.dart';
import '../state/sync_controller.dart';

/// 把同步失败类型翻成一句能直接照做的话。
///
/// 单独放一个函数，是因为「设置页的状态卡」和「浏览目录弹窗」都要用它，
/// 两处各写一份 switch 迟早会不一致。
String syncFailureText(
  AppLocalizations l10n,
  SyncFailure? failure, {
  int? statusCode,
}) {
  switch (failure) {
    case SyncFailure.badConfig:
      return l10n.syncErrorBadConfig;
    case SyncFailure.auth:
      return l10n.syncErrorAuth;
    case SyncFailure.forbidden:
      return l10n.syncErrorForbidden;
    case SyncFailure.notFound:
      return l10n.syncErrorNotFound;
    case SyncFailure.notWebDav:
      return l10n.syncErrorNotWebDav;
    case SyncFailure.mkdirUnsupported:
      return l10n.syncErrorMkdirUnsupported;
    case SyncFailure.pathIsFolder:
      return l10n.syncErrorPathIsFolder;
    case SyncFailure.unrecognized:
      return l10n.syncErrorUnrecognized;
    case SyncFailure.backupFailed:
      return l10n.syncErrorBackupFailed;
    case SyncFailure.network:
      return l10n.syncErrorNetwork;
    case SyncFailure.timeout:
      return l10n.syncErrorTimeout;
    case SyncFailure.server:
      return l10n.syncErrorServer(statusCode ?? 0);
    case null:
      return '';
  }
}

/// 同步结束后给用户看的一句话：成功报四项计数，失败报能照做的原因。
///
/// 主界面「下拉即同步」和设置页的按钮、状态卡共用这一句，
/// 免得同一件事在两处说法不一样。
String syncResultText(AppLocalizations l10n, SyncController controller) {
  if (controller.hasError) {
    return syncFailureText(
      l10n,
      controller.failure,
      statusCode: controller.statusCode,
    );
  }
  final stats = controller.stats;
  if (stats == null) return l10n.syncDone;
  // 四个数都要给：少了「上传」这一项，用户加了记录再同步会看到
  // 「新增 0 · 更新 0 · 删除 0」，误以为没同步上去。
  return l10n.syncResult(
    stats.remoteAdded,
    stats.localOnly,
    stats.conflicts,
    stats.totalDeleted,
  );
}
