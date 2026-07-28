package com.collie.internal

import com.collie.CollieConfiguration
import com.collie.CollieDeviceIdentity
import com.collie.CollieLogEntry
import com.collie.CollieTelemetry
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Builds the JSON `report` part of the multipart upload sent to the Collie backend.
 *
 * The wire format is the backend's ingestion contract, **identical to the iOS SDK's** —
 * the panel and the bridge parse one shape, not one per platform:
 * ```jsonc
 * {
 *   "app":       { "bundleId": …, "version": …, "build": …, "environment": … },
 *   "device":    { "id": …, "name": …, "model": …, "osVersion": …, "locale": …, "screen": … },
 *   "report":    { "whatHappened": …, "capturedAt": …, "sessionId": … },
 *   "entries":   [ /* raw CollieLogEntry[] — ALL categories, lossless */ ],
 *   "telemetry": { /* point-in-time device state, no PII */ }
 * }
 * ```
 *
 * Which app a report belongs to is resolved **server-side from the api-key** (or from the
 * app key the Firestore transport writes), so no app key or slug is sent here.
 *
 * `entries` go out exactly as the host provided them: every category is preserved and
 * nothing is summarized or truncated. The backend keeps the raw stream and derives its
 * network/navigation views from it — the same `metadata` key convention documented on
 * [CollieLogEntry] (`method`/`url`/`status`/…, `reqH.`/`respH.` header prefixes).
 *
 * Absent values are **omitted** rather than written as `null`, which is what Swift's
 * `JSONEncoder` does with `nil` optionals; the two platforms therefore produce the same
 * document for the same report.
 */
internal object ReportEnvelopeBuilder {

    /** Everything needed to describe one report. */
    internal data class ReportContext(
        val whatHappened: String,
        val testerName: String?,
        val identity: CollieDeviceIdentity,
        val telemetry: CollieTelemetry?,
        val sessionId: String,
        val capturedAtMillis: Long,
        val collieInitializedAtMillis: Long,
        val entries: List<CollieLogEntry>,
    )

    /**
     * Encodes the `report` JSON part.
     *
     * Dates (entry timestamps, `capturedAt`) are ISO-8601 in UTC — the format the backend
     * parser reads, and the same one `JSONEncoder.DateEncodingStrategy.iso8601` produces.
     */
    internal fun makeBody(
        configuration: CollieConfiguration,
        context: ReportContext,
    ): ByteArray {
        val app = JSONObject()
            .put("bundleId", context.identity.bundleId)
            .put("version", context.identity.appVersion)
            .put("build", context.identity.appBuild)
            .put("environment", configuration.environment)

        val device = JSONObject()
            .put("id", context.identity.id)
            .putIfPresent("name", context.testerName ?: context.identity.name)
            .put("model", context.identity.model)
            .put("osVersion", context.identity.osVersion)
            .put("locale", context.identity.locale)
            .put("screen", context.identity.screen)

        val report = JSONObject()
            .put("whatHappened", context.whatHappened)
            .put("capturedAt", isoDate(context.capturedAtMillis))
            .putIfPresent("sessionId", context.sessionId.ifBlank { null })

        val entries = JSONArray()
        context.entries.forEach { entries.put(it.toJson()) }

        val envelope = JSONObject()
            .put("app", app)
            .put("device", device)
            .put("report", report)
            .put("entries", entries)
            .putIfPresent("telemetry", context.telemetry?.toJson())

        return envelope.toString().toByteArray(Charsets.UTF_8)
    }

    private fun CollieLogEntry.toJson(): JSONObject {
        val metadataJson = JSONObject()
        metadata.forEach { (key, value) -> metadataJson.put(key, value) }
        return JSONObject()
            .put("date", isoDate(epochMillis))
            .put("level", level)
            .put("category", category)
            .put("message", message)
            .put("metadata", metadataJson)
    }

    private fun CollieTelemetry.toJson(): JSONObject = JSONObject()
        .putIfPresent("timezone", timezone)
        .putIfPresent("screenScale", screenScale)
        .putIfPresent("screenPoints", screenPoints)
        .putIfPresent("networkType", networkType)
        .putIfPresent("batteryLevel", batteryLevel)
        .putIfPresent("batteryState", batteryState)
        .putIfPresent("lowPowerMode", lowPowerMode)
        .putIfPresent("thermalState", thermalState)
        .putIfPresent("orientation", orientation)
        .putIfPresent("freeDiskBytes", freeDiskBytes)
        .putIfPresent("totalDiskBytes", totalDiskBytes)
        .putIfPresent("totalMemoryBytes", totalMemoryBytes)
        .putIfPresent("appMemoryBytes", appMemoryBytes)

    /** `JSONObject.put(key, null)` stores a JSON null; absent fields must vanish instead. */
    private fun JSONObject.putIfPresent(key: String, value: Any?): JSONObject =
        if (value == null) this else put(key, value)

    // MARK: - Formatting helpers

    /** ISO-8601 in UTC, seconds precision: `2026-07-28T16:10:10Z`. */
    internal fun isoDate(epochMillis: Long): String = isoFormatter().format(Date(epochMillis))

    /** Human-readable timestamp used in Collie's own synthetic log entries. */
    internal fun dateTimeString(epochMillis: Long, seconds: Boolean = true): String {
        val pattern = if (seconds) "dd.MM.yyyy HH:mm:ss" else "dd.MM.yyyy HH:mm"
        return SimpleDateFormat(pattern, Locale.US).format(Date(epochMillis))
    }

    // `SimpleDateFormat` is not thread-safe and reports are built off the main thread, so a
    // fresh instance per call is the cheap correct answer (a report has one of these, plus
    // one per log entry — nowhere near hot).
    private fun isoFormatter(): SimpleDateFormat =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
}
