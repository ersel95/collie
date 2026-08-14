package com.collie

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.CaptioningManager
import java.util.TimeZone
import kotlin.math.roundToInt

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
    /**
     * Display and accessibility settings the device is running with. Nested rather than
     * flattened so the panel can render it as its own block, and so a report filed by an
     * SDK that predates it simply has no `accessibility` key.
     */
    public val accessibility: CollieAccessibilityState? = null,
    /**
     * What the tester answered to the system's permission prompts. Nested and optional for
     * the same reasons as [accessibility].
     */
    public val permissions: ColliePermissionState? = null,
)

/**
 * How the device is configured to *present* the app: dark mode, text size, and which
 * accessibility features are switched on.
 *
 * A tester rarely mentions any of this — "the button is cut off" and "I can't read the
 * price" are the same sentence whether the device runs at the default text size or at 2×
 * with bold text — so the report has to carry it. Reading a screenshot back against these
 * values is what turns an unreproducible layout complaint into a known one.
 *
 * Still device state, not PII: every field is a system setting, and nothing here names the
 * person, the network or the place. Nothing is read that would require a permission.
 *
 * The vocabulary is shared with the iOS SDK so one panel column reads both platforms. A
 * field the platform has no equivalent for stays `null` and is omitted from the upload —
 * `null` means "not knowable here", never "off".
 */
public data class CollieAccessibilityState(
    /** `dark` / `light` / `unspecified`. */
    public val interfaceStyle: String? = null,
    /** The text-size multiplier the app actually renders at (1.0 = default). */
    public val fontScale: Double? = null,
    /**
     * Dynamic Type category — iOS only (`L`, `XXL`, `AX3`…). Android has no categories,
     * so [fontScale] is the cross-platform field.
     */
    public val contentSize: String? = null,
    public val boldText: Boolean? = null,
    /** TalkBack on Android, VoiceOver on iOS. */
    public val screenReader: Boolean? = null,
    public val switchControl: Boolean? = null,
    public val assistiveTouch: Boolean? = null,
    public val speakScreen: Boolean? = null,
    public val reduceMotion: Boolean? = null,
    public val reduceTransparency: Boolean? = null,
    /** "High contrast text" on Android, "Increase Contrast" on iOS. */
    public val increaseContrast: Boolean? = null,
    public val invertColors: Boolean? = null,
    public val grayscale: Boolean? = null,
    public val differentiateWithoutColor: Boolean? = null,
    public val onOffLabels: Boolean? = null,
    public val closedCaptions: Boolean? = null,
    public val monoAudio: Boolean? = null,
)

/**
 * What the tester answered to the system's permission prompts, at the moment the report was
 * taken.
 *
 * Half the reports that read like a broken feature are a declined prompt: the camera screen
 * that "opens black", the upload that "does nothing", the push that "never arrives". The
 * tester does not connect the two, and nobody triaging the report can see it — so the
 * answers travel with the report.
 *
 * **Nothing here ever asks for anything.** Every value is a status read; Collie requests no
 * permission and declares none in its manifest, so the tester sees no prompt because Collie
 * looked. A permission the host app does not declare stays `null` — an app with no camera
 * feature must not be reported as "camera denied".
 *
 * No PII: a grant is not the data behind it. Collie reads whether location is allowed, never
 * a coordinate; whether the gallery is allowed, never a photo.
 *
 * The vocabulary is shared with the iOS SDK: `granted` / `denied` / `notDetermined` /
 * `restricted` / `limited`, plus `always` and `whenInUse` for location and `provisional` /
 * `ephemeral` for notifications (the last three iOS-only).
 */
