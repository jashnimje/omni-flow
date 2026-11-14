package com.jashnm.omniflow_app

import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.pm.PackageManager
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
import android.os.PowerManager
import android.os.Process
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * The omniflow/phone_sensors event channel on the foreground service's
 * Flutter engine, so the phone's readings reach the engine with the screen
 * off: the battery and Wi-Fi, the screen turning on and off, Do Not Disturb,
 * Bluetooth devices connecting, the app on screen, and notifications from
 * [NotificationTriggers]. Android pushes all but the app on screen. That one
 * is read every few seconds, only while the screen is on and only once the
 * person allowed usage access for an "An app opens" trigger.
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
    private var system: BroadcastReceiver? = null
    private var foreground: String? = null
    private var lastUsageRead = 0L
    private val home by lazy { homePackages() }
    private val readApps = object : Runnable {
        override fun run() {
            main.removeCallbacks(this)
            if (sink == null) return
            val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!power.isInteractive) return
            if (usageAllowed(app)) readForegroundApp()
            main.postDelayed(this, if (usageAllowed(app)) APP_POLL_MS else APP_CHECK_MS)
        }
    }

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

    /** The screen, Do Not Disturb and Bluetooth: protected system
     * broadcasts, so no other app can send them. */
    private fun listenToSystem() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> {
                        send(mapOf("kind" to "screen", "on" to true))
                        main.post(readApps)
                    }
                    Intent.ACTION_SCREEN_OFF -> send(mapOf("kind" to "screen", "on" to false))
                    NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED -> sendDnd()
                    BluetoothDevice.ACTION_ACL_CONNECTED -> sendBluetooth(intent, true)
                    BluetoothDevice.ACTION_ACL_DISCONNECTED -> sendBluetooth(intent, false)
                }
            }
        }
        system = receiver
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        send(mapOf("kind" to "screen", "on" to power.isInteractive))
        sendDnd()
        sendConnectedBluetooth()
        main.post(readApps)
    }

    /**
     * The headsets and speakers already connected when the service starts,
     * once, so a rule waiting on "connected" knows the current state. Android
     * sends the connect broadcast only at the moment a device connects.
     * Nothing is read without the Bluetooth connect permission.
     */
    private fun sendConnectedBluetooth() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            app.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val adapter = (app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter ?: return
        val sent = mutableSetOf<String>()
        val listener = object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                try {
                    for (device in proxy.connectedDevices) {
                        val address = device.address
                        val first = synchronized(sent) { sent.add(address) }
                        if (first) send(bluetoothReading(device, true))
                    }
                } catch (_: SecurityException) {
                } finally {
                    runCatching { adapter.closeProfileProxy(profile, proxy) }
                }
            }

            override fun onServiceDisconnected(profile: Int) {}
        }
        for (profile in intArrayOf(BluetoothProfile.HEADSET, BluetoothProfile.A2DP)) {
            try {
                adapter.getProfileProxy(app, listener, profile)
            } catch (_: SecurityException) {
            }
        }
    }

    private fun bluetoothReading(device: BluetoothDevice, connected: Boolean): Map<String, Any?> {
        val name = try {
            device.name
        } catch (_: SecurityException) {
            null
        }
        return mapOf(
            "kind" to "bluetooth",
            "name" to (name ?: device.address),
            "address" to device.address,
            "connected" to connected,
        )
    }

    /** Reading Do Not Disturb needs no permission; only changing it would. */
    private fun sendDnd() {
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val filter = manager.currentInterruptionFilter
        if (filter == NotificationManager.INTERRUPTION_FILTER_UNKNOWN) return
        send(mapOf("kind" to "dnd", "on" to (filter != NotificationManager.INTERRUPTION_FILTER_ALL)))
    }

    /** Android 12 and later send these only with the Bluetooth connect
     * permission, which the app asks for when a trigger needs it. */
    private fun sendBluetooth(intent: Intent, connected: Boolean) {
        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        } ?: return
        send(bluetoothReading(device, connected))
    }

    /** The app the person last brought to the screen, from the usage
     * events since the last read. The home screen counts as no app. */
    private fun readForegroundApp() {
        val usage = app.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val since = if (lastUsageRead == 0L) now - FIRST_READ_MS else lastUsageRead
        lastUsageRead = now
        val events = try {
            usage.queryEvents(since, now)
        } catch (_: SecurityException) {
            return
        }
        var latest: String? = null
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            @Suppress("DEPRECATION")
            if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) latest = event.packageName
        }
        val next = (latest ?: return).takeUnless { it in home }
        if (next == foreground) return
        foreground?.let { send(mapOf("kind" to "app", "package" to it, "label" to labelOf(app, it), "event" to "closed")) }
        next?.let { send(mapOf("kind" to "app", "package" to it, "label" to labelOf(app, it), "event" to "opened")) }
        foreground = next
    }

    private fun homePackages(): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        @Suppress("DEPRECATION")
        return app.packageManager.queryIntentActivities(intent, 0).map { it.activityInfo.packageName }.toSet()
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
        if (system == null) listenToSystem()
        active = this
    }

    private fun sendBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        // Plugged in counts as charging, even when Android holds the charge
        // at a limit (80%) and reports "not charging".
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        send(
            mapOf(
                "kind" to "battery",
                "level" to if (level >= 0 && scale > 0) level * 100 / scale else null,
                "charging" to (plugged != 0),
            ),
        )
    }

    /** The Wi-Fi network last reported, so losing another one (roaming, a
     * second local-only network) does not read as leaving Wi-Fi. */
    @Volatile private var current: Network? = null

    /** Android 12 and later strip the SSID from the callback unless asked. */
    private fun wifiCallback(): ConnectivityManager.NetworkCallback {
        val onCapabilities = { network: Network, capabilities: NetworkCapabilities ->
            current = network
            // WifiInfo is a TransportInfo only from Android 12: before that
            // the name comes from the Wi-Fi service.
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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
        val onLost = { network: Network ->
            if (current == null || current == network) {
                current = null
                send(mapOf("kind" to "wifi", "connected" to false))
            }
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            object : ConnectivityManager.NetworkCallback(ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    onCapabilities(network, capabilities)

                override fun onLost(network: Network) = onLost(network)
            }
        } else {
            object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                    onCapabilities(network, capabilities)

                override fun onLost(network: Network) = onLost(network)
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
        system?.let { runCatching { app.unregisterReceiver(it) } }
        system = null
        main.removeCallbacks(readApps)
        foreground = null
        lastUsageRead = 0L
        if (active === this) active = null
        sink = null
    }

    companion object {
        private const val CHANNEL = "omniflow/phone_sensors"
        private const val HIDDEN_BSSID = "02:00:00:00:00:00"
        private const val APP_POLL_MS = 4_000L
        private const val APP_CHECK_MS = 30_000L
        private const val FIRST_READ_MS = 60_000L

        /** The bridge feeding the running engine, for [NotificationTriggers]. */
        @Volatile private var active: PhoneSensorsBridge? = null

        /** Hands a reading to the running engine. Nothing is kept or logged
         * here: with no engine listening the reading is dropped. */
        fun emit(reading: Map<String, Any?>) {
            active?.send(reading)
        }

        /** Whether the person allowed usage access, which the app on screen
         * needs. */
        fun usageAllowed(context: Context): Boolean {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            }
            return mode == AppOpsManager.MODE_ALLOWED
        }

        /** The app's name as the launcher shows it, or null when Android
         * does not show this app the package. */
        fun labelOf(context: Context, packageName: String): String? = try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        } catch (_: Exception) {
            null
        }
    }
}
