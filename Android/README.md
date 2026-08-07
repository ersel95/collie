# Collie for Android 🐕

**Shake the device → report it → an analyst pushes it to Jira.**

The Android port of [Collie](../README.md). Same product, same wire format, same panel: a report
filed from an Android device and one filed from an iPhone are the same document, so nothing
downstream has to know which platform it came from.

```
Tester shakes the device
  → ShakeDetector fires; the screen is captured (FLAG_SECURE windows are respected)
  → Banner: "Spotted a problem? Want to share it?"  (skipped when asksBeforeReporting = false)
  → [Yes] → Form: "What happened?" (+ name on first use)
  → Tap the screenshot → markup opens: circle the problem, Done
  → Backend: POST <reportsPath>  (multipart: report JSON + screenshot, x-collie-api-key)
  → Success: "Report sent" · Transient error: disk queue + automatic retry with backoff
  → Panel: analyst triages the report and pushes it to Jira
```

## Quick start

**1. The repository** (JitPack builds the artifacts from the git tag):

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

**2. The dependency** — the real artifact in debug, the no-op in release:

```kotlin
// build.gradle.kts (app module)
debugImplementation("com.github.ersel95.collie:collie:android-0.1.0")
releaseImplementation("com.github.ersel95.collie:collie-no-op:android-0.1.0")
```

**3. Start it** — once, from `Application.onCreate()`:

```kotlin
Collie.configure(
    context = this,
    configuration = CollieConfiguration(
        // Never a literal `true`: a BuildConfig field fed from non-prod secrets.
        enabled = BuildConfig.COLLIE_ENABLED,
        apiBaseUrl = BuildConfig.COLLIE_API_BASE_URL,
        apiKey = BuildConfig.COLLIE_API_KEY,
        environment = "staging",
        // Recommended: hand Collie your logs (see below).
        logSnapshotProvider = { logs.snapshot() },
        diagnostics = { message -> Log.d("Collie", message) },
    ),
)
```

That is the whole integration. Details, troubleshooting and the Firestore transport are in
[INTEGRATION.md](INTEGRATION.md); a file to copy is in
[`Integration/CollieIntegration.kt`](Integration/CollieIntegration.kt).

**See it working first:** [`example/`](example) is a complete host app — real HTTP traffic,
Chucker wired in beside Collie, the log bridge, tool hand-off, the debug/release artifact split.
Run it before integrating anything.

## Artifacts

| Artifact | What it is |
|---|---|
| `collie` | The reporter: core, Compose UI, HTTPS transport |
| `collie-firebase` | Firestore transport, for hosts whose network policy allows Firebase only |
| `collie-no-op` | Same public API, empty bodies — what a release build links |

The no-op is a **build-time** guarantee on top of the runtime one: `enabled` already defaults to
`false` and the SDK fails closed, but a release build that links `collie-no-op` does not contain a
shake detector, a screenshot path, an upload queue or any Compose UI to begin with. It also covers
`com.collie.firebase.FirestoreTransport`, so the one line that builds the transport compiles in
both variants without splitting your integration across source sets.

## Feeding it logs

Collie is **log-source agnostic** — it never depends on a logging library. At report time it asks
the host for a snapshot, and whatever the host hands over travels with the report, losslessly.

Writing that bridge is the host's job, and the example ships a complete one
([`CollieLogInterceptor`](example/src/main/java/com/collie/example/CollieLogInterceptor.kt)) that
sits on the same `OkHttpClient` as Chucker. Two things matter:

- **The metadata keys are a convention**, not free-form. The panel builds its Network view from
  `method` / `url` / `status` / `durationMs` and the `reqH.` / `respH.` header prefixes. Spell
  them differently and the report still uploads — it just shows a bare log line instead of a
  request.
- **Exclude Collie's own uploads.** A report is sent over HTTP like anything else; without an
  exclusion, filing a bug gets logged into the next report. Pass
  `configuration.captureExclusionFragments` — Collie's two endpoints as whole URLs, safe to
  match as substrings. (Before android-0.2.0 that property returned the host and path
  separately, and a `reportsPath` of `/post` silently swallowed the app's own `/posts` calls;
  the example app is where that surfaced.) Collie's own client carries none of the host's
  interceptors either, so this is the second of two safeguards.

## What is preserved from iOS

The behaviours the iOS SDK guarantees are the same here, and the unit tests mirror the Swift ones:

- **Opt-in + fail-closed** — `enabled` defaults to `false`; a blank required field means nothing
  is installed.
- **Two capture gates** — the build-time opt-in *and* the server-side kill switch, which
  **fails open** when unreachable so an offline tester can still file a report.
- **Queue idempotency** — the envelope id is reused on every retry (as the
  `x-collie-idempotency-key` header, or as the Firestore document id), so a response lost in
  transit cannot create a second report.
- **Process-safe retry** — queued reports schedule network-constrained WorkManager work, so the
  host process can exit and Android will recreate it to retry. The host must configure Collie from
  `Application.onCreate()`; an Android Force stop pauses scheduled work until the app is opened.
- **Lossless log stream** — every category the host provides is uploaded, unsummarised.
- **No PII in telemetry** — no IP, SSID or location, ever.
- **Markup replaces the image** — the editor only ever hands back a complete replacement, so
  marks a tester draws to hide something never travel separately from the pixels they cover.

Two places where Android differs, deliberately:

- **Secure screens.** iOS renders with `afterScreenUpdates: true` so the system masks secure
  text fields. Android has no such concept; instead Collie never attempts `PixelCopy` on a
  `FLAG_SECURE` window and falls back to drawing the view hierarchy. A host that marks a screen
  secure decided its pixels must not leave the device, and a bug reporter is not an exception.
- **The tester's name** lives in the app's preferences rather than the Keychain, so a reinstall
  asks for it once more. The alternative is a hardware identifier nobody consented to.

## Development

```bash
cd Android
./gradlew :collie:testDebugUnitTest        # unit tests
./gradlew :example:installDebug            # the Chucker example on a device/emulator
./gradlew :sample:installDebug             # the one-button harness
```

**Changing the UI? Run it.** A compiling UI is not a working one — two markup implementations
shipped broken on iOS because they were only compile-checked. `example/` and `sample/` exist so
the banner, the form and the markup editor can be driven on an emulator; a shake can be
simulated with `adb emu sensor set acceleration`.

Releasing: [../RELEASING.md](../RELEASING.md). Agent instructions: [AGENTS.md](AGENTS.md).
