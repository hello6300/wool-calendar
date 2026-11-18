# 羊毛日历（Wool Calendar）

记录薅羊毛活动的本地 App：月历 + 列表，按设备 / 平台分类，支持 WebDAV 多设备同步。
Flutter 双端（Android + iOS）工程，含 GitHub Actions CI/CD 与双商店上线路径。

> **当前工作模式：只做本地开发，暂不发布（2026-11-06 起）**。
> 所有商店上传链路默认关闭，不需要任何签名密钥或商店账号。日常开发直接看
> **[docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md)**；上线资料完整保留在
> `docs/RELEASE_PATH.md` 与 `docs/ANDROID_SIGNING_SETUP.md`，随时可恢复。

| 项 | 值 |
|---|---|
| 技术栈 | Flutter 3.24.5 / Dart 3.5+，Provider 状态管理，MVVM 分层起点 |
| 应用名 | AppForge Demo（中文：AppForge 示例） |
| Android applicationId | `com.appforge.demo` |
| iOS Bundle ID | `com.appforge.demo` |
| CI | GitHub Actions（`ci.yml` 质量门禁 + `release.yml` 商店分发） |
| 签名 | Android upload keystore + Play App Signing；iOS Fastlane Match + ASC API Key |
| 版本 | `1.0.0+1`，CI 用 `--build-number` 覆盖 build number |

> **为什么选 Flutter**：一套 Dart 代码产出 AAB 与 IPA，双端 UI 一致、CI 只需两条 job，起步成本约比原生双端低 30–50%。代价是包体积略大、系统新 API 需等插件适配；若后续要做重度相机/AR/复杂动效，再按模块下沉原生即可。

## 工程路径（Windows 必读）

**真实工程目录：`D:\workspace\WorkBuddy\appforge-demo`（纯 ASCII，硬约束）。**

原工作区路径 `...\软件开发\appforge-demo` 含中文，Android Gradle Plugin 会直接拒绝；
即便用 `android.overridePathCheck=true` 绕过检查，`impellerc` 与 Dart AOT 快照器仍会因路径编码错乱
（中文被解成 `软件?发`）写不出 shader 与快照文件，构建必然失败。**这不能靠开关解决，只能换路径。**

工作区内的 `D:\workspace\WorkBuddy\软件开发\appforge-demo` 现在是一个 **NTFS 目录联接（junction）**，
指向上面的真实目录，两者是同一份文件，打开、编辑、提交都正常。命令行构建时 Git Bash / MSYS 会自动
解析到 ASCII 真实路径，所以从任一入口执行都可以（推荐直接写真实路径）：

```bash
cd /d/workspace/WorkBuddy/appforge-demo
flutter build appbundle --release
```

> 若以后把工程复制到别处，新路径必须**全 ASCII**，并执行一次 `flutter clean`，
> 以重建 `ios/Flutter/Generated.xcconfig`、`flutter_export_environment.sh` 等含绝对路径的生成文件。

## 本地开发（环境已装好）

本机已装好 Android 侧工具链（见下方「本地环境」），`bootstrap.sh` 已执行，`android/` 与 `ios/` 原生壳已生成。

> ⚠ **本机桌面终端是 PowerShell，没有独立 Git Bash**：`bash scripts/...` 在这里会报
> 「无法将 bash 项识别为 cmdlet」。日常请用下面的 PowerShell 写法；`.sh` 脚本只在自动化环境的
> Bash 会话可用。详见 [docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) 第 0.5 节。

用户级环境变量已持久化，**重开终端即生效**（`flutter` / `adb` 都在 PATH 里）。
PowerShell 5.1 不支持 `&&`，命令请分两行写：

```powershell
cd D:\workspace\WorkBuddy\appforge-demo
flutter pub get                 # 改 pubspec.yaml 后
flutter gen-l10n                # 改 lib/l10n/*.arb 后
flutter analyze
flutter test
flutter build apk --debug       # ✅ 已验证，无需设备、无需密钥
flutter build appbundle --release   # ✅ 已验证，debug 签名，仅本地验证用
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check   # 只验证连接
powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1          # 连接 MuMu + 热重载
```

`-ExecutionPolicy Bypass` 只对这次调用生效，不改系统设置；也可先在当前窗口跑
`Set-ExecutionPolicy -Scope Process Bypass -Force`，之后直接 `.\scripts\run-mumu.ps1`。
`flutter build ipa` 仅 macOS + Xcode，本机不支持。

