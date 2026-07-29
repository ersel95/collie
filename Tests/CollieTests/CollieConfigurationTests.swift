import XCTest
@testable import Collie

final class CollieConfigurationTests: XCTestCase {

    private func makeConfig(baseURLString: String = "https://collie.example.com") -> CollieConfiguration {
        CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: baseURLString)!,
            apiKey: "secret",
            environment: "staging"
        )
    }

    // MARK: - Flow

    /// A shake asks before opening the form unless the host opts out — and the choice is
    /// explicit, never derived from whether `Collie.onLogoTap` is wired.
    func testAsksBeforeReportingDefaultsToTrue() {
        XCTAssertTrue(makeConfig().asksBeforeReporting)
    }

    func testAsksBeforeReportingCanBeDisabled() {
        var config = makeConfig()
        config.asksBeforeReporting = false
        XCTAssertFalse(config.asksBeforeReporting)
    }

    // MARK: - URL construction

    func testReportsURL() {
        let config = makeConfig()
        XCTAssertEqual(
            config.reportsURL.absoluteString,
            "https://collie.example.com/api/v1/collie/reports"
        )
    }

    func testReportsURLHandlesTrailingSlashBase() {
        let config = makeConfig(baseURLString: "https://collie.example.com/")
        XCTAssertEqual(
            config.reportsURL.absoluteString,
            "https://collie.example.com/api/v1/collie/reports"
        )
    }

    func testConfigURL() {
        let config = makeConfig()
        XCTAssertEqual(
            config.configURL.absoluteString,
            "https://collie.example.com/api/v1/collie/config"
        )
    }

    /// The endpoint paths are overridable so a host can point at a differently mounted
    /// backend without waiting for an SDK release.
    func testCustomPathsAreHonoured() {
        var config = makeConfig()
        config.reportsPath = "/ingest/reports"
        config.configPath = "config"
        XCTAssertEqual(config.reportsURL.absoluteString, "https://collie.example.com/ingest/reports")
        XCTAssertEqual(config.configURL.absoluteString, "https://collie.example.com/config")
    }

    // MARK: - Validation (fail-closed)

    func testValidConfigHasNoValidationError() {
        XCTAssertNil(makeConfig().validationError)
    }

    func testMissingAPIKeyFailsValidation() {
        var config = makeConfig()
        config.apiKey = "   "
        XCTAssertNotNil(config.validationError)
    }

    func testBaseURLWithoutHostFailsValidation() {
        var config = makeConfig()
        config.apiBaseURL = URL(string: "file:///tmp/nope")!
        XCTAssertNotNil(config.validationError)
    }

    func testBlankReportsPathFailsValidation() {
        var config = makeConfig()
        config.reportsPath = " "
        XCTAssertNotNil(config.validationError)
    }

    func testBlankConfigPathFailsValidation() {
        var config = makeConfig()
        config.configPath = ""
        XCTAssertNotNil(config.validationError)
    }

    // MARK: - Capture exclusion

    func testCaptureExclusionFragmentsAreWholeURLs() {
        let fragments = makeConfig().captureExclusionFragments
        XCTAssertTrue(fragments.contains("https://collie.example.com/api/v1/collie/reports"))
        XCTAssertTrue(fragments.contains("https://collie.example.com/api/v1/collie/config"))
    }

    /// The regression this property was rewritten for.
    ///
    /// Capture tools match the exclude list as substrings. While this returned the host and
    /// the path separately, a short `reportsPath` matched the host app's own traffic: the
    /// entry `/post` swallowed every `GET /posts` the app made, so reports arrived with an
    /// empty log stream and nothing said why.
    func testAShortReportsPathDoesNotExcludeTheHostAppsOwnTraffic() {
        var config = makeConfig()
        config.reportsPath = "/post"

        let fragments = config.captureExclusionFragments
        let hostAppRequest = "https://api.example.com/v1/posts"

        XCTAssertFalse(
            fragments.contains { hostAppRequest.contains($0) },
            "An unrelated request must not match any exclusion entry"
        )
        // Collie's own upload still matches, which is the whole point of the list.
        XCTAssertTrue(fragments.contains { config.reportsURL.absoluteString.contains($0) })
    }

    // MARK: - Bounds

    func testScreenshotQualityClamped() {
        let config = CollieConfiguration(
            apiBaseURL: URL(string: "https://x.example.com")!,
            screenshotJPEGQuality: 5
        )
        XCTAssertLessThanOrEqual(config.screenshotJPEGQuality, 1)
        XCTAssertGreaterThanOrEqual(config.screenshotJPEGQuality, 0.1)
    }

    func testNegativeRetrySettingsClamped() {
        let config = CollieConfiguration(
            apiBaseURL: URL(string: "https://x.example.com")!,
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
