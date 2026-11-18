# Android 签名与 GitHub Secrets 配置 Runbook

> **适用范围**：当前 Android-only 阶段，从「本地能构建 debug 签名的 AAB」推进到  
> 「`release.yml` 能把 upload key 签名的 AAB 传上 Play 内部轨道」。
>
> **安全边界**：本文件只给命令与步骤，**不含任何真实口令、私钥或 Base64 密文**。  
> 所有敏感值只出现在你本机的交互式输入、GitHub Secrets 或 `.gitignore` 已忽略的本地文件里。  
> 本环境没有你的 Play Console / GitHub 账号权限，以下步骤需你本人在本机与网页控制台执行。
>
> 工程根目录：`D:\workspace\WorkBuddy\appforge-demo`（纯 ASCII，勿迁回中文路径）。  
> 下文 Git Bash 命令一律先执行 `cd /d/workspace/WorkBuddy/appforge-demo`。



---

## 0. 前置检查（1 分钟）

| 项               | 确认方式                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| JDK 17 可用       | `/d/dev/jdk17/bin/keytool -help` 有输出                                                                                |
| 工程能构建           | `flutter build appbundle --release` 已成功（本仓库已验证，18.5MB）                                                              |
| 敏感文件已忽略         | `.gitignore` 已含 `*.jks`、`android/key.properties`、`play-service-account.json`；`git init` 后用 `git check-ignore -v` 复核 |
| Git 仓库          | ⚠ **当前工程目录尚未 `git init`**，首次初始化命令见步骤 7                                                                              |
| Play Console 账号 | 已注册（个人 $25 / 组织账号）                                                                                                  |
| GitHub 仓库       | 已有远程仓库，且有 Settings → Secrets and variables → Actions 的写入权限                                                          |

> 确认当前 AAB 是 **debug 签名**：`jarsigner -verify` 应显示 `CN=Android Debug`。  
> 这个产物只能本地验证，**绝对不要手动上传到 Play**。

---

## 1. 生成 upload keystore

```bash
cd /d/workspace/WorkBuddy/appforge-demo

/d/dev/jdk17/bin/keytool -genkeypair -v \
  -keystore android/app/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload \
  -dname "CN=AppForge Demo, OU=Dev, O=AppForge, L=Shenzhen, ST=Guangdong, C=CN"
```

**故意不传 `-storepass` / `-keypass`**：keytool 会弹交互式提示让你输入口令，  
这样口令不会进入 shell history、也不会出现在进程命令行里（若 Git Bash 下交互输入不生效，  
改用 PowerShell 终端执行同一条命令）。请：

1. 设置一个强口令并**记到密码管理器**（后面要填两个 Secret）。
2. 提示「输入 `<upload>` 的密钥口令」时可直接回车，表示与 keystore 口令相同  
   —— 此时 `ANDROID_KEYSTORE_PASS` 与 `ANDROID_KEY_PASS` 填同一个值。
3. `-alias upload` 必须与 `ANDROID_KEY_ALIAS` 一致，别改。

验证生成结果：

```bash
/d/dev/jdk17/bin/keytool -list -v \
  -keystore android/app/upload-keystore.jks -alias upload
```

### 立刻做离线备份（不可跳过）

**keystore 丢了 = 以后无法再发布更新**。虽然 Play 支持重置 upload key，但流程要账号所有者申请、  
周期长。把这个 `.jks` 和它的口令存到密码管理器 + 至少一份离线加密介质，  
**不要放进仓库、不要放明文云盘、不要发给任何人**。

---

## 2. 转成 Base64（供 Secret 使用）

推荐用 PowerShell 一步生成并直接进剪贴板，全程不落盘：

```powershell
$jks = 'D:\workspace\WorkBuddy\appforge-demo\android\app\upload-keystore.jks'
Set-Clipboard -Value ([Convert]::ToBase64String([IO.File]::ReadAllBytes($jks)))
```

备选（Git Bash，会落一个临时文件，用完即删）：

