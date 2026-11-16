package com.jashnm.omniflow_app

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationManagerCompat

/**
 * "A notification arrives from" triggers. Android binds this service only
 * after the person turns on notification access for OmniFlow, and only the
 * system can bind it (BIND_NOTIFICATION_LISTENER_SERVICE).
 *
 * Each new notification goes straight to the running engine as a reading
 * (`phone.notification`). Its text is never logged or kept here, and the
 * engine keeps it only in the trigger's event.
 */
class NotificationTriggers : NotificationListenerService() {
    /** The last title and text sent per notification, so a notification
     * that updates in place (a progress bar, a timer) is not sent again. */
    private val sent = LinkedHashMap<String, Int>()

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        if (n.packageName == packageName) return
        val notification = n.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = (extras?.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras?.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()
            ?.take(MAX_TEXT)
        if (title == null && text == null) return
        val fingerprint = (title to text).hashCode()
        if (sent[n.key] == fingerprint) return
        sent[n.key] = fingerprint
        if (sent.size > MAX_KEPT) sent.remove(sent.keys.first())
        PhoneSensorsBridge.emit(
            mapOf(
                "kind" to "notification",
                "package" to n.packageName,
                "label" to PhoneSensorsBridge.labelOf(this, n.packageName),
                "title" to title,
                "text" to text,
            ),
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn?.key?.let { sent.remove(it) }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        connected = true
    }

    /** Android unbinds a listener after an update, a crash or on its own,
     * and may not bind it again until access is toggled: ask at once, so
     * notification and media triggers keep working. */
    override fun onListenerDisconnected() {
        connected = false
        sent.clear()
        super.onListenerDisconnected()
        rebind(this)
    }

    companion object {
        private const val MAX_TEXT = 2_000
        private const val MAX_KEPT = 200

        /** Whether Android has the listener bound now. */
        @Volatile var connected = false
            private set

        /** Asks Android to bind the listener again when the person allowed
         * notification access but it is not bound. */
        fun rebindIfNeeded(context: Context) {
            if (connected) return
            val allowed = NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
            if (allowed) rebind(context)
        }

        private fun rebind(context: Context) {
            try {
                NotificationListenerService.requestRebind(ComponentName(context, NotificationTriggers::class.java))
            } catch (_: RuntimeException) {
                // Access was turned off meanwhile: nothing to bind.
            }
        }
    }
}
