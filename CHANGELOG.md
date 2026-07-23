# Changelog

## Unreleased

### Changed
- When tool switching is wired (`Collie.onLogoTap` handler set), a shake now skips
  the "Spotted a problem?" yes/no banner and opens the report sheet directly.
  Collie-only projects (no handler) keep the yes/no banner as before.
- **Issue summary is now a fixed task name:** `Collie iOS Report - <dd.MM.yyyy HH:mm>`
  (was `[AppName] <first line of "What happened?">`; the app name moved into the
  description's Report table).
- **Visual wiki-markup description** (Jira Server/DC text formatting): the Report /
  Telemetry / Navigation / Network / Logs sections are now tables; "What happened?" /
  "What was expected?" are colored panels; network rows carry (x)/(/) icons and
  red/green status colors, with failing request/response bodies in `{code}` blocks
  below the table.
- Device is reported with its marketing name (`iPhone16,1` → `iPhone 15 Pro`) via the
  new `CollieDeviceModel` map; unknown identifiers fall back to the raw identifier.
- The `collie-logs-*.json` attachment is now pretty-printed with stable key order
  (still ALL entries in full).

### Added
- `COLLIE_JIRA_LABELS` (comma-separated) xcconfig key →
  `CollieConfiguration.labels(fromCommaSeparated:)`: entries are trimmed, empties
  dropped, inner spaces replaced with `-`, and applied to every created issue.
- A synthetic "Collie initialized — <date&time>" log entry (category `collie`) is
  inserted into the report's log timeline at its chronological position, and the init
  time is shown in the description's Report table.

## 0.2.1 — 2026-07-22

### Fixed
- The integration template now wires `config.diagnostics` by default, so the
  troubleshooting output exists out of the box (also removes the unused-variable
  warning the template produced when copied verbatim).
- `AGENTS.md` documents where to find the integration template after SPM resolution
  (Xcode DerivedData / `.build` checkouts / raw GitHub URL).
- The README installation snippet pins the current version.

## 0.2.0 — 2026-07-22

### Changed
- **Activation is now shake-based, not screenshot-based.** `ScreenshotDetector`
  (`userDidTakeScreenshotNotification`) was replaced with `ShakeDetector`, a runtime
  swizzle of `UIWindow.motionEnded` that posts `.collieShake` and always calls the
  original implementation (composes with other tools that swizzle the same selector).
  The screen is now captured at shake time by `ScreenRenderer` (same
  `drawHierarchy(afterScreenUpdates: true)` secure-field-masked rendering as before)
  and attached to the report as `screenshot.jpg`.
- Docs restructured around a log-source-agnostic contract: feed logs from any logger
  via `logSnapshotProvider` (`INTEGRATION.md` §5 has a ready-to-paste bridge example);
  simulator verification via Device → Shake (⌃⌘Z).

### Added
- `Collie.onLogoTap(_:)` — when set, the logo in the report sheet's navigation bar
  becomes a button: tapping it closes the Collie UI and invokes the handler after the
  UI has fully closed, enabling hand-off to another shake-activated diagnostics tool.

## 0.1.0 — 2026-07-22

Initial release. Reports go **directly to Jira** — no backend in between.

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
  - `JiraIssueBuilder` — summary (250), wiki escaping, description sections
    (Reporter/Environment/Telemetry/What happened/What was expected/Navigation/Network/
    Logs), failure-first top-15 network rows, body truncation; `parent` + `assignee` on
    every issue from the config.
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
