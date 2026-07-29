# Changelog — Collie for Android

Android ships on its own version line (`android-*` tags); the iOS changelog is
[../CHANGELOG.md](../CHANGELOG.md). See [../RELEASING.md](../RELEASING.md).

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
