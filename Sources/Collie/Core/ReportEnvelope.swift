import Foundation

/// Builds the JSON `report` part of the multipart upload sent to the Collie backend.
///
/// The wire format is the backend's ingestion contract:
/// ```jsonc
/// {
///   "app":       { "bundleId": …, "version": …, "build": …, "environment": … },
///   "device":    { "id": …, "name": …, "model": …, "osVersion": …, "locale": …, "screen": … },
///   "report":    { "whatHappened": …, "whatExpected": …, "capturedAt": …, "sessionId": … },
///   "entries":   [ /* raw CollieLogEntry[] — ALL categories, lossless */ ],
///   "telemetry": { /* point-in-time device state, no PII */ }
/// }
/// ```
///
/// Which app a report belongs to is resolved **server-side from the api-key**, so no app
/// key or slug is sent here.
///
/// `entries` go out exactly as the host provided them: every category is preserved and
/// nothing is summarized or truncated. The backend keeps the raw stream and derives its
/// network/navigation views from it — the same `metadata` key convention documented on
/// `CollieLogEntry` (`method`/`url`/`status`/…, `reqH.`/`respH.` header prefixes).
enum ReportEnvelopeBuilder {

    /// Everything needed to describe one report.
    struct ReportContext: Sendable {
        let whatHappened: String
        let whatExpected: String
        let testerName: String?
        let identity: CollieDeviceIdentity
        let telemetry: CollieTelemetry?
        let sessionID: String
        let capturedAt: Date
        let collieInitializedAt: Date
        let entries: [CollieLogEntry]
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
            let whatExpected: String
            let capturedAt: Date
            let sessionId: String?
        }
    }

    // MARK: - Building

    /// Encodes the `report` JSON part.
    ///
    /// Dates (entry `date`, `capturedAt`) are ISO-8601 — the format the backend parser
    /// reads. Slashes are left unescaped so URLs stay readable in the stored payload.
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
                whatExpected: context.whatExpected,
                capturedAt: context.capturedAt,
                sessionId: context.sessionID.isEmpty ? nil : context.sessionID
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
