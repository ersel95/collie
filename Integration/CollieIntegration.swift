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
//     <key>CollieEnvironment</key><string>$(COLLIE_ENVIRONMENT)</string>
//
//  3. Call `CollieIntegration.start()` at app startup (AFTER Olaf, if you use Olaf).
//

import Foundation
import Collie
// import Olaf   // Uncomment if you use Olaf.

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
            environment: plist("CollieEnvironment") ?? "staging"
        )

        // ── Olaf bridge (optional — uncomment if you use Olaf) ───────────────────────
        //
        // 1. Log snapshot: all logs at report time are woven into the Jira issue and
        //    attached as the collie-logs JSON.
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
        // 2. Recursion prevention: exclude Collie's Jira traffic from Olaf's capture.
        //    (Collie's own session carries no capture protocol — this is the 2nd safeguard.)
        //    When starting Olaf network capture:
        //    OlafNetworkConfiguration(excludedURLs: config.captureExclusionFragments + [...])

        Collie.configure(with: config)

        // Suggestion: retry pending (offline/VPN-less) reports on returning to foreground.
        // NotificationCenter.default.addObserver(
        //     forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        // ) { _ in Collie.flushPendingUploads() }
    }
}
