import XCTest
@testable import Collie

/// The screenshot byte limit the form compresses against.
///
/// The regression this locks in: `CollieConfiguration.maxScreenshotBytes` defaults to 4 MB
/// and `FirestoreTransport` stores at most 650 KB. The two did not know about each other, so
/// a photo picked from the library was compressed to fit the first, uploaded, and then
/// **dropped** by the transport for exceeding the second — the report arrived without it.
/// Shake captures are small enough to never show it.
final class ScreenshotLimitTests: XCTestCase {

    private struct StubTransport: ReportTransport {
        var declaredLimit: Int?

        var maxScreenshotBytes: Int? { declaredLimit }

        func upload(
            reportID: String,
            envelope: Data,
            screenshots: [Data]
        ) async -> CollieOperationResult<String> {
            .success(reportID)
        }

        func fetchRemoteConfig() async -> CollieRemoteConfig? { nil }
    }

    /// A transport with no limit of its own — an HTTPS backend enforces its own and answers
    /// 413 — must not narrow anything.
    private struct PlainTransport: ReportTransport {
        func upload(
            reportID: String,
            envelope: Data,
            screenshots: [Data]
        ) async -> CollieOperationResult<String> {
            .success(reportID)
        }

        func fetchRemoteConfig() async -> CollieRemoteConfig? { nil }
    }

    private func service(
        localLimit: Int,
        transport: any ReportTransport
    ) -> BugReportService {
        let configuration = CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "key",
            maxScreenshotBytes: localLimit
        )
        return BugReportService(configuration: configuration, transport: transport)
    }

    func testTheDestinationsLimitWinsWhenItIsStricterThanTheConfig() {
        let subject = service(
            localLimit: 4 * 1_048_576,
            transport: StubTransport(declaredLimit: 650_000)
        )

        XCTAssertEqual(subject.maxScreenshotBytes, 650_000)
    }

    /// It is the *strictest* of the three, not simply the destination's: a host that wants
    /// smaller uploads than Firestore allows must still get them.
    func testAStricterConfigStillWins() {
        let subject = service(
            localLimit: 200_000,
            transport: StubTransport(declaredLimit: 650_000)
        )

        XCTAssertEqual(subject.maxScreenshotBytes, 200_000)
    }

    func testATransportWithoutALimitChangesNothing() {
        let subject = service(localLimit: 4 * 1_048_576, transport: PlainTransport())

        XCTAssertEqual(subject.maxScreenshotBytes, 4 * 1_048_576)
    }

    /// A `nil` from a transport that has the property but nothing to declare behaves like a
    /// transport that never implemented it.
    func testAnUndeclaredLimitChangesNothing() {
        let subject = service(
            localLimit: 4 * 1_048_576,
            transport: StubTransport(declaredLimit: nil)
        )

        XCTAssertEqual(subject.maxScreenshotBytes, 4 * 1_048_576)
    }
}
