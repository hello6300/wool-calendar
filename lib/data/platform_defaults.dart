/// 首次启动时写入的默认「常用平台」。
///
/// 这只是**初始值**：用户之后可以在 App 里自由增删改，默认列表不再参与任何逻辑。
/// 之所以按语言给两套，是因为平台名在英文界面下用品牌英文名更自然；
/// 一旦用户改过，就不再随语言切换而变化（存的是用户自己的数据）。
library;

/// 中文环境的初始常用平台。
const List<String> kDefaultPlatformsZh = <String>[
  '京东',
  '淘宝',
  '拼多多',
  '抖音',
  '快手',
  '美团',
  '支付宝',
  '银行',
  '其他',
];

/// 英文环境的初始常用平台（与中文列表一一对应）。
const List<String> kDefaultPlatformsEn = <String>[
  'JD',
  'Taobao',
  'Pinduoduo',
  'Douyin',
  'Kuaishou',
  'Meituan',
  'Alipay',
  'Bank',
  'Other',
];
