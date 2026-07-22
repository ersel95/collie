import XCTest
@testable import Collie

final class CollieConfigurationTests: XCTestCase {

    private func makeConfig(baseURLString: String = "https://jira.example.com") -> CollieConfiguration {
        CollieConfiguration(
            enabled: true,
            jiraBaseURL: URL(string: baseURLString)!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            subtaskIssueType: "Sub-task",
            assigneeUsername: "jira.user",
            environment: "staging"
        )
    }

    // MARK: - URL construction

    func testIssueCreateURL() {
        let config = makeConfig()
        XCTAssertEqual(config.issueCreateURL.absoluteString, "https://jira.example.com/rest/api/2/issue")
    }

    func testIssueCreateURLHandlesTrailingSlashBase() {
        let config = makeConfig(baseURLString: "https://jira.example.com/")
        XCTAssertEqual(config.issueCreateURL.absoluteString, "https://jira.example.com/rest/api/2/issue")
    }

    func testAttachmentsURL() {
        let config = makeConfig()
        XCTAssertEqual(
            config.attachmentsURL(issueKey: "PROJ-456").absoluteString,
            "https://jira.example.com/rest/api/2/issue/PROJ-456/attachments"
        )
    }

    func testBrowseURL() {
        let config = makeConfig()
        XCTAssertEqual(
            config.browseURL(issueKey: "PROJ-456").absoluteString,
            "https://jira.example.com/browse/PROJ-456"
        )
    }

    // MARK: - Validation (fail-closed)

    func testValidConfigHasNoValidationError() {
        XCTAssertNil(makeConfig().validationError)
    }

    func testMissingPATFailsValidation() {
        var config = makeConfig()
        config.pat = "   "
        XCTAssertNotNil(config.validationError)
    }

    func testMissingProjectKeyFailsValidation() {
        var config = makeConfig()
        config.projectKey = ""
        XCTAssertNotNil(config.validationError)
    }

    func testMissingParentIssueKeyFailsValidation() {
        var config = makeConfig()
        config.parentIssueKey = ""
        XCTAssertNotNil(config.validationError)
    }

    func testMissingAssigneeFailsValidation() {
        var config = makeConfig()
        config.assigneeUsername = ""
        XCTAssertNotNil(config.validationError)
    }

    func testMissingSubtaskTypeFailsValidation() {
        var config = makeConfig()
        config.subtaskIssueType = " "
        XCTAssertNotNil(config.validationError)
    }

    // MARK: - Capture exclusion

    func testCaptureExclusionFragmentsContainHostAndRestPath() {
        let fragments = makeConfig().captureExclusionFragments
        XCTAssertTrue(fragments.contains("jira.example.com"))
        XCTAssertTrue(fragments.contains("/rest/api/2/issue"))
    }

    // MARK: - Bounds

    func testScreenshotQualityClamped() {
        let config = CollieConfiguration(
            jiraBaseURL: URL(string: "https://x.example.com")!,
            screenshotJPEGQuality: 5
        )
        XCTAssertLessThanOrEqual(config.screenshotJPEGQuality, 1)
        XCTAssertGreaterThanOrEqual(config.screenshotJPEGQuality, 0.1)
    }

    func testNegativeRetrySettingsClamped() {
        let config = CollieConfiguration(
            jiraBaseURL: URL(string: "https://x.example.com")!,
            requestTimeout: -5,
            maxRetryCount: -3,
            baseRetryDelay: -1,
            maxScreenshotBytes: -100
        )
        XCTAssertGreaterThanOrEqual(config.requestTimeout, 1)
        XCTAssertGreaterThanOrEqual(config.maxRetryCount, 0)
        XCTAssertGreaterThanOrEqual(config.baseRetryDelay, 0)
        XCTAssertGreaterThanOrEqual(config.maxScreenshotBytes, 0)
    }
}
