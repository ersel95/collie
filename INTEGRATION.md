# Collie Integration Guide

## 1. Add the package

Xcode → Package Dependencies → Collie repo URL → add `Collie` to the host app target.

## 2. Backend prerequisites

Collie uploads reports to the Collie backend; analysts triage them in the panel and push
them to Jira from there. **Nothing Jira-related is configured on the device.**

| Requirement | Description |
|---|---|
| Collie backend | A reachable deployment; its root URL becomes `COLLIE_API_BASE_URL` |
| App record | Create the app on the panel's **Admin · Apps** page. Its Jira project, default issue type, retention and the `captureEnabled` kill switch live there |
| Ingestion api-key | Generated with the app record and **shown once** — it identifies the app *and* authenticates uploads. Rotate it from the same page |
| Network | A corporate backend is usually reachable only over VPN; without it reports queue on the device |

## 3. xcconfig / Info.plist keys

The values **never enter the repo** — they live in non-prod xcconfig/secrets. See the
`Integration/CollieIntegration.swift` template for the key list and the Info.plist
mapping:

`COLLIE_ENABLED`, `COLLIE_API_BASE_URL`, `COLLIE_API_KEY`, `COLLIE_ENVIRONMENT`

> ⚠️ `COLLIE_ENABLED` is not defined (or is `NO`) in release/prod xcconfig. Collie is
> fail-closed: when the key is missing, none of its code runs.

If your deployment mounts the API somewhere other than the default
(`/api/v1/collie/reports` and `/api/v1/collie/config`), override
`config.reportsPath` / `config.configPath` before calling `Collie.configure`.

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

Exclude Collie's own endpoints from your capture tool, e.g. with Olaf:

```swift
OlafNetworkConfiguration(
    excludedURLs: config.captureExclusionFragments + existingList
)
```

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

## 6. Offline / VPN behavior

- When the backend is unreachable (no VPN, network error, 5xx) the report is **queued to
  disk** (`Caches/Collie/uploads/`, encrypted with `.completeFileProtection` on iOS) and
  retried with exponential backoff (default 5 attempts, 48-hour TTL).
- A retry **cannot create a duplicate report**: the queue reuses the report's original id
  as an idempotency key (`x-collie-idempotency-key`), so even a response lost in transit
  resolves to the same report server-side.
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
| Banner never appears on shake | `COLLIE_ENABLED` is NO/missing, or `COLLIE_API_KEY`/`COLLIE_API_BASE_URL` is blank (fail-closed). Check the `config.diagnostics` output. In the simulator use Device → Shake (⌃⌘Z) |
| Banner disappeared after working before | The app's `captureEnabled` kill switch was turned off in the panel (§7) |
| "api-key is invalid or disabled (401)" | The api-key is wrong or was rotated — copy the current one from Admin · Apps |
| HTTP 400 with a validation message | The payload was rejected (e.g. too many log entries). The message carries the backend's reason |
| "Report is too large (413)" | Screenshot or log payload above the backend limit — lower `screenshotJPEGQuality` / `maxScreenshotBytes` |
| Report stuck at "queued" | Is the device on VPN? Try reaching the backend from Safari, then call `flushPendingUploads()` |
| Collie's traffic visible in your network-capture tool | Not expected (separate session); still, add `captureExclusionFragments` to the exclude list |
| Network view empty in the panel despite logs | The network entries don't carry the expected metadata keys (`method`, `url`, `status`…) — see §5; the raw entries are still there |