> ✅ **全链路已实测通过（2026-11-13）**：网易 MuMu（Android 15 / API 35 / x86_64）装 APK、冷启动、
> 首屏「首页 / 计数器 0 / +」渲染正常，无白屏无崩溃；用户本机 PowerShell 再跑 `run-mumu.ps1`，
> 输出 **`Flutter run key commands.`** 并给出 Dart VM Service / DevTools 地址 → **热重载会话已建立**；
> 按 `r` 实测 `Reloaded 4 of 839 libraries in 578ms`，增量热重载生效。
> MuMu 同时开 5555/7555/16384 三个端口（同一设备的别名），**必须 `-d` 显式指定**；
> `scripts\run-mumu.ps1`（PowerShell）/ `scripts/run-mumu.sh`（Bash）已自动处理。
> 首次 debug 构建的两行红字（SDK XML version 4 / `storage.flutter-io.cn` 镜像）均为无害提示，见
> **[docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) 第 3 节**。
>
> 📝 **2026-11-13 17:00 UI 微调（首个热重载演示改动）**：主题色 `Colors.blue` → `Colors.green`、
> AppBar 改用 `primaryContainer`、计数上方加一行现有 i18n 文案 `welcome`、数字由 48 放大到 64 并加粗。
> 全部复用已有资源，**没有改 ARB / 生成代码**，所以在正在运行的 `flutter run` 会话里存盘后按 `r` 即可看到，
> 计数状态会保留。上面几条「首屏」的实测描述是**改动前**的画面。

`bootstrap.sh` 可重复执行：会备份并恢复 `pubspec.yaml`、`lib/main.dart`、`README.md`、
`.gitignore`、`analysis_options.yaml`，避免 `flutter create` 覆盖定制内容。
**必须把 `android/`、`ios/` 提交进仓库**——CI 不自动生成原生壳。

## 羊毛日历（当前主界面）

本地离线记录薅羊毛活动，并按月历查看。2026-11-13 实机验证通过（MuMu Android 15 / API 35）；
同日新增**活动时间（开始 / 结束）**与**到点通知提醒**；2026-11-14 新增**手动提取手机日历活动**
与**设备分类（手机 / 平板 / 备用机…）**。

### 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| 活动日期 | ✅ | 决定记录落在日历哪一天；点日期格即可切换选中日 |
| **设备** | ✅（有默认值） | 记这笔羊毛在哪台设备上参与；默认「手机」，可自定义「平板 / 备用机 / 工作机」等 |
| **开始时间 / 结束时间** | — | 24 小时制 `HH:mm`，可只填一端、可清除；结束早于开始按**次日**算（如 20:00-01:00） |
| **到点提醒** | — | 默认开；开始 / 结束时刻各弹一条系统通知，点通知回到当天日历 |
| 羊毛平台 | ✅ | 如京东、淘宝、招商银行；表单提供**可自定义的常用平台 chip**（首次启动预置京东 / 淘宝 / 拼多多 / 抖音 / 快手 / 美团 / 支付宝 / 银行 / 其他，之后可在 App 内增删改） |
| 标题 | ✅ | 一句话说明是什么活动 |
| 状态 | — | 待参与 / 已参与 / 已到账 / 已过期，日历圆点按状态着色；后三种自动取消提醒 |
| 活动链接 | — | 展开卡片后点一下**复制到剪贴板**（不跳浏览器，避免新增 `url_launcher` 依赖） |
| 羊毛详情 | — | 规则、门槛、券面额等多行文本 |
| 攻略备注 | — | 步骤、注意事项、账号要求、避坑点 |
| 预计收益（元） | — | 可选数字，当日列表顶部自动汇总「合计 ¥x.xx」 |

### 操作

点日期格选中当天 → 右下 `+` 新增；`‹` `›` 翻月、右上「今天」复位、**铃铛图标进「提醒设置」**、
**日历打勾图标进「手机日历活动」**；日历网格上方一行是**设备筛选条**（全部设备 / 各台设备 +
右侧齿轮进「设备管理」）。
展开卡片看详情/备注/链接与完整活动时间段，用 ChoiceChip 直接改状态，或编辑 / 删除（删除有二次确认）。
同一天的记录按开始时间排序，没填时间的排最后；日历每格最多显示 3 个状态圆点。

### 设备分类（2026-11-14 新增）

同一个活动常常「每台设备各领一次」，所以每条记录都带一个**设备标签**，
日历可按设备筛选、分开统计。设备只是本机分类，**不会读取其它设备的日历，也不跨设备同步**——
手机上的 App 没法直接访问另一台平板的 `CalendarContract` / `EventKit`，这点在设备管理页也写明。

- **设备注册表**：默认只有「手机」（本机），显示名跟随 App 语言；
  日历页筛选条右侧齿轮 →「设备管理」可自由新增 / 重命名 / 删除，
  编辑器里也有 `+` 就地新增设备并立刻选中。名称必填、不允许重名（含默认设备名）。
- **归属默认值**：新增记录 / 导入活动默认归到当前筛选的设备；筛选为「全部设备」时归默认设备。
  从手机日历导入时，范围卡里另有「归入设备」下拉可单独指定这批活动的归属。
- **筛选**：日历圆点、当日列表、「N 条 / 合计 ¥」都只统计当前设备；
  旧数据缺 `deviceId` 自动归到默认设备，升级后历史记录不会消失。
