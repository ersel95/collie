import Foundation

/// The bug reporter's working engine: gathers report data, produces the upload envelope,
/// and hands it to the offline-capable queue.
///
/// The UI (screenshot detector / banner / sheet) uses this service via
/// `Collie.bugReportService`. The service only exists after a valid
/// `Collie.configure(enabled: true, ...)`; otherwise it's `nil` → the UI installs nothing.
public final class BugReportService: @unchecked Sendable {

    let configuration: CollieConfiguration
    private let transport: any ReportTransport
    private let queue: UploadQueue

    /// Server-side switches. Guarded by `stateLock`.
    private let stateLock = NSLock()
    private var remoteCaptureEnabled = true
    private var remoteMaxScreenshotBytes: Int?

    /// When Collie was configured — written into every report as a synthetic
    /// "Session started" log entry.
    let initializedAt = Date()

    init(configuration: CollieConfiguration, transport: (any ReportTransport)? = nil) {
        self.configuration = configuration
        let effectiveTransport = transport ?? IngestionClient(configuration: configuration)
        self.transport = effectiveTransport
        self.queue = UploadQueue(configuration: configuration, transport: effectiveTransport)
    }

    // MARK: - Lifecycle (called from configure)

    /// Fetches the server-side kill switch and drains the pending queue (once at startup).
    func bootstrap() {
        Task {
            await refreshRemoteConfig()
            await queue.drain()
        }
    }

    /// Attempts to send pending offline reports (e.g. when the app returns to the
    /// foreground or a VPN connection is established).
    public func flushPendingUploads() {
        Task { await queue.drain() }
    }

    // MARK: - Capture gate

    /// Refreshes the server-side switches.
    ///
    /// **Fails open on an unreachable backend**: when the config call fails (no VPN,
    /// offline) the previous value is kept, so a tester can still capture a report and
    /// have it queued. Only an explicit `captureEnabled: false` from the server turns
    /// capture off — that is also what an invalid api-key yields (the backend answers
    /// fail-closed).
    private func refreshRemoteConfig() async {
        guard let config = await transport.fetchRemoteConfig() else {
            diag("Remote config unreachable — keeping the current capture state.")
            return
        }
        apply(config)
        if !config.captureEnabled {
            diag("Capture is disabled server-side for this app (kill switch).")
        }
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func apply(_ config: CollieRemoteConfig) {
        stateLock.lock(); defer { stateLock.unlock() }
        remoteCaptureEnabled = config.captureEnabled
        remoteMaxScreenshotBytes = config.maxScreenshotBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Is capture currently active? Two gates: the local build-time opt-in (this service
    /// only exists when that passed) **and** the server-side kill switch.
    public var isCaptureEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return remoteCaptureEnabled
    }

    /// Screenshot byte limit — the stricter of the local config and the server's value.
    public var maxScreenshotBytes: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let remote = remoteMaxScreenshotBytes else { return configuration.maxScreenshotBytes }
        return min(configuration.maxScreenshotBytes, remote)
    }

    /// JPEG compression quality.
    public var screenshotJPEGQuality: Double { configuration.screenshotJPEGQuality }

    // MARK: - Identity (does the sheet ask for a name on first use?)

    /// Has a tester name been stored before?
    public var hasStoredTesterName: Bool { CollieDeviceIdentity.hasStoredName }

    /// Stores the one-time tester name.
    public func storeTesterName(_ name: String) { CollieDeviceIdentity.storeName(name) }

    // MARK: - Submission

    /// Sends the report to the Collie backend: one multipart upload carrying the JSON
    /// envelope (app/device/report meta + **all** log entries + telemetry) and the
    /// screenshot. Triage and the eventual Jira issue happen in the analyst panel.
    ///
    /// - Parameters:
    ///   - whatHappened: The "What happened?" field.
    ///   - testerName: Name entered on the first submission (stored afterwards); when
    ///     nil, the stored name is used.
    ///   - screenshotJPEG: The screenshot pre-compressed to JPEG (binary).
    ///   - identity: Device identity (collected by the UI on the MainActor).
    @discardableResult
    public func sendReport(
        whatHappened: String,
        testerName: String?,
        screenshotJPEG: Data?,
        identity: CollieDeviceIdentity,
        telemetry: CollieTelemetry? = nil
    ) async -> CollieSubmitOutcome {
        if let testerName, !testerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CollieDeviceIdentity.storeName(testerName)
        }
        let effectiveName = testerName ?? identity.name ?? CollieDeviceIdentity.storedName()

        // The host's log snapshot — ALL categories, raw entries — plus Collie's own
        // init marker, inserted at its chronological position so the timeline shows
        // when Collie started.
        var entries = configuration.logSnapshotProvider?() ?? []
        let initEntry = CollieLogEntry(
            date: initializedAt,
            level: "info",
            category: "collie",
            message: "Session started — \(ReportEnvelopeBuilder.dateTimeString(initializedAt))"
        )
        let insertIndex = entries.firstIndex { $0.date > initializedAt } ?? entries.endIndex
        entries.insert(initEntry, at: insertIndex)
        let sessionID = configuration.sessionIDProvider?() ?? ""

        let context = ReportEnvelopeBuilder.ReportContext(
            whatHappened: whatHappened,
            testerName: effectiveName,
            identity: identity,
            telemetry: telemetry,
            sessionID: sessionID,
            capturedAt: Date(),
            collieInitializedAt: initializedAt,
            entries: entries
        )

        guard let reportBody = try? ReportEnvelopeBuilder.makeBody(
            configuration: configuration,
            context: context
        ) else {
            return .rejected("Could not build the report envelope")
        }

        return await queue.submit(reportBody: reportBody, screenshot: screenshotJPEG)
    }

    func diag(_ message: String) {
        configuration.diagnostics?("[Collie] \(message)")
    }
}
