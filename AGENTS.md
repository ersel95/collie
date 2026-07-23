# Collie — Agent Guide

Collie: an SPM bug-reporter package for iOS test builds — shake → banner → form →
a **subtask directly in Jira**. No backend; the device talks to Jira Server/DC REST v2
with a PAT. A screenshot is captured automatically at shake time and attached, together
with a full log JSON fed from the host's logging library (any source).

## Where to start, by task

| Task | Read |
|---|---|
| **Integrating Collie into a host app** | The "Integration" section below + `INTEGRATION.md` (details and troubleshooting) + `Integration/CollieIntegration.swift` (template to copy) |
| Developing Collie itself | The "Development" section below |

## Integration (into a host app)

Ordered steps — all required:

1. **Add the package:** attach Collie to the host target via SPM.
2. **Copy the template:** `Integration/CollieIntegration.swift` → into the host project.
   This file is NOT part of the package; it exists to be copied. Where to find it:
   - Package added via Xcode: `~/Library/Developer/Xcode/DerivedData/<App>-*/SourcePackages/checkouts/collie/Integration/CollieIntegration.swift`
   - Package added via Package.swift: `.build/checkouts/collie/Integration/CollieIntegration.swift`
   - Or fetch it directly: `https://raw.githubusercontent.com/ersel95/collie/main/Integration/CollieIntegration.swift`
3. **Provide the keys** (xcconfig → Info.plist chain; values NEVER enter the repo):
   `COLLIE_ENABLED`, `COLLIE_JIRA_BASE_URL`, `COLLIE_JIRA_PAT`,
   `COLLIE_JIRA_PROJECT_KEY`, `COLLIE_JIRA_PARENT_KEY` (the parent task reports are
   created under), `COLLIE_JIRA_SUBTASK_TYPE` (the actual subtask type name in Jira),
   `COLLIE_JIRA_ASSIGNEE` (the user every subtask is assigned to),
   `COLLIE_JIRA_LABELS` (optional, comma-separated issue labels), `COLLIE_ENVIRONMENT`.
   The Info.plist mapping is ready in the comment at the top of the template.
   ⚠️ In release/prod configs `COLLIE_ENABLED` is undefined or `NO`; the PAT lives only
   in non-prod secrets.
4. **Start:** call `CollieIntegration.start()` at app startup (after the host's logging
   library, if logs are fed from one).
5. **Feed logs (recommended):** Collie is log-source agnostic — map any logger's
   snapshot (Olaf, Netfox, Pulse, os_log, custom) to `[CollieLogEntry]` via
   `config.logSnapshotProvider`. A ready-to-paste Olaf bridge is in the template and in
   `INTEGRATION.md` §5 (our apps use Olaf). If the logger captures network traffic, add
   `config.captureExclusionFragments` to its URL exclude list (recursion prevention,
   2nd safeguard).
6. **Tool switching (optional):** if another shake-activated tool is installed, wire
   `Collie.onLogoTap { ... }` (runs after the Collie UI fully closes) and the other
   tool's equivalent so testers can hop between them — see `INTEGRATION.md` §5.
   With the handler wired, a shake skips the yes/no banner and opens the report sheet
   directly; without it (Collie-only project) the banner is shown first.
7. **Verify:**
   - Shake the device (simulator: Device → Shake, ⌃⌘Z) → the banner must appear (the
     report sheet directly, if `onLogoTap` is wired); submit
     the form → a subtask must exist in Jira under `COLLIE_JIRA_PARENT_KEY` with
     `screenshot.jpg` + `collie-logs-*.json` + one `net-*.txt` per captured network
     request as attachments, and the correct assignee.
   - If the banner doesn't appear: check the `config.diagnostics` output — when a
     required field is blank, Collie stays silently off (fail-closed).
   - Corporate Jira is reachable only over VPN; without VPN a submission becomes
     "Queued" and is retried via `Collie.flushPendingUploads()`.

Common errors are in the table in `INTEGRATION.md` §7 (401 → PAT, 400 → parent/subtask
type name).

## Development (this repo)

- Structure: single target. `Sources/Collie/Core/` is UIKit-free (compiles/tests on
  macOS), `Sources/Collie/UI/` sits behind `#if canImport(UIKit)`.
- Tests: `swift test` (runs on macOS). iOS compile check:
  `swift build --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)`
- Behaviors that MUST be preserved (do not make breaking changes):
  - Opt-in + fail-closed: `enabled` defaults to `false`; a blank required Jira field
    means nothing is installed.
  - Recursion prevention: `JiraClient` uses its own session with `protocolClasses = []`.
  - Queue duplicate prevention: after a create, `issueKey` is written to the envelope;
    a retry never repeats the create (`UploadQueueTests` locks this in).
  - `parent` + `assignee` are set from the config on every issue (a report is always a
    subtask).
  - The screenshot is rendered at shake time with `drawHierarchy(afterScreenUpdates: true)`
    (the secure-field mask depends on it).
  - Shake detection swizzles `UIWindow.motionEnded` and always calls the original
    implementation (it must compose with other tools that swizzle the same selector).
  - ALL provided log entries are attached to the issue in full (the description may
    summarize/truncate, the JSON attachment never does — and neither do the per-request
    `net-*.txt` files).
  - Network attachment names are deterministic: the description is written *before* the
    files are uploaded and links to them by name, so `NetworkAttachmentBuilder.plan`
    (ordering + naming) and `JiraIssueBuilder.formatNetwork` must stay in sync.
  - Core stays log-source agnostic: no logging-library types or names in `Sources/`
    (concrete bridges live only in docs and the integration template).
  - No PII (IP/SSID/location) is ever added to telemetry.
- Jira assumption: Server/DC (REST v2, PAT Bearer, `assignee.name`, wiki markup).
  Cloud (v3/ADF) is out of scope; if added, isolate it inside
  `JiraClient`/`JiraIssueBuilder`.
- Language: all code comments, docs, and commit messages are in English.
- Releasing: add a `## <version> — <date>` section to `CHANGELOG.md`, commit, then
  `git tag <version> && git push origin <version>` (plain semver, no `v` prefix).
  The `Release` workflow (`.github/workflows/release.yml`) runs the tests, builds for
  the iOS simulator, and publishes the GitHub release with that CHANGELOG section as
  its notes — it fails if the section is missing.
