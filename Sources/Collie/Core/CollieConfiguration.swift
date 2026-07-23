import Foundation

/// Bug-reporter configuration. Provided once via `Collie.configure(...)`.
///
/// **All Jira settings are parametric** — parent task, assignee, project, subtask type
/// etc. are supplied by the integrating project at init time; nothing project- or
/// person-specific is embedded in Collie's code.
///
/// ⚠️ **Public repo rule**: No real URL / company name / secret ever enters this struct
/// as a **default** value. `pat` / `jiraBaseURL` are provided by the host app at runtime
/// (xcconfig/secrets) and are never committed to the repo.
public struct CollieConfiguration: Sendable {

    // MARK: - Gate

    /// Local (build-time) on/off switch for the feature. **Default `false` (opt-in).**
    /// While `false`, `Collie.configure` returns early: zero network / detector / upload.
    public var enabled: Bool

    // MARK: - Jira (all provided by the host)

    /// Jira root URL (e.g. `https://jira.example.com`). Corporate Jira is usually
    /// reachable only over VPN; on send failures the offline queue takes over.
    public var jiraBaseURL: URL

    /// Personal Access Token (Jira Server/DC). Sent as `Authorization: Bearer <pat>`.
    /// If blank, configure behaves fail-closed (no-op).
    public var pat: String

    /// Jira project key (e.g. `PROJ`). Subtasks are created in this project.
    public var projectKey: String

    /// Every report is created **as a subtask under this task** (e.g. `PROJ-123`).
    /// Must live in the same project as `projectKey`; otherwise Jira returns 400.
    public var parentIssueKey: String

    /// The name of the subtask issue type as it exists in Jira (whatever the actual
    /// name is in your installation: "Sub-task", "Alt görev", etc.).
    public var subtaskIssueType: String

    /// Jira username every subtask is assigned to (Server/DC `assignee.name`).
    public var assigneeUsername: String

    /// Labels added to every created issue (optional).
    public var defaultLabels: [String]

    // MARK: - Report meta

    /// App name shown in the issue description's Report table. If blank, the bundle
    /// name is used.
    public var appDisplayName: String

    /// Environment label (e.g. "staging" / "uat"). Written into the issue description.
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

    /// Upper bound allowed for the screenshot (bytes). Kept safely below Jira's
    /// attachment limit (default ~10 MB).
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
        jiraBaseURL: URL,
        pat: String = "",
        projectKey: String = "",
        parentIssueKey: String = "",
        subtaskIssueType: String = "Sub-task",
        assigneeUsername: String = "",
        defaultLabels: [String] = [],
        appDisplayName: String = "",
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
        self.jiraBaseURL = jiraBaseURL
        self.pat = pat
        self.projectKey = projectKey
        self.parentIssueKey = parentIssueKey
        self.subtaskIssueType = subtaskIssueType
        self.assigneeUsername = assigneeUsername
        self.defaultLabels = defaultLabels
        self.appDisplayName = appDisplayName
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

    // MARK: - Labels

    /// Parses a comma-separated label list (e.g. the `COLLIE_JIRA_LABELS` xcconfig
    /// value) into Jira labels: trims whitespace, drops empties, and replaces inner
    /// spaces with `-` (Jira labels cannot contain spaces).
    public static func labels(fromCommaSeparated raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "-")
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Validation (fail-closed)

    /// Returns the reason if any required Jira field is blank; `nil` when all are set.
    /// `Collie.configure` refuses to install unless this is `nil` (fail-closed).
    public var validationError: String? {
        func blank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if blank(pat) { return "pat is blank — cannot authenticate to Jira" }
        if blank(projectKey) { return "projectKey is blank" }
        if blank(parentIssueKey) { return "parentIssueKey is blank — reports are created as subtasks under a parent task" }
        if blank(subtaskIssueType) { return "subtaskIssueType is blank" }
        if blank(assigneeUsername) { return "assigneeUsername is blank" }
        return nil
    }

    // MARK: - URLs

    /// `POST /rest/api/2/issue` — issue creation.
    public var issueCreateURL: URL {
        url(appending: "/rest/api/2/issue")
    }

    /// `POST /rest/api/2/issue/{key}/attachments` — file upload.
    public func attachmentsURL(issueKey: String) -> URL {
        url(appending: "/rest/api/2/issue/\(issueKey)/attachments")
    }

    /// The human-facing URL of an issue.
    public func browseURL(issueKey: String) -> URL {
        url(appending: "/browse/\(issueKey)")
    }

    /// Recursion prevention: if the host uses a network-capture tool, it should add
    /// these fragments to that tool's URL exclude list. (Collie's own session carries no
    /// capture protocol to begin with — this is the second safeguard.)
    public var captureExclusionFragments: [String] {
        var fragments: [String] = []
        if let host = jiraBaseURL.host { fragments.append(host.lowercased()) }
        fragments.append("/rest/api/2/issue")
        return fragments.filter { !$0.isEmpty }
    }

    /// App name to show in the description (falls back to the bundle).
    var resolvedAppDisplayName: String {
        let trimmed = appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "App"
    }

    private func url(appending path: String) -> URL {
        let trimmedBase = jiraBaseURL.absoluteString.hasSuffix("/")
            ? String(jiraBaseURL.absoluteString.dropLast())
            : jiraBaseURL.absoluteString
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: trimmedBase + normalizedPath) ?? jiraBaseURL
    }
}
