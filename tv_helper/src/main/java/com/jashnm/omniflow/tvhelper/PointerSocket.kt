package com.jashnm.omniflow.tvhelper

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

/** One line from OmniFlow, with every number already checked. */
sealed class PointerCommand {
    object Show : PointerCommand()
    object Hide : PointerCommand()
    data class To(val x: Double, val y: Double) : PointerCommand()
    data class By(val dx: Double, val dy: Double) : PointerCommand()

    companion object {
        /** The command in [line], or null when it is not one. */
        fun parse(line: String): PointerCommand? {
            val json = try {
                JSONObject(line)
            } catch (e: JSONException) {
                return null
            }
            if (json.optBoolean("hide")) return Hide
            pair(json, "to", 0.0, 1.0)?.let { return To(it.first, it.second) }
            pair(json, "by", -1.0, 1.0)?.let { return By(it.first, it.second) }
            if (json.optBoolean("show")) return Show
            return null
        }

        private fun pair(json: JSONObject, key: String, low: Double, high: Double): Pair<Double, Double>? {
            val array = json.optJSONArray(key) ?: return null
            if (array.length() != 2) return null
            val a = array.optDouble(0)
            val b = array.optDouble(1)
            if (a.isNaN() || b.isNaN() || a !in low..high || b !in low..high) return null
            return a to b
        }
    }
}

/**
 * Listens on the abstract Unix socket [name], never on the network, and
 * takes newline-separated JSON commands. Only the ADB shell (uid 2000) and
 * root may connect: adbd opens the socket for `localabstract:` as shell, so
 * no app on the TV can move the pointer.
 */
class PointerSocket(
    private val name: String,
    private val onCommand: (PointerCommand) -> Unit,
) : Thread("omniflow-pointer") {

    @Volatile
    private var running = true
    private var server: LocalServerSocket? = null
    private val clients = AtomicInteger()

    override fun run() {
        val listening = try {
            LocalServerSocket(name)
        } catch (e: IOException) {
            Log.e(TAG, "cannot listen on @$name", e)
            return
        }
        server = listening
        while (running) {
            val client = try {
                listening.accept()
            } catch (e: IOException) {
                if (running) Log.w(TAG, "accept failed", e)
                break
            }
            if (!running) {
                client.closeQuietly()
                break
            }
            val uid = try {
                client.peerCredentials.uid
            } catch (e: IOException) {
                -1
            }
            if (uid != SHELL_UID && uid != ROOT_UID) {
                Log.w(TAG, "refused a connection from uid $uid")
                client.closeQuietly()
                continue
            }
            if (clients.incrementAndGet() > MAX_CLIENTS) {
                clients.decrementAndGet()
                client.closeQuietly()
                continue
            }
            Thread({ serve(client) }, "omniflow-pointer-client").start()
        }
        listening.closeQuietly()
    }

    private fun serve(client: LocalSocket) {
        try {
            val input = client.inputStream
            val line = ByteArrayOutputStream()
            var tooLong = false
            val buffer = ByteArray(512)
            while (running) {
                val n = input.read(buffer)
                if (n < 0) break
                for (i in 0 until n) {
                    val b = buffer[i]
                    if (b == '\n'.code.toByte()) {
                        if (!tooLong) {
                            PointerCommand.parse(line.toString(Charsets.UTF_8.name()))
                                ?.let(onCommand)
                        }
                        line.reset()
                        tooLong = false
                    } else if (line.size() < MAX_LINE) {
                        line.write(b.toInt())
                    } else {
                        tooLong = true
                    }
                }
            }
        } catch (e: IOException) {
            // The phone went away; the next move opens a new connection.
        } finally {
            clients.decrementAndGet()
            client.closeQuietly()
        }
    }

    /** Stops listening. close() alone does not wake accept() on every
     * Android version, so a connection of our own does. */
    fun shutdown() {
        running = false
        try {
            LocalSocket().use { it.connect(LocalSocketAddress(name)) }
        } catch (e: IOException) {
            // Already gone.
        }
        server?.closeQuietly()
    }

    private fun LocalSocket.closeQuietly() {
        try {
            close()
        } catch (e: IOException) {
            // Nothing to do.
        }
    }

    private fun LocalServerSocket.closeQuietly() {
        try {
            close()
        } catch (e: IOException) {
            // Nothing to do.
        }
    }

    companion object {
        private const val TAG = "OmniFlowPointer"
        private const val SHELL_UID = 2000
        private const val ROOT_UID = 0
        private const val MAX_CLIENTS = 4
        private const val MAX_LINE = 256
    }
}
