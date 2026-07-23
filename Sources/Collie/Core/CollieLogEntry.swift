import Foundation

/// A log entry the host app hands to Collie. Collie has no dependency on any logging
/// library; the host maps its own log snapshot to this type and provides it via
/// `CollieConfiguration.logSnapshotProvider`.
///
/// Example mapping from a host logging library:
/// ```swift
/// config.logSnapshotProvider = {
///     MyLogger.snapshot().map {
///         CollieLogEntry(
///             date: $0.date,
///             level: $0.level.rawValue,
///             category: $0.category.rawValue,
///             message: $0.message,
///             metadata: $0.metadata
///         )
///     }
/// }
/// ```
///
/// Metadata key convention for network entries (used to build the issue's Network
/// section): `method`, `url`, `status`, `durationMs`, `reqBytes`, `respBytes`, `error`,
/// `requestBody`, `responseBody`; request headers use the `reqH.` prefix, response
/// headers the `respH.` prefix. Navigation entries: `screen`, `kind`.
///
/// One more key, on any entry of any category: `customerNo`. Hosts write it on their
/// sign-in log entries; the newest non-empty value becomes the issue description's
/// "Customer no" row, so a report shows which account was signed in when the bug was
/// captured. Without it the row is simply omitted.
public struct CollieLogEntry: Codable, Sendable {
    public let date: Date
    public let level: String
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(
        date: Date,
        level: String,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}
