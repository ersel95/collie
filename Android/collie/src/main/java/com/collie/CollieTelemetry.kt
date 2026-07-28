package com.collie

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import java.util.TimeZone

/**
 * Point-in-time device state at the moment the report was taken. Device-state only,
 * no PII — no IP / SSID / location / personal data of any kind. Fields that could not
 * be collected are `null` and are omitted from the upload entirely.
 */
public data class CollieTelemetry(
    public val timezone: String?,          // "Europe/Istanbul"
    public val screenScale: Double?,       // 3.0
    public val screenPoints: String?,      // "390x844" (density-independent pixels)
    public val networkType: String?,       // wifi/cellular/wired/none/unknown
    public val batteryLevel: Int?,         // 0–100, null = unknown
    public val batteryState: String?,      // charging/full/unplugged/unknown
    public val lowPowerMode: Boolean?,
    public val thermalState: String?,      // nominal/fair/serious/critical
    public val orientation: String?,       // portrait/landscape
    public val freeDiskBytes: Long?,
    public val totalDiskBytes: Long?,
    public val totalMemoryBytes: Long?,
    public val appMemoryBytes: Long?,
)

/** Collects the point-in-time device telemetry. */
public object CollieTelemetryCollector {

    /**
     * Captures the current telemetry.
     *
     * Everything here is a cheap synchronous read, so unlike iOS — which has to enable
     * battery monitoring and run an `NWPathMonitor` ahead of time — there is nothing to
     * prepare: the first report is as complete as the hundredth.
     */
    public fun capture(context: Context): CollieTelemetry {
        val app = context.applicationContext
        val battery = batteryStatus(app)
        return CollieTelemetry(
            timezone = TimeZone.getDefault().id,
            screenScale = app.resources.displayMetrics.density.toDouble(),
            screenPoints = screenPoints(app),
            networkType = networkType(app),
            batteryLevel = battery?.first,
            batteryState = battery?.second,
            lowPowerMode = powerSaveMode(app),
            thermalState = thermalState(app),
            orientation = orientation(app),
            freeDiskBytes = diskBytes(app)?.first,
            totalDiskBytes = diskBytes(app)?.second,
            totalMemoryBytes = totalMemoryBytes(),
            appMemoryBytes = appMemoryBytes(),
        )
    }

    // MARK: - Screen

    /** Density-independent pixels, the closest equivalent of iOS's points. */
    private fun screenPoints(context: Context): String {
        val metrics = context.resources.displayMetrics
        val density = if (metrics.density > 0f) metrics.density else 1f
        return "${(metrics.widthPixels / density).toInt()}x${(metrics.heightPixels / density).toInt()}"
    }

    private fun orientation(context: Context): String =
        when (context.resources.configuration.orientation) {
            Configuration.ORIENTATION_PORTRAIT -> "portrait"
            Configuration.ORIENTATION_LANDSCAPE -> "landscape"
            else -> "unknown"
        }

    // MARK: - Battery

    /** Level (0–100) and charge state, read from the sticky battery broadcast. */
    private fun batteryStatus(context: Context): Pair<Int?, String?>? {
        val intent: Intent = runCatching {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull() ?: return null

        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val percent = if (level >= 0 && scale > 0) (level * 100f / scale).toInt() else null

        val state = when (intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING,
            -> "unplugged"

            else -> "unknown"
        }
        return percent to state
    }

    private fun powerSaveMode(context: Context): Boolean? =
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isPowerSaveMode

    // MARK: - Thermal

    /**
     * Mapped onto the iOS vocabulary (nominal/fair/serious/critical) so one panel column
     * reads both platforms. Android's throttling ladder is finer-grained; the top three
     * statuses all mean the same thing to someone triaging a report.
     */
    private fun thermalState(context: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val manager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        return when (manager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN,
            -> "critical"

            else -> "unknown"
        }
    }

    // MARK: - Network

    /** Interface type only — no IP, no SSID, nothing that identifies the network. */
    private fun networkType(context: Context): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "unknown"
        val capabilities = runCatching {
            manager.getNetworkCapabilities(manager.activeNetwork)
        }.getOrNull() ?: return "none"

        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wired"
            else -> "other"
        }
    }

    // MARK: - Disk

    private fun diskBytes(context: Context): Pair<Long, Long>? = runCatching {
        val stat = StatFs(context.filesDir.absolutePath)
        stat.availableBytes to stat.totalBytes
    }.getOrNull()

    // MARK: - Memory

    private fun totalMemoryBytes(): Long? = runCatching { Runtime.getRuntime().maxMemory() }.getOrNull()

    private fun appMemoryBytes(): Long? = runCatching {
        val runtime = Runtime.getRuntime()
        runtime.totalMemory() - runtime.freeMemory()
    }.getOrNull()
}
