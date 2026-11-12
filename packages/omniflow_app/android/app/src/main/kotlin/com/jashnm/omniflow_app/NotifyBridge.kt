package com.jashnm.omniflow_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The omniflow/notify method channel on the foreground service's engine:
 * a rule's notify step and a failed run become real notifications, shown
 * with the screen off and the app closed. A tap opens the app.
 */
class NotifyBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "post") return@setMethodCallHandler result.notImplemented()
            post(
                call.argument<String>("channel") ?: AUTOMATIONS,
                call.argument<Int>("id") ?: 0,
                call.argument<String>("title") ?: "OmniFlow",
                call.argument<String>("body"),
                call.argument<String>("link"),
            )
            result.success(null)
        }
    }

    private fun post(channel: String, id: Int, title: String, body: String?, link: String?) {
        if (Build.VERSION.SDK_INT >= 26) {
            val (name, importance) = when (channel) {
                PROBLEMS -> "Problems" to NotificationManager.IMPORTANCE_HIGH
                else -> "From automations" to NotificationManager.IMPORTANCE_DEFAULT
            }
            manager.createNotificationChannel(NotificationChannel(channel, name, importance))
        }
        // A tap opens what the notification names (omniflow://open/...),
        // which Flutter routes for a cold start and a running app alike.
        val open = (
            if (link != null && link.startsWith("omniflow://open/")) {
                Intent(Intent.ACTION_VIEW, android.net.Uri.parse(link)).setPackage(app.packageName)
            } else {
                app.packageManager.getLaunchIntentForPackage(app.packageName)
            }
            )?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val tap = open?.let {
            PendingIntent.getActivity(app, id, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = NotificationCompat.Builder(app, channel)
            .setSmallIcon(app.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        // Without the notification permission Android drops it, which is the
        // user's choice.
        try {
            manager.notify(id, notification)
        } catch (_: SecurityException) {
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() {}

    override fun onEngineWillDestroy() {}

    companion object {
        const val CHANNEL = "omniflow/notify"
        const val AUTOMATIONS = "automations"
        const val PROBLEMS = "problems"
    }
}
