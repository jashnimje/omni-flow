package com.jashnm.omniflow_app

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * The list of answers to an automation's question when there are more than
 * the three Android shows as notification actions. Not exported: only the
 * question's own notification opens it.
 */
class AskActivity : Activity() {
    private var dialog: AlertDialog? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val askId = intent.getStringExtra(EXTRA_ASK)
        val choices = intent.getStringArrayListExtra(EXTRA_CHOICES)
        if (askId == null || choices.isNullOrEmpty()) return finish()
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION, 0)
        dialog = AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(intent.getStringExtra(EXTRA_TITLE) ?: "OmniFlow")
            .setItems(choices.toTypedArray()) { _, which ->
                AskReceiver.answer(this, askId, choices[which], notificationId)
            }
            .setOnDismissListener { finish() }
            .create()
            .also { it.show() }
    }

    override fun onDestroy() {
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        super.onDestroy()
    }

    companion object {
        private const val EXTRA_ASK = "askId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CHOICES = "choices"
        private const val EXTRA_NOTIFICATION = "notification"

        fun pendingChooser(context: Context, notificationId: Int, askId: String, title: String, choices: List<String>): PendingIntent =
            PendingIntent.getActivity(
                context,
                notificationId,
                Intent(context, AskActivity::class.java)
                    .putExtra(EXTRA_ASK, askId)
                    .putExtra(EXTRA_TITLE, title)
                    .putStringArrayListExtra(EXTRA_CHOICES, ArrayList(choices))
                    .putExtra(EXTRA_NOTIFICATION, notificationId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
    }
}
