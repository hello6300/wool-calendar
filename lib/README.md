# lib/ 代码与本地化

- `main.dart`：入口，Provider(Counter) 示例 + MaterialApp 本地化配置。
- `l10n/intl_en.arb` / `intl_zh.arb`：中英文案源（合法 JSON，含 `@@locale`）。
- 生成类由 `flutter gen-l10n` 产出到 `.dart_tool/flutter_gen/`，代码中通过
  `import 'package:flutter_gen/gen_l10n/app_localizations.dart';` 引用，不入库。

新增文案流程：改 ARB → `flutter gen-l10n` → `AppLocalizations.of(context)!.key` →
`flutter analyze`。**禁止在 Widget 里硬编码用户可见文案**，否则商店本地化与无障碍审查会出问题。
