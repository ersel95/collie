# Collie Integration Guide

## 1. Add the package

Xcode → Package Dependencies → Collie repo URL → add `Collie` to the host app target.

## 2. Jira prerequisites

| Requirement | Description |
|---|---|
| Jira Server / Data Center | REST v2 + Personal Access Token (Bearer) support |
| PAT | Token of the account that will create the reports (recommendation: a service account). Jira → Profile → Personal Access Tokens |
| Parent task | The task reports are grouped under (e.g. `PROJ-123`). Must be in the **same project** as `projectKey`, otherwise Jira returns 400 |
| Subtask type name | The actual name in your Jira installation ("Sub-task", "Alt görev"…). Wrong name → 400 |
| Assignee | Jira username the subtasks are assigned to (`assignee.name`) |
| Network | Corporate Jira is usually reachable only over VPN; the device needs VPN |

## 3. xcconfig / Info.plist keys

The values **never enter the repo** — they live in non-prod xcconfig/secrets. See the
`Integration/CollieIntegration.swift` template for the key list and the Info.plist
mapping:

`COLLIE_ENABLED`, `COLLIE_JIRA_BASE_URL`, `COLLIE_JIRA_PAT`, `COLLIE_JIRA_PROJECT_KEY`,
`COLLIE_JIRA_PARENT_KEY`, `COLLIE_JIRA_SUBTASK_TYPE`, `COLLIE_JIRA_ASSIGNEE`,
`COLLIE_ENVIRONMENT`

> ⚠️ `COLLIE_ENABLED` is not defined (or is `NO`) in release/prod xcconfig. Collie is
> fail-closed: when the key is missing, none of its code runs.

## 4. Startup

Copy the `CollieIntegration.swift` template into your project and call it at app startup:

```swift
CollieIntegration.start()
```

## 5. Feeding logs (any source)

Collie is **log-source agnostic**: it takes logs through the
`config.logSnapshotProvider` closure as `[CollieLogEntry]`. Any logger works — Olaf,
Netfox, Pulse, os_log, or your own. ALL provided entries are uploaded to the Jira issue
in full as a `collie-logs-*.json` attachment; entries with category `network` /
`navigation` additionally feed the issue description's Network/Navigation sections.

For the description sections to populate, network entries should carry these metadata
keys: `method`, `url`, `status`, `durationMs`, `error`, `requestBody`, `responseBody`
(headers: `reqH.` / `respH.` prefixes); navigation entries: `screen`, `kind`. Entries
without them still travel in the JSON attachment.

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

Exclude Collie's Jira endpoints from your capture tool, e.g. with Olaf:

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

## 6. Offline / VPN behavior

- When Jira is unreachable (no VPN, network error, 5xx) the report is **queued to disk**
  (`Caches/Collie/uploads/`, encrypted with `.completeFileProtection` on iOS) and retried
  with exponential backoff (default 5 attempts, 48-hour TTL).
- If the issue was created but attachments were left unfinished, the retry **does not
  create a duplicate issue** — it resumes from the remaining step using the `issueKey`
  stored in the envelope.
- The queue is retried automatically at app startup. To also retry on returning to the
  foreground:
  ```swift
  Collie.flushPendingUploads()
  ```

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Banner never appears on shake | `COLLIE_ENABLED` is NO/missing, or a required Jira field is blank (fail-closed). Check the `config.diagnostics` output. In the simulator use Device → Shake (⌃⌘Z) |
| "PAT is invalid or expired (401)" | Renew the PAT; the token needs permissions in the target project |
| HTTP 400: "Parent issue not found" etc. | `COLLIE_JIRA_PARENT_KEY` is wrong or in a different project than `projectKey` |
| HTTP 400: issue type error | `COLLIE_JIRA_SUBTASK_TYPE` doesn't match the actual subtask type name in Jira |
| Report stuck at "queued" | Is the device on VPN? Try reaching Jira from Safari, then call `flushPendingUploads()` |
| Attachment missing but issue created | The attachment may have been skipped on a permanent error (e.g. size limit) — check the diagnostics output |
| Jira traffic visible in your network-capture tool | Not expected (separate session); still, add `captureExclusionFragments` to the exclude list |
| Network section empty despite logs | The network entries don't carry the expected metadata keys (`method`, `url`, `status`…) — see §5; the full entries are still in the JSON attachment |
