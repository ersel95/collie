# Collie — Agent Guide

Collie: an SPM bug-reporter package for iOS test builds — screenshot → banner → form →
a **subtask directly in Jira**. No backend; the device talks to Jira Server/DC REST v2
with a PAT.

## Where to start, by task

| Task | Read |
|---|---|
| **Integrating Collie into a host app** | The "Integration" section below + `INTEGRATION.md` (details and troubleshooting) + `Integration/CollieIntegration.swift` (template to copy) |
| Developing Collie itself | The "Development" section below + `ROADMAP.md` |
| Understanding the architecture rationale | The `ROADMAP.md` intro + `Olaf/docs/bug-reporter-summary.md` (the old architecture) |

## Integration (into a host app)

Ordered steps — all required:

1. **Add the package:** attach Collie to the host target via SPM.
2. **Copy the template:** `Integration/CollieIntegration.swift` → into the host project.
   This file is NOT part of the package; it exists to be copied.
3. **Provide the keys** (xcconfig → Info.plist chain; values NEVER enter the repo):
   `COLLIE_ENABLED`, `COLLIE_JIRA_BASE_URL`, `COLLIE_JIRA_PAT`,
   `COLLIE_JIRA_PROJECT_KEY`, `COLLIE_JIRA_PARENT_KEY` (the parent task reports are
   created under), `COLLIE_JIRA_SUBTASK_TYPE` (the actual subtask type name in Jira),
   `COLLIE_JIRA_ASSIGNEE` (the user every subtask is assigned to), `COLLIE_ENVIRONMENT`.
   The Info.plist mapping is ready in the comment at the top of the template.
   ⚠️ In release/prod configs `COLLIE_ENABLED` is undefined or `NO`; the PAT lives only
   in non-prod secrets.
4. **Start:** call `CollieIntegration.start()` at app startup (AFTER Olaf, if Olaf is
   used).
5. **Olaf bridge (if the host uses Olaf):** uncomment the block in the template —
   `logSnapshotProvider` (Olaf.snapshot → CollieLogEntry mapping), `sessionIDProvider`,
   `diagnostics`; also add `config.captureExclusionFragments` to Olaf's
   `OlafNetworkConfiguration.excludedURLs` (recursion prevention, 2nd safeguard).
6. **Verify:**
   - Take a screenshot in the simulator (⌘S) → the banner must appear; submit the form →
     a subtask must exist in Jira under `COLLIE_JIRA_PARENT_KEY` with `screenshot.jpg` +
     `collie-logs-*.json` attachments and the correct assignee.
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
  - The screenshot is rendered with `drawHierarchy(afterScreenUpdates: true)` (the
    secure-field mask depends on it).
  - No PII (IP/SSID/location) is ever added to telemetry.
- Jira assumption: Server/DC (REST v2, PAT Bearer, `assignee.name`, wiki markup).
  Cloud (v3/ADF) is out of scope; if added, isolate it inside
  `JiraClient`/`JiraIssueBuilder`.
- Language: all code comments, docs, and commit messages are in English.
