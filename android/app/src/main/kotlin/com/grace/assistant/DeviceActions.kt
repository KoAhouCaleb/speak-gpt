package com.grace.assistant

import android.annotation.SuppressLint
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.telephony.SmsManager
import java.util.TimeZone

/**
 * Actions on the device that need no UI: texts, calendar and alarms. The permission prompts
 * are handled by the activity before these run.
 */
object DeviceActions {

    const val CALENDAR_LIMIT = 50

    @Suppress("DEPRECATION")
    fun sendSms(context: Context, number: String, message: String) {
        val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            SmsManager.getDefault()
        }
        val parts = manager.divideMessage(message)
        if (parts.size > 1) {
            manager.sendMultipartTextMessage(number, null, parts, null, null)
        } else {
            manager.sendTextMessage(number, null, message, null, null)
        }
    }

    // ---- Calendar -------------------------------------------------------------------------

    fun calendarEvents(context: Context, from: Long, to: Long): List<Map<String, Any?>> {
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .also {
                ContentUris.appendId(it, from)
                ContentUris.appendId(it, to)
            }
            .build()
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        val events = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(uri, projection, null, null, "${CalendarContract.Instances.BEGIN} ASC")
            ?.use { c ->
                while (c.moveToNext() && events.size < CALENDAR_LIMIT) {
                    events.add(
                        mapOf(
                            "id" to c.getLong(0),
                            "title" to (c.getString(1) ?: ""),
                            "start" to c.getLong(2),
                            "end" to c.getLong(3),
                            "allDay" to (c.getInt(4) == 1),
                            "location" to (c.getString(5) ?: ""),
                            "description" to (c.getString(6) ?: ""),
                            "calendar" to (c.getString(7) ?: ""),
                        ),
                    )
                }
            }
        return events
    }

    /** The calendar new events go to: the primary one if there is one, else any the user can write to. */
    private fun writableCalendarId(context: Context): Long? {
        val projection = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY)
        var fallback: Long? = null
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ? AND ${CalendarContract.Calendars.VISIBLE} = 1",
            arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString()),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(1) == 1) return c.getLong(0)
                if (fallback == null) fallback = c.getLong(0)
            }
        }
        return fallback
    }

    fun calendarAdd(context: Context, args: Map<String, Any?>): Long? {
        val calendarId = writableCalendarId(context) ?: return null
        val allDay = args["allDay"] == true
        val start = (args["start"] as Number).toLong()
        val end = (args["end"] as Number).toLong()

        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, args["title"] as String)
            put(CalendarContract.Events.DTSTART, start)
            val rrule = args["rrule"] as? String
            if (rrule == null) {
                put(CalendarContract.Events.DTEND, end)
            } else {
                // A repeating event has a DURATION and no DTEND
                put(CalendarContract.Events.RRULE, rrule)
                val seconds = (end - start) / 1000
                put(
                    CalendarContract.Events.DURATION,
                    if (allDay) "P${seconds / 86400}D" else "P${seconds}S",
                )
            }
            put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
            // All day events are stored in UTC
            put(
                CalendarContract.Events.EVENT_TIMEZONE,
                if (allDay) "UTC" else TimeZone.getDefault().id,
            )
            (args["location"] as? String)?.let { put(CalendarContract.Events.EVENT_LOCATION, it) }
            (args["description"] as? String)?.let { put(CalendarContract.Events.DESCRIPTION, it) }
        }
        val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) ?: return null
        val id = ContentUris.parseId(uri)

        (args["reminderMinutes"] as? Number)?.let { minutes ->
            val reminder = ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, id)
                put(CalendarContract.Reminders.MINUTES, minutes.toInt())
                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
            }
            context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, reminder)
        }
        return id
    }

    /** Length in milliseconds of an RFC 2445 duration such as P3600S, PT1H or P2D. */
    private fun durationMillis(duration: String?): Long? {
        val m = Regex("^P(?:(\\d+)W)?(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?$")
            .matchEntire(duration ?: return null) ?: return null
        val (w, d, h, min, sec) = m.destructured
        fun n(v: String) = if (v.isEmpty()) 0L else v.toLong()
        return (((n(w) * 7 + n(d)) * 24 + n(h)) * 60 + n(min)) * 60_000 + n(sec) * 1000
    }

    /** Changes only the fields that are present. Returns false if the event does not exist. */
    fun calendarUpdate(context: Context, id: Long, args: Map<String, Any?>): Boolean {
        val values = ContentValues()
        (args["title"] as? String)?.let { values.put(CalendarContract.Events.TITLE, it) }
        (args["location"] as? String)?.let { values.put(CalendarContract.Events.EVENT_LOCATION, it) }
        (args["description"] as? String)?.let { values.put(CalendarContract.Events.DESCRIPTION, it) }

        val newStart = (args["start"] as? Number)?.toLong()
        val newEnd = (args["end"] as? Number)?.toLong()
        val newRule = args["rrule"] as? String
        val clearRule = args["clearRrule"] == true
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)

        if (newStart != null || newEnd != null || newRule != null || clearRule) {
            // Repeating events keep a DURATION and no DTEND, single ones the opposite, so the
            // schedule is written as a whole
            val projection = arrayOf(
                CalendarContract.Events.DTSTART,
                CalendarContract.Events.DTEND,
                CalendarContract.Events.DURATION,
                CalendarContract.Events.ALL_DAY,
                CalendarContract.Events.RRULE,
            )
            val current = context.contentResolver.query(uri, projection, null, null, null)?.use { c ->
                if (!c.moveToFirst()) return false
                arrayOf(c.getLong(0), if (c.isNull(1)) null else c.getLong(1), c.getString(2), c.getLong(3), c.getString(4))
            } ?: return false
            val allDay = current[3] as Long == 1L
            val start = newStart ?: current[0] as Long
            val end = newEnd
                ?: if (newStart != null || current[1] == null) {
                    start + (durationMillis(current[2] as String?)
                        ?: ((current[1] as Long? ?: start) - (current[0] as Long)))
                } else {
                    current[1] as Long
                }
            var keepRule = if (clearRule) null else newRule ?: current[4] as String?
            if (allDay && keepRule != null) {
                // An all day event takes a date as the last day of the repeat
                keepRule = keepRule.replace(Regex("UNTIL=(\\d{8})T\\d{6}Z"), "UNTIL=\$1")
            }

            values.put(CalendarContract.Events.DTSTART, start)
            if (keepRule == null) {
                values.put(CalendarContract.Events.DTEND, end)
                values.putNull(CalendarContract.Events.RRULE)
                values.putNull(CalendarContract.Events.DURATION)
            } else {
                val seconds = (end - start) / 1000
                values.putNull(CalendarContract.Events.DTEND)
                values.put(CalendarContract.Events.RRULE, keepRule)
                values.put(
                    CalendarContract.Events.DURATION,
                    if (allDay) "P${seconds / 86400}D" else "P${seconds}S",
                )
            }
        }
        if (values.size() == 0) return true
        return context.contentResolver.update(uri, values, null, null) > 0
    }

    fun calendarDelete(context: Context, id: Long): Boolean {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        return context.contentResolver.delete(uri, null, null) > 0
    }

    // ---- Alarms and timers ------------------------------------------------------------------

    private fun launch(context: Context, intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: android.content.ActivityNotFoundException) {
            false
        }
    }

    fun setAlarm(context: Context, hour: Int, minute: Int, label: String?, days: List<Int>): Boolean {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label)
        if (days.isNotEmpty()) intent.putIntegerArrayListExtra(AlarmClock.EXTRA_DAYS, ArrayList(days))
        return launch(context, intent)
    }

    fun setTimer(context: Context, seconds: Int, label: String?): Boolean {
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label)
        return launch(context, intent)
    }

    fun showAlarms(context: Context): Boolean = launch(context, Intent(AlarmClock.ACTION_SHOW_ALARMS))

    /** Dismisses alarms by time, by label or all of them. Needs a clock app that supports it. */
    @SuppressLint("InlinedApi")
    fun dismissAlarm(context: Context, hour: Int?, minute: Int?, label: String?): Boolean {
        val intent = Intent(AlarmClock.ACTION_DISMISS_ALARM)
        when {
            hour != null && minute != null -> {
                intent.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_TIME)
                    .putExtra(AlarmClock.EXTRA_HOUR, hour)
                    .putExtra(AlarmClock.EXTRA_MINUTES, minute)
                    .putExtra(AlarmClock.EXTRA_IS_PM, hour >= 12)
            }
            !label.isNullOrBlank() -> {
                intent.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_LABEL)
                    .putExtra(AlarmClock.EXTRA_MESSAGE, label)
            }
            else -> intent.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_ALL)
        }
        return launch(context, intent)
    }
}
