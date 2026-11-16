package com.jashnm.omniflow_app

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.ForegroundServiceStartNotAllowedException
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import com.pravera.flutter_foreground_task.models.ForegroundServiceAction
import com.pravera.flutter_foreground_task.models.ForegroundServiceStatus
import com.pravera.flutter_foreground_task.models.ForegroundTaskData
import com.pravera.flutter_foreground_task.service.ForegroundService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Starts the automation service from outside the app (a widget, the Start
 * button of the "not running" notice, the watchdog), and says whether it
 * runs and whether the person stopped it.
 */
object ServiceStarter {
    fun isRunning(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.packageName == context.packageName && it.service.className == ForegroundService::class.java.name
        }
    }

    /** The person pressed Stop (or the app never started the service). */
    fun stoppedByUser(context: Context): Boolean = ForegroundServiceStatus.getData(context).isCorrectlyStopped()

    fun exactAlarmsAllowed(context: Context): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()

    fun batteryUnrestricted(context: Context): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(context.packageName)

    /** Starts the service, and is null when it runs or is starting, or why
     * it could not start. */
    fun start(context: Context): String? {
        val app = context.applicationContext
        if (isRunning(app)) return null
        // The service runs the Dart entry point the app saved on its first
        // start: before that there is nothing to run.
        if (ForegroundTaskData.getData(app).callbackHandle == null) return NEVER_OPENED
        ForegroundServiceStatus.setData(app, ForegroundServiceAction.RESTART)
        return try {
            ContextCompat.startForegroundService(app, Intent(app, ForegroundService::class.java))
            null
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException) {
                BACKGROUND_REFUSED
            } else {
                "Android did not start it: ${e.message ?: e.javaClass.simpleName}"
            }
        }
    }

    const val NEVER_OPENED = "OmniFlow has not been opened on this phone yet. Open it once"
    const val BACKGROUND_REFUSED = "Android did not let OmniFlow start again in the background. Tap Start. " +
        "To let it come back by itself, allow Alarms and reminders for OmniFlow, or set its battery use to Unrestricted"
}

/**
 * The "Automations are not running" notification: the reason, and a Start
 * button. One at a time, under its own tag, so it never replaces another.
 */
object NotRunningNotice {
    private const val CHANNEL = "omniflow_stopped"
    private const val TAG = "status"
    private const val ID = 1

    fun post(context: Context, reason: String) {
        val app = context.applicationContext
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Automations stopped", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Says when automations stop running, and why"
            },
        )
        val start = PendingIntent.getBroadcast(
            app,
            ID,
            Intent(app, StartReceiver::class.java).setAction(StartReceiver.ACTION_START),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = app.packageManager.getLaunchIntentForPackage(app.packageName)?.let {
            PendingIntent.getActivity(app, ID, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = NotificationCompat.Builder(app, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
            .setContentTitle("Automations are not running")
            .setContentText(reason)
            .setStyle(NotificationCompat.BigTextStyle().bigText(reason))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(NotificationCompat.Action.Builder(0, "Start", start).build())
            .build()
        try {
            manager.notify(TAG, ID, notification)
        } catch (_: SecurityException) {
        }
    }

    fun cancel(context: Context) {
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(TAG, ID)
    }
}

/** The Start button of [NotRunningNotice]. Not exported. A tap on a
 * notification is one of the times Android lets an app start its service
 * from the background. */
class StartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_START) return
        val failed = ServiceStarter.start(context)
        if (failed == null) {
            NotRunningNotice.cancel(context)
            Watchdog.schedule(context)
        } else {
            NotRunningNotice.post(context, failed)
        }
    }

    companion object {
        const val ACTION_START = "com.jashnm.omniflow_app.START"
    }
}

/**
 * Brings a killed service back. Every [EVERY_MS] an alarm looks: a running
 * service is left alone, one the person stopped is not restarted, and any
 * other is started again. Android lets a background app start its service
 * from an exact alarm, which needs Alarms and reminders on Android 14 and
 * later. When Android refuses, the notice says so and offers Start.
 */
object Watchdog {
    private const val EVERY_MS = 15 * 60_000L
    const val ACTION = "com.jashnm.omniflow_app.WATCHDOG"

    fun schedule(context: Context, inMs: Long = EVERY_MS) {
        val app = context.applicationContext
        val alarms = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + inMs
        if (ServiceStarter.exactAlarmsAllowed(app)) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(app))
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(app))
        }
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        (app.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(app))
    }

    private fun pending(app: Context): PendingIntent = PendingIntent.getBroadcast(
        app,
        0,
        Intent(app, WatchdogReceiver::class.java).setAction(ACTION),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** One look: start a service that should be running, or say why not. */
    fun check(context: Context) {
        if (ServiceStarter.stoppedByUser(context)) return cancel(context)
        schedule(context)
        if (ServiceStarter.isRunning(context)) return
        ServiceStarter.start(context)?.let { NotRunningNotice.post(context, it) }
    }
}

class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Watchdog.ACTION) Watchdog.check(context)
    }
}

/**
 * After a reboot or an app update the plugin starts the service itself;
 * this only arms the watchdog, so a start Android refused is noticed, and
 * tells a person who had stopped OmniFlow that it is still stopped. A grant
 * of Alarms and reminders moves the watchdog and the time triggers onto
 * exact alarms.
 */
class SystemEventsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                if (ServiceStarter.stoppedByUser(context)) {
                    // Never started at all is a fresh install: no notice.
                    if (ForegroundTaskData.getData(context).callbackHandle != null) {
                        NotRunningNotice.post(context, STILL_STOPPED)
                    }
                } else {
                    Watchdog.schedule(context, AFTER_START_MS)
                }
            }
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                if (!ServiceStarter.stoppedByUser(context)) Watchdog.schedule(context)
                PowerBridge.signal("exactAlarms")
            }
        }
    }

    private companion object {
        const val AFTER_START_MS = 2 * 60_000L
        const val STILL_STOPPED = "You stopped OmniFlow, so automations stay off. Tap Start to run them again"
    }
}

/** The exact alarm for the next time trigger: wakes the phone a little
 * early, holds the CPU for a short bounded time, and tells the engine. */
class WakeAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PowerBridge.ACTION_WAKE) return
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omniflow:alarm").acquire(PowerBridge.ALARM_HOLD_MS)
        if (!PowerBridge.signal("wake")) Watchdog.check(context)
    }
}

/**
 * The omniflow/power channel on the service's engine. The Dart side decides
 * when the CPU, Wi-Fi and alarms are needed (ServicePower); this holds the
 * locks it asks for, sets the exact alarm for the next time trigger, and
 * posts or clears the "not running" notice. It tells Dart when that alarm
 * fires, when the clock or the time zone changes, when the calendar changes
 * and when Alarms and reminders is granted.
 */
class PowerBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val wifiManager = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var channel: MethodChannel? = null
    private var cpu: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var clock: BroadcastReceiver? = null

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "cpu" -> result.success(holdCpu(call.argument<Boolean>("hold") == true, call.argument<Number>("forMs")?.toLong()))
                    "wifi" -> result.success(holdWifi(call.argument<Boolean>("hold") == true))
                    "wakeAt" -> result.success(wakeAt(call.argument<Number>("atMs")?.toLong()))
                    "status" -> result.success(
                        mapOf(
                            "exactAlarms" to ServiceStarter.exactAlarmsAllowed(app),
                            "batteryUnrestricted" to ServiceStarter.batteryUnrestricted(app),
                        ),
                    )
                    "notRunning" -> {
                        NotRunningNotice.post(app, call.argument<String>("reason") ?: "OmniFlow stopped")
                        result.success(null)
                    }
                    "running" -> {
                        NotRunningNotice.cancel(app)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        active = this
        listenToClock()
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {
        Watchdog.schedule(app)
    }

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() = releaseAll()

    override fun onEngineWillDestroy() {
        releaseAll()
        clock?.let { runCatching { app.unregisterReceiver(it) } }
        clock = null
        channel?.setMethodCallHandler(null)
        channel = null
        if (active === this) active = null
    }

    private fun releaseAll() {
        holdCpu(false, null)
        holdWifi(false)
        wakeAt(null)
    }

    private fun listenToClock() {
        if (clock != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                signal("clock")
            }
        }
        clock = receiver
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** A wake lock that ends by itself after [forMs] (an hour when not
     * given), so a lost release never keeps the phone awake for good. */
    private fun holdCpu(hold: Boolean, forMs: Long?): Boolean {
        if (!hold) {
            cpu?.let { if (it.isHeld) it.release() }
            return false
        }
        val lock = cpu ?: power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "omniflow:automations").apply {
            setReferenceCounted(false)
        }.also { cpu = it }
        lock.acquire(if (forMs != null && forMs > 0) forMs else DEFAULT_HOLD_MS)
        return lock.isHeld
    }

    /** Android 10 and later keep Wi-Fi out of power save only with a low
     * latency lock; before that the high-performance lock does it. */
    private fun holdWifi(hold: Boolean): Boolean {
        if (!hold) {
            wifi?.let { if (it.isHeld) it.release() }
            return false
        }
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        val lock = wifi ?: wifiManager.createWifiLock(mode, "omniflow:run").apply {
            setReferenceCounted(false)
        }.also { wifi = it }
        if (!lock.isHeld) lock.acquire()
        return lock.isHeld
    }

    /** Sets the alarm for [atMs] (epoch ms), or clears it for null. True
     * when the alarm is exact, which Android 14 and later allow only with
     * Alarms and reminders on. */
    private fun wakeAt(atMs: Long?): Boolean {
        val alarms = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = PendingIntent.getBroadcast(
            app,
            0,
            Intent(app, WakeAlarmReceiver::class.java).setAction(ACTION_WAKE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (atMs == null) {
            alarms.cancel(pending)
            return false
        }
        val exact = ServiceStarter.exactAlarmsAllowed(app)
        if (exact) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        }
        return exact
    }

    companion object {
        private const val CHANNEL = "omniflow/power"
        const val ACTION_WAKE = "com.jashnm.omniflow_app.WAKE"
        const val ALARM_HOLD_MS = 30_000L
        private const val DEFAULT_HOLD_MS = 60 * 60_000L
        private val main = Handler(Looper.getMainLooper())

        @Volatile private var active: PowerBridge? = null

        /** Tells the running service's Dart side about [name]. False when
         * no service engine is listening. */
        fun signal(name: String): Boolean {
            val bridge = active ?: return false
            main.post { bridge.channel?.invokeMethod("signal", name) }
            return true
        }
    }
}
