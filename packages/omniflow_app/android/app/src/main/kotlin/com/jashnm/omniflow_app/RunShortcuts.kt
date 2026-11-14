package com.jashnm.omniflow_app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.json.JSONObject

/**
 * Launcher shortcuts (a long press on the OmniFlow icon) for up to four
 * favourite scenes and automations, picked in [ShortcutsPickerActivity].
 * Each shortcut is also bound to Google Assistant's "open app feature"
 * capability under its name.
 */
object RunShortcuts {
    private const val FEATURE = "actions.intent.OPEN_APP_FEATURE"

    fun publish(context: Context, targets: List<RunTarget>) {
        val shortcuts = targets.take(RunTargets.MAX_SHORTCUTS).mapIndexed { rank, t ->
            ShortcutInfoCompat.Builder(context, "run-${t.kind}-${t.id}")
                .setShortLabel(t.name.take(24))
                .setLongLabel("Run ${t.name}")
                .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                .setRank(rank)
                .setIntent(RunShortcutActivity.intent(context, t))
                .addCapabilityBinding(FEATURE, "feature", listOf(t.name))
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts)
    }

    /** Renames the published shortcuts after the names were read again. */
    fun republish(context: Context) = publish(context, RunTargets.shortcuts(context))
}

/**
 * Runs the scene or automation a launcher shortcut names, then closes. Not
 * exported: the launcher starts a shortcut's intent as this app, so no
 * other app can start it.
 */
class RunShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val target = RunTarget.fromJson(intent.getStringExtra(EXTRA_TARGET)?.let { runCatching { JSONObject(it) }.getOrNull() })
        if (target == null) return finish()
        RunTargets.runAndSay(this, target) { reachable ->
            if (!reachable) packageManager.getLaunchIntentForPackage(packageName)?.let(::startActivity)
            finish()
        }
    }

    companion object {
        private const val EXTRA_TARGET = "target"

        fun intent(context: Context, target: RunTarget): Intent = Intent(context, RunShortcutActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .putExtra(EXTRA_TARGET, target.toJson().toString())
    }
}

/** Picks up to four launcher shortcuts. Opened from the app only. */
class ShortcutsPickerActivity : PickerActivity() {
    override val title = "Pick up to ${RunTargets.MAX_SHORTCUTS} shortcuts"

    override fun show(targets: List<RunTarget>) {
        showMany(targets, RunTargets.shortcuts(this), RunTargets.MAX_SHORTCUTS) { picked ->
            RunTargets.setShortcuts(this, picked)
            RunShortcuts.publish(this, picked)
        }
    }
}

/**
 * The share sheet's "Run an automation". Exported, as the share sheet
 * requires, but it only lists automations: one runs only when the person
 * picks it, with the shared text as `msg.shared`.
 */
class ShareActivity : PickerActivity() {
    override val automationsOnly = true
    override val title = "Run an automation with this"

    private var shared: JSONObject? = null

    override fun accept(): Boolean {
        if (intent.action != Intent.ACTION_SEND) return false
        val text = (intent.getCharSequenceExtra(Intent.EXTRA_TEXT) ?: intent.getStringExtra(Intent.EXTRA_SUBJECT))
            ?.toString()
            ?.take(MAX_TEXT)
            ?.takeIf { it.isNotBlank() }
            ?: return false.also { fail("There is no text to share") }
        val url = URL.find(text)?.value?.trimEnd('.', ',', ')', '"')
        shared = JSONObject().put("text", text).apply { if (url != null) put("url", url) }
        return true
    }

    /**
     * OmniFlow's own dark sheet: what was shared at the top, then one row per
     * automation with its colour dot. A tap runs that one; anything else
     * closes the sheet and runs nothing.
     */
    override fun show(targets: List<RunTarget>) {
        val share = shared ?: return finish()
        var built: AlertDialog? = null
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        targets.forEach { target ->
            rows.addView(
                row(target) {
                    built?.dismiss()
                    RunTargets.runAndSay(this, target, JSONObject().put("shared", share))
                },
            )
        }
        val sheet = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(8))
            addView(text(title, 18f, TEXT, bold = true))
            addView(
                text(share.optString("url").ifEmpty { share.optString("text") }, 14f, ACCENT).apply {
                    maxLines = 3
                    ellipsize = TextUtils.TruncateAt.END
                    setPadding(dp(12), dp(10), dp(12), dp(10))
                    background = rounded(CARD, dp(12).toFloat())
                },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                    .apply { topMargin = dp(12); bottomMargin = dp(8) },
            )
            addView(text("Pick one to run. Nothing runs until you do.", 13f, MUTED).apply { setPadding(0, 0, 0, dp(8)) })
            addView(
                ScrollView(this@ShareActivity).apply { addView(rows) },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT),
            )
        }
        built = builder()
            .setTitle(null)
            .setView(sheet)
            .setNegativeButton("Cancel", null)
            .create()
        built.window?.setBackgroundDrawable(rounded(SHEET, dp(24).toFloat()))
        showDialog(built)
        built.getButton(AlertDialog.BUTTON_NEGATIVE)?.setTextColor(ACCENT)
    }

    private fun row(target: RunTarget, onTap: () -> Unit): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(52)
        setPadding(dp(12), 0, dp(12), 0)
        isClickable = true
        isFocusable = true
        background = obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground))
            .run { getDrawable(0).also { recycle() } }
        contentDescription = "Run ${target.name}"
        setOnClickListener { onTap() }
        addView(
            View(context).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(dotColor(target)) } },
            LinearLayout.LayoutParams(dp(12), dp(12)).apply { marginEnd = dp(14) },
        )
        addView(
            text(target.name, 16f, TEXT).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
    }

    private fun dotColor(target: RunTarget) =
        target.color?.let { runCatching { Color.parseColor(it) }.getOrNull() } ?: ACCENT

    private fun text(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun rounded(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val MAX_TEXT = 10_000

        // OmniColors in lib/ui/design/tokens.dart.
        const val SHEET = 0xFF181C22.toInt()
        const val CARD = 0xFF1A1E24.toInt()
        const val TEXT = 0xFFE8ECF1.toInt()
        const val MUTED = 0xFF8B95A3.toInt()
        const val ACCENT = 0xFF00F5D4.toInt()
        val URL = Regex("https?://\\S+")
    }
}
