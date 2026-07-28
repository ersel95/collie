import Foundation
import Collie
import FirebaseFirestore

/// Sends reports to **Firebase** instead of an HTTPS endpoint of your own.
///
/// This exists for hosts whose network policy allows Firebase but not arbitrary
/// destinations — a banking app that may reach `*.googleapis.com` and its own API, and
/// nothing else. The report lands in Firestore and a server-side worker (or the analyst
/// panel) picks it up from there.
///
/// **Screenshots go to Firestore, not Cloud Storage.** Storage requires a paid Firebase
/// plan; on the free tier it is simply unavailable, which would strand every report at
/// the upload step. So the JPEG is base64-encoded into its *own* document — keeping it
/// out of the report document means listing reports in the panel never drags megabytes
/// of image data along. Firestore caps a document at 1 MiB, so `maxScreenshotBytes`
/// bounds the raw JPEG well below that (base64 inflates by ~33%).
///
/// **Idempotency.** The queue's report id becomes the Firestore *document id*, so a
/// retry after a lost response writes to the same document instead of creating a second
/// report — the same guarantee the HTTPS transport gets from its idempotency header.
///
/// **What is written** (`<collection>/<reportID>`):
/// - `app`, `device`, `report`, `entries`, `telemetry` — the envelope, decoded from JSON
///   so the data is queryable in Firestore rather than an opaque blob.
/// - `hasScreenshot` — whether `<screenshotCollection>/<reportID>` holds the image.
/// - `status` — always `"new"`; the panel owns the lifecycle afterwards.
/// - `createdAt` — server timestamp.
///
/// The `entries` array is written **losslessly**: every category the host logged is kept,
/// exactly as `ReportEnvelopeBuilder` produced it.
public final class FirestoreTransport: ReportTransport, @unchecked Sendable {

    /// Where reports and screenshots are written.
    public struct Configuration: Sendable {
        /// Firestore collection that receives the reports.
        public var collection: String
        /// Firestore collection that receives the base64 screenshots, one document per
        /// report. Kept separate so listing reports never pulls image data along.
        public var screenshotCollection: String
        /// Which app the report belongs to — the panel groups by this.
        public var appKey: String
        /// Firestore document holding the remote kill switch
        /// (`<configCollection>/<appKey>` with a boolean `captureEnabled`).
        public var configCollection: String
        /// Upper bound on a single Firestore document (Firestore's own hard limit is
        /// 1 MiB). Envelopes above this are rejected as a permanent failure rather than
        /// retried forever.
        public var maxDocumentBytes: Int
        /// Upper bound on the RAW screenshot. base64 inflates by ~33%, so this must stay
        /// comfortably under `maxDocumentBytes`. A larger image is dropped and the report
        /// still goes — the text and logs matter more than the picture.
        public var maxScreenshotBytes: Int

        public init(
            appKey: String,
            collection: String = "collie_reports",
            screenshotCollection: String = "collie_report_screenshots",
            configCollection: String = "collie_config",
            maxDocumentBytes: Int = 900_000,
            maxScreenshotBytes: Int = 650_000
        ) {
            self.appKey = appKey
            self.collection = collection
            self.screenshotCollection = screenshotCollection
            self.configCollection = configCollection
            self.maxDocumentBytes = maxDocumentBytes
            self.maxScreenshotBytes = maxScreenshotBytes
        }
    }

    private let configuration: Configuration
    private let firestore: Firestore

    /// - Parameters:
    ///   - configuration: Collection layout and the app key.
    ///   - firestore: Defaults to the app's default Firestore instance. The host must
    ///     have called `FirebaseApp.configure()` before this runs.
    public init(
        configuration: Configuration,
        firestore: Firestore = Firestore.firestore()
    ) {
        self.configuration = configuration
        self.firestore = firestore
    }

    // MARK: - ReportTransport

