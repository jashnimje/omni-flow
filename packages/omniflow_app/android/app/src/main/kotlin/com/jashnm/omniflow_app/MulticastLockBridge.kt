package com.jashnm.omniflow_app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The omniflow/multicast channel on the foreground service's Flutter engine.
 * Android drops multicast and broadcast packets for apps without a
 * WifiManager.MulticastLock, and the lock wakes the CPU for every such packet
 * on the LAN, so it is held only while it is needed: when the Dart side asks
 * (a run, a board that reports by broadcast, a short window after joining
 * Wi-Fi), and while one of OmniFlow's screens shows, which is when scans and
 * setup happen. It is released when the service's engine goes away, even if
 * Dart never asked.
 */
class MulticastLockBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.MulticastLock? = null
    private var channel: MethodChannel? = null
    private var wanted = false
    private var running = false

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        wanted = true
                        result.success(apply())
                    }
                    "release" -> {
                        wanted = false
                        result.success(apply())
                    }
                    else -> result.notImplemented()
                }
            }
        }
        running = true
        active = this
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() = stop()

    override fun onEngineWillDestroy() {
        stop()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun stop() {
        running = false
        wanted = false
        release()
        if (active === this) active = null
    }

    /** Holds the lock when Dart wants it or a screen of the app shows, and
     * is whether it is held. */
    private fun apply(): Boolean {
        if (running && (wanted || OmniFlowApplication.onScreen)) acquire() else release()
        return lock?.isHeld == true
    }

    private fun acquire() {
        val held = lock ?: wifi.createMulticastLock(TAG).apply {
            setReferenceCounted(false)
        }.also { lock = it }
        if (!held.isHeld) held.acquire()
    }

    private fun release() {
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    companion object {
        private const val CHANNEL = "omniflow/multicast"
        private const val TAG = "omniflow"
        private val main = Handler(Looper.getMainLooper())

        @Volatile private var active: MulticastLockBridge? = null

        /** One of OmniFlow's screens came up or went away. */
        fun screenChanged() {
            main.post { active?.apply() }
        }
    }
}
