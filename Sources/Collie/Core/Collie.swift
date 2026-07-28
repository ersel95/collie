import Foundation

/// Collie's public facade: screenshot → banner → form → **report in the analyst panel**.
/// **OPT-IN, disabled by default.**
///
/// Unless `configure(...)` is called — or when it is called with `enabled: false`
/// (the default) — **no** detector / network / upload code runs at all.
///
/// The device never talks to Jira: it uploads the report to the Collie backend, where an
/// analyst triages it and pushes it to Jira from the panel.
///
/// ```swift
/// // Default: off. To enable (backend settings come from the host's xcconfig):
/// var config = CollieConfiguration(
///     enabled: true,
///     apiBaseURL: URL(string: "<COLLIE_API_BASE_URL>")!,
///     apiKey: "<COLLIE_API_KEY>",
///     environment: "staging"
/// )
/// config.logSnapshotProvider = { MyLogger.snapshot().map { ... } }   // optional
/// Collie.configure(with: config)
/// ```
public enum Collie {

    private static let box = StateBox()

    // MARK: - Configure (single entry point)

    /// Configures the bug reporter. **Default `enabled: false`** → opt-in.
    public static func configure(
        enabled: Bool = false,
        apiBaseURL: URL,
        apiKey: String = "",
        environment: String = "staging"
    ) {
        let config = CollieConfiguration(
            enabled: enabled,
            apiBaseURL: apiBaseURL,
            apiKey: apiKey,
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
    ///  2. Fail-closed validation: if any required backend field (`apiKey`, `apiBaseURL`,
    ///     the endpoint paths) is blank, nothing is installed.
    /// The host must never pass a hard-coded `enabled: true` in release builds; the value
    /// must come from xcconfig/secrets (non-prod only).
    ///
    /// Idempotent; if called again, the first configuration is kept.
    ///
    /// - Parameter transport: Where reports are sent. Defaults to Collie's own HTTPS
    ///   ingestion client. Pass a custom one — e.g. `FirestoreTransport` from the
    ///   `CollieFirebase` product — when the host's network policy only permits certain
    ///   destinations.
    public static func configure(
        with configuration: CollieConfiguration,
        transport: (any ReportTransport)? = nil
    ) {
        // Gate 1: local opt-in (build-time defense). If off, do nothing.
        guard configuration.enabled else { return }

        // Gate 2: required backend fields — fail-closed. A custom transport brings its
        // own destination and credentials, so the HTTPS-ingestion fields are not
        // required in that case.
        if transport == nil, let error = configuration.validationError {
            configuration.diagnostics?("[Collie] configure: \(error) — bug reporter not started.")
            return
        }

        // Idempotent: keep the first installation.
        guard box.service == nil else { return }

        let service = BugReportService(configuration: configuration, transport: transport)
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

    #if canImport(UIKit)
    /// Registers a handler for taps on the Collie logo in the report sheet's
    /// navigation bar.
    ///
    /// When a handler is set, the logo becomes a button: tapping it closes the Collie UI
    /// and invokes the handler **after** the UI has fully closed, so it is safe to
    /// present another diagnostics tool from the handler. Useful when Collie is
    /// installed alongside another shake-activated tool: the host wires the two logo
    /// callbacks to switch between them. Pass `nil` to remove the handler (the logo
    /// becomes a plain image again).
    ///
    /// The handler does **not** affect shake behavior: whether a shake asks first or
    /// opens the report sheet directly is decided solely by
    /// `CollieConfiguration.asksBeforeReporting` (default `true` — ask first).
    @MainActor
    public static func onLogoTap(_ handler: (() -> Void)?) {
        BugReportBanner.shared.logoTapHandler = handler
    }
    #endif

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
