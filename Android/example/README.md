# Collie example — a host app with Chucker and Collie side by side

A small app that actually talks to the network, so there is real traffic to inspect and real log
entries to travel inside a report. It is the reference integration: everything
[INTEGRATION.md](../INTEGRATION.md) describes is wired up here and verified on an emulator.

```bash
cd Android
./gradlew :example:installDebug
```

## What to do with it

1. **Load posts** — a real `GET https://jsonplaceholder.typicode.com/posts`.
   *(Reports go to Firestore when a `google-services.json` is present, to a public echo service
   otherwise — see [below](#two-transports-and-which-one-you-get).)*
2. **Open Chucker** — the request is there, with headers, body and timings.
3. **Break something** — fires a call that 404s. This is the bug.
4. **Shake the device** (emulator: `adb emu sensor set acceleration 40:40:40`, a few times in
   quick succession) → the banner slides in. The app underneath stays usable.
5. **Yes** → the form, with the screenshot already captured. Tap it to circle the problem.
6. **Send** → "Report sent". Turn airplane mode on first and it says "Queued" instead — the
   report is on disk and retried automatically.

The report that leaves the device carries the same two requests Chucker showed you, with their
status codes, durations and headers, plus the navigation and app lines around them.

## The parts worth reading

| File | What it shows |
|---|---|
| [`ExampleApp.kt`](src/main/java/com/collie/example/ExampleApp.kt) | The whole integration in one file: configuration → HTTP client with both tools → `Collie.configure` → tool hand-off |
| [`CollieLogInterceptor.kt`](src/main/java/com/collie/example/CollieLogInterceptor.kt) | The log bridge every host has to write — metadata conventions, header redaction, recursion prevention |
| [`build.gradle.kts`](build.gradle.kts) | The debug/release artifact split for **both** tools, and `COLLIE_ENABLED` as a BuildConfig field |

## Two things the example gets right on purpose

**Chucker and Collie are not alternatives.** Chucker shows a developer what a request did, now,
on this device. Collie puts that same traffic in front of an analyst later, in a report, next to
the screenshot and the tester's sentence. Chucker exposes no API to read its store, so the traffic
is captured once by the bridge and handed to both.

**This example is where a real SDK bug surfaced.** `configuration.captureExclusionFragments` used
to return Collie's host and path as *separate* strings. With `reportsPath = "/post"`, the entry
`/post` also matched the app's own `GET /posts` — so every request the tester wanted reported was
silently dropped, and the report uploaded looking perfectly fine, just empty. It now returns whole
URLs (iOS 1.13.0 / android-0.2.0), which cannot misfire that way, and the example passes it
straight through.

## Two transports, and which one you get

The example picks its transport from whether a `google-services.json` sits next to this file:

| `google-services.json` | Transport | Where the report goes |
|---|---|---|
| present | `FirestoreTransport` | `collie_reports/<id>` in your Firebase project — the analyst panel reads it from there |
| absent | HTTPS `IngestionClient` | `postman-echo.com/post`, a public echo service that answers 200 and stores nothing |

That file is **git-ignored**: it points at a specific Firebase project, so it is a local file
rather than a committed one. Without it the example still builds and runs the whole flow end to
end — which is also how CI builds it.

To use the Firestore path, drop your project's `google-services.json` in this directory, set
`COLLIE_APP_KEY` in `build.gradle.kts` to a key that exists in the panel's app records
(`collie_apps`), and rebuild. A key the panel does not know still writes to Firestore, but the
report will not be attached to any app there.
