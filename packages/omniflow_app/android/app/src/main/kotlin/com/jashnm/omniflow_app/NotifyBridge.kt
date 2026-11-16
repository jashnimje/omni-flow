package com.jashnm.omniflow_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The omniflow/notify method channel on the foreground service's engine:
 * a rule's notify step, a failed run, a device alert and a question an
 * automation asks become real notifications, shown with the screen off and
 * the app closed. A tap opens the app.
 *
 * Every notification is posted under a tag (its channel, or the ask's), so
 * ids only need to be unique within one kind and never collide across
 * kinds, the service notification or the phone actions.
 */
class NotifyBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "post" -> post(
                    call.argument<String>("channel") ?: AUTOMATIONS,
                    call.argument<Int>("id") ?: 0,
                    call.argument<String>("title") ?: "OmniFlow",
                    call.argument<String>("body"),
                    call.argument<String>("link"),
                    call.argument<String>("open"),
                )
                "ask" -> ask(
                    call.argument<Int>("id") ?: 0,
                    call.argument<String>("askId") ?: return@setMethodCallHandler result.error("invalid", "no askId", null),
                    call.argument<String>("title") ?: "OmniFlow",
                    call.argument<String>("body"),
                    call.argument<List<String>>("actions") ?: emptyList(),
                    call.argument<Boolean>("reply") == true,
                    call.argument<String>("hint"),
                    call.argument<List<String>>("chooser") ?: emptyList(),
                    call.argument<String>("link"),
                    (call.argument<Number>("timeoutMs"))?.toLong(),
                    call.argument<String>("group"),
                )
                "cancel" -> {
                    val id = call.argument<Int>("id") ?: 0
                    val tag = call.argument<String>("tag")
                    if (tag == null) {
                        // An ask, and the summary that keeps it on its own.
                        manager.cancel(QUESTIONS, id)
                        manager.cancel(ASK_SUMMARY, id)
                    } else {
                        manager.cancel(tag, id)
                    }
                }
                else -> return@setMethodCallHandler result.notImplemented()
            }
            result.success(null)
        }
    }

    /**
     * A question from an automation, answered from the notification: one
     * action per answer, a reply box for text, or a tap that opens a list
     * when there are more answers than Android shows as actions. Each answer
     * goes to [AskReceiver] or [AskActivity], neither exported, and Android
     * asks for the unlock before an answer from the lock screen.
     */
    private fun ask(
        id: Int,
        askId: String,
        title: String,
        body: String?,
        actions: List<String>,
        reply: Boolean,
        hint: String?,
        chooser: List<String>,
        link: String?,
        timeoutMs: Long?,
        group: String?,
    ) {
        // The first asks went on a default-importance channel, and Android
        // never raises a channel's importance, so it is replaced.
        manager.deleteNotificationChannel(OLD_ASKS)
        manager.createNotificationChannel(
            NotificationChannel(QUESTIONS, "Questions from automations", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "An automation waits for your answer" },
        )
        val key = group ?: "ask/$askId"
        // A heads-up with the answers as buttons. No full-screen intent: a
        // question never takes over the screen.
        val builder = NotificationCompat.Builder(app, QUESTIONS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setGroup(key)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
        if (timeoutMs != null && timeoutMs > 0) builder.setTimeoutAfter(timeoutMs)
        actions.take(3).forEachIndexed { i, answer ->
            builder.addAction(
                NotificationCompat.Action.Builder(0, answer, AskReceiver.pendingAnswer(app, id, i, askId, answer))
                    .setAuthenticationRequired(true)
                    .build(),
            )
        }
        if (reply) {
            val input = RemoteInput.Builder(AskReceiver.REPLY_KEY).setLabel(hint ?: "Your answer").build()
            builder.addAction(
                NotificationCompat.Action.Builder(0, "Answer", AskReceiver.pendingReply(app, id, askId))
                    .addRemoteInput(input)
                    .setAllowGeneratedReplies(false)
                    .setAuthenticationRequired(true)
                    .build(),
            )
        }
        val tap = if (chooser.isNotEmpty()) {
            AskActivity.pendingChooser(app, id, askId, title, chooser).also {
                builder.addAction(NotificationCompat.Action.Builder(0, "Choose", it).build())
            }
        } else {
            openIntent(id, link, null)
        }
        builder.setContentIntent(tap)
        // A group with a summary and one child shows the child alone, with
        // its buttons. Without the summary Android folds a lone grouped
        // notification into the app's automatic bundle, two taps deep.
        val summary = NotificationCompat.Builder(app, QUESTIONS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setGroup(key)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setSilent(true)
            .setContentIntent(tap)
        if (timeoutMs != null && timeoutMs > 0) summary.setTimeoutAfter(timeoutMs)
        try {
            manager.notify(QUESTIONS, id, builder.build())
            manager.notify(ASK_SUMMARY, id, summary.build())
        } catch (_: SecurityException) {
        }
    }

    /** A tap opens what the notification names: an omniflow://open/ link,
     * one of Android's settings pages ([open]), or the app. */
    private fun openIntent(id: Int, link: String?, open: String?): PendingIntent? {
        val settings = when (open) {
            "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "alarms" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.fromParts("package", app.packageName, null))
            } else {
                null
            }
            else -> null
        }
        val intent = settings ?: if (link != null && link.startsWith("omniflow://open/")) {
            Intent(Intent.ACTION_VIEW, Uri.parse(link)).setPackage(app.packageName)
        } else {
            app.packageManager.getLaunchIntentForPackage(app.packageName)
        }
        val launch = intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) ?: return null
        if (settings != null && launch.resolveActivity(app.packageManager) == null) return openIntent(id, link, null)
        return PendingIntent.getActivity(app, id, launch, PendingIntent.FLAG_IMMUTABLE)
    }

    private fun post(channel: String, id: Int, title: String, body: String?, link: String?, open: String?) {
        val (name, importance) = when (channel) {
            PROBLEMS -> "Problems" to NotificationManager.IMPORTANCE_HIGH
            ALERTS -> "Device alerts" to NotificationManager.IMPORTANCE_DEFAULT
            else -> "From automations" to NotificationManager.IMPORTANCE_DEFAULT
        }
        manager.createNotificationChannel(NotificationChannel(channel, name, importance))
        val notification = NotificationCompat.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openIntent(id, link, open))
            .build()
        // Without the notification permission Android drops it, which is the
        // user's choice.
        try {
            manager.notify(channel, id, notification)
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
        const val ALERTS = "alerts"
        const val QUESTIONS = "questions"
        const val ASK_SUMMARY = "questions/summary"
        private const val OLD_ASKS = "asks"
    }
}
