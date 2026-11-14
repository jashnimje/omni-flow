package com.jashnm.omniflow_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The omniflow/notify method channel on the foreground service's engine:
 * a rule's notify step, a failed run and a question an automation asks
 * become real notifications, shown with the screen off and the app closed.
 * A tap opens the app.
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
                "cancel" -> manager.cancel(call.argument<Int>("id") ?: 0)
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
        if (Build.VERSION.SDK_INT >= 26) {
            // The first asks went on a default-importance channel, and
            // Android never raises a channel's importance, so it is replaced.
            manager.deleteNotificationChannel(OLD_ASKS)
            manager.createNotificationChannel(
                NotificationChannel(QUESTIONS, "Questions from automations", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "An automation waits for your answer" },
            )
        }
        // A heads-up with the answers as buttons. Each ask is its own group
        // so Android does not bundle it with others, which hides the buttons.
        // No full-screen intent: a question never takes over the screen.
        val builder = NotificationCompat.Builder(app, QUESTIONS)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setGroup(group ?: "ask/$askId")
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_ALL)
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
            openIntent(id, link)
        }
        builder.setContentIntent(tap)
        try {
            manager.notify(id, builder.build())
        } catch (_: SecurityException) {
        }
    }

    private fun openIntent(id: Int, link: String?): PendingIntent? {
        val open = (
            if (link != null && link.startsWith("omniflow://open/")) {
                Intent(Intent.ACTION_VIEW, android.net.Uri.parse(link)).setPackage(app.packageName)
            } else {
                app.packageManager.getLaunchIntentForPackage(app.packageName)
            }
            )?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return open?.let { PendingIntent.getActivity(app, id, it, PendingIntent.FLAG_IMMUTABLE) }
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
        val tap = openIntent(id, link)
        val notification = NotificationCompat.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(0xFF00F5D4.toInt())
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
        const val QUESTIONS = "questions"
        private const val OLD_ASKS = "asks"
    }
}
