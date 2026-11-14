package com.jashnm.omniflow.tvhelper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.graphics.Point
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import kotlin.math.floor
import kotlin.math.min

/**
 * Keeps a pointer window over the screen and moves it as [PointerSocket]
 * says. The pointer shows on the first move and hides after [IDLE_MS] with
 * none.
 */
class PointerService : Service() {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var windows: WindowManager
    private lateinit var view: PointerView
    private lateinit var params: WindowManager.LayoutParams
    private var shown = false
    private var fx = 0.5
    private var fy = 0.5
    private var socket: PointerSocket? = null

    private val hideWhenIdle = Runnable { hide() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windows = getSystemService(WINDOW_SERVICE) as WindowManager
        view = PointerView(this)
        params = WindowManager.LayoutParams(
            view.widthPx,
            view.heightPx,
            if (Build.VERSION.SDK_INT >= 26) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = "OmniFlow pointer"
        }
        goForeground()
        socket = PointerSocket(SOCKET_NAME, ::enqueue).also { it.start() }
    }

    private val queue = ArrayList<PointerCommand>()
    private var drainPosted = false

    /**
     * Moves that arrive faster than the window can follow are merged, so a
     * quick drag shows where the finger is now, not where it was.
     */
    private fun enqueue(command: PointerCommand) {
        synchronized(queue) {
            val last = queue.lastOrNull()
            when {
                command is PointerCommand.To && last is PointerCommand.To ->
                    queue[queue.size - 1] = command
                command is PointerCommand.By && last is PointerCommand.By ->
                    queue[queue.size - 1] = PointerCommand.By(last.dx + command.dx, last.dy + command.dy)
                else -> queue.add(command)
            }
            if (!drainPosted) {
                drainPosted = true
                main.post(::drain)
            }
        }
    }

    private fun drain() {
        val commands = synchronized(queue) {
            drainPosted = false
            queue.toList().also { queue.clear() }
        }
        commands.forEach(::apply)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        socket?.shutdown()
        socket = null
        main.removeCallbacks(hideWhenIdle)
        hide()
        super.onDestroy()
    }

    private fun goForeground() {
        val notification = if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Pointer",
                    NotificationManager.IMPORTANCE_MIN,
                ),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("OmniFlow pointer")
            .setContentText("Shows a pointer moved from the OmniFlow app")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun apply(command: PointerCommand) {
        when (command) {
            is PointerCommand.Show -> place()
            is PointerCommand.Hide -> {
                main.removeCallbacks(hideWhenIdle)
                hide()
                return
            }
            is PointerCommand.To -> {
                fx = command.x
                fy = command.y
                place()
            }
            is PointerCommand.By -> {
                fx = (fx + command.dx).coerceIn(0.0, 1.0)
                fy = (fy + command.dy).coerceIn(0.0, 1.0)
                place()
            }
        }
        main.removeCallbacks(hideWhenIdle)
        main.postDelayed(hideWhenIdle, IDLE_MS)
    }

    /**
     * Puts the arrow's tip one pixel above and left of its window, so a tap
     * sent at the pointer lands on the app underneath, not on this window.
     */
    private fun place() {
        val (width, height) = screenSize()
        params.x = min(floor(fx * width).toInt(), width - 1) + 1
        params.y = min(floor(fy * height).toInt(), height - 1) + 1
        try {
            if (shown) {
                windows.updateViewLayout(view, params)
            } else {
                if (Build.VERSION.SDK_INT >= 23 && !Settings.canDrawOverlays(this)) {
                    Log.w(TAG, "not allowed to draw over other apps")
                    return
                }
                windows.addView(view, params)
                shown = true
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "cannot show the pointer", e)
            shown = false
        }
    }

    private fun hide() {
        if (!shown) return
        shown = false
        try {
            windows.removeView(view)
        } catch (e: RuntimeException) {
            Log.w(TAG, "cannot hide the pointer", e)
        }
    }

    private fun screenSize(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val bounds = windows.maximumWindowMetrics.bounds
            return bounds.width() to bounds.height()
        }
        val point = Point()
        @Suppress("DEPRECATION")
        windows.defaultDisplay.getRealSize(point)
        return point.x to point.y
    }

    companion object {
        const val SOCKET_NAME = "omniflow_pointer"
        private const val TAG = "OmniFlowPointer"
        private const val CHANNEL = "pointer"
        private const val NOTIFICATION_ID = 1
        private const val IDLE_MS = 5_000L
    }
}