```bash
base64 -w0 android/app/upload-keystore.jks > ~/keystore.b64
wc -c ~/keystore.b64          # 应为 jks 大小的约 4/3，且是单行
# 粘贴到 GitHub Secret 后立刻：
rm -f ~/keystore.b64
```

> **`-w0` 不能省**：带换行的 Base64 粘进 Secret 后，`base64 -d` 虽常能容错，  
> 但某些情况下会产出截断的 keystore，CI 会报 `Keystore was tampered with, or password was incorrect`，  
> 排查起来非常费时。PowerShell 的 `ToBase64String` 天然无换行。

---

## 3. Play Console：建应用 + 启用 Play App Signing

1. Play Console → **创建应用**，填名称，包名会在首次上传 AAB 时由 `com.appforge.demo` 确定。
2. 进入 **设置 → 应用完整性（App integrity / App signing）**，选择**由 Google 管理应用签名密钥**（默认）。  
   启用后 app signing key 由 Google 保管、不可导出，也**不可撤销**，但已安装用户不受影响。
3. 完成商店信息里的基础项（至少先填隐私政策 URL，正式申请生产权限时是必填项）。

> 🔴 **红线：第一次上传的 AAB 必须是用步骤 1 的 upload key 签名的。**  
> Play 会把首次上传 AAB 的签名证书注册为 upload key。如果误传了 debug 签名的 AAB，  
> `AndroidDebugKey` 就会被永久登记为这个应用的 upload key，后续必须走  
> 「设置 → 应用完整性 → 请求重置上传密钥」才能换回来。  
> 本项目 `release.yml` 已经保证用 `key.properties` 签名，但**不要绕过 CI 手动上传本地 AAB**。

---

## 4. 创建 Play 服务账号 JSON

`release.yml` 用 `fastlane supply` 上传，需要一个有发布权限的服务账号：

1. Play Console → **设置 → API 访问权限（API access）**。
2. 新账号需先创建/关联一个 **Google Cloud 项目**；在该项目里启用  
   **Google Play Developer API**。
3. API access 页 → **创建新的服务账号** → 跳到 Google Cloud Console →  
   创建服务账号时勾选「**提供私钥（JSON）**」→ 下载 JSON。
4. 回到 Play Console 的 API access 页，对刚建的服务账号点 **授予访问权限**，  
   应用权限建议给 **Admin (all permissions)**；若按最小权限，至少要包含  
   「发布到生产环境/测试轨道」「管理商店信息」相关项。
5. 保存后**等 5–10 分钟**再跑流水线，授权传播有延迟。

把 JSON 转 Base64（同样推荐不落盘）：

```powershell
$json = 'C:\Users\87971\Downloads\play-service-account.json'   # 换成你的实际下载路径
Set-Clipboard -Value ([Convert]::ToBase64String([IO.File]::ReadAllBytes($json)))
```

下载的原始 JSON 请放在仓库目录之外。仓库内 `play-service-account.json` 已被 `.gitignore` 忽略。

---

## 5. 填 GitHub Secrets

路径：`Settings → Secrets and variables → Actions → New repository secret`

| Secret                          | 填什么                               | 来源                    |
| ------------------------------- | --------------------------------- | --------------------- |
| `ANDROID_KEYSTORE_B64`          | 步骤 2 的整段 Base64（**单行、无换行、无首尾空格**） | `upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASS`         | keystore 口令                       | 步骤 1 交互输入             |
| `ANDROID_KEY_ALIAS`             | `upload`                          | 步骤 1 的 `-alias`       |
| `ANDROID_KEY_PASS`              | key 口令（回车默认时与上一行同值）               | 步骤 1 交互输入             |
| `PLAY_SERVICE_ACCOUNT_JSON_B64` | 步骤 4 的整段 Base64                   | 服务账号 JSON             |

