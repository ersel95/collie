import Foundation

/// Bug-reporter configuration. Provided once via `Collie.configure(...)`.
///
/// **All backend settings are parametric** — base URL and api-key are supplied by the
/// integrating project at init time; nothing project- or person-specific is embedded in
/// Collie's code.
///
/// ⚠️ **Public repo rule**: No real URL / company name / secret ever enters this struct
/// as a **default** value. `apiBaseURL` / `apiKey` are provided by the host app at
/// runtime (xcconfig/secrets) and are never committed to the repo.
public struct CollieConfiguration: Sendable {

    // MARK: - Gate

    /// Local (build-time) on/off switch for the feature. **Default `false` (opt-in).**
    /// While `false`, `Collie.configure` returns early: zero network / detector / upload.
    public var enabled: Bool

    // MARK: - Backend (all provided by the host)

    /// Root URL of the Collie backend (e.g. `https://collie-api.example.com`). Corporate
    /// deployments are often reachable only over VPN; on send failures the offline queue
    /// takes over.
    public var apiBaseURL: URL

    /// Ingestion api-key. Sent as the `x-collie-api-key` header — it is the **sole**
    /// ingestion credential: it identifies which app the report belongs to and
    /// authenticates the caller. If blank, configure behaves fail-closed (no-op).
    public var apiKey: String

    /// Path of the report ingestion endpoint, appended to `apiBaseURL`.
    public var reportsPath: String

    /// Path of the remote-config endpoint (server-side kill switch), appended to
    /// `apiBaseURL`.
    public var configPath: String

    // MARK: - Flow

    /// Does a shake ask before opening the report form? `true` (default) shows the
    /// "Spotted a problem?" yes/no banner first; `false` opens the report sheet directly.
    ///
    /// This is an explicit switch: whether another diagnostics tool is installed (i.e.
    /// whether `Collie.onLogoTap` has a handler) no longer affects it.
    public var asksBeforeReporting: Bool

    /// Does a shake open Collie at all? `true` (default) installs the shake detector.
    ///
    /// Set `false` when another shake-activated tool owns the gesture and Collie is
    /// reached only deliberately — through `Collie.presentReport()` from that tool's
    /// hand-off. Without this both tools answer the same shake and Collie's banner ends
    /// up buried under the other tool's full-screen UI.
    ///
    /// `presentReport()` keeps working regardless.
    public var activatesOnShake: Bool

    // MARK: - Report meta

    /// Environment label (e.g. "staging" / "uat"). Sent with every report.
    ///
    /// The app's display name is **not** configured here: the backend resolves which app
    /// a report belongs to from the api-key and uses the name on its own app record.
    public var environment: String

    // MARK: - Upload behavior

    /// Timeout for a single request (seconds).
    public var requestTimeout: TimeInterval

    /// Maximum number of attempts for a report in the offline queue.
    public var maxRetryCount: Int

    /// Base delay for exponential backoff (seconds). Attempt n → `baseRetryDelay * 2^n`.
    public var baseRetryDelay: TimeInterval

    /// Screenshot JPEG compression quality (0...1).
    public var screenshotJPEGQuality: Double

    /// Upper bound allowed for the screenshot (bytes). Kept safely below the backend's
    /// ingestion limit (default ~8 MB server-side).
    public var maxScreenshotBytes: Int

    // MARK: - Host bridges (optional)

    /// Closure providing the log snapshot at report time. The host maps its own logs
    /// to `CollieLogEntry`. When `nil`, reports go without logs.
    public var logSnapshotProvider: (@Sendable () -> [CollieLogEntry])?

    /// Closure providing the current session identifier from the host's logging system.
    public var sessionIDProvider: (@Sendable () -> String?)?

    /// Collie's own diagnostic messages (queue/send states). The host can forward these
    /// to its own logging system.
    public var diagnostics: (@Sendable (String) -> Void)?

