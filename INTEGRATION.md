# Collie Integration Guide

## 1. Choose a transport, then add the package

Collie can deliver a report two ways — pick the one your app's network policy allows:

| | **Firebase** (`CollieFirebase`) | **HTTPS** (core `Collie`) |
|---|---|---|
| Report goes to | Firestore, then a server-side bridge | one multipart POST to the Collie backend |
| Use when | the app may only reach a fixed set of hosts (e.g. a banking app allowed to talk to Firebase and its own API) | the device can reach your backend directly |
| Needs | `GoogleService-Info.plist` + `FirebaseApp.configure()` | an ingestion api-key |
| Config keys | `COLLIE_APP_KEY` | `COLLIE_API_BASE_URL` + `COLLIE_API_KEY` |

Both paths end in the same place: an analyst reviews the report in the panel and pushes
it to Jira.

Xcode → Package Dependencies → Collie repo URL → add the product you need to the host app
target: **`CollieFirebase`** for the Firebase path (it brings `Collie` with it), or
**`Collie`** alone for the HTTPS path.

## 2. Backend prerequisites

Analysts triage reports in the panel and push them to Jira from there. **Nothing
Jira-related is configured on the device.**

| Requirement | Description |
|---|---|
| App record | Create the app on the panel's **Admin · Apps** page. Its Jira project, default issue type, retention and the `captureEnabled` kill switch live there |
| **App key** | The record's `key` (e.g. `ykb-nl-test`). Names the app on every report — this is what the Firebase path needs. Not a secret |
| Ingestion api-key | Generated with the app record and **shown once**. Only the HTTPS path uses it; rotate it from the same page |
| Firebase (Firebase path) | The app must already be a Firebase app: `GoogleService-Info.plist` in the target and `FirebaseApp.configure()` before Collie starts. Security rules in `Integration/firestore.rules` |

## 3. xcconfig / Info.plist keys

The values **never enter the repo** — they live in non-prod xcconfig/secrets. See the
`Integration/CollieIntegration.swift` template for the key list and the Info.plist
mapping:

**Firebase path:** `COLLIE_ENABLED`, `COLLIE_APP_KEY`
**HTTPS path:** `COLLIE_ENABLED`, `COLLIE_API_BASE_URL`, `COLLIE_API_KEY`

`COLLIE_APP_KEY` is **not** a secret — it can be read out of the app bundle, and write
access is enforced by Firestore rules. The ingestion api-key **is** a secret.

> ⚠️ `COLLIE_ENABLED` is not defined (or is `NO`) in release/prod xcconfig. Collie is
> fail-closed: when the key is missing, none of its code runs.

On the HTTPS path, if your deployment mounts the API somewhere other than the default
(`/api/v1/collie/reports` and `/api/v1/collie/config`), override `config.reportsPath` /
`config.configPath` before calling `Collie.configure`.

On the Firebase path the collections are configurable the same way — see
`FirestoreTransport.Configuration` (`collection`, `screenshotCollection`,
`configCollection`).

### Permission statuses in the report — nothing to declare

Each report carries what the tester answered to the host app's permission prompts (camera,
microphone, photo library, location, notifications) so a "the camera screen is black" report
is not triaged blind. Collie only *reads* these statuses — `authorizationStatus`, never
`requestAccess` — so:

- **No usage descriptions are needed.** Collie raises no prompt, and a missing
  `NSCameraUsageDescription` cannot crash on a status read.
- **No privacy-manifest change is needed** — a status read is not a required-reason API.
- Linking the package pulls in `AVFoundation`, `Photos`, `CoreLocation` and
  `UserNotifications`. A permission your app never uses is reported as absent, not "denied".

## 4. Startup

Copy the `CollieIntegration.swift` template into your project and call it at app startup:

```swift
CollieIntegration.start()
```

## 5. Feeding logs (any source)

Collie is **log-source agnostic**: it takes logs through the
`config.logSnapshotProvider` closure as `[CollieLogEntry]`. Any logger works — Olaf,
Netfox, Pulse, os_log, or your own. ALL provided entries are uploaded with the report
**in full, losslessly, with their categories preserved**; the panel keeps the raw stream
and derives its Network and Navigation views from it. Collie also inserts one synthetic
entry of its own (category `collie`, "Session started — <date&time>") at its
chronological position in the timeline.

On the **Firebase** path there is one bound the platform imposes: Firestore caps a document
at 1 MiB, so a stream larger than that loses its oldest entries rather than costing the whole
report. A `collie` marker at the head of the stream says how many went. Testers who never
kill the app are the ones who hit it — the entries nearest the bug always survive.

For the panel's derived views to populate, network entries should carry these metadata
keys: `method`, `url`, `status`, `durationMs`, `reqBytes`, `respBytes`, `error`,
`requestBody`, `responseBody` (headers: `reqH.` / `respH.` prefixes); navigation
entries: `screen`, `kind`. Entries without them still travel with the report and remain
visible in the panel's log list — they just don't feed the specialised viewers.

### Showing the signed-in account

