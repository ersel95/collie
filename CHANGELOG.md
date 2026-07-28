# Changelog

## 1.9.0 — 2026-07-28

### Changed
- **Markup is now the system editor.** 1.8.0 drew on a hand-built PencilKit canvas: it
  depended on `PKToolPicker` appearing over Collie's own window, and even when it did it
  offered strokes only. The screenshot preview now opens **QuickLook in editing mode** —
  the same markup screen iOS shows for a screenshot, with the full palette *and* the "+"
  tools (text, shapes, signature, magnifier, opacity). The edits are saved back over a
  temporary PNG, which the form reloads; the rest of the flow is unchanged.

  Tapping the preview opens QuickLook's preview page first — the markup button is in its
  navigation bar, and the hint under the preview now points at it.

## 1.8.0 — 2026-07-28

### Added
- **Screenshot markup.** Tapping the screenshot preview in the report form opens a
  full-screen PencilKit editor with the system tool picker — pen, marker, eraser, colours,
  undo — and finger drawing enabled, since test devices rarely have an Apple Pencil.
  **Save** flattens the strokes into the screenshot at its native pixel size and the flow
  continues with that image; **Cancel** discards them. Testers can circle the problem
  instead of describing where on the screen it is.

## 1.7.0 — 2026-07-28

### Added
- **`CollieConfiguration.activatesOnShake`** (default `true`). Set it to `false` when
  another shake-activated tool owns the gesture: Collie then installs no shake detector
  and is reached only through `Collie.presentReport()` — typically that tool's logo
  hand-off. Previously both tools answered the same shake and Collie's banner opened
  underneath the other tool's full-screen UI, where it timed out unseen.

  Telemetry preparation moved ahead of the gate, so a hand-off still carries battery and
  network state on the very first report.

## 1.6.0 — 2026-07-28

### Added
- **`Collie.presentReport()`** — opens the report form directly, skipping the
  "Spotted a problem?" question. Use it when the tester has already chosen to report,
  which is the case when handing off from another diagnostics tool via `onLogoTap`:
  they tapped the Collie logo inside that tool, so asking them again is a dead click.
  A shake still honours `asksBeforeReporting`, because a shake can be accidental.
  No-op when the reporter is off, capture is disabled, or the Collie UI is already up.

## 1.5.1 — 2026-07-28

### Fixed
- **Releases have been failing silently since 1.1.0.** The Release workflow ran on
  `macos-14`, whose default toolchain is Swift 5.10 — it cannot parse the `sending`
  keyword that firebase-ios-sdk uses, so `swift test` died as soon as `CollieFirebase`
  entered the build graph. Every tag from 1.1.0 to 1.5.0 exists but never produced a
  GitHub release. The workflow now runs on `macos-15` with the latest stable Xcode (and
  prints the toolchain, so a repeat is visible in the log).
  Note this only affected the published release notes: SPM resolves by tag, so hosts
  pinning those versions were unaffected.

## 1.5.0 — 2026-07-28

### Changed
- **Documentation now covers the Firebase transport.** `CollieFirebase` shipped in 1.1.0,
  but every integration document still described only the HTTPS upload — so anyone
  following them (or any agent reading them) wired up keys the Firebase path does not
  use and never set the one it needs. `Integration/CollieIntegration.swift`,
  `INTEGRATION.md`, `AGENTS.md` and `README.md` now present both transports side by side:
  which one to pick, the keys each requires (`COLLIE_APP_KEY` vs
  `COLLIE_API_BASE_URL` + `COLLIE_API_KEY`), the Firebase prerequisites, the
  screenshot-in-Firestore constraint and the matching troubleshooting rows.

## 1.4.0 — 2026-07-28

### Changed
- **The screenshot preview moved below the input fields.** It used to sit at the top, so
  on smaller devices the keyboard covered the text field the tester was meant to fill in.
  The inputs now come first and the thumbnail follows.
- **Removed the "About the screenshot" consent notice.** ⚠️ The warning told testers that
  the image captures everything on screen (balances, account details) and to leave the
  screen first if that was a problem. Removing it is a deliberate product decision — if
  the host app shows sensitive data, that responsibility now sits entirely with whoever
  briefs the testers.

## 1.3.0 — 2026-07-28

### Changed — BREAKING
- **The report form is down to a single field.** "What was expected?" is gone; a tester
  now only describes what happened. Reporting the actual behaviour is the part that
  carries information — the expected behaviour was usually a restatement of it, and
  making it mandatory doubled the effort of filing a report.
  - `BugReportService.sendReport(whatHappened:testerName:screenshotJPEG:identity:telemetry:)`
    no longer takes `whatExpected`.
  - The upload envelope's `report` object drops `whatExpected` accordingly.
  - Send is enabled as soon as the description (and, on first use, the name) is filled.

## 1.2.0 — 2026-07-28

