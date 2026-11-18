import 'dart:convert';

import 'package:appforge_demo/data/calendar_probe.dart';
import 'package:appforge_demo/data/deal_reminder.dart';
import 'package:appforge_demo/data/device_calendar_service.dart';
import 'package:appforge_demo/data/device_identity.dart';
import 'package:appforge_demo/data/device_calendar_source.dart';
import 'package:appforge_demo/data/platform_defaults.dart';
import 'package:appforge_demo/data/sync_service.dart';
import 'package:appforge_demo/data/sync_settings.dart';
import 'package:appforge_demo/data/sync_snapshot.dart';
import 'package:appforge_demo/data/webdav_transport.dart';
import 'package:appforge_demo/data/wool_repository.dart';
import 'package:appforge_demo/models/device.dart';
import 'package:appforge_demo/models/wool_deal.dart';
import 'package:appforge_demo/models/wool_time.dart';
import 'package:appforge_demo/state/sync_controller.dart';
import 'package:appforge_demo/state/wool_store.dart';
import 'package:appforge_demo/ui/calendar_import_page.dart';
import 'package:appforge_demo/ui/calendar_page.dart';
import 'package:appforge_demo/ui/device_settings_page.dart';
import 'package:appforge_demo/ui/platform_settings_page.dart';
import 'package:appforge_demo/ui/sync_settings_page.dart';
import 'package:appforge_demo/ui/wool_editor.dart';
import 'package:appforge_demo/utils/calendar_grid.dart';
import 'package:appforge_demo/utils/import_range.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

WoolDeal _deal({
  required String id,
  required DateTime date,
  required DateTime createdAt,
  double? amount,
  WoolStatus status = WoolStatus.planned,
  WoolTime? startTime,
  WoolTime? endTime,
  bool remind = true,
  String title = '满减券',
  String deviceId = Device.defaultId,
}) =>
    WoolDeal(
      id: id,
      platform: '京东',
      title: title,
      detail: '满 200 减 30',
      url: 'https://example.com/deal',
      notes: '先领券再下单',
      date: date,
      status: status,
      amount: amount,
      startTime: startTime,
      endTime: endTime,
      remind: remind,
      createdAt: createdAt,
      deviceId: deviceId,
    );

CalendarImportLabels _importLabels() => CalendarImportLabels(
      fallbackPlatform: '手机日历',
      fallbackTitle: '（无标题活动）',
      allDayTag: '全天',
      endsAt: (v) => '结束：$v',
      location: (v) => '地点：$v',
      source: (v) => '来源：$v',
    );

CalendarEventEntry _calendarEvent({
  required String id,
  required DateTime start,
  required DateTime end,
  String title = '双十一抢券',
  String calendarName = '我的日历',
  String description = '',
  String location = '',
  String url = '',
  bool allDay = false,
}) =>
    CalendarEventEntry(
      sourceId: id,
      title: title,
      start: start,
      end: end,
      calendarName: calendarName,
      description: description,
      location: location,
      url: url,
      allDay: allDay,
    );

/// 不碰原生插件的系统日历 Fake，覆盖权限 / 读取 / 失败分支。
class FakeCalendarSource implements DeviceCalendarSource {
  FakeCalendarSource({
    this.permitted = true,
    this.events = const <CalendarEventEntry>[],
  });

  bool permitted;
  List<CalendarEventEntry> events;
  Object? error;
  int permissionRequests = 0;
  int fetchCalls = 0;
  DateTime? lastFrom;
  DateTime? lastTo;

  /// 提取结果为空时页面会问它要诊断，这里可以让测试指定答案。
  CalendarDiagnosis? diagnosis;
  int diagnoseCalls = 0;

  @override
  Future<bool> hasPermissions() async => permitted;

  @override
  Future<bool> requestPermissions() async {
    permissionRequests++;
    permitted = true;
    return true;
  }

  @override
  Future<CalendarDiagnosis?> diagnose({
    required DateTime from,
    required DateTime to,
  }) async {
    diagnoseCalls++;
    return diagnosis;
  }

  @override
  Future<List<CalendarEventEntry>> fetchEvents({
    required DateTime from,
    required DateTime to,
  }) async {
    fetchCalls++;
    lastFrom = from;
    lastTo = to;
    if (error != null) throw error!;
    return events;
  }
}

/// 不碰原生插件的提醒 Fake，用来验证 WoolStore 的调度时序。
class FakeDealReminder implements DealReminder {
  final List<String> synced = <String>[];
  final List<String> cancelled = <String>[];
  int permissionRequests = 0;

  @override
  Future<void> sync(WoolDeal deal) async {
    synced.add(deal.id);
  }

  @override
  Future<void> cancel(String dealId) async {
    cancelled.add(dealId);
  }

