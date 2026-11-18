import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/deal_reminder.dart';
import 'data/device_calendar_service.dart';
import 'data/device_identity.dart';
import 'data/local_deal_reminder.dart';
import 'data/platform_defaults.dart';
import 'data/sync_settings.dart';
import 'data/wool_repository.dart';
import 'state/sync_controller.dart';
import 'state/wool_store.dart';
import 'ui/calendar_page.dart';
import 'utils/calendar_grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 插件实例在 runApp 之前拿到，WoolStore 构造时即可同步 load，首帧无 loading 态。
  final prefs = await SharedPreferences.getInstance();

  final reminder = LocalDealReminder();
  await reminder.init();

  // 只读系统日历：插件实例是懒加载的，构造时不触发权限弹窗，
  // 只有用户打开「从手机日历导入」页并点授权时才会申请。
  final calendarSource = DeviceCalendarService();

  // 认本机：读机型 + 设备标识，几毫秒就回来；读不到返回 null，退回旧行为。
  final identity = await DeviceIdentity.read();

  final store = WoolStore(
    WoolRepository(prefs),
    reminder: reminder,
    calendarSource: calendarSource,
    // 只作为首次启动的初始值；之后完全由用户在 App 里增删。
    defaultPlatforms: _defaultPlatforms(),
    identity: identity,
  );
  // 识别结果（设备改名 / 记录换归属）必须在首帧前落盘，避免被自动同步
  // 用旧数据盖掉。
  await store.persistIdentity();

  // 同步配置：密码走系统加密存储，其余字段走 SharedPreferences。
  final syncController = SyncController(
    store: store,
    settingsStore: SyncSettingsStore(prefs, const SecureSecretStore()),
  );
  await syncController.load();

  // 点通知回到对应日期：前台点击走 onTap，冷启动走 launchPayload。
  void jumpToDay(String key) {
    try {
      store.selectDay(parseDateKey(key));
    } on Object {
      // 忽略坏 payload，不让它影响启动。
    }
  }

  reminder.onTap = jumpToDay;
  final launchKey = await reminder.launchPayload();
  if (launchKey != null) jumpToDay(launchKey);

  // 系统重启 / 应用更新会清掉闹钟，冷启动重排所有未来提醒。
  await store.syncReminders();

  runApp(
    MyApp(
      store: store,
      reminder: reminder,
      syncController: syncController,
    ),
  );

  // 首帧之后再尝试自动同步：不阻塞启动，失败只在同步设置页里显示。
  unawaited(syncController.autoSyncIfEnabled());
}

/// 首次启动的默认常用平台：跟随系统语言给一套初始值，之后完全由用户增删。
List<String> _defaultPlatforms() {
  final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  return code == 'zh' ? kDefaultPlatformsZh : kDefaultPlatformsEn;
}

/// 最小状态管理示例（MVVM 中的 ViewModel 角色）。
/// 主界面已换成羊毛日历，这里保留给 test/app_test.dart 作为 Provider 用法的参考。
class Counter with ChangeNotifier {
  int _count = 0;
  int get count => _count;
  void inc() {
    _count++;
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.store,
    required this.reminder,
    this.syncController,
  });

  final WoolStore store;
  final LocalDealReminder reminder;
  final SyncController? syncController;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<WoolStore>.value(
        value: store,
        child: _AppView(reminder: reminder, syncController: syncController),
      );
}

class _AppView extends StatelessWidget {
  const _AppView({required this.reminder, this.syncController});

  final LocalDealReminder reminder;
  final SyncController? syncController;

  @override
  Widget build(BuildContext context) => MaterialApp(
        onGenerateTitle: (ctx) => AppLocalizations.of(ctx)!.appName,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
        // builder 的 context 在 Localizations 之下，才能拿到当前语言；
        // 把通知文案注入服务层，让 main() 里的首次重排也有中文兜底之外的选择。
        builder: (context, child) {
          final l10n = AppLocalizations.of(context);
          if (l10n != null) {
            reminder.labels = ReminderLabels(
              channelName: l10n.reminderChannelName,
              channelDescription: l10n.reminderChannelDesc,
              startTitle: l10n.reminderStartTitle,
              startBody: l10n.reminderStartBody,
              endTitle: l10n.reminderEndTitle,
              endBody: l10n.reminderEndBody,
              testTitle: l10n.testNotificationTitle,
              testBody: l10n.testNotificationBody,
              scheduledTestTitle: l10n.scheduledTestTitle,
              scheduledTestBody: l10n.scheduledTestBody,
            );
          }
          return child!;
        },
        home: CalendarPage(
          reminder: reminder,
          syncController: syncController,
        ),
      );
}
