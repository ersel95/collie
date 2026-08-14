package com.collie

import com.collie.internal.CollieSessionTracker
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

    private fun stamp(
        previousReportAtMillis: Long? = 1_769_615_662_000, // 2026-01-28T15:54:22Z
    ) = CollieSessionTracker.ReportStamp(
        processStartedAtMillis = 1_769_607_603_000, // 2026-01-28T13:40:03Z
        sessionStartedAtMillis = 1_769_612_530_000, // 2026-01-28T15:02:10Z
        sessionOrdinal = 7,
        previousReportAtMillis = previousReportAtMillis,
        sequence = 3,
        resumes = emptyList(),
    )

    private fun envelope(
        whatHappened: String = "The list stayed empty",
        testerName: String? = null,
        sessionId: String = "session-9",
        entries: List<CollieLogEntry> = emptyList(),
        telemetry: CollieTelemetry? = null,
        session: CollieSessionTracker.ReportStamp? = null,
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
                entries = entries,
                session = session,
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

    // MARK: - Session context (the panel's fold boundary)

    @Test
    fun `the session context is encoded`() {
        val report = envelope(session = stamp()).getJSONObject("report")
        assertEquals("android", report.getString("platform"))
        assertEquals("2026-01-28T15:54:22Z", report.getString("previousReportAt"))
        assertEquals("2026-01-28T15:02:10Z", report.getString("sessionStartedAt"))
        assertEquals("2026-01-28T13:40:03Z", report.getString("processStartedAt"))
        assertEquals(7, report.getInt("sessionOrdinal"))
        assertEquals(3, report.getInt("sequence"))
    }

    @Test
    fun `session timestamps carry an offset`() {
        // The boundary is found by *comparing* `previousReportAt` with the entry timestamps,
        // so every one of them has to carry an offset. A bare `2026-01-28T15:54:22` would be
        // read in the browser's timezone and slide the fold by hours — which is what a
        // `SimpleDateFormat` pattern without the zone produces.
        val report = envelope(session = stamp()).getJSONObject("report")
        listOf("capturedAt", "previousReportAt", "sessionStartedAt", "processStartedAt").forEach { key ->
            assertTrue("$key has no UTC offset", report.getString(key).endsWith("Z"))
        }
    }

    @Test
    fun `previous report at is omitted on the first report`() {
        val report = envelope(session = stamp(previousReportAtMillis = null)).getJSONObject("report")
        assertFalse(report.has("previousReportAt"))
        assertTrue(report.has("sessionStartedAt"))
    }

    @Test
    fun `the session context is omitted when absent`() {
        // The panel renders a report without these fields exactly as it did before they
        // existed, which is what keeps older SDK versions working. They stay optional.
        val report = envelope(session = null).getJSONObject("report")
        listOf(
            "previousReportAt",
            "sessionStartedAt",
            "processStartedAt",
            "sessionOrdinal",
            "sequence",
        ).forEach { key -> assertFalse("$key should be omitted", report.has(key)) }
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
        val encoded = envelope(telemetry = telemetry()).getJSONObject("telemetry")
        assertEquals("Europe/Istanbul", encoded.getString("timezone"))
        assertEquals(82, encoded.getInt("batteryLevel"))
        // No PII ever, and fields that could not be collected vanish rather than
        // travelling as nulls the panel would have to special-case.
        assertFalse(encoded.has("totalMemoryBytes"))
        assertFalse(encoded.has("appMemoryBytes"))
    }

    private fun telemetry(
        accessibility: CollieAccessibilityState? = null,
        permissions: ColliePermissionState? = null,
    ) = CollieTelemetry(
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
        accessibility = accessibility,
        permissions = permissions,
    )

    // MARK: - Accessibility (how the device presents the app)

    @Test
    fun `the accessibility state is encoded inside telemetry`() {
        // Dark mode, text size and the accessibility switches travel as a nested block
        // inside `telemetry`, under the same keys `ReportEnvelopeTests.swift` asserts.
        val accessibility = CollieAccessibilityState(
            interfaceStyle = "dark",
            fontScale = 1.35,
            boldText = true,
            screenReader = false,
            reduceMotion = true,
            increaseContrast = false,
            invertColors = false,
        )
        val encoded = envelope(telemetry = telemetry(accessibility))
            .getJSONObject("telemetry").getJSONObject("accessibility")
        assertEquals("dark", encoded.getString("interfaceStyle"))
        assertEquals(1.35, encoded.getDouble("fontScale"), 0.001)
        assertTrue(encoded.getBoolean("boldText"))
        assertFalse(encoded.getBoolean("screenReader"))
        assertTrue(encoded.getBoolean("reduceMotion"))
    }

    @Test
    fun `a setting this platform cannot read is omitted rather than sent as false`() {
        // `contentSize` and the iOS-only switches have no Android equivalent, and a settings
        // read that fails leaves its field unset — the panel has to be able to tell "off"
        // from "not knowable here".
        val encoded = envelope(telemetry = telemetry(CollieAccessibilityState(interfaceStyle = "light")))
            .getJSONObject("telemetry").getJSONObject("accessibility")
        assertEquals("light", encoded.getString("interfaceStyle"))
        listOf("contentSize", "switchControl", "assistiveTouch", "reduceTransparency", "monoAudio")
            .forEach { key -> assertFalse("$key should be omitted", encoded.has(key)) }
    }

    // MARK: - Permissions (what the tester answered to the prompts)

    @Test
    fun `the permission state is encoded inside telemetry`() {
        // The grants travel as their own nested block, under the keys
        // `ReportEnvelopeTests.swift` asserts.
        val permissions = ColliePermissionState(
            camera = "granted",
            microphone = "denied",
            photoLibrary = "limited",
            location = "whenInUse",
            locationAccuracy = "reduced",
            notifications = "denied",
        )
        val encoded = envelope(telemetry = telemetry(permissions = permissions))
            .getJSONObject("telemetry").getJSONObject("permissions")
        assertEquals("granted", encoded.getString("camera"))
        assertEquals("denied", encoded.getString("microphone"))
        assertEquals("limited", encoded.getString("photoLibrary"))
        assertEquals("whenInUse", encoded.getString("location"))
        assertEquals("reduced", encoded.getString("locationAccuracy"))
        assertEquals("denied", encoded.getString("notifications"))
    }

    @Test
    fun `a permission the host does not declare is omitted`() {
        // "The app has no camera feature" and "the tester declined the camera" must not
        // read the same in the panel.
        val encoded = envelope(telemetry = telemetry(permissions = ColliePermissionState(camera = "granted")))
            .getJSONObject("telemetry").getJSONObject("permissions")
        assertEquals("granted", encoded.getString("camera"))
        listOf("microphone", "photoLibrary", "location", "locationAccuracy", "notifications")
            .forEach { key -> assertFalse("$key should be omitted", encoded.has(key)) }
    }

    @Test
    fun `permissions are omitted when absent`() {
        assertFalse(envelope(telemetry = telemetry()).getJSONObject("telemetry").has("permissions"))
    }

    @Test
    fun `accessibility is omitted when absent`() {
        // A report from an SDK version that never collected it has no `accessibility` key
        // at all — the block is additive, like the session context before it.
        val encoded = envelope(telemetry = telemetry()).getJSONObject("telemetry")
        assertFalse(encoded.has("accessibility"))
        assertEquals("Europe/Istanbul", encoded.getString("timezone"))
    }
}
