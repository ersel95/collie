import XCTest
@testable import Collie

/// The queue's single-step upload behavior: idempotency across retries,
/// permanent/transient error distinction, resuming from disk.
final class UploadQueueTests: XCTestCase {

    // MARK: - Mock transport

    /// Programmable ingestion transport. Call counters exist for duplicate checks.
    private final class MockTransport: ReportTransport, @unchecked Sendable {
        private let lock = NSLock()

        var uploadResults: [CollieOperationResult<String>] = []
        private(set) var uploadCallCount = 0
        private(set) var seenReportIDs: [String] = []
        private(set) var seenScreenshotSizes: [Int] = []

        func upload(
            reportID: String,
            envelope: Data,
            screenshot: Data?
        ) async -> CollieOperationResult<String> {
            lock.lock(); defer { lock.unlock() }
            uploadCallCount += 1
            seenReportIDs.append(reportID)
            seenScreenshotSizes.append(screenshot?.count ?? 0)
            return uploadResults.isEmpty ? .success("srv-1") : uploadResults.removeFirst()
        }

        func fetchRemoteConfig() async -> CollieRemoteConfig? {
            CollieRemoteConfig(captureEnabled: true, maxScreenshotBytes: nil)
        }
    }

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollieQueueTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func makeQueue(
        transport: MockTransport,
        baseRetryDelay: TimeInterval = 0
    ) -> UploadQueue {
        let config = CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: "https://collie.example.com")!,
            apiKey: "secret",
            maxRetryCount: 5,
            baseRetryDelay: baseRetryDelay
        )
        return UploadQueue(configuration: config, transport: transport, directoryOverride: tempDir)
    }

    private let reportBody = #"{"app":{},"device":{},"report":{},"entries":[]}"#.data(using: .utf8)!
    private let screenshot = Data([0xFF, 0xD8, 0xFF, 0xE0])

    // MARK: - Happy path

    func testSubmitUploadsReportWithScreenshot() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshot: screenshot)

        XCTAssertEqual(outcome, .sent(reportID: "srv-1"))
        XCTAssertEqual(transport.uploadCallCount, 1)
        XCTAssertEqual(transport.seenScreenshotSizes, [4])
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testSubmitWithoutScreenshotStillUploads() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshot: nil)

        XCTAssertEqual(outcome, .sent(reportID: "srv-1"))
        XCTAssertEqual(transport.seenScreenshotSizes, [0])
    }

    // MARK: - Permanent failure

    func testPermanentFailureRejectsAndDoesNotQueue() async {
        let transport = MockTransport()
        transport.uploadResults = [.permanentFailure("HTTP 400")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshot: screenshot)

        XCTAssertEqual(outcome, .rejected("HTTP 400"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testQueuedReportIsDroppedOnPermanentFailure() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN"), .permanentFailure("api-key is invalid or disabled (401)")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshot: screenshot)
        await queue.drain()

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0, "a permanently rejected report must not stay on disk")
    }

    // MARK: - Transient failure → queue

    func testTransientFailureQueuesReport() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshot: screenshot)

        XCTAssertEqual(outcome, .queued)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testDrainCompletesQueuedReport() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshot: screenshot)
        await queue.drain()   // upload now succeeds (mock default is .success)

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(transport.uploadCallCount, 2)
        XCTAssertEqual(transport.seenScreenshotSizes, [4, 4], "the screenshot must survive the round trip to disk")
    }

    /// CRITICAL: a retry must reuse the SAME idempotency key, so a response lost in
    /// transit cannot produce a second report server-side.
    func testRetryReusesTheSameIdempotencyKey() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("connection dropped")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshot: screenshot)
        await queue.drain()

        XCTAssertEqual(transport.uploadCallCount, 2)
        XCTAssertEqual(
            transport.seenReportIDs.first,
            transport.seenReportIDs.last,
            "the retry must carry the original report id"
        )
    }

    /// Two separate reports must never share an idempotency key.
    func testDistinctReportsGetDistinctIdempotencyKeys() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshot: nil)
        _ = await queue.submit(reportBody: reportBody, screenshot: nil)

        XCTAssertEqual(Set(transport.seenReportIDs).count, 2)
    }

    /// Resume from disk: even when the queue is recreated (process-restart simulation),
    /// the pending report is sent with its original id.
    func testQueueResumesFromDiskAfterRestart() async {
        let transport1 = MockTransport()
        transport1.uploadResults = [.transientFailure("dropped")]
        let queue1 = makeQueue(transport: transport1)
        _ = await queue1.submit(reportBody: reportBody, screenshot: screenshot)
        let originalID = transport1.seenReportIDs.first

        // "Restart": a new queue + new transport over the same directory.
        let transport2 = MockTransport()
        let queue2 = makeQueue(transport: transport2)
        await queue2.drain()

        XCTAssertEqual(transport2.uploadCallCount, 1)
        XCTAssertEqual(transport2.seenReportIDs.first, originalID)
        let pending = await queue2.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Backoff / retry limit

    func testReportDroppedAfterMaxRetries() async {
        let transport = MockTransport()
        // Initial submit + repeated drain attempts, all failing transiently.
        transport.uploadResults = Array(repeating: .transientFailure("down"), count: 10)
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshot: nil)
        for _ in 0..<10 {
            await queue.drain()
        }

        // maxRetryCount(5) exceeded → dropped. (baseRetryDelay=0 → nextAttemptAt always
        // in the past.)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }
}
