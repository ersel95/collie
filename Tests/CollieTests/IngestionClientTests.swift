import XCTest
@testable import Collie

/// HTTP status classification + multipart assembly for the ingestion transport.
final class IngestionClientTests: XCTestCase {

    private func classify(_ status: Int, body: String = "") -> CollieOperationResult<Data> {
        IngestionClient.classify(
            statusCode: status,
            responseBody: body.data(using: .utf8) ?? Data()
        )
    }

    private func isPermanent(_ result: CollieOperationResult<Data>) -> Bool {
        if case .permanentFailure = result { return true }
        return false
    }

    private func isTransient(_ result: CollieOperationResult<Data>) -> Bool {
        if case .transientFailure = result { return true }
        return false
    }

    private func isSuccess(_ result: CollieOperationResult<Data>) -> Bool {
        if case .success = result { return true }
        return false
    }

    // MARK: - Classification

    func testSuccessStatuses() {
        XCTAssertTrue(isSuccess(classify(200)))
        XCTAssertTrue(isSuccess(classify(201)))
        XCTAssertTrue(isSuccess(classify(204)))
    }

    /// A bad api-key is permanent: retrying it forever would just burn the queue.
    func testAuthFailuresArePermanent() {
        XCTAssertTrue(isPermanent(classify(401)))
        XCTAssertTrue(isPermanent(classify(403)))
        if case .permanentFailure(let reason) = classify(401) {
            XCTAssertTrue(reason.contains("api-key"))
        } else {
            XCTFail("401 must be permanent")
        }
    }

    /// Timeouts and rate limits are worth retrying.
    func testTimeoutAndRateLimitAreTransient() {
        XCTAssertTrue(isTransient(classify(408)))
        XCTAssertTrue(isTransient(classify(429)))
    }

    func testPayloadTooLargeIsPermanent() {
        guard case .permanentFailure(let reason) = classify(413) else {
            return XCTFail("413 must be permanent")
        }
        XCTAssertTrue(reason.contains("too large"))
    }

    func testOtherClientErrorsArePermanentAndCarryASnippet() {
        guard case .permanentFailure(let reason) = classify(400, body: "entries must not exceed 5000 items") else {
            return XCTFail("400 must be permanent")
        }
        XCTAssertTrue(reason.contains("entries must not exceed"))
    }

    /// The backend being down (or a proxy hiccup) must not drop the report.
    func testServerErrorsAreTransient() {
        XCTAssertTrue(isTransient(classify(500)))
        XCTAssertTrue(isTransient(classify(502)))
        XCTAssertTrue(isTransient(classify(503)))
    }

    // MARK: - Multipart body

    private func bodyString(envelope: String, screenshots: [Data]) -> String {
        let (body, _) = IngestionClient.makeMultipartBody(
            envelope: envelope.data(using: .utf8)!,
            screenshots: screenshots
        )
        return String(decoding: body, as: UTF8.self)
    }

    func testMultipartCarriesTheReportPart() {
        let text = bodyString(envelope: #"{"entries":[]}"#, screenshots: [])
        XCTAssertTrue(text.contains(#"name="report""#))
        XCTAssertTrue(text.contains(#"filename="report.json""#))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains(#"{"entries":[]}"#))
    }

    func testMultipartCarriesTheScreenshotPartWhenPresent() {
        let text = bodyString(envelope: "{}", screenshots: [Data([0xFF, 0xD8, 0xFF, 0xE0])])
        XCTAssertTrue(text.contains(#"name="screenshot""#))
        XCTAssertTrue(text.contains(#"filename="screenshot.jpg""#))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
    }

    /// The FIRST image keeps the part name every deployed backend already parses; the
    /// rest are appended under indexed names. A backend that knows nothing about the extra
    /// parts still receives the shake-time capture instead of nothing at all.
    func testFurtherScreenshotsAreNumberedAndTheFirstKeepsItsName() {
        let text = bodyString(
            envelope: "{}",
            screenshots: [Data([0x01]), Data([0x02]), Data([0x03])]
        )
        XCTAssertTrue(text.contains(#"name="screenshot""#))
        XCTAssertTrue(text.contains(#"filename="screenshot.jpg""#))
        XCTAssertTrue(text.contains(#"name="screenshot[1]""#))
        XCTAssertTrue(text.contains(#"filename="screenshot1.jpg""#))
        XCTAssertTrue(text.contains(#"name="screenshot[2]""#))
        XCTAssertTrue(text.contains(#"filename="screenshot2.jpg""#))
    }

    /// An empty image must not consume index 0 — the request would then reach the backend
    /// without the part it looks for and arrive picture-less for no reason.
    func testEmptyScreenshotsDoNotConsumeAnIndex() {
        let text = bodyString(envelope: "{}", screenshots: [Data(), Data([0x01])])
        XCTAssertTrue(text.contains(#"name="screenshot""#))
        XCTAssertFalse(text.contains(#"name="screenshot[1]""#))
    }

    func testScreenshotPartIsOmittedWhenMissingOrEmpty() {
        XCTAssertFalse(bodyString(envelope: "{}", screenshots: []).contains(#"name="screenshot""#))
        XCTAssertFalse(bodyString(envelope: "{}", screenshots: [Data()]).contains(#"name="screenshot""#))
    }

    func testBoundaryIsUniquePerBodyAndTerminated() {
        let (body1, boundary1) = IngestionClient.makeMultipartBody(envelope: Data("{}".utf8), screenshots: [])
        let (_, boundary2) = IngestionClient.makeMultipartBody(envelope: Data("{}".utf8), screenshots: [])

        XCTAssertNotEqual(boundary1, boundary2)
        let text = String(decoding: body1, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary1)\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(boundary1)--\r\n"))
    }
}
