import Foundation

/// The bug reporter's working engine: gathers report data, produces the Jira issue
/// content, and hands it to the two-step queue (create + attachments).
///
/// The UI (screenshot detector / banner / sheet) uses this service via
/// `Collie.bugReportService`. The service only exists after a valid
/// `Collie.configure(enabled: true, ...)`; otherwise it's `nil` → the UI installs nothing.
public final class BugReportService: @unchecked Sendable {

    let configuration: CollieConfiguration
    private let queue: UploadQueue

    init(configuration: CollieConfiguration, transport: (any JiraTransport)? = nil) {
        self.configuration = configuration
        let effectiveTransport = transport ?? JiraClient(configuration: configuration)
        self.queue = UploadQueue(configuration: configuration, transport: effectiveTransport)
    }

    // MARK: - Lifecycle (called from configure)

    /// Attempts to drain the pending queue (once at startup).
    func bootstrap() {
        Task { await queue.drain() }
    }

    /// Attempts to send pending offline reports (e.g. when the app returns to the
    /// foreground or a VPN connection is established).
    public func flushPendingUploads() {
        Task { await queue.drain() }
    }

    // MARK: - Capture gate

    /// Is capture currently active? The old architecture's server-side kill switch
    /// (`GET /config`) went away with the backend; in v1 the only gate is the local
    /// opt-in (service exists → on). If a remote kill switch is ever added, this is
    /// the single place to change.
    public var isCaptureEnabled: Bool { true }

    /// Screenshot byte limit.
    public var maxScreenshotBytes: Int { configuration.maxScreenshotBytes }

    /// JPEG compression quality.
    public var screenshotJPEGQuality: Double { configuration.screenshotJPEGQuality }

    // MARK: - Identity (does the sheet ask for a name on first use?)

    /// Has a tester name been stored before?
    public var hasStoredTesterName: Bool { CollieDeviceIdentity.hasStoredName }

    /// Stores the one-time tester name.
    public func storeTesterName(_ name: String) { CollieDeviceIdentity.storeName(name) }

    // MARK: - Submission

    /// Sends the report to Jira: a subtask is created under the configured parent, and
    /// the screenshot + log JSON are uploaded as attachments.
    ///
    /// - Parameters:
    ///   - whatHappened: The "What happened?" field.
    ///   - whatExpected: The "What was expected?" field.
    ///   - testerName: Name entered on the first submission (stored afterwards); when
    ///     nil, the stored name is used.
    ///   - screenshotJPEG: The screenshot pre-compressed to JPEG (binary).
    ///   - identity: Device identity (collected by the UI on the MainActor).
    @discardableResult
    public func sendReport(
        whatHappened: String,
        whatExpected: String,
        testerName: String?,
        screenshotJPEG: Data?,
        identity: CollieDeviceIdentity,
        telemetry: CollieTelemetry? = nil
    ) async -> CollieSubmitOutcome {
        if let testerName, !testerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CollieDeviceIdentity.storeName(testerName)
        }
        let effectiveName = testerName ?? identity.name ?? CollieDeviceIdentity.storedName()

        // The host's log snapshot — ALL categories, raw entries.
        let entries = configuration.logSnapshotProvider?() ?? []
        let sessionID = configuration.sessionIDProvider?() ?? ""

        let context = JiraIssueBuilder.ReportContext(
            whatHappened: whatHappened,
            whatExpected: whatExpected,
            testerName: effectiveName,
            identity: identity,
            telemetry: telemetry,
            sessionID: sessionID,
            capturedAt: Date(),
            entries: entries
        )

        guard let issueBody = try? JiraIssueBuilder.makeCreateBody(
            configuration: configuration,
            context: context
        ) else {
            return .rejected("Could not build the issue body")
        }

        let logsJSON = entries.isEmpty ? nil : try? Self.encodeLogs(entries)
        return await queue.submit(issueBody: issueBody, screenshot: screenshotJPEG, logs: logsJSON)
    }

    /// Encodes log entries for the attachment file (`collie-logs-*.json`).
    static func encodeLogs(_ entries: [CollieLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    func diag(_ message: String) {
        configuration.diagnostics?("[Collie] \(message)")
    }
}
