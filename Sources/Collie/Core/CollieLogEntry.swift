import Foundation

/// A log entry the host app hands to Collie. Collie has no hard dependency on any
/// logging library (e.g. Olaf); the host maps its own log snapshot to this type and
/// provides it via `CollieConfiguration.logSnapshotProvider`.
///
/// Example mapping from Olaf:
/// ```swift
/// config.logSnapshotProvider = {
///     Olaf.snapshot().map {
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
/// Metadata key convention for network entries (same as the Olaf iOS SDK):
/// `method`, `url`, `status`, `durationMs`, `reqBytes`, `respBytes`, `error`,
/// `requestBody`, `responseBody`; request headers use the `reqH.` prefix, response
/// headers the `respH.` prefix. Navigation entries: `screen`, `kind`.
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
