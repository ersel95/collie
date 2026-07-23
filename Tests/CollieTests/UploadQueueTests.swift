import XCTest
@testable import Collie

/// The queue's two-step (create → attach) behavior: duplicate prevention,
/// permanent/transient error distinction, resuming from disk.
final class UploadQueueTests: XCTestCase {

    // MARK: - Mock transport

    /// Step-by-step programmable Jira transport. Call counters exist for duplicate checks.
    private final class MockTransport: JiraTransport, @unchecked Sendable {
        private let lock = NSLock()

        var createResults: [JiraOperationResult<String>] = []
        var attachResults: [JiraOperationResult<Void>] = []
        private(set) var createCallCount = 0
        private(set) var attachCallCount = 0
        private(set) var attachedFilenames: [String] = []

        func createIssue(body: Data) async -> JiraOperationResult<String> {
            lock.lock(); defer { lock.unlock() }
            createCallCount += 1
            return createResults.isEmpty ? .success("PROJ-1") : createResults.removeFirst()
        }

        func attach(issueKey: String, data: Data, filename: String, mimeType: String) async -> JiraOperationResult<Void> {
            lock.lock(); defer { lock.unlock() }
            attachCallCount += 1
            attachedFilenames.append(filename)
            return attachResults.isEmpty ? .success(()) : attachResults.removeFirst()
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
            jiraBaseURL: URL(string: "https://jira.example.com")!,
            pat: "secret",
            projectKey: "PROJ",
            parentIssueKey: "PROJ-123",
            assigneeUsername: "jira.user",
            maxRetryCount: 5,
            baseRetryDelay: baseRetryDelay
        )
        return UploadQueue(configuration: config, transport: transport, directoryOverride: tempDir)
    }

    private let issueBody = #"{"fields":{}}"#.data(using: .utf8)!
    private let screenshot = Data([0xFF, 0xD8])
    private let logs = #"[]"#.data(using: .utf8)!

    private func networkFiles(_ count: Int) -> [CollieAttachment] {
        (1...count).map {
            CollieAttachment(
                filename: String(format: "net-%03d-GET-200-ok.txt", $0),
                mimeType: "text/plain",
                data: "request \($0)".data(using: .utf8)!
            )
        }
    }

    // MARK: - Happy path

