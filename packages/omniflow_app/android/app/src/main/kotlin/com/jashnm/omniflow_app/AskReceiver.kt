package com.jashnm.omniflow_app

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.core.app.RemoteInput
import org.json.JSONObject

/**
 * Sends the person's answer to an automation's question (`ask.answer`) to
 * the engine, from a notification action or its reply box. Not exported:
 * only this app's pending intents on its own notifications reach it.
 */
class AskReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_ANSWER) return
        val askId = intent.getStringExtra(EXTRA_ASK) ?: return
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION, 0)
        val answer = intent.getStringExtra(EXTRA_ANSWER)
            ?: RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_KEY)?.toString()
            ?: return
        val pending = goAsync()
        answer(context, askId, answer, notificationId) { pending.finish() }
    }

    companion object {
        const val ACTION_ANSWER = "com.jashnm.omniflow_app.ANSWER"
        const val REPLY_KEY = "answer"
        private const val EXTRA_ASK = "askId"
        private const val EXTRA_ANSWER = "answer"
        private const val EXTRA_NOTIFICATION = "notification"

        /**
         * Sends [answer] for [askId], then takes the question's notification
         * down. The engine closes the ask (`ask.closed`) too; this only
         * keeps the notification from waiting on that.
         */
        fun answer(context: Context, askId: String, answer: String, notificationId: Int, done: () -> Unit = {}) {
            val app = context.applicationContext
            EngineSocket.callAsync(app, "ask.answer", JSONObject().put("askId", askId).put("answer", answer)) { reply ->
                (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(notificationId)
                if (!reply.optBoolean("ok")) {
                    Toast.makeText(app, EngineSocket.messageOf(reply), Toast.LENGTH_LONG).show()
                }
                done()
            }
        }

        private fun base(context: Context, notificationId: Int, askId: String) = Intent(context, AskReceiver::class.java)
            .setAction(ACTION_ANSWER)
            .putExtra(EXTRA_ASK, askId)
            .putExtra(EXTRA_NOTIFICATION, notificationId)

        fun pendingAnswer(context: Context, notificationId: Int, index: Int, askId: String, answer: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                notificationId * 8 + index,
                base(context, notificationId, askId).putExtra(EXTRA_ANSWER, answer),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

        /** The reply box's intent. Android fills the typed text in, so it
         * must be mutable; it names this receiver, so nothing can redirect it. */
        fun pendingReply(context: Context, notificationId: Int, askId: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                notificationId * 8 + 7,
                base(context, notificationId, askId),
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0,
            )
    }
}