    public init(
        enabled: Bool = false,
        apiBaseURL: URL,
        apiKey: String = "",
        reportsPath: String = CollieConfiguration.defaultReportsPath,
        configPath: String = CollieConfiguration.defaultConfigPath,
        asksBeforeReporting: Bool = true,
        activatesOnShake: Bool = true,
        environment: String = "staging",
        requestTimeout: TimeInterval = 30,
        maxRetryCount: Int = 5,
        baseRetryDelay: TimeInterval = 5,
        screenshotJPEGQuality: Double = 0.7,
        maxScreenshotBytes: Int = 4 * 1_048_576,
        logSnapshotProvider: (@Sendable () -> [CollieLogEntry])? = nil,
        sessionIDProvider: (@Sendable () -> String?)? = nil,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.enabled = enabled
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.reportsPath = reportsPath
        self.configPath = configPath
        self.asksBeforeReporting = asksBeforeReporting
        self.activatesOnShake = activatesOnShake
        self.environment = environment
        self.requestTimeout = max(1, requestTimeout)
        self.maxRetryCount = max(0, maxRetryCount)
        self.baseRetryDelay = max(0, baseRetryDelay)
        self.screenshotJPEGQuality = min(1, max(0.1, screenshotJPEGQuality))
        self.maxScreenshotBytes = max(0, maxScreenshotBytes)
        self.logSnapshotProvider = logSnapshotProvider
        self.sessionIDProvider = sessionIDProvider
        self.diagnostics = diagnostics
    }

    // MARK: - Defaults

    /// Default ingestion endpoint path.
    public static let defaultReportsPath = "/api/v1/collie/reports"

    /// Default remote-config endpoint path.
    public static let defaultConfigPath = "/api/v1/collie/config"

    /// HTTP header carrying the ingestion api-key.
    public static let apiKeyHeader = "x-collie-api-key"

    // MARK: - Validation (fail-closed)

    /// Returns the reason if any required field is blank; `nil` when all are set.
    /// `Collie.configure` refuses to install unless this is `nil` (fail-closed).
    public var validationError: String? {
        func blank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if blank(apiKey) { return "apiKey is blank — cannot authenticate to the Collie backend" }
        if blank(apiBaseURL.absoluteString) { return "apiBaseURL is blank" }
        if apiBaseURL.host?.isEmpty != false { return "apiBaseURL has no host" }
        if blank(reportsPath) { return "reportsPath is blank" }
        if blank(configPath) { return "configPath is blank" }
        return nil
    }

    // MARK: - URLs

    /// `POST <apiBaseURL><reportsPath>` — multipart report upload.
    public var reportsURL: URL {
        url(appending: reportsPath)
    }

    /// `GET <apiBaseURL><configPath>` — remote config / server-side kill switch.
    public var configURL: URL {
        url(appending: configPath)
    }

    /// Recursion prevention: if the host uses a network-capture tool, it should add these to
    /// that tool's URL exclude list. (Collie's own session carries no capture protocol to
    /// begin with — this is the second safeguard.)
    ///
    /// These are **whole URLs**, and that matters. Capture tools match their exclude list as
    /// substrings, and this property used to return the host and the path as two *separate*
    /// entries — so a short `reportsPath` swallowed unrelated traffic: with `reportsPath =
    /// "/post"`, the entry `/post` also matched the host app's own `GET /posts`, and every
    /// one of those requests silently vanished from the logs a tester was trying to report.
    /// The bug is invisible from the outside: the report uploads fine, it just arrives with
    /// nothing in it.
    ///
    /// A full URL cannot misfire that way — it only matches Collie's own two endpoints.
    public var captureExclusionFragments: [String] {
        [reportsURL.absoluteString, configURL.absoluteString].filter { !$0.isEmpty }
    }

    private func url(appending path: String) -> URL {
        let trimmedBase = apiBaseURL.absoluteString.hasSuffix("/")
            ? String(apiBaseURL.absoluteString.dropLast())
            : apiBaseURL.absoluteString
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: trimmedBase + normalizedPath) ?? apiBaseURL
    }
}
