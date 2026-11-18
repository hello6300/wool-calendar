# 本地开发指南（当前工作模式）

> **当前模式：只做本地开发，不发布（2026-11-06 起）**。
> 所有会向商店上传产物的链路默认关闭；签名密钥、Play 服务账号、商店后台记录**都不需要准备**。
> 上线资料完整保留在 [RELEASE_PATH.md](RELEASE_PATH.md) 与 [ANDROID_SIGNING_SETUP.md](ANDROID_SIGNING_SETUP.md)，
> 想恢复发布时看本文最后一节，不需要重搭工程。

---

## 0. 一句话现状

| 能力 | 状态 |
|---|---|
| `flutter analyze` / `flutter test` | ✅ 已验证通过（**70/70**） |
| `flutter build apk --debug` | ✅ 已验证通过（含通知 + 日历 + 同步插件，约 123MB，无需设备、无需密钥） |
| 到点通知提醒 | ✅ **2026-11-13 MuMu 实测**：权限弹窗、渠道创建、立即通知与 1 分钟后定时通知真实弹出；详见第 2.5 节 |
| 从手机日历提取活动 | ✅ **2026-11-14 MuMu 实测**：权限弹窗 → 读到 2 条系统日历活动 → 导入 → 落在日历并排上提醒；详见第 2.6 节 |
| 设备分类（手机 / 平板 / 备用机） | ✅ **2026-11-14 MuMu 实测**：新增设备 → 按设备筛选 / 记一笔 → 全部设备汇总 → 删除设备迁回默认；详见第 2.7 节 |
| 自定义常用平台 | ✅ **2026-11-16 完成**：编辑器内直接增删改 + 独立管理页，删光不回退默认；详见第 2.8 节 |
| WebDAV 多设备同步 | ✅ **2026-11-16 完成**：双向合并（id + updatedAt + 删除墓碑）、密码加密存储、外来文件中止；详见第 2.9 节 |
| 浏览远端文件夹（免猜路径） | ✅ **2026-11-16 MuMu + 真实飞牛 NAS 实测**：根目录只列出 `团队文件-webdav` → 进 `yangmao` → 自动填好路径 → 同步成功；详见第 2.9 节 |
| `flutter build appbundle --release` | ✅ 已验证通过（18.5MB，**debug 签名，仅供本地验证**） |
| 在 MuMu 上安装 / 启动 / 渲染 App | ✅ **2026-11-13 实测通过**（Android 15 / x86_64，首屏「首页 + 计数器 0 + FAB」正常；17:00 UI 微调前的画面） |
| `flutter run` 热重载 | ✅ **2026-11-13 用户本机实测通过**（`Flutter run key commands.`），用 `scripts\run-mumu.ps1`；见第 0.5 / 3 节 |
| CI 质量门禁 `ci.yml` | ✅ 正常跑，不强制任何 Secrets |
| 商店分发 `release.yml` | ⛔ 默认跳过（误打 tag 也不会上传） |
| iOS | ⛔ 默认跳过，文件全部保留 |

---

## 0.5 ⚠ 终端类型（本机必读）

**本机桌面只有 PowerShell，没有独立安装的 Git for Windows / Git Bash。**
`bash` 在 PowerShell 里不是命令（会报「无法将 bash 项识别为 cmdlet、函数、脚本文件或可运行程序的名称」），
`dev-env.sh` / `run-mumu.sh` 只在自动化环境内置的 Bash 会话里可用。

在你自己的终端里请用 PowerShell 版（脚本已实测：

`Connected: 127.0.0.1:16384 | Android 15 (API 35) | x86_64`）：

```powershell
cd D:\workspace\WorkBuddy\appforge-demo
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check   # 只验证连接
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1          # 启动热重载
```

| 需求 | PowerShell（本机默认） | Bash 会话（自动化环境） |
|---|---|---|
| 加载环境 | 重开终端即生效；`run-mumu.ps1` 内也已注入 | `source scripts/dev-env.sh` |
| 连接 MuMu | `powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1` | `bash scripts/run-mumu.sh` |
| 只检查连接 | `-Check` | `--check` |
| 日常门禁 | `flutter analyze` 与 `flutter test` 分两行（PS 5.1 不支持 `&&`） | `flutter analyze && flutter test` |

> PowerShell 默认执行策略禁止运行 `.ps1`，所以必须带 `-ExecutionPolicy Bypass`
> （只对该次调用生效，**不改系统设置**）。也可先在当前窗口执行
> `Set-ExecutionPolicy -Scope Process Bypass -Force`，之后直接 `.\scripts\run-mumu.ps1`。
> 本文后续出现的 `bash scripts/...` 均为 Bash 会话写法，PowerShell 用户按上表替换。
>
> 不想用脚本也可以，纯原生三条命令：
> `adb connect 127.0.0.1:16384` → `adb devices` → `flutter run -d 127.0.0.1:16384 --device-timeout 60`。

---

## 1. 每次打开终端，先加载环境（Bash 会话）

用户级环境变量已经持久化，但**已经打开的终端不会自动刷新**；Git Bash 里 PATH 还必须是 POSIX 形式。
**PowerShell 用户跳过本节**，重开终端即可（或直接用 `run-mumu.ps1`，它内部已注入全部变量）。
Bash 会话统一用工程自带的脚本，一条命令搞定：

```bash
cd /d/workspace/WorkBuddy/appforge-demo
source scripts/dev-env.sh
```

脚本会做 5 件事：注入 `JAVA_HOME` / `ANDROID_HOME` / `PUB_CACHE` / `LOCALAPPDATA`、
把 `/d/dev/...` 加进 PATH、设置 `NO_PROXY`（否则 `flutter test` 的本机 WebSocket 被代理拦截）、
**从当前会话的 `HTTP_PROXY` 动态解析端口**注入 `JAVA_TOOL_OPTIONS`（Java 不读 `HTTP_PROXY`）、
并检查当前路径是否为纯 ASCII。

> 代理端口每次会话都可能变（实测经历过 `14488` → `13936` → `4132`），**千万不要硬编码**。
> 脚本在无代理环境会自动清掉旧的 `JAVA_TOOL_OPTIONS`，避免连到上次会话的死端口。

装在别处时：`export DEV_ROOT=/e/dev && export DEV_WIN=E:/dev` 再 `source`。

