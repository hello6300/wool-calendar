# 上线路径总纲（Android + iOS）

> 目标链路：**PR 质量门禁 → main 构建产物 → tag 分发测试轨道 → 人工提审 → 灰度 → 全量**。
> 只有 `release.yml` 会向商店上传产物，`ci.yml` 永远不碰商店后台。

> **⚠ 当前阶段：只做本地开发，暂不发布（2026-11-06 起）——本文件以下所有步骤暂不执行。**
> 两条 workflow 的发布动作由仓库变量 `ENABLE_RELEASE` 控制，默认关闭：
> `ci.yml` 不再注入/强制校验 upload key，`release.yml` 的 `android` / `ios` job 全部跳过，
> **误打 `v*` tag 也不会向商店上传任何产物**。日常开发请改看 [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)。
>
> 本文保留完整双端上线路径备查。恢复顺序：
> ① 按 [ANDROID_SIGNING_SETUP.md](ANDROID_SIGNING_SETUP.md) 配齐 Android 的 5 个 Secrets；
> ② 仓库 Variables 加 `ENABLE_RELEASE=true`；
> ③ 若要恢复 iOS，再加 `ENABLE_IOS=true` 并补齐 Match / ASC / 证书 Secrets。
> 三项都是改配置，不需要改代码或重建工程。
>
> （2026-11-05 起的范围仍是 **Android only**：`ios/` 原生壳、Fastfile 的 iOS lanes、
> App Store 上架素材与本文 iOS 章节全部原样保留，只是两个 `ios` job 默认跳过。）

```
本地 bootstrap.sh ──► 提交 android/ ios/ ──► PR(ci.yml: analyze/test/编译)
                                              │
                                        合并 main(ci.yml: 签名 AAB + Artifact)
                                              │
                                   git tag v1.0.0 / workflow_dispatch
                                              │
                    ┌─────────────────────────┴─────────────────────────┐
              release.yml/android                              release.yml/ios
              Play 内部测试轨道 (AAB)                        TestFlight (IPA)
                    │                                              │
              封闭/开放测试 → 生产                          提交审核 → 手动发布
                    └──────────── 分阶段灰度 + 崩溃观测 ────────────┘
```

---

## 阶段 0 · 账号与前置资产

| 平台 | 需要准备 | 备注 |
|---|---|---|
| Apple | Apple Developer 账号（￥688/年）、App Store Connect 建 App 记录 | Bundle ID `com.appforge.demo` |
| Google | Play Console 开发者账号（$25 一次性）、建应用 | 启用 **Play App Signing**（上传密钥由我们保管） |
| 代码 | GitHub 仓库 Secrets（见阶段 3） | 私有证书仓库（Match）另建 |
| 素材 | 图标 iOS 1024×1024 / Android 512×512、启动屏、截图、隐私政策 URL | 规格见 `store-listing/*/screenshot-spec.md` |

---

## 阶段 1 · 生成并提交原生壳

```bash
bash scripts/bootstrap.sh
git add android/ ios/ && git commit -m "chore: add native shells"
```

脚本会：生成两端壳 → 恢复已定制的 `pubspec.yaml` / `main.dart` / `README.md` →
把 `com.appforge.appforge_demo` 统一改成 `com.appforge.demo` → `pub get` + `gen-l10n`。

> CI 里有 `Ensure native shells are committed` 显式检查。不要指望 CI 自动 `flutter create`——
> 签名配置、Info.plist 权限用途文案、图标都必须固化在仓库里。

---

## 阶段 2 · 签名配置

> **可直接照做的完整命令清单**：[ANDROID_SIGNING_SETUP.md](ANDROID_SIGNING_SETUP.md)
> ——keystore 生成 → Base64 → Play App Signing → 服务账号 → 5 个 GitHub Secrets →
> 本地预演验证证书 → 触发发布 → 验收清单与常见坑 → 个人账号 12 人 × 14 天政策风险。
> 本节只保留构建侧的签名原理。

### Android（upload key + build.gradle）

```bash
keytool -genkey -v -keystore android/app/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
# 生成 Base64 供 Secret 使用（不要复制明文到任何文件）
base64 -w0 android/app/upload-keystore.jks
```

**`android/app/build.gradle` 已内置下列逻辑，无需再手动合入**（Flutter 3.24 模板为 Groovy；
若改为 Kotlin DSL 需相应改写）。与官方模板的差别是多了「`key.properties` 不存在就回退 debug 签名」的分支：
本地不配密钥也能构建，CI 注入密钥后自动切换为 upload key。

