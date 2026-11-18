# ---------------------------------------------------------------------------
# flutter_local_notifications：定时提醒的“已排程列表”是用 Gson 序列化后存
# SharedPreferences 的，插件内部靠 `new TypeToken<...>() {}` 匿名子类拿泛型类型。
#
# release 构建默认开 R8，会把泛型签名（Signature 属性）当无用元数据裁掉，
# 于是 TypeToken 构造直接抛：
#   IllegalStateException: TypeToken must be created with a type argument ...
# 表现为 **zonedSchedule() 每次都失败 → 定时提醒一条都排不上**，而「立即发一条
# 测试通知」走的是另一条代码路径，看起来完全正常 —— 从现象上极难定位。
#
# 自查方式：提醒设置页会显示
#   [reminder] sync: PlatformException(error, TypeToken must be created ...)
# 或 logcat 里搜 MethodChannel#dexterous.com/flutter/local_notifications。
# ---------------------------------------------------------------------------
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod

# 插件的 receiver / service / model 一律保留，避免被裁后闹钟静默不投递。
-keep class com.dexterous.** { *; }

# Gson 反射所需的适配器实现与泛型信息。
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-dontwarn com.google.gson.**