> 前 4 个由 `ci.yml`（push main / 非 PR）与 `release.yml` 共同使用，缺一个就会在  
> 「Decode signing assets from Secrets」步骤 `exit 1`。第 5 个只有 `release.yml` 用。  
> **iOS 相关的 8 个 Secret 当前阶段不用配**——两个 `ios` job 默认跳过。

核对 Secret 是否生效：push 一次 `main`，在 Actions 日志里应看到  
`Configure upload key (non-PR only)` 通过、`flutter build appbundle --release` 成功，  
且 `ios` job 显示 **skipped** 而不是 failed。

---

## 6. 本地预演：验证签名链路（强烈建议）

在把密钥交给 CI 之前，先在本机用同样的 `key.properties` 机制跑一遍，确认产物证书正确：

```bash
cd /d/workspace/WorkBuddy/appforge-demo

cat > android/key.properties <<'PROPS'
storePassword=<步骤1的 keystore 口令>
keyPassword=<步骤1的 key 口令>
keyAlias=upload
storeFile=upload-keystore.jks
PROPS

flutter clean
flutter build appbundle --release

/d/dev/jdk17/bin/jarsigner -verify -verbose -certs \
  build/app/outputs/bundle/release/app-release.aab 2>&1 | grep -m1 'CN='
# ✅ 期望：CN=AppForge Demo
# ❌ 若仍是 CN=Android Debug：key.properties 未被读取，检查文件名/路径/Gradle 缓存
```

也可以用 `./gradlew :app:signingReport` 直接看 `Config: release / Store: ...upload-keystore.jks / Alias: upload`。

**预演完必须清理**，避免明文口令留在工作区：

```bash
rm -f android/key.properties
# 把 upload-keystore.jks 从 android/app/ 移到步骤 1 的离线备份位置
git status --short        # 确认没有任何 .jks / key.properties 出现在待提交列表
```

> `android/key.properties` 与 `*.jks` 都已被忽略，但 `git status` 这一眼仍值得看——  
> 忽略规则被改动、或文件放错目录时，密钥是会被提交进去的。

---

## 7. 跑流水线

**首次使用：当前工程还没有 `.git`，先初始化并关联远程**（已有仓库则跳过这一段）：

```bash
git init
git branch -M main
git remote add origin <你的 GitHub 仓库 URL>
git config user.name  "<你的 Git 用户名>"
git config user.email "<你的 Git 邮箱>"
git check-ignore -v android/key.properties android/app/upload-keystore.jks play-service-account.json
# 上面三条都应打印出命中的 .gitignore 规则，确认密钥不会被提交
```

之后（每次改动的常规流程）：

```bash
git add . && git commit -m "chore: android-only release setup"
git push -u origin main                   # ① 验证 ci.yml 的 android job（需前 4 个 Secret）

git tag v1.0.0 && git push origin v1.0.0  # ② 触发 release.yml → Play 内部轨道
```

> 首次 `git add .` 会一并纳入 `android/`、`ios/` 原生壳——**这是必须的**，  
> `ci.yml` 有 `Ensure native shells are committed` 显式检查，CI 不会自动 `flutter create`。

预期状态：

| 工作流                     | `verify` | `android`                                   | `ios`     |
| ----------------------- | -------- | ------------------------------------------- | --------- |
| `ci.yml`（PR）            | ✅        | ✅ AAB 为 debug 签名，仅验证                        | ⏭ skipped |
| `ci.yml`（main）          | ✅        | ✅ 用 upload key 签名，存 Artifact                | ⏭ skipped |
| `release.yml`（tag `v*`） | —        | ✅ `fastlane android beta` → Play `internal` | ⏭ skipped |

`release.yml` 也支持在 Actions 页手动运行并选 `play_track`（`internal / alpha / beta / production`）。  
`BUILD_NUMBER` 取 `github.run_number`，会覆盖 `pubspec.yaml` 的 `+1`。

---

## 8. 验收清单与常见坑

打勾后再宣布「Android 链路通了」：

