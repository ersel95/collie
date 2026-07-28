package com.collie.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

/**
 * Shake detection over the accelerometer — the Android counterpart of the iOS SDK's
 * `UIWindow.motionEnded` swizzle.
 *
 * A shake is reported when the total acceleration exceeds [SHAKE_THRESHOLD_G] gravities a
 * few times in quick succession, which keeps ordinary handling and walking from opening a
 * bug report. The thresholds match Olaf's detector deliberately: the two tools ship in the
 * same builds, and a gesture that opens one but not the other reads as a bug.
 */
internal class ShakeDetector(private val onShake: () -> Unit) : SensorEventListener {

    private var sensorManager: SensorManager? = null
    private var lastShakeAtMillis = 0L
    private var shakeCount = 0

    fun start(context: Context) {
        if (sensorManager != null) return
        val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        val accelerometer = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        manager.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_UI)
        sensorManager = manager
    }

    fun stop() {
        sensorManager?.unregisterListener(this)
        sensorManager = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return

        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val gForce = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
        if (gForce < SHAKE_THRESHOLD_G) return

        val now = System.currentTimeMillis()
        if (now - lastShakeAtMillis < MIN_INTERVAL_MS) return
        // A pause long enough means the previous burst is over — start counting again.
        if (now - lastShakeAtMillis > RESET_INTERVAL_MS) shakeCount = 0

        lastShakeAtMillis = now
        shakeCount++
        if (shakeCount >= REQUIRED_SHAKES) {
            shakeCount = 0
            onShake()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int): Unit = Unit

    private companion object {
        const val SHAKE_THRESHOLD_G = 2.3f
        const val MIN_INTERVAL_MS = 200L
        const val RESET_INTERVAL_MS = 1_500L
        const val REQUIRED_SHAKES = 2
    }
}
