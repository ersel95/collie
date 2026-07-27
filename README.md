# Collie 🐕

**Shake the device → report it → an analyst pushes it to Jira.**

Collie is a bug-reporter SDK for iOS test builds: when a tester shakes the device, a
bubble slides in from the bottom ("Want to share it?"), a short form is filled out, and
the report is uploaded to the **Collie backend** in a single multipart request. Analysts
review it in the panel — screenshot, full log stream, network and navigation views — and
push it to Jira from there, choosing the issue type, parent, assignee and labels.

```
Tester shakes the device
  → ShakeDetector fires; ScreenRenderer renders the key window (secure fields stay masked)
  → Banner: "Spotted a problem? Want to share it?"  (skipped when asksBeforeReporting = false)
  → [Yes] → Form: "What happened?" / "What was expected?" (+ name on first use)
  → Backend: POST <reportsPath>  (multipart: report JSON + screenshot, x-collie-api-key)
  → Success: "Report sent" · Transient error: disk queue + automatic retry with backoff
  → Panel: analyst triages the report and pushes it to Jira
```

## Why a backend in between

The device carries **no Jira credentials at all** — no PAT, project key, parent task or
assignee. Reports are triaged before they reach Jira, so noise never lands in the tracker,
and each report is filed by the analyst who reviewed it, against the right parent and the
right person.

## Features

- **One request per report** — a multipart upload carrying the JSON envelope (app/device
  meta, both free-text fields, all log entries, telemetry) and the screenshot. The
  api-key both identifies the app and authenticates the upload.
- **Opt-in + fail-closed** — off by default; if any required field is missing, nothing
  runs at all.
- **Remote kill switch** — the panel can disable capture for an app without a new build.
  The check fails *open* when the backend is unreachable, so a tester without VPN can
  still file a report.
- **Offline resilience** — without VPN the report is queued to disk (encrypted, 48-hour
  TTL) and retried with exponential backoff. A retry **cannot create a duplicate**: the
  report's id travels as an idempotency key, so even a response lost in transit resolves
  to the same report.
- **Screenshot safety** — the screen is captured at shake time with secure text field
  masks preserved via `drawHierarchy(afterScreenUpdates: true)`; informed-consent notice
  in the form; progressive JPEG compression down to the size limit.
- **Lossless logs** — ALL entries travel with the report, categories preserved, nothing
  summarized or truncated. The panel keeps the raw stream and derives its Network and
  Navigation views from it.
- **Signed-in account** — log a `customerNo` metadata key on your sign-in paths and the
  panel shows which account the tester was using; omitted when the key is never logged.
- **Log-source agnostic** — feed logs from any logger ([Olaf](https://github.com/ersel95/olaf),
  Netfox, Pulse, os_log, your own) via the `logSnapshotProvider` closure; Collie has no
  dependency on any of them.
- **Tool switching** — `Collie.onLogoTap { ... }`: tapping the logo in the report sheet
  closes the Collie UI and hands off to another diagnostics tool of your choice.
- **Ask or go straight in** — `asksBeforeReporting` (default `true`): a shake raises the
  "Spotted a problem?" yes/no banner first, or opens the report form directly (`false`).
- **No PII** — telemetry is device-state only (no IP/SSID/location).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/ersel95/collie.git", from: "1.0.0")
]
```

## Usage

```swift
import Collie

var config = CollieConfiguration(
    enabled: true,                                        // from xcconfig; always false in release
    apiBaseURL: URL(string: "<COLLIE_API_BASE_URL>")!,
    apiKey: "<COLLIE_API_KEY>",                           // xcconfig/secrets — never enters the repo
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

The api-key comes from the panel's **Admin · Apps** page, where the app's Jira project,
default issue type, retention and kill switch are configured.

See `Integration/CollieIntegration.swift` for a ready-made template, and
`INTEGRATION.md` for detailed setup and troubleshooting.

## Requirements

- iOS 17+ (UI layer) · macOS 14+ (core, for tests)
- A reachable Collie backend deployment
- A corporate backend is usually reachable only over **VPN** — without VPN, reports are
  queued and retried via `Collie.flushPendingUploads()` / automatically at app startup.

## Security notes

- `enabled` must be `true` only in non-prod builds (via xcconfig).
- The ingestion api-key is the single secret on the device; it is never committed to the
  repo and can be rotated from the panel.
- Collie's traffic leaves through its own `URLSession` (`protocolClasses = []`) —
  network-capture tools do not capture this traffic. For an extra safeguard, add
  `config.captureExclusionFragments` to your capture tool's exclude list.

## License

MIT — see [LICENSE](LICENSE).
