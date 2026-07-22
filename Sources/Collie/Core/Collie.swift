import Foundation

/// Collie's public facade: screenshot → banner → form → **subtask directly in Jira**.
/// **OPT-IN, disabled by default.**
///
/// Unless `configure(...)` is called — or when it is called with `enabled: false`
/// (the default) — **no** detector / network / upload code runs at all.
///
/// ```swift
/// // Default: off. To enable (all Jira settings come from the host's xcconfig):
/// var config = CollieConfiguration(
///     enabled: true,
///     jiraBaseURL: URL(string: "<JIRA_BASE_URL>")!,
///     pat: "<PAT>",
///     projectKey: "PROJ",
///     parentIssueKey: "PROJ-123",
///     subtaskIssueType: "Sub-task",
///     assigneeUsername: "jira.user",
///     environment: "staging"
/// )
/// config.logSnapshotProvider = { Olaf.snapshot().map { ... } }   // optional
/// Collie.configure(with: config)
/// ```
public enum Collie {

    private static let box = StateBox()

    // MARK: - Configure (single entry point)

    /// Configures the bug reporter. **Default `enabled: false`** → opt-in.
    public static func configure(
        enabled: Bool = false,
        jiraBaseURL: URL,
        pat: String = "",
        projectKey: String = "",
        parentIssueKey: String = "",
        subtaskIssueType: String = "Sub-task",
        assigneeUsername: String = "",
        environment: String = "staging"
    ) {
        let config = CollieConfiguration(
            enabled: enabled,
            jiraBaseURL: jiraBaseURL,
            pat: pat,
            projectKey: projectKey,
            parentIssueKey: parentIssueKey,
            subtaskIssueType: subtaskIssueType,
            assigneeUsername: assigneeUsername,
            environment: environment
        )
        configure(with: config)
    }

    /// Configures with a full configuration object (recommended — provider closures
    /// can be attached as well).
    ///
    /// DEFENSE LAYERS (against accidental activation in release builds):
    ///  1. Build-time opt-in (`enabled`): defaults to `false`. Until this gate passes,
    ///     no network/detector/upload code runs (early return below).
    ///  2. Fail-closed validation: if any required Jira field (pat, projectKey,
    ///     parentIssueKey, subtaskIssueType, assigneeUsername) is blank, nothing is installed.
    /// The host must never pass a hard-coded `enabled: true` in release builds; the value
    /// must come from xcconfig/secrets (non-prod only).
    ///
    /// Idempotent; if called again, the first configuration is kept.
    public static func configure(with configuration: CollieConfiguration) {
        // Gate 1: local opt-in (build-time defense). If off, do nothing.
        guard configuration.enabled else { return }

        // Gate 2: required Jira fields — fail-closed.
        if let error = configuration.validationError {
            configuration.diagnostics?("[Collie] configure: \(error) — bug reporter not started.")
            return
        }

        // Idempotent: keep the first installation.
        guard box.service == nil else { return }

        let service = BugReportService(configuration: configuration)
        box.service = service

        // Try to drain the pending (offline) queue.
        service.bootstrap()

        // UI side (screenshot detector + banner) — UIKit platforms only.
        installDetectorIfPossible()
    }

    // MARK: - Access

    /// The active bug-report service. `nil` unless a valid `configure(enabled: true, ...)`
    /// happened. The UI uses this to submit reports; when `nil`, no UI is installed.
    public static var bugReportService: BugReportService? {
        box.service
    }

    /// Is the bug reporter currently active? (configured + service exists)
    public static var isConfigured: Bool { box.service != nil }

    /// Attempts to send pending offline reports (call e.g. on returning to foreground
    /// or once a VPN connection is established).
    public static func flushPendingUploads() {
        box.service?.flushPendingUploads()
    }

    // MARK: - Internal helpers

    /// Collie's own diagnostic message (flows into the host's `diagnostics` closure).
    static func diag(_ message: String) {
        box.service?.diag(message)
    }

    private static func installDetectorIfPossible() {
        #if canImport(UIKit)
        Task { @MainActor in
            BugReportBanner.shared.install()
        }
        #endif
    }

    /// Resets global state for tests. Never called in production code.
    static func _resetForTesting() {
        box.service = nil
    }

    // MARK: - State

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _service: BugReportService?

        var service: BugReportService? {
            get { lock.lock(); defer { lock.unlock() }; return _service }
            set { lock.lock(); _service = newValue; lock.unlock() }
        }
    }
}
