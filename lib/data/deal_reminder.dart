import '../models/wool_deal.dart';

/// 通知文案由 UI 层（AppLocalizations）注入，服务层不需要 BuildContext，
/// 因此 main() 里首次重排提醒时也能用（此时还没有 widget 树）。
class ReminderLabels {
  const ReminderLabels({
    required this.channelName,
    required this.channelDescription,
    required this.startTitle,
    required this.startBody,
    required this.endTitle,
    required this.endBody,
    required this.testTitle,
    required this.testBody,
    required this.scheduledTestTitle,
    required this.scheduledTestBody,
  });

  final String channelName;
  final String channelDescription;
  final String Function(String title) startTitle;
  final String Function(String platform, String time) startBody;
  final String Function(String title) endTitle;
  final String Function(String platform, String time) endBody;
  final String testTitle;
  final String testBody;
  final String scheduledTestTitle;
  final String scheduledTestBody;

  /// 冷启动重排发生在 runApp 之前，先用中文兜底；UI 首帧会换成当前语言。
  static ReminderLabels fallback = ReminderLabels(
    channelName: '羊毛提醒',
    channelDescription: '活动开始 / 结束时间到点提醒',
    startTitle: (title) => '羊毛开始：$title',
    startBody: (platform, time) => '$platform · $time，点开去看攻略',
    endTitle: (title) => '羊毛即将结束：$title',
    endBody: (platform, time) => '$platform · $time，别错过了',
    testTitle: '通知已开启',
    testBody: '到点提醒会像这样弹出，点通知可回到当天日历',
    scheduledTestTitle: '定时提醒测试成功',
    scheduledTestBody: '这条通知是 1 分钟前排定的，说明到点提醒链路已生效',
  );
}

/// 提醒调度边界：WoolStore 只依赖这个抽象，测试里可以塞 Fake。
abstract class DealReminder {
  /// 幂等排程：先清掉这条记录的旧通知，再按当前字段重排。
  Future<void> sync(WoolDeal deal);

  /// 删除记录 / 关掉提醒时取消该记录的两条通知。
  Future<void> cancel(String dealId);

  /// 申请通知权限（Android 13+）。默认空实现，纯 Dart 测试无需原生插件。
  Future<void> ensurePermissions() async {}
}
