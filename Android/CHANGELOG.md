# Changelog — Collie for Android

Android ships on its own version line (`android-*` tags); the iOS changelog is
[../CHANGELOG.md](../CHANGELOG.md). See [../RELEASING.md](../RELEASING.md).

## 0.7.0 — 2026-08-21

### Added
- **A report can carry up to five screenshots** — the Android half of iOS 1.18.0, same
  feature, same document shape, same ceiling. One picture was the whole evidence a tester
  could attach, and a bug rarely lives on one screen.

  The shake-time capture still arrives attached. What is new is the row below the fields: a
  thumbnail per image, each tappable into the markup editor and removable, and an **Add**
  tile that opens the system photo picker until five is reached. The picker is
  `ActivityResultContracts.PickVisualMedia`, which runs outside the app and grants access
  only to the items the tester chose — so `READ_MEDIA_IMAGES` is never required and Collie's
  manifest, which merges into the host's, still declares no storage permission. Picked
  images are decoded as software bitmaps, because a hardware one cannot be drawn into the
  markup canvas.

  Markup still only ever *replaces* the image it was opened for, addressed by id rather
  than position: the tester can remove a thumbnail while another is being marked up, and
  the result still lands on the right picture.

- `CollieConfiguration.maxScreenshots` (default 5, clamped to
  `CollieConfiguration.MAX_SCREENSHOTS_LIMIT` by `effectiveMaxScreenshots`) and a
  `maxScreenshots` key in the remote config, so an app can be given fewer slots without a
  new build. `BugReportService.maxScreenshots` is the stricter of the two.

### Changed
- **Firestore: one document per image, numbered.** A report's images are written to
  `collie_report_screenshots/<reportId>_0 … _<n-1>` and the report document gains
  `screenshotCount`. The two are one contract with the panel: it switches shapes on the
  count and then reads only the numbered ids. The count is how many documents were
  *actually written*, so a report whose third image failed says `2` and explains the third
  in `screenshotError`. `maxScreenshotBytes` is now explicitly **per image**.

  Nothing existing is rewritten, and the security rules need no change — see
  [`../MIGRATION.md`](../MIGRATION.md).

- **HTTPS: one multipart part per image.** The first keeps the name it has always had —
  `screenshot` / `screenshot.jpg` — so a single-image request is byte-for-byte what a
  deployed backend already parses; further images are `screenshot[i]` / `screenshot<i>.jpg`,
  numbered from 1.

- **Breaking — `ReportTransport`.** `upload(reportId, envelope, screenshot)` becomes
  `upload(reportId, envelope, screenshots: List<ByteArray>)`. Hosts that ship their own
  transport must update the signature; hosts using the built-in client or
  `FirestoreTransport` need no change. `BugReportService.sendReport` takes
  `screenshotsJpeg: List<ByteArray>` for the same reason, and `collie-no-op` mirrors both —
  its signatures must stay identical or the host's release build stops compiling.

- The upload queue writes `<id>.screenshot.<index>` files and records `screenshotCount` in
  its envelope. `hasScreenshot` stays in that envelope and the unsuffixed file name is still
  read and still deleted: a report queued off-VPN is read back by whatever build is
  installed when the connection returns, and losing its image to an app update would be a
  silent loss of the thing the tester filed the report for.

### Fixed
- **An image picked from the gallery was uploaded too large and then dropped** — the Android
  half of iOS 1.18.2, the same bug in the same place. The form compressed against
  `CollieConfiguration.maxScreenshotBytes` (4 MB by default) while `FirestoreTransport` stores
  at most 650 KB, and the two limits did not know about each other.

  `ReportTransport.maxScreenshotBytes` (`null` by default) lets a destination declare its own
  limit, and `BugReportService.maxScreenshotBytes` now takes the strictest of local config,
  server value and destination.

## 0.6.0 — 2026-08-18