```groovy
def keystoreProperties = new java.util.Properties()
def keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new java.io.FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            if (keystorePropertiesFile.exists()) {
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
                storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
                storePassword keystoreProperties['storePassword']
            }
        }
    }
    buildTypes {
        release {
            signingConfig = keystorePropertiesFile.exists() ? signingConfigs.release : signingConfigs.debug
        }
    }
}
```

本地可把 `android/key.properties.example` 复制为 `android/key.properties` 并填值（已在 `.gitignore`）。
CI 由 workflow 从 Secrets 生成同名文件，**两者都不入库**。
`storeFile=upload-keystore.jks` 是相对 `android/app/` 解析，与 `ci.yml` 写入
`android/app/upload-keystore.jks` 的位置一致。
**没有该文件时产出的 AAB 是 debug 签名，只能本地验证，不能上传 Play。**

Play Console → Setup → API access：创建服务账号、授予 Release 权限，下载 JSON 并 `base64 -w0`。

### iOS（Match + ASC API Key）

```bash
bundle install
bundle exec fastlane match init          # 指向私有证书 Git 仓库
bundle exec fastlane match appstore      # 首次创建 Distribution 证书与 profile
```

- App Store Connect → Users and Access → Integrations → 生成 API Key（`.p8`），记下 **Key ID / Issuer ID**。
- `IOS_PROFILE_NAME` 通常为 `match AppStore com.appforge.demo`。
- `MATCH_GIT_BASIC_AUTHORIZATION` = `base64("git用户名:个人访问令牌")`，用于 CI 只读拉取证书仓库。
- `Fastfile` 的 `update_code_signing_settings` 会把 Runner target 从 Automatic 切到 Manual 并指定 profile，
  避免 Match 与 Xcode 自动签名冲突。

> 密钥/证书/私钥**一律不写入仓库**；本仓库只有变量引用与 `.example` 占位文件。

---

## 阶段 3 · GitHub Secrets 清单

路径：`Settings → Secrets and variables → Actions → New repository secret`

### Android

| Secret | 来源 | 必填 |
|---|---|---|
| `ANDROID_KEYSTORE_B64` | upload-keystore.jks 的 Base64 | ✅ |
| `ANDROID_KEYSTORE_PASS` | keystore 口令 | ✅ |
| `ANDROID_KEY_ALIAS` | 别名（如 `upload`） | ✅ |
| `ANDROID_KEY_PASS` | key 口令 | ✅ |
| `PLAY_SERVICE_ACCOUNT_JSON_B64` | Play 服务账号 JSON 的 Base64 | ✅（release） |

### iOS

| Secret | 来源 | 必填 |
|---|---|---|
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY` | App Store Connect API Key；`ASC_PRIVATE_KEY` 为 `.p8` 内容 | ✅（release） |
| `MATCH_GIT_URL` / `MATCH_GIT_BASIC_AUTHORIZATION` / `MATCH_PASSWORD` | Match 私有证书仓库与加密口令 | ✅（release） |
| `APPLE_TEAM_ID` | Developer Team ID | ✅（release） |
| `IOS_PROFILE_NAME` | Match 生成的 profile 名 | ✅（release） |

> `pull_request` 不会注入 Secrets，`ci.yml` 已用 `if` 跳过签名步骤（此时 AAB 用 debug 签名，仅供验证，不可上架）。

---

## 阶段 4 · 跑流水线

```bash
# 本地先验
flutter analyze && flutter test
bundle exec fastlane android test
# bundle exec fastlane ios test   # Android-only 阶段跳过；恢复 iOS 后启用

