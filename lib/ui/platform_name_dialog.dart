import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

/// 新增 / 重命名常用平台的输入框。
///
/// 校验在对话框内部完成（空名称、与已有平台重名），失败时不关闭，
/// 避免调用方拿到一个非法名字再回滚。
Future<String?> showPlatformNameDialog(
  BuildContext context, {
  required String title,
  required List<String> existingNames,
  String? initialName,
}) =>
    showDialog<String>(
      context: context,
      builder: (ctx) => _PlatformNameDialog(
        title: title,
        existingNames: existingNames,
        initialName: initialName,
      ),
    );

class _PlatformNameDialog extends StatefulWidget {
  const _PlatformNameDialog({
    required this.title,
    required this.existingNames,
    this.initialName,
  });

  final String title;
  final List<String> existingNames;
  final String? initialName;

  @override
  State<_PlatformNameDialog> createState() => _PlatformNameDialogState();
}

class _PlatformNameDialogState extends State<_PlatformNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName ?? '');
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.platformNameRequired);
      return;
    }

    final lower = name.toLowerCase();
    final except = widget.initialName?.trim().toLowerCase();
    final duplicated = widget.existingNames.any(
      (p) => p.toLowerCase() == lower && p.toLowerCase() != except,
    );
    if (duplicated) {
      setState(() => _error = l10n.platformNameDuplicate);
      return;
    }

    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('platformNameField'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          labelText: l10n.platformNameLabel,
          hintText: l10n.platformNameHint,
          errorText: _error,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('platformNameConfirm'),
          onPressed: _submit,
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}
