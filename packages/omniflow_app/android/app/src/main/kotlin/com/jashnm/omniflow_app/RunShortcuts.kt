package com.jashnm.omniflow_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
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

    override fun show(targets: List<RunTarget>) {
        showSingle(targets) { picked ->
            val share = shared ?: return@showSingle
            if (picked != null) RunTargets.runAndSay(this, picked, JSONObject().put("shared", share))
        }
    }

    private companion object {
        const val MAX_TEXT = 10_000
        val URL = Regex("https?://\\S+")
    }
}
