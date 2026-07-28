package com.collie

import com.collie.internal.ReportEnvelopeBuilder
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The envelope is the backend's ingestion contract, and the panel parses **one** shape for
 * both platforms. These assertions mirror `ReportEnvelopeTests.swift` field for field: if
 * Android ever starts sending a different document for the same report, this fails.
 */
class ReportEnvelopeTest {

    private val identity = CollieDeviceIdentity(
        id = "device-1",
        name = "Stored Name",
        model = "Google Pixel 9",
        osVersion = "16",
        locale = "tr_TR",
        screen = "1280x2856",
        bundleId = "com.example.app",
        appVersion = "3.2.1",
        appBuild = "4210",
    )

    private val configuration = CollieConfiguration(
        enabled = true,
        apiBaseUrl = "https://collie.example.com",
        apiKey = "key",
        environment = "uat",
    )

    private fun envelope(
        whatHappened: String = "The list stayed empty",
        testerName: String? = null,
        sessionId: String = "session-9",
        entries: List<CollieLogEntry> = emptyList(),
        telemetry: CollieTelemetry? = null,
    ): JSONObject {
        val body = ReportEnvelopeBuilder.makeBody(
            configuration = configuration,
            context = ReportEnvelopeBuilder.ReportContext(
                whatHappened = whatHappened,
                testerName = testerName,
                identity = identity,
                telemetry = telemetry,
                sessionId = sessionId,
                capturedAtMillis = 1_769_616_610_000, // 2026-01-28T16:10:10Z
                collieInitializedAtMillis = 1_769_616_600_000,
                entries = entries,
            ),
        )
        return JSONObject(String(body, Charsets.UTF_8))
    }

    @Test
    fun `the envelope has the four required sections`() {
        val json = envelope()
        listOf("app", "device", "report", "entries").forEach { key ->
            assertTrue("missing section: $key", json.has(key))
        }
    }

    @Test
    fun `the envelope carries no app key`() {
        // Which app a report belongs to is resolved from the api-key server-side; the
        // Firestore transport adds its own `appKey` on top of this document.
        val raw = envelope().toString()
        assertFalse(raw.contains("appKey"))
    }

    @Test
    fun `the app section describes the host build`() {
        val app = envelope().getJSONObject("app")
        assertEquals("com.example.app", app.getString("bundleId"))
        assertEquals("3.2.1", app.getString("version"))
        assertEquals("4210", app.getString("build"))
        assertEquals("uat", app.getString("environment"))
    }

    @Test
    fun `the device section uses the identity`() {
        val device = envelope().getJSONObject("device")
        assertEquals("device-1", device.getString("id"))
        assertEquals("Google Pixel 9", device.getString("model"))
        assertEquals("tr_TR", device.getString("locale"))
        assertEquals("1280x2856", device.getString("screen"))
    }

    @Test
    fun `a tester name overrides the stored identity name`() {
        val device = envelope(testerName = "Ersel").getJSONObject("device")
        assertEquals("Ersel", device.getString("name"))
    }

    @Test
    fun `captured at is iso 8601`() {
        val capturedAt = envelope().getJSONObject("report").getString("capturedAt")
        assertEquals("2026-01-28T16:10:10Z", capturedAt)
    }

    @Test
    fun `a blank session id is omitted`() {
        assertFalse(envelope(sessionId = "  ").getJSONObject("report").has("sessionId"))
    }

    @Test
    fun `every category is preserved lossless`() {
        val entries = listOf(
            CollieLogEntry(1_769_616_601_000, "info", "network", "GET /accounts"),
            CollieLogEntry(1_769_616_602_000, "debug", "navigation", "AccountsScreen"),
            CollieLogEntry(1_769_616_603_000, "error", "app", "Boom"),
            CollieLogEntry(1_769_616_604_000, "warning", "analytics", "event fired"),
        )
        val encoded = envelope(entries = entries).getJSONArray("entries")
        assertEquals(4, encoded.length())
        val categories = (0 until encoded.length())
            .map { encoded.getJSONObject(it).getString("category") }
        assertEquals(listOf("network", "navigation", "app", "analytics"), categories)
    }

    @Test
    fun `entry dates are iso 8601 under the date key`() {
        val entries = listOf(CollieLogEntry(1_769_616_601_000, "info", "app", "hello"))
        val entry = envelope(entries = entries).getJSONArray("entries").getJSONObject(0)
        assertEquals("2026-01-28T16:10:01Z", entry.getString("date"))
    }

    @Test
    fun `entry metadata survives with its keys`() {
        val entries = listOf(
            CollieLogEntry(
                epochMillis = 1_769_616_601_000,
                level = "info",
                category = "network",
                message = "GET /accounts",
                metadata = mapOf(
                    "method" to "GET",
                    "status" to "200",
                    "reqH.Authorization" to "Bearer x",
                ),
            ),
        )
        val metadata = envelope(entries = entries)
            .getJSONArray("entries").getJSONObject(0).getJSONObject("metadata")
        assertEquals("GET", metadata.getString("method"))
        assertEquals("200", metadata.getString("status"))
        assertEquals("Bearer x", metadata.getString("reqH.Authorization"))
    }

    @Test
    fun `slashes are not escaped`() {
        val entries = listOf(
            CollieLogEntry(
                epochMillis = 1_769_616_601_000,
                level = "info",
                category = "network",
                message = "GET https://api.example.com/v1/accounts",
            ),
        )
        // `org.json` does not escape forward slashes, and neither does the iOS encoder
        // (`.withoutEscapingSlashes`) — URLs stay readable in the stored payload.
        assertFalse(envelope(entries = entries).toString().contains("\\/"))
    }

    @Test
    fun `telemetry is omitted when absent`() {
        assertFalse(envelope(telemetry = null).has("telemetry"))
    }

    @Test
    fun `telemetry is encoded when present and drops unavailable fields`() {
        val telemetry = CollieTelemetry(
            timezone = "Europe/Istanbul",
            screenScale = 3.0,
            screenPoints = "412x915",
            networkType = "wifi",
            batteryLevel = 82,
            batteryState = "unplugged",
            lowPowerMode = false,
            thermalState = "nominal",
            orientation = "portrait",
            freeDiskBytes = 1_000L,
            totalDiskBytes = 2_000L,
            totalMemoryBytes = null,
            appMemoryBytes = null,
        )
        val encoded = envelope(telemetry = telemetry).getJSONObject("telemetry")
        assertEquals("Europe/Istanbul", encoded.getString("timezone"))
        assertEquals(82, encoded.getInt("batteryLevel"))
        // No PII ever, and fields that could not be collected vanish rather than
        // travelling as nulls the panel would have to special-case.
        assertFalse(encoded.has("totalMemoryBytes"))
        assertFalse(encoded.has("appMemoryBytes"))
    }
}
