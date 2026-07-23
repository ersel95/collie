//
//  CollieIntegration.swift
//  ⚠️ This file is NOT part of the package — it is a reference template to copy into
//  the host project.
//
//  Setup:
//  1. Copy this file into your host project.
//  2. Provide the keys below via the xcconfig → Info.plist chain (the values never
//     enter the repo; in particular COLLIE_JIRA_PAT lives only in non-prod
//     xcconfig/secrets):
//
//     // Secrets-NonProd.xcconfig (not committed to git)
//     COLLIE_ENABLED = YES
//     COLLIE_JIRA_BASE_URL = https:/$()/jira.example.com
//     COLLIE_JIRA_PAT = <personal-access-token>
//     COLLIE_JIRA_PROJECT_KEY = PROJ
//     COLLIE_JIRA_PARENT_KEY = PROJ-123
//     COLLIE_JIRA_SUBTASK_TYPE = Sub-task
//     COLLIE_JIRA_ASSIGNEE = jira.username
//     COLLIE_JIRA_LABELS = collie,ios-report        // optional, comma-separated
//     COLLIE_ENVIRONMENT = staging
//
//     // Corresponding Info.plist entries (resolved through Build Settings):
//     <key>CollieEnabled</key><string>$(COLLIE_ENABLED)</string>
//     <key>CollieJiraBaseURL</key><string>$(COLLIE_JIRA_BASE_URL)</string>
//     <key>CollieJiraPAT</key><string>$(COLLIE_JIRA_PAT)</string>
//     <key>CollieJiraProjectKey</key><string>$(COLLIE_JIRA_PROJECT_KEY)</string>
//     <key>CollieJiraParentKey</key><string>$(COLLIE_JIRA_PARENT_KEY)</string>
//     <key>CollieJiraSubtaskType</key><string>$(COLLIE_JIRA_SUBTASK_TYPE)</string>
//     <key>CollieJiraAssignee</key><string>$(COLLIE_JIRA_ASSIGNEE)</string>
//     <key>CollieJiraLabels</key><string>$(COLLIE_JIRA_LABELS)</string>
//     <key>CollieEnvironment</key><string>$(COLLIE_ENVIRONMENT)</string>
//
//  3. Call `CollieIntegration.start()` at app startup (after your logging library, if
//     you feed logs from one).
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
              let baseURLString = plist("CollieJiraBaseURL"),
              let baseURL = URL(string: baseURLString) else {
            return
        }

        var config = CollieConfiguration(
            enabled: true,
            jiraBaseURL: baseURL,
            pat: plist("CollieJiraPAT") ?? "",
            projectKey: plist("CollieJiraProjectKey") ?? "",
            parentIssueKey: plist("CollieJiraParentKey") ?? "",
            subtaskIssueType: plist("CollieJiraSubtaskType") ?? "Sub-task",
            assigneeUsername: plist("CollieJiraAssignee") ?? "",
            defaultLabels: CollieConfiguration.labels(fromCommaSeparated: plist("CollieJiraLabels")),
            environment: plist("CollieEnvironment") ?? "staging"
        )

        // Surface Collie's own status messages (queue/send/config errors). The
        // troubleshooting guide assumes this output exists — keep it wired, or route it
        // into your logging library (see the bridge below).
        config.diagnostics = { print($0) }

        // ── Log source (optional but recommended) ────────────────────────────────────
        //
        // Collie is log-source agnostic: map ANY logger's snapshot (Olaf, Netfox,
        // Pulse, os_log, your own) to [CollieLogEntry]. ALL entries are attached to the
        // Jira issue as collie-logs JSON; network/navigation entries also feed the
        // issue description (see the metadata key convention in CollieLogEntry docs).
        // Each network request is additionally attached as its own net-*.txt file,
        // linked from the description's Network table (cap: config.maxNetworkAttachments,
        // default 50 — set it to 0 to turn per-request files off).
        //
        // Signed-in account: log a "customerNo" metadata key on every sign-in path
        // (LoginView, RememberMeLoginView, biometric re-login…) and the report's
        // Report table gets a "Customer no" row with the newest value. With Olaf:
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
        // Collie's Jira endpoints from its capture. (Collie's own session carries no
        // capture protocol — this is the 2nd safeguard.) With Olaf:
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
