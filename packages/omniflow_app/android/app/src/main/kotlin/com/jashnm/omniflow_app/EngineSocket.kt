package com.jashnm.omniflow_app

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Sends one command to the engine in the foreground service over its
 * private control socket (`filesDir/omniflow/omni.sock`, mode 0600 in a 0700
 * directory). Widgets, tiles, launcher shortcuts, the share sheet and the
 * answers to asks all reach the engine this way, so nothing listens on the
 * network and no other app can reach the socket.
 */
object EngineSocket {
    private val worker = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    /** The engine's answer, `{ok, ...}`. Throws [IOException] when the
     * service is not running, or did not answer within [timeoutMs].
     * [onSent] runs on the calling thread once the engine has the command,
     * before its answer. */
    @Throws(IOException::class)
    fun call(
        context: Context,
        command: String,
        args: JSONObject = JSONObject(),
        timeoutMs: Int = 15_000,
        onSent: () -> Unit = {},
    ): JSONObject {
        val line = JSONObject().put("id", 1).put("command", command).put("args", args)
        val socket = File(context.applicationContext.filesDir, "omniflow/omni.sock")
        LocalSocket().use { local ->
            local.connect(LocalSocketAddress(socket.path, LocalSocketAddress.Namespace.FILESYSTEM))
            local.soTimeout = timeoutMs
            local.outputStream.write((line.toString() + "\n").toByteArray())
            local.outputStream.flush()
            onSent()
            val answer = local.inputStream.bufferedReader().readLine()
                ?: throw IOException("the engine closed the connection")
            return JSONObject(answer).optJSONObject("result")
                ?: failure("internal", "the engine sent no result")
        }
    }

    /** [call] off the main thread. [done] runs on the main thread, with a
     * failure `{ok: false, error: {type: "unreachable"}}` when the service is
     * not running. */
    fun callAsync(
        context: Context,
        command: String,
        args: JSONObject = JSONObject(),
        done: (JSONObject) -> Unit = {},
    ) {
        val app = context.applicationContext
        worker.execute {
            val reply = callOrFailure(app, command, args)
            main.post { done(reply) }
        }
    }

    /** [call], with a failed connection as a failure reply. */
    fun callOrFailure(context: Context, command: String, args: JSONObject = JSONObject()): JSONObject = try {
        call(context, command, args)
    } catch (_: IOException) {
        failure(UNREACHABLE, NOT_RUNNING)
    } catch (_: org.json.JSONException) {
        failure("internal", "the engine sent a reply that is not JSON")
    }

    fun failure(type: String, message: String): JSONObject = JSONObject()
        .put("ok", false)
        .put("error", JSONObject().put("type", type).put("message", message))

    /** The plain message of a failed reply. */
    fun messageOf(reply: JSONObject): String =
        reply.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: "That did not work"

    const val UNREACHABLE = "unreachable"
    const val NOT_RUNNING = "OmniFlow is not running. Open the app once, then try again"
}
