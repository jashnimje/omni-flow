package com.jashnm.omniflow_app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.util.Base64
import org.json.JSONObject
import java.io.File

/**
 * Hands one engine command from a computer to the engine's private control
 * socket, so an agent can set OmniFlow up with `omni --phone` or MCP and no
 * screen. Only adb's shell user (or root) may call it: a computer gets that
 * only after the phone owner allows it for USB or wireless debugging.
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
        } catch (e: Exception) {
            failure(
                "unreachable",
                "OmniFlow is not running on the phone. Open the app once, then try again",
            )
        }
        return Bundle().apply {
            putString("result", Base64.encodeToString(reply.toByteArray(), Base64.NO_WRAP))
        }
    }

    private fun forward(request: String): String {
        val json = JSONObject(request)
        val line = JSONObject()
            .put("id", 1)
            .put("command", json.getString("command"))
            .put("args", json.optJSONObject("args") ?: JSONObject())
        val socket = File(context!!.filesDir, "omniflow/omni.sock")
        LocalSocket().use { local ->
            local.connect(LocalSocketAddress(socket.path, LocalSocketAddress.Namespace.FILESYSTEM))
            local.soTimeout = TIMEOUT_MS
            local.outputStream.write((line.toString() + "\n").toByteArray())
            local.outputStream.flush()
            val answer = local.inputStream.bufferedReader().readLine()
                ?: return failure("unreachable", "the engine closed the connection")
            return JSONObject(answer).getJSONObject("result").toString()
        }
    }

    private fun failure(type: String, message: String) = JSONObject()
        .put("ok", false)
        .put("error", JSONObject().put("type", type).put("message", message))
        .toString()

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
