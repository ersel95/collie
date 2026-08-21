# Changelog

## 1.18.2 — 2026-08-21

### Fixed
- **An image picked from the photo library was uploaded too large and then dropped.** The
  form compressed against `CollieConfiguration.maxScreenshotBytes`, which defaults to 4 MB;
  `FirestoreTransport` stores at most 650 KB and refuses anything above it. The two limits
  did not know about each other, so a 2.4 MB photo passed the first, failed the second, and
  the report arrived with `screenshotError: Screenshot 3 of 3 dropped: 2435161 bytes exceeds
  the 650000-byte Firestore limit` and no picture.

  Shake captures hid it — a rendered app screen compresses well under 650 KB — so it only
  surfaced once a real photo could be attached.

  A transport with a hard limit of its own now declares it (`ReportTransport.maxScreenshotBytes`,
  `nil` by default so existing transports are unaffected), and
  `BugReportService.maxScreenshotBytes` takes the **strictest** of local config, server value
  and destination. Compression aims at a size the destination will actually accept: the same
  two library photos now upload at 509 KB and 408 KB instead of 2.4 MB and 1.4 MB.

Android 0.7.0 carries the same fix (still untagged).

## 1.18.1 — 2026-08-21

### Changed
- **Screenshot mode hands the report back after every capture.** It used to stay put, with a
  counter in the corner as the only sign anything had happened — so the tester kept shooting
  without seeing what they had actually attached, and found out only once they left the mode.
  Now one tap takes the picture and returns to the report, thumbnail and all; the next screen
  is one tap on **Screenshot** away.

  The capture flash went with it. The form coming back *is* the confirmation, and the two
  animations only fought each other.

## 1.18.0 — 2026-08-21

### Added
- **A report can carry up to five screenshots.** One picture was the whole evidence a
  tester could attach, and a bug rarely lives on one screen: the state two steps back, the
  notification that started it, the other app the data came from — all of that had to be
  described in prose, or filed as a second report.

  The shake-time capture still arrives attached, exactly as before. Beside it now sits a
  thumbnail per image — each one removable, each one tappable into the markup editor — and
  two ways to add another: **Screenshot** (below) and **Upload**, which opens the system
  photo picker. That picker is `PHPickerViewController`, which runs out of process, so it
  needs **no** photo-library permission and raises no prompt: Collie asking for the photo
  library would teach testers to decline, and a request without a usage description crashes
  the host.

  Markup still only ever *replaces* the image it was opened for, addressed by id rather
  than position: the tester can remove a thumbnail while another is being marked up, and
  the result still lands on the right picture.

- `CollieConfiguration.maxScreenshots` (default 5, clamped to
  `CollieConfiguration.maxScreenshotsLimit`) and a `maxScreenshots` key in the remote
  config, so an app can be given fewer slots without a new build.
  `BugReportService.maxScreenshots` is the stricter of the two, and the form stops offering
  to add one there.

- **Screenshot mode.** A bug is rarely one screen, and the shake happens where the tester
  *noticed* it — often two screens after the one an analyst needs. **Screenshot** in the
  form hands the app back: a bar across the top says the mode is on and returns to the
  report, a shutter sits in the bottom-right corner, and everything between them belongs to
  the host app. The tester navigates to each screen worth reporting and taps once. At five
  images the mode ends and the form comes back on its own.

  Nothing about the report is at risk during that trip: the sentence, the name and the
  images already attached live outside the form, so it can be dismissed on the way in and
  rebuilt on the way out.

- **Every screenshot leaves a marker in the log stream** (`CollieScreenshotEvent`): a
  `collie` entry at the instant it was taken — "Screenshot 2 captured" — merged into the
  stream at its chronological position like every other Collie marker. Five pictures taken
  minutes apart were otherwise a row of thumbnails with no place in a timeline that is
  stamped to the second; now a screenshot can be read against the request that failed just
  before it. An image the tester deleted leaves no marker, and one picked from the library
  says "attached", not "captured" — it was taken at some earlier, unknown time.

  `BugReportService.sendReport` gains `screenshotEvents:` for it. The parameter has a
  default, so existing call sites keep compiling.