- **删除保护**：默认设备恒存在、不可删；删除其它设备时**记录不删除**，
  全部迁回默认设备并提示迁移条数，筛选自动回到「全部设备」。
- **存储**：`SharedPreferences` 单键 `appforge.devices.v1`（设备 JSON 数组）；
  记录里只存 `deviceId` 外键，重命名设备不动历史记录。零新增依赖。

### 自定义常用平台（2026-11-16 新增）

「常用平台」不再是写死在语言包里的列表，而是**用户自己的数据**，可随时增删改。

- **入口**：编辑器「羊毛平台」输入框下方的 chip 行，最后一个是「管理」；
  平台管理页支持新增 / 重命名 / 删除，名称为空或与已有平台重名会被拦下。
- **只影响快捷词**：重命名或删除平台**不会改动任何历史记录**的 `platform` 字段——
  已经写下的内容不做批量改写。删除确认框里也写明了这一点。
- **首次启动**：按系统语言预置一套初始值（中文 / 英文两套），之后完全由用户控制；
  即使把平台全删光，重启也不会自动塞回默认值。
- **存储**：`appforge.platforms.v1`（JSON 字符串数组）+ `appforge.platforms_updated_at.v1`
  （最后修改时刻，供同步判断整份列表谁更新）。零新增依赖。

### 多设备同步（WebDAV，2026-11-16 新增）

用任何支持 WebDAV 的网盘做**双向同步**，不依赖自建后端、不接入第三方账号体系。
坚果云、Nextcloud、群晖（WebDAV Server）、自建 NAS 都能用。

- **配置**：日历右上角**云同步图标** → 填「服务器地址 + 用户名 + 密码 / 应用密码 + 远端文件路径」，
  可「测试连接」「立即同步」，也可打开「启动时自动同步」。目录不存在会逐级 `MKCOL` 自动创建。
- **不用猜路径**：「远端文件路径」右侧的**浏览按钮**会 `PROPFIND Depth:1` 列出账号里真实的目录，
  点进去选一个即自动拼成 `<目录>/wool-sync.json`。各家 WebDAV 的「根」映射并不一样
  （飞牛 fnOS 的团队文件夹是 `/团队文件-<团队文件夹名>/`，坚果云是 `/dav/`，
  Nextcloud 是 `/remote.php/dav/files/<用户名>/`），靠文档猜前缀基本必错。
- **同步方式**：远端是**一个 JSON 文件**（默认 `appforge/wool-sync.json`）。每次同步：
  下载远端 → 与本地按记录 `id` 做并集、同 id 取 `updatedAt` 较新的一方 → 落盘 → 整份上传合并结果。
  两台设备各自新增的记录都会保留，不会互相覆盖。
- **删除会同步**：删除记录时写一个**墓碑**（`appforge.tombstones.v1`，记录 id + 删除时刻）。
  合并时「墓碑比副本新」就删除，避免另一台设备的旧副本把记录复活；
  若删除之后又编辑过（`updatedAt` 晚于墓碑），则以编辑为准保留。墓碑保留 365 天后清理。
- **冲突策略**：同一 id 双方都改过时按 `updatedAt` 取新（最后写入者胜），
  同步结果会显示「新增 / 更新 / 删除」各多少条；常用平台列表按整份 LWW
  （谁最后改过用谁），所以删除平台也能同步出去。
- **安全**：密码只写系统加密存储（`flutter_secure_storage` → Android Keystore /
  EncryptedSharedPreferences），不落 `SharedPreferences`、不进日志，界面上默认隐藏。
  远端文件缺少 `app: appforge-wool` 标记时**直接中止**，绝不覆盖别人的文件。
- **权限**：Manifest 增加 `INTERNET`；允许 `http://` 明文地址（内网群晖 / NAS 常见），
  外网建议用 https。App 只会连接用户自己填的地址，不向任何第三方服务器发送数据。
- **报错能直接定位**：错误详情固定带 `<动词> <地址> → <状态码> · <服务器原话>`。
  405 按动词分开解释，因为语义完全不同：
  `PROPFIND` 405 = 地址不是 WebDAV 端点（漏了 `/dav`），客户端会自动探 `dav/`、`webdav/`
  并把可用地址写进提示；
  `MKCOL` 405 = 有的服务器是「目录已存在」（RFC 4918），**有的是「不许客户端建目录」**
  （飞牛 fnOS 就是这样）—— 所以会用 `PROPFIND` 复核，真不存在就明确提示「请先在网盘里手动建目录」，
  并把**上级目录里实际有什么**列出来（如 `上级目录现有：团队文件-webdav/`），一眼看出前缀错在哪；
  `GET` 405 = 要么路径指向文件夹（提示补文件名），要么文件还没建（按首次同步继续）。
