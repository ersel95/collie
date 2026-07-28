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

**The exclusion list is matched on whole URLs, not fragments.** Collie also offers
`configuration.captureExclusionFragments` (host and path as separate strings), and this example
used it first — with `reportsPath = "/post"`, the fragment `/post` also matched the app's own
`GET /posts`, and every request the tester wanted reported was silently dropped from the report.
Whole-URL prefixes cannot misfire that way.

## No backend needed

The example points `apiBaseUrl` at `postman-echo.com`, whose `/post` endpoint accepts the
multipart upload and answers 200 — enough to walk the "Sent" path end to end without deploying
anything. Point it at a real Collie backend, or swap in `FirestoreTransport`, and nothing else
changes.
