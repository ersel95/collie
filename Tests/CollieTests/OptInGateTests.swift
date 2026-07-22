import XCTest
@testable import Collie

/// `Collie.configure` opt-in + fail-closed behavior.
final class CollieOptInGateTests: XCTestCase {

    override func tearDown() {
        Collie._resetForTesting()
        super.tearDown()
    }

    func testDisabledByDefaultIsNoOp() {
        // enabled: false (the default) → configure returns early, no service installed.
        Collie.configure(
            enabled: false,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            assigneeUsername: "jira.user"
        )
        XCTAssertFalse(Collie.isConfigured)
        XCTAssertNil(Collie.bugReportService)
    }

    func testEnabledWithEmptyPATIsNoOp() {
        Collie.configure(
            enabled: true,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "   ",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            assigneeUsername: "jira.user"
        )
        XCTAssertFalse(Collie.isConfigured)
    }

    func testEnabledWithMissingParentKeyIsNoOp() {
        // Reports are always created as subtasks under a parent; no parent → fail-closed.
        Collie.configure(
            enabled: true,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "",
            assigneeUsername: "jira.user"
        )
        XCTAssertFalse(Collie.isConfigured)
    }

    func testEnabledWithMissingAssigneeIsNoOp() {
        Collie.configure(
            enabled: true,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            assigneeUsername: ""
        )
        XCTAssertFalse(Collie.isConfigured)
    }

    func testValidConfigInstallsServiceAndIsIdempotent() {
        Collie.configure(
            enabled: true,
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            assigneeUsername: "jira.user"
        )
        XCTAssertTrue(Collie.isConfigured)
        let first = Collie.bugReportService

        // Idempotent: a second configure keeps the first one.
        Collie.configure(
            enabled: true,
            jiraBaseURL: URL(string: "https://other.example.com")!,
            pat: "other",
            projectKey: "OTHER",
            parentIssueKey: "OTHER-1",
            assigneeUsername: "other.user"
        )
        XCTAssertTrue(Collie.bugReportService === first)
    }
}