### Fixed
- **A long test session no longer costs the report** — the Android half of iOS 1.17.0, the
  same bug in the same place. A report was rejected outright ("Report is too large for
  Firestore (… bytes > 900000)") as a *permanent* failure, so the queue dropped it and the
  tester's words, screenshot and logs went with it.

  The check measured the whole envelope, including the log stream — which since 0.4.0 goes
  to its own document (`collie_report_entries/<reportId>`) and is by far the largest part
  of an envelope. `maxDocumentBytes` now bounds the report document itself, measured after
  the stream is lifted out. The envelope is also parsed into `JSONObject` before it is
  converted to Firestore maps, so the size is read off the JSON that actually ships.

### Added
- **A stream larger than a Firestore document is trimmed instead of lost.** The stream
  document has its own 1 MiB ceiling, and past it the choice is not "lossless or trimmed"
  but "trimmed or no report at all". The **oldest** entries go; the tail — the part nearest
  the bug — survives.

  Never silently: a `collie` warning entry heads the trimmed stream, carrying the timestamp
  of the cut so the panel's session fold still lands where it should, and `entriesTrimmed`
  counts the loss on the report document. `trimEntries` matches the iOS implementation of
  the same name, entry for entry, because a report is the same document whichever device
  filed it.

- `FirestoreTransport.Configuration.maxEntriesBytes` (default `900_000`) — the stream
  document's budget. Mirrored in the no-op artifact, in the same position: the host builds
  the transport in one file shared by debug and release.

- `EntriesTrimTest`, and `:collie-firebase:testDebugUnitTest` in CI — the Firestore module's
  unit tests were never being run there, so `EnvelopeConversionTest` was skipped too.

## 0.5.0 — 2026-08-14

### Added
- **Every report now says how the device presents the app** — the Android half of iOS
  1.16.0, under the same keys. Telemetry gains a nested `accessibility` block: appearance
  (`interfaceStyle`, from the night-mode configuration), `fontScale`, `boldText` (the font
  weight adjustment, API 31+), `screenReader` (TalkBack, via touch exploration),
  `reduceMotion` ("Remove animations"), `increaseContrast` ("High contrast text"),
  `invertColors`, `grayscale` (colour correction set to monochromacy), `closedCaptions` and
  `monoAudio`.

  A tester never mentions any of this, and it is usually why a layout complaint reproduces
  on their device and nowhere else.

  Still device state, not PII, and **no new permission**: the toggles Android has no public
  API for are read by their AOSP settings key, and a read that fails leaves the field
  absent rather than claiming the setting is off. iOS-only settings (`contentSize`, switch
  control, AssistiveTouch, Speak Screen, reduce transparency, differentiate-without-colour,
  on/off labels) stay absent here rather than being invented.

  The block is **additive and optional** — a report filed by an older SDK has no
  `accessibility` key and the panel renders it exactly as it did. `CollieTelemetry` gains a
  trailing `accessibility` parameter defaulting to `null`, mirrored in the no-op artifact.

- **And what the tester answered to the permission prompts** — the Android half of iOS
  1.16.0. A second nested block, `telemetry.permissions`: `camera`, `microphone`,
  `photoLibrary` (`limited` for Android 14's partial "Select photos" grant), `location`
  (`always` for background access, `whenInUse` for either foreground grant) with
  `locationAccuracy` (`full` for fine, `reduced` for coarse-only), and `notifications`.

  A declined prompt is the invisible cause behind half the reports that read like a broken
  feature — the camera screen that "opens black", the push that "never arrives".

  **Nothing is requested and nothing is declared.** The statuses come from
  `checkSelfPermission` and `areNotificationsEnabled()`; Collie adds **no `uses-permission`
  to its manifest**, so a host's merged manifest is unchanged and filing a report can never
  raise a prompt. A permission the host does not declare is reported as *absent* rather
  than `denied` — `checkSelfPermission` cannot tell "declined" from "not used by this app".

  Two differences from iOS, both platform limits: Android cannot distinguish "never asked"
  from "declined" outside an Activity, so there is no `notDetermined` here; and
  `notifications` reports the *effective* state, so a channel switched off in system
  settings reads as `denied` too — which is the state the "push never arrived" report is
  actually about.

## 0.4.0 — 2026-08-13

### Changed
- **The log stream is written to its own document, not inside the report** — the Android half
  of iOS 1.15.0, field for field. The panel's list screen shows four fields per report, but
  Firestore's web SDK cannot fetch a subset of a document's fields, so every list load
  downloaded each report's complete `entries` array. Since testers never close the app and
  each report repeats the previous ones' stream, those documents kept growing and the list
  got slower every week.

  `entries` now goes to `collie_report_entries/<reportId>` — `{ appKey, entries, createdAt }`,
  same document id as the report, the same pattern screenshots have used all along. Write
  order is screenshot → entries → report. A permanent failure on the entries write falls back
  to the old inline shape rather than losing the logs; a transient one retries the whole
  report. The panel reads both shapes, so nothing needs backfilling.

  `FirestoreTransport.Configuration` gains `entriesCollection` (default
  `"collie_report_entries"`), mirrored in the no-op artifact so the host's single integration
  file still compiles in release builds.

  ⚠️ **Deploy `Integration/firestore.rules` before shipping this** — see the iOS changelog
  entry and [`../MIGRATION.md`](../MIGRATION.md).

## 0.3.0 — 2026-08-12

### Added
- **Session context on every report, so the panel can fold a tester's repeated history** —
  the Android half of iOS 1.14.0, field for field. Testers do not kill the app: the log
  stream lives as long as the process, so the tenth report from a device carried the nine
  earlier reports' navigation and network history and the part that was actually new drowned
  in the repetition.

  The report block now carries five optional fields — `previousReportAt`, `sessionStartedAt`,
  `processStartedAt`, `sessionOrdinal`, `sequence` — plus `platform: "android"`, which the
  panel previously had to guess from the package name (`com.example.android.uat` → Android,
  and nothing at all when the name does not spell it out). The panel collapses everything
  older than the boundary into an expandable block and leaves the newer part open.

  **Nothing is dropped.** `entries` are still uploaded in full; this adds metadata and three
  synthetic `category = "collie"` markers at their chronological positions — `Session
  started`, `Session resumed after N min background`, and `Previous report submitted`, whose
  timestamp is exactly `previousReportAt` so it renders as the line under the collapsed
  block.

  A **logical session** starts at `Collie.configure` and starts over when the app returns
  from 30+ minutes in the background (`ProcessLifecycleOwner`, and the same threshold the iOS
  SDK uses, so one scenario cannot fold differently on the two platforms). `sequence`,
  `sessionOrdinal` and `previousReportAt` are persisted and survive a kill;
  `processStartedAt` is the one field that resets with the process. Every timestamp is
  ISO-8601 **with an offset** — the boundary is found by comparing them, and a zone-less
  stamp would be read in the browser's timezone and slide the fold by hours.

  All five fields are **optional and stay optional** — a report from an older SDK renders
  exactly as it did before. Hosts need no integration change: the fields appear on the next
  build.

### Fixed
- Report uploads now time out after 15 seconds by default. A transport that never completes —
  including a Firestore write blocked by a VPN — is classified as a transient failure, persisted
  to the offline queue and reported to the tester as **Queued** instead of leaving the form in an
  endless loading state. `requestTimeoutMillis` still overrides the default. A network-constrained
  WorkManager job now keeps retrying the persisted queue after the app process exits or the device
  restarts; background transient failures remain on disk until they are sent or reach the 48-hour
  TTL.
- The shake confirmation banner and screenshot markup palette now respect Android's navigation
  bar insets, keeping their controls above both three-button and gesture navigation areas.

## 0.2.0 — 2026-07-29

### Fixed
- **`captureExclusionFragments` could silently empty a report's log stream** — the same defect
  fixed in iOS 1.13.0, and the platform where it was found. It returned the host and the
  ingestion path as two *separate* entries; capture tools match that list as substrings, so a
  `reportsPath` of `/post` also matched the host app's own `GET /posts` and dropped those
  requests from every report. The report uploaded and looked fine, just empty.

  It now returns the **whole URLs** of Collie's two endpoints (the config endpoint was never
  excluded before either). The example app passes the property straight through again instead
  of working around it.

## 0.1.1 — 2026-07-29

### Fixed
- **`FirestoreTransport` rejected every report.** The envelope-to-Firestore conversion built its
  arrays with `buildList { … get(index) … }`, where `get` resolves to the *list's* own accessor
  rather than the `JSONArray`'s — so it read index 0 of an empty list and every upload died with
  `IndexOutOfBoundsException: index: 0, size: 0`. Because a decode failure is classified as
  *permanent*, the queue then dropped the report instead of retrying it: on 0.1.0 the Firebase
  path lost reports silently. Anyone on `collie-firebase` should move to 0.1.1.

  The conversion moved to the companion object so it can be tested without a `FirebaseFirestore`,
  and `EnvelopeConversionTest` now covers it — entries, nested arrays, and JSON nulls.
- **Decode failures say what went wrong.** The message was a bare "Could not decode the report
  envelope", which is nothing to debug from when the report has already been dropped. It now
  carries the exception type and message.

### Changed
- The example app writes to **Firestore** when a `google-services.json` is present, and falls
  back to the HTTPS transport when it is not (which is how CI builds it). The file is
  git-ignored — it points at a specific Firebase project.

## 0.1.0 — 2026-07-29

First Android release. A port of the iOS SDK rather than a new product: the report a device
uploads is the same document on both platforms, so the panel and the bridge parse one shape.

### Added
- **The reporter** (`collie`) — shake → banner → form → report, with the screenshot captured at
  shake time and Collie's own one-screen markup editor (pen / marker / eraser, three widths, six
  colours) over it. Compose throughout, in Collie's own colours rather than the host's.
