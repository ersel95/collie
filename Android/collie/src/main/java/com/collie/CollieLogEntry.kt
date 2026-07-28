package com.collie

/**
 * A log entry the host app hands to Collie. Collie has no dependency on any logging
 * library; the host maps its own log snapshot to this type and provides it via
 * [CollieConfiguration.logSnapshotProvider].
 *
 * Example mapping from a host logging library (Olaf):
 * ```kotlin
 * config.logSnapshotProvider = {
 *     Olaf.snapshot().map {
 *         CollieLogEntry(
 *             epochMillis = it.timestamp,
 *             level = it.level.name.lowercase(),
 *             category = it.category.name.lowercase(),
 *             message = it.message,
 *             metadata = it.metadata,
 *         )
 *     }
 * }
 * ```
 *
 * Metadata key convention for network entries (used to build the issue's Network
 * section): `method`, `url`, `status`, `durationMs`, `reqBytes`, `respBytes`, `error`,
 * `requestBody`, `responseBody`; request headers use the `reqH.` prefix, response
 * headers the `respH.` prefix. Navigation entries: `screen`, `kind`.
 *
 * One more key, on any entry of any category: `customerNo`. Hosts write it on their
 * sign-in log entries; the newest non-empty value becomes the issue description's
 * "Customer no" row, so a report shows which account was signed in when the bug was
 * captured. Without it the row is simply omitted.
 *
 * The timestamp is epoch milliseconds rather than a `Date`/`Instant`: the host's logger
 * already has one, and it serialises to the same ISO-8601 string the iOS SDK sends, so
 * the panel reads either platform's report with one parser.
 */
public data class CollieLogEntry(
    public val epochMillis: Long,
    public val level: String,
    public val category: String,
    public val message: String,
    public val metadata: Map<String, String> = emptyMap(),
)
