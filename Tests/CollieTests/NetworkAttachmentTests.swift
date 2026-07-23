import XCTest
@testable import Collie

/// Per-request network attachments: deterministic order/filenames (the description links
/// to them before they exist in Jira) and a readable plain-text dump.
final class NetworkAttachmentTests: XCTestCase {

    private func networkEntry(
        method: String = "GET",
        url: String,
        status: String? = nil,
        error: String? = nil,
        metadata extra: [String: String] = [:],
        at seconds: TimeInterval = 0
    ) -> CollieLogEntry {
        var metadata: [String: String] = ["method": method, "url": url, "durationMs": "120"]
        if let status { metadata["status"] = status }
        if let error { metadata["error"] = error }
        metadata.merge(extra) { _, new in new }
        return CollieLogEntry(
            date: Date(timeIntervalSince1970: seconds),
            level: "info",
            category: "network",
            message: "request",
            metadata: metadata
        )
    }

    // MARK: - Plan

    func testPlanOrdersFailuresFirstAndNumbersFilesInThatOrder() {
        let entries = [
            networkEntry(url: "https://api.example.com/v1/users", status: "200", at: 0),
            networkEntry(method: "POST", url: "https://api.example.com/v1/payments", status: "500", at: 1)
        ]
        let plan = NetworkAttachmentBuilder.plan(entries: entries, limit: 50)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].filename, "net-001-POST-500-v1-payments.txt")
        XCTAssertEqual(plan[1].filename, "net-002-GET-200-v1-users.txt")
    }

    func testPlanIgnoresNonNetworkEntries() {
        let entries = [
            CollieLogEntry(date: Date(timeIntervalSince1970: 0), level: "info", category: "navigation", message: "screen"),
            networkEntry(url: "https://api.example.com/ok", status: "200")
        ]
        XCTAssertEqual(NetworkAttachmentBuilder.plan(entries: entries, limit: 50).count, 1)
    }

    func testPlanStopsNamingFilesPastTheLimit() {
        let entries = (0..<4).map { networkEntry(url: "https://api.example.com/ok/\($0)", status: "200", at: TimeInterval($0)) }
        let plan = NetworkAttachmentBuilder.plan(entries: entries, limit: 2)

        XCTAssertEqual(plan.compactMap(\.filename).count, 2)
        XCTAssertNil(plan[2].filename)
        XCTAssertNil(plan[3].filename)
        XCTAssertEqual(NetworkAttachmentBuilder.attachments(for: plan).count, 2)
    }

    func testLimitZeroProducesNoAttachments() {
        let plan = NetworkAttachmentBuilder.plan(
            entries: [networkEntry(url: "https://api.example.com/ok", status: "200")],
            limit: 0
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(NetworkAttachmentBuilder.attachments(for: plan).isEmpty)
    }

    // MARK: - Filenames

    /// Filenames go straight into a `[^...]` wiki link, so nothing outside
    /// `[A-Za-z0-9.-]` may survive.
    func testFilenameIsSlugSafeForUnusualURLs() {
        let entry = networkEntry(
            method: "post",
            url: "https://api.example.com/v2/kullanıcı ara?q=a|b&x=[1]",
            status: "404"
        )
        let name = NetworkAttachmentBuilder.filename(order: 7, view: .init(entry: entry))

        XCTAssertTrue(name.hasPrefix("net-007-POST-404-"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
        XCTAssertNil(name.range(of: "[^A-Za-z0-9.-]", options: .regularExpression), name)
    }

    func testFilenameUsesERRWhenThereIsNoStatus() {
        let entry = networkEntry(url: "https://api.example.com/v1/ping", error: "timed out")
        let name = NetworkAttachmentBuilder.filename(order: 1, view: .init(entry: entry))
        XCTAssertEqual(name, "net-001-GET-ERR-v1-ping.txt")
    }

    func testFilenameFallsBackToHostWhenThereIsNoPath() {
        let entry = networkEntry(url: "https://api.example.com", status: "200")
        let name = NetworkAttachmentBuilder.filename(order: 1, view: .init(entry: entry))
        XCTAssertEqual(name, "net-001-GET-200-api-example-com.txt")
    }

    // MARK: - File body

    func testTextDumpContainsSummaryHeadersAndFullBodies() {
        let longBody = String(repeating: "x", count: 5_000)
        let entry = networkEntry(
            method: "POST",
            url: "https://api.example.com/v1/pay",
            status: "500",
            error: "internal server error",
            metadata: [
                "requestBody": #"{"amount":10}"#,
                "responseBody": longBody,
                "reqH.Content-Type": "application/json",
                "respH.X-Trace-Id": "abc123",
                "respBytes": "5000"
            ]
        )
        let text = NetworkAttachmentBuilder.makeText(for: .init(entry: entry))

        XCTAssertTrue(text.hasPrefix("POST https://api.example.com/v1/pay\n"), text)
        XCTAssertTrue(text.contains("Status:   500"))
        XCTAssertTrue(text.contains("Duration: 120ms"))
        XCTAssertTrue(text.contains("Error:    internal server error"))
        XCTAssertTrue(text.contains("--- Request headers ---\nContent-Type: application/json"))
        XCTAssertTrue(text.contains("--- Request body ---\n{\"amount\":10}"))
        XCTAssertTrue(text.contains("--- Response headers ---\nX-Trace-Id: abc123"))
        XCTAssertTrue(text.contains("--- Other metadata ---\nrespBytes: 5000"))
        // The whole point of the per-request file: the body is never truncated.
        XCTAssertTrue(text.contains(longBody))
    }

    func testTextDumpOmitsEmptySections() {
        let text = NetworkAttachmentBuilder.makeText(
            for: .init(entry: networkEntry(url: "https://api.example.com/ok", status: "200"))
        )
        XCTAssertFalse(text.contains("--- Request body ---"))
        XCTAssertFalse(text.contains("--- Response headers ---"))
    }

    func testAttachmentsAreUTF8TextFiles() {
        let plan = NetworkAttachmentBuilder.plan(
            entries: [networkEntry(url: "https://api.example.com/v1/ok", status: "200")],
            limit: 50
        )
        let attachments = NetworkAttachmentBuilder.attachments(for: plan)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].mimeType, "text/plain")
        XCTAssertEqual(attachments[0].filename, "net-001-GET-200-v1-ok.txt")
        XCTAssertNotNil(String(data: attachments[0].data, encoding: .utf8))
    }
}
