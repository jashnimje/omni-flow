package com.jashnm.omniflow_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home screen widgets with the person's scenes and automations: a tap runs
 * one through the engine. The small widget holds one, the wide one up to
 * four. The person picks them in [WidgetConfigActivity].
 *
 * The provider is exported only for the launcher's widget broadcasts, which
 * carry no run. A tap goes to [RunReceiver], which is not exported.
 */
abstract class RunWidget : AppWidgetProvider() {
    protected abstract val slots: Int

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { render(context, manager, it) }
        // Names can change in the app: read them again, then redraw.
        val pending = goAsync()
        Thread {
            try {
                if (RunTargets.refreshNames(context)) ids.forEach { render(context, manager, it) }
            } finally {
                pending.finish()
            }
        }.start()
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        // The provider is exported, so only a widget Android no longer has
        // loses its picks: another app cannot clear a live one.
        val manager = AppWidgetManager.getInstance(context)
        ids.filter { manager.getAppWidgetInfo(it) == null }.forEach { RunTargets.removeWidget(context, it) }
    }

    fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
        manager.updateAppWidget(widgetId, views(context, widgetId, slots))
    }

    companion object {
        private val SLOT_VIEWS = intArrayOf(R.id.widget_slot0, R.id.widget_slot1, R.id.widget_slot2, R.id.widget_slot3)

        fun views(context: Context, widgetId: Int, slots: Int): RemoteViews {
            val targets = RunTargets.widget(context, widgetId).take(slots)
            val layout = if (slots == 1) R.layout.widget_small else R.layout.widget_wide
            val views = RemoteViews(context.packageName, layout)
            val pick = PendingIntent.getActivity(
                context,
                widgetId,
                Intent(context, WidgetConfigActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            views.setViewVisibility(R.id.widget_empty, if (targets.isEmpty()) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(R.id.widget_empty, pick)
            SLOT_VIEWS.take(if (slots == 1) 1 else SLOT_VIEWS.size).forEachIndexed { i, viewId ->
                val target = targets.getOrNull(i)
                if (target == null) {
                    views.setViewVisibility(viewId, View.GONE)
                } else {
                    views.setViewVisibility(viewId, View.VISIBLE)
                    views.setTextViewText(viewId, target.name)
                    views.setContentDescription(viewId, "Run ${target.name}")
                    views.setOnClickPendingIntent(viewId, RunReceiver.pendingRun(context, widgetId * 10 + i, target))
                }
            }
            return views
        }

        /** Redraws every widget, after a pick or a rename. */
        fun renderAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for ((cls, slots) in listOf(RunWidgetSmall::class.java to 1, RunWidgetWide::class.java to 4)) {
                manager.getAppWidgetIds(ComponentName(context, cls)).forEach {
                    manager.updateAppWidget(it, views(context, it, slots))
                }
            }
        }
    }
}

class RunWidgetSmall : RunWidget() {
    override val slots = 1
}

class RunWidgetWide : RunWidget() {
    override val slots = 4
}

/**
 * Runs the scene or automation a widget button names. Not exported: only
 * this app's own pending intents reach it.
 */
class RunReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_RUN) return
        val target = RunTarget.fromJson(intent.getStringExtra(EXTRA_TARGET)?.let { runCatching { JSONObject(it) }.getOrNull() })
            ?: return
        val pending = goAsync()
        // Finished once the engine has it: a run can outlast a broadcast.
        RunTargets.runAndSay(context, target) { pending.finish() }
    }

    companion object {
        const val ACTION_RUN = "com.jashnm.omniflow_app.RUN"
        const val EXTRA_TARGET = "target"

        fun pendingRun(context: Context, requestCode: Int, target: RunTarget): PendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            Intent(context, RunReceiver::class.java)
                .setAction(ACTION_RUN)
                .putExtra(EXTRA_TARGET, target.toJson().toString()),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

/**
 * Picks what a widget holds. The launcher starts it when the widget is
 * added (so it is exported, as Android requires), and a tap on an empty
 * widget opens it. It only saves a pick for a widget of this app, and never
 * runs anything.
 */
class WidgetConfigActivity : PickerActivity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var slots = 1

    override val title get() = if (slots == 1) "Pick what this widget runs" else "Pick up to $slots for this widget"

    override fun accept(): Boolean {
        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        val info = AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId) ?: return false
        if (info.provider.packageName != packageName) return false
        slots = if (info.provider.className == RunWidgetWide::class.java.name) 4 else 1
        return true
    }

    override fun show(targets: List<RunTarget>) {
        if (slots == 1) {
            showSingle(targets) { picked -> save(listOfNotNull(picked)) }
        } else {
            showMany(targets, RunTargets.widget(this, widgetId), slots, ::save)
        }
    }

    private fun save(picked: List<RunTarget>) {
        RunTargets.setWidget(this, widgetId, picked)
        val manager = AppWidgetManager.getInstance(this)
        manager.updateAppWidget(widgetId, RunWidget.views(this, widgetId, slots))
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish()
    }
}