- **手动优先**：不做后台定时同步（不引入 `workmanager`），只在「立即同步」
  或开启自动同步时的冷启动执行一次。

### 到点通知提醒（2026-11-13 新增）

- **纯本地定时通知**：`flutter_local_notifications` + `timezone` / `flutter_timezone`，
  不联网、不用 FCM / 厂商推送、不需要账号。每条记录最多排 2 条通知（开始、结束），
  id 由记录 id 稳定派生，编辑时先取消再重排，不会留孤儿通知。
- **时间存储**：日期仍只存 `yyyy-MM-dd`，时间只存 `HH:mm` 字符串，两者分开 → 换时区不会让日历错位；
  排通知时才合成本地 `DateTime`。旧记录缺字段时视为「没填时间」，不会突然收到通知。
- **权限**：Android 13+ 的 `POST_NOTIFICATIONS` 在首次保存带时间的记录时自动申请；
  Android 14+ 精确闹钟需到系统设置授权，**未授权自动降级为非精确**（仍会弹，可能晚几分钟）。
- **重启 / 重装**：`BOOT_COMPLETED` receiver + App 冷启动 `syncReminders()` 重排全部未来提醒。
- **自检页**：日历右上铃铛 → 看通知权限、精确闹钟、当前时区、待发提醒条数、最近错误；
  可一键「开启通知权限」「去开启精确闹钟」「发一条测试通知」「排一条 1 分钟后的提醒」
  （验证 `zonedSchedule` 定时链路）「重新同步全部提醒」。

> 在 MuMu 上验证：新建一条记录，日期选今天、开始时间设成 2 分钟后、提醒打开 → 保存；
> 铃铛页「待发提醒」应 ≥1；到点下拉通知栏应看到「羊毛开始：xxx」。
> 模拟器息屏 / 省电策略可能延迟非精确闹钟，锁屏前测试最准。

### 从手机日历提取活动（2026-11-14 新增，手动流程）

日历右上角新增**日历打勾图标** → 「手机日历活动」页。**全程手动，不自动读取**：
进页面只检查权限状态，用户先选提取范围，再点「提取活动」才扫描系统日历，最后人工勾选导入。

- **① 选提取范围**：默认预填日历页当前显示的整月（仅预填，不触发读取）。
  四个快捷 chip「今天 / 未来 7 天 / 本月 / 未来 30 天」，两个日期按钮可点系统日期选择器
  自定义起止日；范围含首尾两天，起止顺序自动纠正，一次最多 366 天。
  改范围会清空已有结果并提示「范围已更改，请重新提取活动」，**绝不自动重新读取**。
- **② 手动点提取**：`提取活动` / `重新提取` / `重试提取` 是唯一的读取入口；
  结果条显示「本次提取：yyyy-MM-dd ~ yyyy-MM-dd」，避免范围与列表对不上。
  未授权时点它会先弹系统授权框，授权后接着完成这一次读取；权限页单独的
  「允许读取手机日历」按钮**只授权、不读取**。
- **③ 勾选导入**：列表显示标题、起止时间、所属日历，已导入项置灰，支持「全选」；
  底部「导入选中（N）」才真正落盘。结果区顶部可「重新提取」。
  范围卡里有「归入设备」下拉，指定这批活动记到手机 / 平板 / 备用机哪台设备名下
  （默认跟随日历页当前筛选的设备）。
- **只读**：只调用 `retrieveCalendars` / `retrieveEvents`，**从不新增、修改、删除**系统日历里的活动。
- **权限与合规**：`device_calendar` 插件的 `hasPermissions()` 内部把 READ + WRITE 绑定检查，
  因此 Manifest 同时声明了 `WRITE_CALENDAR`，授权框也可能写「日历读写」。
  **App 代码只用读取接口**，这点在导入页的帮助卡里也直接写给用户看，不做任何回写。
- **映射规则**：系统活动标题 → 标题、日历名 → 平台、描述 / 地点 / 来源 → 详情、
  描述里的 http 链接 → 活动链接；日期取**开始日**，起止时刻填进「活动时间」。
  全天活动不填时间、不排提醒；跨天 `20:00-01:00` 复用既有「结束早于开始 = 次日」规则；
  跨多日活动只保留开始时间，完整结束时刻写进详情（避免排出错误的结束提醒）。
  插件把 `eventURL` 包装成 `data:` URI，所以链接优先从描述里提取真实 http 地址。
- **去重**：每条导入记录带 `sourceId = device_calendar:<日历ID>:<事件ID>:<开始时刻>`，
  已导入的活动显示「已导入」并置灰；编辑标题后标记不丢，重复活动的每次实例也能分别导入。
- **导入后**：一次落盘、逐条按开始 / 结束时间排提醒，日历自动跳到第一条活动那天；
  卡片展开后能看到「来自手机日历 · <日历名>」标记。

### 实现与数据

