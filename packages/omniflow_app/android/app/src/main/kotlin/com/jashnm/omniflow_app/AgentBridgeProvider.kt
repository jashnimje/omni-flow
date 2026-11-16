package com.jashnm.omniflow_app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.util.Base64
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.SocketTimeoutException

/**
 * Hands one engine command from a computer to the engine's private control
 * socket, so OmniFlow can be set up from a computer with `omni --phone` or
 * MCP and no screen.
 * Only adb's shell user (or root) may call it: a computer gets that only
 * after the phone owner allows it for USB or wireless debugging.
 * Nothing listens on the network.
 *
 * `adb shell content call --uri content://com.jashnm.omniflow_app.agent
 * --method handle --arg <base64 {"command", "args"}>` answers
 * `result=<base64 reply>`.
 */
class AgentBridgeProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val uid = Binder.getCallingUid()
        if (uid != SHELL_UID && uid != ROOT_UID) {
            throw SecurityException("only adb can use the OmniFlow agent bridge")
        }
        require(method == "handle" && arg != null) { "call handle with a base64 request" }
        val reply = try {
            forward(String(Base64.decode(arg, Base64.DEFAULT), Charsets.UTF_8))
        } catch (e: JSONException) {
            failure("invalid", "the request is not {command, args} JSON: ${e.message}")
        } catch (e: IllegalArgumentException) {
            failure("invalid", "the request is not base64")
        } catch (e: SocketTimeoutException) {
            failure("timeout", "the engine did not answer within ${TIMEOUT_MS / 1000} s")
        } catch (e: IOException) {
            failure(
                "unreachable",
                "OmniFlow is not running on the phone. Open the app once, then try again",
            )
        }
        return Bundle().apply {
            putString("result", Base64.encodeToString(reply.toByteArray(), Base64.NO_WRAP))
        }
    }

    /**
     * A command from `omni --phone` runs as the phone owner's, the same as
     * the `omni` CLI on a computer: adb reaches the phone only after its
     * owner allowed that computer, and with adb a computer can already drive
     * the whole screen. `omni mcp --phone` sends its tools as `agent.call`,
     * which keeps an agent to its access level.
     */
    private fun forward(request: String): String {
        val json = JSONObject(request)
        return EngineSocket.call(
            context!!,
            json.getString("command"),
            json.optJSONObject("args") ?: JSONObject(),
            TIMEOUT_MS,
        ).toString()
    }

    private fun failure(type: String, message: String) = EngineSocket.failure(type, message).toString()

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0

    private companion object {
        const val SHELL_UID = 2000
        const val ROOT_UID = 0
        const val TIMEOUT_MS = 120_000
    }
}