Any entry — any category — carrying a **`customerNo`** metadata key lets the panel show
which account was signed in when the report was captured (the newest non-empty value).

Leave one log line on each sign-in path (`LoginView`, `RememberMeLoginView`, biometric
re-login, account switch…) right after the sign-in succeeds:

```swift
// With Olaf:
Olaf.info("Signed in", category: .auth, metadata: ["customerNo": customerNo])
```

The value reaches the panel and can end up on the Jira issue, so log the customer
number you are comfortable seeing there — not credentials or tokens.

**Olaf quick start** (our apps use Olaf, so this bridge is ready to paste — Olaf already
writes the metadata keys under the names above):

```swift
config.logSnapshotProvider = {
    Olaf.snapshot().map {
        CollieLogEntry(date: $0.date, level: $0.level.rawValue,
                       category: $0.category.rawValue, message: $0.message,
                       metadata: $0.metadata)
    }
}
config.sessionIDProvider = { Olaf.currentSessionID }
config.diagnostics = { Olaf.info($0) }
```

**Other sources** (Netfox, Pulse, custom): map each record to `CollieLogEntry`, using
category `network` for HTTP records and filling the metadata keys above from the
record's fields.

### Recursion prevention (if your logger captures network traffic)

Exclude Collie's destination from your capture tool. On the Firebase path that is the
Firebase hosts; on the HTTPS path use `config.captureExclusionFragments`:

```swift
// Firebase path
OlafNetworkConfiguration(excludedURLs: ["firestore.googleapis.com"] + existingList)

// HTTPS path
OlafNetworkConfiguration(excludedURLs: config.captureExclusionFragments + existingList)
```

`captureExclusionFragments` returns the **whole URLs** of Collie's two endpoints, so it is
safe to match as a substring however your capture tool does it. Before 1.13.0 it returned
the host and the path separately, which was a trap: with a short `reportsPath` such as
`/post`, the entry `/post` also matched the app's own `GET /posts` and those requests
vanished from every report — a failure that looks like nothing at all, because the report
still uploads, just empty. If you pinned an older version, exclude
`config.reportsURL.absoluteString` and `config.configURL.absoluteString` instead.

Note: Collie's own `URLSession` carries no capture protocol (primary safeguard); this
step is the second safeguard.

### Shake conflict & tool switching

Collie activates on shake. If another shake-activated tool is installed (e.g. Olaf's
log viewer via `OlafUI.install()`), one shake triggers both UIs. Both swizzle
`UIWindow.motionEnded` and call the previous implementation, so they don't break each
other technically — but decide who owns the gesture, or wire the logo callbacks so
testers can hop between the tools:

```swift
Collie.onLogoTap { OlafUI.present() }   // Collie logo → open the Olaf viewer
OlafUI.onLogoTap { }                    // Olaf logo → close; Collie opens on the next shake
```

`Collie.onLogoTap` runs its handler after the Collie UI has fully closed, so presenting
another tool from it is safe.

Shake behavior is independent of the handler: `config.asksBeforeReporting` (default
`true`) decides whether a shake raises the "Spotted a problem?" yes/no banner first or
opens the report sheet directly (`false`).

## 6. Offline behavior

- When the destination is unreachable the report is **queued to disk**
  (`Caches/Collie/uploads/`, encrypted with `.completeFileProtection` on iOS) and retried
  with exponential backoff (default 5 attempts, 48-hour TTL).
- A retry **cannot create a duplicate report**. On the HTTPS path the queue reuses the
  report's id as `x-collie-idempotency-key`; on the Firebase path that same id is the
  Firestore *document id*, so a retry overwrites the same document.

### What a report looks like in Firestore

The report and its stream are one document each; the screenshots are one document **per
image**, all keyed off the same report id:

| Document | Holds |
|---|---|
| `collie_reports/<reportId>` | The envelope minus its stream — `app`, `device`, `report`, `telemetry` — plus `appKey`, `status`, `hasScreenshot`, `screenshotCount`, `clientReportId`, `createdAt` |
| `collie_report_entries/<reportId>` | `appKey`, `entries` (the full raw stream), `createdAt` |
| `collie_report_screenshots/<reportId>_<index>` | `appKey`, `reportId`, `index` (0-based), `contentType`, `byteSize`, `data` (base64), `createdAt` |

`screenshotCount` and the numbered ids are **one contract, not two fields**: the panel
switches shapes on the presence of `screenshotCount` and then reads exactly
`<reportId>_0 … <reportId>_<count-1>`. Writing the count without the suffixed ids — or the
ids without the count — hides every image, silently. It counts the documents that were
**actually written**, so a report whose third image failed says `2` and carries a
`screenshotError` explaining the third.

Reports filed by an SDK older than iOS 1.18.0 / Android 0.7.0 have no `screenshotCount` and
a single unsuffixed `collie_report_screenshots/<reportId>`; the panel keeps reading those
through its older path, and nothing rewrites them.

