package com.jashnm.omniflow_app

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.widget.Toast

/**
 * A small dialog over whatever is on screen that lists the person's scenes
 * and automations, read from the engine. Subclasses say what a pick does.
 * Nothing runs until the person picks.
 */
abstract class PickerActivity : Activity() {
    protected var dialog: AlertDialog? = null

    /** Whether to list only automations (the share sheet: a scene takes no
     * shared text). */
    protected open val automationsOnly = false

    protected abstract val title: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!accept()) return finish()
        Thread {
            val targets = RunTargets.fetchAll(this, automationsOnly)
            runOnUiThread {
                if (isFinishing) return@runOnUiThread
                when {
                    targets == null -> fail(EngineSocket.NOT_RUNNING)
                    targets.isEmpty() -> fail(
                        if (automationsOnly) "You have no automations yet" else "You have no scenes or automations yet",
                    )
                    else -> show(targets)
                }
            }
        }.start()
    }

    /** False to close at once, for an intent this activity will not serve. */
    protected open fun accept() = true

    protected abstract fun show(targets: List<RunTarget>)

    protected fun label(t: RunTarget) = if (t.isScene) "${t.name}  (scene)" else t.name

    protected fun builder(): AlertDialog.Builder =
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(title)
            .setOnCancelListener { finish() }

    protected fun showDialog(built: AlertDialog) {
        dialog = built
        built.setOnDismissListener { if (!isChangingConfigurations) finish() }
        built.show()
    }

    protected fun fail(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        finish()
    }

    override fun onDestroy() {
        dialog?.setOnDismissListener(null)
        dialog?.dismiss()
        super.onDestroy()
    }

    /** One pick. */
    protected fun showSingle(targets: List<RunTarget>, extra: String? = null, onPick: (RunTarget?) -> Unit) {
        val labels = targets.map(::label) + listOfNotNull(extra)
        showDialog(
            builder()
                .setItems(labels.toTypedArray()) { _, which -> onPick(targets.getOrNull(which)) }
                .create(),
        )
    }

    /** Up to [max] picks, starting from [chosen]. */
    protected fun showMany(
        targets: List<RunTarget>,
        chosen: List<RunTarget>,
        max: Int,
        onDone: (List<RunTarget>) -> Unit,
    ) {
        val keys = chosen.map { it.kind to it.id }.toSet()
        val checked = BooleanArray(targets.size) { (targets[it].kind to targets[it].id) in keys }
        var built: AlertDialog? = null
        built = builder()
            .setMultiChoiceItems(targets.map(::label).toTypedArray(), checked) { _, which, on ->
                if (on && checked.count { it } >= max) {
                    built?.listView?.setItemChecked(which, false)
                    Toast.makeText(this, "Pick up to $max", Toast.LENGTH_SHORT).show()
                } else {
                    checked[which] = on
                }
            }
            .setPositiveButton("Done") { _, _ ->
                onDone(targets.filterIndexed { i, _ -> checked[i] })
            }
            .setNegativeButton("Cancel", null)
            .create()
        showDialog(built)
    }
}
