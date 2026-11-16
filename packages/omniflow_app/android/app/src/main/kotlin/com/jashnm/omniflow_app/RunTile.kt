package com.jashnm.omniflow_app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

/**
 * Three Quick Settings tiles, each holding one scene or automation the
 * person picked in [TilePickerActivity] (a long press on the tile, or the
 * app). A tap runs it through the engine. On the lock screen Android asks
 * for the unlock first, so a locked phone cannot open a door.
 *
 * Exported only to the system, which binds tiles with the
 * BIND_QUICK_SETTINGS_TILE permission that no other app holds.
 */
abstract class RunTile : TileService() {
    protected abstract val slot: Int

    override fun onStartListening() {
        super.onStartListening()
        show()
    }

    override fun onClick() {
        super.onClick()
        val target = RunTargets.tile(this, slot)
        if (target == null) {
            openPicker()
            return
        }
        if (isLocked) unlockAndRun { run(target) } else run(target)
    }

    private fun run(target: RunTarget) {
        RunTargets.runAndSay(this, target) { reachable -> if (!reachable) openApp() }
    }

    private fun show() {
        val tile = qsTile ?: return
        val target = RunTargets.tile(this, slot)
        tile.label = target?.name ?: getString(R.string.tile_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (target == null) "Tap to pick" else if (target.isScene) "Scene" else "Automation"
        }
        tile.icon = Icon.createWithResource(this, R.drawable.ic_notification)
        tile.state = if (target == null) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.updateTile()
    }

    private fun openPicker() = startCollapsed(
        Intent(this, TilePickerActivity::class.java).putExtra(TilePickerActivity.EXTRA_SLOT, slot),
    )

    private fun openApp() {
        packageManager.getLaunchIntentForPackage(packageName)?.let(::startCollapsed)
            ?: Toast.makeText(this, EngineSocket.NOT_RUNNING, Toast.LENGTH_LONG).show()
    }

    // The old call runs only before Android 14, behind the version check.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun startCollapsed(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, slot, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        private val TILES = listOf(RunTile1::class.java, RunTile2::class.java, RunTile3::class.java)

        fun slotOf(component: ComponentName?): Int? =
            TILES.indexOfFirst { it.name == component?.className }.takeIf { it >= 0 }?.plus(1)

        /** Asks Android to redraw every tile, after a pick or a rename. */
        fun refreshAll(context: Context) {
            TILES.forEach { requestListeningState(context, ComponentName(context, it)) }
        }
    }
}

class RunTile1 : RunTile() {
    override val slot = 1
}

class RunTile2 : RunTile() {
    override val slot = 2
}

class RunTile3 : RunTile() {
    override val slot = 3
}

/**
 * Picks what a Quick Settings tile runs. Android opens it on a long press
 * of the tile (so it is exported for that action), and the app and an empty
 * tile open it too. It only saves a pick and never runs anything.
 */
class TilePickerActivity : PickerActivity() {
    private var slot = 0

    override val title get() = if (slot == 0) "Pick a Quick Settings tile" else "Pick what tile $slot runs"

    override fun accept(): Boolean {
        slot = if (intent.action == TileService.ACTION_QS_TILE_PREFERENCES) {
            val component = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_COMPONENT_NAME)
            }
            if (component?.packageName != packageName) return false
            RunTile.slotOf(component) ?: return false
        } else {
            intent.getIntExtra(EXTRA_SLOT, 0).takeIf { it in 1..RunTargets.TILE_SLOTS } ?: 0
        }
        return true
    }

    override fun show(targets: List<RunTarget>) {
        if (slot != 0) return pickFor(targets)
        val labels = (1..RunTargets.TILE_SLOTS).map { "Tile $it: ${RunTargets.tile(this, it)?.name ?: "empty"}" }
        showDialog(
            builder()
                .setItems(labels.toTypedArray()) { _, which ->
                    slot = which + 1
                    // The first dialog's dismiss would finish the activity.
                    dialog?.setOnDismissListener(null)
                    pickFor(targets)
                }
                .create(),
        )
    }

    private fun pickFor(targets: List<RunTarget>) {
        showSingle(targets, extra = "Nothing") { picked ->
            RunTargets.setTile(this, slot, picked)
            RunTile.refreshAll(this)
            Toast.makeText(
                this,
                if (picked == null) "Tile $slot is empty" else "Tile $slot runs ${picked.name}",
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    companion object {
        const val EXTRA_SLOT = "slot"
    }
}
