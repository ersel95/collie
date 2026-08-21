# Collie — Agent Guide

Collie: an SPM bug-reporter package for iOS test builds — shake → banner → form →
**a report in the analyst panel**. An analyst triages it there and pushes it to Jira,
choosing the issue type, parent, assignee and labels. A screenshot is captured
automatically at shake time; in the form the tester can mark it up, remove it, and add up
to four more — either from their photo library or by walking back through the app in
**screenshot mode**, photographing each screen that matters. All of them are uploaded with
the report, together with the full log stream fed from the host's logging library (any
source).

**Two transports, one destination.** `Collie` uploads over plain HTTPS
(`IngestionClient`); the separate **`CollieFirebase`** product writes to Firestore
(`FirestoreTransport`) for hosts whose network policy only allows Firebase — a
server-side bridge then moves those reports into the same panel. The host picks one via
`Collie.configure(with:transport:)`. Only `CollieFirebase` depends on `firebase-ios-sdk`;
the core stays dependency-free.

**The device never talks to Jira.** No PAT, project key, parent key or assignee exists
on the device — those decisions belong to the panel.

**Two platforms, one repository.** The Swift package is at the repository root; the Android
port lives in [`Android/`](Android/) and ships on its own version line (`android-*` tags,
which SPM ignores). They share the product decisions and the upload envelope, so a report is
the same document whichever device filed it. Releasing either: [`RELEASING.md`](RELEASING.md).

## Where to start, by task