> ⚠ **工程路径必须是纯 ASCII**：`D:\workspace\WorkBuddy\appforge-demo`。
> 工作区里的 `软件开发\appforge-demo` 是指向它的目录联接，同一份文件，从哪边打开都行；
> 但命令行请直接用真实路径。原因见 [README 的「工程路径」](../README.md#工程路径windows-必读)。

---

## 2. 日常开发循环（不需要设备、不需要密钥）

```bash
cd /d/workspace/WorkBuddy/appforge-demo && source scripts/dev-env.sh

flutter pub get                 # 改了 pubspec.yaml 后
flutter gen-l10n                # 改了 lib/l10n/*.arb 后
flutter analyze                 # 静态检查
flutter test                    # 单元测试
flutter build apk --debug       # 编译验证，产物 build/app/outputs/flutter-apk/app-debug.apk
```

在 MuMu 上跑（**推荐，一条命令**，自动加载环境 + 探测端口 + 指定设备）：

```powershell
# PowerShell（本机默认终端）
cd D:\workspace\WorkBuddy\appforge-demo
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check   # 只验证连接与设备信息
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1          # 启动热重载
```

```bash
# Bash 会话（自动化环境）
bash scripts/run-mumu.sh --check
bash scripts/run-mumu.sh
```

手动方式（MuMu 同时暴露多个端口别名，必须显式 `-d` 指定，否则会要求选设备）：

```bash
source scripts/dev-env.sh
adb start-server && adb connect 127.0.0.1:16384
flutter run -d 127.0.0.1:16384 --device-timeout 60
# 或只验证已构建的 APK：
adb -s 127.0.0.1:16384 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s 127.0.0.1:16384 shell am start -n com.appforge.demo/.MainActivity
```

代码入口：`lib/main.dart`（初始化通知插件 → 注入 `LocalDealReminder` 与 `DeviceCalendarService`
→ `WoolStore` → 重排提醒 → `CalendarPage`），业务在 `lib/models/` + `lib/data/` +
`lib/state/` + `lib/ui/`，文案在 `lib/l10n/*.arb`，测试在 `test/app_test.dart` 与
`test/wool_test.dart`（42 项，含设备注册表 / 筛选 / 删除迁移 / 矮屏布局）。
设备注册表在 `lib/models/device.dart` + `WoolRepository.devicesKey`，UI 在
`lib/ui/device_settings_page.dart` 与 `device_name_dialog.dart`。改 ARB 后要重跑 `flutter gen-l10n`，
`AppLocalizations` 才会更新；**改 `pubspec.yaml` / `AndroidManifest.xml` / `build.gradle` 后必须
`q` 退出 `flutter run` 重新构建**，热重载不会注册新插件。

---

## 2.5 到点通知提醒（2026-11-13 新增）

### 它怎么工作

| 环节 | 实现 |
|---|---|
| 时间存储 | 日期 `yyyy-MM-dd` 与时间 `HH:mm` **分开存**（`WoolTime`），换时区不让日历错位；结束早于开始 = 次日 |
| 排程 | `LocalDealReminder.sync()`：先取消该记录的两条旧通知，再按开始 / 结束时刻各排一条 `zonedSchedule` |
| 权限 | 首次保存「带时间 + 开提醒」的记录时自动申请 `POST_NOTIFICATIONS`；精确闹钟没授权就降级 `inexactAllowWhileIdle` |
| 自动取消 | 关提醒 / 删记录 / 状态改成已参与·已到账·已过期，`sync` 只取消不排程 |
| 重启重排 | `BOOT_COMPLETED` receiver + 冷启动 `store.syncReminders()` 双保险 |
| 点通知 | payload = `yyyy-MM-dd`，前台回调 `onTap`、冷启动 `getNotificationAppLaunchDetails()` → 跳到那天 |

相关文件：`lib/data/deal_reminder.dart`（抽象 + 文案注入）、
`lib/data/local_deal_reminder.dart`（Android 实现）、`lib/ui/reminder_settings_page.dart`（自检页）。
`WoolStore` 只依赖 `DealReminder` 抽象，所以 `flutter test` 用 Fake 就能测调度时序，不碰原生插件。

### ⚠ 第一次跑必须先重启会话

本次新增了 `flutter_local_notifications` 原生插件 + Manifest 权限 + Gradle desugaring，
**按 `r` 热重载或 `R` 热重启都不够**（插件注册在原生层，会报 `MissingPluginException`）：

```powershell
# 在正在运行的 flutter run 会话里按 q 退出，然后：
cd D:\workspace\WorkBuddy\appforge-demo
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1
```

### MuMu 实测（2026-11-13，Android 15 / API 35）

- 重新 `adb install -r` 后冷启 **2438ms**，`logcat` 无 `FATAL` / `MissingPlugin`；
  日历页右上角新增**铃铛图标**，首屏渲染正常。
- 铃铛页显示：`通知权限 未开启` / `精确闹钟 未开启` / `当前时区 Asia/Shanghai` / `待发提醒 0 条`。
- 点「开启通知权限」→ 系统弹出「要允许 "AppForge Demo" 向您发送通知吗？」→ 允许。
- 点「发一条测试通知」→ 通知栏真实出现「通知已开启 · 现在」；
  `adb shell dumpsys notification --noredact` 可见
  `NotificationRecord(... pkg=com.appforge.demo id=999999 ... channel=wool_reminders ... importance=5)`，
  渠道名「羊毛提醒」。**说明权限 + 渠道 + 立即通知整条链路通了。**
- 「排一条 1 分钟后的提醒」按钮用于验证 `zonedSchedule` 定时链路：点完铃铛页「待发提醒」
  从 0 变 **1 条**，`dumpsys alarm` 出现
  `RTC_WAKEUP origWhen=18:06:30 window=+44s ... com.appforge.demo ... ScheduledNotificationReceiver`；
  **1 分钟后通知栏真实弹出「定时提醒测试成功」**（`dumpsys notification` 中 `id=1000000`）。
  精确闹钟未授权时自动走非精确窗口（实测约 ±1 分钟内触发），仍会弹、可能晚几分钟。

### 自己验证真实记录

新建记录 → 活动日期今天、**开始时间设成 2 分钟后**、到点提醒打开 → 保存；
铃铛页「待发提醒」应 ≥1，到点下拉通知栏应看到「羊毛开始：xxx」，点它回到当天日历。

---

## 2.6 从手机日历提取活动（2026-11-14 新增）

### 它怎么工作

| 环节 | 实现 |
|---|---|
| 入口 | 日历页右上角「日历打勾」图标 → `CalendarImportPage`；默认只**预填**日历页当前显示的整月，不读取 |
| 范围（手动选） | `lib/utils/import_range.dart` 的 `ImportRange`：今天 / 未来 7 天 / 本月 / 未来 30 天四个 chip + 起止日期选择器；含首尾两天、顺序自动纠正、最多 366 天。改范围只清空结果并提示「范围已更改，请重新提取活动」，**绝不自动读取** |
| 权限 | 进页面只 `hasPermissions()` 检查，不弹系统框；权限页「允许读取手机日历」只授权、不读取；点「提取活动」时若未授权会先申请，再接着完成这一次提取 |
| 读取（手动触发） | 唯一入口是「提取活动 / 重新提取 / 重试提取」→ `fetchEvents(from, toExclusive)` → `DeviceCalendarService`：`retrieveCalendars()` 拿到日历 ID → 逐个 `retrieveEvents(id, 用户选定区间)` → 合并排序；结果条显示「本次提取：<范围>」 |
| 时间 | 插件给的是 `TZDateTime`，用绝对毫秒重建 `DateTime` 得到设备本地时间，不依赖 `tz.local` 是否被设过 |
| 映射 | 纯函数 `calendarEventToDeal()`；全天不填时间不排提醒、跨天复用「结束早于开始 = 次日」、跨多日把完整结束时刻写进详情 |
| 去重 | `sourceId = device_calendar:<日历ID>:<事件ID>:<开始毫秒>`；已导入项置灰，`importEvents()` 二次校验 |
| 导入后 | 一次落盘 → 逐条 `reminder.sync()` 排提醒 → 日历跳到第一条活动那天；卡片显示「来自手机日历」 |

相关文件：`lib/data/device_calendar_source.dart`（抽象 + 数据类 + 纯映射 + 链接提取）、
`lib/data/device_calendar_service.dart`（插件实现）、`lib/utils/import_range.dart`（提取范围纯函数）、
`lib/ui/calendar_import_page.dart`（导入页）。
`WoolStore` 通过 `DeviceCalendarSource` 抽象注入，测试用 Fake 覆盖
「进页面不自动读取 / 手动触发 / 改范围清空结果 / 权限 / 勾选 / 导入」全流程。

> ★ 布局约束：800×600 与 MuMu 的 960×540 都是矮屏。顶部设置区放在
> `ConstrainedBox(maxHeight: 屏高 48%)` + `SingleChildScrollView` 里，帮助卡默认折叠、chip 横向滚动，
> **「提取活动」主按钮固定在设置区下方**（不放进滚动区），结果列表用 `Expanded`。
> 早期把按钮放在滚动区里，widget test 实测按钮中心落在裁剪区外（`y=304` 点不到），真机上也会被藏起来。

### ⚠ 两个必须知道的原生坑

1. **插件把 READ + WRITE 绑在一起检查**：`CalendarDelegate.kt` 里 `hasPermissions()` 要求
   `WRITE_CALENDAR && READ_CALENDAR` 同时授予，`requestPermissions()` 也会申请两个。
   所以 Manifest **必须同时声明 `WRITE_CALENDAR`**，否则所有读取 API 都会判定无权限。
   App 代码只读，从不调用 `createOrUpdateEvent` / `deleteEvent`；导入页帮助卡里也向用户说明了这点。
2. **`retrieveEvents` 不接受 `calendarId = null`**：Dart 层 `_validateCalendarIdParameter`
   会直接报 `invalidArguments`。必须先拿日历列表再逐个查，不能「一次读全部」。

另外插件把 `eventURL` 用 `Uri.dataFromString` 包成了 `data:` URI，直接 `toString()` 是乱码；
`resolveCalendarEventUrl()` 只在 scheme 为 http(s) 时采用，否则从描述里正则提取第一条链接。

### ⚠ 第一次跑必须先重启会话

新增了 `device_calendar` 原生插件与 Manifest 权限，`r` / `R` 都不够：

```powershell
cd D:\workspace\WorkBuddy\appforge-demo
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1
```

### MuMu 实测（2026-11-14，Android 15 / API 35）

MuMu 带 `com.android.providers.calendar`，但默认没有任何日历 / 活动。用 adb 造两条测试数据：

```bash
ADB=/d/dev/android-sdk/platform-tools/adb.exe; D=127.0.0.1:16384
$ADB start-server; $ADB connect $D
CAL='content://com.android.calendar/calendars?caller_is_syncadapter=true&account_name=appforge%40local&account_type=LOCAL'
EVT='content://com.android.calendar/events?caller_is_syncadapter=true&account_name=appforge%40local&account_type=LOCAL'
$ADB -s $D shell content insert --uri "'$CAL'" --bind _id:i:1 --bind name:s:appforge_test \
  --bind calendar_displayName:s:AppForgeTest --bind calendar_access_level:i:700 \
  --bind visible:i:1 --bind sync_events:i:1 --bind ownerAccount:s:appforge@local \
  --bind account_name:s:appforge@local --bind account_type:s:LOCAL \
  --bind calendar_timezone:s:Asia/Shanghai
# NOW/S1/E1 用 `adb shell date +%s` 现算毫秒，别手写时间戳
NOW=$($ADB -s $D shell date +%s | tr -d '\r'); S1=$(( (NOW + 600) * 1000 )); E1=$(( (NOW + 2400) * 1000 ))
$ADB -s $D shell content insert --uri "'$EVT'" --bind _id:i:100 --bind calendar_id:i:1 \
  --bind title:s:AppForge_Deal_Test --bind description:s:Coupon_200_minus_30 \
  --bind dtstart:l:$S1 --bind dtend:l:$E1 --bind eventTimezone:s:Asia/Shanghai --bind allDay:i:0
$ADB -s $D shell content query --uri content://com.android.calendar/events \
  --projection _id:title:dtstart:dtend:calendar_id
```

> ★ 三个坑：① 普通身份写 `account_name` 会报 `Only sync adapters may write to account_name`，
> URI 必须带 `?caller_is_syncadapter=true&account_name=...&account_type=...`（**不是** `asSyncAdapter`）；
> ② `--bind` 的值**不要带空格**（会拆成多个参数报 usage），带链接的描述也要写成无空格形式；
> ③ `content insert` 成功时会打印一行 `Segmentation fault`，是 Android `content` 命令自身的退出 bug，
> 用 `content query` 确认写入结果即可，不用管。

实测结果：新 APK 冷启 **2301ms** 无 `FATAL` → 日历打勾图标进入导入页显示「还没有日历读取权限」 →
点「允许读取手机日历」→ 系统弹「要允许 "AppForge Demo" 访问您的日历吗？」→ 允许 →
**列表读出 2 条活动**（`AppForge_Deal_Test 2026-11-14 22:03-22:33 · AppForgeTest`、
`Member_Day_Reminder 2026-11-15 21:52-22:52`）→ 全选 → 「导入选中（2）」→
SnackBar「已导入 2 条，到点会按开始 / 结束时间提醒」、两条都变「已导入」置灰 →
`dumpsys alarm` 出现 `RTC_WAKEUP origWhen=2026-11-14 22:03 / 22:33 ... ScheduledNotificationReceiver` →
返回日历页 14 / 15 号出现圆点、14 号列表显示 `AppForgeTest · 待参与 · 22:03-22:33`、
展开卡片有「来自手机日历 · AppForgeTest」。**读取 → 授权 → 勾选 → 导入 → 落盘 → 排提醒全链路闭环。**

★ **手动流程改造后复测（2026-11-14 22:26）**：这一轮把「进页面自动读整月」改成
「选范围 → 手动点提取 → 勾选导入」。新 APK 冷启 2386ms 无崩溃 → 进页面是空态，列表为空
（确认没有自动读取）→ 点「提取活动」得到 `本次提取：2026-11-01 ~ 11-30` 共 2 个活动 →
点「今天」chip → 范围变 `11-14 ~ 11-14` 共 1 天、结果立即清空、提示「范围已更改，请重新提取活动」、
底部导入按钮禁用 → 再点提取 → 只剩 1 个活动（11-15 那条被过滤），说明范围参数真的传到了
`retrieveEvents` → 点「开始日期」弹出系统日期选择器（标题「开始日期」、2026 年 11 月、14 日选中），
返回键正常关闭。

### 2.6.1 小米 / 红米上「提取活动」读不到东西（2026-11-16 加）

用户实测现象：小米日历里明明有「结婚纪念日」「去【抖音极速版】领30金币预约奖励
12:00-14:00」，App 选 2026-11-01 ~ 11-30 点提取，却显示「这个范围内系统日历没有活动」。

**根因不是用户选错范围，也不是没给权限。** 插件 `device_calendar` 只查
`Instances` 视图（`content://com.android.calendar/instances/when/...`），而部分 ROM
在这个 URI 的实现里会额外按 `Calendars.visible` 等条件过滤，结果就是「日历 App 看得到、
第三方 App 一条都读不到」，而且**不报错**——插件把这种情况吞成 `isSuccess=false`
或空列表，上层只能显示「没有活动」。

现在改成**三级读取**，任意一级拿到数据就返回：

| 级别 | 通道 | 说明 |
| --- | --- | --- |
| 1 | `device_calendar` 插件 | 标准路径，逐个日历查 Instances |
| 2 | 原生 `CalendarProbe.queryInstances` | 同样查 Instances，但不逐个日历回查、不加任何过滤 |
| 3 | 原生 `CalendarProbe.queryEvents` | 直读 **Events 表**，App 自己展开重复规则 |

第 3 级是关键：只要 provider 里还有原始事件行，就算 Instances 被过滤成 0 条也能读出来。
它只在前面几级**一条都没有**时才执行，避免每次提取都扫一张大表。

去重键由 `calendarSourceId()` 统一生成（`device_calendar:<日历>:<事件>:<开始时刻>`），
两条通道读到同一条活动只会导入一次。

### 重复规则的展开只做常见形态

`Events.RRULE` 支持 `FREQ`（DAILY / WEEKLY / MONTHLY / YEARLY）、`INTERVAL`、
`COUNT`、`UNTIL`，以及 `WEEKLY` 的 `BYDAY`。冷门的 `BYMONTHDAY` / `BYSETPOS`
等会被忽略——宁可少几条，也不要因为一条怪规则整体读不出来。展开按 **UTC 日粒度**
推进：中国的用户区无夏令时，所以不会漂。

### 读不到时怎么自查

导入页空态会摊开一张诊断卡（不是只说一句「没有活动」），关键几行：

```
诊断信息                                   [复制诊断信息]
设备：Xiaomi Redmi K30 Pro · Android 31
日历权限：已授予
系统日历 1 个 · 可读实例 0 条 · 原始事件 109 条
其中 109 条带重复规则（每天/每周重复的日程）
本机日程总数 157 条（不分区间）
按日历：calendar_displayname_xiaomi 0 条
读到 1 个日历：calendar_displayname_xiaomi
```

判读方法：

| 现象 | 含义 | 怎么办 |
| --- | --- | --- |
| 权限「未授予」 | 运行时权限没给 | 点授权按钮，或到系统设置里改 |
| 系统日历 0 个 | provider 里没有日历账户，常见于权限被「空白通行证」接管 | 关掉空白通行证 / 改成「始终允许」 |
| **本机日程总数 0** | 整张 Events 表都是空的，一条数据都读不到 | 权限被「返回空数据」接管，或日历还没同步下来 |
| **本机日程总数 > 0，原始事件也有，但区间内就是没有** | 这些日程都不落在所选区间 | 换个范围即可，**不是**手机限制 |
| 按日历里只有某个是 0 | 那个日历不可见或不允许同步 | 到系统日历里把该日历的「显示」打开 |

「复制诊断信息」放在卡片标题行右侧而不是底部——矮屏上卡片内容会超出一屏，
放底部的按钮会被推出视口，用户根本看不到入口。

### 2.6.2 诊断卡的两个真机 bug（2026-11-16 红米 K30 Pro 实测修）

**① 空区间被误报成「手机限制了日历」。** `statsEventRows` 的区间条件和读数据时一致：
重复日程只要 `DTSTART <= to` 就算命中（因为 RRULE 可能一直重复下去）。于是查
2030 年这种空区间时，109 条一年前就开始的重复日程全被算成「原始事件」，而 Instances
又是 0 条 → `instancesFiltered` 成立 → 卡片断言「系统接口读不出来、是手机限制」。
用户按提示去改权限，改到天荒地老也不会好，因为压根没有活动。

修法：诊断多给两个数，判定改用它们。

| 新字段 | 含义 | 来源 |
| --- | --- | --- |
| `tableRowCount` | 整张 Events 表行数（不分区间） | `countAllEvents()`，只看 `deleted=0` |
| `expandedCount` | 直读 Events + 展开重复规则后，区间内真正的实例数 | 复用 `queryEvents()` |

- `instancesFiltered` 必须带 `expandedCount > 0`：能展开出实例才叫「接口被过滤」。
- `noEventsAtAll`：`tableRowCount == 0` → 权限被接管 / 没同步。
- `genuinelyEmpty`：`tableRowCount > 0 && expandedCount == 0` → 区间真的没有。

实测结果：2030-11-01 那张卡从「日历里有事件，但系统接口一条都读不出来」变成
「这台手机的日历里共有 157 条日程，但没有一条落在所选区间内」，和 `content query`
数出来的 157 完全对得上。

**② 日历名被写成资源键。** MIUI 的 `Calendars.calendar_displayName` 存的是
`calendar_displayname_xiaomi` 这种**资源键**，由日历 App 自己翻译。第三方 App 拿到键本身，
于是导入的记录里平台名、`来源：` 详情行全是 `calendar_displayname_xiaomi`。

修法：`displayCalendarName(raw, fallback)`（`lib/data/device_calendar_source.dart`）——
匹配 `^calendar_displayname(_|$)` 一律当「无名字」，退回本地化的「手机日历」。
两条通道（插件 / 原生）在构造 `CalendarEventEntry` 时就清洗，避免列表与落库不一致。
**诊断卡里保留原始键**：那是排查线索，不能为了好看抹掉。

---

## 2.7 设备分类：手机 / 平板 / 备用机（2026-11-14 新增）

### 它解决什么

同一个活动常常「每台设备各领一次」，所以每条记录带一个**设备标签**，日历可按设备筛选、分开统计。
⚠ **设备只是本机分类标签**：`device_calendar` 只能读当前这台设备的 `CalendarContract` / `EventKit`，
App 无法直接访问另一台平板 / 手机的系统日历，也**没有做跨设备云同步**。
若要在多台设备上看同一份账本，需要另接云端（会打破当前「不联网、只本地开发」的边界）。

| 环节 | 实现 |
|---|---|
| 数据 | `lib/models/device.dart`：`Device(id, name, isDefault, autoNamed)`；「本机」那台由原生识别（见 2.7.1），id 通常是 `dev-xxxxxxxx`，**只有读不到设备标识时才退回 `default`**，显示名跟随语言（中文「手机」/ 英文「Phone」） |
| 持久化 | `WoolRepository.devicesKey = 'appforge.devices.v1'`（设备 JSON 数组）+ `thisDeviceKey = 'appforge.this_device.v1'`（本机 id 与机型名缓存）；记录里只存 `WoolDeal.deviceId` 外键，重命名不动历史记录 |
| 兼容 | 旧数据缺 `deviceId` → `_parseDeviceId()` 归到 `default`；存储损坏 / 缺本机设备 → `loadDevices()` 自动补回，任何时刻至少一台设备 |
| 管理 | 日历筛选条右侧齿轮 → `DeviceSettingsPage`：新增（非空 + 不重名校验）/ 重命名 / 删除；编辑器里 `+` 可就地新增并立刻选中 |
| 筛选 | `WoolStore.activeDeviceId`（空串 = 全部）→ `visibleDeals` → `dealsByDay` / `dealsOn` / `dayReward` 全部按设备过滤，日历圆点、列表、「合计 ¥」同步 |
| 默认归属 | `deviceForNew`：当前筛选了某台设备就归它，否则归默认设备；导入页底部「归入设备」下拉可单独指定 `importEvents(deviceId:)` |
| 删除保护 | 本机设备不可删（菜单里就没有删除项）；删其它设备时记录**不删除**，全部 `copyWith(deviceId: thisDeviceId)` 迁回本机，筛选自动回到「全部」，SnackBar 显示迁移条数 |

> ★ 布局约束：设备筛选条是固定 38dp 的单行横向滚动 `Row`，日历行高由
> `_gridRowHeight(bodyHeight, width)` 按 `LayoutBuilder` 剩余高度动态收缩（28~44dp），
> 保证 960×540 矮屏下当日列表仍有约 140dp；`_DayHeader` 用 `Expanded/Flexible + ellipsis`
> 而不是 `Spacer`，320dp 窄屏也不横向溢出。widget test 里必须显式设
> `tester.view.devicePixelRatio = 1.0` 才是 960×540 逻辑尺寸（flutter_test 默认 dpr=3，
> 只设 `physicalSize` 会变成 320×180，测出假溢出）。

### 顺手修掉的两个真实缺陷

1. **编辑器保存会丢来源标记**：`_save()` 重新构造 `WoolDeal` 时没带 `sourceId/sourceName`，
   用户编辑过标题的「手机日历导入」记录会被再次导入。现已原样带回。
2. **设备名对话框 controller 提前释放**：`showDialog` 返回就 `dispose()` 会在退出动画期间抛
   `A TextEditingController was used after being disposed`。现改为 StatefulWidget 持有，随对话框生命周期释放。

### MuMu 实测（2026-11-14，Android 15 / API 35）

新 APK 冷启 2669ms 无崩溃 → 首页出现「全部设备 / 手机」筛选条，上一轮导入的旧记录自动显示「手机」 →
齿轮进「设备管理」→ 添加 `Tablet`（「已保存」）→ 点 Tablet chip：0 条 / 合计 ¥0.00 / 圆点清空 /
空态「「Tablet」这天还没有羊毛」 → 点 `+` 新增 `TabletDeal`，编辑器设备默认已是 Tablet →
保存后卡片 `TestPlatform · Tablet · 待参与` → 切「全部设备」显示 2 条、14 日 2 个圆点 →
设备管理删除 Tablet 并确认 →「已删除设备，1 条记录已移到默认设备」、手机变 3 条记录 →
回日历 `TabletDeal` 仍在且设备名变「手机」 → 导入页底部「归入设备 / 手机」下拉与
「导入选中（0）」正常，无溢出。

### 2.7.1 自动识别本机（2026-11-16 新增）

以前每台手机的「本机」都叫 `default`，装两台手机同步时云端会把它们并成**同一台设备**，
记录归属就分不清了。现在开机就认机：

| 环节 | 实现 |
|---|---|
| 原生 | `android/.../DeviceProbe.kt` + 通道 `appforge/device_info` 的 `identity`，只读 `Build.*` 与 `Settings.Secure.ANDROID_ID`，**不申请任何权限**（不碰 IMEI / 序列号） |
| id | `dev-` + FNV-1a 32 位（`ANDROID_ID`）。同一台手机卸载重装仍是同一个 id；不同手机必不同。远端 JSON 里不出现原始系统标识 |
| 名字 | `Build.MODEL`；纯代号（`M2007J3SC`、`SM-G9910`）前面补厂商名，超过 24 字符截断（设备 chip 是单行） |
| 迁移 | 首次识别把 `default` 那台**就地换 id 换名**（用户改过名则保留自己的叫法、`autoNamed=false`），记录只改 `deviceId`、**不动 `updatedAt`**（这不是内容修改，否则会压过另一台设备上更新的编辑）；给 `default` 留墓碑，防止云端那行又并集回来 |
| 合并 | 锚点 = 列表里 `isDefault` 的那台（`_anchorDevice`）；远端 `default` 设备行与 `default` 记录的 deviceId 全部映射到锚点；合并后只保留一台 `isDefault`（远端的 isDefault 是它自己的本机，不该在本机生效） |
| 兜底 | 通道异常 / 没有 `ANDROID_ID` → 返回 null，`WoolStore` 退回旧的 `default` 行为，不报错、不卡启动；缓存 `appforge.this_device.v1` 让下次冷启动即使读不到也还认得自己 |
| 界面 | 设备管理里本机那台带「本机」徽标、副标题显示「已识别本机：Redmi K30 Pro」；删除项直接不出现 |

> ★ 为什么必须换 id：`mergeSnapshots` 里设备是**按 id 取并集**，id 相同就是同一台。
> 两台手机都用 `default` 时，云端只能保留一份，本机标记与设备名会互相覆盖。
> 换 id 是唯一能把「两台物理手机」表达出来的办法。
>
> ★ 旧版本手机仍在写 `default`：新版本会把它当历史忽略（设备行丢弃、记录改挂锚点），
> 所以云端可能长期留着一行 `default`，属正常，不影响本机。那台旧手机升级后会自己迁移。

> ★ **设备名归谁：`autoNamed` 是唯一的凭据（2026-11-18 修 bug）**。
> `Device.autoNamed = true` 表示「这名字是机型自动起的，可以被新机型名顶掉」；
> `false` 表示「用户起的，谁也不许改」。
>
> - 用户手动改名（`renameDevice`）**必须同时置 `autoNamed=false`**。漏掉这一步会连锁出三个症状：
>   ① 下次冷启动「认本机」认为它还是自动名，又拿 `Build.MODEL` 盖回去 ——
>   表现就是「我改的名字过一会儿/同步后自己变了」；
>   ② 同步合并只把 `autoNamed=false` 当「用户命名」，改名因此传不到另一台设备；
>   ③ 远端那行的标记也一直是 `true`，另一台合并时不会采纳。
> - 存量脏数据靠自愈：`_adoptThisDevice` 不再只看标记，还比对「名字是否等于当前机型名 /
>   上次记下的机型名（`this_device.v1` 的 label）」。两者都不像 → 认定是用户写的，
>   就地置 `autoNamed=false`，从此不再动它。
> - 同步落盘（`applySyncSnapshot`）前补一刀：若本机设备是「用户命名」，名字以内存里最新的为准。
>   同步是「导出快照 → 网络往返 → 落盘」，用户完全可能在网络往返期间改名，
>   而合并结果里的本机那行还是改名前的旧值，直接落盘就把刚改的名字抹了。
>   反方向（本地是自动名、远端是用户命名）不受影响，仍由合并采纳远端名字。

实测（MuMu Android 15，机型 `V2284A` / 厂商 `vivo`，`ANDROID_ID` 已知）：升级后设备栏从
「全部设备 / 手机 / 小米10s」变为「全部设备 / **vivo V2284A** / 小米10s」，原 `默认` 设备里的
1 条记录跟着迁到新 id（首页按本机筛选仍能查到，卡片显示 `手机日历 · vivo V2284A`）；
设备管理显示「已识别本机：vivo V2284A」+「本机」徽标，本机菜单只剩「重命名」；
强杀重启后仍只有三台，没有冒出 `default`「手机」；新增记录「设备」默认就是 `vivo V2284A`。

---

## 2.8 自定义常用平台（2026-11-16 新增）

### 它怎么工作

- 平台列表是**用户数据**：`WoolStore.platforms`，存 `appforge.platforms.v1`（JSON 字符串数组）。
  首次启动时 `main()` 按系统语言传 `defaultPlatforms`（`kDefaultPlatformsZh` / `En`）；
  Repository 里 `null` 表示「从未配置」→ 用默认值，`[]` 表示用户删光 → 保持为空，
  **不会**在重启时又塞回默认平台。
- 编辑器里 chip 直接来自 `store.platforms`，最后固定一个「管理」chip 打开平台管理页；
  列表为空时显示引导文案。
- 增删改只动 chip，**不动历史记录的 `platform` 字段**：把「京东」改名成「京东商城」
  不会批量改旧记录，删除平台也不会删记录。删除确认框里写明了这一点。
- 名称校验：trim、非空、忽略大小写去重；校验在对话框内部完成，失败时不关闭。

### 以后加平台不用改代码

在编辑器点「管理」→「添加平台」即可。默认预置列表在 `lib/data/platform_defaults.dart`，
只有「首次启动」会用到，改它只影响新装用户。

---

## 2.9 WebDAV 多设备同步（2026-11-16 新增）

### 入口：「立即同步」不许藏在列表末尾（2026-11-17 优化）

- 主界面当日记录列表可**下拉即同步**（只在配置过同步时启用），结果用 snackbar
  报四项计数，失败报原因 —— 不进设置页也能同步一次。
- 同步设置页的「立即同步」是**底部常驻操作条**（`bottomNavigationBar`，
  `_SyncActionBar`），全宽单键。以前它排在 4 个输入框 + 2 个开关 + 状态卡之后，
  进页面要一路往下翻才看得见，而这正是九成情况下想按的那个键。
- 键盘弹出时底栏自动收起（`MediaQuery.viewInsets.bottom > 0`），
  否则它会被顶到输入框正上方，把表单挤成一条缝。
- 校验失败时除输入框红字，还会弹 snackbar 并把列表滚回顶部：
  按钮既然固定在底部，红字很可能落在看不见的输入框上。
- 说明卡改成 `ExpansionTile`，已填过地址就默认收起，首屏留给状态卡和输入框。

### 它怎么工作

1. 同步设置页保存 `baseUrl / username / password / remotePath`；密码进
   `flutter_secure_storage`（Android Keystore / EncryptedSharedPreferences），
   其余进 SharedPreferences（`appforge.sync.*`）。
2. 每次同步：`ensureDirectory`（逐级 MKCOL）→ `GET` 远端 JSON → `mergeSnapshots` →
   本地落盘 → `PUT` 合并结果。**先合并再上传**，不会用本机数据覆盖另一台设备。
3. 合并规则（`lib/data/sync_snapshot.dart`，纯函数）：
   - 记录按 `id` 并集；同 id 取 `updatedAt` 较新的一方（旧数据缺该字段回退 `createdAt`）。
   - 删除写墓碑 `{id: 删除时刻}`；墓碑比副本新 → 删除（不被旧副本复活），
     但删除之后的新编辑（`updatedAt` 晚于墓碑）保留。
   - 设备按 id 并集，本机顺序优先、同 id 名字冲突保留本机；
     **但有墓碑的设备一律排除**（见 2.9.4）。
   - 平台列表整份 LWW（`platforms_updated_at`），所以删除平台也能同步出去。
   - 墓碑保留 365 天后清理。
4. 远端文件缺少 `"app": "appforge-wool"` → 抛 `SyncFailure.unrecognized`，**不上传**。

### 必须知道的原生坑

- `flutter_secure_storage` 9.x 要求 **minSdk 23**：`android/app/build.gradle` 已把
  `minSdk` 从 `flutter.minSdkVersion`（21）改成 23。
- 内网 `http://` WebDAV（群晖 / NAS）需要 `android:usesCleartextTraffic="true"`，已开；
  外网建议 https。
- 新增了原生插件 → **必须整包重跑**，`r` / `R` 会 `MissingPluginException`。
- `dio` 的状态码处理：`WebDavTransport._request` 必须在 `Options` 上显式
  `validateStatus: (_) => true`。只靠 `BaseOptions` 时，注入自定义 `Dio`（测试就是这么做的）
  会退回 dio 默认的 2xx 判定，401/404 直接被抛成 `DioException`，映射分支永远走不到。
- 同步失败不改本地数据：合并结果只在 `PUT` 成功后由 `WoolStore.applySyncSnapshot` 落盘；
  失败时设置页显示错误类型（认证 / 权限 / 404 / 网络 / 超时 / 服务器）。

### ⚠ 405 Method Not Allowed 怎么排查（2026-11-16 实测补充）

这是同步最常见的「配置类」报错，**与网络无关**。405 在不同动词上含义完全不同：

| 现象 | 真实原因 | 处理 |
|---|---|---|
| `PROPFIND` 405 | 这个地址不是 WebDAV 端点（填成了网页地址，或漏了 `/dav`） | 看详情末尾的「可用地址」；客户端会自动探 `dav/`、`webdav/` |
| `MKCOL` 405 **且 PROPFIND 说目录不存在** | 服务器**不允许客户端建目录**（飞牛 fnOS 就是这样） | 先在 NAS 的「文件管理」里手动建好目录并给账号读写权限 |
| `MKCOL` 405 且 PROPFIND 200/207 | **正常的**「集合已存在」（RFC 4918） | 代码放过，继续同步 |
| `GET` 405 且 PROPFIND 是集合 | 远端路径指向的是**文件夹** | 路径末尾补文件名，如 `yangmao/wool-sync.json` |
| `GET` 405 且 PROPFIND 404 | 部分服务器用 405 代替 404 | 按首次同步继续，直接 `PUT` |
| `GET` 405 且文件存在 | 服务端禁读 | 中止（不能读就没法合并，硬写会覆盖远端） |
| `PUT` 405 | 没有该目录的写权限 | 换有写权限的目录 |

要点：**不能把 `MKCOL` 的 405 一律当「目录已存在」放过**。飞牛的语义正好相反
（「不许建」也回 405），盲信会导致后面 `PUT` 到一个不存在的目录，再抛一个没头没脑的 405。
现在的做法是 `MKCOL` 405 → 用 `PROPFIND` 确认到底存不存在 → 不存在则明确报
`SyncFailure.mkdirUnsupported`。

错误详情固定带上下文：`<动词> <完整地址> → <状态码> · <服务器原话>`，
例如 `GET https://dav.xxx.fnos.net/yangmao/wool-sync.json → 405 · Method Not Allowed`。

### 飞牛 fnOS 实测结论（2026-11-16）

用户实际地址形如 `https://dav.<设备名>.fnos.net/`：

- `PROPFIND /` 无凭据 → **401 + `WWW-Authenticate: Basic realm="Restricted"`**，
  说明地址本身**是对的**（真 WebDAV 端点），405 不是地址问题；
- 飞牛官方论坛：WebDAV **不允许浏览器直接访问**，会回 `Method Not Allowed`
  （即 GET 目录 = 405），所以「GET 405」在这台机器上是常态；
- 第三方避坑文：飞牛**对客户端自动创建根目录限制较严**，目标目录不存在时
  MKCOL 容易 405；并且**地址必须以 `/` 结尾**（本 App 的 `_normalizeBase` 会自动补）。

结论：飞牛上**必须先手动建目录**，再让 App 往里面写 `wool-sync.json`。

### 各家 WebDAV 的「根」映射不一样（2026-11-16 新增目录浏览）

这是最容易踩的坑：同一个账号，不同服务的**根路径指向完全不同的东西**，
用户按文档猜前缀必然错，而且错了只表现为 404 / 405。

| 服务 | 根目录下实际是什么 |
|---|---|
| 飞牛 fnOS | 团队文件夹挂在 **`/团队文件-dav/`**（中文、带 `-dav` 后缀）下，个人文件是另一套 |
| 坚果云 | 根就是 `/dav/`，里面直接是自己的文件夹 |
| Nextcloud | `/remote.php/dav/files/<用户名>/` 才是个人根 |
| 群晖 | `:5005/` 根下是共享文件夹 |

所以设置页「远端路径」右侧加了 **浏览按钮**（`syncBrowseButton` → `RemoteBrowseDialog`）：
用表单里当前的地址 / 账号 / 密码跑一次 `PROPFIND Depth:1`，把真实目录列出来，点进去、选一个，
自动拼成 `<目录>/wool-sync.json`。**不用猜、不用查文档**，也顺带验证了账号权限。

实现上新增 `SyncTransport.list(path)`（Fake 也实现了，测试用 `tree` 配目录树）：

- 解析 `multistatus` 不引 XML 依赖：正则抓 `<response>` 块 → `<href>` + 是否含 `collection`，
  namespace 前缀写成可选（`D:` / `d:` / `lp1:` 都见过）。
- `href` 可能是绝对路径、完整 URL、相对路径三种写法 → 统一用 `Uri.pathSegments`
  （已做百分号解码，中文目录名可直接显示）后，剥掉 baseUrl 的路径前缀。
- 只返回**直接子项**：跳过目录自身，也跳过更深的层级（Depth:1 不该出现，容错）。
- 文件夹排前面、再按名字排序；文件可显示但不可点进。

同时修掉一个隐蔽缺陷：**部分服务器（飞牛就是）对集合只认带末尾斜杠的地址**，
`PROPFIND /webdav` 会 404，`PROPFIND /webdav/` 才 207。不补这次重试，
已存在的目录会被判成「不存在」，于是错误地抛 `mkdirUnsupported`。
现在 `_propfind` 遇到 404 且地址不带斜杠时，会补斜杠再试一次。

另外 `mkdirUnsupported` 的详情现在会**列出上级目录里实际有什么**：
`MKCOL https://…/webdav → 405 · 目录不存在，服务器不允许自动创建 · 上级目录现有：团队文件-dav/、personal/`
—— 看到这一行，用户立刻就知道前缀该写 `/团队文件-dav/` 而不是 `/webdav/`。

### 本地怎么验

没有网盘也能跑：单测用 `_FakeSyncTransport` 覆盖首次同步 / 双向合并 / 外来文件中止，
WebDAV 客户端用 dio 的 `HttpClientAdapter` 假服务器验证 `MKCOL` / `PUT` / `PROPFIND` 与
401 / 403 / 404 / 405 映射（含「MKCOL 405 但目录不存在」「GET 405 但路径是文件夹」）。
真机验证需要你自己的地址：

- 飞牛 fnOS：`https://dav.<设备名>.fnos.net/`，**先在文件管理里建好目录**；
- 坚果云：`https://dav.jianguoyun.com/dav/`，用「应用密码」而不是登录密码；
- Nextcloud：`https://<host>/remote.php/dav/files/<user>/`；
- 群晖：控制面板 → 文件服务 → WebDAV，地址类似 `http://<nas>:5005/`。

### 2.9.1 同步结果怎么读，以及「云端数据」诊断（2026-11-16 加）

同步页的结果文案必须给**四个数**，少一个都会让人误判：

```
同步完成：云端拉到 0 条 · 上传 1 条 · 更新 0 条 · 删除 1 条
```

- **上传** = 本机有、云端没有 → 这次推上去的条数（原本文案漏了它，
  于是「加一条记录→同步」会显示「新增 0 · 更新 0 · 删除 0」，看起来像没同步）；
- **删除** = 两个方向合起来：`deleted`（云端删了、本机跟着删）+ `remoteDeleted`
  （本机删了、这次上传会把云端那条也删掉）。只算前者时，本机删完同步也会显示 0。
- **拉到 / 更新** = 云端新增到本机的条数 / 两边都改过按 `updatedAt` 取新的条数。

同步页还有一个 **「查看云端数据」**（`Key('syncInspectButton')`）：
`GET` 远端文件后只读地摊开 `N 条记录 · M 台设备 · K 个常用平台 / 生成时间 / 文件大小 /
本机条数 / 前 5 条标题`，**不写入、不建目录**。
它是回答「到底同步上去了没有」最快的方式，比盯着计数猜可靠。
实现：`WoolSyncService.inspect()` → `RemoteInspection`；远端文件不存在返回
`RemoteInspection.missing()`，不是本 App 的文件返回 `recognized = false`（不会谎报成空文件）。

实测闭环（MuMu + 真实 fnOS）：加一条 → 同步显示 `上传 1 条` → 诊断显示云端 3 条 →
删除该条 → 同步显示 `删除 1 条` → 诊断显示云端回到 2 条，与「本机：2 条记录」一致。

### 2.9.2 每日备份：同步前先把云端那份留一份（2026-11-16 加）

同步是「合并结果整份覆盖写回云端」，写坏了就没有回头路，所以每天第一次同步前，
先把**云端当前那份**复制成按日期命名的备份文件：

```
团队文件-webdav/yangmao/wool-sync.json
团队文件-webdav/yangmao/wool-sync-2026-11-16.json   ← 当天首次同步前自动生成
```

要点（都踩过或有明确理由）：

- **备份的是远端，不是本机**：本机数据本来就在本地，真正会被覆盖、也真正会丢的是云端那份。
- **备份文件与原文件同目录**，不建 `backup/` 子目录。飞牛 fnOS 这类服务器不允许客户端
  MKCOL 建目录，一建就 405，备份会天天失败、连带把同步卡死。
- **用 GET + PUT 复制**，不用 WebDAV 的 `COPY`（可选动词，实现未必有）。
- **按本地日历日判断**（`WoolSyncService.needsDailyBackup`），不是按 24 小时；
  同一天第二次同步不再备份。状态记在 `appforge.sync.last_backup_at`，
  备份文件名记在 `appforge.sync.last_backup_path`。
- **备份失败 = 中止本次同步**（`SyncFailure.backupFailed`），宁可不改云端，
  也不能让用户失去「回到昨天」的机会。同步页可以关掉这个开关。
- 状态卡常驻显示「今日已备份：<文件>」；同一天后续同步不再写文件，但这行仍然在
  （只记了时间、没记文件名的旧数据会退化显示为「今日已备份」）。
- 备份会一直累积（一天一个文件，一年 365 个）。**故意不做自动清理**：
  删用户的数据要他自己决定，需要清理时去网盘里删即可。

验证：`WoolSyncService.dailyBackupPath / needsDailyBackup` 纯函数单测 5 条 +
控制器集成测试 4 条（同步前备份 / 同日不重复 / 备份失败中止 / 关掉开关不备份），
共 **82/82**。真机实测：首次同步后网盘里出现 `wool-sync-2026-11-16.json`，
同日再同步不重复生成，重启 App 后提示仍在。

### 2.9.3 备份恢复：从某天的备份回到那天（2026-11-16 加）

入口：同步设置页 →「恢复备份」。三步走，每一步都有明确目的：

1. **选**：`PROPFIND` 一次主文件所在目录，筛出符合命名规则的文件，新的在前。
   这一步只读文件名，**不下载**——备份攒一年几百个文件，逐个 GET 太慢。
2. **预览**：真正 GET 一次选中的备份，解析成快照，把「备份里 N 条 · 本机现在 M 条」
   摊开给用户。不写本机、不写云端。
3. **确认后执行**：读备份 → **先把云端现状另存为恢复前快照** → 最后才覆盖主文件。
   前两步任何一步失败，云端和本机都还是原样。

命名规则（`WoolSyncService.parseBackupName`，只认这两种）：

| 文件 | 来源 | 界面显示 |
| --- | --- | --- |
| `wool-sync-2026-11-16.json` | 每日备份（同步前自动留） | `2026-11-16` / 每日备份 |
| `wool-sync-2026-11-16-1432.json` | 恢复前快照（每次恢复前自动留） | `2026-11-16` / 恢复前快照 14:32 |

主文件自己、`wool-sync-notes.json`、非法日期（2 月 31 日）、别的扩展名都**不算**备份。

要点（几个刻意的选择）：

- **恢复是替换，不是合并**。合并留着墓碑与「较新的副本」，根本回不到那天；
  要的就是「本机数据 = 那份备份」。因此备份之后新增的记录会被清掉——
  确认框里明写「备份里 N 条 · 本机现在 M 条」，让人看得见少了什么。
- **恢复前快照名带时分**，避免和当天那份每日备份撞名。撞名就等于毁掉退路。
- **恢复同时写云端**。只改本机的话，下次同步会把云端较新的那份合并回来，等于白恢复。
- **恢复后清空 `stats`**：状态卡不再挂着上一次的「新增/更新/删除」计数，
  否则看起来像又同步了一次。
- **多设备的固有限制要如实说**：恢复只影响这台设备和云端文件。另一台设备之后
  再同步，它那边 `updatedAt` 更新的记录会再次被合并回来（确认框里已提示）。
- 恢复失败一律提示「本机数据没有改动」——这确实是实现保证（先读、再存快照、最后写）。

验证：`safetyBackupPath / parseBackupName / listBackups / restore` 单测 6 条
（命名不撞名、非法日期、列目录只 PROPFIND 一次、先快照后覆盖、别人的文件中止、
空文件中止）+ 控制器 2 条（替换语义、失败不动本机）+ 界面 1 条（选→确认→本机被替换），
共 **91/91**。真机实测（MuMu + 真实 fnOS）：本机 2 条 → 同步上传 1 条（云端 2 条）→
恢复当日备份（1 条）→ 本机与云端都变成 1 条，RestoreProbe 被清掉 →
备份列表里多出 `恢复前快照 14:58`，点开确认框显示「备份里 2 条」，退路可用。

### 2.9.4 设备删除的墓碑：为什么删了又活（2026-11-16 修）

**现象**：删掉一台设备（比如「平板」），同步一次它又回来了。

**根因**：设备是**按 id 并集**合并的（记录才有 `updatedAt` 冲突解决）。并集的语义就是
「两边有的都留下」，所以本机删掉只是从本地列表消失，云端那份还在 → 下次合并原样并集回来。
平台列表不会这样，因为它走整份 LWW；设备当时没做。

**修法**：给设备也建墓碑，`SyncSnapshot.deviceTombstones`（`{设备 id: 删除时刻}`，
prefs 键 `appforge.device_tombstones.v1`）。合并阶段：

```dart
for (final device in local.devices) {
  if (deviceTombstones.containsKey(device.id)) continue;  // 删掉的，不参与并集
  ...
}
```

要点：

- 设备的墓碑**只看存不存在**，不像记录那样比 `updatedAt`：设备没有 `updatedAt`
  （改名不参与冲突解决），而且 id 是随机生成的，重建不会撞 id，所以「有墓碑即删除」
  就够，也不会出现「删完又想恢复」的正常路径。
- **默认设备 (`default`) 永远不进墓碑**：它是记录归属的最后兜底，
  合并末尾还会 `remove(Device.defaultId)`，防止云端脏数据把默认设备删掉。
- 墓碑同样受 365 天保留期约束（与记录墓碑共用 `cutoff`）。
- **墓碑必须上传**：只清本地列表的话，下一轮同步照旧复活。所以它跟着快照一起 PUT。
- 老云端文件没有 `deviceTombstones` 字段 → 解析成空 map，行为与升级前完全一致。

**连带修的问题：孤儿记录。** 另一台设备删了「平板」，它名下的记录还留在云端；
同步后这些记录带着一个不存在的 `deviceId` 回来，任何设备筛选都点不到它们。
`applySyncSnapshot` 里统一迁回默认设备，并刷新 `updatedAt` 让这次归属变更传回去
（否则下次同步又会被远端旧副本覆盖成孤儿）。

验证：单测 3 条（并集不复活 + 墓碑上传、默认设备不被墓碑误删 + 过期墓碑清理、
老文件无该字段照常解析）+ 端到端 2 条（删设备→同步不复活、孤儿记录迁回）。
另外用**真实 dio + 一个临时最小 WebDAV 服务端**（`HttpServer` 起在 127.0.0.1）
跑了完整往返，实测输出：

```
第一次同步后本机设备: [default, d1794841950110315]
远端 devices: [default, d1794841950110315]    远端 deviceTombstones: {}
删除设备后 → 第二次同步
第二次同步后本机设备: [default]
远端 devices（只剩默认）: [{id: default, ...}]
远端 deviceTombstones: {d1794841950110315: 1794841950211050}
第三次同步：仍是 [default]（幂等）
```

共 **108/108**。

**真机实测（红米 K30 Pro + 真实飞牛 fnOS）**，全程走 App 自己的界面，不碰 SharedPreferences：

| 步骤 | 云端「查看云端数据」 | 本机设备栏 |
| --- | --- | --- |
| 初始 | 0 条记录 · **2 台设备** · 9 个平台 | 全部 / k30pro / 小米10s |
| 添加临时设备 TP → 立即同步 | 0 条记录 · **3 台设备** · 687 B | 多了 TP |
| 删除 TP → 立即同步 | 0 条记录 · **2 台设备** · 666 B | 只剩 k30pro / 小米10s |
| 再同步一次 | 仍 **2 台设备**（幂等） | TP 没有回来 |

注意「记录 0 条 / 上传 0 条」是正常的：那四项统计只算记录，设备增删不计数。
副作用：云端 `deviceTombstones` 里会留下 `TP` 的墓碑（约 40 字节），365 天后自动清理。

---

## 2.10 应用名与图标（2026-11-17 改名「羊毛日历」）

以前桌面名是模板自带的 `AppForge Demo`（`android:label` 硬编码），现在统一成品牌名。

| 位置 | 文件 | 说明 |
|---|---|---|
| 桌面名 | `android/app/src/main/res/values/strings.xml` → `@string/app_name` | 默认 `羊毛日历`；`values-en/strings.xml` 覆盖成 `Wool Calendar`，英文系统显示英文 |
| 应用内标题 | `lib/l10n/intl_zh.arb` 的 `appName` / `woolCalendarTitle` | 已经是「羊毛日历」，改回品牌名时保持两者一致；英文同步改成 `Wool Calendar` |
| 任务切换器 | `appName`（`main.dart` 的 `onGenerateTitle`） | 与桌面名同源 |
| iOS | `ios/Runner/Info.plist` 的 `CFBundleDisplayName` | 不构建 iOS，仅为一致性同步 |
| 图标 | `tools/make_icon.py` 一键生成 | 见下 |

### 2.10.1 图标：一只羊

主视觉就是**正面羊头**：白色羊毛团（大圆 + 11 个小圆做扇形波浪边）+ 米色脸 + 两点眼睛 + 一条微笑弧，
衬暖橙对角渐变（`#FFB04A → #F45A20`）。选羊头而不是「日历 + 羊」的复合构图，是因为 48dp 下
两个元素必然糊在一起，而羊头本身在小尺寸下就能一眼认出。

```bash
python tools/make_icon.py            # 生成 android res + design/branding 全部素材
python tools/make_icon.py --preview  # 额外出 .tmp/logo/preview-sizes.png（48/72/96/144 对照）
```

产物：

| 文件 | 用途 |
|---|---|
| `res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48/72/96/144/192，预 Android 8.0 的图标 |
| 同目录 `ic_launcher_round.png` | 声明了 `android:roundIcon` 的桌面用圆形版 |
| 同目录 `ic_launcher_foreground.png` | 自适应图标前景，108dp 画布（108/162/216/324/432） |
| `res/mipmap-anydpi-v26/ic_launcher{,_round}.xml` | 自适应图标：渐变背景 + 前景 |
| `res/drawable/ic_launcher_background.xml` | 渐变背景（`angle=315` 左上→右下，与位图方向一致） |
| `design/branding/icon-1024.png` | 圆角方图，分享 / 商店用 |
| `design/branding/logo-lockup{,-dark}.png` | 横版组合标志：图标 + 「羊毛日历」字标 |
| `design/branding/logo.svg` | 矢量稿，坐标与位图同源 |

> ★ **主视觉比例有两套，别混用**：品牌图用 `ICON_SCALE=0.96`（饱满好看），桌面图标用
> `LAUNCHER_SCALE=0.68`。自适应图标是 108dp 画布，桌面只保证显示中间 72dp，换算到 1024
> 画布可见区只有 683px。第一版按 0.80 出图，装机后小米的圆角遮罩直接把两只耳朵切掉了——
> 量尺寸要按**可见区**量，不是按画布量。0.68 时含耳朵约 533px，占可见区 78%，正合适。
>
> ★ 所有几何都写 1024 逻辑坐标 + 4 倍超采样再缩小：48px 时眼睛只有约 2px，先画 4096 再缩
> 才有干净的边。五官也据此放大过一档（眼睛 rx 24/ry 27、嘴宽 13），否则小尺寸下只剩白团。
>
> ★ 渐变不能用「竖直渐变旋转 45° 再裁方形」——旋转后四角是黑的（裁到方框外了）。
> 现在是在 64×64 小图上按 `(x+y)` 逐点算插值再双三次放大，既平滑又便宜。

验证：真机（红米 K30 Pro / MIUI 14）桌面显示橙色方圆图标 + 「羊毛日历」，耳朵完整、留白均匀；
MuMu（Android 15）同样正常；`aapt dump badging` 显示 `application-label:'羊毛日历'`、
`application-label-en:'Wool Calendar'`；`logo.svg` 用无头 Edge 渲染与位图一致。

---

## 3. 设备：网易 MuMu 已装并实测跑通（2026-11-13）

### 实测结果

| 项 | 实测值 |
|---|---|
| 版本 / 位置 | MuMu模拟器 `6.8.14.0`，`D:\Program Files\Netease\MuMu` |
| 虚拟化 | `MuMuNxVbox`（VirtualBox 系），**不依赖 Hyper-V / WHPX** |
| 系统 | **Android 15 / API 35**，机型 vivo V2284A (PD2284) |
| ABI | **x86_64** —— 命中工程自带的 `lib/x86_64/libflutter.so`，无需 ARM 翻译 |
| adb 端口 | **同时监听 5555 / 7555 / 16384**（进程 `MuMuNxDevice`），三者是同一台设备的别名 |
| 推荐连接 | `127.0.0.1:16384`，用 `bash scripts/run-mumu.sh` 自动探测 |

安装 → `am start -W` 冷启 **2332ms** → 前台 Activity `com.appforge.demo/.MainActivity` →
截屏确认首屏「首页 / 计数器 0 / + FAB」正常渲染（**17:00 UI 微调前的画面**），
**无白屏、无崩溃日志**，中文 i18n 生效。

> ★ **实机验证抓到一个 CI 编译发现不了的缺陷（已修）**：`MainActivity.kt` 的 package 曾是模板值
> `com.appforge.appforge_demo`，而 `namespace/applicationId` 已改成 `com.appforge.demo`，
> Manifest 里 `.MainActivity` 按 namespace 解析就会 `ClassNotFoundException`，装得上但一启动就崩。
> 现已统一 package、把源码目录移到 `kotlin/com/appforge/demo/`、应用名改为 `AppForge Demo`，
> 并在 `scripts/bootstrap.sh` 增加「所有 Kotlin package 必须等于 applicationId」的自检防回归。
> **教训：`flutter analyze` / `flutter build` 全绿不等于能启动，必须至少装一次真机/模拟器。**

### 其他方案（选型回顾，备查）

| 方案 | 本机可行性 | 关键门槛 | adb 端口 |
|---|---|---|---|
| **网易 MuMu（已采用）** | ✅ 已跑通 | 装 exe，BIOS 虚拟化已开 | 5555 / 7555 / 16384 |
| 雷电 / 夜神 / 逍遥 / BlueStacks | ✅ 同类可用 | 注意 adb 版本冲突 | 5555 / 62001·62026 / 21503 / 5555 |
| 安卓真机 | ✅ 最稳 | 手机 + 数据线 | USB |
| Android Studio 官方 AVD | ⚠ 可行但麻烦 | WHPX/Hyper-V（管理员）+ 3–5GB 镜像 | 5554… |
| Windows 桌面端 | ❌ 本机不行 | 缺 VS 2022 C++ 工作负载 | — |
| WSA | ❌ 已停用 | 微软 2025-03-05 终止支持并下架 | — |

> 为什么第三方模拟器能跑这个工程：`app-debug.apk` 内含 `x86` / `x86_64` / `arm64-v8a` / `armeabi-v7a`
> 四套 `libflutter.so`；Flutter 3.24 默认 `minSdkVersion=21`；`compileSdk=34` 只影响编译期，
> 与模拟器系统版本无关（旧教程说要下载对应 API 镜像，已过时）。
> 本机无 Visual Studio，CPU 为 AMD Ryzen 7 7840HS + 780M 核显，BIOS 虚拟化已开。

### 方案 A：插一台安卓真机（最稳，零安装）

1. 手机「设置 → 关于手机」连点版本号 7 次开启开发者选项；
2. 开发者选项里打开 **USB 调试**；
3. 数据线连接，手机上同意「允许 USB 调试」；
4. `adb devices` 出现 `xxxxxx device` → `flutter run`。

> `flutter devices` 里的 `reg.EXE` 报错是自动化沙箱的程序黑名单拦截，只影响探测 Edge 版本，
> 你自己的终端不会出现，也不影响 Android 构建。

### 方案 B：网易 MuMu 模拟器（已采用）

**日常一条命令**（自动加载环境、探测端口、显式指定设备）：

```powershell
cd D:\workspace\WorkBuddy\appforge-demo
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check   # 只验证连接：应输出 Android 15 (API 35) | x86_64
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1          # 启动 flutter run：r 热重载 / R 热重启 / q 退出
```

脚本只调用本机 SDK 的 adb，按 `16384 → 7555 → 5555` 顺序取第一个 `device` 状态的端口。
手动等价流程：

```bash
cd /d/workspace/WorkBuddy/appforge-demo && source scripts/dev-env.sh
adb start-server
adb connect 127.0.0.1:16384
adb devices -l                       # 出现 127.0.0.1:16384  device 即成功
flutter run -d 127.0.0.1:16384 --device-timeout 60
```

只验证已构建的 APK（不启动热重载会话）：

```bash
adb -s 127.0.0.1:16384 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s 127.0.0.1:16384 shell am start -W -n com.appforge.demo/.MainActivity
adb -s 127.0.0.1:16384 exec-out screencap -p > /tmp/mumu.png   # 看首屏是否白屏
```

> ✅ **热重载已实测通过（2026-11-13，用户本机 PowerShell）**：执行 `run-mumu.ps1` 后输出
> `Running Gradle task 'assembleDebug'... 33.2s` → `√ Built ...app-debug.apk` →
> `Installing ... 2,200ms` → `Syncing files to device V2284A... 99ms` →
> **`Flutter run key commands.`**，并给出 Dart VM Service（`127.0.0.1:5026`）与
> DevTools（`127.0.0.1:9100`）地址。
> 随后按 `r` 实测：`Reloaded 4 of 839 libraries in 578ms (compile: 57 ms, reload: 146 ms,
> reassemble: 108 ms)` —— **增量编译与热重载真正生效**，不只是会话建立。
> 至此「环境 → 构建 → 设备 → 热重载」全链路闭环。
>
> **自动化沙箱的边界（仅我这侧）**：`reg.EXE` 黑名单会拦截 Flutter 在 Windows 探测 Edge 的调用，
> `flutter devices` / `flutter run` 在自动化会话里提前退出（安全策略不允许绕过）。
> 用户自己的 PowerShell 终端无此拦截，已完整跑通；若你的终端也报 `reg.EXE`，是本机安全软件策略，
> 与工程无关。

**启动时的两行红字不用管**（首次 debug 构建常见，后面 `√ Built` 正常）：

| 红字 | 来源 | 处理 |
|---|---|---|
| `Warning: SDK processing. This version only understands SDK XML versions up to 3 but an SDK XML file version 4 was encountered` | 本机 `cmdline-tools 23.0` / `platform-tools 37.0.1`（2026 版，写 `repository2/04` schema）与 Flutter 3.24.5 模板的 **AGP 8.1.0**（只认到 version 3）版本差 | **忽略**。AGP 仍能解析 SDK 且构建成功；升级 AGP 风险远大于收益，降级 cmdline-tools 也没必要 |
| `Flutter assets will be downloaded from https://storage.flutter-io.cn. Make sure you trust this source!` | `FLUTTER_STORAGE_BASE_URL` 指向国内镜像（当初为避开 Google 源限速而配） | 正常提示，不是错误 |

日志里的 `D/gralloc_kona ... Creating ashmem region`、`I/TimeTracker: onCancelled`、
`W/System: A resource failed to call close.` 都是 MuMu / Android 系统层常规输出，
**没有** `E/Flutter` 或 `FATAL EXCEPTION`，与 App 无关。

**六个必须注意的坑**：

1. **★ 只用本机 SDK 的 adb，别用 MuMu 安装目录里的 `adb_server.exe` / `adb.exe`。**
   MuMu 自带 adb 版本与本机 platform-tools 37.0.1 不同，会另起一个 server 抢 `5037` 端口，
   结果 `flutter run` 用的那个 adb 看不到设备。若已经跑过 MuMu 自带的 adb：
   `adb kill-server && adb connect 127.0.0.1:16384` 统一到本机 adb。
2. **网络 adb 是 TCP 连接**，模拟器每次重启都要重新 `adb connect`；设备发现比 USB 慢，
   用 `--device-timeout 60`，别一看到 "No devices" 就以为失败。
3. **白屏 / GPU 报错**：Flutter 3.24.5 **已移除** `--enable-software-rendering`
   （本机 `flutter run --help` 实测无此参数），老教程里那条命令会直接报未知参数。
   改在 MuMu「设置 → 显示/性能」里切换渲染模式（OpenGL / DirectX / Vulkan）或开兼容模式。
4. **GMS 不完整**：本 demo 不依赖 Google Play 服务，无所谓；但以后接 Firebase、Google 登录、
   FCM 推送时，第三方模拟器的 GMS 可能不全，那时得换官方 AVD 或真机。
5. **★ 同一台模拟器会出现多个设备名**（`127.0.0.1:16384` / `7555` / `5555`，
   adb server 还会自动发现 `emulator-5554`）。不指定 `-d` 时 `flutter run` 会要求选设备甚至重复安装。
   `scripts/run-mumu.sh` 已处理；手动执行务必带 `-d`。
6. **adb server 不跨命令常驻**（自动化沙箱会在命令结束后回收 daemon）：连接与后续操作要放在
   同一条命令里，或直接用 `scripts/run-mumu.sh`。你自己的终端通常不会有这个现象。

同类产品（端口不同，其余步骤一致）：雷电 LDPlayer、夜神 Nox、逍遥 MEmu、BlueStacks。
它们与 MuMu 一样面向手游，做 Flutter 调试够用，但都不是 Google 官方镜像，
不要拿它们做「上架前兼容性验收」的结论。

### 方案 C：Android Studio 官方 AVD（最标准，但本机门槛高）

```bash
source scripts/dev-env.sh
sdkmanager "emulator" "system-images;android-34;google_apis;x86_64"   # 斜杠包名，分号会被 Git Bash 拆
avdmanager create avd -n appforge -k "system-images;android-34;google_apis;x86_64" -d pixel_5
flutter emulators --launch appforge
flutter run
```

前置：启用 **Windows Hypervisor Platform / Hyper-V**（需管理员、重启）、3–5GB 镜像下载。
AMD 平台上这一步 historically 比第三方模拟器麻烦，这正是本机优先推荐 MuMu 的原因。

### 方案 D：Windows 桌面端（本机不可用）

`flutter config --enable-windows-desktop && flutter create --platforms=windows . && flutter run -d windows`
需要 Visual Studio 2022 +「使用 C++ 的桌面开发」，本机未检测到。`windows/` 只是预览壳，不建议提交。

### 零安装补充：只想看 UI + 热重载，可以先跑 Web

不需要模拟器、不需要 VS、不需要 Hyper-V，只要 Chrome/Edge：

```bash
flutter create --platforms=web .
flutter run -d chrome      # 同样支持 r 热重载
```

本 demo 的 `provider` / `shared_preferences` / `dio` / `flutter_localizations` 都支持 Web。
代价是 Web 端不等于 Android 真机（无原生权限、通知、相机等），只能用来调 UI 和业务逻辑。

> **推荐顺序**：想立刻看 UI → Web；要验证 Android 行为又不想装东西 → 真机；
> 两者都没有 → **装 MuMu**，按方案 B 连 adb。
> 上述方案我没有擅自执行：安装模拟器、改系统虚拟化设置、启用 Windows 平台都需要你确认。
> 告诉我选哪个，我再按实际环境装并验证到 `flutter run` 成功。

---

## 4. 发布链路现在是什么状态

用一个仓库变量 `ENABLE_RELEASE` 统一控制，默认（未设置）= 关闭：

| 位置 | 行为 | 默认 |
|---|---|---|
| `ci.yml` → `Configure upload key` | 开启时才从 Secrets 生成 `key.properties` 并强制校验 4 个签名 Secrets | 跳过，**不要求任何 Secret** |
| `ci.yml` → `Build release AAB` | 照常构建，产物存 Artifact | ✅ 执行（debug 签名） |
| `release.yml` → `android` | 上传 Play 测试轨道 | ⛔ 整个 job 跳过 |
| `release.yml` → `ios` | 上传 TestFlight | ⛔ 整个 job 跳过（双重开关） |
| `ci.yml` / `release.yml` 的 `ios` job | 另由 `ENABLE_IOS` 控制 | ⛔ 跳过 |

也就是说：**打 `v1.0.0` tag 或手动触发 release workflow 都不会上传任何东西**，
`push main` 也不会因为没配密钥而变红。本地构建的 AAB 是 debug 签名，
只用于验证工具链，本来就不能上传 Play。

---

## 5. 常见坑速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Your project path contains non-ASCII characters` | 用了含中文的路径 | `cd /d/workspace/WorkBuddy/appforge-demo`；**不要**用 `android.overridePathCheck=true` 硬绕 |
| `impellerc` 写 shader 失败 / `exit -1073740791` | 同上，中文被解成 `软件?发` | 换纯 ASCII 路径后 `flutter clean` 重建 |
| `Unable to connect to flutter_tester ... WebSocket` | 代理拦截本机回环 | `NO_PROXY=localhost,127.0.0.1,::1`（dev-env.sh 已设） |
| Gradle `Connection refused` / `Could not resolve io.flutter:*_debug` | `JAVA_TOOL_OPTIONS` 里是上次会话的旧代理端口 | Bash：`source scripts/dev-env.sh`；PowerShell：重开终端或跑 `run-mumu.ps1`（自动重新解析）。**不要硬编码端口** |
| `No cached version available for offline mode` | 首次构建依赖未下载完 | 联网跑一次 `flutter build apk --debug`；用户级 `~/.gradle/init.gradle` 已配阿里云镜像 |
| `Null check operator used on a null value`（flutter test） | 沙箱缺 `LOCALAPPDATA` / `PUB_CACHE` | dev-env.sh 已显式设置 |
| `Package platforms not found` | 2026 版 sdkmanager 用斜杠包名，分号被 Git Bash 拆开 | 用 `"platforms/android-34"`、`"build-tools/34.0.0"` |
| 本地 AAB 显示 `CN=Android Debug` | 没有 `android/key.properties` | 正常，本地开发阶段无需处理 |
| `adb connect` 成功但 `flutter devices` 仍为空 | 跑过模拟器自带的 `adb_server.exe`，两个 adb server 抢 5037，版本还不一致 | `adb kill-server` 后**只用本机 SDK 的 adb** 重连 |
| 第三方模拟器上 "No supported devices found" | 网络 adb 设备发现慢于 USB | `flutter run -d <ip:port> --device-timeout 60` |
| 模拟器里 App 白屏 / Skia GL 报错 | 虚拟显卡与 Skia GLES 不兼容 | 切 MuMu 渲染模式（OpenGL/DirectX/Vulkan）；**Flutter 3.24.5 已无** `--enable-software-rendering`，老教程会报未知参数 |
| 提示要给模拟器下载对应 API 镜像 | 旧版 Flutter 教程的遗留说法 | 本项目 `compileSdk=34` 用本地 `android-34` 编译即可，与模拟器系统版本无关 |
| **APK 装得上，一启动就崩：`ClassNotFoundException: ...MainActivity`** | Kotlin `package` 与 `namespace/applicationId` 不一致；Manifest 的 `.MainActivity` 按 namespace 解析 | 已于 2026-11-13 修复：`MainActivity.kt` 改为 `package com.appforge.demo` 并移到 `kotlin/com/appforge/demo/`；`bootstrap.sh` 已加自检。**编译/build 全绿发现不了这个错，必须实机启动一次** |
| `flutter devices` / `flutter run` 报 `reg.EXE` 相关错误 | Flutter 在 Windows 探测 Edge 版本，被本机安全软件/沙箱黑名单拦截 | 与工程无关；换自己的终端，或在安全中心把 `reg.EXE` 移出黑名单 |
| PowerShell 里报「无法将 `bash` 项识别为 cmdlet…」 | 本机没有独立 Git Bash，`.sh` 只在自动化环境的 Bash 会话可用 | 改用 `powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1`，见第 0.5 节 |
| 「无法加载文件 run-mumu.ps1，因为在此系统上禁止运行脚本」 | PowerShell 默认 ExecutionPolicy 禁止 `.ps1` | 调用时加 `-ExecutionPolicy Bypass`（仅本次生效），或先 `Set-ExecutionPolicy -Scope Process Bypass -Force` |
| PowerShell 5.1 里 `flutter analyze && flutter test` 报语法错 | PS 5.1 不支持 `&&` | 分两行写，或用 `;` |
| 红字 `SDK XML versions up to 3 but ... version 4 was encountered` | `cmdline-tools 23.0` / `platform-tools 37.0.1` 比 AGP 8.1.0 新，schema 不认 | **忽略**，构建照常成功；详见第 3 节的两行红字说明 |
| 红字 `Flutter assets will be downloaded from https://storage.flutter-io.cn` | 配了国内镜像 `FLUTTER_STORAGE_BASE_URL` | 正常提示，不是错误 |
| `adb connect` 成功但下一条命令就 `device not found` | 沙箱在命令结束后回收 adb daemon | 连接与使用放在同一条命令内，或用 `run-mumu.ps1` / `run-mumu.sh` |
| 加了通知插件后按 `r` 热重载，调用通知报 `MissingPluginException` | 原生插件注册在构建期（`GeneratedPluginRegistrant`），热重载 / 热重启不会重新生成 | `q` 退出 → `flutter pub get` → 重新 `flutter run`（或重跑 `run-mumu.ps1`） |
| Android 13+ 到点不弹通知 | `POST_NOTIFICATIONS` 没申请或被拒 | 铃铛页看「通知权限」，点「开启通知权限」；仍不行去系统设置里给 App 开通知 |
| 提醒晚了几分钟才弹 | Android 14+ 精确闹钟默认不授权，代码自动降级 `inexactAllowWhileIdle`（会有触发窗口） | 铃铛页点「去系统设置开启精确闹钟」；测 1 分钟提醒时保持亮屏，别让模拟器息屏 |
| 铃铛页「待发提醒」是 0、到点也不弹 | 没填任何时间 / 关了提醒 / 状态是已参与·已到账·已过期 / 目标时刻已过去 | 补齐开始或结束时间、打开「到点提醒」、保持「待参与」；设置页看「最近一次提醒错误」 |
| 改了日期 / 时间后旧时刻还在弹 | 每条记录用固定通知 id，编辑会先 cancel 再重排；强杀进程可能打断重排 | 铃铛页点「重新同步全部提醒」，或重启 App（冷启动会自动重排全部未来提醒） |
| 时区显示不是本地 / 夏令时错 | `flutter_timezone` 返回非 IANA 名字时回退 `Asia/Shanghai` | 铃铛页「当前时区」可核对；国内环境实测 `Asia/Shanghai` 正常 |
| 导入页一直显示「还没有日历读取权限」 | `device_calendar` 的 `hasPermissions()` 要求 READ + WRITE 同时授予，Manifest 只声明 READ 会永远返回 false | Manifest 已同时声明 `WRITE_CALENDAR`；App 仍只读，不调用任何写入 API，详见第 2.6 节 |
| 导入页读到 0 个活动 | 模拟器 / 新手机的系统日历本来就是空的，或选的提取范围不对 | 在「提取范围」换个预设或自定义起止日，再点「提取活动」；MuMu 上按第 2.6 节用 `content insert` 造测试数据 |
| `content insert` 报 `Only sync adapters may write to account_name` | CalendarProvider 拒绝普通身份写账户字段 | URI 加 `?caller_is_syncadapter=true&account_name=...&account_type=...`（**不是** `asSyncAdapter`） |
| `content insert` 报 usage，或成功后打印 `Segmentation fault` | `--bind` 值带空格会被拆成多个参数；segfault 是 Android `content` 命令自身的退出 bug | 值里不要带空格；用 `content query` 核对写入结果，忽略那行 segfault |
| 导入的活动没有到点提醒 | 全天活动不排提醒；或活动的开始 / 结束时刻已经过去 | 导入页副标题可看时间；过去的时刻 `sync()` 会跳过，属预期 |
| 设备名对话框关闭时抛 `A TextEditingController was used after being disposed` | `showDialog` 一返回就 `dispose()`，但退出动画期间 `TextFormField` 还在树里 | 用 StatefulWidget 持有 controller，在 `State.dispose()` 里释放（见 `device_name_dialog.dart`） |
| widget test 里日历在「960×540」离奇溢出 270px | 只设了 `tester.view.physicalSize`，flutter_test 默认 `devicePixelRatio=3` → 逻辑尺寸其实是 320×180 | 同时设 `tester.view.devicePixelRatio = 1.0`，并在 `addTearDown` 里 reset 两个值 |
| 设备筛选后日历格子圆点处溢出 1~2px | 自适应行高收到 ~28dp 时，日期文字 + 间距 + 圆点超过格子高度 | `_DayCell` 间距改 2dp、圆点容器 5dp；`_gridRowHeight` 下限 28dp |
| 加 `flutter_secure_storage` 后构建报 `minSdkVersion 21 cannot be smaller than version 23` | 插件 9.x 用 EncryptedSharedPreferences，要求 API 23 | `android/app/build.gradle` 已写 `minSdk = 23`（覆盖 Android 6.0+） |
| 同步按钮总是报网络错误，401 / 404 分不出来 | 注入自定义 `Dio` 后 `Options.validateStatus` 没设，状态码被 dio 先抛成 `DioException` | `_request` 已显式 `validateStatus: (_) => true`，交给 `_statusFailure` 映射 |
| WebDAV 连内网 `http://` 一直失败 | Android 9+ 默认禁止明文流量 | Manifest 已加 `android:usesCleartextTraffic="true"`；外网请用 https |
| 同步报 405（飞牛 fnOS 常见） | NAS 侧：目录不存在时不允许客户端 MKCOL，GET 目录也回 405 | 先在 NAS「文件管理」建好目录并授权，远端路径填 `目录/wool-sync.json`；新版本会明确报「目录不存在，服务器不允许自动创建」 |
| 同步后另一台设备删掉的记录又回来了 | 远端是旧副本，且墓碑丢失 / 超过 365 天保留期 | 确认两端都是带墓碑的版本，再同步一次；墓碑在 `appforge.tombstones.v1` |
| 同步提示「远端文件不是本 App 的同步文件」 | 远端路径指到了别的文件（缺 `app: appforge-wool` 标记） | 换一个空路径或确认文件名；App 绝不覆盖别人的文件 |

---

## 6. 以后想恢复发布

不需要改代码，只要两步：

1. 按 [ANDROID_SIGNING_SETUP.md](ANDROID_SIGNING_SETUP.md) 生成 upload keystore、开通 Play App Signing、
   建服务账号，并配齐 5 个 Secrets；
2. 仓库 `Settings → Secrets and variables → Actions → Variables` 新增 `ENABLE_RELEASE=true`。

`ci.yml` 会重新开始用 upload key 签名，`release.yml` 的 `android` job 恢复上传 Play 内部轨道。
iOS 还需额外设 `ENABLE_IOS=true` 并补齐 Match / ASC 证书 Secrets（见 [RELEASE_PATH.md](RELEASE_PATH.md)）。

> 提醒：第一次上传 Play 的 AAB **必须**是 upload key 签名的。误传本地 debug 签名的产物，
> `AndroidDebugKey` 会被永久登记为上传密钥，之后只能走「请求重置上传密钥」。
