package com.jashnm.omniflow_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.Toast
import org.json.JSONException
import java.io.IOException
import java.net.SocketTimeoutException
import org.json.JSONArray
import org.json.JSONObject

/**
 * A scene or an automation the person put on a widget, tile or shortcut.
 * [color] is the automation's `#RRGGBB` colour from the engine, shown in the
 * share picker and never kept.
 */
data class RunTarget(val kind: String, val id: String, val name: String, val color: String? = null) {
    val isScene get() = kind == SCENE

    fun toJson(): JSONObject = JSONObject().put("kind", kind).put("id", id).put("name", name)

    companion object {
        const val SCENE = "scene"
        const val AUTOMATION = "automation"

        fun fromJson(json: JSONObject?): RunTarget? {
            val id = json?.optString("id")?.takeIf { it.isNotEmpty() } ?: return null
            val kind = if (json.optString("kind") == SCENE) SCENE else AUTOMATION
            return RunTarget(kind, id, json.optString("name").ifEmpty { id })
        }
    }
}

/**
 * Which scenes and automations sit on each widget, tile and launcher
 * shortcut, kept in the app's private preferences, and the engine calls that
 * list and run them. Only ids and names are kept here: the engine decides
 * what a run does.
 */
object RunTargets {
    private const val PREFS = "omniflow_run_from_anywhere"
    private val COLOR = Regex("#[0-9A-Fa-f]{6}")
    const val TILE_SLOTS = 3
    const val MAX_SHORTCUTS = 4

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readList(context: Context, key: String): List<RunTarget> {
        val raw = prefs(context).getString(key, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { RunTarget.fromJson(array.optJSONObject(it)) }
    }

    private fun writeList(context: Context, key: String, targets: List<RunTarget>) {
        val array = JSONArray()
        targets.forEach { array.put(it.toJson()) }
        prefs(context).edit().putString(key, array.toString()).apply()
    }

    fun widget(context: Context, widgetId: Int) = readList(context, "widget.$widgetId")

    fun setWidget(context: Context, widgetId: Int, targets: List<RunTarget>) =
        writeList(context, "widget.$widgetId", targets)

    fun removeWidget(context: Context, widgetId: Int) =
        prefs(context).edit().remove("widget.$widgetId").apply()

    fun tile(context: Context, slot: Int): RunTarget? = readList(context, "tile.$slot").firstOrNull()

    fun setTile(context: Context, slot: Int, target: RunTarget?) =
        writeList(context, "tile.$slot", listOfNotNull(target))

    fun shortcuts(context: Context) = readList(context, "shortcuts")

    fun setShortcuts(context: Context, targets: List<RunTarget>) =
        writeList(context, "shortcuts", targets.take(MAX_SHORTCUTS))

    /**
     * Every scene, then every automation, from the engine. Blocking: call it
     * off the main thread. Null when the engine is not running.
     */
    fun fetchAll(context: Context, automationsOnly: Boolean = false): List<RunTarget>? {
        val out = mutableListOf<RunTarget>()
        if (!automationsOnly) {
            val scenes = EngineSocket.callOrFailure(context, "scene.list")
            if (!scenes.optBoolean("ok")) return null
            scenes.optJSONArray("scenes")?.let { list ->
                for (i in 0 until list.length()) {
                    val s = list.optJSONObject(i) ?: continue
                    val id = s.optString("id")
                    if (id.isEmpty()) continue
                    out += RunTarget(RunTarget.SCENE, id, s.optString("name").ifEmpty { id })
                }
            }
        }
        val automations = EngineSocket.callOrFailure(context, "automation.list")
        if (!automations.optBoolean("ok")) return null
        automations.optJSONArray("automations")?.let { list ->
            for (i in 0 until list.length()) {
                val a = list.optJSONObject(i) ?: continue
                if (a.optString("source") == RunTarget.SCENE) continue
                val id = a.optString("id")
                if (id.isEmpty()) continue
                val color = a.optString("color").takeIf { COLOR.matches(it) }
                out += RunTarget(RunTarget.AUTOMATION, id, a.optString("name").ifEmpty { id }, color)
            }
        }
        return out
    }

    /**
     * Renames every kept target to its current name, so a renamed scene
     * shows its new name. A target the engine no longer has keeps its last
     * name; tapping it then says it is gone. Blocking. False when nothing is
     * kept or the engine is not running.
     */
    fun refreshNames(context: Context): Boolean {
        val keys = prefs(context).all.keys.filter {
            it.startsWith("widget.") || it.startsWith("tile.") || it == "shortcuts"
        }
        if (keys.isEmpty()) return false
        val names = fetchAll(context)?.associateBy { it.kind to it.id } ?: return false
        val fresh = { t: RunTarget -> names[t.kind to t.id] ?: t }
        for (key in keys) writeList(context, key, readList(context, key).map(fresh))
        return true
    }

    /** The engine command and args that run [target], with [msg] as the
     * run's trigger details (automations only: a scene takes none). */
    private fun runCall(target: RunTarget, msg: JSONObject?): Pair<String, JSONObject> {
        val args = JSONObject().put("id", target.id)
        if (msg != null && !target.isScene) args.put("msg", msg)
        return (if (target.isScene) "scene.run" else "automation.run") to args
    }

    /**
     * Runs [target] off the main thread and says in a toast that it started,
     * or why not. A run answers when it finishes, which can take minutes
     * (waits, questions), so [started] runs on the main thread as soon as
     * the engine has the command, true, or false when OmniFlow is not
     * running. A failure during the run is announced by the engine as a
     * notification, as for any run.
     */
    fun runAndSay(context: Context, target: RunTarget, msg: JSONObject? = null, started: (Boolean) -> Unit = {}) {
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        val (command, args) = runCall(target, msg)
        Thread {
            var sent = false
            fun attempt(): JSONObject? = try {
                EngineSocket.call(app, command, args, RUN_TIMEOUT_MS) {
                    sent = true
                    main.post {
                        Toast.makeText(app, "Running ${target.name}", Toast.LENGTH_SHORT).show()
                        started(true)
                    }
                }
            } catch (_: SocketTimeoutException) {
                null
            } catch (_: IOException) {
                // Lost after the engine had it: the run goes on regardless.
                if (sent) null else EngineSocket.failure(EngineSocket.UNREACHABLE, EngineSocket.NOT_RUNNING)
            } catch (_: JSONException) {
                null
            }
            var reply = attempt()
            // A tap on a widget, tile or shortcut is a time Android lets the
            // app start its service: start it, wait for the engine, and try
            // once more.
            if (!sent && reply?.optJSONObject("error")?.optString("type") == EngineSocket.UNREACHABLE) {
                val failed = ServiceStarter.start(app)
                reply = if (failed != null) {
                    EngineSocket.failure(EngineSocket.UNREACHABLE, failed)
                } else if (waitForEngine(app)) {
                    attempt()
                } else {
                    EngineSocket.failure(EngineSocket.UNREACHABLE, STARTING)
                }
            }
            main.post {
                if (!sent) started(false)
                if (reply != null && !reply.optBoolean("ok")) {
                    Toast.makeText(app, "${target.name}: ${EngineSocket.messageOf(reply)}", Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    /** Waits up to [START_WAIT_MS] for the engine to answer on its socket. */
    private fun waitForEngine(app: Context): Boolean {
        val until = SystemClock.elapsedRealtime() + START_WAIT_MS
        while (SystemClock.elapsedRealtime() < until) {
            try {
                EngineSocket.call(app, "engine.status", JSONObject(), 2_000)
                return true
            } catch (_: IOException) {
            } catch (_: JSONException) {
                return true
            }
            Thread.sleep(500)
        }
        return false
    }

    private const val RUN_TIMEOUT_MS = 600_000
    private const val START_WAIT_MS = 20_000L
    private const val STARTING = "OmniFlow is starting. Try again in a moment"
}
