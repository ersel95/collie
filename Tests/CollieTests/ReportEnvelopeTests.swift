import XCTest
@testable import Collie

/// The upload envelope's wire format — the contract the backend's ingestion DTO and
/// report parser read.
final class ReportEnvelopeTests: XCTestCase {

    private func makeConfig() -> CollieConfiguration {
        CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "secret",
            environment: "uat"
        )
    }

    private func makeIdentity(name: String? = "Ada L.") -> CollieDeviceIdentity {
        CollieDeviceIdentity(
            id: "device-123",
            name: name,
            model: "iPhone15,3",
            osVersion: "17.5",
            locale: "tr_TR",
            screen: "1179x2556"
        )
    }

    private func makeContext(
        testerName: String? = "Ada L.",
        sessionID: String = "session-9",
        entries: [CollieLogEntry] = [],
        telemetry: CollieTelemetry? = nil
    ) -> ReportEnvelopeBuilder.ReportContext {
        ReportEnvelopeBuilder.ReportContext(
            whatHappened: "Login button did nothing",
            whatExpected: "It should open the dashboard",
            testerName: testerName,
            identity: makeIdentity(),
            telemetry: telemetry,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            collieInitializedAt: Date(timeIntervalSince1970: 1_699_999_000),
            entries: entries
        )
    }

    private func encodeToJSON(
        _ context: ReportEnvelopeBuilder.ReportContext
    ) throws -> [String: Any] {
        let data = try ReportEnvelopeBuilder.makeBody(configuration: makeConfig(), context: context)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Shape

    func testEnvelopeHasTheFourRequiredSections() throws {
        let json = try encodeToJSON(makeContext())
        XCTAssertNotNil(json["app"])
        XCTAssertNotNil(json["device"])
        XCTAssertNotNil(json["report"])
        XCTAssertNotNil(json["entries"])
    }

    /// Which app a report belongs to is resolved server-side from the api-key — the
    /// client must not invent an app key.
    func testEnvelopeCarriesNoAppKey() throws {
        let json = try encodeToJSON(makeContext())
        let app = try XCTUnwrap(json["app"] as? [String: Any])
        XCTAssertNil(app["key"])
        XCTAssertEqual(app["environment"] as? String, "uat")
    }

    func testDeviceSectionUsesTheIdentity() throws {
        let json = try encodeToJSON(makeContext())
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, "device-123")
        XCTAssertEqual(device["name"] as? String, "Ada L.")
        XCTAssertEqual(device["model"] as? String, "iPhone15,3")
        XCTAssertEqual(device["osVersion"] as? String, "17.5")
        XCTAssertEqual(device["locale"] as? String, "tr_TR")
        XCTAssertEqual(device["screen"] as? String, "1179x2556")
    }

    func testReportSectionCarriesBothFreeTextFields() throws {
        let json = try encodeToJSON(makeContext())
        let report = try XCTUnwrap(json["report"] as? [String: Any])
        XCTAssertEqual(report["whatHappened"] as? String, "Login button did nothing")
        XCTAssertEqual(report["whatExpected"] as? String, "It should open the dashboard")
        XCTAssertEqual(report["sessionId"] as? String, "session-9")
    }

    /// The backend parser reads ISO-8601 timestamps.
    func testCapturedAtIsISO8601() throws {
        let json = try encodeToJSON(makeContext())
        let report = try XCTUnwrap(json["report"] as? [String: Any])
        XCTAssertEqual(report["capturedAt"] as? String, "2023-11-14T22:13:20Z")
    }

    /// An absent session must be omitted rather than sent as an empty string.
    func testBlankSessionIDIsOmitted() throws {
        let json = try encodeToJSON(makeContext(sessionID: ""))
        let report = try XCTUnwrap(json["report"] as? [String: Any])
        XCTAssertNil(report["sessionId"])
    }

    /// The name typed in the sheet wins over the one stored on the identity.
    func testTesterNameOverridesTheStoredIdentityName() throws {
        let json = try encodeToJSON(makeContext(testerName: "Grace H."))
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertEqual(device["name"] as? String, "Grace H.")
    }

    // MARK: - Entries (lossless)

    /// ALL categories go out untouched — the backend keeps the raw stream and derives its
    /// own network/navigation views from it.
    func testEveryCategoryIsPreservedLossless() throws {
        let entries = [
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_001),
                level: "info", category: "navigation", message: "to dashboard",
                metadata: ["screen": "dashboard-main", "kind": "push"]
            ),
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_002),
                level: "error", category: "network", message: "GET /accounts",
                metadata: [
                    "method": "GET", "url": "https://api.example.com/accounts",
                    "status": "500", "durationMs": "1240",
                    "reqH.Accept": "application/json", "respH.Server": "nginx",
                ]
            ),
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_003),
                level: "debug", category: "payment", message: "custom category kept"
            ),
        ]
        let json = try encodeToJSON(makeContext(entries: entries))
        let encoded = try XCTUnwrap(json["entries"] as? [[String: Any]])

        XCTAssertEqual(encoded.count, 3)
        XCTAssertEqual(encoded.map { $0["category"] as? String }, ["navigation", "network", "payment"])

        // The metadata bag — including the reqH./respH. header prefixes the parser
        // depends on — survives verbatim.
        let network = try XCTUnwrap(encoded[1]["metadata"] as? [String: String])
        XCTAssertEqual(network["method"], "GET")
        XCTAssertEqual(network["status"], "500")
        XCTAssertEqual(network["reqH.Accept"], "application/json")
        XCTAssertEqual(network["respH.Server"], "nginx")
    }

    /// Entry timestamps use the `date` key in ISO-8601 (the parser accepts `date` as the
    /// fallback for `timestamp`).
    func testEntryDatesAreISO8601UnderTheDateKey() throws {
        let entries = [
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000),
                level: "info", category: "general", message: "hello"
            )
        ]
        let json = try encodeToJSON(makeContext(entries: entries))
        let encoded = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(encoded[0]["date"] as? String, "2023-11-14T22:13:20Z")
    }

    /// URLs must stay readable in the stored payload.
    func testSlashesAreNotEscaped() throws {
        let entries = [
            CollieLogEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000),
                level: "info", category: "network", message: "call",
                metadata: ["url": "https://api.example.com/v1/accounts"]
            )
        ]
        let data = try ReportEnvelopeBuilder.makeBody(
            configuration: makeConfig(),
            context: makeContext(entries: entries)
        )
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(raw.contains("https://api.example.com/v1/accounts"))
        XCTAssertFalse(raw.contains("\\/"))
    }

    // MARK: - Telemetry

    func testTelemetryIsOmittedWhenAbsent() throws {
        let json = try encodeToJSON(makeContext())
        XCTAssertNil(json["telemetry"])
    }

    func testTelemetryIsEncodedWhenPresent() throws {
        let telemetry = CollieTelemetry(
            timezone: "Europe/Istanbul", screenScale: 3, screenPoints: "393x852",
            networkType: "wifi", batteryLevel: 82, batteryState: "unplugged",
            lowPowerMode: false, thermalState: "nominal", orientation: "portrait",
            freeDiskBytes: 1024, totalDiskBytes: 2048,
            totalMemoryBytes: 4096, appMemoryBytes: 512
        )
        let json = try encodeToJSON(makeContext(telemetry: telemetry))
        let encoded = try XCTUnwrap(json["telemetry"] as? [String: Any])
        XCTAssertEqual(encoded["timezone"] as? String, "Europe/Istanbul")
        XCTAssertEqual(encoded["batteryLevel"] as? Int, 82)
        XCTAssertEqual(encoded["networkType"] as? String, "wifi")
    }
}
