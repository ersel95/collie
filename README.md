# Collie 🐕

**Shake the device → report it → a subtask in Jira.**

Collie is a bug-reporter SDK for iOS test builds: when a tester shakes the device, a
bubble slides in from the bottom ("Want to share it?"), a short form is filled out, and
the report goes **straight to Jira** — no backend in between. Every report is created as
a **subtask** under a configured parent task and assigned to a configured person; a
screenshot captured at shake time and a log JSON are uploaded as attachments to the issue.

```
Tester shakes the device
  → ShakeDetector fires; ScreenRenderer renders the key window (secure fields stay masked)
  → Banner: "Spotted a problem? Want to share it?"  (skipped when tool switching is wired)
  → [Yes] → Form: "What happened?" / "What was expected?" (+ name on first use)
  → Jira: POST /rest/api/2/issue  (subtask under the parent, assignee from config)
  →       POST /issue/{key}/attachments  (screenshot.jpg + collie-logs.json)
  → Success: "PROJ-123 created" · Transient error: disk queue + automatic retry with backoff
```

## Features

- **Direct Jira Server/DC** — REST v2 + Personal Access Token (Bearer). No backend.
- **Fully parametric Jira settings** — project, parent task, subtask type, assignee,
  labels: everything comes from the host project's `configure` call; nothing is embedded
  in the SDK.
- **Opt-in + fail-closed** — off by default; if any required field is missing, nothing
  runs at all.
- **Offline resilience** — without VPN the report is queued to disk (encrypted, 48-hour
  TTL) and retried with exponential backoff; if the issue was created but an attachment
  was left unfinished, the retry **does not create a duplicate issue** — it resumes from
  the remaining step.
- **Screenshot safety** — the screen is captured at shake time with secure text field
  masks preserved via `drawHierarchy(afterScreenUpdates: true)`; informed-consent notice
  in the form; progressive JPEG compression down to the size limit.
- **Rich issue content** — visual wiki-markup description: a Report info table (device
  shown by its marketing name, e.g. `iPhone 15 Pro`), colored "What happened / expected"
  panels, telemetry, navigation timeline, failure-first network table (top 15) with
  red/green status colors, category counts. Summary is `Collie iOS Report - <date&time>`;
  the raw logs travel in full as a pretty-printed JSON attachment.
- **Log-source agnostic** — feed logs from any logger ([Olaf](https://github.com/ersel95/olaf),
  Netfox, Pulse, os_log, your own) via the `logSnapshotProvider` closure; Collie has no
  dependency on any of them. ALL entries travel to Jira in full as a JSON attachment,
  and network/navigation entries also feed the issue description.
- **Tool switching** — `Collie.onLogoTap { ... }`: tapping the logo in the report sheet
  closes the Collie UI and hands off to another diagnostics tool of your choice. With a
  handler wired, a shake opens the report sheet directly (no yes/no banner).
- **No PII** — telemetry is device-state only (no IP/SSID/location).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/ersel95/collie.git", from: "0.2.1")
]
```

## Usage

```swift
import Collie

var config = CollieConfiguration(
    enabled: true,                                   // from xcconfig; always false in release
    jiraBaseURL: URL(string: "<JIRA_BASE_URL>")!,
    pat: "<PAT>",                                    // xcconfig/secrets — never enters the repo
    projectKey: "PROJ",
    parentIssueKey: "PROJ-123",                      // reports become subtasks under this
    subtaskIssueType: "Sub-task",                    // the actual subtask type name in Jira
    assigneeUsername: "jira.user",                   // every subtask is assigned to this user
    environment: "staging"
)

// Optional: feed logs from any source — example with Olaf
config.logSnapshotProvider = {
    Olaf.snapshot().map {
        CollieLogEntry(date: $0.date, level: $0.level.rawValue,
                       category: $0.category.rawValue, message: $0.message,
                       metadata: $0.metadata)
    }
}
config.sessionIDProvider = { Olaf.currentSessionID }

Collie.configure(with: config)
```

See `Integration/CollieIntegration.swift` for a ready-made template, and
`INTEGRATION.md` for detailed setup and troubleshooting.

## Requirements

- iOS 17+ (UI layer) · macOS 14+ (core, for tests)
- Jira Server / Data Center (REST v2, PAT support)
- Corporate Jira is usually reachable only over **VPN** — without VPN, reports are
  queued and retried via `Collie.flushPendingUploads()` / automatically at app startup.

## Security notes

- `enabled` must be `true` only in non-prod builds (via xcconfig).
- The PAT is the single secret; it is never committed to the repo.
- Collie's Jira traffic leaves through its own `URLSession` (`protocolClasses = []`) —
  network-capture tools do not capture this traffic. For an extra safeguard, add
  `config.captureExclusionFragments` to your capture tool's exclude list.

## License

MIT — see [LICENSE](LICENSE).
