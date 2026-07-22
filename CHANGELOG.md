# Changelog

## 0.1.0 — 2026-07-22

Initial release. A standalone redevelopment of the bug-reporter mechanism extracted
from Olaf (see `Olaf/docs/bug-reporter-summary.md`); the backend/frontend pair was
removed from the flow — reports now go **directly to Jira**.

### Added
- **Core (UIKit-free):**
  - `Collie.configure` — opt-in (off by default) + fail-closed validation (pat,
    projectKey, parentIssueKey, subtaskIssueType, assigneeUsername required), idempotent.
  - `CollieConfiguration` — all Jira settings parametric; logging-library-agnostic
    bridge via the `logSnapshotProvider` / `sessionIDProvider` / `diagnostics` closures.
  - `JiraClient` — Jira REST v2 (Server/DC): issue create + attachment upload
    (`X-Atlassian-Token: no-check`), PAT Bearer auth, its own ephemeral `URLSession`
    (`protocolClasses = []` → no capture recursion), permanent/transient error
    classification (special 401 message, 408/429 transient).
  - `JiraIssueBuilder` — Swift port of the One4All panel's `jira-issue.builder.ts`:
    summary (250), wiki escaping, description sections (Reporter/Environment/Telemetry/
    What happened/What was expected/Navigation/Network/Logs), failure-first top-15
    network rows, body truncation; `parent` + `assignee` on every issue from the config.
  - `UploadQueue` — two-step (create → attachments) disk queue: `issueKey` is written
    to the envelope → retries never create duplicate issues; exponential backoff,
    48-hour TTL, `.completeFileProtection`, resumes from disk after restart.
  - `CollieDeviceIdentity` — persistent device UUID in the Keychain + one-time tester name.
  - `CollieTelemetry` — PII-free device-state snapshot (network type, battery, thermal,
    disk, memory…).
- **UI (iOS):** `ScreenshotDetector` (secure-field-masked rendering), `BugReportBanner`
  (separate window + passthrough hit-testing), `BugReportSheet` (informed consent,
  keyboard navigation), `BugReportComposer` (progressive JPEG compression),
  `BugReportToast` ("PROJ-123 created" / "Queued").
- **Other:** `PrivacyInfo.xcprivacy` (device id + screenshot + diagnostic data
  declaration), the `Integration/CollieIntegration.swift` template, `INTEGRATION.md`,
  `AGENTS.md`, 49 unit tests.
