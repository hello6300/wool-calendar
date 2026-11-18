package com.appforge.demo

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import androidx.core.content.ContextCompat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * 直接读系统 CalendarProvider 的兜底通道。
 *
 * 为什么不只用 device_calendar 插件：
 * 1. 插件查事件前会先用 `Calendars.CONTENT_URI/<id>` 回查一次该日历，查不到就报
 *    NOT_FOUND 并跳过 —— 部分 ROM 的日历行读不全，于是整个日历的活动全被丢掉。
 * 2. 插件只查 Instances 视图。个别 ROM（小米等）的 `instances/when` 实现会额外
 *    按 Calendars.visible 等条件过滤，表现出来就是「系统日历没有活动」，
 *    而小米日历 App 自己明明看得到。
 * 3. 插件把错误吞成 isSuccess=false，上层只能显示「没有活动」，无法区分
 *    「真没有」和「读不到」。
 *
 * 因此这里有三级：Instances 视图 → Events 表 + 自行展开重复规则 → 诊断报告。
 * 全程只读，没有权限时不硬查。
 */
object CalendarProbe {

    private const val MAX_ROWS = 2000

    /// 单个重复活动最多展开多少次，防止「每天重复且无结束」的事件把内存撑爆。
    private const val MAX_EXPAND_PER_EVENT = 400