The stream and the screenshot are kept out of the report document for the same reason: the
panel's list screen shows four fields per report, and Firestore's web SDK cannot fetch a
subset of a document's fields. Anything left inside the report is therefore downloaded for
every report on every list load — and since testers do not close the app, each report
repeats the previous ones' stream, so those documents only grow.

If you write to this Firestore **without** the Collie SDK, the same split applies to you:
see [`MIGRATION.md`](MIGRATION.md).

### Screenshots on the Firebase path

Cloud Storage requires a paid Firebase plan, so each JPEG is base64-encoded into a Firestore
document of its own (`collie_report_screenshots/<reportId>_<index>`) instead. Firestore caps
a document at 1 MiB, so `FirestoreTransport.Configuration.maxScreenshotBytes` (650 KB) bounds
**each** raw image — it is a per-image limit, never a total, which is what lets a report carry
five of them. A larger one is dropped, with the reason recorded on the report, rather than
failing the whole submission.

A report carries **0 to 5 images**: the capture taken at shake time, plus whatever the tester
adds in the form — from the system photo picker (which needs no permission; Collie never
raises one), or in **screenshot mode**, where the form steps aside so they can walk back
through the app; one tap on the shutter takes the picture and returns to the report. Every image also leaves a `collie`
entry in the log stream at the moment it was taken ("Screenshot 2 captured"), so the analyst
can place each picture on the timeline instead of guessing.

The ceiling is `CollieConfiguration.maxScreenshotsLimit` /
`CollieConfiguration.MAX_SCREENSHOTS_LIMIT`, and it is shared with the panel, so raising it in
the SDK alone only uploads images nobody sees. To offer testers *fewer* slots, set
`maxScreenshots` on `CollieConfiguration`, or `maxScreenshots` on the app's
`collie_config/<appKey>` document to change it without a new build.

### Screenshots on the HTTPS path

The multipart body carries one part per image. The first keeps the part name it always had —
`screenshot`, filename `screenshot.jpg` — and each further image is appended as
`screenshot[<i>]`, filename `screenshot<i>.jpg`, numbered from 1:

```
report        report.json     application/json   ← the envelope
screenshot    screenshot.jpg  image/jpeg         ← the shake-time capture
screenshot[1] screenshot1.jpg image/jpeg         ← attached by the tester
screenshot[2] screenshot2.jpg image/jpeg
…
```

A single-image report is therefore byte-for-byte the request a pre-1.18.0 SDK sent, so an
existing backend keeps working untouched; one that ignores the extra parts still receives the
capture the tester started from rather than nothing at all.
- The queue is retried automatically at app startup. To also retry on returning to the
  foreground:
  ```swift
  Collie.flushPendingUploads()
  ```

## 7. Remote kill switch

Collie has two capture gates: the build-time `enabled` flag **and** the app's
`captureEnabled` setting in the panel. At startup Collie calls `GET <configPath>`; when
the panel reports capture as disabled, the banner never appears.

The remote check **fails open**: if the config call itself fails (no VPN, offline), the
previous state is kept so a tester can still file a report and have it queued. Only an
explicit "disabled" from the backend — which is also what an invalid api-key returns —
turns capture off.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Banner never appears on shake | `COLLIE_ENABLED` is NO/missing, or the transport's required key is blank — `COLLIE_APP_KEY` (Firebase) / `COLLIE_API_KEY` + `COLLIE_API_BASE_URL` (HTTPS). Fail-closed. Check `config.diagnostics`. In the simulator use Device → Shake (⌃⌘Z) |
| Report never reaches the panel (Firebase) | The app key must match the panel's app record exactly — a mismatch is recorded as `bridgeError: Unknown appKey` on the Firestore document |
| "Could not write the report: PERMISSION_DENIED" | Firestore security rules reject the write; see `Integration/firestore.rules` |
| Banner disappeared after working before | The app's `captureEnabled` kill switch was turned off in the panel (§7) |
| "api-key is invalid or disabled (401)" | The api-key is wrong or was rotated — copy the current one from Admin · Apps |
| HTTP 400 with a validation message | The payload was rejected (e.g. too many log entries). The message carries the backend's reason |
| "Report is too large (413)" | Screenshot or log payload above the backend limit — lower `screenshotJPEGQuality` / `maxScreenshotBytes`, or `maxScreenshots` to carry fewer images |
| "Screenshot N of M dropped: … exceeds the …-byte Firestore limit" | The image reached the transport larger than it can store. A custom transport with a hard limit must declare it via `ReportTransport.maxScreenshotBytes`, so the form compresses to that size instead of to `CollieConfiguration.maxScreenshotBytes` |
| Screenshots missing in the panel, no error anywhere | `screenshotCount` and the `_<index>` document ids must be written together — the panel reads only the numbered ids once the count is present |
| Report stuck at "queued" | Is the device on VPN? Try reaching the backend from Safari, then call `flushPendingUploads()` |
| Collie's traffic visible in your network-capture tool | Not expected (separate session); still, add `captureExclusionFragments` to the exclude list |
| Network view empty in the panel despite logs | The network entries don't carry the expected metadata keys (`method`, `url`, `status`…) — see §5; the raw entries are still there |
