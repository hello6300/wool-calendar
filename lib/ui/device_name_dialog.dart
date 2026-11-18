import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../state/wool_store.dart';

/// 新增 / 重命名设备共用的输入对话框。
///
/// 校验放在 UI 层：默认设备的显示名跟随语言，只有这里拿得到 [AppLocalizations]，
/// 所以重名判断把 `defaultLabel` 传进 [WoolStore.deviceNameExists]。
/// 返回 trim 后的名字；取消或校验不通过时返回 null。
///
/// 必须用 StatefulWidget 持有 [TextEditingController]：对话框关闭后还有一段退出动画，
/// 期间 TextFormField 仍在树里；若在 showDialog 返回时就 dispose，会抛
/// "A TextEditingController was used after being disposed"。
Future<String?> showDeviceNameDialog(
  BuildContext context, {
  required AppLocalizations l10n,
  required WoolStore store,
  required String title,
  String initial = '',
  String? exceptId,
}) =>
    showDialog<String>(
      context: context,
      builder: (ctx) => _DeviceNameDialog(
        l10n: l10n,
        store: store,
        title: title,
        initial: initial,
        exceptId: exceptId,
      ),
    );

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({
    required this.l10n,
    required this.store,
    required this.title,
    required this.initial,
    this.exceptId,
  });

  final AppLocalizations l10n;
  final WoolStore store;
  final String title;
  final String initial;
  final String? exceptId;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          key: const Key('deviceNameField'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.deviceNameLabel,
            hintText: l10n.deviceNameHint,
            border: const OutlineInputBorder(),
          ),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) return l10n.deviceNameRequired;
            if (widget.store.deviceNameExists(
              name,
              defaultLabel: l10n.defaultDeviceName,
              exceptId: widget.exceptId,
            )) {
              return l10n.deviceNameDuplicate;
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('deviceNameConfirm'),
          onPressed: _submit,
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}
