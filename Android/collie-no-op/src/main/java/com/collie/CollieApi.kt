package com.collie

import android.content.Context

/**
 * The rest of Collie's public surface, as no-ops.
 *
 * These types exist so the host's integration code — which names `CollieConfiguration`,
 * maps its logger onto `CollieLogEntry`, and may hand over a transport — compiles unchanged
 * in a release build.
 */

/** No-op configuration: accepted, stored, never acted on. */
public class CollieConfiguration(
    public val enabled: Boolean = false,
    public val apiBaseUrl: String = "",
    public val apiKey: String = "",
    public val reportsPath: String = DEFAULT_REPORTS_PATH,
    public val configPath: String = DEFAULT_CONFIG_PATH,
    public val asksBeforeReporting: Boolean = true,
    public val activatesOnShake: Boolean = true,
    public val environment: String = "staging",
    public val requestTimeoutMillis: Long = 15_000,
    public val maxRetryCount: Int = 5,
    public val baseRetryDelayMillis: Long = 5_000,
    public val screenshotJpegQuality: Double = 0.7,
    public val maxScreenshotBytes: Int = 4 * 1_048_576,
    public val logSnapshotProvider: (() -> List<CollieLogEntry>)? = null,
    public val sessionIdProvider: (() -> String?)? = null,
    public val diagnostics: ((String) -> Unit)? = null,
) {
    /**
     * The derived members the host reads at wiring time.
     *
     * These are not decoration: a host feeds [captureExclusionFragments] into its logging
     * tool's exclude list, and that line has to compile in a release build like any other.
     * They stay faithful to the real implementation — the exclusions are still computed, so
     * a release build that keeps its own network logger keeps excluding the same URLs.
     */
    public val effectiveJpegQuality: Double = screenshotJpegQuality.coerceIn(0.1, 1.0)

    /** Always `null`: there is nothing to validate when nothing can be installed. */
    public val validationError: String? get() = null

    public val reportsUrl: String get() = url(reportsPath)

    public val configUrl: String get() = url(configPath)

    /** Whole URLs, matching the real artifact — see its documentation for why. */
    public val captureExclusionFragments: List<String>
        get() = listOf(reportsUrl, configUrl).filter { it.isNotEmpty() }

    private fun url(path: String): String {
        val base = apiBaseUrl.trimEnd('/')
        val normalized = if (path.startsWith("/")) path else "/$path"
        return base + normalized
    }

    public companion object {
        public const val DEFAULT_REPORTS_PATH: String = "/api/v1/collie/reports"
        public const val DEFAULT_CONFIG_PATH: String = "/api/v1/collie/config"
        public const val API_KEY_HEADER: String = "x-collie-api-key"
    }
}

/** Same shape as the real entry; a release build simply never asks for a snapshot. */
public data class CollieLogEntry(
    public val epochMillis: Long,
    public val level: String,
    public val category: String,
    public val message: String,
    public val metadata: Map<String, String> = emptyMap(),
)

public data class CollieTelemetry(
    public val timezone: String?,
    public val screenScale: Double?,
    public val screenPoints: String?,
    public val networkType: String?,
    public val batteryLevel: Int?,
    public val batteryState: String?,
    public val lowPowerMode: Boolean?,
    public val thermalState: String?,
    public val orientation: String?,
    public val freeDiskBytes: Long?,
    public val totalDiskBytes: Long?,
    public val totalMemoryBytes: Long?,
    public val appMemoryBytes: Long?,
)

public object CollieTelemetryCollector {
    /** Everything unavailable — nothing about the device is read in a release build. */
    public fun capture(context: Context): CollieTelemetry = CollieTelemetry(
        timezone = null,
        screenScale = null,
        screenPoints = null,
        networkType = null,
        batteryLevel = null,
        batteryState = null,
        lowPowerMode = null,
        thermalState = null,
        orientation = null,
        freeDiskBytes = null,
        totalDiskBytes = null,
        totalMemoryBytes = null,
        appMemoryBytes = null,
    )
}

public data class CollieDeviceIdentity(
    public val id: String,
    public val name: String?,
    public val model: String,
    public val osVersion: String,
    public val locale: String,
    public val screen: String,
    public val bundleId: String,
    public val appVersion: String,
    public val appBuild: String,
) {
    public companion object {
        public fun current(context: Context): CollieDeviceIdentity = CollieDeviceIdentity(
            id = "",
            name = null,
            model = "",
            osVersion = "",
            locale = "",
            screen = "",
            bundleId = context.packageName,
            appVersion = "",
            appBuild = "",
        )

        public fun hasStoredName(context: Context): Boolean = false

        public fun storeName(context: Context, name: String): Unit = Unit
    }
}

public sealed interface CollieOperationResult<out T> {
    public data class Success<T>(public val value: T) : CollieOperationResult<T>
    public data class PermanentFailure(public val reason: String) : CollieOperationResult<Nothing>
    public data class TransientFailure(public val reason: String) : CollieOperationResult<Nothing>
}

public data class CollieRemoteConfig(
    public val captureEnabled: Boolean,
    public val maxScreenshotBytes: Int? = null,
)

public interface ReportTransport {
    public suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String>

    public suspend fun fetchRemoteConfig(): CollieRemoteConfig?
}

public sealed interface CollieSubmitOutcome {
    public data class Sent(public val reportId: String) : CollieSubmitOutcome
    public data object Queued : CollieSubmitOutcome
    public data class Rejected(public val reason: String) : CollieSubmitOutcome
}

/**
 * Present only so `Collie.bugReportService` keeps its type. A release build never has an
 * instance, so none of these members can be reached.
 */
public class BugReportService private constructor() {
    public val isCaptureEnabled: Boolean get() = false
    public val maxScreenshotBytes: Int get() = 0
    public val screenshotJpegQuality: Double get() = 0.0
    public val hasStoredTesterName: Boolean get() = false
    public fun storeTesterName(name: String): Unit = Unit
    public fun flushPendingUploads(): Unit = Unit

    public suspend fun sendReport(
        whatHappened: String,
        testerName: String?,
        screenshotJpeg: ByteArray?,
        identity: CollieDeviceIdentity,
        telemetry: CollieTelemetry? = null,
    ): CollieSubmitOutcome = CollieSubmitOutcome.Rejected("Collie is not present in this build")
}