  @override
  Future<void> ensurePermissions() async {
    permissionRequests++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // device_calendar 把 Events 的时间戳解析成 TZDateTime，插件自身不会建时区库；
  // 真机上由 LocalDealReminder.init() 建，测试里得自己来，否则事件解析会抛异常
  // 并被服务层吞掉，看起来就像「插件什么都没读到」。
  tzdata.initializeTimeZones();

  group('日历工具函数', () {
    test('dateKey 与 parseDateKey 可逆，且忽略时分秒', () {
      final d = DateTime(2026, 11, 13, 23, 59, 59);
      expect(dateKey(d), '2026-11-13');
      expect(parseDateKey('2026-11-13'), DateTime(2026, 11, 13));
      expect(isSameDay(d, DateTime(2026, 11, 13)), isTrue);
    });

    test('calendarGrid 固定 42 格、周一起始、覆盖当月每一天', () {
      final grid = calendarGrid(DateTime(2026, 11));
      expect(grid.length, 42);
      expect(grid.first.weekday, DateTime.monday);
      expect(grid.last.weekday, DateTime.sunday);

      final daysInMonth = DateTime(2026, 12, 0).day; // 30
      for (var day = 1; day <= daysInMonth; day++) {
        expect(
          grid.any((d) => isSameDay(d, DateTime(2026, 11, day))),
          isTrue,
          reason: '11 月 $day 号应出现在网格里',
        );
      }
    });

    test('addMonths 跨年正确', () {
      expect(addMonths(DateTime(2026, 1, 15), -1), DateTime(2025, 12, 1));
      expect(addMonths(DateTime(2026, 12, 15), 1), DateTime(2027, 1, 1));
    });
  });

  group('提取范围 ImportRange', () {
    final anchor = DateTime(2026, 11, 14, 22, 13);

    test('快捷预设：今天 / 未来 7 天 / 本月 / 未来 30 天', () {
      final today = ImportRange.fromPreset(ImportRangePreset.today, anchor);
      expect(today.from, DateTime(2026, 11, 14));
      expect(today.toExclusive, DateTime(2026, 11, 15));
      expect(today.dayCount, 1);

      final week = ImportRange.fromPreset(ImportRangePreset.next7Days, anchor);
      expect(week.label, '2026-11-14 ~ 2026-11-20');
      expect(week.dayCount, 7);
      expect(week.toExclusive, DateTime(2026, 11, 21));

      final month = ImportRange.fromPreset(ImportRangePreset.thisMonth, anchor);
      expect(month.from, DateTime(2026, 11, 1));
      expect(month.toExclusive, DateTime(2026, 12, 1));
      expect(month.dayCount, 30);

      final days30 =
          ImportRange.fromPreset(ImportRangePreset.next30Days, anchor);
      expect(days30.dayCount, 30);
      expect(days30.toExclusive, DateTime(2026, 12, 14));

      // 跟随日历页月份时标记 custom，不谎称「本月」被选中。
      final initial = ImportRange.initialMonth(DateTime(2026, 12, 5));
      expect(initial.preset, ImportRangePreset.custom);
      expect(initial.label, '2026-12-01 ~ 2026-12-31');
    });

    test('范围是左闭右开，结束日当天的活动也要包含', () {
      final r = ImportRange.fromPreset(ImportRangePreset.thisMonth, anchor);
      expect(r.contains(DateTime(2026, 11, 1, 9)), isTrue);
      expect(r.contains(DateTime(2026, 11, 30, 23, 59)), isTrue);
      expect(r.contains(DateTime(2026, 12, 1)), isFalse);
      expect(r.contains(DateTime(2026, 10, 31, 23)), isFalse);
    });

    test('改起止日期自动纠正顺序，且最多 366 天', () {
      final base = ImportRange.fromPreset(ImportRangePreset.next7Days, anchor);

      final movedStart = base.withStart(DateTime(2026, 12, 1));
      expect(movedStart.start, DateTime(2026, 12, 1));
      expect(movedStart.end, DateTime(2026, 12, 1));
      expect(movedStart.preset, ImportRangePreset.custom);

      final movedEnd = base.withEnd(DateTime(2026, 10, 1));
      expect(movedEnd.start, DateTime(2026, 10, 1));
      expect(movedEnd.end, DateTime(2026, 10, 1));

      final tooLong = base.withEnd(DateTime(2030, 1, 1));
      expect(tooLong.end, DateTime(2030, 1, 1));
      expect(tooLong.dayCount, ImportRange.maxDays);
      expect(tooLong.isMaxLength, isTrue);
      expect(tooLong.dayCount <= ImportRange.maxDays, isTrue);
    });
  });

  group('WoolDeal JSON', () {
    test('全字段 roundtrip，日期只保留到天', () {
      final original = _deal(
        id: 'w1',
        date: DateTime(2026, 11, 13, 9, 30),
        createdAt: DateTime(2026, 11, 1, 8),
        amount: 12.5,
        status: WoolStatus.received,
      );
      final restored = WoolDeal.fromJson(original.toJson());

      expect(restored.id, 'w1');
      expect(restored.platform, '京东');
      expect(restored.title, '满减券');
      expect(restored.detail, '满 200 减 30');
      expect(restored.url, 'https://example.com/deal');
      expect(restored.notes, '先领券再下单');
      expect(restored.dateText, '2026-11-13');
      expect(restored.status, WoolStatus.received);
      expect(restored.amount, 12.5);
      expect(restored.createdAt, original.createdAt);
    });

    test('脏数据安全降级：未知状态回退 planned，坏日期回退今天', () {
      final restored = WoolDeal.fromJson(<String, dynamic>{
        'id': 'x',
        'platform': 'a',
        'title': 'b',
        'date': 'not-a-date',
        'status': 'unknown',
        'createdAt': 0,
      });
      expect(restored.status, WoolStatus.planned);
      expect(restored.detail, '');
      expect(restored.amount, isNull);
      expect(restored.dateText, dateKey(dayOnly(DateTime.now())));
    });
  });

  group('WoolTime / 活动时间', () {
    test('HH:mm 解析、格式化与脏数据降级', () {
      expect(WoolTime.tryParse('09:30'), const WoolTime(9, 30));
      expect(const WoolTime(9, 30).text, '09:30');
      expect(const WoolTime(20, 0).inMinutes, 1200);
      expect(WoolTime.tryParse('25:00'), isNull);
      expect(WoolTime.tryParse('9:5'), isNull);
      expect(WoolTime.tryParse('12:60'), isNull);
      expect(WoolTime.tryParse('not-a-time'), isNull);
      expect(WoolTime.tryParse(null), isNull);
    });

    test('时间字段 roundtrip，兼容缺字段的旧数据与坏值', () {
      final original = _deal(
        id: 'w1',
        date: DateTime(2026, 11, 13),
        createdAt: DateTime(2026, 11, 1),
        startTime: const WoolTime(9, 30),
        endTime: const WoolTime(11, 0),
        remind: false,
      );
      final restored = WoolDeal.fromJson(original.toJson());
      expect(restored.startTime, const WoolTime(9, 30));
      expect(restored.endTime, const WoolTime(11, 0));
      expect(restored.remind, isFalse);
      expect(restored.timeRangeText, '09:30-11:00');

      final legacy = WoolDeal.fromJson(original.toJson()
        ..remove('startTime')
        ..remove('endTime')
        ..remove('remind'));
      expect(legacy.startTime, isNull);
      expect(legacy.endTime, isNull);
      expect(legacy.remind, isTrue);
      expect(legacy.hasTime, isFalse);

      final dirty = WoolDeal.fromJson(<String, dynamic>{
        'id': 'x',
        'date': '2026-11-13',
        'startTime': '99:99',
        'endTime': '12:5',
        'createdAt': 0,
      });
      expect(dirty.startTime, isNull);
      expect(dirty.endTime, isNull);
    });

    test('结束早于开始按次日算，通知时刻正确', () {
      final day = DateTime(2026, 11, 13);
      final cross = _deal(
        id: 'a',
        date: day,
        createdAt: day,
        startTime: const WoolTime(20, 0),
        endTime: const WoolTime(1, 0),
      );
      expect(cross.crossesMidnight, isTrue);
      expect(cross.startDateTime, DateTime(2026, 11, 13, 20));
      expect(cross.endDateTime, DateTime(2026, 11, 14, 1));

      final normal = _deal(
        id: 'b',
        date: day,
        createdAt: day,
        startTime: const WoolTime(10, 0),
        endTime: const WoolTime(12, 0),
      );
      expect(normal.crossesMidnight, isFalse);
      expect(normal.endDateTime, DateTime(2026, 11, 13, 12));
      expect(normal.startDateTime, DateTime(2026, 11, 13, 10));

      final noTime = _deal(id: 'c', date: day, createdAt: day);
      expect(noTime.startDateTime, isNull);
      expect(noTime.endDateTime, isNull);
    });

    test('copyWith 能分别清除开始 / 结束时间', () {
      final d = _deal(
        id: 'a',
        date: DateTime(2026, 11, 13),
        createdAt: DateTime(2026, 11, 1),
        startTime: const WoolTime(9, 0),
        endTime: const WoolTime(11, 0),
      );
      expect(d.copyWith(clearStartTime: true).startTime, isNull);
      expect(d.copyWith(clearStartTime: true).endTime, const WoolTime(11, 0));
      expect(d.copyWith(clearEndTime: true).startTime, const WoolTime(9, 0));
      expect(d.copyWith(remind: false).remind, isFalse);
    });
  });

  group('WoolStore 提醒调度', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('增删改与状态变更会同步 / 取消提醒', () async {
      final prefs = await SharedPreferences.getInstance();
      final fake = FakeDealReminder();
      final store = WoolStore(WoolRepository(prefs), reminder: fake);
      final day = DateTime(2026, 11, 13);
      final deal = _deal(
        id: 'a',
        date: day,
        createdAt: day,
        startTime: const WoolTime(10, 0),
      );

      await store.add(deal);
      expect(fake.synced, <String>['a']);

      await store.update(deal.copyWith(title: '改过标题'));
      expect(fake.synced, <String>['a', 'a']);

      await store.setStatus('a', WoolStatus.done);
      expect(fake.synced.length, 3);

      await store.remove('a');
      expect(fake.cancelled, <String>['a']);

      await store.enableReminders();
      expect(fake.permissionRequests, 1);
    });

    test('冷启动重排磁盘上的全部记录', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = WoolRepository(prefs);
      final day = DateTime(2026, 11, 13);
      await repo.save(<WoolDeal>[
        _deal(id: 'a', date: day, createdAt: day),
        _deal(id: 'b', date: day, createdAt: day),
      ]);
      final fake = FakeDealReminder();
      final store = WoolStore(repo, reminder: fake);
      await store.syncReminders();
      expect(fake.synced, <String>['a', 'b']);
    });
  });

  group('WoolStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('增删改查、按日筛选、收益合计与持久化', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = WoolRepository(prefs);
      final store = WoolStore(repo);
      final day = DateTime(2026, 11, 13);

      await store.add(_deal(
        id: 'a',
        date: day,
        createdAt: DateTime(2026, 11, 1),
        amount: 10,
      ));
      await store.add(_deal(
        id: 'b',
        date: day,
        createdAt: DateTime(2026, 11, 2),
        amount: 5.5,
      ));
      await store.add(_deal(
        id: 'c',
        date: DateTime(2026, 11, 14),
        createdAt: DateTime(2026, 11, 3),
      ));

      expect(store.dealsOn(day).length, 2);
      expect(store.dealsOn(DateTime(2026, 11, 14)).length, 1);
      expect(store.dayReward(day), 15.5);

      await store.setStatus('a', WoolStatus.received);
      expect(store.dealsOn(day).first.status, WoolStatus.received);

      await store.update(store.deals
          .firstWhere((d) => d.id == 'a')
          .copyWith(title: '改过标题', clearAmount: true));
      final updated = store.deals.firstWhere((d) => d.id == 'a');
      expect(updated.title, '改过标题');
      expect(updated.amount, isNull);

      // 换一个 Store 实例从磁盘重读，确认真的落盘了。
      final reloaded = WoolStore(repo);
      expect(reloaded.deals.length, 3);
      expect(reloaded.dealsOn(day).length, 2);
      expect(reloaded.deals.firstWhere((d) => d.id == 'a').status,
          WoolStatus.received);

      await store.remove('a');
      expect(WoolStore(repo).deals.length, 2);
    });

    test('点到跨月补位日期时自动切月，今天按钮复位', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));

      store.showMonth(DateTime(2026, 11));
      expect(store.month, DateTime(2026, 11, 1));

      store.selectDay(DateTime(2026, 12, 6));
      expect(store.selectedDay, DateTime(2026, 12, 6));
      expect(store.month, DateTime(2026, 12, 1));

      store.goToday();
      expect(store.month, monthStart(DateTime.now()));
      expect(store.selectedDay, dayOnly(DateTime.now()));
    });
  });

  group('设备注册表与按设备筛选', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('默认设备恒存在、名字跟随语言，脏数据自动补默认设备', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = WoolRepository(prefs);

      final initial = repo.loadDevices();
      expect(initial.length, 1);
      expect(initial.first.id, Device.defaultId);
      expect(initial.first.displayName('手机'), '手机');
      expect(initial.first.displayName('Phone'), 'Phone');
      expect(const Device(id: 'x', name: '平板').displayName('手机'), '平板');

      // 缺默认设备 / 带空 ID / JSON 损坏：都要兜住，记录不会失去归属。
      await prefs.setString(
        WoolRepository.devicesKey,
        '[{"id":"x","name":"平板"},{"id":"","name":"坏数据"}]',
      );
      final repaired = repo.loadDevices();
      expect(repaired.first.id, Device.defaultId);
      expect(repaired.length, 2);
      expect(repaired.last.name, '平板');

      await prefs.setString(WoolRepository.devicesKey, 'not-json');
      expect(repo.loadDevices().single.id, Device.defaultId);
    });

    test('新增 / 重名 / 重命名 / 删除设备并迁移记录', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = WoolRepository(prefs);
      final store = WoolStore(repo);
      expect(store.devices.length, 1);
      expect(store.deviceForNew, Device.defaultId);

      final tablet = await store.addDevice(' 平板 ', defaultLabel: '手机');
      expect(tablet, isNotNull);
      expect(tablet!.name, '平板');
      expect(store.devices.length, 2);
      // 同名（含默认设备的本地化名）、空名都拒绝。
      expect(await store.addDevice('平板', defaultLabel: '手机'), isNull);
      expect(await store.addDevice('手机', defaultLabel: '手机'), isNull);
      expect(await store.addDevice('  ', defaultLabel: '手机'), isNull);
      expect(store.devices.length, 2);

      expect(
        await store.renameDevice(tablet.id, 'iPad', defaultLabel: '手机'),
        isTrue,
      );
      expect(store.devices.last.displayName('手机'), 'iPad');
      // 重命名回默认设备名会撞车，但改成自己的原名不应报错。
      expect(
        await store.renameDevice(tablet.id, '手机', defaultLabel: '手机'),
        isFalse,
      );
      expect(
        await store.renameDevice(tablet.id, 'iPad', defaultLabel: '手机'),
        isTrue,
      );

      final day = DateTime(2026, 11, 14);
      await store.add(_deal(
        id: 'a',
        date: day,
        createdAt: day,
        deviceId: tablet.id,
        amount: 10,
      ));
      await store.add(_deal(
        id: 'b',
        date: day,
        createdAt: day,
        amount: 5,
      ));
      expect(store.dealCountOf(tablet.id), 1);

      // 切到该设备：列表、圆点数据源、收益都只算这台设备。
      store.selectDevice(tablet.id);
      expect(store.isAllDevices, isFalse);
      expect(store.dealsOn(day).map((d) => d.id), <String>['a']);
      expect(store.dayReward(day), 10);
      expect(store.deviceForNew, tablet.id);
      store.selectDevice('');
      expect(store.dealsOn(day).length, 2);
      expect(store.dayReward(day), 15);

      // 删除设备：记录保留，迁回默认设备，筛选自动回到全部。
      store.selectDevice(tablet.id);
      expect(await store.removeDevice(tablet.id), 1);
      expect(store.devices.length, 1);
      expect(store.isAllDevices, isTrue);
      expect(store.deals.length, 2);
      expect(store.deals.every((d) => d.deviceId == Device.defaultId), isTrue);

      // 默认设备不可删；换 Store 从磁盘重读结果一致。
      expect(await store.removeDevice(Device.defaultId), -1);
      final reloaded = WoolStore(repo);
      expect(reloaded.devices.single.id, Device.defaultId);
      expect(
        reloaded.deals.every((d) => d.deviceId == Device.defaultId),
        isTrue,
      );
    });

    test('deviceId 兼容旧数据，copyWith 不丢设备与来源标记', () {
      final d = _deal(
        id: 'a',
        date: DateTime(2026, 11, 14),
        createdAt: DateTime(2026, 11, 1),
        deviceId: 'd1',
      );
      final restored = WoolDeal.fromJson(d.toJson());
      expect(restored.deviceId, 'd1');
      expect(restored.copyWith(title: '改过').deviceId, 'd1');

      final legacy = WoolDeal.fromJson(d.toJson()..remove('deviceId'));
      expect(legacy.deviceId, Device.defaultId);
      final dirty = WoolDeal.fromJson(<String, dynamic>{
        'id': 'x',
        'date': '2026-11-14',
        'deviceId': '',
        'createdAt': 0,
      });
      expect(dirty.deviceId, Device.defaultId);
    });

    test('导入活动可指定设备，缺省归当前筛选 / 默认设备', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      final tablet = (await store.addDevice('平板', defaultLabel: '手机'))!;
      final e1 = _calendarEvent(
        id: 'e1',
        start: DateTime(2026, 11, 14, 10),
        end: DateTime(2026, 11, 14, 11),
      );
      final e2 = _calendarEvent(
        id: 'e2',
        start: DateTime(2026, 11, 15, 10),
        end: DateTime(2026, 11, 15, 11),
      );

      expect(
        await store.importEvents(<CalendarEventEntry>[e1],
            labels: _importLabels(), deviceId: tablet.id),
        1,
      );
      expect(
        await store
            .importEvents(<CalendarEventEntry>[e2], labels: _importLabels()),
        1,
      );
      expect(store.deals.firstWhere((d) => d.sourceId == 'e1').deviceId,
          tablet.id);
      expect(store.deals.firstWhere((d) => d.sourceId == 'e2').deviceId,
          Device.defaultId);

      store.selectDevice(tablet.id);
      expect(store.dealsOn(DateTime(2026, 11, 14)).length, 1);
      expect(store.dealsOn(DateTime(2026, 11, 15)).length, 0);
    });
  });

  group('识别本机设备', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    const identity = DeviceIdentity(
      id: 'dev-1a2b3c4d',
      label: 'Redmi K30 Pro',
      model: 'Redmi K30 Pro',
      manufacturer: 'Xiaomi',
    );

    Map<String, dynamic> raw(
      String androidId,
      String model, [
      String manufacturer = 'Xiaomi',
    ]) =>
        <String, dynamic>{
          'androidId': androidId,
          'model': model,
          'manufacturer': manufacturer,
          'device': 'lmi',
        };

    test('解析原生字段：id 从设备标识派生，机型名可读', () {
      final a = DeviceIdentity.fromRaw(raw('abc123', 'Redmi K30 Pro'))!;
      expect(a.id, startsWith('dev-'));
      // 同一台手机每次算出来都是同一个 id，卸载重装也认得出。
      expect(DeviceIdentity.fromRaw(raw('abc123', 'Redmi K30 Pro'))!.id, a.id);
      // 换一台手机必须是另一个 id，否则云端分不清谁是谁。
      expect(
        DeviceIdentity.fromRaw(raw('zzz999', 'Redmi K30 Pro'))!.id,
        isNot(a.id),
      );
      expect(a.label, 'Redmi K30 Pro');

      // 读不到设备标识就老实返回 null，不能共用 id 去冒充别的手机。
      expect(DeviceIdentity.fromRaw(raw('', 'Redmi K30 Pro')), isNull);
      expect(DeviceIdentity.fromRaw(null), isNull);

      // 内部代号补厂商名，正常机型原样，机型缺失退到代号。
      expect(
        DeviceIdentity.buildLabel(
          model: 'M2007J3SC',
          manufacturer: 'Xiaomi',
          codename: 'lmi',
        ),
        'Xiaomi M2007J3SC',
      );
      expect(
        DeviceIdentity.buildLabel(
          model: 'Redmi K30 Pro',
          manufacturer: 'Xiaomi',
          codename: 'lmi',
        ),
        'Redmi K30 Pro',
      );
      expect(
        DeviceIdentity.buildLabel(
          model: '',
          manufacturer: 'Xiaomi',
          codename: 'lmi',
        ),
        'lmi',
      );
      // 过长机型名截断，避免把设备 chip 挤变形。
      expect(
        DeviceIdentity.buildLabel(
          model: List<String>.filled(40, 'A').join(),
          manufacturer: '',
          codename: '',
        ).length,
        lessThanOrEqualTo(DeviceIdentity.maxLabelLength),
      );
    });

    test('首次识别：本机设备换成真身份，历史记录跟着搬', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        WoolRepository.devicesKey,
        '[{"id":"default","name":"","isDefault":true},'
        '{"id":"d1","name":"小米10s","isDefault":false}]',
      );
      await prefs.setString(
        WoolRepository.storageKey,
        jsonEncode(<Map<String, dynamic>>[
          _deal(
            id: 'a',
            date: DateTime(2026, 11, 14),
            createdAt: DateTime(2026, 11, 1),
          ).toJson(),
          _deal(
            id: 'b',
            date: DateTime(2026, 11, 15),
            createdAt: DateTime(2026, 11, 1),
            deviceId: 'd1',
          ).toJson(),
        ]),
      );

      final repo = WoolRepository(prefs);
      final store = WoolStore(repo, identity: identity);

      expect(store.thisDeviceId, 'dev-1a2b3c4d');
      expect(store.hasDeviceIdentity, isTrue);
      expect(store.thisDeviceLabel, 'Redmi K30 Pro');

      final self = store.devices.first;
      expect(self.id, 'dev-1a2b3c4d');
      expect(self.name, 'Redmi K30 Pro');
      expect(self.isDefault, isTrue);
      expect(self.autoNamed, isTrue);
      // 旧 id 退场，手动加的设备原样保留。
      expect(store.devices.any((d) => d.id == Device.defaultId), isFalse);
      expect(store.deviceName('d1', '手机'), '小米10s');

      // 历史记录搬到本机名下，另一台设备的记录不动。
      expect(store.deals.firstWhere((d) => d.id == 'a').deviceId, 'dev-1a2b3c4d');
      expect(store.deals.firstWhere((d) => d.id == 'b').deviceId, 'd1');
      expect(store.deviceForNew, 'dev-1a2b3c4d');
      // 本机不能删。
      expect(await store.removeDevice('dev-1a2b3c4d'), -1);
      // 删其它设备时记录迁回本机，而不是迁到已经消失的 default。
      expect(await store.removeDevice('d1'), 1);
      expect(store.deals.firstWhere((d) => d.id == 'b').deviceId, 'dev-1a2b3c4d');

      // 落盘后重启（这次原生读不到）也还认得自己。
      await store.persistIdentity();
      final reopened = WoolStore(WoolRepository(prefs));
      expect(reopened.thisDeviceId, 'dev-1a2b3c4d');
      expect(reopened.devices.single.id, 'dev-1a2b3c4d');
      expect(
        reopened.deals.firstWhere((d) => d.id == 'a').deviceId,
        'dev-1a2b3c4d',
      );
    });

    test('用户改过名就保留自己的叫法，不被机型名顶掉', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        WoolRepository.devicesKey,
        '[{"id":"default","name":"k30pro","isDefault":true}]',
      );
      final repo = WoolRepository(prefs);
      final store = WoolStore(repo, identity: identity);

      final self = store.devices.single;
      expect(self.id, 'dev-1a2b3c4d');
      expect(self.name, 'k30pro');
      expect(self.autoNamed, isFalse);

      await store.persistIdentity();
      final reopened = WoolStore(WoolRepository(prefs), identity: identity);
      expect(reopened.devices.single.name, 'k30pro');
      expect(reopened.devices.single.id, 'dev-1a2b3c4d');
    });

    test('读不到身份时保持旧行为：共用 default，不瞎猜', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs), identity: null);
      expect(store.thisDeviceId, Device.defaultId);
      expect(store.hasDeviceIdentity, isFalse);
      expect(store.devices.single.id, Device.defaultId);
      expect(store.deviceForNew, Device.defaultId);
    });

    test('用户改自己的设备名后，重启 / 同步都不会被机型名盖回去', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs), identity: identity);
      final self = store.devices.single;
      // 首次识别：自动叫机型名。
      expect(self.name, 'Redmi K30 Pro');
      expect(self.autoNamed, isTrue);
      await store.persistIdentity();

      // 用户改名。改名同时必须清掉「自动命名」标记，否则下次冷启动
      // 「认本机」会认为它还是机型名，又拿 Build.MODEL 盖回去。
      expect(
        await store.renameDevice(self.id, 'k30pro', defaultLabel: '手机'),
        isTrue,
      );
      expect(store.devices.single.name, 'k30pro');
      expect(store.devices.single.autoNamed, isFalse);

      // 同一台手机再识别一次（冷启动）也不能改回去。
      final reopened = WoolStore(WoolRepository(prefs), identity: identity);
      expect(reopened.devices.single.name, 'k30pro');
      expect(reopened.devices.single.autoNamed, isFalse);

      // 再改一次、再重启，仍然保持。
      expect(
        await reopened.renameDevice(self.id, '主力机', defaultLabel: '手机'),
        isTrue,
      );
      await reopened.persistIdentity();
      final again = WoolStore(WoolRepository(prefs), identity: identity);
      expect(again.devices.single.name, '主力机');
    });

    test('老版本留下的「自动命名」标记不该再盖掉用户起的名字', () async {
      final prefs = await SharedPreferences.getInstance();
      // 复现旧版 bug 落盘的样子：名字是用户起的，autoNamed 却还是 true。
      await prefs.setString(
        WoolRepository.devicesKey,
        '[{"id":"dev-1a2b3c4d","name":"k30pro","isDefault":true,'
        '"autoNamed":true}]',
      );
      await prefs.setString(
        WoolRepository.thisDeviceKey,
        '{"id":"dev-1a2b3c4d","label":"Redmi K30 Pro"}',
      );

      final store = WoolStore(WoolRepository(prefs), identity: identity);
      // 名字既不等于当前机型名、也不等于上次记下的机型名 → 是用户起的，
      // 就地停掉自动命名，别再动它。
      expect(store.devices.single.name, 'k30pro');
      expect(store.devices.single.autoNamed, isFalse);
    });

    test('同步落盘时不能把用户刚改的设备名改回去', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs), identity: identity);
      await store.persistIdentity();
      final id = store.thisDeviceId;
      await store.renameDevice(id, '我的手机', defaultLabel: '手机');

      // 模拟「同步在改名之前就导出了快照」：那份快照里的本机还是老的自动名。
      await store.applySyncSnapshot(
        _snapshot(
          devices: <Device>[
            Device(
              id: id,
              name: 'Redmi K30 Pro',
              isDefault: true,
              autoNamed: true,
            ),
          ],
        ),
      );

      expect(store.devices.single.name, '我的手机');
      expect(store.devices.single.autoNamed, isFalse);
      // 落盘也要是这个结果，重启后不能又变回机型名。
      final reopened = WoolStore(WoolRepository(prefs), identity: identity);
      expect(reopened.devices.single.name, '我的手机');
    });
  });

  testWidgets('日历页能渲染月历网格与空态', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => WoolStore(WoolRepository(prefs)),
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 若日历把页面撑溢出，pumpAndSettle 会直接抛 RenderFlex 异常，测试即失败。
    expect(find.text('Wool Calendar'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.textContaining('No deals on this day'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('编辑页显示开始 / 结束时间与到点提醒开关', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => WoolStore(WoolRepository(prefs)),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WoolEditorPage(date: DateTime(2026, 11, 13)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start time'), findsOneWidget);
    expect(find.text('End time'), findsOneWidget);
    expect(find.text('Remind me'), findsOneWidget);
    expect(find.text('Not set'), findsNWidgets(2));
  });

  group('系统日历活动 → 羊毛记录映射', () {
    test('同时段事件映射成日期 + 起止时间 + 来源标记', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11, 30),
          description: '满 200 减 30',
          location: '线上',
          url: 'https://example.com/deal',
        ),
        id: 'w1',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );

      expect(deal.dateText, '2026-11-14');
      expect(deal.startTime, const WoolTime(10, 0));
      expect(deal.endTime, const WoolTime(11, 30));
      expect(deal.timeRangeText, '10:00-11:30');
      expect(deal.platform, '我的日历');
      expect(deal.title, '双十一抢券');
      expect(deal.url, 'https://example.com/deal');
      expect(deal.remind, isTrue);
      expect(deal.sourceId, 'dc:1');
      expect(deal.sourceName, '我的日历');
      expect(deal.isFromDeviceCalendar, isTrue);
      expect(deal.status, WoolStatus.planned);
      expect(deal.amount, isNull);
      expect(deal.detail, contains('满 200 减 30'));
      expect(deal.detail, contains('地点：线上'));
      expect(deal.detail, contains('来源：我的日历'));
    });

    test('日历名是 ROM 资源键时不写进记录，退回兜底名', () {
      // 红米 K30 Pro 的 Calendars 表里 displayName 就是 calendar_displayname_xiaomi，
      // 直接落库会让用户看到一串英文。
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:key',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
          calendarName: 'calendar_displayname_xiaomi',
        ),
        id: 'w-key',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );

      expect(deal.platform, '手机日历');
      expect(deal.sourceName, '手机日历');
      expect(deal.detail, contains('来源：手机日历'));
      expect(deal.detail, isNot(contains('calendar_displayname')));

      // 正常的日历名照旧，不能被误伤。
      expect(displayCalendarName('我的日历', '手机日历'), '我的日历');
      expect(displayCalendarName('  ', '手机日历'), '手机日历');
      expect(displayCalendarName('calendar_displayname_local', '手机日历'), '手机日历');
      // 只是名字里带这串字，但不像资源键的，不该被吞掉。
      expect(
        displayCalendarName('calendar_displayname 备注', '手机日历'),
        'calendar_displayname 备注',
      );
    });

    test('跨天 20:00-01:00 命中 WoolDeal 的次日规则', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:2',
          start: DateTime(2026, 11, 14, 20),
          end: DateTime(2026, 11, 15, 1),
        ),
        id: 'w2',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );
      expect(deal.crossesMidnight, isTrue);
      expect(deal.startDateTime, DateTime(2026, 11, 14, 20));
      expect(deal.endDateTime, DateTime(2026, 11, 15, 1));
      expect(deal.detail, isNot(contains('结束：')));
    });

    test('跨多日活动不填结束时间，完整结束时刻写进详情', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:3',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 17, 18),
        ),
        id: 'w3',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );
      expect(deal.startTime, const WoolTime(10, 0));
      expect(deal.endTime, isNull);
      expect(deal.detail, contains('结束：2026-11-17 18:00'));
    });

    test('全天活动不填时间、不排提醒', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:4',
          start: DateTime(2026, 11, 14),
          end: DateTime(2026, 11, 15),
          allDay: true,
        ),
        id: 'w4',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );
      expect(deal.hasTime, isFalse);
      expect(deal.remind, isFalse);
      expect(deal.detail, contains('全天'));
    });

    test('空标题 / 空日历名走本地化兜底文案', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:5',
          start: DateTime(2026, 11, 14, 9),
          end: DateTime(2026, 11, 14, 10),
          title: '  ',
          calendarName: '',
        ),
        id: 'w5',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );
      expect(deal.title, '（无标题活动）');
      expect(deal.platform, '手机日历');
      expect(deal.sourceName, '手机日历');
    });

    test('链接解析：真 http 直接用，data: URI 回退到描述里的链接', () {
      expect(resolveCalendarEventUrl(Uri.parse('https://a.com/x'), ''),
          'https://a.com/x');
      expect(
        resolveCalendarEventUrl(
            Uri.dataFromString('https://b.com/y'), '见 https://b.com/y 领券'),
        'https://b.com/y',
      );
      expect(resolveCalendarEventUrl(null, '没有链接'), '');
    });

    test('来源字段 JSON roundtrip，旧数据缺字段视为手工记录', () {
      final deal = calendarEventToDeal(
        _calendarEvent(
          id: 'dc:1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
        ),
        id: 'w1',
        createdAt: DateTime(2026, 11, 1),
        labels: _importLabels(),
      );
      final restored = WoolDeal.fromJson(deal.toJson());
      expect(restored.sourceId, 'dc:1');
      expect(restored.sourceName, '我的日历');
      expect(restored.isFromDeviceCalendar, isTrue);

      final legacy = WoolDeal.fromJson(deal.toJson()
        ..remove('sourceId')
        ..remove('sourceName'));
      expect(legacy.isFromDeviceCalendar, isFalse);

      // 用户编辑过标题后来源标记不能丢，否则下次会被重复导入。
      expect(restored.copyWith(title: '改过').sourceId, 'dc:1');
    });

    test('timeText 覆盖同时段 / 跨天 / 全天', () {
      final same = _calendarEvent(
        id: 'a',
        start: DateTime(2026, 11, 14, 10),
        end: DateTime(2026, 11, 14, 11, 30),
      );
      expect(same.timeText('All-day'), contains('10:00-11:30'));

      final cross = _calendarEvent(
        id: 'b',
        start: DateTime(2026, 11, 14, 20),
        end: DateTime(2026, 11, 15, 1),
      );
      expect(cross.timeText('All-day'), contains('2026-11-15 01:00'));

      final allDay = _calendarEvent(
        id: 'c',
        start: DateTime(2026, 11, 14),
        end: DateTime(2026, 11, 15),
        allDay: true,
      );
      expect(allDay.timeText('All-day'), contains('All-day'));
    });
  });

  group('系统日历批量导入', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('去重、一次落盘、逐条排提醒；重复导入返回 0', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = WoolRepository(prefs);
      final fake = FakeDealReminder();
      final store = WoolStore(repo, reminder: fake);
      final a = _calendarEvent(
        id: 'a',
        start: DateTime(2026, 11, 14, 10),
        end: DateTime(2026, 11, 14, 11),
      );
      final b = _calendarEvent(
        id: 'b',
        start: DateTime(2026, 11, 15, 9),
        end: DateTime(2026, 11, 15, 10),
      );

      expect(
          await store.importEvents(<CalendarEventEntry>[a, b],
              labels: _importLabels()),
          2);
      expect(store.deals.length, 2);
      expect(fake.synced.length, 2);
      expect(WoolStore(repo).deals.length, 2); // 确实落盘
      expect(store.importedSourceIds, <String>{'a', 'b'});

      expect(
          await store.importEvents(<CalendarEventEntry>[a, b],
              labels: _importLabels()),
          0);
      expect(store.deals.length, 2);
      expect(fake.synced.length, 2);
    });

    test('同一批里重复 sourceId 只导入一次', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      final e = _calendarEvent(
        id: 'dup',
        start: DateTime(2026, 11, 14, 10),
        end: DateTime(2026, 11, 14, 11),
      );
      expect(
          await store.importEvents(<CalendarEventEntry>[e, e],
              labels: _importLabels()),
          1);
      expect(store.deals.length, 1);
    });

    test('编辑导入记录后来源标记不丢', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      await store.importEvents(
        <CalendarEventEntry>[
          _calendarEvent(
            id: 'a',
            start: DateTime(2026, 11, 14, 10),
            end: DateTime(2026, 11, 14, 11),
          ),
        ],
        labels: _importLabels(),
      );
      await store.update(store.deals.first.copyWith(title: '改过标题'));
      expect(store.deals.first.sourceId, 'a');
      expect(WoolStore(WoolRepository(prefs)).deals.first.sourceId, 'a');
    });
  });

  testWidgets('进页面不自动读取，手动点提取后才列出活动并勾选导入', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final source = FakeCalendarSource(
      events: <CalendarEventEntry>[
        _calendarEvent(
          id: 'e1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
        ),
        _calendarEvent(
          id: 'e2',
          start: DateTime(2026, 11, 15, 9),
          end: DateTime(2026, 11, 15, 10),
          title: '会员日',
        ),
      ],
    );
    final store = WoolStore(WoolRepository(prefs), calendarSource: source);

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarImportPage(
            source: source,
            initialMonth: DateTime(2026, 11),
            now: DateTime(2026, 11, 14),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phone calendar events'), findsOneWidget);
    expect(
      find.text(
          'Pick a range, then tap Extract events to read your phone calendar'),
      findsOneWidget,
    );
    expect(find.text('2026-11-01 ~ 2026-11-30'), findsOneWidget);
    expect(find.text('双十一抢券'), findsNothing);
    expect(source.fetchCalls, 0);

    await tester.tap(find.byKey(const Key('importExtractButton')));
    await tester.pumpAndSettle();

    expect(source.fetchCalls, 1);
    expect(source.lastFrom, DateTime(2026, 11, 1));
    expect(source.lastTo, DateTime(2026, 12, 1));
    expect(find.text('Extracted: 2026-11-01 ~ 2026-11-30'), findsOneWidget);
    expect(find.text('双十一抢券'), findsOneWidget);
    expect(find.text('会员日'), findsOneWidget);

    await tester.tap(find.text('双十一抢券'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import selected (1)'));
    await tester.pumpAndSettle();

    expect(store.deals.length, 1);
    expect(store.deals.first.sourceId, 'e1');
    expect(store.deals.first.dateText, '2026-11-14');
    expect(store.selectedDay, DateTime(2026, 11, 14));
    expect(find.text('Imported'), findsOneWidget);
  });

  testWidgets('未授权时授权按钮只授权不读取，提取按钮才触发读取', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final source = FakeCalendarSource(
      permitted: false,
      events: <CalendarEventEntry>[
        _calendarEvent(
          id: 'e1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
        ),
      ],
    );
    final store = WoolStore(WoolRepository(prefs), calendarSource: source);

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarImportPage(
            source: source,
            initialMonth: DateTime(2026, 11),
            now: DateTime(2026, 11, 14),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Allow calendar access'), findsOneWidget);
    expect(find.text('双十一抢券'), findsNothing);
    expect(source.fetchCalls, 0);

    await tester.tap(find.text('Allow calendar access'));
    await tester.pumpAndSettle();

    expect(source.permissionRequests, 1);
    expect(source.fetchCalls, 0);
    expect(find.text('双十一抢券'), findsNothing);

    await tester.tap(find.byKey(const Key('importExtractButton')));
    await tester.pumpAndSettle();
    expect(source.fetchCalls, 1);
    expect(find.text('双十一抢券'), findsOneWidget);
  });

  group('系统日历读不到时的兜底与诊断', () {
    const pluginChannel = MethodChannel('plugins.builttoroam.com/device_calendar');
    const probeChannel = MethodChannel('appforge/calendar_probe');

    void setHandler(
      MethodChannel channel,
      Future<Object?> Function(MethodCall) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() {
      setHandler(pluginChannel, (call) async => null);
      setHandler(probeChannel, (call) async => null);
    });

    Map<String, Object?> instance({
      String eventId = '9',
      String calendarId = '5',
      String title = '领金币',
      String calendarName = '小米日历',
      String description = '',
      bool allDay = false,
    }) {
      final begin = DateTime(2026, 11, 16, 12).millisecondsSinceEpoch;
      final end = DateTime(2026, 11, 16, 14).millisecondsSinceEpoch;
      return <String, Object?>{
        'eventId': eventId,
        'calendarId': calendarId,
        'title': title,
        'begin': begin,
        'end': end,
        'allDay': allDay,
        'description': description,
        'location': '',
        'calendarName': calendarName,
      };
    }

    test('诊断能区分「没有日历」「有事件但实例读不出」「区间真空」', () {
      const noCalendar = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[],
        instanceCount: 0,
        eventRowCount: 0,
        errors: <String>[],
      );
      expect(noCalendar.noCalendars, isTrue);
      expect(noCalendar.instancesFiltered, isFalse);
      // 没有日历不代表「区间为空」，不能混为一谈。
      expect(noCalendar.genuinelyEmpty, isFalse);

      const filtered = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[
          CalendarAccountInfo(
            id: '1',
            name: '小米日历',
            account: 'mi',
            visible: false,
            syncEvents: false,
            accessLevel: 500,
          ),
        ],
        instanceCount: 0,
        eventRowCount: 12,
        // 直读 Events 表能展开出实例，才叫「接口被过滤」。
        expandedCount: 12,
        tableRowCount: 40,
        errors: <String>[],
      );
      expect(filtered.instancesFiltered, isTrue);
      expect(filtered.noCalendars, isFalse);
      expect(filtered.genuinelyEmpty, isFalse);
      expect(filtered.noEventsAtAll, isFalse);

      // 红米 K30 Pro 实测踩过的坑：查一个空区间（2030 年）时，Events 表的区间
      // 条件对重复日程只要求 DTSTART <= to，于是 109 条重复日程全被算成「原始
      // 事件」，旧逻辑据此报成「手机限制了日历」。真正的答案看展开结果。
      const emptyRange = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[
          CalendarAccountInfo(
            id: '1',
            name: '本地日历',
            account: 'local',
            visible: true,
            syncEvents: true,
            accessLevel: 500,
          ),
        ],
        instanceCount: 0,
        eventRowCount: 109,
        expandedCount: 0,
        tableRowCount: 157,
        errors: <String>[],
      );
      expect(emptyRange.genuinelyEmpty, isTrue);
      expect(emptyRange.instancesFiltered, isFalse);
      expect(emptyRange.noEventsAtAll, isFalse);

      // 整张表 0 条：权限被「返回空数据」接管，不是区间的问题。
      const blocked = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[
          CalendarAccountInfo(
            id: '1',
            name: '本地日历',
            account: 'local',
            visible: true,
            syncEvents: true,
            accessLevel: 500,
          ),
        ],
        instanceCount: 0,
        eventRowCount: 0,
        errors: <String>[],
      );
      expect(blocked.noEventsAtAll, isTrue);
      expect(blocked.genuinelyEmpty, isFalse);
      expect(blocked.instancesFiltered, isFalse);
    });

    test('设备名能识别小米 / 红米，用于给出对应的权限指引', () {
      const xiaomi = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[],
        instanceCount: 0,
        eventRowCount: 0,
        errors: <String>[],
        manufacturer: 'Xiaomi',
        model: 'Xiaomi 14',
      );
      expect(xiaomi.isXiaomi, isTrue);
      expect(xiaomi.deviceLabel, 'Xiaomi Xiaomi 14');

      const other = CalendarDiagnosis(
        readPermission: true,
        writePermission: true,
        calendars: <CalendarAccountInfo>[],
        instanceCount: 0,
        eventRowCount: 0,
        errors: <String>[],
        manufacturer: 'samsung',
        model: 'SM-S9180',
      );
      expect(other.isXiaomi, isFalse);
    });

    test('原生兜底返回的实例能转成活动，sourceId 与插件路径同形', () async {
      setHandler(probeChannel, (call) async {
        expect(call.method, 'queryInstances');
        return <Map<String, Object?>>[
          instance(description: '详见 https://example.com/a'),
        ];
      });

      const probe = PlatformCalendarProbe();
      final events = await probe.queryInstances(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      final begin = DateTime(2026, 11, 16, 12).millisecondsSinceEpoch;
      expect(events, hasLength(1));
      expect(events.single.sourceId, 'device_calendar:5:9:$begin');
      expect(events.single.title, '领金币');
      expect(events.single.calendarName, '小米日历');
      // 原生侧没有 url 字段，从描述里的链接兜回来。
      expect(events.single.url, 'https://example.com/a');
    });

    test('插件一个日历都读不到时，原生通道把活动读回来', () async {
      setHandler(pluginChannel, (call) async {
        if (call.method == 'hasPermissions') return true;
        if (call.method == 'retrieveCalendars') return '[]';
        return null;
      });
      setHandler(probeChannel, (call) async {
        if (call.method == 'queryInstances') {
          return <Map<String, Object?>>[instance()];
        }
        return null;
      });

      final events = await DeviceCalendarService().fetchEvents(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(1));
      expect(events.single.title, '领金币');
    });

    test('插件读日历报错时仍走原生兜底，不直接判失败', () async {
      setHandler(pluginChannel, (call) async {
        if (call.method == 'retrieveCalendars') {
          throw PlatformException(code: 'error', message: 'no calendars');
        }
        return null;
      });
      setHandler(probeChannel, (call) async {
        if (call.method == 'queryInstances') {
          return <Map<String, Object?>>[instance(title: '兜底活动')];
        }
        return null;
      });

      final events = await DeviceCalendarService().fetchEvents(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(1));
      expect(events.single.title, '兜底活动');
    });

    test('同一个活动被重复返回时只保留一条', () async {
      setHandler(probeChannel, (call) async {
        if (call.method == 'queryInstances') {
          // 同 calendarId + eventId + 开始时刻 = 同一个活动。
          return <Map<String, Object?>>[instance(), instance(), instance(eventId: '10')];
        }
        return null;
      });

      final events = await const PlatformCalendarProbe().queryInstances(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(2));
      expect(events.map((e) => e.sourceId).toSet(), hasLength(2));
    });

    test('实例视图被 ROM 过滤成 0 条时，改从事件表把数据读回来', () async {
      // 小米那台机器的真实表现：日历里有日程，但 Instances 一条都读不到。
      setHandler(pluginChannel, (call) async {
        if (call.method == 'hasPermissions') return true;
        if (call.method == 'retrieveCalendars') {
          return '[{"id":"5","name":"小米日历","accountName":"mi","color":0,'
              '"isReadOnly":false,"isDefault":true,"accountType":"LOCAL",'
              '"allowsModifications":true}]';
        }
        if (call.method == 'retrieveEvents') return '[]';
        return null;
      });
      final calls = <String>[];
      setHandler(probeChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'queryEvents') {
          return <Map<String, Object?>>[
            instance(title: '去【抖音极速版】领30金币预约奖励'),
          ];
        }
        // Instances 这条通道返回空 —— 正是被 ROM 过滤的样子。
        if (call.method == 'queryInstances') return <Map<String, Object?>>[];
        return null;
      });

      final events = await DeviceCalendarService().fetchEvents(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(1));
      expect(events.single.title, '去【抖音极速版】领30金币预约奖励');
      // 只在前面几条通道都空的时候才去查大表。
      expect(calls, contains('queryEvents'));
    });

    test('插件已经读到内容时不去查事件表，省掉一次全表扫描', () async {
      final begin = DateTime(2026, 11, 16, 12);
      final end = DateTime(2026, 11, 16, 14);
      setHandler(pluginChannel, (call) async {
        if (call.method == 'retrieveCalendars') {
          return '[{"id":"5","name":"小米日历","accountName":"mi","color":0,'
              '"isReadOnly":false,"isDefault":true,"accountType":"LOCAL",'
              '"allowsModifications":true}]';
        }
        if (call.method == 'retrieveEvents') {
          // 插件的真实 JSON 形状：字段名是 eventTitle / eventStartDate（毫秒）等，
          // 不是 title / start。写错格式插件会静默解析失败，测试就验不到东西。
          return '[{"eventId":"9","calendarId":"5","eventTitle":"领金币",'
              '"eventDescription":"",'
              '"eventStartDate":${begin.millisecondsSinceEpoch},'
              '"eventStartTimeZone":"Asia/Shanghai",'
              '"eventEndDate":${end.millisecondsSinceEpoch},'
              '"eventEndTimeZone":"Asia/Shanghai",'
              '"eventAllDay":false,"eventLocation":"","eventURL":null}]';
        }
        return null;
      });
      var eventsQueried = false;
      setHandler(probeChannel, (call) async {
        if (call.method == 'queryEvents') eventsQueried = true;
        return <Map<String, Object?>>[];
      });

      final events = await DeviceCalendarService().fetchEvents(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(1));
      expect(eventsQueried, isFalse, reason: '已经有数据就不该再扫事件表');
    });

    test('插件与原生给出同一个活动时只导入一条，不会重复', () async {
      final begin = DateTime(2026, 11, 16, 12);
      final end = DateTime(2026, 11, 16, 14);
      setHandler(pluginChannel, (call) async {
        if (call.method == 'retrieveCalendars') {
          return '[{"id":"5","name":"小米日历","accountName":"mi","color":0,'
              '"isReadOnly":false,"isDefault":true,"accountType":"LOCAL",'
              '"allowsModifications":true}]';
        }
        if (call.method == 'retrieveEvents') {
          // 插件的真实 JSON 形状：字段名是 eventTitle / eventStartDate（毫秒）等，
          // 不是 title / start。写错格式插件会静默解析失败，测试就验不到东西。
          return '[{"eventId":"9","calendarId":"5","eventTitle":"领金币",'
              '"eventDescription":"",'
              '"eventStartDate":${begin.millisecondsSinceEpoch},'
              '"eventStartTimeZone":"Asia/Shanghai",'
              '"eventEndDate":${end.millisecondsSinceEpoch},'
              '"eventEndTimeZone":"Asia/Shanghai",'
              '"eventAllDay":false,"eventLocation":"","eventURL":null}]';
        }
        return null;
      });
      // 原生通道回同一条（calendarId=5, eventId=9, 同一开始时刻）。
      setHandler(probeChannel, (call) async {
        if (call.method == 'queryInstances') {
          return <Map<String, Object?>>[instance()];
        }
        return null;
      });

      final events = await DeviceCalendarService().fetchEvents(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 12, 1),
      );

      expect(events, hasLength(1), reason: '两条通道各读到一次，但只该导入一条');
      expect(events.single.title, '领金币');
    });

    testWidgets('一条都读不到时把诊断摊开，而不是只说「没有活动」', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final source = FakeCalendarSource()
        ..diagnosis = const CalendarDiagnosis(
          readPermission: true,
          writePermission: true,
          calendars: <CalendarAccountInfo>[],
          instanceCount: 0,
          eventRowCount: 0,
          errors: <String>[],
          manufacturer: 'Xiaomi',
          model: 'Xiaomi 14',
          sdkInt: 34,
        );
      final store = WoolStore(WoolRepository(prefs), calendarSource: source);

      await tester.pumpWidget(
        ChangeNotifierProvider<WoolStore>(
          create: (_) => store,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CalendarImportPage(
              source: source,
              initialMonth: DateTime(2026, 11),
              now: DateTime(2026, 11, 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('importExtractButton')));
      await tester.pumpAndSettle();

      expect(source.diagnoseCalls, 1);
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(
        find.textContaining('There is no calendar account at all'),
        findsOneWidget,
      );
      expect(find.textContaining('Xiaomi Xiaomi 14'), findsOneWidget);
      // 小米机型要额外给出权限怎么改。
      expect(find.textContaining('Blank pass'), findsOneWidget);
      // 复制入口必须在，且要能被点到（放在标题行而不是卡片底部，矮屏才看得到）。
      expect(find.byKey(const Key('importDiagCopyButton')), findsOneWidget);
    });

    testWidgets('诊断里摊开每个日历各读到几条，指出是哪个日历被过滤', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final source = FakeCalendarSource()
        ..diagnosis = const CalendarDiagnosis(
          readPermission: true,
          writePermission: true,
          calendars: <CalendarAccountInfo>[
            CalendarAccountInfo(
              id: '5',
              name: '小米日历',
              account: 'mi',
              visible: true,
              syncEvents: true,
              accessLevel: 700,
            ),
            CalendarAccountInfo(
              id: '7',
              name: '生日',
              account: 'mi',
              visible: false,
              syncEvents: false,
              accessLevel: 500,
            ),
          ],
          instanceCount: 0,
          eventRowCount: 3,
          recurringCount: 2,
          tableRowCount: 40,
          perCalendar: <CalendarInstanceCount>[],
          errors: <String>[],
          manufacturer: 'Xiaomi',
          model: 'Xiaomi 14',
          sdkInt: 34,
        );
      final store = WoolStore(WoolRepository(prefs), calendarSource: source);

      await tester.pumpWidget(
        ChangeNotifierProvider<WoolStore>(
          create: (_) => store,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CalendarImportPage(
              source: source,
              initialMonth: DateTime(2026, 11),
              now: DateTime(2026, 11, 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('importExtractButton')));
      await tester.pumpAndSettle();

      // 两个日历都列出来，各自 0 条 —— 一眼看出不是「只有某个日历被过滤」，
      // 而是整体读不到实例。
      expect(find.textContaining('小米日历 0'), findsOneWidget);
      expect(find.textContaining('生日 0'), findsOneWidget);
      // 带重复规则的条数要单独报，重复日程是最容易被 ROM 过滤掉的一类。
      expect(find.textContaining('2 of them carry a recurrence rule'), findsOneWidget);
      // 关键回归：整张表有 40 条、本区间展开后 0 条 —— 这是「真的没有」，
      // 绝不能再报成「手机限制了日历」（红米 K30 Pro 上曾经误报）。
      expect(
        find.textContaining(
          'holds 40 events, but none of them fall inside the selected range',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('yields no occurrence inside it'),
        findsOneWidget,
      );
      expect(
        find.textContaining('system-level limitation'),
        findsNothing,
      );
    });
  });

  testWidgets('手动选择范围会清空旧结果，重新提取才用新范围读取', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final source = FakeCalendarSource(
      events: <CalendarEventEntry>[
        _calendarEvent(
          id: 'e1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
        ),
      ],
    );
    final store = WoolStore(WoolRepository(prefs), calendarSource: source);

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarImportPage(
            source: source,
            initialMonth: DateTime(2026, 11),
            now: DateTime(2026, 11, 14),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('importExtractButton')));
    await tester.pumpAndSettle();
    expect(find.text('双十一抢券'), findsOneWidget);
    expect(source.fetchCalls, 1);

    // 改范围只清结果，绝不自动再读一次。
    await tester.tap(find.byKey(const Key('importPreset_next7Days')));
    await tester.pumpAndSettle();
    expect(find.text('双十一抢券'), findsNothing);
    expect(
        find.text('Range changed. Tap Extract events again'), findsOneWidget);
    expect(source.fetchCalls, 1);
    expect(find.text('7 days'), findsOneWidget);

    await tester.tap(find.byKey(const Key('importExtractButton')));
    await tester.pumpAndSettle();
    expect(source.fetchCalls, 2);
    expect(source.lastFrom, DateTime(2026, 11, 14));
    expect(source.lastTo, DateTime(2026, 11, 21));
    expect(find.text('Extracted: 2026-11-14 ~ 2026-11-20'), findsOneWidget);
    expect(find.text('双十一抢券'), findsOneWidget);
  });

  testWidgets('常用平台包含抖音 / 快手（中文文案）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(
      WoolRepository(prefs),
      defaultPlatforms: kDefaultPlatformsZh,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: WoolEditorPage(date: DateTime(2026, 11, 14)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('常用平台'), findsOneWidget);
    expect(find.text('抖音'), findsOneWidget);
    expect(find.text('快手'), findsOneWidget);
  });

  testWidgets('常用平台英文含 Douyin / Kuaishou，点击一键填入平台', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(
      WoolRepository(prefs),
      defaultPlatforms: kDefaultPlatformsEn,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: WoolEditorPage(date: DateTime(2026, 11, 14)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Douyin'), findsOneWidget);
    final kuaishou = find.text('Kuaishou');
    expect(kuaishou, findsOneWidget);
    await tester.ensureVisible(kuaishou);
    await tester.pumpAndSettle();
    await tester.tap(kuaishou);
    await tester.pumpAndSettle();

    final field = tester.widget<TextFormField>(
      find.byKey(const Key('editorPlatformField')),
    );
    expect(field.controller!.text, 'Kuaishou');
  });

  testWidgets('编辑页可选设备、就地新增设备，保存后记录归属正确', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));

    // 用 push 打开编辑器，保存后的 Navigator.pop() 才有上一层可回。
    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => WoolEditorPage(
                        date: DateTime(2026, 11, 14),
                      ),
                    ),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('editorDeviceField')), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);

    await tester.tap(find.byKey(const Key('editorAddDevice')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('deviceNameField')), 'Tablet');
    await tester.tap(find.byKey(const Key('deviceNameConfirm')));
    await tester.pumpAndSettle();
    expect(store.devices.length, 2);
    expect(find.text('Tablet'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('editorPlatformField')), '京东');
    await tester.enterText(find.byKey(const Key('editorTitleField')), '平板专属券');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(store.deals.length, 1);
    expect(store.deals.first.title, '平板专属券');
    expect(store.deals.first.deviceId, store.devices.last.id);
    expect(store.deals.first.deviceId, isNot(Device.defaultId));
  });

  testWidgets('设备管理页重命名 / 删除设备并迁移记录', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final tablet = (await store.addDevice('Tablet', defaultLabel: 'Phone'))!;
    final day = DateTime(2026, 11, 14);
    await store.add(_deal(
      id: 'a',
      date: day,
      createdAt: day,
      deviceId: tablet.id,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeviceSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Manage devices'), findsOneWidget);
    expect(find.text('Tablet'), findsOneWidget);

    await tester.tap(find.byKey(Key('deviceMenu_${tablet.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('deviceNameField')), 'iPad');
    await tester.tap(find.byKey(const Key('deviceNameConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('iPad'), findsOneWidget);

    await tester.tap(find.byKey(Key('deviceMenu_${tablet.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete device'));
    await tester.pumpAndSettle();
    expect(find.text('Delete "iPad"?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('deviceDeleteConfirm')));
    await tester.pumpAndSettle();

    expect(store.devices.length, 1);
    expect(store.deals.single.deviceId, Device.defaultId);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('日历页设备筛选：列表 / 合计按设备变，矮屏不溢出', (tester) async {
    // 模拟 MuMu 的 960x540 逻辑分辨率（物理 1920x1080 / dpr 2）。
    // 必须同时把 dpr 设为 1，否则 flutter_test 默认 dpr=3 会得到 320x180 逻辑尺寸。
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final tablet = (await store.addDevice('Tablet', defaultLabel: 'Phone'))!;
    final day = dayOnly(DateTime.now());
    await store.add(_deal(
      id: 'a',
      date: day,
      createdAt: day,
      title: '手机券',
      amount: 10,
    ));
    await store.add(_deal(
      id: 'b',
      date: day,
      createdAt: day,
      title: '平板券',
      deviceId: tablet.id,
      amount: 3,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarPage(),
        ),
      ),
    );
    // 若布局溢出，pumpAndSettle 会直接抛 RenderFlex 异常。
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('deviceFilter_all')), findsOneWidget);
    expect(find.text('手机券'), findsOneWidget);
    expect(find.text('平板券'), findsOneWidget);
    expect(find.text('Total ¥13.00'), findsOneWidget);

    await tester.tap(find.byKey(Key('deviceFilter_${tablet.id}')));
    await tester.pumpAndSettle();
    expect(find.text('平板券'), findsOneWidget);
    expect(find.text('手机券'), findsNothing);
    expect(find.text('Total ¥3.00'), findsOneWidget);

    final empty = (await store.addDevice('Watch', defaultLabel: 'Phone'))!;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('deviceFilter_${empty.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No deals on "Watch"'), findsOneWidget);
  });

  testWidgets('导入页可指定归入设备，导入后记录带该设备', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final source = FakeCalendarSource(
      events: <CalendarEventEntry>[
        _calendarEvent(
          id: 'e1',
          start: DateTime(2026, 11, 14, 10),
          end: DateTime(2026, 11, 14, 11),
        ),
      ],
    );
    final store = WoolStore(WoolRepository(prefs), calendarSource: source);
    final tablet = (await store.addDevice('Tablet', defaultLabel: 'Phone'))!;

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>(
        create: (_) => store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarImportPage(
            source: source,
            initialMonth: DateTime(2026, 11),
            now: DateTime(2026, 11, 14),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('importDevicePicker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('importDevicePicker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tablet').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('importExtractButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('双十一抢券'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import selected (1)'));
    await tester.pumpAndSettle();

    expect(store.deals.length, 1);
    expect(store.deals.single.deviceId, tablet.id);
  });

  group('自定义常用平台', () {
    test('首次用默认值初始化，增删改落盘，删光后不回退默认值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(
        WoolRepository(prefs),
        defaultPlatforms: kDefaultPlatformsZh,
      );
      expect(store.platforms, kDefaultPlatformsZh);

      expect(await store.addPlatform('盒马'), isTrue);
      expect(store.platforms.last, '盒马');
      expect(await store.addPlatform('盒马'), isFalse);
      expect(await store.addPlatform('   '), isFalse);

      expect(await store.renamePlatform('盒马', '盒马鲜生'), isTrue);
      expect(store.platforms.contains('盒马鲜生'), isTrue);
      // 与已有平台重名时拒绝
      expect(await store.renamePlatform('盒马鲜生', '京东'), isFalse);

      expect(await store.removePlatform('京东'), isTrue);
      expect(store.platforms.contains('京东'), isFalse);

      // 重新构造验证持久化
      final reloaded = WoolStore(WoolRepository(prefs));
      expect(reloaded.platforms, store.platforms);

      // 用户主动删光后，再次启动不应被默认值塞回来
      for (final name in List<String>.of(store.platforms)) {
        await store.removePlatform(name);
      }
      expect(store.platforms, isEmpty);
      final emptyReloaded = WoolStore(
        WoolRepository(prefs),
        defaultPlatforms: kDefaultPlatformsZh,
      );
      expect(emptyReloaded.platforms, isEmpty);
    });

    test('删除 / 重命名平台不改历史记录的 platform 字段', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(
        WoolRepository(prefs),
        defaultPlatforms: kDefaultPlatformsZh,
      );
      final day = DateTime(2026, 11, 16);
      await store.add(_deal(id: 'a', date: day, createdAt: day));

      await store.renamePlatform('京东', '京东商城');
      await store.removePlatform('京东商城');

      expect(store.deals.single.platform, '京东');
      expect(store.platforms, isNot(contains('京东')));
    });
  });

  group('同步合并', () {
    test('按 id 并集：远端新增、本机新增、同 id 取 updatedAt 较新的一方', () {
      final local = _snapshot(
        deals: <WoolDeal>[
          _syncDeal('a', DateTime(2026, 11, 10), title: '本地A'),
          _syncDeal('b', DateTime(2026, 11, 10), title: '本地B'),
        ],
        platforms: const <String>['京东'],
        platformsUpdatedAt: DateTime(2026, 11, 1),
      );
      final remote = _snapshot(
        deals: <WoolDeal>[
          _syncDeal('a', DateTime(2026, 11, 12), title: '远端A'),
          _syncDeal('c', DateTime(2026, 11, 12), title: '远端C'),
        ],
        devices: <Device>[
          Device.fallback,
          const Device(id: 'tab', name: '平板'),
        ],
        platforms: const <String>['京东', '拼多多'],
        platformsUpdatedAt: DateTime(2026, 11, 12),
      );

      final result = mergeSnapshots(local: local, remote: remote);
      final byId = <String, WoolDeal>{
        for (final deal in result.merged.deals) deal.id: deal,
      };

      expect(byId.keys.toSet(), <String>{'a', 'b', 'c'});
      expect(byId['a']!.title, '远端A');
      expect(byId['b']!.title, '本地B');
      expect(result.stats.remoteAdded, 1);
      expect(result.stats.localOnly, 1);
      expect(result.stats.conflicts, 1);
      expect(result.stats.deleted, 0);
      expect(result.merged.devices.any((d) => d.id == 'tab'), isTrue);
      expect(result.merged.platforms, <String>['京东', '拼多多']);
    });

    test('墓碑优先于旧副本；删除之后的新编辑会复活', () {
      final deletedAt = DateTime(2026, 11, 15);
      final local = _snapshot(
        deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 10))],
      );
      final remote = _snapshot(
        tombstones: <String, DateTime>{'a': deletedAt},
      );

      final killed = mergeSnapshots(local: local, remote: remote);
      expect(killed.merged.deals, isEmpty);
      expect(killed.stats.deleted, 1);
      expect(killed.merged.tombstones.containsKey('a'), isTrue);

      final edited = _snapshot(
        deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 16))],
      );
      final revived = mergeSnapshots(local: edited, remote: remote);
      expect(revived.merged.deals.single.id, 'a');
      expect(revived.stats.deleted, 0);
    });

    test('删掉的设备不会被云端那份并集回来，墓碑跟着一起上传', () {
      // 本机删了「平板」并留下墓碑；云端还留着它（设备是按 id 取并集的）。
      final local = _snapshot(
        devices: <Device>[Device.fallback],
        deviceTombstones: <String, DateTime>{'tab': DateTime(2026, 11, 16)},
      );
      final remote = _snapshot(
        devices: <Device>[
          Device.fallback,
          const Device(id: 'tab', name: '平板'),
        ],
      );

      final result = mergeSnapshots(local: local, remote: remote);
      expect(result.merged.devices.map((d) => d.id).toList(), <String>['default']);
      expect(result.merged.deviceTombstones.containsKey('tab'), isTrue);
    });

    test('默认设备不会被墓碑误删，过期墓碑会被清掉', () {
      final newish = DateTime(2026, 11, 16);
      final result = mergeSnapshots(
        local: _snapshot(
          deviceTombstones: <String, DateTime>{
            Device.defaultId: newish,
            // 一年前的墓碑该被清掉，否则文件无限膨胀。
            'old': DateTime(2025, 1, 1),
          },
        ),
        remote: _snapshot(devices: <Device>[Device.fallback]),
        now: DateTime(2026, 11, 16, 12),
      );
      expect(result.merged.devices.map((d) => d.id).toList(), <String>['default']);
      expect(result.merged.deviceTombstones.containsKey(Device.defaultId), isFalse);
      expect(result.merged.deviceTombstones.containsKey('old'), isFalse);
    });

    test('旧云端文件没有设备墓碑字段，照常解析', () {
      const raw = '{"app":"appforge-wool","schema":1,"deals":[],'
          '"devices":[{"id":"default","name":"","isDefault":true},'
          '{"id":"tab","name":"平板","isDefault":false}],"platforms":[]}';
      final snapshot = SyncSnapshot.decode(raw);
      expect(snapshot.deviceTombstones, isEmpty);
      expect(snapshot.devices.map((d) => d.id).toList(), <String>['default', 'tab']);
    });

    test('本机删除传到远端时单独计数，结果里不会显示「删除 0 条」', () {
      // 本机已记墓碑（删于 11-15），远端还留着 11-10 的旧副本。
      final local = _snapshot(
        tombstones: <String, DateTime>{'a': DateTime(2026, 11, 15)},
      );
      final remote = _snapshot(
        deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 10))],
      );

      final result = mergeSnapshots(local: local, remote: remote);
      expect(result.merged.deals, isEmpty);
      expect(result.stats.deleted, 0); // 本机本来就没有，不算「本机被删」
      expect(result.stats.remoteDeleted, 1);
      expect(result.stats.totalDeleted, 1);
      expect(result.stats.totalChanges, 1);
    });

    test('平台列表整份 LWW：谁更新用谁，删除才能传播', () {
      final remoteNewer = _snapshot(
        platforms: const <String>['淘宝'],
        platformsUpdatedAt: DateTime(2026, 11, 2),
      );
      final localOlder = _snapshot(
        platforms: const <String>['京东'],
        platformsUpdatedAt: DateTime(2026, 11, 1),
      );
      expect(
        mergeSnapshots(local: localOlder, remote: remoteNewer).merged.platforms,
        <String>['淘宝'],
      );

      final localEmptied = _snapshot(
        platforms: const <String>[],
        platformsUpdatedAt: DateTime(2026, 11, 3),
      );
      expect(
        mergeSnapshots(local: localEmptied, remote: remoteNewer)
            .merged
            .platforms,
        isEmpty,
      );
    });

    test('快照 encode / decode 往返，并能识别外来的 JSON 文件', () {
      final snapshot = _snapshot(
        deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 12))],
        devices: <Device>[
          Device.fallback,
          const Device(id: 'tab', name: '平板'),
        ],
        platforms: const <String>['京东', '抖音'],
        platformsUpdatedAt: DateTime(2026, 11, 12),
        tombstones: <String, DateTime>{'dead': DateTime(2026, 11, 11)},
      );

      final restored = SyncSnapshot.decode(snapshot.encode());
      expect(restored.deals.single.id, 'a');
      expect(restored.deals.single.updatedAt, snapshot.deals.single.updatedAt);
      expect(restored.platforms, <String>['京东', '抖音']);
      expect(restored.tombstones.containsKey('dead'), isTrue);
      expect(SyncSnapshot.looksLikeOurs(snapshot.encode()), isTrue);
      expect(SyncSnapshot.looksLikeOurs('{"hello":"world"}'), isFalse);
      expect(SyncSnapshot.looksLikeOurs('not json'), isFalse);
    });
  });

  group('同步服务', () {
    test('首次同步上传本机快照，第二次双向合并', () async {
      final transport = _FakeSyncTransport();
      final service = WoolSyncService(transport: transport);

      final first = await service.run(
        remotePath: 'appforge/wool-sync.json',
        local: _snapshot(
          deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 10))],
        ),
      );
      expect(first.remoteWasEmpty, isTrue);
      expect(transport.uploads, 1);
      expect(transport.stored, isNotNull);

      final second = await service.run(
        remotePath: 'appforge/wool-sync.json',
        local: _snapshot(
          deals: <WoolDeal>[_syncDeal('b', DateTime(2026, 11, 11))],
        ),
      );
      expect(
        second.snapshot.deals.map((d) => d.id).toSet(),
        <String>{'a', 'b'},
      );
      expect(second.stats.remoteAdded, 1);
      expect(second.remoteWasEmpty, isFalse);
    });

    test('删除设备后再同步一次，设备不会被云端并集回来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      final transport = _FakeSyncTransport();
      final service = WoolSyncService(transport: transport);
      const path = 'wool-sync.json';

      final tablet = await store.addDevice('平板', defaultLabel: '手机');
      expect(tablet, isNotNull);

      // 第一次同步：两台设备都推上云端。
      var outcome = await service.run(remotePath: path, local: store.syncSnapshot());
      await store.applySyncSnapshot(outcome.snapshot);
      expect(store.devices.map((d) => d.id), contains(tablet!.id));

      // 本机删除这台设备（名下没有记录，迁移 0 条）。
      expect(await store.removeDevice(tablet.id), 0);

      // 再同步一次：云端那份还留着「平板」，但绝不能并集回来。
      outcome = await service.run(remotePath: path, local: store.syncSnapshot());
      await store.applySyncSnapshot(outcome.snapshot);
      expect(store.devices.map((d) => d.id).toList(), <String>[Device.defaultId]);

      // 墓碑必须写进远端文件，否则下一轮同步又会被并集复活。
      final stored = SyncSnapshot.decode(transport.stored!);
      expect(stored.deviceTombstones.containsKey(tablet.id), isTrue);

      // 墓碑落了盘：换一个 Store 从磁盘重读，设备仍是删掉的状态。
      final reopened = WoolStore(WoolRepository(prefs));
      expect(reopened.devices.map((d) => d.id).toList(), <String>[Device.defaultId]);
    });

    test('设备在别处被删后，云端带回来的孤儿记录迁回默认设备', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));

      // 远端：设备「平板」已被删（有墓碑），但它名下的记录还在文件里。
      await store.applySyncSnapshot(
        _snapshot(
          deals: <WoolDeal>[
            _syncDeal('a', DateTime(2026, 11, 12)).copyWith(deviceId: 'tab'),
          ],
          devices: <Device>[Device.fallback],
          deviceTombstones: <String, DateTime>{'tab': DateTime(2026, 11, 16)},
        ),
      );

      // 不迁移的话这条记录会挂在一台不存在的设备上，任何筛选都点不到它。
      expect(store.deals.single.deviceId, Device.defaultId);
      expect(store.dealCountOf(Device.defaultId), 1);
    });

    test('识别出真身份后，云端老的 default 设备与记录不再变出幽灵设备', () {
      final local = _snapshot(
        devices: <Device>[
          const Device(
            id: 'dev-1a2b3c4d',
            name: 'Redmi K30 Pro',
            isDefault: true,
            autoNamed: true,
          ),
        ],
        deals: <WoolDeal>[
          _syncDeal('a', DateTime(2026, 11, 12))
              .copyWith(deviceId: 'dev-1a2b3c4d'),
        ],
        deviceTombstones: <String, DateTime>{
          Device.defaultId: DateTime(2026, 11, 16),
        },
      );
      final remote = _snapshot(
        devices: <Device>[
          Device.fallback,
          const Device(id: 'd1', name: '小米10s'),
        ],
        // 旧版本写的记录，还挂在共用的 default 上。
        deals: <WoolDeal>[_syncDeal('b', DateTime(2026, 11, 13))],
      );

      final result = mergeSnapshots(local: local, remote: remote);
      // 只剩本机与手动设备，老的 default 不再作为第三台设备出现。
      expect(
        result.merged.devices.map((d) => d.id).toList(),
        <String>['dev-1a2b3c4d', 'd1'],
      );
      expect(result.merged.devices.where((d) => d.isDefault).length, 1);
      // 老记录接到本机名下，不会变成谁都点不到的孤儿。
      expect(
        result.merged.deals.firstWhere((d) => d.id == 'b').deviceId,
        'dev-1a2b3c4d',
      );
      // 本机设备永远不会被墓碑删掉。
      expect(
        result.merged.deviceTombstones.containsKey('dev-1a2b3c4d'),
        isFalse,
      );
    });

    test('设备改名能同步过去，自动机型名不会顶掉用户起的名字', () {
      // 本机：刚识别出来，名字还是机型自动名。
      final local = _snapshot(
        devices: <Device>[
          const Device(
            id: 'dev-aaa',
            name: 'Redmi K30 Pro',
            isDefault: true,
            autoNamed: true,
          ),
        ],
      );
      // 另一台手机上用户把同一台改名成「主力机」后上传（autoNamed=false）。
      final remote = _snapshot(
        devices: <Device>[
          const Device(id: 'dev-aaa', name: '主力机', autoNamed: false),
        ],
      );

      final merged = mergeSnapshots(local: local, remote: remote).merged;
      final self = merged.devices.firstWhere((d) => d.id == 'dev-aaa');
      expect(self.name, '主力机');
      expect(self.autoNamed, isFalse);
      // 本机标记不能被远端带跑。
      expect(self.isDefault, isTrue);

      // 反方向：本机是用户命名，远端那份还是老的自动机型名 —— 保留本机的。
      final back = mergeSnapshots(
        local: _snapshot(
          devices: <Device>[
            const Device(
              id: 'dev-aaa',
              name: '主力机',
              isDefault: true,
              autoNamed: false,
            ),
          ],
        ),
        remote: local,
      ).merged;
      expect(back.devices.single.name, '主力机');
      expect(back.devices.single.autoNamed, isFalse);
    });

    test('两台手机各自识别后不会互相冒充，也不会出现两台「本机」', () {
      final phoneA = _snapshot(
        devices: <Device>[
          const Device(
            id: 'dev-aaa',
            name: 'Redmi K30 Pro',
            isDefault: true,
            autoNamed: true,
          ),
        ],
      );
      final phoneB = _snapshot(
        devices: <Device>[
          const Device(
            id: 'dev-bbb',
            name: 'Xiaomi 10S',
            isDefault: true,
            autoNamed: true,
          ),
        ],
      );

      final merged = mergeSnapshots(local: phoneA, remote: phoneB).merged;
      expect(
        merged.devices.map((d) => d.id).toList(),
        <String>['dev-aaa', 'dev-bbb'],
      );
      // 远端的 isDefault 只是它自己的本机标记，在本机不该生效。
      expect(
        merged.devices.where((d) => d.isDefault).map((d) => d.id).toList(),
        <String>['dev-aaa'],
      );
    });

    test('远端不是本 App 的文件时中止，绝不覆盖', () async {
      final transport = _FakeSyncTransport()..stored = '{"hello":"world"}';
      final service = WoolSyncService(transport: transport);

      await expectLater(
        service.run(remotePath: 'x/y.json', local: _snapshot()),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.unrecognized,
          ),
        ),
      );
      expect(transport.uploads, 0);
    });

    test('诊断：远端还没有文件时明确说「没有」', () async {
      final service = WoolSyncService(transport: _FakeSyncTransport());
      final info = await service.inspect(remotePath: 'x/y.json');
      expect(info.exists, isFalse);
      expect(info.recognized, isFalse);
      expect(info.deals, 0);
    });

    test('诊断：读得到云端条数、大小、生成时间与标题，且不写入', () async {
      final transport = _FakeSyncTransport();
      final service = WoolSyncService(transport: transport);
      await service.run(
        remotePath: 'x/y.json',
        local: _snapshot(
          deals: <WoolDeal>[
            _syncDeal('a', DateTime(2026, 11, 10)),
            _syncDeal('b', DateTime(2026, 11, 11)),
          ],
        ),
      );
      final uploadsAfterRun = transport.uploads;

      final info = await service.inspect(remotePath: 'x/y.json');
      expect(info.exists, isTrue);
      expect(info.recognized, isTrue);
      expect(info.deals, 2);
      expect(info.bytes, greaterThan(0));
      expect(info.generatedAt, isNotNull);
      expect(info.sampleTitles.length, 2);
      // 诊断是只读的：不能再传一次。
      expect(transport.uploads, uploadsAfterRun);
    });

    test('诊断：远端是别人的文件时标成「不认识」，别谎报成空', () async {
      final transport = _FakeSyncTransport()..stored = '{"hello":"world"}';
      final service = WoolSyncService(transport: transport);
      final info = await service.inspect(remotePath: 'x/y.json');
      expect(info.exists, isTrue);
      expect(info.recognized, isFalse);
      expect(info.bytes, greaterThan(0));
    });
  });

  group('每日备份', () {
    test('备份文件名：同目录、按日期，扩展名与中文目录都保留', () {
      final day = DateTime(2026, 11, 16);
      String path(String remote) => WoolSyncService.dailyBackupPath(remote, day);

      expect(path('yangmao/wool-sync.json'), 'yangmao/wool-sync-2026-11-16.json');
      expect(path('wool-sync.json'), 'wool-sync-2026-11-16.json');
      expect(
        path('团队文件-webdav/yangmao/wool-sync.json'),
        '团队文件-webdav/yangmao/wool-sync-2026-11-16.json',
      );
      // 没有扩展名就挂在末尾，不要凭空造一个 .json
      expect(path('appforge/sync'), 'appforge/sync-2026-11-16');
      // 尾部多余斜杠要吃掉，别生成 a/b/-2026-11-16.json
      expect(path('appforge/wool-sync.json/'), 'appforge/wool-sync-2026-11-16.json');
    });

    test('按本地日历日判断：同一天只备份一次，跨天再备份', () {
      expect(WoolSyncService.needsDailyBackup(null, DateTime(2026, 11, 16, 0, 1)),
          isTrue);
      expect(
        WoolSyncService.needsDailyBackup(
          DateTime(2026, 11, 16, 7, 30),
          DateTime(2026, 11, 16, 23, 59),
        ),
        isFalse,
      );
      expect(
        WoolSyncService.needsDailyBackup(
          DateTime(2026, 11, 16, 23, 59),
          DateTime(2026, 11, 17, 0, 1),
        ),
        isTrue,
      );
    });

    test('备份的是云端那一份，且不碰原文件', () async {
      const original = '{"app":"appforge-wool","deals":[]}';
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json'
        ..stored = original;
      final service = WoolSyncService(transport: transport);

      final path = await service.backupRemote(
        remotePath: 'yangmao/wool-sync.json',
        day: DateTime(2026, 11, 16),
      );

      expect(path, 'yangmao/wool-sync-2026-11-16.json');
      expect(transport.uploaded[path!], original);
      expect(transport.stored, original, reason: '备份不能改动原文件内容');
    });

    test('云端还没有文件时不做备份，也不上传空文件', () async {
      final transport = _FakeSyncTransport();
      final service = WoolSyncService(transport: transport);
      final path = await service.backupRemote(
        remotePath: 'yangmao/wool-sync.json',
        day: DateTime(2026, 11, 16),
      );
      expect(path, isNull);
      expect(transport.uploads, 0);
    });
  });

  group('每日备份接入同步流程', () {
    /// 起一套内存环境的同步控制器：远端固定 `yangmao/wool-sync.json`。
    Future<(SyncController, _FakeSyncTransport)> boot() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json';
      final controller = SyncController(
        store: store,
        settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
        transportFactory: (_) => transport,
      );
      await controller.load();
      await controller.save(
        const SyncSettings(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'me',
          password: 'p',
          remotePath: 'yangmao/wool-sync.json',
        ),
      );
      return (controller, transport);
    }

    test('同步前先把云端那份写成按日期的备份文件', () async {
      final (controller, transport) = await boot();
      const original = '{"app":"appforge-wool","deals":[]}';
      transport.stored = original;

      await controller.syncNow();

      expect(controller.hasError, isFalse);
      final backupPath = controller.backupPath;
      expect(backupPath, isNotNull);
      expect(backupPath, startsWith('yangmao/wool-sync-'));
      expect(backupPath, endsWith('.json'));
      expect(transport.uploaded[backupPath], original);
    });

    test('同一天再同步不会重复备份', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      await controller.syncNow();
      final firstBackup = controller.backupPath;
      expect(firstBackup, isNotNull);

      await controller.syncNow();

      expect(controller.hasError, isFalse);
      expect(controller.backupPath, isNull, reason: '今天已经备份过');
      // 提示条要留在界面上，否则用户看不出今天到底备份了没。
      expect(controller.backupPathToday, firstBackup);
      final backupWrites = transport.uploaded.keys
          .where((key) => key != 'yangmao/wool-sync.json')
          .toList();
      expect(backupWrites, <String>[firstBackup!]);
    });

    test('备份失败就中止同步，云端主文件一个字节都不动', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      transport.uploadError =
          const SyncException(SyncFailure.server, statusCode: 507);

      await controller.syncNow();

      expect(controller.failure, SyncFailure.backupFailed);
      expect(transport.uploaded.containsKey('yangmao/wool-sync.json'), isFalse);
      expect(controller.lastSyncAt, isNull, reason: '没同步就不该记同步时间');
    });

    test('关掉每日备份开关后不再写备份文件', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      await controller.save(controller.settings.copyWith(dailyBackup: false));

      await controller.syncNow();

      expect(controller.hasError, isFalse);
      expect(controller.backupPath, isNull);
      expect(
        transport.uploaded.keys.where((k) => k != 'yangmao/wool-sync.json'),
        isEmpty,
      );
    });

    test('保留最近 3 份：同步后删掉更旧的备份，最近的 3 份留下', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      transport.tree = <String, List<RemoteEntry>>{
        'yangmao': <RemoteEntry>[
          const RemoteEntry(name: 'wool-sync.json', isCollection: false),
          const RemoteEntry(name: 'wool-sync-2026-11-10.json', isCollection: false),
          const RemoteEntry(name: 'wool-sync-2026-11-11.json', isCollection: false),
          const RemoteEntry(name: 'wool-sync-2026-11-12.json', isCollection: false),
          const RemoteEntry(name: 'wool-sync-2026-11-13.json', isCollection: false),
          const RemoteEntry(name: 'wool-sync-2026-11-14.json', isCollection: false),
        ],
      };
      await controller.save(
        controller.settings.copyWith(backupKeep: 3),
      );

      await controller.syncNow();

      expect(controller.hasError, isFalse);
      // 新的在前：14 / 13 / 12 留下，11 与 10 删掉。
      expect(transport.deleted, <String>[
        'yangmao/wool-sync-2026-11-11.json',
        'yangmao/wool-sync-2026-11-10.json',
      ]);
      expect(controller.prunedBackups, 2);
      expect(
        transport.deleted,
        isNot(contains('yangmao/wool-sync.json')),
        reason: '主文件永远不能被清理逻辑碰到',
      );
    });

    test('保留份数设为不限时不发任何 DELETE', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      transport.tree = <String, List<RemoteEntry>>{
        'yangmao': <RemoteEntry>[
          for (var day = 1; day <= 10; day++)
            RemoteEntry(
              name: 'wool-sync-2026-11-${day.toString().padLeft(2, '0')}.json',
              isCollection: false,
            ),
        ],
      };
      await controller.save(
        controller.settings.copyWith(
          backupKeep: SyncSettings.unlimitedBackupKeep,
        ),
      );

      await controller.syncNow();

      expect(controller.hasError, isFalse);
      expect(transport.deleted, isEmpty);
      expect(controller.prunedBackups, 0);
    });

    test('服务器不支持 DELETE 时同步仍然算成功，只是不报清理数', () async {
      final (controller, transport) = await boot();
      transport.stored = '{"app":"appforge-wool","deals":[]}';
      transport.tree = <String, List<RemoteEntry>>{
        'yangmao': <RemoteEntry>[
          for (var day = 1; day <= 6; day++)
            RemoteEntry(
              name: 'wool-sync-2026-11-${day.toString().padLeft(2, '0')}.json',
              isCollection: false,
            ),
        ],
      };
      transport.deleteError =
          const SyncException(SyncFailure.notWebDav, statusCode: 405);
      await controller.save(controller.settings.copyWith(backupKeep: 3));

      await controller.syncNow();

      // 删旧备份是顺带动作：服务器不回 405 也不该让一次成功的同步变红。
      expect(controller.hasError, isFalse);
      expect(controller.lastSyncAt, isNotNull);
      expect(controller.prunedBackups, 0);
      expect(transport.uploaded.containsKey('yangmao/wool-sync.json'), isTrue);
    });
  });

  group('备份恢复', () {
    test('安全副本命名：同目录、带时分，不与每日备份撞名', () {
      final at = DateTime(2026, 11, 16, 14, 32);

      expect(
        WoolSyncService.safetyBackupPath('yangmao/wool-sync.json', at),
        'yangmao/wool-sync-2026-11-16-1432.json',
      );
      expect(
        WoolSyncService.safetyBackupPath('团队文件-webdav/wool-sync.json', at),
        '团队文件-webdav/wool-sync-2026-11-16-1432.json',
      );
      // 顶掉当天那份每日备份就等于毁掉退路，两者必须不同名。
      expect(
        WoolSyncService.safetyBackupPath('a/b.json', at),
        isNot(WoolSyncService.dailyBackupPath('a/b.json', at)),
      );
    });

    test('识别备份文件名：主文件、无关文件、非法日期都不算', () {
      const remote = 'yangmao/wool-sync.json';
      RemoteBackup? parse(String name) =>
          WoolSyncService.parseBackupName(remote, name);

      final daily = parse('wool-sync-2026-11-16.json');
      expect(daily?.day, DateTime(2026, 11, 16));
      expect(daily?.path, 'yangmao/wool-sync-2026-11-16.json');
      expect(daily?.isSafetyCopy, isFalse);

      final safety = parse('wool-sync-2026-11-16-1432.json');
      expect(safety?.isSafetyCopy, isTrue);
      expect(safety?.at, DateTime(2026, 11, 16, 14, 32));

      expect(parse('wool-sync.json'), isNull, reason: '主文件自己不是备份');
      expect(parse('wool-sync-notes.json'), isNull);
      expect(parse('hiker-2026-11-16.json'), isNull);
      expect(parse('wool-sync-2026-02-31.json'), isNull, reason: '2 月没有 31 号');
      expect(parse('wool-sync-2026-11-16.txt'), isNull);
    });

    test('列出备份：跳过目录与非备份，新的在前，只 PROPFIND 一次', () async {
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json'
        ..tree = <String, List<RemoteEntry>>{
          'yangmao': const <RemoteEntry>[
            RemoteEntry(name: 'wool-sync.json', isCollection: false),
            RemoteEntry(name: 'wool-sync-2026-11-14.json', isCollection: false),
            RemoteEntry(name: 'wool-sync-2026-11-16.json', isCollection: false),
            RemoteEntry(
                name: 'wool-sync-2026-11-16-1432.json', isCollection: false),
            RemoteEntry(name: 'hiker', isCollection: true),
          ],
        };
      final service = WoolSyncService(transport: transport);

      final backups =
          await service.listBackups(remotePath: 'yangmao/wool-sync.json');

      expect(
        backups.map((b) => b.name),
        <String>[
          'wool-sync-2026-11-16.json',
          'wool-sync-2026-11-16-1432.json',
          'wool-sync-2026-11-14.json',
        ],
      );
      expect(transport.listed, <String>['yangmao']);
      expect(transport.downloads, 0, reason: '列目录不该逐个下载');
    });

    test('恢复：读备份 → 存恢复前快照 → 最后才覆盖主文件', () async {
      const original = '{"app":"appforge-wool","deals":[]}';
      final backup = _snapshot(
        deals: <WoolDeal>[_syncDeal('a', DateTime(2026, 11, 10))],
      );
      // encode() 每次都写新的 generatedAt，先编一次再比对，否则比的是时间戳。
      final backupJson = backup.encode();
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json'
        ..stored = original
        ..files['yangmao/wool-sync-2026-11-14.json'] = backupJson;
      final service = WoolSyncService(transport: transport);

      final outcome = await service.restore(
        remotePath: 'yangmao/wool-sync.json',
        backupPath: 'yangmao/wool-sync-2026-11-14.json',
        at: DateTime(2026, 11, 16, 14, 32),
      );

      expect(outcome.snapshot.deals.single.id, 'a');
      expect(outcome.safetyPath, 'yangmao/wool-sync-2026-11-16-1432.json');
      expect(transport.uploaded[outcome.safetyPath], original);
      // 写回主文件的是「重新编码的快照」（generatedAt 会变），比对内容而不是字节。
      final written = transport.uploaded['yangmao/wool-sync.json'];
      expect(written, isNotNull);
      expect(SyncSnapshot.decode(written!).deals.single.id, 'a');
      expect(transport.stored, written);
    });

    test('备份不是本 App 格式时中止：一个字节都不写', () async {
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json'
        ..stored = '{"app":"appforge-wool","deals":[]}'
        ..files['yangmao/wool-sync-2026-11-14.json'] = '{"hello":"world"}';
      final service = WoolSyncService(transport: transport);

      await expectLater(
        service.restore(
          remotePath: 'yangmao/wool-sync.json',
          backupPath: 'yangmao/wool-sync-2026-11-14.json',
          at: DateTime(2026, 11, 16, 14, 32),
        ),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.unrecognized),
        ),
      );
      expect(transport.uploaded, isEmpty);
    });

    test('备份读不到内容时中止，绝不拿空内容覆盖云端', () async {
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json'
        ..stored = '{"app":"appforge-wool","deals":[]}';
      final service = WoolSyncService(transport: transport);

      await expectLater(
        service.restore(
          remotePath: 'yangmao/wool-sync.json',
          backupPath: 'yangmao/wool-sync-2026-11-14.json',
          at: DateTime(2026, 11, 16, 14, 32),
        ),
        throwsA(isA<SyncException>()),
      );
      expect(transport.uploaded, isEmpty);
    });
  });

  group('恢复接入控制器', () {
    Future<(SyncController, WoolStore, _FakeSyncTransport)> boot() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = WoolStore(WoolRepository(prefs));
      final transport = _FakeSyncTransport()
        ..mainPath = 'yangmao/wool-sync.json';
      final controller = SyncController(
        store: store,
        settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
        transportFactory: (_) => transport,
      );
      await controller.load();
      await controller.save(
        const SyncSettings(
          baseUrl: 'https://dav.example.com/dav/',
          username: 'me',
          password: 'p',
          remotePath: 'yangmao/wool-sync.json',
        ),
      );
      return (controller, store, transport);
    }

    test('恢复是替换而不是合并：备份之后新增的记录会被清掉', () async {
      final (controller, store, transport) = await boot();
      await store.add(_syncDeal('old', DateTime(2026, 11, 2)));
      transport.stored = _snapshot(
        deals: <WoolDeal>[
          _syncDeal('old', DateTime(2026, 11, 2)),
          _syncDeal('new', DateTime(2026, 11, 15)),
        ],
      ).encode();
      transport.files['yangmao/wool-sync-2026-11-10.json'] = _snapshot(
        deals: <WoolDeal>[_syncDeal('old', DateTime(2026, 11, 2))],
      ).encode();

      final outcome = await controller.restoreBackup(
        'yangmao/wool-sync-2026-11-10.json',
        at: DateTime(2026, 11, 16, 14, 32),
      );

      expect(controller.hasError, isFalse);
      expect(store.deals.map((d) => d.id), <String>['old']);
      expect(outcome.safetyPath, isNotNull);
      expect(controller.lastSyncAt, DateTime(2026, 11, 16, 14, 32));
      expect(controller.stats, isNull, reason: '恢复不是合并，别留旧计数');
    });

    test('恢复失败时本机数据原封不动', () async {
      final (controller, store, transport) = await boot();
      await store.add(_syncDeal('keep', DateTime(2026, 11, 2)));
      transport.files['yangmao/wool-sync-2026-11-10.json'] = '{"hello":"world"}';

      await expectLater(
        controller.restoreBackup('yangmao/wool-sync-2026-11-10.json'),
        throwsA(isA<SyncException>()),
      );
      expect(controller.failure, SyncFailure.unrecognized);
      expect(store.deals.map((d) => d.id), <String>['keep']);
    });
  });

  group('WebDAV 客户端', () {
    WebDavTransport build(
      List<RequestOptions> log,
      int Function(RequestOptions options) status, {
      String body = '',
      String Function(RequestOptions options)? bodyBuilder,
    }) {
      final dio = Dio();
      dio.httpClientAdapter = _FakeDioAdapter((options) async {
        log.add(options);
        return ResponseBody.fromString(
          bodyBuilder?.call(options) ?? body,
          status(options),
        );
      });
      return WebDavTransport(
        baseUrl: 'https://dav.example.com/dav/',
        username: 'u',
        password: 'p',
        dio: dio,
      );
    }

    test('download：404 视为首次同步，401 抛认证错误', () async {
      final missing = build(<RequestOptions>[], (_) => 404);
      expect(await missing.download('a/b.json'), isNull);

      final unauthorized = build(<RequestOptions>[], (_) => 401);
      await expectLater(
        unauthorized.download('a/b.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.auth),
        ),
      );
    });

    test('ensureDirectory 逐级 MKCOL，405 且目录确实存在时放过', () async {
      final log = <RequestOptions>[];
      // MKCOL 405 + PROPFIND 207 = RFC 4918 的「集合已存在」。
      final transport = build(
        log,
        (options) => options.method == 'MKCOL' ? 405 : 207,
      );
      await transport.ensureDirectory('appforge/sub/wool.json');

      expect(
        log.where((o) => o.method == 'MKCOL').map((o) => o.uri.toString()),
        <String>[
          'https://dav.example.com/dav/appforge',
          'https://dav.example.com/dav/appforge/sub',
        ],
      );
      // 405 之后必须用 PROPFIND 确认目录真存在，不能盲信状态码：
      // 飞牛 fnOS 把「不许建目录」也回成 405。
      expect(log.where((o) => o.method == 'PROPFIND').length, 2);
    });

    test('upload 带 Basic Auth，默认 JSON 内容类型', () async {
      final log = <RequestOptions>[];
      final transport = build(log, (_) => 201);
      await transport.upload('appforge/wool.json', '{"app":"appforge-wool"}');

      expect(log.single.method, 'PUT');
      expect(log.single.headers['Authorization'], startsWith('Basic '));
      expect(log.single.data, '{"app":"appforge-wool"}');
    });

    test('delete 发 DELETE 动词；404 视为已删掉，405 报地址问题', () async {
      final log = <RequestOptions>[];
      final transport = build(log, (_) => 204);
      await transport.delete('yangmao/wool-sync-2026-11-10.json');

      expect(log.single.method, 'DELETE');
      expect(
        log.single.path,
        contains('yangmao/wool-sync-2026-11-10.json'),
      );
      expect(log.single.headers['Authorization'], startsWith('Basic '));

      // 文件已经不在了 = 清理目的已达成，不该让同步因此报错。
      await build(<RequestOptions>[], (_) => 404)
          .delete('yangmao/wool-sync-2026-11-10.json');

      await expectLater(
        build(<RequestOptions>[], (_) => 405).delete('a/b.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.notWebDav),
        ),
      );
    });

    test('probe 用 PROPFIND + Depth:0，403 抛无权限', () async {
      final log = <RequestOptions>[];
      final transport = build(log, (_) => 207);
      await transport.probe('appforge/wool.json');

      expect(log.single.method, 'PROPFIND');
      expect(log.single.headers['Depth'], '0');

      final forbidden = build(<RequestOptions>[], (_) => 403);
      await expectLater(
        forbidden.probe('a.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.forbidden),
        ),
      );
    });

    test('405 归为「地址不是 WebDAV 端点」，详情带动词、地址与服务器原话', () async {
      final transport =
          build(<RequestOptions>[], (_) => 405, body: 'Method Not Allowed');

      await expectLater(
        transport.download('yangmao/wool-sync.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.notWebDav)
              .having((e) => e.statusCode, 'status', 405)
              .having(
                (e) => e.detail,
                'detail',
                contains(
                  'GET https://dav.example.com/dav/yangmao/wool-sync.json → 405',
                ),
              )
              .having((e) => e.detail, 'server body',
                  contains('Method Not Allowed')),
        ),
      );
    });

    test('PUT 被拒（405）同样指向地址问题，而不是笼统的服务器错误', () async {
      final transport = build(<RequestOptions>[], (_) => 405);

      await expectLater(
        transport.upload('yangmao/wool-sync.json', '{}'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.notWebDav)
              .having((e) => e.detail, 'detail', contains('PUT ')),
        ),
      );
    });

    test('GET 被拒（405）但 PROPFIND 说文件不存在：按首次同步继续', () async {
      final transport = build(
        <RequestOptions>[],
        (options) => options.method == 'GET' ? 405 : 404,
      );

      expect(await transport.download('yangmao/wool-sync.json'), isNull);
    });

    test('GET 被拒（405）而路径其实是文件夹：单独报「请补文件名」', () async {
      const collection = '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/yangmao/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response></D:multistatus>';
      final transport = build(
        <RequestOptions>[],
        (options) => options.method == 'GET' ? 405 : 207,
        bodyBuilder: (options) => options.method == 'GET' ? '' : collection,
      );

      await expectLater(
        transport.download('yangmao'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.pathIsFolder)
              .having((e) => e.detail, 'detail', contains('这是文件夹')),
        ),
      );
    });

    test('MKCOL 被禁且目录不存在（飞牛 fnOS）：报「请手动建目录」并列出上级内容', () async {
      // 根目录下真实存在的是 /团队文件-dav/，用户却填了 webdav/ —— 这正是
      // 飞牛上最常见的路径错法，错误提示必须直接把真实目录名列出来。
      const rootListing = '<?xml version="1.0" encoding="utf-8"?>'
          '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/dav/%E5%9B%A2%E9%98%9F%E6%96%87%E4%BB%B6-dav/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/personal/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '</D:multistatus>';

      final transport = build(
        <RequestOptions>[],
        (options) {
          if (options.method == 'MKCOL') return 405;
          // Depth:1 的列目录请求要成功，才能证明「上级目录现有」有内容可写。
          return options.headers['Depth'] == '1' ? 207 : 404;
        },
        bodyBuilder: (options) =>
            options.headers['Depth'] == '1' ? rootListing : '',
      );

      await expectLater(
        transport.ensureDirectory('webdav/yangmao/wool-sync.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.mkdirUnsupported)
              .having((e) => e.detail, 'detail', contains('MKCOL'))
              .having((e) => e.detail, 'detail', contains('上级目录现有'))
              .having(
                (e) => e.detail,
                'detail',
                contains('团队文件-dav/'),
              ),
        ),
      );
    });

    test('集合只认带斜杠的服务器：404 后补斜杠重试，别把已有目录判成不存在', () async {
      final log = <RequestOptions>[];
      final transport = build(
        log,
        (options) {
          if (options.method == 'MKCOL') return 405;
          // 只有带末尾斜杠的集合地址才认（飞牛 fnOS 的行为）。
          return options.uri.path.endsWith('/') ? 207 : 404;
        },
        bodyBuilder: (options) => options.uri.path.endsWith('/')
            ? '<D:multistatus xmlns:D="DAV:"><D:response>'
                '<D:href>/dav/appforge/</D:href><D:propstat><D:prop>'
                '<D:resourcetype><D:collection/></D:resourcetype>'
                '</D:prop></D:propstat></D:response></D:multistatus>'
            : '',
      );

      // 目录其实存在 → 不应抛 mkdirUnsupported。
      await transport.ensureDirectory('appforge/wool.json');
      expect(
        log.any((o) => o.uri.path.endsWith('/appforge/')),
        isTrue,
      );
    });

    test('list 解析 multistatus：剥根前缀、区分文件夹与文件、解码中文名', () async {
      final log = <RequestOptions>[];
      const xml = '<?xml version="1.0" encoding="utf-8"?>'
          '<D:multistatus xmlns:D="DAV:">'
          // 目录自身：必须被排除
          '<D:response><D:href>/dav/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/%E5%9B%A2%E9%98%9F%E6%96%87%E4%BB%B6-dav/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/appforge/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/notes.txt</D:href><D:propstat><D:prop>'
          '<D:resourcetype/></D:prop></D:propstat></D:response>'
          '</D:multistatus>';

      final transport = build(log, (_) => 207, body: xml);
      final entries = await transport.list('');

      expect(log.single.method, 'PROPFIND');
      expect(log.single.headers['Depth'], '1');
      // 文件夹排前面（按名排序），文件排后面。
      expect(
        entries.map((e) => e.name).toList(),
        <String>['appforge', '团队文件-dav', 'notes.txt'],
      );
      expect(entries.where((e) => e.isCollection).length, 2);
      expect(entries.last.isCollection, isFalse);
    });

    test('list 在子目录下只返回这一层的子项', () async {
      const xml = '<D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/dav/webdav/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/webdav/yangmao/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '<D:response><D:href>/dav/webdav/yangmao/deep/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
          '</D:prop></D:propstat></D:response>'
          '</D:multistatus>';

      final transport = build(<RequestOptions>[], (_) => 207, body: xml);
      final entries = await transport.list('webdav');

      // 自身与更深层都不能出现，只留直接子目录。
      expect(entries.map((e) => e.name).toList(), <String>['yangmao']);
    });

    test('list 401 抛认证错误', () async {
      final transport = build(<RequestOptions>[], (_) => 401);
      await expectLater(
        transport.list(''),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.auth),
        ),
      );
    });

    test('GET 被拒（405）而文件其实存在：中止，绝不上传覆盖远端', () async {
      final transport = build(
        <RequestOptions>[],
        (options) => options.method == 'GET' ? 405 : 207,
      );

      await expectLater(
        transport.download('yangmao/wool-sync.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.notWebDav),
        ),
      );
    });

    test('probe 遇到 405 会探同主机端点，并把可用地址写进提示', () async {
      final log = <RequestOptions>[];
      // 根地址是网页服务，只有 /dav/ 子路径才是真正的 WebDAV。
      final transport = build(
        log,
        (options) => options.uri.path == '/dav/dav/' ? 207 : 405,
      );

      await expectLater(
        transport.probe('yangmao/wool-sync.json'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.notWebDav)
              .having(
                (e) => e.detail,
                'detail',
                contains('可用地址：https://dav.example.com/dav/dav/'),
              ),
        ),
      );
      expect(log.map((o) => o.method).toSet(), <String>{'PROPFIND'});
    });
  });

  testWidgets('平台管理页可新增、拦截重名、删除，且不改历史记录', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(
      WoolRepository(prefs),
      defaultPlatforms: kDefaultPlatformsEn,
    );
    final day = DateTime(2026, 11, 16);
    await store.add(_deal(id: 'a', date: day, createdAt: day));

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>.value(
        value: store,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlatformSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('addPlatformAction')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('platformNameField')), 'Hema');
    await tester.tap(find.byKey(const Key('platformNameConfirm')));
    await tester.pumpAndSettle();
    expect(store.platforms, contains('Hema'));

    // 重名：对话框不关闭，给出提示
    await tester.tap(find.byKey(const Key('addPlatformAction')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('platformNameField')), 'Hema');
    await tester.tap(find.byKey(const Key('platformNameConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('This platform already exists'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // 删除 JD：只影响快捷词
    await tester.tap(find.byKey(const Key('platformMenu_JD')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete platform').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platformDeleteConfirm')));
    await tester.pumpAndSettle();

    expect(store.platforms, isNot(contains('JD')));
    expect(store.deals.single.platform, '京东');
  });

  testWidgets('同步设置页拦截空地址，填好后能保存并同步本机记录', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final transport = _FakeSyncTransport();
    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => transport,
    );
    await controller.load();

    final day = DateTime(2026, 11, 16);
    await store.add(_deal(id: 'a', date: day, createdAt: day));

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('syncSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the server URL'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('syncBaseUrlField')),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.byKey(const Key('syncUsernameField')), 'me');
    await tester.enterText(
        find.byKey(const Key('syncPasswordField')), 'secret');
    await tester.tap(find.byKey(const Key('syncSaveButton')));
    await tester.pumpAndSettle();
    expect(controller.settings.baseUrl, 'https://dav.example.com/dav/');
    expect(controller.settings.password, 'secret');

    await tester.tap(find.byKey(const Key('syncNowButton')));
    await tester.pumpAndSettle();
    expect(transport.uploads, 1);
    expect(controller.hasError, isFalse);
    expect(controller.stats!.localOnly, 1);
    expect(store.deals.length, 1);
  });

  testWidgets('同步页的「立即同步」钉在屏幕底部，不用往下翻', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => _FakeSyncTransport(),
    );
    await controller.load();

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final screen =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final button = find.byKey(const Key('syncNowButton'));
    expect(button, findsOneWidget);
    // 首屏就该在屏幕下部：以前它在列表末尾，要一路翻下去。
    final top = tester.getRect(button).top;
    expect(top, greaterThan(screen * 0.7));

    // 表单滚到底，按钮原地不动。
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(tester.getRect(button).top, closeTo(top, 0.5));
  });

  testWidgets('备份保留份数可以选「不限」并保存，关掉备份后选项消失', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => _FakeSyncTransport(),
    );
    await controller.load();
    await controller.save(
      const SyncSettings(
        baseUrl: 'https://dav.example.com/dav/',
        username: 'me',
        password: 'secret',
        remotePath: 'yangmao/wool-sync.json',
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认是 7 份，不是「不限」：一年 365 个备份文件没人挑得动。
    expect(find.text('7 backups'), findsOneWidget);

    final field = find.byKey(const Key('syncBackupKeepField'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlimited (never delete)').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('syncSaveButton')));
    await tester.pumpAndSettle();

    expect(controller.settings.backupKeep, SyncSettings.unlimitedBackupKeep);
    expect(controller.settings.keepsUnlimitedBackups, isTrue);

    // 关掉每日备份后这个选项必须消失：不再写备份，就没有「保留几份」可言。
    await tester.tap(find.byKey(const Key('syncBackupSwitch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('syncBackupKeepField')), findsNothing);
  });

  testWidgets('主界面下拉即同步，不必先进设置页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final transport = _FakeSyncTransport();
    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => transport,
    );
    await controller.load();
    await controller.save(
      const SyncSettings(
        baseUrl: 'https://dav.example.com/dav/',
        username: 'me',
        password: 'secret',
        remotePath: 'yangmao/wool-sync.json',
      ),
    );

    final day = DateTime(2026, 11, 16);
    await store.add(_deal(id: 'a', date: day, createdAt: day));
    store.selectDay(day);

    await tester.pumpWidget(
      ChangeNotifierProvider<WoolStore>.value(
        value: store,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CalendarPage(syncController: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(find.byType(ListView).first, const Offset(0, 320), 1200);
    await tester.pumpAndSettle();

    expect(transport.uploads, 1);
    expect(controller.hasError, isFalse);
    // 同步结果要当场说出来，不能只留个「转一圈就没了」。
    expect(find.textContaining('Sync complete'), findsOneWidget);
  });

  testWidgets('同步设置页可浏览远端文件夹，选中后自动补好文件路径', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final transport = _FakeSyncTransport()
      ..tree = <String, List<RemoteEntry>>{
        '': <RemoteEntry>[
          const RemoteEntry(name: 'TeamFiles', isCollection: true),
          const RemoteEntry(name: 'readme.txt', isCollection: false),
        ],
        'TeamFiles': <RemoteEntry>[
          const RemoteEntry(name: 'yangmao', isCollection: true),
        ],
      };
    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => transport,
    );
    await controller.load();

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('syncBaseUrlField')),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.byKey(const Key('syncUsernameField')), 'me');
    await tester.enterText(
        find.byKey(const Key('syncPasswordField')), 'secret');
    // 清空远端路径，浏览从根目录开始
    await tester.enterText(find.byKey(const Key('syncRemotePathField')), '');

    await tester.tap(find.byKey(const Key('syncBrowseButton')));
    await tester.pumpAndSettle();

    expect(find.text('Pick a remote folder'), findsOneWidget);
    expect(find.text('TeamFiles'), findsOneWidget);
    expect(find.text('readme.txt'), findsOneWidget);
    // 文件不可点进（点了也没意义），只有文件夹能下钻
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text('TeamFiles'));
    await tester.pumpAndSettle();
    expect(find.text('yangmao'), findsOneWidget);

    await tester.tap(find.text('yangmao'));
    await tester.pumpAndSettle();
    expect(find.text('No subfolders here'), findsOneWidget);

    await tester.tap(find.byKey(const Key('syncBrowseUse')));
    await tester.pumpAndSettle();

    expect(
      find.text('TeamFiles/yangmao/wool-sync.json'),
      findsOneWidget,
    );
    expect(transport.listed, <String>['', 'TeamFiles', 'TeamFiles/yangmao']);
  });

  testWidgets('恢复备份：选备份 → 确认 → 本机被替换成备份内容', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final store = WoolStore(WoolRepository(prefs));
    final day = DateTime(2026, 11, 16);
    await store.add(_deal(id: 'now', date: day, createdAt: day));

    final transport = _FakeSyncTransport()
      ..mainPath = 'yangmao/wool-sync.json'
      ..tree = <String, List<RemoteEntry>>{
        'yangmao': const <RemoteEntry>[
          RemoteEntry(name: 'wool-sync.json', isCollection: false),
          RemoteEntry(name: 'wool-sync-2026-11-10.json', isCollection: false),
        ],
      };
    transport.stored = _snapshot(
      deals: <WoolDeal>[_syncDeal('now', DateTime(2026, 11, 16))],
    ).encode();
    transport.files['yangmao/wool-sync-2026-11-10.json'] = _snapshot(
      deals: <WoolDeal>[_syncDeal('old', DateTime(2026, 11, 10))],
    ).encode();

    final controller = SyncController(
      store: store,
      settingsStore: SyncSettingsStore(prefs, MemorySecretStore()),
      transportFactory: (_) => transport,
    );
    await controller.load();
    await controller.save(
      const SyncSettings(
        baseUrl: 'https://dav.example.com/dav/',
        username: 'me',
        password: 'p',
        remotePath: 'yangmao/wool-sync.json',
        dailyBackup: false,
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncController>.value(
        value: controller,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('syncRestoreButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('syncRestoreButton')));
    await tester.pumpAndSettle();

    // 只列出备份，主文件自己不出现
    expect(find.byKey(const Key('backupItem_0')), findsOneWidget);
    expect(find.byKey(const Key('backupItem_1')), findsNothing);
    expect(find.text('2026-11-10'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backupItem_0')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite this device with this backup?'), findsOneWidget);
    // 确认框要把「备份几条 / 本机几条」摊开
    expect(find.textContaining('1 deals in the backup'), findsOneWidget);
    expect(find.textContaining('1 on this device now'), findsOneWidget);

    await tester.tap(find.byKey(const Key('syncRestoreConfirm')));
    await tester.pumpAndSettle();

    expect(store.deals.map((d) => d.id), <String>['old']);
    expect(transport.uploads, 2, reason: '恢复前快照 + 覆盖主文件');
  });
}

WoolDeal _syncDeal(
  String id,
  DateTime updatedAt, {
  String title = '券',
}) =>
    WoolDeal(
      id: id,
      platform: '京东',
      title: title,
      date: DateTime(2026, 11, 16),
      createdAt: DateTime(2026, 11, 1),
      updatedAt: updatedAt,
    );

SyncSnapshot _snapshot({
  List<WoolDeal> deals = const <WoolDeal>[],
  List<Device> devices = const <Device>[Device.fallback],
  List<String> platforms = const <String>[],
  DateTime? platformsUpdatedAt,
  Map<String, DateTime> tombstones = const <String, DateTime>{},
  Map<String, DateTime> deviceTombstones = const <String, DateTime>{},
}) =>
    SyncSnapshot(
      deals: deals,
      devices: devices,
      platforms: platforms,
      platformsUpdatedAt:
          platformsUpdatedAt ?? DateTime.fromMicrosecondsSinceEpoch(0),
      tombstones: tombstones,
      deviceTombstones: deviceTombstones,
    );

class _FakeSyncTransport implements SyncTransport {
  String? stored;
  int downloads = 0;
  int uploads = 0;

  /// 主文件路径。设了之后，只有 PUT 这个路径才会更新 [stored]；
  /// 备份写到别的路径时不会污染「远端正文」，才能断言两件事互不影响。
  String? mainPath;

  /// 每次 PUT 的内容，按路径记下来（备份测试要看写到了哪个文件名）。
  final Map<String, String> uploaded = <String, String>{};

  /// 按路径存的已有文件（备份文件）。恢复功能要 GET 指定路径，
  /// 只有一个 [stored] 不够用；这里没命中才回落到 [stored]。
  final Map<String, String> files = <String, String>{};

  /// 设了就让下一次 PUT 直接失败，用来验「备份失败要中止同步」。
  SyncException? uploadError;

  /// DELETE 过的路径（备份保留份数测试用）。
  final List<String> deleted = <String>[];

  /// 设了就让 DELETE 直接失败，用来验「删不掉不该把同步判成失败」。
  SyncException? deleteError;

  /// 「远端目录树」：path → 子项。浏览功能测试用。
  Map<String, List<RemoteEntry>> tree = const <String, List<RemoteEntry>>{};
  final List<String> listed = <String>[];

  @override
  Future<void> ensureDirectory(String remotePath) async {}

  @override
  Future<void> probe(String remotePath) async {}

  @override
  Future<String?> download(String remotePath) async {
    downloads++;
    final byPath = files[remotePath];
    if (byPath != null) return byPath;
    final main = mainPath;
    // 设了主文件路径，就别把正文当成别的路径（备份）的内容返回，
    // 否则「备份不存在」这类分支测不出来。
    if (main != null && main != remotePath) return null;
    return stored;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    return tree[path] ?? const <RemoteEntry>[];
  }

  @override
  Future<void> upload(String remotePath, String content) async {
    final error = uploadError;
    if (error != null) throw error;
    uploads++;
    uploaded[remotePath] = content;
    if (mainPath == null || mainPath == remotePath) stored = content;
  }

  @override
  Future<void> delete(String remotePath) async {
    final error = deleteError;
    if (error != null) throw error;
    deleted.add(remotePath);
    files.remove(remotePath);
    uploaded.remove(remotePath);
    // 主文件不该被清理逻辑删掉；真删了说明逻辑有 bug，让后续断言直接失败。
    if (mainPath != null && remotePath == mainPath) stored = null;
  }
}

/// 用 dio 的适配器边界做假服务器：不联网，但走真实的请求构造与状态码处理。
class _FakeDioAdapter implements HttpClientAdapter {
  _FakeDioAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}
