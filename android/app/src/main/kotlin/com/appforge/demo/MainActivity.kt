package com.appforge.demo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "diagnose" -> {
                            val from = (call.argument<Number>("from") ?: 0L).toLong()
                            val to = (call.argument<Number>("to") ?: 0L).toLong()
                            result.success(CalendarProbe.diagnose(this, from, to))
                        }
                        "queryInstances" -> {
                            val from = (call.argument<Number>("from") ?: 0L).toLong()
                            val to = (call.argument<Number>("to") ?: 0L).toLong()
                            result.success(CalendarProbe.queryInstances(this, from, to))
                        }
                        // Instances 被 ROM 过滤时的最后一条通道：直读 Events 并展开重复。
                        "queryEvents" -> {
                            val from = (call.argument<Number>("from") ?: 0L).toLong()
                            val to = (call.argument<Number>("to") ?: 0L).toLong()
                            result.success(CalendarProbe.queryEvents(this, from, to))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("calendar_probe_failed", e.message, null)
                }
            }

        // 设备识别单独一条通道：和日历读取没有关系，混在一起出错时难判读。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "identity" -> result.success(DeviceProbe.identity(this))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("device_probe_failed", e.message, null)
                }
            }
    }

    private companion object {
        const val CHANNEL = "appforge/calendar_probe"
        const val DEVICE_CHANNEL = "appforge/device_info"
    }
}
