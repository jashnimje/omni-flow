package com.jashnm.omniflow_app

import android.content.Context
import android.net.wifi.WifiManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The omniflow/multicast channel on the foreground service's Flutter engine.
 * Android drops multicast and broadcast packets for apps without a
 * WifiManager.MulticastLock, so the service holds one while it runs. The lock
 * is released when the service's engine goes away, even if Dart never asked.
 */
class MulticastLockBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var lock: WifiManager.MulticastLock? = null
    private var channel: MethodChannel? = null

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(acquire())
                    "release" -> {
                        release()
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() = release()

    override fun onEngineWillDestroy() {
        release()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun acquire(): Boolean {
        val held = lock ?: wifi.createMulticastLock(TAG).apply {
            setReferenceCounted(false)
        }.also { lock = it }
        if (!held.isHeld) held.acquire()
        return held.isHeld
    }

    private fun release() {
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    companion object {
        private const val CHANNEL = "omniflow/multicast"
        private const val TAG = "omniflow"
    }
}
