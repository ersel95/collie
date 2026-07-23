import Foundation

/// Outcome of a report submission (the UI shows a toast/error based on this).
public enum CollieSubmitOutcome: Sendable, Equatable {
    /// The issue was created (with its attachments, or with attachments skipped on a
    /// permanent error). Key: `PROJ-123`.
    case sent(issueKey: String)
    /// Transient failure — the report was queued to disk and will be retried
    /// automatically once a connection is available.
    case queued
    /// Permanent failure (auth/config) — the report could not be sent and was not queued.
    case rejected(String)
}

/// Persistent (offline) upload queue on disk. Failed reports are stored under
/// `Caches/Collie/uploads/` and retried with exponential backoff. Pending reports are
/// read back from disk and sending continues even after a process restart.
///
/// **Two-step job**: one report = 1× issue create + N× attachments. If the create
/// succeeds but an attachment is left unfinished, `issueKey` is written into the
/// envelope; a retry **does not create a new issue** — it resumes from the remaining
/// step (duplicate prevention). The same holds per network file: each one records its
/// own `done` flag, so a retry only uploads what is left.
///
/// Concurrency: runs on a single serial `actor` → no races.
actor UploadQueue {

    /// A pending report envelope stored on disk.
    private struct Envelope: Codable {
        let id: String
        var attempt: Int
        let createdAt: Date
        var nextAttemptAt: Date
        /// Key of the created issue once the create step completed (duplicate prevention).
        var issueKey: String?
        let hasScreenshot: Bool
        let hasLogs: Bool
        var screenshotDone: Bool
        var logsDone: Bool
        /// Per-request network attachments, in upload order. Optional so envelopes
        /// written by an older Collie version still decode.
        var networkFiles: [NetworkFileState]?
    }

    /// One per-request network attachment's progress inside an envelope.
    private struct NetworkFileState: Codable {
        let filename: String
        let mimeType: String
        var done: Bool
    }

    private enum StepOutcome {
        case done(issueKey: String)
        case createRejected(String)
        case transient(String)
    }

    private let configuration: CollieConfiguration
    private let transport: any JiraTransport
    private let directory: URL
    private let fileManager = FileManager.default

    /// Protection for files written to disk: content stays encrypted while the device is
    /// locked (and before first unlock) + atomic writes. Mandatory since the files carry
    /// sensitive logs/screenshots.
    private static let writeOptions: Data.WritingOptions = {
        #if canImport(UIKit) || os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        // No FileProtection on macOS; atomic writes are kept (tests also run on macOS).
        return [.atomic]
        #endif
    }()

    /// Maximum age of a report waiting in the queue. Older reports are deleted without
    /// being sent (so stale sensitive data does not sit on disk indefinitely).
    private static let maxEnvelopeAge: TimeInterval = 48 * 60 * 60   // 48 hours

    private var isDraining = false

    init(
        configuration: CollieConfiguration,
        transport: any JiraTransport,
        directoryOverride: URL? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        if let directoryOverride {
            self.directory = directoryOverride
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = caches.appendingPathComponent("Collie/uploads", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func diag(_ message: String) {
        configuration.diagnostics?("[Collie] \(message)")
    }

    // MARK: - Public

    /// Tries to send a report immediately.
    /// - Transient failure → remaining steps are queued to disk, `.queued`.
    /// - Permanent failure on create → `.rejected` (not written to disk — the same error
    ///   would just repeat).
    /// - A permanent attachment failure does not drop the report; the attachment is
    ///   skipped and the issue still counts as `.sent`.
    func submit(
        issueBody: Data,
        screenshot: Data?,
        logs: Data?,
        networkFiles: [CollieAttachment] = []
    ) async -> CollieSubmitOutcome {
        var envelope = Envelope(
            id: UUID().uuidString,
            attempt: 0,
            createdAt: Date(),
            nextAttemptAt: Date(),
            issueKey: nil,
            hasScreenshot: screenshot?.isEmpty == false,
            hasLogs: logs?.isEmpty == false,
            screenshotDone: false,
            logsDone: false,
            networkFiles: networkFiles.map {
                NetworkFileState(filename: $0.filename, mimeType: $0.mimeType, done: false)
            }
        )
        let outcome = await perform(
            envelope: &envelope,
            issueBody: issueBody,
            screenshot: screenshot,
            logs: logs,
            networkFiles: networkFiles
        )
        switch outcome {
        case .done(let issueKey):
            return .sent(issueKey: issueKey)
        case .createRejected(let reason):
            diag("Report rejected by Jira with a permanent error: \(reason)")
            return .rejected(reason)
        case .transient(let reason):
            diag("Report could not be sent, queued: \(reason)")
            envelope.nextAttemptAt = Date().addingTimeInterval(configuration.baseRetryDelay)
            persist(
                envelope: envelope,
                issueBody: issueBody,
                screenshot: screenshot,
                logs: logs,
                networkFiles: networkFiles
            )
            return .queued
        }
    }

    /// Tries to send all pending reports on disk (the ones whose time has come), in order.
    /// Idempotent: returns early if already running.
    func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        let envelopes = loadEnvelopes().sorted { $0.createdAt < $1.createdAt }
        let now = Date()
        for var envelope in envelopes {
            // TTL: reports past the maximum age are deleted unsent (stale sensitive data).
            if now.timeIntervalSince(envelope.createdAt) > Self.maxEnvelopeAge {
                diag("Report expired (TTL), deleted without sending.")
                remove(envelope)
                continue
            }
            guard envelope.nextAttemptAt <= now else { continue }
            guard let issueBody = readFile(envelope.id, kind: .issue) else {
                remove(envelope); continue
            }
            let screenshot = envelope.hasScreenshot ? readFile(envelope.id, kind: .screenshot) : nil
            let logs = envelope.hasLogs ? readFile(envelope.id, kind: .logs) : nil
            let networkFiles = readNetworkFiles(envelope)

            let outcome = await perform(
                envelope: &envelope,
                issueBody: issueBody,
                screenshot: screenshot,
                logs: logs,
                networkFiles: networkFiles
            )
            switch outcome {
            case .done(let issueKey):
                diag("Queued report sent: \(issueKey)")
                remove(envelope)
            case .createRejected(let reason):
                diag("Queued report dropped with a permanent error: \(reason)")
                remove(envelope)
            case .transient:
                envelope.attempt += 1
                if envelope.attempt > configuration.maxRetryCount {
                    diag("Report exceeded the retry limit, dropped.")
                    remove(envelope)
                } else {
                    let delay = configuration.baseRetryDelay * pow(2, Double(envelope.attempt))
                    envelope.nextAttemptAt = Date().addingTimeInterval(delay)
                    writeEnvelope(envelope)
                }
            }
        }
    }

    /// Number of (non-expired) reports waiting in the queue (tests/diagnostics).
    /// Expired envelopes are cleaned off disk during this call.
    func pendingCount() -> Int {
        let now = Date()
        var live = 0
        for envelope in loadEnvelopes() {
            if now.timeIntervalSince(envelope.createdAt) > Self.maxEnvelopeAge {
                remove(envelope)
            } else {
                live += 1
            }
        }
        return live
    }

    // MARK: - Step machine (create → screenshot → logs)

    /// Executes the envelope's remaining steps in order and updates its progress state.
    /// - Permanent failure on an attachment: the attachment is skipped (`…Done = true`);
    ///   the issue is not dropped.
    private func perform(
        envelope: inout Envelope,
        issueBody: Data,
        screenshot: Data?,
        logs: Data?,
        networkFiles: [CollieAttachment]
    ) async -> StepOutcome {
        // Step 1 — issue create (only if not already done; duplicate prevention).
        if envelope.issueKey == nil {
            switch await transport.createIssue(body: issueBody) {
            case .success(let key):
                envelope.issueKey = key
            case .permanentFailure(let reason):
                return .createRejected(reason)
            case .transientFailure(let reason):
                return .transient(reason)
            }
        }
        guard let issueKey = envelope.issueKey else {
            return .createRejected("Missing issueKey (unexpected state)")
        }

        // Step 2 — screenshot attachment.
        if envelope.hasScreenshot, !envelope.screenshotDone, let screenshot {
            switch await transport.attach(
                issueKey: issueKey, data: screenshot,
                filename: "screenshot.jpg", mimeType: "image/jpeg"
            ) {
            case .success:
                envelope.screenshotDone = true
            case .permanentFailure(let reason):
                diag("Screenshot attachment skipped with a permanent error (\(issueKey)): \(reason)")
                envelope.screenshotDone = true
            case .transientFailure(let reason):
                return .transient(reason)
            }
        }

        // Step 3 — log JSON attachment.
        if envelope.hasLogs, !envelope.logsDone, let logs {
            switch await transport.attach(
                issueKey: issueKey, data: logs,
                filename: "collie-logs-\(envelope.id).json", mimeType: "application/json"
            ) {
            case .success:
                envelope.logsDone = true
            case .permanentFailure(let reason):
                diag("Log attachment skipped with a permanent error (\(issueKey)): \(reason)")
                envelope.logsDone = true
            case .transientFailure(let reason):
                return .transient(reason)
            }
        }

        // Step 4 — one attachment per network request. Progress is tracked per file, so
        // a transient failure only re-uploads what is still missing.
        if var states = envelope.networkFiles, !states.isEmpty {
            for index in states.indices where !states[index].done {
                guard index < networkFiles.count, !networkFiles[index].data.isEmpty else {
                    // Payload missing on disk — skip rather than block the report.
                    states[index].done = true
                    continue
                }
                switch await transport.attach(
                    issueKey: issueKey, data: networkFiles[index].data,
                    filename: states[index].filename, mimeType: states[index].mimeType
                ) {
                case .success:
                    states[index].done = true
                case .permanentFailure(let reason):
                    diag("Network attachment skipped with a permanent error (\(issueKey), \(states[index].filename)): \(reason)")
                    states[index].done = true
                case .transientFailure(let reason):
                    envelope.networkFiles = states
                    return .transient(reason)
                }
            }
            envelope.networkFiles = states
        }

        return .done(issueKey: issueKey)
    }

    // MARK: - Disk

    private enum FileKind: String {
        case issue = "issue"
        case screenshot = "screenshot"
        case logs = "logs"
    }

    private func fileURL(_ id: String, kind: FileKind) -> URL {
        directory.appendingPathComponent("\(id).\(kind.rawValue)")
    }

    /// Per-request network payloads are stored one file per request, indexed by their
    /// position in the envelope's `networkFiles`.
    private func networkFileURL(_ id: String, index: Int) -> URL {
        directory.appendingPathComponent("\(id).net-\(index)")
    }

    private func envelopeURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func persist(
        envelope: Envelope,
        issueBody: Data,
        screenshot: Data?,
        logs: Data?,
        networkFiles: [CollieAttachment]
    ) {
        do {
            try issueBody.write(to: fileURL(envelope.id, kind: .issue), options: Self.writeOptions)
            if envelope.hasScreenshot, let screenshot {
                try screenshot.write(to: fileURL(envelope.id, kind: .screenshot), options: Self.writeOptions)
            }
            if envelope.hasLogs, let logs {
                try logs.write(to: fileURL(envelope.id, kind: .logs), options: Self.writeOptions)
            }
            for (index, file) in networkFiles.enumerated() {
                try file.data.write(to: networkFileURL(envelope.id, index: index), options: Self.writeOptions)
            }
        } catch {
            remove(envelope)
            return
        }
        writeEnvelope(envelope)
    }

    private func writeEnvelope(_ envelope: Envelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: envelopeURL(envelope.id), options: Self.writeOptions)
    }

    private func readFile(_ id: String, kind: FileKind) -> Data? {
        try? Data(contentsOf: fileURL(id, kind: kind))
    }

    /// Reads the envelope's network payloads back in envelope order. A payload that is
    /// gone from disk becomes empty data; `perform` skips those instead of blocking the
    /// report.
    private func readNetworkFiles(_ envelope: Envelope) -> [CollieAttachment] {
        (envelope.networkFiles ?? []).enumerated().map { index, state in
            CollieAttachment(
                filename: state.filename,
                mimeType: state.mimeType,
                data: (try? Data(contentsOf: networkFileURL(envelope.id, index: index))) ?? Data()
            )
        }
    }

    private func remove(_ envelope: Envelope) {
        try? fileManager.removeItem(at: envelopeURL(envelope.id))
        for kind in [FileKind.issue, .screenshot, .logs] {
            try? fileManager.removeItem(at: fileURL(envelope.id, kind: kind))
        }
        for index in (envelope.networkFiles ?? []).indices {
            try? fileManager.removeItem(at: networkFileURL(envelope.id, index: index))
        }
    }

    private func loadEnvelopes() -> [Envelope] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Envelope? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Envelope.self, from: data)
            }
    }
}
