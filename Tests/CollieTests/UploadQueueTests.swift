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
        /// Total screenshot bytes seen per call — one entry per upload attempt.
        private(set) var seenScreenshotSizes: [Int] = []
        /// The individual images seen on each attempt, so order and count are checkable.
        private(set) var seenScreenshots: [[Data]] = []

        func upload(
            reportID: String,
            envelope: Data,
            screenshots: [Data]
        ) async -> CollieOperationResult<String> {
            lock.lock(); defer { lock.unlock() }
            uploadCallCount += 1
            seenReportIDs.append(reportID)
            seenScreenshotSizes.append(screenshots.reduce(0) { $0 + $1.count })
            seenScreenshots.append(screenshots)
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

        let outcome = await queue.submit(reportBody: reportBody, screenshots: [screenshot])

        XCTAssertEqual(outcome, .sent(reportID: "srv-1"))
        XCTAssertEqual(transport.uploadCallCount, 1)
        XCTAssertEqual(transport.seenScreenshotSizes, [4])
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// Several images survive the trip in order — the panel numbers them by position, so
    /// a queue that reordered them would caption the wrong picture.
    func testSubmitCarriesEveryScreenshotInOrder() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)
        let images = [Data([0x01]), Data([0x02, 0x02]), Data([0x03, 0x03, 0x03])]

        let outcome = await queue.submit(reportBody: reportBody, screenshots: images)

        XCTAssertEqual(outcome, .sent(reportID: "srv-1"))
        XCTAssertEqual(transport.seenScreenshots.first, images)
    }

    /// Queued, then read back after a "restart": every image must return, in order, from
    /// its own file on disk — and nothing may be left behind once the report is sent.
    func testQueuedScreenshotsSurviveTheRoundTripToDisk() async {
        let transport1 = MockTransport()
        transport1.uploadResults = [.transientFailure("no VPN")]
        let queue1 = makeQueue(transport: transport1)
        let images = [Data([0x01]), Data([0x02, 0x02]), Data([0x03, 0x03, 0x03])]
        _ = await queue1.submit(reportBody: reportBody, screenshots: images)

        let transport2 = MockTransport()
        let queue2 = makeQueue(transport: transport2)
        await queue2.drain()

        XCTAssertEqual(transport2.seenScreenshots.first, images)
        let leftovers = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers, [], "no orphaned screenshot file may stay behind")
    }

    /// An envelope written by a build that predated multiple screenshots: `hasScreenshot`
    /// and a single unsuffixed file, no `screenshotCount`. It has to be read back after
    /// the app update, or a report queued off-VPN loses its image to the upgrade.
    func testLegacyEnvelopeOnDiskStillFindsItsScreenshot() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let now = Date().timeIntervalSinceReferenceDate
        let legacy = "{\"id\":\"\(id)\",\"attempt\":0,\"createdAt\":\(now),"
            + "\"nextAttemptAt\":\(now - 1),\"hasScreenshot\":true}"
        try Data(legacy.utf8).write(to: tempDir.appendingPathComponent("\(id).json"))
        try reportBody.write(to: tempDir.appendingPathComponent("\(id).report"))
        try screenshot.write(to: tempDir.appendingPathComponent("\(id).screenshot"))

        let transport = MockTransport()
        let queue = makeQueue(transport: transport)
        await queue.drain()

        XCTAssertEqual(transport.seenScreenshots.first, [screenshot])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers, [], "the old unsuffixed file must be cleaned up too")
    }

    /// The same legacy envelope, but the retry fails: it is written back to disk, and it must
    /// come back as legacy. Stamping a `screenshotCount` on it would point the next attempt
    /// at `<id>.screenshot.0`, a file that build never wrote — and the image would disappear
    /// on the retry rather than on the upgrade. (It was exactly this on Android.)
    func testRewritingALegacyEnvelopeDoesNotLoseItsScreenshot() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let now = Date().timeIntervalSinceReferenceDate
        let legacy = "{\"id\":\"\(id)\",\"attempt\":0,\"createdAt\":\(now),"
            + "\"nextAttemptAt\":\(now - 1),\"hasScreenshot\":true}"
        try Data(legacy.utf8).write(to: tempDir.appendingPathComponent("\(id).json"))
        try reportBody.write(to: tempDir.appendingPathComponent("\(id).report"))
        try screenshot.write(to: tempDir.appendingPathComponent("\(id).screenshot"))

        let failing = MockTransport()
        failing.uploadResults = [.transientFailure("no VPN")]
        await makeQueue(transport: failing).drain()

        let succeeding = MockTransport()
        await makeQueue(transport: succeeding).drain()

        XCTAssertEqual(succeeding.seenScreenshots.first, [screenshot])
    }

    func testSubmitWithoutScreenshotStillUploads() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshots: [])

        XCTAssertEqual(outcome, .sent(reportID: "srv-1"))
        XCTAssertEqual(transport.seenScreenshotSizes, [0])
    }

    // MARK: - Permanent failure

    func testPermanentFailureRejectsAndDoesNotQueue() async {
        let transport = MockTransport()
        transport.uploadResults = [.permanentFailure("HTTP 400")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshots: [screenshot])

        XCTAssertEqual(outcome, .rejected("HTTP 400"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testQueuedReportIsDroppedOnPermanentFailure() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN"), .permanentFailure("api-key is invalid or disabled (401)")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshots: [screenshot])
        await queue.drain()

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0, "a permanently rejected report must not stay on disk")
    }

    // MARK: - Transient failure → queue

    func testTransientFailureQueuesReport() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(reportBody: reportBody, screenshots: [screenshot])

        XCTAssertEqual(outcome, .queued)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testDrainCompletesQueuedReport() async {
        let transport = MockTransport()
        transport.uploadResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(reportBody: reportBody, screenshots: [screenshot])
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

        _ = await queue.submit(reportBody: reportBody, screenshots: [screenshot])
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

        _ = await queue.submit(reportBody: reportBody, screenshots: [])
        _ = await queue.submit(reportBody: reportBody, screenshots: [])

        XCTAssertEqual(Set(transport.seenReportIDs).count, 2)
    }

    /// Resume from disk: even when the queue is recreated (process-restart simulation),
    /// the pending report is sent with its original id.
    func testQueueResumesFromDiskAfterRestart() async {
        let transport1 = MockTransport()
        transport1.uploadResults = [.transientFailure("dropped")]
        let queue1 = makeQueue(transport: transport1)
        _ = await queue1.submit(reportBody: reportBody, screenshots: [screenshot])
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

        _ = await queue.submit(reportBody: reportBody, screenshots: [])
        for _ in 0..<10 {
            await queue.drain()
        }

        // maxRetryCount(5) exceeded → dropped. (baseRetryDelay=0 → nextAttemptAt always
        // in the past.)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }
}