- 日历本体不引入 `table_calendar`，网格自己画（原生 `Row`/`Column`，行高有上限，避免宽屏/横屏溢出）；
  基础状态管理复用 `provider` + `shared_preferences` + `intl`。在此之上新增 6 个依赖：
  `flutter_local_notifications 17.2.4`、`timezone 0.9.4`、`flutter_timezone 3.0.1`（通知）、
  `device_calendar 4.3.3`（只读系统日历）、`dio 5.4`（WebDAV 请求）、
  `flutter_secure_storage 9.2.4`（同步密码加密存储）。
- 目录：`lib/models/wool_deal.dart`（模型+JSON，含来源与设备标记）、`wool_time.dart`（HH:mm 值对象）、
  `device.dart`（设备值对象）、
  `lib/data/wool_repository.dart`（记录 + 设备两个键的持久化）、`deal_reminder.dart`（通知调度抽象）、
  `local_deal_reminder.dart`（Android 通知实现）、
  `device_calendar_source.dart`（日历源抽象 + 纯映射函数 + 去重键）、
  `device_calendar_service.dart`（插件实现）、
  `sync_snapshot.dart`（同步快照 + 双向合并纯函数）、`sync_service.dart`（拉取→合并→上传）、
  `webdav_transport.dart`（最小 WebDAV 客户端：GET / PUT / MKCOL / PROPFIND）、
  `sync_settings.dart`（同步配置 + 加密密码）、`platform_defaults.dart`（首次启动的默认平台）、
  `lib/state/wool_store.dart`（ChangeNotifier + 批量导入 + 平台注册表）、
  `lib/state/sync_controller.dart`（同步忙碌态 / 结果 / 错误编排）、
  `lib/utils/calendar_grid.dart`（日历网格纯函数）、`import_range.dart`（提取范围纯函数）、
  `lib/ui/`（日历页 / 编辑页 / 卡片 / 提醒设置页 / **导入页** / **设备管理页** /
  **平台管理页** / **同步设置页** / 设备名与平台名对话框 / 状态元数据）。
  中英文案在 `lib/l10n/*.arb`。
- Android 侧：`AndroidManifest.xml` 加通知 / 精确闹钟 / 开机启动 / 日历读写权限与两个 scheduled receiver；
  `android/app/build.gradle` 开 `multiDexEnabled` + `coreLibraryDesugaring`（`java.time` 脱糖），
  并把 `minSdk` 提到 **23**（`flutter_secure_storage` 9.x 的 EncryptedSharedPreferences 要求）。
- `DealReminder` 与 `DeviceCalendarSource` 都是纯 Dart 抽象，`WoolStore` 只依赖它们 →
  单元测试用 Fake，不碰原生插件；测试覆盖提取范围计算、映射、去重、设备注册表 / 筛选 /
  删除迁移、矮屏布局，以及「进页面不自动读取 / 手动触发 / 改范围清空结果」等导入页交互。
  同步侧 `SyncTransport` 同样是纯 Dart 抽象：单测用 Fake 覆盖首次同步 / 双向合并 / 外来文件中止，
  WebDAV 客户端再用 dio 的 `HttpClientAdapter` 假服务器验证 `MKCOL` / `PUT` / `PROPFIND` 与
  401 / 403 / 404 的状态码映射。
- 数据默认只存**本机** `SharedPreferences`：`appforge.wool_deals.v1`（记录）、
  `appforge.devices.v1`（设备）、`appforge.platforms.v1`（常用平台）、
  `appforge.platforms_updated_at.v1`（平台最后修改时刻）、`appforge.tombstones.v1`（删除墓碑）。
  **只有用户自己配好 WebDAV 之后**，才会把合并后的快照上传到那个地址；不向任何第三方服务器发送数据。
  以后要换 SQLite 只需替换 `WoolRepository`。
- `main()` 改为 async（先 `await SharedPreferences.getInstance()`），所以代码里**保留了 `Counter` 类**
  作为 `test/app_test.dart` 的 Provider 最小示例，但主界面已不用它。

> ⚠ **每次新增原生插件 / Manifest 权限 / Gradle 配置，热重载 / 热重启都不够**：
> 必须按 `q` 退出 `flutter run` → `flutter pub get` → 重新构建安装（最稳是直接重跑
> `powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1`）。
> 只按 `r` / `R` 会让新插件没注册，调用时报 `MissingPluginException`
> （2026-11-13 的通知插件、2026-11-14 的日历插件都验证过这一条）。
> 改 `lib/l10n/*.arb` 后还需要先 `flutter gen-l10n`。

---

## 目录

