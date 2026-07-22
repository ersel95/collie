import XCTest
@testable import Collie

final class JiraIssueBuilderTests: XCTestCase {

    private func makeConfig() -> CollieConfiguration {
        CollieConfiguration(
            enabled: true,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            subtaskIssueType: "Sub-task",
            assigneeUsername: "jira.user",
            defaultLabels: ["collie", "bug-report"],
            appDisplayName: "MyApp",
            environment: "staging"
        )
    }

    private func makeContext(
        whatHappened: String = "Payment screen did not open",
        entries: [CollieLogEntry] = []
    ) -> JiraIssueBuilder.ReportContext {
        JiraIssueBuilder.ReportContext(
            whatHappened: whatHappened,
            whatExpected: "The payment screen should have opened",
            testerName: "Ersel",
            identity: CollieDeviceIdentity(
                id: "device-uuid",
                name: "Ersel",
                model: "iPhone15,3",
                osVersion: "17.4",
                locale: "tr_TR",
                screen: "1179x2556"
            ),
            telemetry: nil,
            sessionID: "session-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: entries
        )
    }

    private func decodeFields(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["fields"] as? [String: Any]) ?? [:]
    }

    // MARK: - Fields (parent + assignee always come from the config)

    func testCreateBodyAlwaysContainsParentAndAssigneeFromConfig() throws {
        let body = try JiraIssueBuilder.makeCreateBody(configuration: makeConfig(), context: makeContext())
        let fields = try decodeFields(body)

        XCTAssertEqual((fields["parent"] as? [String: Any])?["key"] as? String, "PROJ-123")
        XCTAssertEqual((fields["assignee"] as? [String: Any])?["name"] as? String, "jira.user")
        XCTAssertEqual((fields["project"] as? [String: Any])?["key"] as? String, "PROJ")
        XCTAssertEqual((fields["issuetype"] as? [String: Any])?["name"] as? String, "Sub-task")
        XCTAssertEqual(fields["labels"] as? [String], ["collie", "bug-report"])
    }

    func testCreateBodyOmitsLabelsWhenEmpty() throws {
        var config = makeConfig()
        config.defaultLabels = []
        let body = try JiraIssueBuilder.makeCreateBody(configuration: config, context: makeContext())
        let fields = try decodeFields(body)
        XCTAssertNil(fields["labels"])
    }

    // MARK: - Summary

    func testSummaryUsesAppNameAndFirstLine() {
        let summary = JiraIssueBuilder.makeSummary(
            appName: "MyApp",
            whatHappened: "Payment screen did not open\nsecond line"
        )
        XCTAssertEqual(summary, "[MyApp] Payment screen did not open")
    }

    func testSummaryCappedAt250() {
        let long = String(repeating: "a", count: 400)
        let summary = JiraIssueBuilder.makeSummary(appName: "MyApp", whatHappened: long)
        XCTAssertEqual(summary.count, 250)
    }

    func testFirstLineFallsBackToBugReport() {
        XCTAssertEqual(JiraIssueBuilder.firstLine(""), "Bug report")
        XCTAssertEqual(JiraIssueBuilder.firstLine("   \nx"), "Bug report")
        XCTAssertEqual(JiraIssueBuilder.firstLine(nil), "Bug report")
    }

    // MARK: - Wiki escape (markup-injection prevention)

    func testWikiEscapeEscapesControlCharacters() {
        let escaped = JiraIssueBuilder.wikiEscape("a*b_c{d}[e]|f-g#h!i?j+k^l~m")
        XCTAssertEqual(escaped, ##"a\*b\_c\{d\}\[e\]\|f\-g\#h\!i\?j\+k\^l\~m"##)
    }

    func testWikiEscapeNormalizesCRLF() {
        XCTAssertEqual(JiraIssueBuilder.wikiEscape("a\r\nb"), "a\nb")
    }

    func testCodeBlockBreaksNestedCodeMacro() {
        let block = JiraIssueBuilder.codeBlock("x {code} y")
        XCTAssertEqual(block, "{code}\nx { code } y\n{code}")
    }

    // MARK: - Network section

    private func networkEntry(
        url: String,
        status: String? = nil,
        error: String? = nil,
        responseBody: String? = nil,
        at seconds: TimeInterval = 0
    ) -> CollieLogEntry {
        var metadata: [String: String] = ["method": "GET", "url": url, "durationMs": "120"]
        if let status { metadata["status"] = status }
        if let error { metadata["error"] = error }
        if let responseBody { metadata["responseBody"] = responseBody }
        return CollieLogEntry(
            date: Date(timeIntervalSince1970: seconds),
            level: "info",
            category: "network",
            message: "request",
            metadata: metadata
        )
    }

    func testNetworkSectionPutsFailuresFirstAndCapsRows() {
        // 20 successful + 1 failing request: the failure must come first, with 15 rows
        // total + a "+N more" note.
        var entries = (0..<20).map { networkEntry(url: "https://api.example.com/ok/\($0)", status: "200", at: TimeInterval($0)) }
        entries.append(networkEntry(url: "https://api.example.com/fail", status: "500", responseBody: "boom", at: 99))

        let views = entries.map(JiraIssueBuilder.NetworkView.init)
        let section = JiraIssueBuilder.formatNetwork(views)
        let lines = section.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines[0].contains("fail"))
        XCTAssertTrue(lines[0].contains("500"))
        XCTAssertTrue(section.contains("{code}\nboom\n{code}"))
        XCTAssertTrue(section.contains("_+6 more requests in attached collie-logs JSON_"))
    }

    func testNetworkSectionEmptyPlaceholder() {
        XCTAssertEqual(JiraIssueBuilder.formatNetwork([]), "_No network activity captured_")
    }

    func testFailureBodiesOnlyIncludedForFailures() {
        let ok = networkEntry(url: "https://api.example.com/ok", status: "200", responseBody: "should-not-appear")
        let section = JiraIssueBuilder.formatNetwork([JiraIssueBuilder.NetworkView(entry: ok)])
        XCTAssertFalse(section.contains("should-not-appear"))
    }

    // MARK: - Navigation and category counts

    func testNavigationSection() {
        let entry = CollieLogEntry(
            date: Date(timeIntervalSince1970: 0),
            level: "info",
            category: "navigation",
            message: "screen change",
            metadata: ["screen": "PaymentView", "kind": "push"]
        )
        let section = JiraIssueBuilder.formatNavigation([JiraIssueBuilder.NavigationView(entry: entry)])
        XCTAssertTrue(section.contains("PaymentView"))
        XCTAssertTrue(section.contains("(push)"))
    }

    func testCategorySummaryCountsSortedDescending() {
        let entries =
            (0..<3).map { _ in CollieLogEntry(date: Date(), level: "info", category: "network", message: "n") } +
            (0..<1).map { _ in CollieLogEntry(date: Date(), level: "info", category: "auth", message: "a") }
        let summary = JiraIssueBuilder.summarizeCategories(entries)
        let networkIndex = summary.range(of: "network: 3")
        let authIndex = summary.range(of: "auth: 1")
        XCTAssertNotNil(networkIndex)
        XCTAssertNotNil(authIndex)
        XCTAssertLessThan(networkIndex!.lowerBound, authIndex!.lowerBound)
        XCTAssertTrue(summary.contains("_Full log set attached as collie-logs JSON_"))
    }

    // MARK: - Full description

    func testDescriptionContainsAllSections() {
        let description = JiraIssueBuilder.makeDescription(
            configuration: makeConfig(),
            context: makeContext(entries: [networkEntry(url: "https://api.example.com/x", status: "404")])
        )
        for header in ["h3. Reporter", "h3. Environment", "h3. What happened?", "h3. What was expected?", "h3. Navigation", "h3. Network", "h3. Logs"] {
            XCTAssertTrue(description.contains(header), "Missing section: \(header)")
        }
        XCTAssertTrue(description.contains("Name:"))
        XCTAssertTrue(description.contains("Ersel"))
    }
}
