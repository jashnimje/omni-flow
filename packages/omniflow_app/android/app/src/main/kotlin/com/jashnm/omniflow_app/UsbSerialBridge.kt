package com.jashnm.omniflow_app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * USB serial boards plugged into the phone (CDC-ACM, CP210x, CH34x, FTDI,
 * Prolific), on the foreground service's engine, so the engine sets boards
 * up and flashes them with no computer. The omniflow/usb method channel
 * lists ports as `usb:<vendor>:<product>`, asks Android for permission, opens,
 * writes, sets DTR, RTS and speed, and closes. omniflow/usb_data carries
 * each port's bytes and plug and unplug events.
 */
class UsbSerialBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val usb = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    // One thread: writes, line changes, opens and closes happen in order,
    // and the ports map is only touched here.
    private val io = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    private val ports = mutableMapOf<String, Open>()
    private var plugReceiver: BroadcastReceiver? = null
    private val waitingPermission = mutableMapOf<String, MutableList<MethodChannel.Result>>()
    private var permissionReceiver: BroadcastReceiver? = null

    private class Open(val port: UsbSerialPort, val reader: SerialInputOutputManager)

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, METHODS).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            when (call.method) {
                "ports" -> result.success(listPorts())
                "permission" -> permission(path!!, result)
                "open" -> io.execute { reply(result) { open(path!!, call.argument<Int>("baud")!!) } }
                "write" -> io.execute {
                    reply(result) { portOf(path!!).write(call.argument<ByteArray>("bytes")!!, WRITE_TIMEOUT_MS) }
                }
                "lines" -> io.execute {
                    reply(result) {
                        val port = portOf(path!!)
                        call.argument<Boolean>("dtr")?.let { port.setDTR(it) }
                        call.argument<Boolean>("rts")?.let { port.setRTS(it) }
                    }
                }
                "baud" -> io.execute {
                    reply(result) {
                        portOf(path!!).setParameters(
                            call.argument<Int>("baud")!!, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE,
                        )
                    }
                }
                "close" -> io.execute { reply(result) { close(path!!) } }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                listenForPlugs()
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private fun listPorts(): List<Map<String, Any?>> {
        val names = stableNames()
        return UsbSerialProber.getDefaultProber().findAllDrivers(usb).map { driver ->
            val d = driver.device
            mapOf(
                "path" to (names[d.deviceName] ?: "usb:${d.deviceName}"),
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "name" to (d.productName ?: driver.javaClass.simpleName.removeSuffix("SerialDriver")),
                "maker" to d.manufacturerName,
                "allowed" to usb.hasPermission(d),
            )
        }
    }

    /**
     * A port's name by its vendor and product id (`usb:1a86:7523`), with
     * `-2`, `-3` for a second and third board of the same kind. Android
     * numbers the device again on every attach (`/dev/bus/usb/001/007`),
     * so a name from that would lose the board after a replug or a reboot.
     */
    private fun stableNames(): Map<String, String> {
        val names = mutableMapOf<String, String>()
        usb.deviceList.values.sortedBy { it.deviceName }
            .groupBy { String.format(java.util.Locale.ROOT, "usb:%04x:%04x", it.vendorId, it.productId) }
            .forEach { (base, devices) ->
                devices.forEachIndexed { i, d -> names[d.deviceName] = if (i == 0) base else "$base-${i + 1}" }
            }
        known.putAll(names)
        return names
    }

    /** Kept after a detach, when Android no longer lists the device. */
    private val known = java.util.concurrent.ConcurrentHashMap<String, String>()

    private fun pathOf(device: UsbDevice): String =
        stableNames()[device.deviceName] ?: known[device.deviceName] ?: "usb:${device.deviceName}"

    /** By its stable name, or the kernel path that names saved before had. */
    private fun deviceOf(path: String): UsbDevice {
        val names = stableNames()
        return usb.deviceList.values.firstOrNull { names[it.deviceName] == path || "usb:${it.deviceName}" == path }
            ?: throw IllegalStateException("$path is not plugged in")
    }

    private fun permission(path: String, result: MethodChannel.Result) {
        val device = try {
            deviceOf(path)
        } catch (e: Exception) {
            return result.error("unreachable", e.message, null)
        }
        if (usb.hasPermission(device)) return result.success(true)
        // Keyed by Android's device name, which the answer carries.
        val key = device.deviceName
        waitingPermission.getOrPut(key) { mutableListOf() }.add(result)
        if (waitingPermission[key]!!.size > 1) return
        listenForPermissions()
        val intent = Intent(ACTION_PERMISSION).setPackage(app.packageName)
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(app, 0, intent, flags))
        // Nobody may be at the phone (a start after a reboot): stop waiting
        // after a while, as a refusal, rather than hold the engine's call.
        main.postDelayed({ waitingPermission.remove(key)?.forEach { it.success(false) } }, PERMISSION_WAIT_MS)
    }

    /** One receiver for every answer, settled by the device it names. */
    private fun listenForPermissions() {
        if (permissionReceiver != null) return
        permissionReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val device = deviceIn(intent) ?: return
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                waitingPermission.remove(device.deviceName)?.forEach { it.success(granted) }
            }
        }
        register(permissionReceiver!!, IntentFilter(ACTION_PERMISSION))
    }

    private fun deviceIn(intent: Intent): UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
    } else {
        @Suppress("DEPRECATION")
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
    }

    /** Not exported: Android still delivers its own USB broadcasts, and no
     * other app can send a fake unplug. */
    private fun register(receiver: BroadcastReceiver, filter: IntentFilter) {
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(receiver, filter)
        }
    }

    private fun open(path: String, baud: Int) {
        close(path)
        val device = deviceOf(path)
        if (!usb.hasPermission(device)) throw SecurityException("OmniFlow may not use $path yet: allow it first")
        val driver = UsbSerialProber.getDefaultProber().probeDevice(device)
            ?: throw IllegalStateException("$path is not a serial adapter OmniFlow knows")
        val connection = usb.openDevice(device) ?: throw IllegalStateException("$path did not open")
        val port = driver.ports.first()
        port.open(connection)
        try {
            port.setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
        } catch (e: Exception) {
            try {
                port.close()
            } catch (_: Exception) {
            }
            throw e
        }
        lateinit var open: Open
        val reader = SerialInputOutputManager(port, object : SerialInputOutputManager.Listener {
            override fun onNewData(data: ByteArray) {
                emit(mapOf("event" to "data", "path" to path, "bytes" to data))
            }

            // A reader stopped by close() also ends in an error: only the
            // port still open on this path is closed and reported.
            override fun onRunError(e: Exception) {
                io.execute {
                    if (ports[path] !== open) return@execute
                    close(path)
                    emit(mapOf("event" to "closed", "path" to path, "error" to e.message))
                }
            }
        })
        open = Open(port, reader)
        ports[path] = open
        reader.start()
    }

    private fun portOf(path: String): UsbSerialPort =
        ports[path]?.port ?: throw IllegalStateException("$path is not open")

    private fun close(path: String) {
        val open = ports.remove(path) ?: return
        open.reader.listener = null
        open.reader.stop()
        try {
            open.port.close()
        } catch (_: Exception) {
        }
    }

    private fun listenForPlugs() {
        if (plugReceiver != null) return
        plugReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val device = deviceIn(intent) ?: return
                val path = pathOf(device)
                val kernel = "usb:${device.deviceName}"
                val plugged = intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED
                if (!plugged) {
                    known.remove(device.deviceName)
                    io.execute {
                        close(path)
                        close(kernel)
                    }
                }
                // By the stable name, so the Dart side reopens a board that
                // comes back on the same name.
                emit(mapOf("event" to if (plugged) "attached" else "detached", "path" to path))
            }
        }
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        register(plugReceiver!!, filter)
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    private fun reply(result: MethodChannel.Result, work: () -> Unit) {
        try {
            work()
            main.post { result.success(null) }
        } catch (e: Exception) {
            main.post { result.error("device_error", e.message ?: e.javaClass.simpleName, null) }
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() {
        io.execute { for (path in ports.keys.toList()) close(path) }
        for (receiver in listOfNotNull(plugReceiver, permissionReceiver)) {
            try {
                app.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
        }
        plugReceiver = null
        permissionReceiver = null
        // The engine asking is going away: answer it rather than leave its
        // call waiting forever.
        val waiting = waitingPermission.values.flatten()
        waitingPermission.clear()
        waiting.forEach { it.success(false) }
    }

    override fun onEngineWillDestroy() {}

    private companion object {
        const val METHODS = "omniflow/usb"
        const val EVENTS = "omniflow/usb_data"
        const val ACTION_PERMISSION = "com.jashnm.omniflow_app.USB_PERMISSION"
        const val WRITE_TIMEOUT_MS = 2000
        const val PERMISSION_WAIT_MS = 60_000L
    }
}