    func testSubmitSendsIssueAndBothAttachments() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)

        XCTAssertEqual(outcome, .sent(issueKey: "PROJ-1"))
        XCTAssertEqual(transport.createCallCount, 1)
        XCTAssertEqual(transport.attachCallCount, 2)
        XCTAssertTrue(transport.attachedFilenames.contains("screenshot.jpg"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testSubmitWithoutAttachmentsOnlyCreates() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: nil, logs: nil)

        XCTAssertEqual(outcome, .sent(issueKey: "PROJ-1"))
        XCTAssertEqual(transport.attachCallCount, 0)
    }

    // MARK: - Per-request network attachments

    func testSubmitUploadsEveryNetworkFile() async {
        let transport = MockTransport()
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(
            issueBody: issueBody, screenshot: screenshot, logs: logs,
            networkFiles: networkFiles(3)
        )

        XCTAssertEqual(outcome, .sent(issueKey: "PROJ-1"))
        XCTAssertEqual(transport.attachCallCount, 5)   // screenshot + logs + 3 requests
        XCTAssertEqual(
            transport.attachedFilenames.suffix(3),
            ["net-001-GET-200-ok.txt", "net-002-GET-200-ok.txt", "net-003-GET-200-ok.txt"]
        )
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// A transient failure part-way through the network files must only re-upload the
    /// ones that are still missing (and never re-create the issue).
    func testRetryResumesFromTheFailedNetworkFile() async {
        let transport = MockTransport()
        // screenshot ✓, logs ✓, net-001 ✓, net-002 ✗ (transient)
        transport.attachResults = [.success(()), .success(()), .success(()), .transientFailure("dropped")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(
            issueBody: issueBody, screenshot: screenshot, logs: logs,
            networkFiles: networkFiles(3)
        )
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(transport.attachedFilenames.suffix(2), ["net-001-GET-200-ok.txt", "net-002-GET-200-ok.txt"])

        await queue.drain()

        XCTAssertEqual(transport.createCallCount, 1, "the issue must not be created twice")
        // Only net-002 and net-003 are retried.
        XCTAssertEqual(transport.attachedFilenames.suffix(2), ["net-002-GET-200-ok.txt", "net-003-GET-200-ok.txt"])
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testNetworkAttachmentPermanentFailureIsSkipped() async {
        let transport = MockTransport()
        transport.attachResults = [.success(()), .success(()), .permanentFailure("HTTP 413")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(
            issueBody: issueBody, screenshot: screenshot, logs: logs,
            networkFiles: networkFiles(2)
        )

        XCTAssertEqual(outcome, .sent(issueKey: "PROJ-1"))
        XCTAssertEqual(transport.attachCallCount, 4)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Permanent failure

    func testCreatePermanentFailureRejectsAndDoesNotQueue() async {
        let transport = MockTransport()
        transport.createResults = [.permanentFailure("HTTP 400")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)

        XCTAssertEqual(outcome, .rejected("HTTP 400"))
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(transport.attachCallCount, 0)
    }

    func testAttachmentPermanentFailureIsSkippedButIssueIsSent() async {
        let transport = MockTransport()
        transport.attachResults = [.permanentFailure("HTTP 413")]   // screenshot rejected
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)

        // The screenshot was skipped but the issue + log attachment went through; the
        // report was not lost.
        XCTAssertEqual(outcome, .sent(issueKey: "PROJ-1"))
        XCTAssertEqual(transport.attachCallCount, 2)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Transient failure → queue

    func testCreateTransientFailureQueuesReport() async {
        let transport = MockTransport()
        transport.createResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)

        XCTAssertEqual(outcome, .queued)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testDrainCompletesQueuedReport() async {
        let transport = MockTransport()
        transport.createResults = [.transientFailure("no VPN")]
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)
        await queue.drain()   // create now succeeds (mock default is .success)

        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(transport.createCallCount, 2)
        XCTAssertEqual(transport.attachCallCount, 2)
    }

    /// CRITICAL: create succeeded + attachment failed transiently → the retry must NOT
    /// create the issue again.
    func testRetryAfterPartialFailureDoesNotCreateDuplicateIssue() async {
        let transport = MockTransport()
        transport.attachResults = [.transientFailure("connection dropped")]   // screenshot step fails
        let queue = makeQueue(transport: transport)

        let outcome = await queue.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(transport.createCallCount, 1)

        await queue.drain()

        // The issue create was NOT called again; the remaining attachments completed.
        XCTAssertEqual(transport.createCallCount, 1)
        XCTAssertEqual(transport.attachCallCount, 3)   // 1 failed + 2 on retry (screenshot+logs)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// Resume from disk: even when the queue is recreated (process-restart simulation),
    /// `issueKey` is read from the envelope and the create step is skipped.
    func testQueueResumesFromDiskAfterRestartWithoutDuplicateCreate() async {
        let transport1 = MockTransport()
        transport1.attachResults = [.transientFailure("dropped")]
        let queue1 = makeQueue(transport: transport1)
        _ = await queue1.submit(issueBody: issueBody, screenshot: screenshot, logs: logs)
        XCTAssertEqual(transport1.createCallCount, 1)

        // "Restart": a new queue + new transport over the same directory.
        let transport2 = MockTransport()
        let queue2 = makeQueue(transport: transport2)
        await queue2.drain()

        XCTAssertEqual(transport2.createCallCount, 0, "issueKey is on disk — create must not repeat")
        XCTAssertEqual(transport2.attachCallCount, 2)
        let pending = await queue2.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Backoff / retry limit

    func testReportDroppedAfterMaxRetries() async {
        let transport = MockTransport()
        // Initial submit + repeated drain attempts, all failing transiently.
        transport.createResults = Array(repeating: .transientFailure("down"), count: 10)
        let queue = makeQueue(transport: transport)

        _ = await queue.submit(issueBody: issueBody, screenshot: nil, logs: nil)
        for _ in 0..<10 {
            await queue.drain()
        }

        // maxRetryCount(5) exceeded → dropped. (baseRetryDelay=0 → nextAttemptAt always
        // in the past.)
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }
}
