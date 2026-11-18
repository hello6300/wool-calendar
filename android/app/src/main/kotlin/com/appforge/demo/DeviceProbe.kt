package com.appforge.demo

import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * 认「这是哪台手机」。
 *
 * 只读三个东西，都不需要任何权限：
 * - `Build.MODEL` / `MANUFACTURER`：给用户看的机型名（Redmi K30 Pro）。
 * - `Settings.Secure.ANDROID_ID`：每台设备唯一、卸载重装不变（Android 8+ 按
 *   应用签名 + 用户隔离），用来做稳定的设备标识。
 *
 * 不读 IMEI / 序列号：Android 10 起普通应用拿不到，而且要 READ_PHONE_STATE。
 * ANDROID_ID 恢复出厂设置后会变，那种情况下会被当成一台新手机 —— 可以接受，
 * 因为那时本机数据也已经清空了。
 */
object DeviceProbe {

    fun identity(ctx: Context): Map<String, Any?> {
        val androidId = try {
            Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (e: Exception) {
            ""
        }
        return mapOf(
            "model" to (Build.MODEL ?: ""),
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "brand" to (Build.BRAND ?: ""),
            "device" to (Build.DEVICE ?: ""),
            "product" to (Build.PRODUCT ?: ""),
            "androidId" to androidId,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }
}
