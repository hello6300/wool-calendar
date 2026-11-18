import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/wool_deal.dart';
import '../state/wool_store.dart';
import 'wool_editor.dart';
import 'wool_status.dart';
import 'wool_time_text.dart';

/// 当日列表里的一条记录：折叠时看概要，展开看详情/备注/链接与操作。
class WoolTile extends StatelessWidget {
  const WoolTile({super.key, required this.deal});

  final WoolDeal deal;

  Future<void> _confirmDelete(
    BuildContext context,
    AppLocalizations l10n,
    WoolStore store,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteConfirmTitle),
        content: Text(l10n.deleteConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.remove(deal.id);
    messenger.showSnackBar(SnackBar(content: Text(l10n.deleted)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final store = context.read<WoolStore>();
    final scheme = Theme.of(context).colorScheme;
    final reward =
        deal.amount == null ? '' : '  ·  ¥${deal.amount!.toStringAsFixed(2)}';
    final time = dealTimeText(l10n, deal);
    final timeLabel = time.isEmpty ? '' : '  ·  $time';
    final deviceLabel =
        '  ·  ${store.deviceName(deal.deviceId, l10n.defaultDeviceName)}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        leading: CircleAvatar(
          backgroundColor: statusColor(deal.status).withOpacity(0.15),
          child: Icon(statusIcon(deal.status),
              color: statusColor(deal.status), size: 20),
        ),
        title: Text(deal.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${deal.platform}$deviceLabel  ·  '
          '${statusText(l10n, deal.status)}$timeLabel$reward',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        children: <Widget>[
          if (deal.isFromDeviceCalendar)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.event_available, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.importedFromDevice(
                        deal.sourceName ?? l10n.importFallbackPlatform,
                      ),
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          if (deal.hasTime)
            _section(
              context,
              l10n.timeRangeLabel,
              '${deal.dateText}  ${dealTimeText(l10n, deal)}'
              '${deal.remind ? '  ·  ${l10n.remindLabel}' : ''}',
            ),
          if (deal.detail.trim().isNotEmpty)
            _section(context, l10n.dealDetail, deal.detail),
          if (deal.notes.trim().isNotEmpty)
            _section(context, l10n.notes, deal.notes),
          if (deal.url.trim().isNotEmpty)
            InkWell(
              onTap: () async {
                // 不启动外部浏览器（避免新增 url_launcher 依赖），改为复制链接。
                final messenger = ScaffoldMessenger.of(context);
                final copied = l10n.linkCopied;
                await Clipboard.setData(ClipboardData(text: deal.url));
                messenger.showSnackBar(SnackBar(content: Text(copied)));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.link, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        deal.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.primary, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.copy, size: 14, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(l10n.copyLink,
                        style: TextStyle(color: scheme.primary, fontSize: 12)),
                  ],
                ),
              ),
            ),
          const Divider(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: <Widget>[
                for (final s in WoolStatus.values)
                  ChoiceChip(
                    label: Text(statusText(l10n, s)),
                    selected: deal.status == s,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => store.setStatus(deal.id, s),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WoolEditorPage(date: deal.date, deal: deal),
                  ),
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l10n.editDeal),
              ),
              TextButton.icon(
                onPressed: () => _confirmDelete(context, l10n, store),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(l10n.delete),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}
