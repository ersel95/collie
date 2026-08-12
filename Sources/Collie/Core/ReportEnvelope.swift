import Foundation

/// Builds the JSON `report` part of the multipart upload sent to the Collie backend.
///
/// The wire format is the backend's ingestion contract:
/// ```jsonc
/// {
///   "app":       { "bundleId": …, "version": …, "build": …, "environment": … },
///   "device":    { "id": …, "name": …, "model": …, "osVersion": …, "locale": …, "screen": … },
///   "report":    { "whatHappened": …, "capturedAt": …, "sessionId": …, "platform": "ios",
///                  "previousReportAt": …, "sessionStartedAt": …, "processStartedAt": …,
///                  "sessionOrdinal": …, "sequence": … },
///   "entries":   [ /* raw CollieLogEntry[] — ALL categories, lossless */ ],
///   "telemetry": { /* point-in-time device state, no PII */ }
/// }
/// ```
///
/// Which app a report belongs to is resolved **server-side from the api-key**, so no app
/// key or slug is sent here.
///
/// The session fields are **optional presentation metadata** (see `CollieSessionTracker`):
/// the panel uses them to fold a report's repeated history into a collapsed block. A report
/// without them renders exactly as it did before they existed, which is what keeps older
/// SDK versions working — they must never become required.
///
/// `entries` go out exactly as the host provided them: every category is preserved and
/// nothing is summarized or truncated. The backend keeps the raw stream and derives its
/// network/navigation views from it — the same `metadata` key convention documented on
/// `CollieLogEntry` (`method`/`url`/`status`/…, `reqH.`/`respH.` header prefixes).
enum ReportEnvelopeBuilder {

    /// Everything needed to describe one report.
    struct ReportContext: Sendable {
        let whatHappened: String
        let testerName: String?
        let identity: CollieDeviceIdentity
        let telemetry: CollieTelemetry?
        let sessionID: String
        let capturedAt: Date
        let entries: [CollieLogEntry]
        /// Session context — everything the panel needs to fold the repeated history.
        /// `nil` only where a value genuinely does not exist yet (the first report has no
        /// `previousReportAt`).
        let session: CollieSessionTracker.ReportStamp?

        init(
            whatHappened: String,
            testerName: String?,
            identity: CollieDeviceIdentity,
            telemetry: CollieTelemetry?,
            sessionID: String,
            capturedAt: Date,
            entries: [CollieLogEntry],
            session: CollieSessionTracker.ReportStamp? = nil
        ) {
            self.whatHappened = whatHappened
            self.testerName = testerName
            self.identity = identity
            self.telemetry = telemetry
            self.sessionID = sessionID
            self.capturedAt = capturedAt
            self.entries = entries
            self.session = session
        }
    }

    // MARK: - Wire format

    private struct Envelope: Encodable {
        let app: App
        let device: Device
        let report: Body
        let entries: [CollieLogEntry]
        let telemetry: CollieTelemetry?

        struct App: Encodable {
            let bundleId: String
            let version: String
            let build: String
            let environment: String
        }

        struct Device: Encodable {
            let id: String
            let name: String?
            let model: String
            let osVersion: String
            let locale: String
            let screen: String
        }

        struct Body: Encodable {
            let whatHappened: String
            let capturedAt: Date
            let sessionId: String?
            /// Which SDK filed the report. Without it the panel has to guess the platform
            /// from the bundle id, which fails whenever the id does not spell it out.
            let platform: String
            let previousReportAt: Date?
            let sessionStartedAt: Date?
            let processStartedAt: Date?
            let sessionOrdinal: Int?
            let sequence: Int?

            /// This SDK is the iOS one wherever it is built; the macOS test build files
            /// the same document, so the value is a constant rather than a compile-time
            /// platform check.
            static let platform = "ios"
        }
    }

    // MARK: - Building

    /// Encodes the `report` JSON part.
    ///
    /// Dates (entry `date`, `capturedAt`, the session timestamps) are ISO-8601 **with an
    /// offset** — `.iso8601` renders UTC with a trailing `Z`. That offset is not cosmetic:
    /// the panel finds the fold boundary by comparing `previousReportAt` against the entry
    /// timestamps, and a stamp without one is read in the *browser's* timezone. Send one
    /// side with an offset and the other without and the boundary slides by hours, cutting
    /// the report in the wrong place. Slashes are left unescaped so URLs stay readable in
    /// the stored payload.
    static func makeBody(
        configuration: CollieConfiguration,
        context: ReportContext
    ) throws -> Data {
        let envelope = Envelope(
            app: Envelope.App(
                bundleId: CollieDeviceIdentity.bundleIdentifier,
                version: CollieDeviceIdentity.appVersion,
                build: CollieDeviceIdentity.appBuild,
                environment: configuration.environment
            ),
            device: Envelope.Device(
                id: context.identity.id,
                name: context.testerName ?? context.identity.name,
                model: context.identity.model,
                osVersion: context.identity.osVersion,
                locale: context.identity.locale,
                screen: context.identity.screen
            ),
            report: Envelope.Body(
                whatHappened: context.whatHappened,
                capturedAt: context.capturedAt,
                sessionId: context.sessionID.isEmpty ? nil : context.sessionID,
                platform: Envelope.Body.platform,
                previousReportAt: context.session?.previousReportAt,
                sessionStartedAt: context.session?.sessionStartedAt,
                processStartedAt: context.session?.processStartedAt,
                sessionOrdinal: context.session?.sessionOrdinal,
                sequence: context.session?.sequence
            ),
            entries: context.entries,
            telemetry: context.telemetry
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    // MARK: - Formatting helpers

    /// Human-readable timestamp used in Collie's own synthetic log entries.
    static func dateTimeString(_ date: Date, seconds: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = seconds ? "dd.MM.yyyy HH:mm:ss" : "dd.MM.yyyy HH:mm"
        return f.string(from: date)
    }
}