```
.github/workflows/   ci.yml（PR/main 验证构建）· release.yml（tag 分发商店）
fastlane/            Fastfile（Flutter 构建 + supply/pilot）· Appfile
android/ ios/        原生壳（bootstrap 后生成，需提交）
lib/                 main.dart · models/（WoolDeal · WoolTime · Device）· data/（持久化 · 通知调度 · 系统日历源）·
                     state/ · utils/（日历网格 · 提取范围）· ui/（日历 · 编辑 · 提醒设置 · 日历导入 · 设备管理）·
                     l10n/*.arb（中英文案）
test/                单元/Widget 测试
scripts/             bootstrap.sh 首次初始化
docs/
  RELEASE_PATH.md    ★ 上线路径总纲（Secrets / 签名 / 轨道 / 审核 / 回滚）
  store-listing/     App Store 与 Google Play 元数据、描述、关键词、截图规格、ASO
  checklists/        无障碍 / 安全隐私 / 商业化支付 三类提审自查清单
  feature-flags/     Firebase Remote Config 功能开关骨架（三端示例）
  growth/            埋点事件模型与 A/B 实验方案
```

## CI/CD 触发规则

> **当前为「只做本地开发」模式**：`ios/` 原生壳、Fastfile 的 iOS lanes、App Store 上架素材、
> `docs/RELEASE_PATH.md` 全部原样保留，只是两条 workflow 里所有 iOS 与发布动作默认跳过。
> 用仓库变量控制，恢复时不用改代码：
>
> | 变量 | 默认 | 控制范围 |
> |---|---|---|
> | `ENABLE_RELEASE` | 未设置＝关闭 | `ci.yml` 的 upload key 注入、`release.yml` 的两个分发 job |
> | `ENABLE_IOS` | 未设置＝关闭 | `ci.yml` / `release.yml` 的 iOS job（且需 `ENABLE_RELEASE` 同时开启才会上传） |

| 事件 | 工作流 | 当前实际动作 | 是否上传商店 |
|---|---|---|---|
| Pull Request | `ci.yml` | analyze、test、构建 debug 签名 AAB 存 Artifact | 否 |
| push `main` | `ci.yml` | 同上，**不要求任何 Secrets**，不会因缺密钥变红 | 否 |
| tag `v*` / 手动 | `release.yml` | 两个 job 全部跳过（误打 tag 也不会上传） | 否 |
| 手动 `fastlane android release` | — | 当前不执行（未装 Ruby/Fastlane） | 否 |

**恢复发布**：按 [docs/ANDROID_SIGNING_SETUP.md](docs/ANDROID_SIGNING_SETUP.md) 配齐 5 个 Secrets，
再在 `Settings → Secrets and variables → Actions → Variables` 加 `ENABLE_RELEASE=true`；
`ci.yml` 会重新用 upload key 签名，`release.yml` 的 `android` job 恢复上传 Play 内部轨道。
iOS 另需 `ENABLE_IOS=true` 与 Match / ASC 证书 Secrets。

完整上线链路见 [docs/RELEASE_PATH.md](docs/RELEASE_PATH.md)；
本地开发细节见 [docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md)。

## 本地环境（Windows，已配置）

通过 `scripts/setup-windows-env.sh` 在 `D:\dev` 完成用户级安装（无需管理员，全部哈希校验通过）：

| 组件 | 版本 | 路径 |
|---|---|---|
| Flutter / Dart | 3.24.5 / 3.5.4 | `D:\dev\flutter` |
| Temurin JDK | 17.0.20.1+1 | `D:\dev\jdk17` |
| Android SDK | platform-tools 37.0.1 / android-34 / build-tools 34.0.0 / cmdline-tools 23.0.0 | `D:\dev\android-sdk` |
| actionlint | 1.7.12 | `D:\dev\bin` |
| PyYAML | 6.0.3 | 用户 site-packages |

