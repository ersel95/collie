//
//  CollieIntegration.swift
//  ⚠️ This file is NOT part of the package — it is a reference template to copy into
//  the host project.
//
//  Setup:
//  1. Copy this file into your host project.
//  2. Provide the keys below via the xcconfig → Info.plist chain (the values never
//     enter the repo; in particular COLLIE_API_KEY lives only in non-prod
//     xcconfig/secrets):
//
//     // Secrets-NonProd.xcconfig (not committed to git)
//     COLLIE_ENABLED = YES
//     COLLIE_API_BASE_URL = https:/$()/collie-api.example.com
//     COLLIE_API_KEY = <ingestion-api-key from the panel's Admin · Apps page>
//     COLLIE_ENVIRONMENT = staging
//
//     // Corresponding Info.plist entries (resolved through Build Settings):
//     <key>CollieEnabled</key><string>$(COLLIE_ENABLED)</string>
//     <key>CollieApiBaseURL</key><string>$(COLLIE_API_BASE_URL)</string>
//     <key>CollieApiKey</key><string>$(COLLIE_API_KEY)</string>
//     <key>CollieEnvironment</key><string>$(COLLIE_ENVIRONMENT)</string>
//
//  3. Call `CollieIntegration.start()` at app startup (after your logging library, if
//     you feed logs from one).
//
//  Where reports go: the device uploads to the Collie backend — it never talks to Jira.
//  An analyst reviews the report in the panel and pushes it to Jira from there, choosing
//  the issue type, parent, assignee and labels. So no Jira project/parent/assignee/PAT
//  settings exist on the device any more.
//

import Foundation
import Collie
// import Olaf   // Uncomment if you feed logs from Olaf (see the bridge below).

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
        guard enabled,
              let baseURLString = plist("CollieApiBaseURL"),
              let baseURL = URL(string: baseURLString) else {
            return
        }

        var config = CollieConfiguration(
            enabled: true,
            apiBaseURL: baseURL,
            apiKey: plist("CollieApiKey") ?? "",
            environment: plist("CollieEnvironment") ?? "staging"
        )

        // Surface Collie's own status messages (queue/send/config errors). The
        // troubleshooting guide assumes this output exists — keep it wired, or route it
        // into your logging library (see the bridge below).
        config.diagnostics = { print($0) }

        // ── Log source (optional but recommended) ────────────────────────────────────
        //
        // Collie is log-source agnostic: map ANY logger's snapshot (Olaf, Netfox,
        // Pulse, os_log, your own) to [CollieLogEntry]. ALL entries are uploaded with the
        // report, in full, with their categories preserved — the panel derives its
        // network and navigation views from them (see the metadata key convention in the
        // CollieLogEntry docs) and the analyst can attach them to the Jira issue.
        //
        // Signed-in account: log a "customerNo" metadata key on every sign-in path
        // (LoginView, RememberMeLoginView, biometric re-login…) so the panel can show
        // which account was signed in. With Olaf:
        // Olaf.info("Signed in", category: .auth, metadata: ["customerNo": customerNo])
        //
        // Ready-made Olaf bridge — uncomment if your app uses Olaf:
        // config.logSnapshotProvider = {
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
        // config.sessionIDProvider = { Olaf.currentSessionID }
        // config.diagnostics = { Olaf.info($0) }
        //
        // Recursion prevention: if your logger captures network traffic, exclude
        // Collie's own endpoints from its capture. (Collie's session carries no capture
        // protocol — this is the 2nd safeguard.) With Olaf:
        // OlafNetworkConfiguration(excludedURLs: config.captureExclusionFragments + [...])

        Collie.configure(with: config)

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

        // Suggestion: retry pending (offline/VPN-less) reports on returning to foreground.
        // NotificationCenter.default.addObserver(
        //     forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        // ) { _ in Collie.flushPendingUploads() }
    }
}