| Task | Read |
|---|---|
| **Integrating Collie into an iOS host app** | The "Integration" section below + `INTEGRATION.md` (details and troubleshooting) + `Integration/CollieIntegration.swift` (template to copy) |
| **Anything Android** | [`Android/AGENTS.md`](Android/AGENTS.md) — layout, commands, and the behaviours that must be preserved there |
| Developing Collie itself (iOS) | The "Development" section below |

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
- **Changing the UI? Run it.** `Examples/CollieHarness` is a one-button host app that links
  this checkout and calls `Collie.presentReport()`, so the banner/form/markup can be driven
  on a simulator (a shake cannot be triggered from a script). Its README has the xcodegen +
  simctl + UI-automation commands. Two markup implementations shipped broken because they
  were only compile-checked — a compiling UI is not a working one.
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
  - **Screenshot mode** (`ScreenshotModeOverlay`) is the second way in, and it only works
    because the app underneath stays usable: the tester leaves the form, navigates the host
    app, and taps the shutter on the screen worth reporting. **One tap, one picture, back to
    the report** — staying in the mode would leave a counter in the corner as the only
    confirmation, so the tester would not know what they had attached until they left. Three
    things make the mode hold, and all three have already been got wrong once:
    - `PassthroughWindow` returns `nil` from `hitTest` for a point nothing on Collie's layer
      wants. A `UIWindow` is a `UIView`, so without this it answers "mine" for every touch
      its content declined, and the app below is frozen — which is what the banner's
      "the app stays interactive" comment claimed for a long time without it being true.
    - The overlay declines those points itself, the same way, so only its bar and its
      shutter take touches.
    - The form's state lives in `BugReportBanner.draft`, not in the form: the sheet is
      dismissed on the way into the mode and rebuilt on the way out. A reporter that loses
      the tester's sentence when they go and photograph the bug gets used once.
    The mode needs no cooperation from `ScreenRenderer` — that only ever draws windows below
    `.alert`, and Collie's overlay sits above it, so the bar and shutter cannot appear in a
    capture.
  - The tester's name is asked **once**, in an alert on the first Send, and it explains why
    it is being asked — a name demanded with no reason given gets answered "a". It is kept in
    the Keychain (survives reinstall), with a `UserDefaults` fallback for builds the Keychain
    refuses: without the entitlement `SecItemAdd` fails, and it used to fail *silently*, so
    the question came back on every report.
  - **Every image leaves a marker in the log stream** (`CollieScreenshotEvent`): a `collie`
    entry at the moment it was taken, numbered by its position in the report as sent. Five
    pictures taken minutes apart are otherwise a row of thumbnails with no place in a
    timeline that is stamped to the second. Deleted images produce no marker, and a library
    image says "attached", not "captured" — it was taken at some earlier, unknown time.
  - A report carries **0 to 5 screenshots**: the shake-time capture plus whatever the tester
    attaches in the form. Two things hold that together and neither may move on its own.
    `screenshotCount` on the report document and the `_<index>`-suffixed screenshot document
    ids are ONE contract with the panel — it switches shapes on the count and then reads only
    the numbered ids, so writing one without the other hides every image with no error
    anywhere. And the ceiling (`CollieConfiguration.maxScreenshotsLimit`, 5) is the panel's
    `MAX_SCREENSHOTS`: raising it here alone uploads images nobody can open.
    `maxScreenshotBytes` is per image, never a total — each one gets a document of its own.
  - **The size the form compresses to is the size the destination accepts.** A transport with
    a hard limit of its own declares it (`ReportTransport.maxScreenshotBytes`) and
    `BugReportService.maxScreenshotBytes` takes the strictest of local config, server value
    and that. The two used not to know about each other: the config defaults to 4 MB and
    Firestore stores 650 KB, so a photo from the library was compressed to fit the first and
    then dropped by the second — report through, picture gone. Shake captures are small
    enough that nothing showed it.
  - Attaching an image uses `PHPickerViewController` (`ScreenshotPicker`), which runs out of
    process and therefore needs **no** photo-library permission. That is the same rule the
    telemetry permissions follow: Collie never raises a prompt, and a request without a usage
    description would crash the host outright.
  - Markup (`ScreenshotMarkupEditor`) is **one screen, in Collie's own window**: a
    `PKCanvasView` over the screenshot plus `MarkupPalette`, Collie's own tool/width/colour
    bar. One tap on the preview opens it, Done flattens the strokes into the screenshot at
    its native pixel size and returns. It only ever *replaces* the image held by the form, so
    the composer/queue/envelope keep seeing a single `UIImage` and stay markup-unaware; marks
    a tester draws to hide something must never travel separately from the pixels they cover.
    Two Apple-provided editors were tried and **must not be reintroduced without re-testing
    on device** (both verified broken on iOS 26, see the file's header comment): QuickLook's
    editing mode renders out of process, so it stalls on a blank page and hides its buttons
    from the host; `PKToolPicker` docks into the `UITextEffectsWindow` and is invisible under
    Collie's overlay window — and reordering the windows to fix that kills touch delivery to
    the overlay entirely.
  - Shake detection swizzles `UIWindow.motionEnded` and always calls the original
    implementation (it must compose with other tools that swizzle the same selector).
  - ALL provided log entries are uploaded in full, with their categories preserved and
    nothing summarized or truncated — the panel derives its network/navigation views
    from that raw stream, so it must stay lossless. Collie adds its own `category: "collie"`
    markers at their chronological positions and changes nothing else.
    The **one** exception is a hard platform limit, not a product decision:
    `FirestoreTransport.trimEntries` drops the OLDEST entries when a stream exceeds what a
    Firestore document can hold (1 MiB), because the alternative there is losing the whole
    report — the tester's words and screenshot with it. It is never silent: a `collie`
    marker heads the trimmed stream and `entriesTrimmed` counts it on the report document.
    Nothing else may trim, and the HTTPS path never does.
  - The upload envelope is the backend's ingestion contract
    (`ReportEnvelopeBuilder`): `app` / `device` / `report` / `entries` / `telemetry`,
    ISO-8601 dates, and **no app key** (the backend resolves the app from the api-key).
    `ReportEnvelopeTests` locks the shape in.
  - Session context (`CollieSessionTracker`) — the fields the panel folds a report's
    repeated history with, because testers never kill the app and the tenth report
    otherwise repeats the first nine. Three rules hold it together:
    - `report.previousReportAt` / `sessionStartedAt` / `processStartedAt` / `sessionOrdinal`
      / `sequence` are **optional** and stay that way; a report without them must render
      exactly as it did before they existed, which is what keeps older SDKs working.
    - Every timestamp carries a UTC offset. The boundary is found by *comparing*
      `previousReportAt` with entry timestamps, so a stamp without one is read in the
      browser's timezone and slides the fold by hours.
    - `sequence` / `sessionOrdinal` / `previousReportAt` are persistent (`UserDefaults`) and
      survive a kill; `processStartedAt` is the one field that resets with the process. The
      background threshold that ends a logical session **must equal Android's**.
  - Core stays log-source agnostic: no logging-library types or names in `Sources/`
    (concrete bridges live only in docs and the integration template).
  - No PII (IP/SSID/location) is ever added to telemetry. The `telemetry.accessibility`
    block (dark mode, text size, VoiceOver, reduce motion, …) shares its keys and its
    vocabulary with Android's; a field the platform cannot read stays absent, so the panel
    can tell "off" from "not knowable here". It is optional the way the session fields
    are — a report without it renders as it always did.
  - `telemetry.permissions` (camera / microphone / photo library / location / notifications)
    is **status reads only**: `authorizationStatus`, never `requestAccess`. Collie must
    never raise a permission prompt — a bug reporter that asks for the camera teaches
    testers to decline, and a request without a usage description crashes the host. Reading
    a grant is not reading the data behind it: no coordinate, no photo, no PII. The
    notification grant is the one status with no synchronous API, so it is cached by
    `CollieNotificationAuthorizationMonitor` (filled in `prepare()`, refreshed on
    `didBecomeActive`) — `UNUserNotificationCenter.current()` also traps in a process
    without an app bundle, which is what the macOS test run is, hence the UIKit guard.
- Backend assumptions:
  - HTTPS — `POST <reportsPath>` (multipart: `report` JSON part + one part per screenshot,
    `x-collie-api-key` header) and `GET <configPath>`; both overridable via
    `CollieConfiguration`. The first image keeps the part name `screenshot` /
    `screenshot.jpg` it has always had, so a single-image request is unchanged on the wire;
    further ones are `screenshot[i]` / `screenshot<i>.jpg`, numbered from 1.
  - Firebase — `collie_reports/<reportId>` (envelope decoded, plus `appKey`, `status`,
    `hasScreenshot`, `screenshotCount`), the raw log stream in
    `collie_report_entries/<reportId>`, each screenshot's base64 in
    `collie_report_screenshots/<reportId>_<index>` (Cloud Storage needs a paid plan, so it
    is NOT used), and the kill switch in `collie_config/<appKey>`. Collections
    are overridable via `FirestoreTransport.Configuration`. Rule templates:
    `Integration/firestore.rules`. Moving an existing writer onto the split shape:
    [`MIGRATION.md`](MIGRATION.md).
  - **The report document carries no `entries`.** The stream is written to its own document
    first, and only falls back to inline if that write fails *permanently* (rules that
    predate the collection). The panel reads both shapes, so this is not a flag day — but
    a change that puts the stream back inside the report document undoes the reason the
    panel's list is fast, and must not be made casually. Why, and what the panel expects:
    [`MIGRATION.md`](MIGRATION.md).
- Language: all code comments, docs, and commit messages are in English.
- Releasing: add a `## <version> — <date>` section to `CHANGELOG.md`, commit, then
  `git tag <version> && git push origin <version>` (plain semver, no `v` prefix).
  The `Release` workflow (`.github/workflows/release.yml`) runs the tests, builds for
  the iOS simulator, and publishes the GitHub release with that CHANGELOG section as
  its notes — it fails if the section is missing.