    public func upload(
        reportID: String,
        envelope: Data,
        screenshot: Data?
    ) async -> CollieOperationResult<String> {
        // A malformed envelope can never succeed — fail permanently so the queue drops
        // it instead of retrying for 48 hours.
        guard envelope.count <= configuration.maxDocumentBytes else {
            return .permanentFailure(
                "Report is too large for Firestore (\(envelope.count) bytes > \(configuration.maxDocumentBytes))"
            )
        }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: envelope),
            var document = parsed as? [String: Any]
        else {
            return .permanentFailure("Could not decode the report envelope")
        }

        // 1. Screenshot first: if it fails transiently the whole report is retried, so the
        //    report document never claims an image that was never written.
        var hasScreenshot = false
        if let screenshot, !screenshot.isEmpty {
            if screenshot.count > configuration.maxScreenshotBytes {
                document["screenshotError"] =
                    "Screenshot dropped: \(screenshot.count) bytes exceeds the \(configuration.maxScreenshotBytes)-byte Firestore limit"
            } else {
                switch await putScreenshot(screenshot, reportID: reportID) {
                case .success:
                    hasScreenshot = true
                case .permanentFailure(let reason):
                    // Losing the image must not lose the report.
                    document["screenshotError"] = reason
                case .transientFailure(let reason):
                    return .transientFailure(reason)
                }
            }
        }

        document["appKey"] = configuration.appKey
        document["hasScreenshot"] = hasScreenshot
        document["status"] = "new"
        document["clientReportId"] = reportID
        document["createdAt"] = FieldValue.serverTimestamp()

        // 2. The report id IS the document id → a retry overwrites the same document
        //    rather than adding another one.
        do {
            try await firestore
                .collection(configuration.collection)
                .document(reportID)
                .setData(document, merge: true)
            return .success(reportID)
        } catch {
            return Self.classify(error, action: "write the report")
        }
    }

    public func fetchRemoteConfig() async -> CollieRemoteConfig? {
        do {
            let snapshot = try await firestore
                .collection(configuration.configCollection)
                .document(configuration.appKey)
                .getDocument()
            guard let data = snapshot.data() else {
                // No config document yet → treat capture as on (fail-open), matching the
                // HTTPS transport's behaviour when the endpoint is unreachable.
                return CollieRemoteConfig(captureEnabled: true)
            }
            return CollieRemoteConfig(
                captureEnabled: data["captureEnabled"] as? Bool ?? true,
                maxScreenshotBytes: data["maxScreenshotBytes"] as? Int
            )
        } catch {
            // Unreachable → nil, so BugReportService keeps the previous state.
            return nil
        }
    }

    // MARK: - Screenshot

    /// Writes the JPEG as base64 into its own document, keyed by the report id so a
    /// retry overwrites rather than duplicates.
    private func putScreenshot(
        _ data: Data,
        reportID: String
    ) async -> CollieOperationResult<Void> {
        do {
            try await firestore
                .collection(configuration.screenshotCollection)
                .document(reportID)
                .setData([
                    "appKey": configuration.appKey,
                    "contentType": "image/jpeg",
                    "byteSize": data.count,
                    "data": data.base64EncodedString(),
                    "createdAt": FieldValue.serverTimestamp(),
                ], merge: true)
            return .success(())
        } catch {
            return Self.classify(error, action: "write the screenshot")
        }
    }

    // MARK: - Error classification

    /// Maps Firestore errors onto the queue's retry policy. Permission/argument
    /// problems repeat forever, so they are permanent; everything else is worth another
    /// attempt once connectivity returns.
    static func classify<T>(_ error: Error, action: String) -> CollieOperationResult<T> {
        let nsError = error as NSError
        let message = "Could not \(action): \(nsError.localizedDescription)"

        if nsError.domain == FirestoreErrorDomain {
            switch FirestoreErrorCode.Code(rawValue: nsError.code) {
            case .permissionDenied, .unauthenticated, .invalidArgument, .failedPrecondition:
                return .permanentFailure(message)
            default:
                return .transientFailure(message)
            }
        }

        return .transientFailure(message)
    }
}