### Changed — BREAKING (CollieFirebase only)
- **Screenshots go to Firestore, not Cloud Storage.** Cloud Storage requires a paid
  Firebase plan; on the free tier it is unavailable, so the previous release stranded
  every screenshot at the upload step. The JPEG is now base64-encoded into its own
  document (`collie_report_screenshots/<reportID>`), keyed by the report id so a retry
  overwrites rather than duplicates. Keeping it out of the report document means listing
  reports never drags image data along.
  - `FirestoreTransport.Configuration`: `storagePrefix` → `screenshotCollection`, plus a
    new `maxScreenshotBytes` (default 650 KB). Firestore caps a document at 1 MiB and
    base64 inflates by ~33%, so a larger image is dropped — with the reason recorded on
    the report — instead of failing the whole submission.
  - `CollieFirebase` no longer links `FirebaseStorage`.
  - The report document now carries `hasScreenshot: Bool` instead of `screenshotPath`.

## 1.1.1 — 2026-07-28

### Fixed
- **`CollieFirebase` could not be resolved alongside a host that pins its own Firebase.**
  The dependency was declared `from: "11.0.0"`, which means `11.0.0..<12.0.0`, so an app
  already on Firebase 12.x failed to resolve ("root depends on firebase-ios-sdk 12.13.0"
  vs "collie depends on 11.x"). It is now a wide `11.0.0..<14.0.0` range — the Firestore
  and Storage APIs used are stable across those majors, and the host keeps deciding the
  exact version.

## 1.1.0 — 2026-07-28

### Added
- **`CollieFirebase` product — send reports to Firebase instead of your own endpoint.**
  Some hosts may only talk to a fixed set of destinations: a banking app allowed to reach
  Firebase and its own API, and nothing else. `FirestoreTransport` writes the report to
  Firestore and the screenshot to Cloud Storage, so Collie works inside that policy.
  - The queue's report id becomes the Firestore **document id**, so a retry after a lost
    response overwrites the same document instead of creating a second report — the same
    guarantee the HTTPS transport gets from its idempotency header.
  - The envelope is stored decoded (not as a blob), so `app` / `device` / `report` /
    `entries` / `telemetry` stay queryable. Entries remain lossless.
  - The kill switch reads `collie_config/<appKey>.captureEnabled`; a missing document
    means capture stays on, matching the HTTPS transport's fail-open behaviour.
  - Firestore/Storage errors are classified for the queue: permission, quota and
    argument failures are permanent (dropped), everything else is retried.
  - Only this product depends on `firebase-ios-sdk`; the core `Collie` library stays
    dependency-free.

### Changed
- `ReportTransport`, `CollieOperationResult` and `CollieRemoteConfig` are now **public**,
  and `Collie.configure(with:transport:)` accepts a custom transport. Hosts can plug in
  their own destination without forking the SDK.
- When a custom transport is supplied, the `apiKey` / `apiBaseURL` validation is skipped —
  that transport carries its own destination and credentials.

## 1.0.0 — 2026-07-28

### Changed — BREAKING: the device no longer talks to Jira

Reports now go to the **Collie backend**, and an analyst pushes them to Jira from the
panel. The device carries no Jira credentials at all, and reports are triaged before they
reach the tracker.

- **Configuration.** All Jira fields are gone — `jiraBaseURL`, `pat`, `projectKey`,
  `parentIssueKey`, `subtaskIssueType`, `assigneeUsername`, `defaultLabels`,
  `maxNetworkAttachments`, `appDisplayName` and the `labels(fromCommaSeparated:)` helper.
  In their place: `apiBaseURL`, `apiKey`, and the overridable `reportsPath` / `configPath`.
  Integration keys change accordingly: `COLLIE_JIRA_*` → `COLLIE_API_BASE_URL` +
  `COLLIE_API_KEY`.
- **Transport.** `JiraClient` → `IngestionClient`: one multipart `POST` per report
  (`report` JSON part + optional `screenshot` part, `x-collie-api-key` header) instead of
  an issue create followed by N attachment uploads.
- **Payload.** `JiraIssueBuilder` (wiki-markup description) → `ReportEnvelopeBuilder`,
  which emits the backend's ingestion contract: `app` / `device` / `report` / `entries` /
  `telemetry`, ISO-8601 dates, no app key (the backend resolves the app from the api-key).
  Log entries travel raw and lossless; the panel derives the Network and Navigation views
  the description used to render.
- **Per-request `net-*.txt` attachments** are no longer built on the device. The panel
  generates them from the uploaded log stream when pushing to Jira, so the SDK no longer
  performs one upload per captured request.
- **Outcome.** `CollieSubmitOutcome.sent(issueKey:)` → `.sent(reportID:)`; the success
  toast reads "Report sent" instead of naming an issue key.