### Changed
- **The report form is the form testers already know.** One title, then the whole page as a
  single writing surface with the keyboard already up, and the evidence riding directly
  above the keyboard instead of competing with the text for room. The screenshots sit there
  as a row of thumbnails — each removable with ✕, each tappable into the markup editor —
  beside the two ways to add another.

  The old layout asked for a description inside a boxed field halfway down a scrolling form,
  with the pictures below it where the keyboard covered them. Testers write one sentence and
  send; the sentence should be the page.

- **The name is asked in an alert, with a reason.** It used to be a placeholder above the
  description — "Your name (asked only once)" — which says what to type and not one word
  about why. Now the first **Send** raises an alert that explains it: reports from every test
  device land in one list, and the name is what says which one this came from. Answer it and
  the send carries straight on.

  Nothing asks before the tester has written anything, and the button stays "Send" for
  everyone who has already answered.

- **Firestore: one document per image, numbered.** A report's images are written to
  `collie_report_screenshots/<reportId>_0 … _<n-1>` and the report document gains
  `screenshotCount`. The two are one contract with the panel: it switches shapes on the
  count and then reads only the numbered ids. The count is how many documents were
  *actually written*, so a report whose third image failed says `2` and explains the third
  in `screenshotError` — a partial set of pictures and a working report beats no report.

  `maxScreenshotBytes` (650 KB on the Firestore path) is now explicitly **per image**. It
  always was a per-document limit; with five documents that finally matters.

  Nothing existing is rewritten. Reports already in Firestore have no `screenshotCount` and
  a single unsuffixed document, and the panel keeps reading them through its older path.
  The security rules need no change either — `Integration/firestore.rules` matches a
  suffixed id and does not object to the new `index` / `reportId` fields.

- **HTTPS: one multipart part per image.** The first keeps the name it has always had —
  `screenshot` / `screenshot.jpg` — so a single-image request is byte-for-byte what a
  deployed backend already parses; further images are `screenshot[i]` / `screenshot<i>.jpg`,
  numbered from 1. A backend that ignores the extra parts still receives the capture the
  tester started from. The scheme is in `INTEGRATION.md` §6.

- **Breaking — `ReportTransport`.** `upload(reportID:envelope:screenshot:)` becomes
  `upload(reportID:envelope:screenshots:)`, taking `[Data]`. Hosts that ship their own
  transport must update the signature; hosts using `IngestionClient` or `FirestoreTransport`
  need no change. `BugReportService.sendReport` takes `screenshotsJPEG: [Data]` for the
  same reason.

- The upload queue writes `<id>.screenshot.<index>` files and records `screenshotCount` in
  its envelope. `hasScreenshot` stays in that envelope and the unsuffixed file name is
  still read and still deleted: a report queued off-VPN is read back by whatever build is
  installed when the connection returns, and losing its image to an app update would be a
  silent loss of the thing the tester filed the report for.

- `PrivacyInfo.xcprivacy` now declares **Photos or Videos** alongside the existing types,
  because a report may carry an image the tester picked from their library. No new API
  access is declared — the out-of-process picker needs none.

### Fixed
- **A tester could be asked their name on every single report, forever.** The name is kept
  in the Keychain so it survives a reinstall — but a build without the Keychain entitlement
  (an unsigned harness, some enterprise re-signing setups) has that write refused with
  `errSecMissingEntitlement`, and nothing read the status, so it failed silently and
  `hasStoredName` stayed false. `KeychainStore` now checks, says so through `diagnostics`,
  and falls back to `UserDefaults`: wiped on reinstall, which is worse than the Keychain and
  far better than being asked every time.

- **The app underneath Collie's overlay was not actually interactive.** `UIView.hitTest`
  returns *self* when no subview wants a point, and a `UIWindow` is a view — so Collie's
  overlay window answered "mine" for every touch its content had already declined, and the
  host app could not be touched while the banner was up. It had been documented as working
  since the banner shipped. `PassthroughWindow` now returns `nil` for those points, which is
  what lets UIKit try the next window down — and is what makes screenshot mode possible at
  all.

Android 0.7.0 carries the multi-screenshot half of this — the same document shape, the
same limit. The new form, screenshot mode and the capture markers are iOS-only for now.

## 1.17.0 — 2026-08-18