用户级环境变量已持久化：`JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`PUB_CACHE`、
`PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`（国内镜像）、`LOCALAPPDATA`、`NO_PROXY`，PATH 追加各 `bin`。
**重开终端生效**；Git Bash 里 PATH 要用 POSIX 形式 `/d/dev/...`。

沙箱网络注意事项：`flutter test` 需要 `NO_PROXY=localhost,127.0.0.1,::1`（已持久化），否则代理会拦截
`flutter_tester` 的本机 WebSocket；Java 不读 `HTTP_PROXY`，Gradle 首次构建需按
`scripts/setup-windows-env.sh` 的说明用国内镜像预置发行包，或临时设置 `JAVA_TOOL_OPTIONS` 代理。

验证结果（迁到 ASCII 路径后全量重跑）：

- `flutter analyze` → `No issues found!`
- `flutter test` → `00:07 +70: All tests passed!`（含时间解析、跨天、提醒调度、
  提取范围计算、系统日历映射 / 去重 / 链接提取、手动提取导入页交互、
  设备注册表 / 按设备筛选 / 删除迁移、自定义平台增删改、同步合并
  （`updatedAt` 取新 / 墓碑删除与复活 / 平台 LWW）、WebDAV 状态码映射
  （含 405 判定为「地址不是 WebDAV 端点」、`MKCOL` 405 复核目录是否真存在、
  `GET` 405 区分「路径是文件夹」与「文件还没建」）、目录浏览
  （`multistatus` 解析 / 剥根前缀 / 中文名解码 / 只留直接子项 / 集合补斜杠重试），
  以及平台管理页与同步设置页（含浏览远端文件夹）widget 测试）
- `flutter build appbundle --release` → `√ Built build/app/outputs/bundle/release/app-release.aab (18.5MB)`，
  内含 arm64-v8a / armeabi-v7a / x86_64 三套 `libflutter.so`（同步功能加入前的历史构建，未重打 AAB）
- `flutter build apk --debug` → `√ Built build/app/outputs/flutter-apk/app-debug.apk (约 200MB，含通知 + 日历 + 安全存储插件)`（无需设备/密钥，Gradle 126.9s）
- **MuMu 实机（2026-11-13）**：`adb install` → `am start -W` 冷启 2332ms → 首屏「首页 / 0 / +」正常渲染（17:00 UI 微调前的画面），无崩溃日志
- **通知链路 MuMu 实测（2026-11-13，Android 15）**：新 APK 冷启 2335ms 无 `FATAL`/`MissingPlugin` →
  铃铛页显示权限 / 精确闹钟 / `Asia/Shanghai` / 待发条数 → 系统权限弹窗「允许」→
  「发一条测试通知」真实出现在通知栏（`dumpsys notification` 可见 `channel=wool_reminders`、`id=999999`）→
  「排一条 1 分钟后的提醒」后待发变 **1 条**，`dumpsys alarm` 出现
  `RTC_WAKEUP ... com.appforge.demo ... ScheduledNotificationReceiver`（未授权精确闹钟时自动走非精确窗口）→
  **1 分钟后通知栏真实弹出「定时提醒测试成功」**（`id=1000000`），定时链路闭环
- **系统日历导入 MuMu 实测（2026-11-14，Android 15）**：用 `content insert` 往模拟器
  `CalendarContract` 插 1 个日历 + 2 条活动 → 新 APK 冷启 2301ms 无崩溃 → 右上日历打勾图标进入导入页 →
  系统弹「要允许 AppForge Demo 访问您的日历吗？」→ 允许 → **列表正确读出 2 条活动（含时间与日历名）** →
  全选导入 → SnackBar「已导入 2 条」、两条变「已导入」置灰 → `dumpsys alarm` 出现
  `RTC_WAKEUP origWhen=22:03 / 22:33 ... ScheduledNotificationReceiver` → 回日历页
  14 / 15 号出现圆点、14 号列表显示 `AppForge_Deal_Test · 22:03-22:33`、卡片有「来自手机日历」标记
- **手动提取改造 MuMu 复测（2026-11-14 22:26）**：新 APK 冷启 2386ms 无崩溃 → 进导入页只显示
  范围卡（默认 `2026-11-01 ~ 11-30`、共 30 天）与空态「选好范围后点提取活动」，**列表为空、未读取** →
  点「提取活动」→「本次提取：2026-11-01 ~ 11-30」共 2 个活动 → 点「今天」chip →
  范围变 `11-14 ~ 11-14` 共 1 天、结果清空并提示「范围已更改，请重新提取活动」、导入按钮禁用 →
  再点提取 → **共 1 个活动**（11-15 的 `Member_Day_Reminder` 被范围正确过滤）→
  点「开始日期」弹出 2026 年 11 月日期选择器，返回键正常关闭。
- **自定义平台 + WebDAV 同步 MuMu 实测（2026-11-16，Android 15）**：新 APK 冷启 **2801ms**，
  `logcat -b crash` **为空**（`flutter_secure_storage` 原生插件注册正常，启动链路无 `MissingPluginException`）→
  首页 AppBar 出现云同步图标，日历 / 设备筛选条（全部设备 / 手机 / 小米10s）/ 空态显示正常；
  同步表单与双向合并流程由 70 个测试覆盖（真机联调需自备 WebDAV 地址）
- **飞牛 fnOS 真机同步闭环（2026-11-16 13:49，Android 15）**：装新包冷启 2467ms 无崩溃 →
  云图标进同步页 → 点「浏览」→ **根目录只列出 `团队文件-webdav`**（该账号的团队文件夹就叫
  `webdav`，飞牛在 WebDAV 根下把它显示成 `团队文件-<名字>`，所以按文档猜 `/webdav/` 必然 404）→
  逐级进入 `yangmao`（同级还有 hiker / legado / moviepilot / siyuan，与飞牛「文件管理」完全一致）→
  「用这个文件夹」自动填成 `团队文件-webdav/yangmao/wool-sync.json` →「立即同步」**成功**
  （上次同步 13:49，新增 0 · 更新 0 · 删除 0 —— 当时本机无记录，只写入了空快照）→ 再同步一次仍成功，
  证明二次同步的 `GET` 也正常（飞牛只在「GET 目录」时报 405，GET 文件没问题）。
  另外同一台服务器上旧错误已被新提示补全：`MKCOL …/webdav → 405 · 目录不存在，
  服务器不允许自动创建 · 上级目录现有：团队文件-webdav/`
- **405 排查实测（2026-11-16）**：用 Python 在本机起了一台「只有 `/dav/` 才是 WebDAV」的假服务器，
  根路径对 PROPFIND / GET / PUT / MKCOL 一律回 405。`WebDavTransport` 实测结果：
  填根地址 → `SyncFailure.notWebDav`，详情
  `PROPFIND http://127.0.0.1:8099/ → 405 · Method Not Allowed · 可用地址：http://127.0.0.1:8099/dav/`；
  改成 `/dav/` 后 probe / MKCOL / GET(404→首次同步) / PUT / 回读全通；
  第二次同步时 MKCOL 真实返回 405（目录已存在）被正确放过，不再误报失败。