### Added
- **Remote kill switch.** At startup Collie calls `GET <configPath>` and honours the
  app's `captureEnabled` flag from the panel — capture can be turned off without a new
  build. The check **fails open** when the backend is unreachable, so a tester without
  VPN can still file a report and have it queued.
- **Idempotent retries.** The queued report's id travels as `x-collie-idempotency-key`
  and is reused on every retry, so a response lost in transit cannot produce a second
  report. This replaces the old "issue already created, resume from the attachment step"
  duplicate prevention.

### Removed
- `JiraClient`, `JiraIssueBuilder`, `NetworkAttachmentBuilder` / `CollieAttachment` and
  their tests. `ReportEnvelopeTests` and `IngestionClientTests` cover the new contract.

## 0.6.1 — 2026-07-23

### Fixed
- **Dashes and question marks no longer render as HTML entities.** Jira turns a
  backslash escape into a numeric entity outside table cells, so the Network section's
  host line came out as `apigateway&#45;adc.tst.yapikredi.nl`. Escaping is now limited to
  the characters that can actually break the document — `{`, `}`, `[`, `]`, `|`, `!` —
  and inline-style characters (`-`, `*`, `_`, `+`, `^`, `~`, `#`, `?`) travel as typed.
  This also cleans up every "What happened?" panel that contained a dash or a question
  mark. Empty cells now show a plain `-` instead of an escaped one.

## 0.6.0 — 2026-07-23

### Changed
Jira sizes a table's columns by their widest cell, so one long value used to squeeze
every other column into a vertical letter-stack ("M/e/t/h/o/d"). Both tables now keep
their cells short — the full values are still in the log JSON and the per-request files.

- **Network:** the host shared by all requests is hoisted above the table
  (`*Host:* https://api.example.com`) and rows carry only the path. With requests
  spread over several hosts the full URLs stay (a bare path would be ambiguous).
  Over-long paths are cut in the middle, keeping the distinguishing tail.
- **Network:** the `File` column now shows a short link label (`net-003`) instead of the
  full attachment name; the link still points at `net-003-GET-500-v1-users.txt`.
- **Network:** the `URL` column header is now `Path`.
- **Navigation:** the `Screen` column drops the payload an enum/case dump drags along
  (`accounts-transactions(screens: …DTO(iban: …))` → `accounts-transactions`) and caps
  the name at 60 characters. A `navigationTitle` (or `title`) metadata key, when the
  host provides one, wins over the raw screen id.
- **Navigation:** the `Transition` column header is now `Kind`.

## 0.5.0 — 2026-07-23

### Changed
- **The yes/no banner is back under explicit control.** Since 0.3.0 a shake skipped the
  "Spotted a problem?" question whenever `Collie.onLogoTap` had a handler — an implicit
  rule that silently changed the flow as soon as a project wired tool switching. The
  decision is now a single explicit setting, `CollieConfiguration.asksBeforeReporting`
  (default `true` → ask first; `false` → open the report sheet directly), and the logo
  handler no longer affects shake behavior at all.

## 0.4.0 — 2026-07-23

### Added
- **One attachment per network request.** Next to the (unchanged, still complete)
  `collie-logs-*.json`, every captured request is uploaded as its own plain-text file —
  `net-001-POST-500-v1-payments.txt` — containing the summary line, request/response
  headers, and the **full, never truncated** bodies.
- The description's Network table has a new **`File`** column linking to that attachment
  (`[^net-001-…txt]`), so a single request can be downloaded straight from the table.
- `CollieConfiguration.maxNetworkAttachments` (default `50`, `0` disables): caps how many
  per-request files are uploaded, since each one is a separate upload. Requests past the
  cap keep their table row (without a link) and stay in the log JSON.
- **`Customer no` row** in the Report table: any log entry (any category) carrying a
  `customerNo` metadata key feeds it, newest non-empty value wins — so a report shows
  which account was signed in. Hosts log it on their sign-in paths
  (`Olaf.info("Signed in", category: .auth, metadata: ["customerNo": customerNo])`).
  The row is omitted when nothing logs the key.

### Changed
- The network table is no longer capped at 15 rows — every request is listed (safety
  ceiling 200) so each row can point at its file. Inline `{code}` failure bodies below
  the table are now limited to the first 10 failures; the rest are one click away in
  their own attachment.
- Report table split into single-fact rows: `Device` / `iOS version` / `App` /
  `Version` (version + build) / `Environment` were previously merged into two rows.
- `Locale` row is now `Language`, showing the English language name next to the code
  (`tr_TR` → `Turkish (Türkiye) (tr_TR)`).
- `Collie initialized` renamed to `Session started` (both the description row and the
  synthetic log entry).
- The upload queue tracks each network file's own `done` flag: a transient failure
  re-uploads only what is missing, and still never re-creates the issue.

## 0.3.0 — 2026-07-23

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