    fun hasRead(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    fun hasWrite(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 诊断：把「能看到的日历」「Instances 里有多少实例」「Events 表里有多少原始行」
     * 一次全给出来。上层据此就能判断卡在哪一环，而不是笼统地显示「没有活动」。
     */
    fun diagnose(ctx: Context, from: Long, to: Long): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["readPermission"] = hasRead(ctx)
        out["writePermission"] = hasWrite(ctx)
        out["sdkInt"] = android.os.Build.VERSION.SDK_INT
        out["manufacturer"] = android.os.Build.MANUFACTURER ?: ""
        out["brand"] = android.os.Build.BRAND ?: ""
        out["model"] = android.os.Build.MODEL ?: ""
        out["authority"] = "com.android.calendar"

        if (!hasRead(ctx)) {
            out["calendars"] = emptyList<Map<String, Any?>>()
            out["instanceCount"] = 0
            out["eventRowCount"] = 0
            out["recurringCount"] = 0
            out["perCalendar"] = emptyList<Map<String, Any?>>()
            out["errors"] = listOf("没有读取日历的权限")
            return out
        }

        val errors = ArrayList<String>()
        val calendars = readCalendars(ctx, errors)
        out["calendars"] = calendars

        // Instances：带展开，和插件读的是同一张视图，但不加任何额外条件。
        val instanceStats = statsInstances(ctx, from, to, errors)
        out["instanceCount"] = instanceStats.total
        out["perCalendar"] = instanceStats.perCalendar

        // Events：原始行（未展开重复规则）。若 Events 有行而 Instances 为 0，
        // 说明是 Instances 视图被 ROM 过滤，而不是本机没数据。
        val eventStats = statsEventRows(ctx, from, to, errors)
        out["eventRowCount"] = eventStats.total
        out["recurringCount"] = eventStats.recurring

        // 上面那个 eventRowCount 只代表「和区间可能有关」：重复日程只要开始时间
        // 早于区间终点就会被算进来（RRULE 可能一直重复下去）。真正能回答
        // 「区间里有没有东西」的是展开后的实例数，以及「本机总共有没有数据」
        // 只能看整张表的行数 —— 少了这两个数，任何空区间都会被误报成 ROM 限制。
        out["tableRowCount"] = countAllEvents(ctx, errors)
        out["expandedCount"] = queryEvents(ctx, from, to).size
        out["errors"] = errors
        return out
    }

    /**
     * 兜底一：不带日历过滤、不逐个日历回查，直接按时间范围取 Instances。
     * 只要 provider 里查得到就返回，哪怕是插件读不到的那部分。
     */
    fun queryInstances(ctx: Context, from: Long, to: Long): List<Map<String, Any?>> {
        if (!hasRead(ctx)) return emptyList()
        val uri = buildInstancesUri(from, to)

        // 个别 ROM 的 Instances 视图缺列，一次失败就整体读不到，所以逐级降级。
        for (projection in listOf(INSTANCE_PROJECTION, INSTANCE_PROJECTION_MIN)) {
            var cursor: Cursor? = null
            try {
                cursor = ctx.contentResolver.query(uri, projection, null, null, "${Instances.BEGIN} ASC")
                // cursor 为 null 说明这一级没查成，换下一级再试。
                if (cursor == null) continue
                val items = ArrayList<Map<String, Any?>>()
                while (cursor.moveToNext() && items.size < MAX_ROWS) {
                    items.add(mapInstance(cursor, projection.size))
                }
                return items
            } catch (e: Exception) {
                // 换下一级投影再试。
            } finally {
                cursor?.close()
            }
        }
        return emptyList()
    }

    /**
     * 兜底二：直接读 Events 表原始行，自己展开重复规则。
     *
     * 只在 Instances 一条都读不到时才调用 —— ROM 把 `instances/when` 过滤成空、
     * 但数据其实还在 Events 表里的情况，这是唯一还能拿到数据的路径。
     *
     * 重复规则的展开只覆盖常见形态（FREQ 的 DAILY/WEEKLY/MONTHLY/YEARLY，
     * 加上 INTERVAL/COUNT/UNTIL，以及 WEEKLY 的 BYDAY）。更冷门的 BYxxx 组合会被
     * 忽略 —— 宁可少数几条，也不要因为一条怪规则整体读不出来。
     */
    fun queryEvents(ctx: Context, from: Long, to: Long): List<Map<String, Any?>> {
        if (!hasRead(ctx)) return emptyList()

        // 与区间有交集：非重复看 DTEND，重复看 RRULE（它可能从很早开始一直重复下去）。
        val selection = "(${Events.DELETED} = 0)" +
            " AND (${Events.STATUS} IS NULL OR ${Events.STATUS} != ${Events.STATUS_CANCELED})" +
            " AND ((${Events.DTSTART} <= ? AND (${Events.DTEND} IS NULL OR ${Events.DTEND} >= ?))" +
            " OR (${Events.RRULE} IS NOT NULL AND ${Events.DTSTART} <= ?))"
        val args = arrayOf(to.toString(), from.toString(), to.toString())

        for (projection in listOf(EVENT_PROJECTION, EVENT_PROJECTION_MIN)) {
            var cursor: Cursor? = null
            try {
                cursor = ctx.contentResolver.query(
                    Events.CONTENT_URI,
                    projection,
                    selection,
                    args,
                    "${Events.DTSTART} ASC",
                )
                if (cursor == null) continue

                val items = ArrayList<Map<String, Any?>>()
                val full = projection.size >= EVENT_PROJECTION.size
                while (cursor.moveToNext() && items.size < MAX_ROWS) {
                    val row = readEventRow(cursor, full)
                    if (row.start <= 0L) continue
                    val rrule = if (full) safeString(cursor, 8) else null
                    if (rrule.isNullOrBlank()) {
                        // 非重复：只要与区间有交集就算一条。
                        val end = if (row.end > row.start) row.end else row.start + DEFAULT_DURATION_MS
                        if (row.start <= to && end >= from) {
                            items.add(row.toMap(row.start, end))
                        }
                    } else {
                        expandRecurring(row, rrule, from, to, items)
                    }
                }
                return items
            } catch (e: Exception) {
                // 投影缺列（部分 ROM 没有 CALENDAR_DISPLAY_NAME 等）→ 换最小投影。
            } finally {
                cursor?.close()
            }
        }
        return emptyList()
    }

    // ---------------------------------------------------------------- Events 展开

    private data class EventRow(
        val id: String,
        val calendarId: String,
        val title: String,
        val start: Long,
        val end: Long,
        val allDay: Boolean,
        val description: String,
        val location: String,
        val calendarName: String,
    ) {
        fun toMap(begin: Long, finish: Long): Map<String, Any?> = mapOf(
            "eventId" to id,
            "calendarId" to calendarId,
            "title" to title,
            "begin" to begin,
            "end" to finish,
            "allDay" to allDay,
            "description" to description,
            "location" to location,
            "calendarName" to calendarName,
        )
    }

    private fun readEventRow(c: Cursor, full: Boolean): EventRow {
        val start = safeLong(c, 3)
        val rawEnd = safeLong(c, 4)
        return EventRow(
            id = safeString(c, 0) ?: "",
            calendarId = safeString(c, 1) ?: "",
            title = safeString(c, 2) ?: "",
            start = start,
            end = rawEnd,
            allDay = safeInt(c, 5) == 1,
            description = safeString(c, 6) ?: "",
            location = safeString(c, 7) ?: "",
            calendarName = if (full) (safeString(c, 11) ?: "") else "",
        )
    }

    private data class RRule(
        val freq: String,
        val interval: Int,
        /// 0 表示不限次数。
        val count: Int,
        /// 0 表示不设截止。
        val until: Long,
        /// Calendar.DAY_OF_WEEK 取值；空表示跟随 DTSTART 的星期几。
        val byDays: List<Int>,
    )

    private fun parseRRule(raw: String): RRule? {
        var freq = ""
        var interval = 1
        var count = 0
        var until = 0L
        var byDays = emptyList<Int>()
        for (part in raw.split(';')) {
            val idx = part.indexOf('=')
            if (idx <= 0) continue
            val key = part.substring(0, idx).trim().uppercase(Locale.US)
            val value = part.substring(idx + 1).trim()
            when (key) {
                "FREQ" -> freq = value.uppercase(Locale.US)
                "INTERVAL" -> interval = (value.toIntOrNull() ?: 1).coerceIn(1, 1000)
                "COUNT" -> count = (value.toIntOrNull() ?: 0).coerceIn(0, MAX_EXPAND_PER_EVENT)
                "UNTIL" -> until = parseUntil(value)
                "BYDAY" -> byDays = parseByDay(value)
            }
        }
        if (freq != "DAILY" && freq != "WEEKLY" && freq != "MONTHLY" && freq != "YEARLY") {
            return null
        }
        return RRule(freq, interval, count, until, byDays)
    }

    private fun parseUntil(value: String): Long {
        val trimmed = value.trim().trimEnd('Z')
        val patterns = listOf("yyyyMMdd'T'HHmmss", "yyyyMMdd")
        for (pattern in patterns) {
            try {
                val fmt = java.text.SimpleDateFormat(pattern, Locale.US)
                fmt.timeZone = TimeZone.getTimeZone("UTC")
                return fmt.parse(trimmed)?.time ?: 0L
            } catch (e: Exception) {
                // 换下一个格式。
            }
        }
        return 0L
    }

    private fun parseByDay(value: String): List<Int> {
        val list = ArrayList<Int>()
        for (token in value.split(',')) {
            val t = token.trim().uppercase(Locale.US)
            if (t.length < 2) continue
            val day = when (t.substring(t.length - 2)) {
                "MO" -> Calendar.MONDAY
                "TU" -> Calendar.TUESDAY
                "WE" -> Calendar.WEDNESDAY
                "TH" -> Calendar.THURSDAY
                "FR" -> Calendar.FRIDAY
                "SA" -> Calendar.SATURDAY
                "SU" -> Calendar.SUNDAY
                else -> -1
            }
            if (day > 0) list.add(day)
        }
        return list
    }

    /// 一周里的偏移量（周一 = 0 … 周日 = 6），避开 Calendar 的「周日 = 1」。
    private fun weekOffset(dayOfWeek: Int): Int =
        if (dayOfWeek == Calendar.SUNDAY) 6 else dayOfWeek - Calendar.MONDAY

    private fun expandRecurring(
        row: EventRow,
        rawRule: String,
        from: Long,
        to: Long,
        out: MutableList<Map<String, Any?>>,
    ) {
        val rule = parseRRule(rawRule) ?: return
        val duration = when {
            row.end > row.start -> row.end - row.start
            row.allDay -> DAY_MS
            else -> DEFAULT_DURATION_MS
        }

        // 重复展开按 UTC 日粒度推进：DTSTART 存的是 UTC 毫秒，日/周/月/年
        // 的推进在 UTC 上做不会因 DST 漂移（中国无夏令时，主要用户区无影响）。
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.timeInMillis = row.start
        if (rule.freq == "WEEKLY" && rule.byDays.isNotEmpty()) {
            // 有 BYDAY 时以「本周周一」为周期起点，周期内再挑具体星期几。
            cal.add(Calendar.DAY_OF_YEAR, -weekOffset(cal.get(Calendar.DAY_OF_WEEK)))
        }

        var produced = 0
        var guard = 0
        while (guard++ < MAX_EXPAND_PER_EVENT * 4) {
            if (rule.count > 0 && produced >= rule.count) return
            if (cal.timeInMillis > to) return

            val candidates = if (rule.freq == "WEEKLY" && rule.byDays.isNotEmpty()) {
                byDayCandidates(cal, rule, row.start)
            } else {
                listOf(cal.timeInMillis)
            }

            for (begin in candidates) {
                if (rule.count > 0 && produced >= rule.count) return
                if (rule.until > 0 && begin > rule.until) return
                if (begin > to) return
                produced++
                val finish = begin + duration
                if (begin <= to && finish >= from && out.size < MAX_ROWS) {
                    out.add(row.toMap(begin, finish))
                }
            }

            when (rule.freq) {
                "DAILY" -> cal.add(Calendar.DAY_OF_YEAR, rule.interval)
                "WEEKLY" -> cal.add(Calendar.DAY_OF_YEAR, 7 * rule.interval)
                "MONTHLY" -> cal.add(Calendar.MONTH, rule.interval)
                "YEARLY" -> cal.add(Calendar.YEAR, rule.interval)
                else -> return
            }
        }
    }

    /// 一周内按 BYDAY 挑出具体的开始时刻（保留 DTSTART 的时分秒）。
    private fun byDayCandidates(base: Calendar, rule: RRule, seriesStart: Long): List<Long> {
        val mondayOffset = weekOffset(base.get(Calendar.DAY_OF_WEEK))
        val result = ArrayList<Long>()
        for (day in rule.byDays) {
            val c = base.clone() as Calendar
            c.add(Calendar.DAY_OF_YEAR, weekOffset(day) - mondayOffset)
            val t = c.timeInMillis
            // 第一次不该早于 DTSTART 本身。
            if (t >= seriesStart) result.add(t)
        }
        result.sort()
        return result
    }

    // ---------------------------------------------------------------- Instances

    private fun buildInstancesUri(from: Long, to: Long): android.net.Uri {
        val builder = Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(builder, from)
        ContentUris.appendId(builder, to)
        return builder.build()
    }

    private data class InstanceStats(
        val total: Int,
        val perCalendar: List<Map<String, Any?>>,
    )

    private fun statsInstances(
        ctx: Context,
        from: Long,
        to: Long,
        errors: MutableList<String>,
    ): InstanceStats {
        var cursor: Cursor? = null
        return try {
            cursor = ctx.contentResolver.query(
                buildInstancesUri(from, to),
                arrayOf(Instances._ID, Instances.CALENDAR_ID),
                null,
                null,
                null,
            )
            if (cursor == null) {
                errors.add("Instances 查询返回空游标")
                InstanceStats(0, emptyList())
            } else {
                val counts = LinkedHashMap<String, Int>()
                var total = 0
                while (cursor.moveToNext()) {
                    total++
                    val id = safeString(cursor, 1) ?: ""
                    counts[id] = (counts[id] ?: 0) + 1
                }
                val perCalendar = counts.map { (id, n) -> mapOf("calendarId" to id, "count" to n) }
                InstanceStats(total, perCalendar)
            }
        } catch (e: Exception) {
            errors.add("Instances 查询失败：${e.javaClass.simpleName} ${e.message ?: ""}")
            InstanceStats(0, emptyList())
        } finally {
            cursor?.close()
        }
    }

    private fun readCalendars(ctx: Context, errors: MutableList<String>): List<Map<String, Any?>> {
        val list = ArrayList<Map<String, Any?>>()
        var cursor: Cursor? = null
        try {
            cursor = ctx.contentResolver.query(
                Calendars.CONTENT_URI,
                CALENDAR_PROJECTION,
                null,
                null,
                "${Calendars.CALENDAR_DISPLAY_NAME} ASC",
            )
            while (cursor != null && cursor.moveToNext() && list.size < MAX_ROWS) {
                list.add(
                    mapOf(
                        "id" to cursor.getString(0),
                        "name" to (safeString(cursor, 1) ?: ""),
                        "account" to (safeString(cursor, 2) ?: ""),
                        "accountType" to (safeString(cursor, 3) ?: ""),
                        "visible" to safeInt(cursor, 4),
                        "syncEvents" to safeInt(cursor, 5),
                        "accessLevel" to safeInt(cursor, 6),
                        "owner" to (safeString(cursor, 7) ?: ""),
                    ),
                )
            }
        } catch (e: Exception) {
            errors.add("读取日历列表失败：${e.javaClass.simpleName} ${e.message ?: ""}")
        } finally {
            cursor?.close()
        }
        return list
    }

    private data class EventStats(val total: Int, val recurring: Int)

    private fun statsEventRows(
        ctx: Context,
        from: Long,
        to: Long,
        errors: MutableList<String>,
    ): EventStats {
        var cursor: Cursor? = null
        val selection = "(${Events.DELETED} = 0)" +
            " AND ((${Events.DTSTART} <= ? AND (${Events.DTEND} IS NULL OR ${Events.DTEND} >= ?))" +
            " OR (${Events.RRULE} IS NOT NULL AND ${Events.DTSTART} <= ?))"
        val args = arrayOf(to.toString(), from.toString(), to.toString())
        return try {
            cursor = ctx.contentResolver.query(
                Events.CONTENT_URI,
                arrayOf(Events._ID, Events.RRULE),
                selection,
                args,
                null,
            )
            if (cursor == null) {
                errors.add("Events 查询返回空游标")
                EventStats(0, 0)
            } else {
                var total = 0
                var recurring = 0
                while (cursor.moveToNext()) {
                    total++
                    val rule = safeString(cursor, 1)
                    if (!rule.isNullOrBlank()) recurring++
                }
                EventStats(total, recurring)
            }
        } catch (e: Exception) {
            errors.add("Events 查询失败：${e.javaClass.simpleName} ${e.message ?: ""}")
            EventStats(0, 0)
        } finally {
            cursor?.close()
        }
    }

    /**
     * 整张 Events 表有多少条（不分区间、不含已删除）。
     *
     * 「本机是不是一条日程都没有」只能这样问：带上区间条件的话，重复日程会把
     * 任何区间都撑成非空，反而看不出数据到底在不在。
     */
    private fun countAllEvents(ctx: Context, errors: MutableList<String>): Int {
        var cursor: Cursor? = null
        return try {
            cursor = ctx.contentResolver.query(
                Events.CONTENT_URI,
                arrayOf(Events._ID),
                "(${Events.DELETED} = 0)",
                null,
                null,
            )
            cursor?.count ?: 0
        } catch (e: Exception) {
            errors.add("事件总数查询失败：${e.javaClass.simpleName} ${e.message ?: ""}")
            0
        } finally {
            cursor?.close()
        }
    }

    // ---------------------------------------------------------------- 游标映射

    private fun mapInstance(c: Cursor, columnCount: Int): Map<String, Any?> {
        // 降级投影只有前 7 列，后面的描述/地点/日历名一律留空，不要让越界读崩掉。
        val full = columnCount >= INSTANCE_PROJECTION.size
        return mapOf(
            "eventId" to safeString(c, 1),
            "calendarId" to safeString(c, 2),
            "title" to (safeString(c, 3) ?: ""),
            "begin" to safeLong(c, 4),
            "end" to safeLong(c, 5),
            "allDay" to (safeInt(c, 6) == 1),
            "description" to if (full) (safeString(c, 7) ?: "") else "",
            "location" to if (full) (safeString(c, 8) ?: "") else "",
            "calendarName" to if (full) (safeString(c, 10) ?: "") else "",
        )
    }

    private fun safeString(c: Cursor, i: Int): String? = try {
        if (c.isNull(i)) null else c.getString(i)
    } catch (e: Exception) {
        null
    }

    private fun safeLong(c: Cursor, i: Int): Long = try {
        if (c.isNull(i)) 0L else c.getLong(i)
    } catch (e: Exception) {
        0L
    }

    private fun safeInt(c: Cursor, i: Int): Int = try {
        if (c.isNull(i)) 0 else c.getInt(i)
    } catch (e: Exception) {
        0
    }

    private const val DAY_MS = 24L * 60 * 60 * 1000
    private const val DEFAULT_DURATION_MS = 60L * 60 * 1000

    private val CALENDAR_PROJECTION = arrayOf(
        Calendars._ID,                  // 0
        Calendars.CALENDAR_DISPLAY_NAME,// 1
        Calendars.ACCOUNT_NAME,         // 2
        Calendars.ACCOUNT_TYPE,         // 3
        Calendars.VISIBLE,              // 4
        Calendars.SYNC_EVENTS,          // 5
        Calendars.CALENDAR_ACCESS_LEVEL,// 6
        Calendars.OWNER_ACCOUNT,        // 7
    )

    private val INSTANCE_PROJECTION = arrayOf(
        Instances._ID,                    // 0
        Instances.EVENT_ID,               // 1
        Instances.CALENDAR_ID,            // 2
        Instances.TITLE,                  // 3
        Instances.BEGIN,                  // 4
        Instances.END,                    // 5
        Instances.ALL_DAY,                // 6
        Instances.DESCRIPTION,            // 7
        Instances.EVENT_LOCATION,         // 8
        Instances.RRULE,                  // 9
        Instances.CALENDAR_DISPLAY_NAME,  // 10
    )

    // 最小投影：只保留各版本 CalendarContract 都一定有的列。
    private val INSTANCE_PROJECTION_MIN = arrayOf(
        Instances._ID,
        Instances.EVENT_ID,
        Instances.CALENDAR_ID,
        Instances.TITLE,
        Instances.BEGIN,
        Instances.END,
        Instances.ALL_DAY,
    )

    private val EVENT_PROJECTION = arrayOf(
        Events._ID,                     // 0
        Events.CALENDAR_ID,             // 1
        Events.TITLE,                   // 2
        Events.DTSTART,                 // 3
        Events.DTEND,                   // 4
        Events.ALL_DAY,                 // 5
        Events.DESCRIPTION,             // 6
        Events.EVENT_LOCATION,          // 7
        Events.RRULE,                   // 8
        Events.DURATION,                // 9
        Events.EVENT_TIMEZONE,          // 10
        Events.CALENDAR_DISPLAY_NAME,   // 11
    )

    private val EVENT_PROJECTION_MIN = arrayOf(
        Events._ID,
        Events.CALENDAR_ID,
        Events.TITLE,
        Events.DTSTART,
        Events.DTEND,
        Events.ALL_DAY,
        Events.DESCRIPTION,
        Events.EVENT_LOCATION,
        Events.RRULE,
    )
}