- [ ] `keytool -list` 能看到 `upload` 别名，keystore 与口令已离线备份
- [ ] 5 个 Secret 全部填入，Base64 单行无换行
- [ ] Play Console 已启用 Play App Signing，隐私政策 URL 已填
- [ ] 服务账号已在 API access 页被授予权限，且已等待传播
- [ ] 本地 `jarsigner` 显示 `CN=AppForge Demo`，`git status` 无密钥文件
- [ ] `ci.yml` 的 `ios` job 为 skipped，`release.yml` 整体为绿色
- [ ] Play Console → 测试 → 内部测试 里能看到 `v1.0.0` 的 AAB

| 现象                                                      | 原因                                        | 处理                                                                          |
| ------------------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------- |
| `Keystore was tampered with, or password was incorrect` | Base64 带换行/被截断，或口令填错                      | 用 PowerShell 重新生成单行 Base64；核对两个 PASS Secret                                 |
| `jarsigner` 仍显示 `CN=Android Debug`                      | `android/key.properties` 不存在或没被 Gradle 读到 | 确认文件在 `android/`（不是 `android/app/`），重跑 `flutter clean`                      |
| `supply` 报 403 / `The caller does not have permission`  | 服务账号没在 Play Console 授权，或授权未传播             | 回 API access 页确认权限，等 10 分钟重试                                                |
| `Version code 1 has already been used`                  | `--build-number` 未递增                      | 让 `github.run_number` 自然递增；若仓库迁移导致计数重置，需手动抬高 `pubspec version` 的 `+N`       |
| `mobile-release` 标红但 Play 已收到 AAB                       | `ios` job 没被跳过                            | 确认仓库 Variables 里 `ENABLE_IOS` **未**设为 `true`                                |
| 应用商店信息被拒                                                | 占位符未替换                                    | 替换 `example.com` 隐私/支持链接与 `{{support_email}}`，清单见 `store-listing/README.md` |

---

## 9. 时间与政策风险（个人开发者账号必读）

Google 对 **2023-11-13 之后创建的个人 Play 开发者账号**设有生产发布门槛  
（组织/企业账号豁免，可跳过本节）：

- 必须先在**封闭测试**轨道运行至少 **12 名已选择加入的测试者 × 连续 14 天**；  
  **内部测试轨道不计入**。
- 期间要维持低崩溃率/ANR、隐私政策 URL 已填，并在  
  `设置 → 生产访问权限` 提交问卷说明测试范围、发现的问题与修复。
- 从首次上传到能发生产版，实际通常 **17–23 天**（14 天测试 + 3–7 天审核）。

**对本项目的直接影响**：`release.yml` 默认进 `internal` 轨道，这一步**不受该门槛限制**，  
可以立刻跑通；但想走到 `production` 轨道，个人账号要先完成上面的封闭测试周期。  
建议把 `internal → alpha/beta → production` 的节奏按这个时间线排，别按「打完 tag 就能上线」预期。

---

## 10. 密钥轮换与恢复

| 情况                    | 处理                                                                                                         |
| --------------------- | ---------------------------------------------------------------------------------------------------------- |
| upload keystore 丢失或泄露 | Play Console → 设置 → 应用完整性 → **请求重置上传密钥**；生成新 keypair，导出 PEM 上传证书提交申请。不影响已安装用户，因为 app signing key 仍在 Google |
| 只想换口令                 | 不能直接改已注册 keystore 的口令并沿用；按重置流程走，或新建 keypair 后重置                                                            |
| 误把 debug 签名的 AAB 首次上传 | 同样走「重置上传密钥」，把新 upload certificate 交给 Play                                                                  |
| 恢复 iOS 发布             | 见 README「CI/CD 触发规则」：仓库 Variables 加 `ENABLE_IOS=true`，再按 `RELEASE_PATH.md` 阶段 2/3 补齐 iOS 证书与 Secrets       |

> 完整双端上线总纲见 [RELEASE\_PATH.md](RELEASE_PATH.md)；工程路径与本机工具链见 [../README.md](../README.md)。