# 触发分发
git tag v1.0.0 && git push origin v1.0.0
# 或在 Actions 页手动运行 mobile-release，选择 play_track
```

- `BUILD_NUMBER` 取 `github.run_number`，两端的 build number / versionCode 必须**严格递增**。
- 产物同时存档为 GitHub Artifact（AAB / IPA，保留 90 天），便于复现与人工补传。
- 首次运行前确认商店后台已建好应用与版本，否则 `supply` / `deliver` 会报「app not found」。

---

## 阶段 5 · 双商店提审

### Google Play
1. 填商店信息（用 `store-listing/google-play/`）、**Data safety** 数据安全声明、内容分级问卷。
2. `internal` 轨道验证 → `alpha/beta` 封闭/开放测试 → `production`。
3. 分阶段发布：`10% → 50% → 100%`，每档观察崩溃率与 ANR。

### App Store
1. 填元数据（`store-listing/app-store/`）、年龄分级、定价、隐私政策 URL。
2. TestFlight 内部测试 → 外部测试（可选）→ 提交审核（一般 1–2 天）。
3. 过审后选「手动发布」，用 TestFlight 与分阶段发布（7 天灰度）控制节奏。
4. 被拒时看 Resolution Center 逐条回复，不要重复提交同一构建。

### 提审前自查（三份清单逐条打勾）
- `checklists/checklist-a11y.md` — 朗读标签、动态字体、44/48 触控目标、4.5:1 对比度
- `checklists/checklist-security.md` — HTTPS/Pinning、令牌加密、权限最小化、账号注销
- `checklists/checklist-commercialization.md` — IAP 合规、恢复购买、订阅披露、站外支付禁令

**审核红线**：禁止绝对化用语与虚假演示；iOS 不得引导站外支付，安卓内购必须走 Play Billing；
敏感权限须写明用途；账号系统必须提供注销；不得使用未授权第三方素材。

> ⚠ `store-listing/` 是模板草案：已剔除「离线使用/数据本地优先」等本 demo 未实现的功能宣称，
> 但仍含 `example.com` 隐私/支持链接与 `{{support_email}}` 等占位符。**提审前必须逐项替换**，
> 清单见 `store-listing/README.md`。文案与实际功能不符是 App Store 2.3.1 与 Play 虚假描述的高频拒审原因。

---

## 阶段 6 · 灰度、观测与回滚

| 手段 | 操作 | 适用 |
|---|---|---|
| Feature Flag | `docs/feature-flags/` 的 Remote Config 一键关停新功能 | 功能级故障，秒级 |
| Play 分阶段发布 | Console 里 halt 灰度并上传更高 versionCode 的 AAB | 安卓版本级回滚 |
| iOS | 不能直接下架线上版本；移除待审构建，或提交修复版本加速审核 | iOS 版本级回滚 |
| 观测 | Crashlytics / Bugly 崩溃率、ANR、启动耗时；设阈值告警 | 全程 |

---

## 常见失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| CI 报「缺少 android/ 原生壳」 | 未执行/未提交 bootstrap 产物 | 本地跑脚本并 `git add android/ ios/` |
| `flutter gen-l10n` 解析失败 | ARB 不是合法 JSON 或缺 `@@locale` | 本仓库 ARB 已修正，新增 key 勿留尾逗号 |
| `supply` 找不到 AAB | 路径写成原生工程的 `../app/build/...` | Flutter 正确路径：`build/app/outputs/bundle/release/app-release.aab`（已修） |
| iOS archive 签名失败 | Runner 仍是 Automatic signing | Fastfile 已切 Manual；核对 `IOS_PROFILE_NAME` / Team ID |
| PR 构建失败在密钥步骤 | Fork PR 不注入 Secrets | `ci.yml` 已用 `if` 跳过签名，仅验证编译 |
| 上传被拒「version code 已存在」 | build number 未递增 | 用 `github.run_number` 或手动递增 `pubspec version` |
| 商店报「app not found」 | 后台未建应用记录 | 先完成阶段 0 |
| `mobile-release` 整体标红，但 Play 后台已收到 AAB | Android-only 阶段的 `ios` job 若未跳过，会因缺证书失败并拖垮 workflow 状态 | 确认 `ENABLE_IOS` 未设为 `true`；两个 `ios` job 应显示 skipped 而非 failed |
| Windows 报「project path contains non-ASCII characters」，或 `impellerc` 写 shader / Dart AOT 快照器崩溃 | 工程路径含中文，路径编码错乱 | 迁到**全 ASCII 路径**后 `flutter clean` 重建；不要用 `android.overridePathCheck=true` 硬绕过，检查过了编译仍会失败（见 README） |

---

## 环境边界

本机（Windows）已装 Flutter 3.24.5 / Dart 3.5.4 / Temurin JDK 17 / Android SDK，
`bootstrap.sh` 已生成并提交 `android/` 与 `ios/`（含 `.xcodeproj`），
并真实跑通 `flutter analyze`、`flutter test` 与 `flutter build appbundle --release`（18.5MB AAB）。

仍受限的部分：

- Windows 无 Xcode，**iOS 编译、签名、IPA 归档只能在 macOS / `release.yml` 的 `macos-14` runner 上完成**。
- 本机未装 Ruby / Fastlane；`bundle exec fastlane` 需本机补装 Ruby，或直接在 CI 中执行。
- 本机 AAB 默认 **debug 签名**，只能本地验证；正式上架产物必须由 CI 注入 upload key 生成。
- 证书、keystore、服务账号 JSON、商店后台记录与截图仍需人工准备，**未做任何真实提审**。
- 工程路径必须是纯 ASCII（见 README「工程路径」）。