### Fixed
- **A long test session no longer costs the report.** On the Firebase path a report was
  rejected outright — "Report is too large for Firestore (1003443 bytes > 900000)", a
  *permanent* failure, so the queue dropped it and the tester's words, screenshot and logs
  were gone — whenever the whole envelope crossed the document limit.

  It was measuring the wrong thing. The log stream has had its own document since 1.15.0
  (`collie_report_entries/<reportId>`), and the stream is by far the largest part of an
  envelope; the check ran *before* it was lifted out, so a report whose actual document
  was a few kilobytes was refused on account of data that was never going to be written
  there. `maxDocumentBytes` now bounds the report document itself, measured after the
  stream comes out.

  Testers do not kill the app, so the stream grows all session and every device reached
  this eventually — the report that surfaced it was three lines of Turkish about a
  background colour.

### Added
- **A stream larger than a Firestore document is trimmed instead of lost.** The stream
  document has its own 1 MiB ceiling, and past it the choice is not "lossless or trimmed"
  but "trimmed or no report at all". So the **oldest** entries go and the tail survives —
  the entries nearest the bug are the ones the report was filed for.

  Never silently: a `collie` warning entry heads the trimmed stream ("the oldest N of M
  entries were dropped…"), carrying the timestamp of the cut so the panel's session fold
  still lands where it should, and `entriesTrimmed` counts the loss on the report document.

  This is the one place Collie is not lossless, and it takes a hard platform limit to get
  there: the HTTPS transport still uploads every entry, and `ReportEnvelopeBuilder` still
  builds every entry into the envelope.

- `FirestoreTransport.Configuration.maxEntriesBytes` (default `900_000`) — the stream
  document's budget, alongside the existing `maxDocumentBytes` and `maxScreenshotBytes`.
  A trailing parameter with a default, so existing call sites keep compiling.

- Tests for the transport's pure parts (`CollieFirebaseTests`), which had none: the size
  budgeting and the trim decide whether a report survives at all. Android 0.6.0 carries
  the same fix and the same tests.

## 1.16.0 — 2026-08-14

### Added
- **Every report now says how the device presents the app.** Telemetry gains a nested
  `accessibility` block: appearance (`interfaceStyle` — dark or light), text size
  (`fontScale`, plus iOS's own `contentSize` category: `L`, `XXL`, `AX3`…) and the
  accessibility switches — `boldText`, `screenReader` (VoiceOver), `switchControl`,
  `assistiveTouch`, `speakScreen`, `reduceMotion`, `reduceTransparency`,
  `increaseContrast`, `invertColors`, `grayscale`, `differentiateWithoutColor`,
  `onOffLabels`, `closedCaptions`, `monoAudio`.

  A tester never mentions any of this. "The button is cut off" and "I can't read the
  price" are the same sentence whether the device runs at the default text size or at AX5
  with bold text, so the layout complaint that reproduces nowhere else stays
  unreproducible. Reading the screenshot back against these values is what ends that.

  Still device state, not PII: every field is a system setting, and nothing here names the
  person, the network or the place.

  The block is **additive and optional**, like the session fields before it — a report
  filed by an older SDK simply has no `accessibility` key, and the panel renders it
  exactly as it did. A setting the platform cannot read is *absent* rather than `false`,
  so the panel can tell "off" from "not knowable here". Android 0.5.0 sends the same keys.

  `CollieTelemetry` gains a trailing `accessibility:` parameter with a `nil` default, so
  existing call sites keep compiling.

- **And what the tester answered to the permission prompts.** A second nested block,
  `telemetry.permissions`: `camera`, `microphone`, `photoLibrary` (`limited` for "Selected
  Photos"), `location` (`always` / `whenInUse`) with `locationAccuracy` (`full` /
  `reduced`), and `notifications` (`provisional` and `ephemeral` included).

  A declined prompt is the invisible cause behind half the reports that read like a broken
  feature: the camera screen that "opens black", the upload that "does nothing", the push
  that "never arrives". The tester does not connect the two, and nobody triaging the report
  could see it.

  **Collie never asks for anything.** Every value is a status read — `authorizationStatus`,
  never `requestAccess` — so no prompt is raised, no usage description is required, and no
  privacy-manifest entry changes (a status read is not a required-reason API). Reading a
  grant is not reading the data behind it: whether location is allowed, never a coordinate.

  Two integration notes: linking the package now also links `AVFoundation`, `Photos`,
  `CoreLocation` and `UserNotifications`; and a permission the host app never uses is
  reported as *absent* rather than `denied`.

  The notification grant is the one status with no synchronous API, so it is fetched in
  `CollieTelemetryCollector.prepare()` and refreshed whenever the app becomes active —
  which is exactly when it can have changed, since altering it means a trip to Settings and
  back. Same optional, additive shape as the accessibility block.

## 1.15.0 — 2026-08-13

### Changed
- **The log stream is written to its own document, not inside the report.** The panel's list
  screen shows four fields per report, but Firestore's web SDK cannot fetch a subset of a
  document's fields — so every list load downloaded each report's complete `entries` array,
  request and response bodies included. Combined with testers never closing the app (each
  report repeats the previous ones' stream), report documents kept growing and the list got
  slower every week.

  `entries` now goes to `collie_report_entries/<reportId>` — `{ appKey, entries, createdAt }`,
  same document id as the report, the same pattern screenshots have used all along. The
  report document keeps `app` / `device` / `report` / `telemetry` and no longer carries the
  stream. Write order is screenshot → entries → report, so the report the panel discovers
  never points at a stream that is not there yet.

  **Nothing is dropped and nothing is a flag day.** The stream is still uploaded in full,
  losslessly. A *permanent* failure writing the entries document (rules that predate the
  collection) falls back to the old inline shape rather than losing the logs; a transient one
  retries the whole report. The panel reads both shapes, so old reports and older SDKs keep
  working untouched — no backfill.

  ⚠️ **Deploy `Integration/firestore.rules` before shipping this.** It adds the
  `collie_report_entries` block and stops *requiring* `entries` on the report document; with
  the old rules live, a report without that field is rejected outright.

  Writing to this Firestore without the SDK? [`MIGRATION.md`](MIGRATION.md) has the wire
  shape, the ordering, and the one mistake that costs you a report's logs (`entries: []`
  instead of an absent field).

## 1.14.0 — 2026-08-12

### Added
- **Session context on every report, so the panel can fold a tester's repeated history.**
  Testers do not kill the app: the log stream lives as long as the process, so the tenth
  report from a device carried the nine earlier reports' navigation and network history and
  the part that was actually new drowned in the repetition — in the panel and in the Jira
  issue alike.

  The report block now carries five optional fields — `previousReportAt`, `sessionStartedAt`,
  `processStartedAt`, `sessionOrdinal`, `sequence` — plus `platform: "ios"`, which the panel
  previously had to guess from the bundle id. The panel collapses everything older than the
  boundary (`previousReportAt`, or `sessionStartedAt` for a device's first report) into an
  expandable block and leaves the newer part open.

  **Nothing is dropped.** `entries` are still uploaded in full: an `appConfig` or `login`
  call fired once at session start is inside the collapsed block, one click away, not gone.
  This release adds metadata and three synthetic `category: "collie"` markers at their
  chronological positions — `Session started`, `Session resumed after N min background`, and
  `Previous report submitted`, whose timestamp is exactly `previousReportAt` so it renders as
  the line under the collapsed block.

  A **logical session** starts at `Collie.configure` and starts over when the app returns
  from 30+ minutes in the background (the same threshold the Android SDK uses, so one
  scenario cannot fold differently on the two platforms). `sequence`, `sessionOrdinal` and
  `previousReportAt` live in `UserDefaults` and survive a kill; `processStartedAt` is the one
  field that resets with the process.

  All five fields are **optional and stay optional** — a panel report from an older SDK
  renders exactly as it did before, so nothing has to be upgraded in step. Hosts need no
  integration change at all: the fields appear on the next build.

## 1.13.0 — 2026-07-29

### Fixed
- **`captureExclusionFragments` could silently empty a report's log stream.** It returned
  Collie's host and its ingestion path as two *separate* entries, and capture tools match that
  list as substrings — so a short `reportsPath` matched the host app's own traffic. With
  `reportsPath = "/post"`, the entry `/post` also matched every `GET /posts` the app made, and
  those requests never reached the logger. The report still uploaded and still looked fine; it
  just arrived with the network section missing, and nothing anywhere said why.

  The property now returns the **whole URLs** of Collie's two endpoints (`reportsURL` and
  `configURL` — the config endpoint was never excluded before either). A full URL cannot match
  unrelated traffic, so the same one-line integration is now safe whatever path a host
  configures.

  Found while building the Android example app, which hit it with a real `/post` endpoint.
  Hosts that pinned an older version and use a short `reportsPath` should exclude
  `config.reportsURL.absoluteString` / `config.configURL.absoluteString` by hand.

## 1.12.0 — 2026-07-28

### Added
- **A harness app for running the UI on a simulator.** Collie's flow starts with a shake,
  which no script can trigger on a simulator, so until now the UI could only be checked by
  hand inside a real host app — which is how two markup implementations shipped broken.
  `Examples/CollieHarness` links this checkout and calls `presentReport()` from a button,
  putting the banner, the form and the markup editor one tap away and within reach of UI
  automation. The generated `.xcodeproj` stays out of the repo; `project.yml` regenerates
  it.

### Changed
- **`Integration/firestore.rules` now covers the analyst panel, not just the device.** The
  panel is a pure client module — no bridge, no server of its own — so the rules are the
  only thing standing between the reports and the internet. They gain a second caller: an
  analyst authenticated with Firebase Auth whose row in `collie_analysts` carries the apps
  they may see and whether they are an admin. Reads, triage updates and deletes are scoped
  to that list; the device keeps its create-only access and the unauthenticated kill-switch
  read.

  An analyst cannot widen their own grants — only admins write `collie_analysts`, and an
  admin may not change the role or active flag on their own row. The Jira PAT in
  `collie_secrets` is readable only by the uid that owns it, admins included: with no
  server to hold an encryption key, per-user access control is the protection.

  ⚠️ The file also carries the Android reporter's `bug_reports` collections, which used to
  fall through to the project-wide test-mode allow-all. They now keep `create` open and
  restrict reads to analysts — confirm that with the Android team before deploying, and
  remember that deploying replaces the entire ruleset.

## 1.11.0 — 2026-07-28

### Changed
- **Markup is one screen again — Collie's own.** Tapping the screenshot now opens the
  editor directly: the screenshot, a PencilKit canvas over it, and a palette with pen /
  marker / eraser, three widths and six colours. Done flattens the marks and returns to the
  form. No preview page, no loading state, no second Done.

  This replaces QuickLook (1.9.x), whose UX could not be fixed from the outside. Both of
  Apple's ready-made editors were measured on an iOS 26 simulator and fail here:

  - **QuickLook** renders the preview *out of process* since iOS 26 (`_EXHostView` hosting a
    remote scene). It opens on a blank page while that scene loads, always shows its own
    preview page before markup, and its buttons are not in the host app's view hierarchy at
    all — so the extra page cannot be skipped programmatically.
  - **`PKToolPicker`** (1.8.0's palette) docks into the `UITextEffectsWindow` at window
    level 10, while Collie's UI runs in an overlay window at `.alert + 1` — the palette was
    drawn 1991 levels below the editor, which is why it never appeared. Reordering the two
    windows makes it visible but stops the overlay receiving touches at all: no drawing, no
    Cancel, no Done.

  Collie's palette lives in the same window as the canvas, so neither problem applies.

## 1.10.0 — 2026-07-28

### Changed
- **One tap on the screenshot is now one markup session.** QuickLook wrapped markup in a
  preview page on both sides: the tester had to tap the markup button to start and Done
  twice to get back to the form. Collie now opens QuickLook straight into markup and closes
  the editor once the markup is saved, so tapping the screenshot leads directly to the
  tools and Done leads directly back to the form.

  Both steps are best-effort: they locate QuickLook's markup button by its accessibility
  identifier (or the selector it carries), never by its label, and quietly fall back to
  QuickLook's own navigation if a future release moves it.

## 1.9.1 — 2026-07-28

### Fixed
- **Crash when leaving the markup editor (1.9.0).** QuickLook reports a saved edit from an
  `NSFileCoordinator` operation queue, not the main one, and the delegate assumed main-actor
  isolation — so tapping **Done** trapped the process (`SIGTRAP`). The QuickLook callbacks
  now touch immutable state only and hop to the main queue when they have to; whether the
  screenshot was edited is decided by reading the file back on dismiss instead of by a flag
  set from another thread.

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
