//
//  CollieIntegration.swift
//  ⚠️ This file is NOT part of the package — it is a reference template to copy into
//  the host project.
//
//  Collie can deliver a report two ways. Pick the one your app's network policy allows:
//
//  A) Firebase (CollieFirebase product) — the report is written to Firestore and a
//     server-side bridge moves it into the analyst panel. Use this when the app may
//     only reach a fixed set of hosts (a banking app allowed to talk to Firebase and
//     its own API, and nothing else). This is what the Yk apps use.
//
//  B) Direct HTTPS (core Collie only) — one multipart POST to the Collie backend.
//     Simpler, but requires the device to reach that host.
//
//  Both paths end in the same place: an analyst reviews the report in the panel and
//  pushes it to Jira. The device never talks to Jira and holds no Jira credentials.
//
//  ── Setup for (A) Firebase ───────────────────────────────────────────────────
//  1. SPM: add the `collie` package and link the **CollieFirebase** product to the app
//     target (linking only `Collie` will not compile the transport below).
//  2. The app must already be a Firebase app: `GoogleService-Info.plist` in the target
//     and `FirebaseApp.configure()` called BEFORE `CollieIntegration.start()`.
//  3. Provide the keys via the xcconfig → Info.plist chain:
//
//     // Secrets-NonProd.xcconfig
//     COLLIE_ENABLED = YES
//     COLLIE_APP_KEY = <app key from the panel: Admin · Apps>
//
//     // Info.plist (resolved through Build Settings)
//     <key>CollieEnabled</key><string>$(COLLIE_ENABLED)</string>
//     <key>CollieAppKey</key><string>$(COLLIE_APP_KEY)</string>
//
//     COLLIE_APP_KEY is NOT a secret — it names the app on each report, and write
//     access is governed by Firestore security rules. (See Integration/firestore.rules.)
//
//  ── Setup for (B) HTTPS ──────────────────────────────────────────────────────
//     COLLIE_API_BASE_URL = https:/$()/collie-api.example.com
//     COLLIE_API_KEY      = <ingestion api-key from Admin · Apps>   // this IS a secret
//     …and use the `Collie.configure(with:)` call marked (B) below.
//
//  4. Call `CollieIntegration.start()` at app startup (after your logging library, and
//     after FirebaseApp.configure() when using (A)).
//

import Foundation
import Collie
import CollieFirebase   // (A) only — remove when using the HTTPS path
// import Olaf          // Uncomment if you feed logs from Olaf (see the bridge below).

enum CollieIntegration {

    /// Reads a string from Info.plist (blank values count as nil).
    private static func plist(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static func start() {
        // Local opt-in gate: if the key is missing/NO, Collie never runs (fail-closed).
        let enabled = (plist("CollieEnabled") as NSString?)?.boolValue ?? false
        guard enabled, let appKey = plist("CollieAppKey") else { return }

        // (A) Firebase: `apiBaseURL` is unused by FirestoreTransport — it only satisfies
        // the initialiser. Nothing is ever sent to it.
        var configuration = CollieConfiguration(
            enabled: true,
            apiBaseURL: URL(string: "https://firestore.googleapis.com")!,
            environment: "staging"
        )

        // (B) HTTPS — swap the block above for this one:
        // var configuration = CollieConfiguration(
        //     enabled: true,
        //     apiBaseURL: URL(string: plist("CollieApiBaseURL") ?? "")!,
        //     apiKey: plist("CollieApiKey") ?? "",
        //     environment: "staging"
        // )

        // Surface Collie's own status messages (queue/send/config errors). The
        // troubleshooting guide assumes this output exists — keep it wired, or route it
        // into your logging library (see the bridge below).
        configuration.diagnostics = { print($0) }

        // ── Log source (optional but recommended) ────────────────────────────────────
        //
        // Collie is log-source agnostic: map ANY logger's snapshot (Olaf, Netfox,
        // Pulse, os_log, your own) to [CollieLogEntry]. ALL entries are uploaded with the
        // report **in full, losslessly, with their categories preserved**; the panel
        // derives its Network and Navigation views from them (see the metadata key
        // convention in the CollieLogEntry docs).
        //
        // Signed-in account: log a "customerNo" metadata key on every sign-in path so the
        // panel can show which account was in use. With Olaf:
        // Olaf.info("Signed in", category: .auth, metadata: ["customerNo": customerNo])
        //
        // Ready-made Olaf bridge — uncomment if your app uses Olaf:
        // configuration.logSnapshotProvider = {
        //     Olaf.snapshot().map {
        //         CollieLogEntry(
        //             date: $0.date,
        //             level: $0.level.rawValue,
        //             category: $0.category.rawValue,
        //             message: $0.message,
        //             metadata: $0.metadata
        //         )
        //     }
        // }
        // configuration.sessionIDProvider = { Olaf.currentSessionID }
        // configuration.diagnostics = { Olaf.info($0) }
        //
        // Recursion prevention: if your logger captures network traffic, exclude Collie's
        // destination from that capture. With (A) that means the Firebase hosts
        // ("firestore.googleapis.com"); with (B) use `configuration.captureExclusionFragments`.

        // (A) Firebase transport. The app key groups reports in the panel.
        Collie.configure(
            with: configuration,
            transport: FirestoreTransport(configuration: .init(appKey: appKey))
        )

        // (B) HTTPS transport — the default when no transport is passed:
        // Collie.configure(with: configuration)

        // ── Switching between shake-activated tools (optional) ───────────────────────
        //
        // Both Collie and viewer-style tools (e.g. Olaf's log viewer) can react to the
        // same shake. Wire the logo callbacks so testers can hop between them:
        // Collie.onLogoTap { OlafUI.present() }         // Collie logo → open Olaf
        // OlafUI.onLogoTap { /* Collie opens on the next shake */ }
        //
        // Wiring the logos does NOT change shake behavior — that is decided by
        // `config.asksBeforeReporting` (default true: a shake asks first; set it to
        // false to open the report sheet straight away).

        // Suggestion: retry pending (offline) reports on returning to foreground.
        // NotificationCenter.default.addObserver(
        //     forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        // ) { _ in Collie.flushPendingUploads() }
    }
}
