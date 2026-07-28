# Collie — Agent Guide

Collie: an SPM bug-reporter package for iOS test builds — shake → banner → form →
**a report in the analyst panel**. An analyst triages it there and pushes it to Jira,
choosing the issue type, parent, assignee and labels. A screenshot is captured
automatically at shake time and uploaded with the report, together with the full log
stream fed from the host's logging library (any source).

**Two transports, one destination.** `Collie` uploads over plain HTTPS
(`IngestionClient`); the separate **`CollieFirebase`** product writes to Firestore
(`FirestoreTransport`) for hosts whose network policy only allows Firebase — a
server-side bridge then moves those reports into the same panel. The host picks one via
`Collie.configure(with:transport:)`. Only `CollieFirebase` depends on `firebase-ios-sdk`;
the core stays dependency-free.

**The device never talks to Jira.** No PAT, project key, parent key or assignee exists
on the device — those decisions belong to the panel.

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
3. **Provide the keys** (xcconfig → Info.plist chain; secrets NEVER enter the repo):
   - Firebase path: `COLLIE_ENABLED`, `COLLIE_APP_KEY` (the app record's `key` from
     Admin · Apps — **not** a secret; write access is enforced by Firestore rules).
     Requires `GoogleService-Info.plist` and `FirebaseApp.configure()` before Collie starts.
   - HTTPS path: `COLLIE_ENABLED`, `COLLIE_API_BASE_URL`, `COLLIE_API_KEY` (a real secret).
   The Info.plist mapping is ready in the comment at the top of the template.
   ⚠️ In release/prod configs `COLLIE_ENABLED` is undefined or `NO`; the api-key lives
   only in non-prod secrets.
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
   The handler does not change shake behavior — that is `config.asksBeforeReporting`
   (default `true`: ask first; `false`: open the report sheet directly).
7. **Verify:**
   - Shake the device (simulator: Device → Shake, ⌃⌘Z) → the banner must appear (the
     report sheet directly, when `asksBeforeReporting` is `false`); submit
     the form → the report must show up in the panel's Reports list with its screenshot,
     the full log stream, and the derived network/navigation views.
   - If the banner doesn't appear: check the `config.diagnostics` output — when a
     required field is blank, Collie stays silently off (fail-closed). The banner also
     stays hidden when the panel has flipped the app's `captureEnabled` kill switch off.
   - A corporate backend is often reachable only over VPN; without VPN a submission
     becomes "Queued" and is retried via `Collie.flushPendingUploads()`.

Common errors are in the table in `INTEGRATION.md` §7 (401 → api-key, 400 → payload
validation).

## Development (this repo)

- Structure: single target. `Sources/Collie/Core/` is UIKit-free (compiles/tests on
  macOS), `Sources/Collie/UI/` sits behind `#if canImport(UIKit)`.
- Tests: `swift test` (runs on macOS). iOS compile check:
  `swift build --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --sdk iphonesimulator --show-sdk-path)`
- Behaviors that MUST be preserved (do not make breaking changes):
  - Opt-in + fail-closed: `enabled` defaults to `false`; a blank required field
    (`apiKey`, `apiBaseURL`, endpoint paths) means nothing is installed.
  - Two capture gates: the local build-time opt-in **and** the server-side kill switch
    (HTTPS: `GET <configPath>`; Firebase: `collie_config/<appKey>.captureEnabled`). The
    remote check **fails open** when unreachable — a tester offline must still be able to
    file a report and have it queued.
  - Recursion prevention: `IngestionClient` uses its own session with `protocolClasses = []`.
  - Queue idempotency: the envelope id is reused on every retry — as the
    `x-collie-idempotency-key` header (HTTPS) or as the Firestore document id (Firebase) —
    so a response lost in transit cannot create a second report (`UploadQueueTests`).
  - The screenshot is rendered at shake time with `drawHierarchy(afterScreenUpdates: true)`
    (the secure-field mask depends on it).
  - Shake detection swizzles `UIWindow.motionEnded` and always calls the original
    implementation (it must compose with other tools that swizzle the same selector).
  - ALL provided log entries are uploaded in full, with their categories preserved and
    nothing summarized or truncated — the panel derives its network/navigation views
    from that raw stream, so it must stay lossless.
  - The upload envelope is the backend's ingestion contract
    (`ReportEnvelopeBuilder`): `app` / `device` / `report` / `entries` / `telemetry`,
    ISO-8601 dates, and **no app key** (the backend resolves the app from the api-key).
    `ReportEnvelopeTests` locks the shape in.
  - Core stays log-source agnostic: no logging-library types or names in `Sources/`
    (concrete bridges live only in docs and the integration template).
  - No PII (IP/SSID/location) is ever added to telemetry.
- Backend assumptions:
  - HTTPS — `POST <reportsPath>` (multipart: `report` JSON part + optional `screenshot`
    part, `x-collie-api-key` header) and `GET <configPath>`; both overridable via
    `CollieConfiguration`.
  - Firebase — `collie_reports/<reportId>` (envelope decoded, plus `appKey`, `status`,
    `hasScreenshot`), the screenshot base64 in `collie_report_screenshots/<reportId>`
    (Cloud Storage needs a paid plan, so it is NOT used), and the kill switch in
    `collie_config/<appKey>`. Collections are overridable via
    `FirestoreTransport.Configuration`. Rule templates: `Integration/firestore.rules`.
- Language: all code comments, docs, and commit messages are in English.
- Releasing: add a `## <version> — <date>` section to `CHANGELOG.md`, commit, then
  `git tag <version> && git push origin <version>` (plain semver, no `v` prefix).
  The `Release` workflow (`.github/workflows/release.yml`) runs the tests, builds for
  the iOS simulator, and publishes the GitHub release with that CHANGELOG section as
  its notes — it fails if the section is missing.
