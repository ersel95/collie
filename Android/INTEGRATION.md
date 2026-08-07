# Integrating Collie into an Android app

The short version is in [README.md](README.md#quick-start). This file covers the details, the
Firestore transport, and what goes wrong.

A working reference implementation of everything below is [`example/`](example) — a host app with
Chucker beside Collie, a real log bridge and real traffic. Run it first; it is faster than reading.

---

## 1. Prerequisites

- `minSdk ≥ 26`, Compose available in the app (Collie's UI is Compose; the library brings its own
  dependency, the host does not have to be a Compose app).
- Somewhere to send reports: a Collie backend over HTTPS, **or** a Firebase project (see §5).

## 2. Dependency

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }   // ← required
    }
}
```

**Skipping the JitPack line is the most common failure** — the dependency simply cannot resolve.
If the project uses `FAIL_ON_PROJECT_REPOS`, the line must go in `dependencyResolutionManagement`,
not in a module.

```kotlin
// build.gradle.kts (app module)
debugImplementation("com.github.ersel95.collie:collie:android-0.1.0")
releaseImplementation("com.github.ersel95.collie:collie-no-op:android-0.1.0")
```

With a version catalog:

```toml
[versions]
collie = "android-0.1.0"

[libraries]
collie = { module = "com.github.ersel95.collie:collie", version.ref = "collie" }
collie-no-op = { module = "com.github.ersel95.collie:collie-no-op", version.ref = "collie" }
collie-firebase = { module = "com.github.ersel95.collie:collie-firebase", version.ref = "collie" }
```

## 3. The keys

Secrets never enter the repository. Feed them through `BuildConfig` fields from a file that is
git-ignored (`local.properties`, a keystore file, CI variables — whatever the project already
uses):

```kotlin
// build.gradle.kts
android {
    defaultConfig {
        buildConfigField("String", "COLLIE_API_BASE_URL", "\"${secret("collieBaseUrl")}\"")
        buildConfigField("String", "COLLIE_API_KEY", "\"${secret("collieApiKey")}\"")
    }
    buildTypes {
        debug   { buildConfigField("boolean", "COLLIE_ENABLED", "true") }
        release { buildConfigField("boolean", "COLLIE_ENABLED", "false") }   // ⚠️ never true
    }
    buildFeatures { buildConfig = true }
}
```

- **HTTPS path:** `COLLIE_ENABLED`, `COLLIE_API_BASE_URL`, `COLLIE_API_KEY` (a real secret — it
  both identifies the app and authenticates the upload).
- **Firebase path:** `COLLIE_ENABLED` and `COLLIE_APP_KEY` (the app record's key from Admin ·
  Apps — **not** a secret; write access is enforced by the Firestore rules), plus
  `google-services.json` and `FirebaseApp.initializeApp()` before Collie starts.

## 4. Starting it

Copy [`Integration/CollieIntegration.kt`](Integration/CollieIntegration.kt) into the app and call
it from `Application.onCreate()`. That file is not part of the artifact; it exists to be copied.
Starting from the application is also required for background retries: WorkManager recreates the
application process, then Collie's worker uses the transport configured there to drain the queue.

Order matters when a logging bridge is involved: build the configuration first (it is what tells
the bridge which URLs to skip), then the HTTP client, then start Collie.

## 5. The Firestore transport

For hosts whose network policy allows Firebase but not arbitrary destinations:

```kotlin
debugImplementation("com.github.ersel95.collie:collie-firebase:android-0.1.0")
```

```kotlin
Collie.configure(
    context = this,
    configuration = configuration,           // apiBaseUrl/apiKey are not needed here
    transport = FirestoreTransport(
        FirestoreTransport.Configuration(appKey = BuildConfig.COLLIE_APP_KEY),
    ),
)
```

The report lands in `collie_reports/<reportId>` with its screenshot base64-encoded in
`collie_report_screenshots/<reportId>` — Cloud Storage needs a paid plan, so it is deliberately
not used. Rules template: [`../Integration/firestore.rules`](../Integration/firestore.rules).

A custom transport brings its own destination and credentials, so Collie skips the HTTPS field
validation when one is passed.

## 6. Feeding logs

```kotlin
CollieConfiguration(
    …,
    logSnapshotProvider = { logs.snapshot() },   // your logger → List<CollieLogEntry>
    sessionIdProvider = { logs.sessionId },      // optional
)
```

Metadata key convention (this is what the panel's Network view is built from):

| Key | Meaning |
|---|---|
| `method`, `url`, `status`, `durationMs` | the request |
| `reqBytes`, `respBytes`, `error` | size and failure |
| `requestBody`, `responseBody` | bodies, if you capture them |
| `reqH.<Name>`, `respH.<Name>` | headers |
| `screen`, `kind` | navigation entries |
| `customerNo` | on any entry — the newest non-empty value becomes the report's "Customer no" row |

**Redact credentials.** A bug report is read by more people than a developer's device: strip
`Authorization`, `Cookie` and anything equivalent before it goes into an entry. The example does
this in `putHeaders`.

**Recursion prevention.** Exclude Collie's own uploads from your capture: pass
`configuration.captureExclusionFragments`, which returns Collie's two endpoints as whole URLs —
safe to match as substrings, however your capture tool does it.

Before `android-0.2.0` that property returned the host and the path as separate entries, and a
short `reportsPath` was a trap: `/post` also matched the app's own `GET /posts`, so those requests
vanished from every report. Nothing looked wrong — the report still uploaded, just empty. If you
are pinned to an older version, exclude `configuration.reportsUrl` and `configuration.configUrl`
instead.

## 7. Living beside another tool

If another shake-activated tool is installed (Olaf), give the gesture to one of them:

```kotlin
CollieConfiguration(activatesOnShake = false, …)   // Collie opens only via presentReport()
```

and wire the hand-off in both directions:

```kotlin
Collie.onLogoTap { startActivity(Chucker.getLaunchIntent(this)) }
```

The handler runs **after** Collie's UI has fully closed, so starting another activity from it is
safe. Without this both tools answer the same shake and Collie's banner ends up buried.

## 8. Verifying

Shake the device (emulator: `adb emu sensor set acceleration 40:40:40` a few times in quick
succession) → the banner appears → submit the form → the report shows up in the panel with its
screenshot, the full log stream and the derived views.

If nothing happens:

| Symptom | Cause |
|---|---|
| No banner at all | `enabled` false, or a required field blank — check the `diagnostics` output; Collie stays silently off (fail-closed) |
| No banner, diagnostics quiet | The panel flipped the app's `captureEnabled` kill switch off |
| "Queued" on every submission | Backend unreachable (VPN?). The report is on disk and WorkManager retries it in the background; `Collie.flushPendingUploads()` still prompts an immediate foreground retry |
| 401 / 403 | api-key wrong or disabled |
| 400 | Payload rejected — check the envelope against the backend's contract |
| Report arrives without logs | `logSnapshotProvider` not set, or your exclusion list is swallowing the traffic (see §6) |

Background work survives leaving the app, process death, device restarts and removing the app from
Recents. Android deliberately suspends all scheduled work after a **Force stop** in system settings;
opening the app again re-enables it. Uninstalling the app removes both the private queue and its work.
