# 上架素材使用说明（提审前必读）

本目录是 **ASO 文案草案**，由模板生成，用于占位与结构参考。**直接提交会被拒**，
因为其中含未实现的功能宣称与占位链接。已把「离线使用 / 数据本地优先 / 适配主流机型」
等模板宣称替换为 demo 真实具备的能力；其余内容仍须按实际情况核对。

## 必须替换的占位符

| 文件 | 字段 | 当前值 | 应替换为 |
|---|---|---|---|
| `app-store/metadata.json` | `privacy_url` | `https://example.com/privacy` | 可公开访问的真实隐私政策页 |
| `app-store/metadata.json` | `support_url` | `https://example.com/support` | 真实支持页 / 客服入口 |
| `google-play/metadata.json` | `contact_email` | `{{support_email}}` | 真实联系邮箱 |
| `google-play/metadata.json` | `privacy_policy` | `{{privacy_policy_url}}` | 真实隐私政策 URL |
| 两端 `metadata.json` | `category` / `keywords` / 描述 | 效率类示例 | 与实际功能一致的分类与关键词 |

## 提审前一致性检查

- [ ] 文案描述的每个功能，在应用里都能实际演示（App Store Guideline 2.3.1 / Play 虚假描述）
- [ ] 截图/预览视频与当前版本 UI 一致，无演示假功能
- [ ] 隐私政策与应用内入口可访问，且与 Data safety / App Privacy 声明一致
- [ ] 应用内确实提供账号注销（若文案提到账号体系）
- [ ] 无「最佳 / 第一 / 唯一」等绝对化表述
- [ ] 中文 `zh-Hans` 与英文 `en` 两套文案都已补齐（见 `app-store/metadata.json` 的 `locales`）
- [ ] 关键词未堆叠竞品商标，未超各商店字数上限

## 素材清单

- `app-store/`：metadata.json、description.txt、keywords.txt、screenshot-spec.md
- `google-play/`：metadata.json、description.txt、short-description.txt、keywords.txt、screenshot-spec.md
- `aso-report.md`：ASO 结构与关键词策略说明

截图与预览视频需人工按 `screenshot-spec.md` 的尺寸产出，本仓库不含二进制素材。
