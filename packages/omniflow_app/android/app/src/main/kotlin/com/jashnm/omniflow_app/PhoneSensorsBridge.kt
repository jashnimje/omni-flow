package com.jashnm.omniflow_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * The omniflow/phone_sensors event channel on the foreground service's
 * Flutter engine, so the phone's battery and Wi-Fi reach the engine with the
 * screen off. Both are pushed by Android (the sticky battery broadcast and a
 * Wi-Fi network callback), so nothing polls.
 *
 * Android only names the Wi-Fi network to an app with location access. Without
 * it a reading has no ssid, which the Dart side does not report as being off
 * Wi-Fi.
 */
class PhoneSensorsBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var channel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var battery: BroadcastReceiver? = null
    private var wifi: ConnectivityManager.NetworkCallback? = null

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        channel = EventChannel(messenger, CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    listen()
                }

                override fun onCancel(arguments: Any?) = stop()
            })
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() = stop()

    override fun onEngineWillDestroy() {
        stop()
        channel?.setStreamHandler(null)
        channel = null
    }

    private fun send(reading: Map<String, Any?>) {
        main.post { sink?.success(reading) }
    }

    private fun listen() {
        if (battery == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = sendBattery(intent)
            }
            battery = receiver
            app.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let(::sendBattery)
        }
        if (wifi == null) {
            val callback = wifiCallback()
            wifi = callback
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            connectivity.registerNetworkCallback(request, callback)
        }
    }

    private fun sendBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        send(
            mapOf(
                "kind" to "battery",
                "level" to if (level >= 0 && scale > 0) level * 100 / scale else null,
                "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL),
            ),
        )
    }

    /** Android 12 and later strip the SSID from the callback unless asked. */
    private fun wifiCallback(): ConnectivityManager.NetworkCallback {
        val onCapabilities = { capabilities: NetworkCapabilities ->
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                capabilities.transportInfo as? WifiInfo
            } else {
                @Suppress("DEPRECATION")
                (app.getSystemService(Context.WIFI_SERVICE) as WifiManager).connectionInfo
            }
            send(
                mapOf(
                    "kind" to "wifi",
                    "connected" to true,
                    "ssid" to ssidOf(info),
                    "bssid" to info?.bssid?.takeUnless { it == HIDDEN_BSSID },
                ),
            )
        }
        val onLost = { send(mapOf("kind" to "wifi", "connected" to false)) }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            object : ConnectivityManager.NetworkCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    onCapabilities(capabilities)

                override fun onLost(network: Network) = onLost()
            }
        } else {
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    onCapabilities(capabilities)

                override fun onLost(network: Network) = onLost()
            }
        }
    }

    private fun ssidOf(info: WifiInfo?): String? {
        @Suppress("DEPRECATION")
        val raw = info?.ssid ?: return null
        if (raw == WifiManager.UNKNOWN_SSID || raw.isBlank()) return null
        return raw.removeSurrounding("\"")
    }

    private fun stop() {
        battery?.let { runCatching { app.unregisterReceiver(it) } }
        battery = null
        wifi?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        wifi = null
        sink = null
    }

    companion object {
        private const val CHANNEL = "omniflow/phone_sensors"
        private const val HIDDEN_BSSID = "02:00:00:00:00:00"
    }
}
