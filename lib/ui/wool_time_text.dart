import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../models/wool_deal.dart';

/// 列表 / 详情里统一的活动时间段文案。
/// 只填一端时说清「起」或「截止」，跨天活动补一个「次日」标记。
String dealTimeText(AppLocalizations l10n, WoolDeal deal) {
  final start = deal.startTime;
  final end = deal.endTime;
  if (start == null && end == null) return '';

  final base = start != null && end != null
      ? '${start.text}-${end.text}'
      : (start != null
          ? l10n.timeOnlyStart(start.text)
          : l10n.timeOnlyEnd(end!.text));
  return deal.crossesMidnight ? '$base (${l10n.crossDayShort})' : base;
}
