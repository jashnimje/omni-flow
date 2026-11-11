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
 * lists ports as `usb:<device name>`, asks Android for permission, opens,
 * writes, sets DTR, RTS and speed, and closes. omniflow/usb_data carries
 * each port's bytes and plug and unplug events.
 */
class UsbSerialBridge(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val app = context.applicationContext
    private val usb = app.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private var sink: EventChannel.EventSink? = null
    private val ports = mutableMapOf<String, Open>()
    private var plugReceiver: BroadcastReceiver? = null
    private val waitingPermission = mutableMapOf<String, MutableList<MethodChannel.Result>>()

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

    private fun listPorts(): List<Map<String, Any?>> =
        UsbSerialProber.getDefaultProber().findAllDrivers(usb).map { driver ->
            val d = driver.device
            mapOf(
                "path" to "usb:${d.deviceName}",
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "name" to (d.productName ?: driver.javaClass.simpleName.removeSuffix("SerialDriver")),
                "maker" to d.manufacturerName,
                "allowed" to usb.hasPermission(d),
            )
        }

    private fun deviceOf(path: String): UsbDevice =
        usb.deviceList.values.firstOrNull { "usb:${it.deviceName}" == path }
            ?: throw IllegalStateException("$path is not plugged in")

    private fun permission(path: String, result: MethodChannel.Result) {
        val device = try {
            deviceOf(path)
        } catch (e: Exception) {
            return result.error("unreachable", e.message, null)
        }
        if (usb.hasPermission(device)) return result.success(true)
        waitingPermission.getOrPut(path) { mutableListOf() }.add(result)
        if (waitingPermission[path]!!.size > 1) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                app.unregisterReceiver(this)
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                waitingPermission.remove(path)?.forEach { it.success(granted) }
            }
        }
        val filter = IntentFilter(ACTION_PERMISSION)
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(receiver, filter)
        }
        val intent = Intent(ACTION_PERMISSION).setPackage(app.packageName)
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(app, 0, intent, flags))
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
        port.setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
        val reader = SerialInputOutputManager(port, object : SerialInputOutputManager.Listener {
            override fun onNewData(data: ByteArray) {
                emit(mapOf("event" to "data", "path" to path, "bytes" to data))
            }

            override fun onRunError(e: Exception) {
                emit(mapOf("event" to "closed", "path" to path, "error" to e.message))
                io.execute { close(path) }
            }
        })
        ports[path] = Open(port, reader)
        reader.start()
    }

    private fun portOf(path: String): UsbSerialPort =
        ports[path]?.port ?: throw IllegalStateException("$path is not open")

    private fun close(path: String) {
        val open = ports.remove(path) ?: return
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
                val device: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                val path = "usb:${device?.deviceName ?: return}"
                val plugged = intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED
                if (!plugged) io.execute { close(path) }
                emit(mapOf("event" to if (plugged) "attached" else "detached", "path" to path))
            }
        }
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(plugReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(plugReceiver, filter)
        }
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
        for (path in ports.keys.toList()) close(path)
        plugReceiver?.let {
            try {
                app.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        plugReceiver = null
    }

    override fun onEngineWillDestroy() {}

    private companion object {
        const val METHODS = "omniflow/usb"
        const val EVENTS = "omniflow/usb_data"
        const val ACTION_PERMISSION = "com.jashnm.omniflow_app.USB_PERMISSION"
        const val WRITE_TIMEOUT_MS = 2000
    }
}
