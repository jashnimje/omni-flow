package com.jashnm.omniflow_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlin.math.sqrt

/**
 * Shake and face down from the accelerometer. It listens only while an
 * automation uses one of them, at the UI rate, so the sensor costs little
 * battery: [PhoneActionsBridge] stops it when no rule needs it.
 *
 * A shake is two strong jolts within [SHAKE_GAP_MS], then a pause before
 * the next one counts. Face down is the screen pointing at the floor for
 * [FACE_DOWN_MS], and it ends when the phone is turned over again.
 */
class MotionSensor(context: Context, private val emit: (Map<String, Any?>) -> Unit) : SensorEventListener {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private var shake = false
    private var faceDown = false
    private var listening = false

    private var lastJolt = 0L
    private var lastShake = 0L
    private var downSince = 0L
    private var isDown: Boolean? = null

    fun watch(shake: Boolean, faceDown: Boolean) {
        this.shake = shake
        this.faceDown = faceDown
        if (!listening && accelerometer != null) {
            listening = sensors.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_UI)
        }
    }

    fun stop() {
        if (listening) sensors.unregisterListener(this)
        listening = false
        isDown = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        val (x, y, z) = Triple(event.values[0], event.values[1], event.values[2])
        val now = SystemClock.elapsedRealtime()
        if (shake) {
            val g = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
            if (g > SHAKE_G && now - lastShake > SHAKE_PAUSE_MS) {
                if (now - lastJolt in 1..SHAKE_GAP_MS) {
                    lastShake = now
                    lastJolt = 0L
                    emit(mapOf("kind" to "shake"))
                } else {
                    lastJolt = now
                }
            }
        }
        if (faceDown) {
            val down = z < -FACE_DOWN_Z
            val up = z > -FACE_UP_Z
            if (down) {
                if (downSince == 0L) downSince = now
                if (now - downSince >= FACE_DOWN_MS && isDown != true) {
                    isDown = true
                    emit(mapOf("kind" to "face_down", "on" to true))
                }
            } else {
                downSince = 0L
                if (up && isDown != false) {
                    isDown = false
                    emit(mapOf("kind" to "face_down", "on" to false))
                }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private companion object {
        const val SHAKE_G = 2.5f
        const val SHAKE_GAP_MS = 700L
        const val SHAKE_PAUSE_MS = 1_500L
        const val FACE_DOWN_Z = 8.5f
        const val FACE_UP_Z = 4f
        const val FACE_DOWN_MS = 800L
    }
}
