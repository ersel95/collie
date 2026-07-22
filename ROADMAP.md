# Collie — Roadmap

> Collie is the standalone redevelopment, as its own Swift package, of the
> "take a screenshot → report it" (bug-reporter) mechanism that used to live inside the
> Olaf package.
>
> **Architecture change:** The old flow was device → Olaf backend (`POST /reports`) →
> panel frontend → (from the analyst's browser) Jira. In Collie the backend and frontend
> are removed: **the device creates the issue in Jira and uploads the attachments
> directly.** Reference code for what the backend/frontend used to do lives in the
> One4All project:
> - Issue content generation: `One4All/Backend/Vx-Hub-Backend/src/olaf/jira/jira-issue.builder.ts`
> - Jira REST calls: `One4All/Frontend/Frontend/src/services/api/olaf/jira-client.ts`
> - Push flow (create → attach order): `One4All/Frontend/Frontend/src/services/api/olaf/jira.ts`
>
> The final state of the device-side code is in Olaf git history: **`5aeadd1^`**
> (recovery: `git -C ../Olaf show '5aeadd1^:Sources/OlafUpload/OlafUploader.swift'` etc.)
> Reference document: `Olaf/docs/bug-reporter-summary.md`.

## Files to recover / adapt

| Source | Collie counterpart | Note |
|---|---|---|
| `OlafUpload.swift` (`5aeadd1^`) | `Core/Collie.swift` | Facade, `configure` |
| `OlafUploadConfiguration.swift` | `Core/CollieConfiguration.swift` | Fields change for Jira (below) |
| `OlafBugReportService.swift` | `Core/BugReportService.swift` | Produces a Jira issue instead of a payload |
| `OlafUploader.swift` | `Core/JiraClient.swift` | HTTP skeleton kept, target becomes Jira REST |
| `OlafUploadQueue.swift` | `Core/UploadQueue.swift` | Adapted to the two-step (create+attach) job |
| `OlafRemoteConfig.swift` | — | **Removed** (no backend; see Open Questions #2) |
| `OlafReportPayload.swift` | `Core/JiraIssueBuilder.swift` | Swift port of `jira-issue.builder.ts` |
| `OlafTelemetry.swift` | `Core/Telemetry.swift` | As is |
| `OlafDeviceIdentity.swift` | `Core/DeviceIdentity.swift` | As is (+ KeychainStore) |
| `ScreenshotDetector.swift` (OlafUI) | `UI/ScreenshotDetector.swift` | As is |
| `BugReportBanner.swift` | `UI/BugReportBanner.swift` | As is |
| `BugReportSheet.swift` | `UI/BugReportSheet.swift` | As is |
| `BugReportComposer.swift` | `UI/BugReportComposer.swift` | As is |
| `BugReportToast.swift` | `UI/BugReportToast.swift` | As is |
| `jira-issue.builder.ts` (One4All) | `Core/JiraIssueBuilder.swift` | TS → Swift port |
| `Tests/OlafUploadTests/*` (5 files) | `Tests/CollieTests/*` | Payload tests become issue-builder tests |

## Phase 0 — Project skeleton

- [x] SPM package: `Collie`, iOS 17 / macOS 14 (same as Olaf), `StrictConcurrency` on.
- [x] Follow Olaf's current structure: **single target**, UIKit-dependent parts behind
      `#if canImport(UIKit)` (the core also compiles/tests on macOS).
- [x] **Olaf dependency decision (critical):** Collie must NOT depend on Olaf. The host
      app attaches provider closures: `logSnapshotProvider` (log entries),
      `sessionIDProvider`. Collie thus works standalone; Olaf stays optional.
      NOTE: since the issue builder derives the network/navigation sections from log
      entries, the provider must supply **structured entries** rather than raw `Data`
      (see Phase 3, "view derivation").
- [x] git init, LICENSE, README draft, CHANGELOG.

## Phase 1 — Code recovery and renaming

- [x] Extract the device-side files from `5aeadd1^`, rename the `Olaf` prefix to `Collie`.
- [x] Convert direct Olaf references to providers; `Olaf.log(...)` calls → an optional
      diagnostics closure.
- [x] The old `setDetectorInstaller` hook existed for two separate targets
      (OlafUpload/OlafUI); simplify in single-target Collie: once
      `configure(enabled: true)` succeeds, install the detector directly under
      `#if canImport(UIKit)`.

## Phase 2 — Core engine (UIKit-free)

Design decisions to preserve (the ones from the summary document §4 still applicable):

- [x] **Opt-in + fail-closed:** local `enabled` (default off, from xcconfig). For the
      new counterpart of gate 2 (the old server `captureEnabled`) see Open Questions #2.
- [x] **Recursion prevention:** JiraClient uses its own ephemeral `URLSession` with
      `protocolClasses = []`. The host adds the Jira base URL to Olaf's
      `OlafNetworkConfiguration.excludedURLs` (documented in INTEGRATION.md; Olaf no
      longer has a runtime exclusion API).
- [x] **Offline resilience:** disk queue (`Caches/Collie/uploads/`, `.atomic` +
      `.completeFileProtection`), exponential backoff (`5s * 2^attempt`, max 5),
      permanent 4xx / transient 5xx-network distinction (408/429 transient),
      **48-hour TTL**, idempotent `drain()`.
- [x] **Queue adapted to the two-step job (new):** one report = 1× issue create + N×
      attachments. If the create succeeds but an attachment is left unfinished, the
      retry **must not open a new issue** — `issueKey` is written to the envelope and
      drain resumes from the remaining step.
- [x] **Identity:** Keychain UUID (`kSecAttrAccessibleAfterFirstUnlock`), tester name
      asked once, stored in the Keychain.
- [x] **Telemetry:** no PII (no IP/SSID/location); `prepare()` early start,
      NWPathMonitor cache, mach `phys_footprint`.
- [x] New `CollieConfiguration` fields — **all Jira settings parametric, provided by the
      host project at `configure` time** (nothing project/person-specific embedded in
      Collie):
      - `jiraBaseURL`, `pat` (see Open Questions #1)
      - `projectKey`
      - `parentIssueKey` — **every report is created as a subtask under this task** (required)
      - `subtaskIssueType` — the subtask type's name (default `"Sub-task"`; whatever the
        actual name is in the installation, e.g. "Alt görev")
      - `assigneeUsername` — **every subtask is always assigned to this person** (required)
      - `defaultLabels`, `appDisplayName` (the `[AppName]` summary prefix), `environment`
      - `maxScreenshotBytes` (now fully local; Jira's attachment limit is usually 10 MB),
        timeout/retry settings
      - Validation: if required fields are blank at `configure` time → fail-closed
        (log + disabled). `parentIssueKey` must be in the same project as `projectKey`
        (Jira otherwise returns 400) — noted in INTEGRATION.md.

## Phase 3 — Jira integration (new layer)

Reference: `jira-client.ts` + `jira.ts` + `jira-issue.builder.ts` (One4All).

- [x] **`JiraClient`** (evolution of the old Uploader):
      - `POST {base}/rest/api/2/issue` — JSON `{ fields }` → `{ key, id }`.
      - `POST {base}/rest/api/2/issue/{key}/attachments` — multipart `file` part,
        the **`X-Atlassian-Token: no-check`** header is mandatory.
      - Auth: `Authorization: Bearer <PAT>` (Jira Server/DC).
      - Attachments: `screenshot.jpg` (JPEG) + `collie-logs-{uuid}.json` (raw log
        entries — the new home of the old payload's `entries`).
- [x] **`JiraIssueBuilder`** (Swift port of `jira-issue.builder.ts`):
      - Summary: `[AppName] {first line of whatHappened}`, capped at 250 characters.
      - Description (wiki markup, h3 sections): Reporter (name, device) · Environment
        (iOS, app version/build, environment, locale) · What happened? · What was
        expected? · Navigation (timestamped screen list) · Network (failure/4xx-first
        ordering, **top 15 requests**, request/response bodies in `{code}` blocks for
        failures, the rest as "+N more in attached JSON") · Logs (category counts).
      - **`wikiEscape`**: escape control characters against markup injection
        (`{}[]|*_-#!?+^~`); break the `{code}` literal inside `{code}` content.
      - Fields: `project.key`, `issuetype.name` (= `subtaskIssueType`), `summary`,
        `description`, **`parent.key`** (= `parentIssueKey`, always set — a report is
        always a subtask), **`assignee.name`** (= `assigneeUsername`, always set),
        optional `labels`. Everything comes from the config; no selection UI on device.
- [x] **View derivation:** Collie takes over what the backend's `report-parser` did —
      the Navigation view (screen-tracking entries) and the Network view
      (method/url/status/duration/error/bodies) are derived from log entries. The
      provider contract is designed to carry these fields.
- [x] **Error classification for Jira:** 401 (invalid PAT) permanent + a meaningful
      user message; 400 (field error) permanent; connection errors without VPN
      transient → queue.
- [x] The returned `{base}/browse/{issueKey}` URL can be surfaced in the toast/log.

## Phase 4 — UI layer

- [x] `ScreenshotDetector`: `userDidTakeScreenshotNotification` → render the key window
      via `drawHierarchy(afterScreenUpdates: true)` (the only way the secure-field mask
      actually works); Collie's own windows (`windowLevel >= .alert`) excluded.
- [x] `BugReportBanner`: separate `UIWindow` (`.alert + 1`) + PassthroughView (the app
      stays interactive), 6s auto-dismiss, [Yes] → formSheet.
- [x] `BugReportSheet`: SwiftUI form — preview + informed-consent warning, name on
      first use, "What happened?" / "What was expected?", `@FocusState` field order,
      keyboard toolbar, scrolling the focused field above the keyboard,
      `interactiveDismissDisabled` while submitting, error → inline banner + retry.
- [x] `BugReportComposer`: progressive JPEG compression (0.7→0.2, steps of 0.15) +
      dimension downscaling if needed (×0.7, min 320pt) — until under `maxScreenshotBytes`.
- [x] `BugReportToast`: temporary window at `alert + 2`, fades after 2s. The issue key
      can be shown on success ("PROJ-123 created").
- [x] **VPN UX (new):** Corporate Jira is reachable only over VPN. On a send failure,
      a "check your VPN" hint + a "queued, will be sent once connected" message.

## Phase 5 — Integration and documentation

- [x] The `Integration/CollieIntegration.swift` template + xcconfig/Info.plist keys:
      `COLLIE_ENABLED`, `COLLIE_JIRA_BASE_URL`, `COLLIE_JIRA_PROJECT_KEY`,
      `COLLIE_JIRA_PARENT_KEY`, `COLLIE_JIRA_SUBTASK_TYPE`, `COLLIE_JIRA_ASSIGNEE`,
      `COLLIE_JIRA_PAT` (never enters the repo), `COLLIE_ENVIRONMENT`.
      Each integrating project thus defines its own parent task / assignee in its own
      xcconfig; nothing is embedded in Collie's code.
- [x] `INTEGRATION.md`: setup, usage together with Olaf (provider wiring + the
      excludedURLs step), the VPN prerequisite, troubleshooting.
- [x] `PrivacyInfo.xcprivacy`: a real data-collection declaration is required since the
      device UUID + screenshot + telemetry are collected (different from Olaf's).
- [x] README + CHANGELOG.

## Phase 6 — Tests and hardening

- [x] Migrated tests: `ConfigurationTests`, `MultipartBodyTests` (adapted to the
      attachment multipart), `OptInGateTests`; `ReportPayloadTests` →
      `JiraIssueBuilderTests` (summary cap, wikiEscape, network top-15 ordering,
      category counts — matching the TS builder's behavior exactly; verification that
      `parent.key` and `assignee.name` come from the config on every issue),
      `RemoteConfigTests` → removed; config validation tests (fail-closed when required
      Jira fields are missing).
- [x] New tests: UploadQueue two-step resume (no duplicate issue on attachment retry
      after a create), backoff/TTL/restart drain, Jira error classification (401/400
      permanent, network transient), Composer compression loop, working without providers.
- [x] Core compile/tests on macOS, StrictConcurrency cleanliness.
- [ ] End-to-end on a real device (on VPN): screenshot → banner → form → issue +
      attachments in Jira; the queue scenario with VPN off.

## Open questions

1. **PAT strategy (most critical):** In the panel every analyst entered their own PAT in
   the browser. On device the options are: (a) a **service-account PAT** embedded into
   the build via xcconfig — simple, but a secret is embedded into an internal build;
   issues are created from a single account (the tester name is in the description
   anyway). (b) Every tester enters their own PAT on first use, stored in the Keychain
   — safer but testers need Jira accounts/PATs. Recommendation: start with (a) (risk is
   limited since it's only compiled into non-prod builds), keep (b) as an option.
2. **Kill switch (old gate 2):** The backend `GET /config` is gone. Options: settle for
   the local gate only; or preserve fail-closed behavior with an optional
   `remoteConfigURL` (a static JSON hosted anywhere). Recommendation: local gate only in
   v1; keep the field optional in the config.
3. **Jira version assumption:** The code targets Jira Server/DC (REST v2, PAT Bearer,
   `assignee: {name}`, wiki markup). Moving to Jira Cloud would require API v3 + ADF +
   Basic auth — out of scope for v1, but write JiraClient so it isolates this.

> ~~#4 Issue type / assignee selection~~ — decided: every report is created as a subtask
> under the configured `parentIssueKey` and assigned to `assigneeUsername`. All of these
> values are set by the integrating project at init time (xcconfig → `configure`);
> there is no selection UI on the device.