public data class ColliePermissionState(
    public val camera: String? = null,
    public val microphone: String? = null,
    /** The gallery: `READ_MEDIA_IMAGES`, or the storage permission below Android 13. */
    public val photoLibrary: String? = null,
    /** `always` (background) / `whenInUse` / `denied`. */
    public val location: String? = null,
    /** `full` (fine) / `reduced` (coarse only). Meaningful only while location is granted. */
    public val locationAccuracy: String? = null,
    public val notifications: String? = null,
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
            accessibility = accessibility(app),
            permissions = permissions(app),
        )
    }

    // MARK: - Permissions (status reads only — nothing is ever requested)

    /**
     * Reads the grants the tester gave the *host app*. `checkSelfPermission` is a status
     * query; Collie requests nothing and declares none of these permissions itself, so no
     * prompt can come out of filing a report — a bug reporter that raised one would teach
     * testers to decline.
     *
     * A permission the host does not declare in its manifest is reported as `null`, not
     * `denied`: `checkSelfPermission` cannot tell the two apart, and "camera denied" on an
     * app without a camera feature is a false lead in every report it appears in.
     */
    private fun permissions(context: Context): ColliePermissionState {
        val declared = declaredPermissions(context)
        return ColliePermissionState(
            camera = grant(context, declared, Manifest.permission.CAMERA),
            microphone = grant(context, declared, Manifest.permission.RECORD_AUDIO),
            photoLibrary = photoLibrary(context, declared),
            location = location(context, declared),
            locationAccuracy = locationAccuracy(context),
            notifications = notifications(context),
        )
    }

    private fun grant(context: Context, declared: Set<String>, permission: String): String? = when {
        isGranted(context, permission) -> "granted"
        permission in declared -> "denied"
        else -> null
    }

    /**
     * Android 13 split the gallery out of storage and Android 14 added the partial grant
     * ("Select photos") — the same state iOS calls `limited`. All three spellings are
     * checked rather than branching on the API level: a permission that does not exist on
     * the running version is simply never granted, and an app targeting below 33 still
     * uses the storage permission on an Android 13 device.
     */
    @Suppress("DEPRECATION") // READ_EXTERNAL_STORAGE is how the gallery is spelled below 13.
    private fun photoLibrary(context: Context, declared: Set<String>): String? = when {
        isGranted(context, Manifest.permission.READ_MEDIA_IMAGES) -> "granted"
        isGranted(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "limited"
        isGranted(context, Manifest.permission.READ_EXTERNAL_STORAGE) -> "granted"
        declared.any { it in GALLERY_PERMISSIONS } -> "denied"
        else -> null
    }

    /** Background access is iOS's "Always"; either foreground grant is "While Using". */
    private fun location(context: Context, declared: Set<String>): String? = when {
        isGranted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) -> "always"
        isGranted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            isGranted(context, Manifest.permission.ACCESS_COARSE_LOCATION) -> "whenInUse"

        declared.any { it in LOCATION_PERMISSIONS } -> "denied"
        else -> null
    }

    /** Coarse-only is what iOS reports as reduced accuracy — the same tester decision. */
    private fun locationAccuracy(context: Context): String? = when {
        isGranted(context, Manifest.permission.ACCESS_FINE_LOCATION) -> "full"
        isGranted(context, Manifest.permission.ACCESS_COARSE_LOCATION) -> "reduced"
        else -> null
    }

    /**
     * The effective state, not the permission: a channel switched off in system settings
     * silences notifications just as thoroughly as a declined `POST_NOTIFICATIONS`, and
     * "the push never arrived" is the report either one produces.
     *
     * Android cannot distinguish "never asked" from "declined" outside an Activity, so a
     * permission that was never requested reads as `denied` here, where iOS would say
     * `notDetermined`.
     */
    private fun notifications(context: Context): String? = runCatching {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (manager?.areNotificationsEnabled() == true) "granted" else "denied"
    }.getOrNull()

    private fun isGranted(context: Context, permission: String): Boolean =
        runCatching {
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)

    /** What the host's merged manifest asks for — Collie's own manifest adds none of these. */
    @Suppress("DEPRECATION") // The flags overload is the only one below Android 13.
    private fun declaredPermissions(context: Context): Set<String> = runCatching {
        val manager = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(
                context.packageName,
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
            )
        } else {
            manager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        }
        info.requestedPermissions?.toSet().orEmpty()
    }.getOrDefault(emptySet())

    @Suppress("DEPRECATION")
    private val GALLERY_PERMISSIONS = setOf(
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        Manifest.permission.READ_EXTERNAL_STORAGE,
    )

    private val LOCATION_PERMISSIONS = setOf(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
        Manifest.permission.ACCESS_BACKGROUND_LOCATION,
    )

    // MARK: - Accessibility & appearance

    /**
     * The switches iOS reads from `UIAccessibility` live in three different places here:
     * the configuration (night mode, font scale, font weight), a system service
     * (TalkBack, captions) and `Settings.Secure` / `Settings.Global` for the display
     * toggles Android has no public API for. Every read is guarded; a read that fails
     * outright leaves the field `null` rather than claiming the setting is off.
     *
     * The fields left at their defaults (switch control, AssistiveTouch, Speak Screen,
     * reduce transparency, differentiate-without-colour, on/off labels) are iOS-only
     * settings with no Android equivalent.
     */
    private fun accessibility(context: Context): CollieAccessibilityState {
        val configuration = context.resources.configuration
        return CollieAccessibilityState(
            interfaceStyle = interfaceStyle(configuration),
            fontScale = (configuration.fontScale * 100f).roundToInt() / 100.0,
            boldText = boldText(configuration),
            screenReader = screenReader(context),
            reduceMotion = reduceMotion(context),
            increaseContrast = secureFlag(context, HIGH_TEXT_CONTRAST),
            invertColors = secureFlag(context, COLOR_INVERSION),
            grayscale = grayscale(context),
            closedCaptions = closedCaptions(context),
            monoAudio = systemFlag(context, MASTER_MONO),
        )
    }

    private fun interfaceStyle(configuration: Configuration): String =
        when (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) {
            Configuration.UI_MODE_NIGHT_YES -> "dark"
            Configuration.UI_MODE_NIGHT_NO -> "light"
            else -> "unspecified"
        }

    /** "Bold text" moves every weight up; the setting itself is not readable directly. */
    private fun boldText(configuration: Configuration): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val adjustment = configuration.fontWeightAdjustment
        if (adjustment == Configuration.FONT_WEIGHT_ADJUSTMENT_UNDEFINED) return null
        return adjustment != 0
    }

    /**
     * Touch exploration, not merely "an accessibility service is enabled": that is what
     * TalkBack turns on, and the reason a tester's taps land somewhere else than they
     * expect.
     */
    private fun screenReader(context: Context): Boolean? =
        (context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager)
            ?.isTouchExplorationEnabled

    /**
     * "Remove animations" zeroes the animator scale; a report filed from such a device
     * explains a missing transition that reproduces nowhere else.
     */
    private fun reduceMotion(context: Context): Boolean? = runCatching {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f, // the platform's own default: animations at normal speed
        ) == 0f
    }.getOrNull()

    /** Colour correction set to monochromacy — Android's equivalent of iOS's grayscale. */
    private fun grayscale(context: Context): Boolean? {
        val enabled = secureFlag(context, COLOR_CORRECTION_ENABLED) ?: return null
        if (!enabled) return false
        val mode = secureInt(context, COLOR_CORRECTION_MODE) ?: return null
        return mode == COLOR_CORRECTION_MONOCHROMACY
    }

    private fun closedCaptions(context: Context): Boolean? =
        (context.getSystemService(Context.CAPTIONING_SERVICE) as? CaptioningManager)?.isEnabled

    /**
     * A toggle the user has never touched has no row in the settings table, and the
     * platform's own readers treat that absence as off — so does this. `null` is kept for
     * a read that fails outright, which is the only case where the value is unknowable.
     */
    private fun secureFlag(context: Context, key: String): Boolean? =
        runCatching { Settings.Secure.getInt(context.contentResolver, key, 0) == 1 }.getOrNull()

    /** Reads a setting whose absence is not meaningfully "0" — a mode, not a switch. */
    private fun secureInt(context: Context, key: String): Int? =
        runCatching { Settings.Secure.getInt(context.contentResolver, key, UNSET) }
            .getOrNull()?.takeIf { it != UNSET }

    private fun systemFlag(context: Context, key: String): Boolean? =
        runCatching { Settings.System.getInt(context.contentResolver, key, 0) == 1 }.getOrNull()

    // Settings keys with no public constant. Reading them needs no permission.
    private const val UNSET = -1
    private const val HIGH_TEXT_CONTRAST = "high_text_contrast_enabled"
    private const val COLOR_INVERSION = "accessibility_display_inversion_enabled"
    private const val COLOR_CORRECTION_ENABLED = "accessibility_display_daltonizer_enabled"
    private const val COLOR_CORRECTION_MODE = "accessibility_display_daltonizer"
    private const val COLOR_CORRECTION_MONOCHROMACY = 0
    private const val MASTER_MONO = "master_mono"

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