- **飞牛 fnOS 地址实测（2026-11-16）**：`PROPFIND https://dav.<设备>.fnos.net/` 无凭据返回
  **401 + `WWW-Authenticate: Basic realm="Restricted"`** —— 地址本身是合法 WebDAV 端点，
  405 不是地址问题。据飞牛官方论坛与第三方避坑记录：飞牛**不允许浏览器直接访问 WebDAV**
  （GET 目录一律 405），且**对客户端自动建目录限制较严**（目标目录不存在时 MKCOL 回 405）。
  因此新增 `SyncFailure.mkdirUnsupported`：MKCOL 405 后用 PROPFIND 复核，目录真不存在就
  明确提示「请先在网盘里手动建目录」，而不是把 405 当「已存在」放过、让 PUT 再撞一次 405。
- **设备分类 MuMu 实测（2026-11-14，Android 15）**：新 APK 冷启 2669ms 无崩溃 →
  首页出现「全部设备 / 手机」筛选条，上一轮导入的旧记录自动显示「手机」 →
  齿轮进「设备管理」→ 添加 `Tablet`（SnackBar「已保存」、0 条记录）→ 点 Tablet chip →
  `0 条 / 合计 ¥0.00`、圆点清空、空态「「Tablet」这天还没有羊毛」 →
  点 `+` 新增 `TabletDeal`，编辑器设备默认已是 Tablet → 保存后卡片
  `TestPlatform · Tablet · 待参与` → 切「全部设备」显示 2 条、14 日 2 个圆点 →
  设备管理删除 Tablet 并确认 →「已删除设备，1 条记录已移到默认设备」、手机变 3 条记录 →
  回日历 `TabletDeal` 仍在且设备名变「手机」 → 导入页底部「归入设备 / 手机」下拉与
  「导入选中（0）」正常，全程无溢出、无崩溃日志。
- `actionlint` 两条 workflow 0 告警；5 个 YAML + 2 个 ARB 均可解析
- `powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check` → `Android 15 (API 35) | x86_64`

> ★ 2026-11-13 修复：首次装进 MuMu 时暴露 `ClassNotFoundException: com.appforge.demo.MainActivity`
> ——`MainActivity.kt` 的 package 仍是模板值 `com.appforge.appforge_demo`，与 `namespace/applicationId`
> 不一致。已统一包名、整理源码目录、应用名改为 `AppForge Demo`，并在 `scripts/bootstrap.sh`
> 加入「Kotlin package 必须等于 applicationId」的自检。**编译全绿 ≠ 能启动，务必实机跑一次。**

> ⚠ 本机 AAB 是 **debug 签名**（未配置 `android/key.properties`），仅供验证工具链，**不能上传 Play**。
> CI 由 Secrets 生成 `key.properties` 后，`android/app/build.gradle` 会自动切换为 upload key 签名，
> 细节见 `docs/RELEASE_PATH.md` 阶段 2。

## 环境边界（务必阅读）

Windows **装不了 Xcode**：iOS 编译、签名、IPA 归档以及 Xcode 工程里的 Signing 配置无法在本机完成，
恢复发布后由 `release.yml` 的 `macos-14` runner 承担（本地不需要 Mac）。
**当前「只做本地开发」模式下，以下各项都不需要准备**；列出仅供恢复发布时对照：

1. 在 Mac / CI 的 Xcode 里配 Team 与 Bundle ID（`com.appforge.demo`）；
2. 生成签名资产并配置 GitHub Secrets（清单见 `docs/ANDROID_SIGNING_SETUP.md` / `docs/RELEASE_PATH.md`）；
3. 在 App Store Connect / Play Console 建应用记录、填商店信息、上传截图；
4. 打 tag 触发 `release.yml`，人工在商店后台做灰度与提审。

证书、私钥、keystore、服务账号 JSON **一律不入库、不写入本仓库任何文件**，只通过环境变量/Secrets 注入。
