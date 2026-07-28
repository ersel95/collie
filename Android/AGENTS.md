# Collie for Android — Agent Guide

The Android port of Collie. Read the [root AGENTS.md](../AGENTS.md) first for the product: what a
report is, why the device never talks to Jira, and what the panel does with it. This file covers
what is specific to Android.

| Task | Read |
|---|---|
| **Integrating Collie into a host app** | [INTEGRATION.md](INTEGRATION.md) + [`Integration/CollieIntegration.kt`](Integration/CollieIntegration.kt) (the file to copy) + [`example/`](example) (a working reference) |
| Developing Collie for Android | This file |

## Layout

```
Android/
  collie/           core + Compose UI + HTTPS transport   (published: collie)
  collie-firebase/  Firestore transport                   (published: collie-firebase)
  collie-no-op/     same API, empty bodies                (published: collie-no-op)
  example/          host app with Chucker — the reference integration
  sample/           one-button harness + API-compatibility gate
```

The Swift package stays at the repository root, so SPM resolution is unaffected by these sources;
`android-*` tags are not semver, so SPM ignores them. Releasing: [../RELEASING.md](../RELEASING.md).

## Commands

```bash
cd Android
./gradlew :collie:testDebugUnitTest                    # unit tests
./gradlew :example:installDebug                        # the reference app
./gradlew :sample:assembleDebug -PcollieNoOp=true      # the no-op compatibility gate
```

No JDK on the PATH? Android Studio ships one:
`JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`.

## Behaviours that MUST be preserved

These are the iOS guarantees, and they hold here for the same reasons — do not make breaking
changes:

- **Opt-in + fail-closed.** `enabled` defaults to `false`; a blank required field (`apiKey`,
  `apiBaseUrl`, the endpoint paths) means nothing is installed. The `collie-no-op` artifact is the
  build-time half of the same promise: a release build must contain no reporter code at all.
- **Two capture gates.** The local build-time opt-in **and** the server-side kill switch. The
  remote check **fails open** when unreachable — a tester offline must still be able to file a
  report and have it queued.
- **Recursion prevention.** Collie's `IngestionClient` builds its own `OkHttpClient` and inherits
  none of the host's interceptors, so a report upload is never captured by the host's logger.
- **Queue idempotency.** The envelope id is reused on every retry — as the
  `x-collie-idempotency-key` header (HTTPS) or as the Firestore document id (Firebase) — so a
  response lost in transit cannot create a second report (`UploadQueueTest`).
- **The envelope is the contract.** `app` / `device` / `report` / `entries` / `telemetry`,
  ISO-8601 dates, absent values omitted rather than `null`, **no app key** (the backend resolves
  the app from the api-key; the Firestore transport adds `appKey` on top). `ReportEnvelopeTest`
  locks the shape in, and it must keep matching `ReportEnvelopeTests.swift`.
- **Lossless entries.** Every category the host provides is uploaded, unsummarised — the panel
  derives its network and navigation views from that raw stream.
- **No PII in telemetry.** No IP, SSID or location, ever.
- **`FLAG_SECURE` is honoured.** `PixelCopy` is not attempted on a secure window; the fallback
  draws the view hierarchy. Do not add a path around this.
- **Markup replaces the image.** `MarkupEditor` hands back a complete replacement bitmap,
  flattened at the screenshot's native pixel size, or `null` on cancel. Nothing downstream knows
  markup exists — marks a tester draws to hide something must never travel separately from the
  pixels they cover. The display scale is what maps stroke coordinates back to full resolution;
  get it wrong and the marks land somewhere else in the uploaded image.
- **Core stays log-source agnostic.** No logging-library types or names in `collie/src` — concrete
  bridges live in the example and in the docs.

## Changing the UI? Run it.

A compiling UI is not a working one — two markup implementations shipped broken on iOS because
they were only compile-checked. Drive it on an emulator:

```bash
./gradlew :example:installDebug
adb shell am start -n com.collie.example/.ExampleActivity
# shake:
for i in 1 2 3 4; do
  adb emu sensor set acceleration 40:40:40;  sleep 0.15
  adb emu sensor set acceleration -40:-40:-40; sleep 0.15
done
adb emu sensor set acceleration 0:9.81:0
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png .
```

⚠️ The banner self-dismisses after 6 seconds. Script the shake and the tap that follows it in one
go — inspecting a screenshot in between is slow enough that the banner is gone by the time you
tap, and the tap then lands on the app underneath.

Inspecting what a report actually contains, without a backend:

```bash
adb shell cmd connectivity airplane-mode enable    # force the queue path
# … file a report …
adb shell run-as <applicationId> ls cache/collie/uploads
adb shell run-as <applicationId> cat cache/collie/uploads/<id>.report | python3 -m json.tool
```

## Language

All code comments, docs and commit messages are in English.
