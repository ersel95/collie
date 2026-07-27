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
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "secret"
        )
        XCTAssertFalse(Collie.isConfigured)
        XCTAssertNil(Collie.bugReportService)
    }

    func testEnabledWithEmptyAPIKeyIsNoOp() {
        Collie.configure(
            enabled: true,
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "   "
        )
        XCTAssertFalse(Collie.isConfigured)
    }

    func testEnabledWithHostlessBaseURLIsNoOp() {
        Collie.configure(
            enabled: true,
            apiBaseURL: URL(string: "file:///tmp/collie")!,
            apiKey: "secret"
        )
        XCTAssertFalse(Collie.isConfigured)
    }

    func testValidConfigInstallsServiceAndIsIdempotent() {
        Collie.configure(
            enabled: true,
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "secret"
        )
        XCTAssertTrue(Collie.isConfigured)
        let first = Collie.bugReportService

        // Idempotent: a second configure keeps the first one.
        Collie.configure(
            enabled: true,
            apiBaseURL: URL(string: "https://other.example.com")!,
            apiKey: "other"
        )
        XCTAssertTrue(Collie.bugReportService === first)
    }
}
