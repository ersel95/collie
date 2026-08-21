import Foundation

/// Outcome of a report submission (the UI shows a toast/error based on this).
public enum CollieSubmitOutcome: Sendable, Equatable {
    /// The backend accepted the report. Carries the server's report id.
    case sent(reportID: String)
    /// Transient failure — the report was queued to disk and will be retried
    /// automatically once a connection is available.
    case queued
    /// Permanent failure (auth/validation) — the report could not be sent and was not
    /// queued.
    case rejected(String)
}

/// Persistent (offline) upload queue on disk. Failed reports are stored under
/// `Caches/Collie/uploads/` and retried with exponential backoff. Pending reports are
/// read back from disk and sending continues even after a process restart.
///
/// **One report = one request.** The envelope id doubles as the idempotency key sent to
/// the backend, so a retry after a lost response resolves to the same report instead of
/// creating a duplicate (`UploadQueueTests` locks this in).
///
/// Concurrency: runs on a single serial `actor` → no races.
actor UploadQueue {

    /// A pending report envelope stored on disk.
    ///
    /// Both screenshot fields are optional and both are written, because the file on disk
    /// outlives the build that wrote it: a report queued while the tester was off VPN is
    /// read back by whatever version of the app is installed when the connection returns.
    private struct Envelope: Codable {
        let id: String
        var attempt: Int
        let createdAt: Date
        var nextAttemptAt: Date
        /// Written by every build. Pre-multi-screenshot ones wrote *only* this, alongside
        /// a single unsuffixed `<id>.screenshot` file.
        let hasScreenshot: Bool?
        /// How many `<id>.screenshot.<index>` files this envelope has. Absent on a file
        /// left by a build that predates multiple screenshots.
        let screenshotCount: Int?

        init(id: String, attempt: Int, createdAt: Date, nextAttemptAt: Date, screenshotCount: Int) {
            self.id = id
            self.attempt = attempt
            self.createdAt = createdAt
            self.nextAttemptAt = nextAttemptAt
            self.hasScreenshot = screenshotCount > 0
            self.screenshotCount = screenshotCount
        }

        /// How many screenshot files to expect. An older envelope's `true` means one.
        var screenshots: Int {
            if let screenshotCount { return screenshotCount }
            return hasScreenshot == true ? 1 : 0
        }

        /// Were the files written under the old, unsuffixed name? Only the absence of
        /// `screenshotCount` says so — the flag alone cannot tell the two shapes apart.
        var usesLegacyScreenshotName: Bool { screenshotCount == nil }
    }

    private enum StepOutcome {
        case done(reportID: String)
        case rejected(String)
        case transient(String)
    }

    private let configuration: CollieConfiguration
    private let transport: any ReportTransport
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
        transport: any ReportTransport,
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
    /// - Transient failure → the report is queued to disk, `.queued`.
    /// - Permanent failure → `.rejected` (not written to disk — the same error would just
    ///   repeat).
    func submit(reportBody: Data, screenshots: [Data]) async -> CollieSubmitOutcome {
        let images = screenshots.filter { !$0.isEmpty }
        var envelope = Envelope(
            id: UUID().uuidString,
            attempt: 0,
            createdAt: Date(),
            nextAttemptAt: Date(),
            screenshotCount: images.count
        )
        let outcome = await perform(
            envelope: &envelope,
            reportBody: reportBody,
            screenshots: images
        )
        switch outcome {
        case .done(let reportID):
            return .sent(reportID: reportID)
        case .rejected(let reason):
            diag("Report rejected by the backend with a permanent error: \(reason)")
            return .rejected(reason)
        case .transient(let reason):
            diag("Report could not be sent, queued: \(reason)")
            envelope.nextAttemptAt = Date().addingTimeInterval(configuration.baseRetryDelay)
            persist(envelope: envelope, reportBody: reportBody, screenshots: images)
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
            guard let reportBody = readFile(envelope.id, kind: .report) else {
                remove(envelope); continue
            }
            let screenshots = readScreenshots(envelope)

            let outcome = await perform(
                envelope: &envelope,
                reportBody: reportBody,
                screenshots: screenshots
            )
            switch outcome {
            case .done(let reportID):
                diag("Queued report sent: \(reportID)")
                remove(envelope)
            case .rejected(let reason):
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

    // MARK: - Single step (upload)

    /// Uploads the report. The envelope id travels as the idempotency key, so a repeat of
    /// a request the server already accepted resolves to the same report.
    private func perform(
        envelope: inout Envelope,
        reportBody: Data,
        screenshots: [Data]
    ) async -> StepOutcome {
        switch await transport.upload(
            reportID: envelope.id,
            envelope: reportBody,
            screenshots: screenshots
        ) {
        case .success(let reportID):
            return .done(reportID: reportID)
        case .permanentFailure(let reason):
            return .rejected(reason)
        case .transientFailure(let reason):
            return .transient(reason)
        }
    }

    // MARK: - Disk

    private enum FileKind {
        case report
        case screenshot(index: Int)
        /// The single unsuffixed name written before a report could carry several images.
        /// Still read and still deleted — a queue file survives the app update that
        /// changed the naming.
        case legacyScreenshot

        var suffix: String {
            switch self {
            case .report: return "report"
            case .screenshot(let index): return "screenshot.\(index)"
            case .legacyScreenshot: return "screenshot"
            }
        }
    }

    private func fileURL(_ id: String, kind: FileKind) -> URL {
        directory.appendingPathComponent("\(id).\(kind.suffix)")
    }

    private func envelopeURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func persist(envelope: Envelope, reportBody: Data, screenshots: [Data]) {
        do {
            try reportBody.write(to: fileURL(envelope.id, kind: .report), options: Self.writeOptions)
            for (index, screenshot) in screenshots.enumerated() {
                try screenshot.write(
                    to: fileURL(envelope.id, kind: .screenshot(index: index)),
                    options: Self.writeOptions
                )
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

    /// Reads the queued screenshots back in the order they were persisted.
    ///
    /// A file that has gone missing is skipped rather than aborting the report: the
    /// tester's words and the log stream are worth more than one image, and the transport
    /// is told how many it actually got.
    private func readScreenshots(_ envelope: Envelope) -> [Data] {
        let count = envelope.screenshots
        guard count > 0 else { return [] }
        if envelope.usesLegacyScreenshotName {
            return [readFile(envelope.id, kind: .legacyScreenshot)].compactMap { $0 }
        }
        return (0..<count).compactMap { readFile(envelope.id, kind: .screenshot(index: $0)) }
    }

    private func remove(_ envelope: Envelope) {
        try? fileManager.removeItem(at: envelopeURL(envelope.id))
        try? fileManager.removeItem(at: fileURL(envelope.id, kind: .report))
        // The legacy name too: an envelope written by an older build points at it, and a
        // partially written newer one can have more files than its count admits. Sweeping
        // the whole slot range is a handful of `unlink` calls against a leaked screenshot
        // sitting in the cache directory until the OS reclaims it.
        try? fileManager.removeItem(at: fileURL(envelope.id, kind: .legacyScreenshot))
        let slots = max(envelope.screenshots, CollieConfiguration.maxScreenshotsLimit)
        for index in 0..<slots {
            try? fileManager.removeItem(at: fileURL(envelope.id, kind: .screenshot(index: index)))
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
