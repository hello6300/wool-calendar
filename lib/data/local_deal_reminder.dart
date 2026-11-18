import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/wool_deal.dart';
import '../utils/calendar_grid.dart';
import 'deal_reminder.dart';

/// Android 本地定时通知实现：不联网、不需要服务器推送、不需要 FCM。
///
/// 每条羊毛最多排两条通知：开始时间一条、结束时间一条。
/// 通知 id 由 deal.id 稳定派生（base / base+1），所以更新记录时 cancel+重排
/// 不会留下孤儿通知；App 冷启动会重排全部未来提醒，配合 BOOT_COMPLETED
/// receiver 覆盖「重启后闹钟被系统清掉」的场景。
class LocalDealReminder implements DealReminder {
  LocalDealReminder({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String channelId = 'wool_reminders';
  static const int _testNotificationId = 999999;

  /// 把字符串 hash 收进 28 bit，再乘 2 给两条通知留位，确保落在 Android
  /// 通知 id 的 32 位正数范围内。
  static const int _idMask = 0x0fffffff;

  final FlutterLocalNotificationsPlugin _plugin;

  bool _ready = false;
  String _timeZoneName = 'Asia/Shanghai';
  String? lastError;
  ReminderLabels labels = ReminderLabels.fallback;

  /// 通知点击回调，payload 是 yyyy-MM-dd，由 main() 接到 store.selectDay。
  void Function(String dateKey)? onTap;

  bool get ready => _ready;
  String get timeZoneName => _timeZoneName;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// 在 runApp 之前调用：初始化时区数据库、定位本机时区、注册通知渠道。
  Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      var name = 'Asia/Shanghai';
      try {
        final reported = await FlutterTimezone.getLocalTimezone();
        if (reported.isNotEmpty) {
          tz.getLocation(reported); // 名字不存在会抛，走下面的兜底
          name = reported;
        }
      } on Object {
        // 某些 ROM / 模拟器返回 "GMT+08:00" 这类非 IANA 名字，按东八区处理。
      }
      tz.setLocalLocation(tz.getLocation(name));
      _timeZoneName = name;

      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) onTap?.call(payload);
        },
      );
      _ready = true;
    } catch (e) {
      lastError = 'init: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  /// 通知点击导致冷启动时，从插件里取回 payload（前台点击走 onTap）。
  Future<String?> launchPayload() async {
    try {
      final payload = (await _plugin.getNotificationAppLaunchDetails())
          ?.notificationResponse
          ?.payload;
      return (payload == null || payload.isEmpty) ? null : payload;
    } on Object {
      return null;
    }
  }

  Future<bool?> notificationsEnabled() async {
    try {
      return await _android?.areNotificationsEnabled();
    } on Object {
      return null;
    }
  }

  Future<bool?> exactAlarmsEnabled() async {
    try {
      return await _android?.canScheduleExactNotifications();
    } on Object {
      return null;
    }
  }

  Future<int> pendingCount() async {
    try {
      return (await _plugin.pendingNotificationRequests()).length;
    } on Object {
      return 0;
    }
  }

  /// Android 13+ 需要动态申请 POST_NOTIFICATIONS；Android 14 的精确闹钟
  /// 需要用户到系统设置里授权，这里只在用户主动点按钮时跳转。
  @override
  Future<void> ensurePermissions({bool requestExactAlarm = false}) async {
    if (!_ready) return;
    try {
      await _android?.requestNotificationsPermission();
      if (requestExactAlarm) {
        await _android?.requestExactAlarmsPermission();
      }
    } catch (e) {
      lastError = 'permission: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  @override
  Future<void> sync(WoolDeal deal) async {
    if (!_ready) return;
    await cancel(deal.id);

    // 关掉提醒、已参与/已到账/已过期、或压根没填时间 → 只取消不排程。
    if (!deal.remind || !isReminderStatus(deal.status) || !deal.hasTime) return;

    try {
      final start = deal.startDateTime;
      final end = deal.endDateTime;
      final now = DateTime.now();
      final time = deal.timeRangeText;

      if (start != null && start.isAfter(now)) {
        await _schedule(
          id: _baseId(deal.id),
          at: start,
          title: labels.startTitle(deal.title),
          body: labels.startBody(deal.platform, time),
          payload: deal.dateText,
        );
      }
      // 起止时间完全相同（或跨天算下来同刻）时不重复弹第二条。
      if (end != null && end.isAfter(now) && end != start) {
        await _schedule(
          id: _baseId(deal.id) + 1,
          at: end,
          title: labels.endTitle(deal.title),
          body: labels.endBody(deal.platform, time),
          payload: deal.dateText,
        );
      }
    } catch (e) {
      // 权限没给、精确闹钟没授权等都不应让「保存记录」失败。
      lastError = 'sync: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  @override
  Future<void> cancel(String dealId) async {
    if (!_ready) return;
    final base = _baseId(dealId);
    try {
      await _plugin.cancel(base);
      await _plugin.cancel(base + 1);
    } catch (e) {
      lastError = 'cancel: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  Future<void> _schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String payload,
  }) async {
    final scheduled = tz.TZDateTime.from(at, tz.local);
    // 插件内部 validateDateIsInTheFuture 会抛错，这里先挡掉已过期的时刻。
    if (!scheduled.isAfter(tz.TZDateTime.now(tz.local))) return;

    // 没有精确闹钟权限时自动降级为非精确（仍会弹，只是可能晚几分钟）。
    final exact = await exactAlarmsEnabled() ?? false;
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          labels.channelName,
          channelDescription: labels.channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  /// 设置页里的「发一条测试通知」，用来在模拟器上确认权限与渠道是否正常。
  Future<void> sendTestNotification() async {
    if (!_ready) return;
    await ensurePermissions();
    try {
      await _plugin.show(
        _testNotificationId,
        labels.testTitle,
        labels.testBody,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            labels.channelName,
            channelDescription: labels.channelDescription,
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      lastError = 'test: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  /// 设置页里的「排一条 1 分钟后的提醒」：完整走一遍 zonedSchedule 链路，
  /// 用来验证「到点真的会弹」，而不是只验证立即通知和权限。
  Future<void> scheduleTestReminder() async {
    if (!_ready) return;
    await ensurePermissions();
    try {
      final at = DateTime.now().add(const Duration(minutes: 1));
      await _schedule(
        id: _testNotificationId + 1,
        at: at,
        title: labels.scheduledTestTitle,
        body: labels.scheduledTestBody,
        payload: dateKey(at),
      );
    } catch (e) {
      lastError = 'scheduleTest: $e';
      debugPrint('[reminder] $lastError');
    }
  }

  static int _baseId(String dealId) => (dealId.hashCode & _idMask) * 2;
}