- **Core**, ported behaviour-for-behaviour from Swift: opt-in and fail-closed configuration, the
  two capture gates (build-time opt-in plus the server-side kill switch, which fails *open* when
  unreachable), the offline disk queue with exponential backoff, a 48-hour TTL and idempotent
  retries, and the report envelope — byte-identical in shape to the one iOS sends. The unit tests
  mirror the Swift suite.
- **`collie-firebase`** — the Firestore transport, for hosts whose network policy allows Firebase
  but not arbitrary destinations. Same collections, same document ids, same base64 screenshot
  document as iOS.
- **`collie-no-op`** — the release counterpart: same public API, empty bodies, no shake detector,
  no upload queue, no Compose. It also carries `com.collie.firebase.FirestoreTransport`, so the
  one line that builds a transport compiles in both variants without splitting the host's
  integration across source sets.
- **[`example/`](example)** — a host app with Chucker beside Collie: real traffic, a complete
  OkHttp log bridge, tool hand-off through `Collie.onLogoTap`, and the debug/release artifact
  split for both tools.
- **[`sample/`](sample)** — the one-button harness, and the API-compatibility gate: CI compiles it
  against the real artifact and against the no-op, so the two cannot drift.

### Notes on platform differences
- **Secure screens.** iOS masks secure text fields by rendering with `afterScreenUpdates: true`.
  Android has no equivalent, so Collie never attempts `PixelCopy` on a `FLAG_SECURE` window and
  falls back to drawing the view hierarchy. A host that marks a screen secure decided its pixels
  must not leave the device.
- **The tester's name** lives in the app's preferences, not the Keychain, so a reinstall asks for
  it once more — better than a hardware identifier nobody consented to.
