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
/// **The log stream goes to its own document, like the screenshot.** For the same reason:
/// the panel's list screen shows a status, a sentence, a device and a date, and Firestore's
/// web SDK cannot fetch a subset of a document's fields — asking for the report meant
/// downloading every log line and response body it carried. Testers do not close the app,
/// so each report also carries the previous ones' stream and the documents keep growing:
/// the list got slower with every report filed. `entries` therefore lands in
/// `<entriesCollection>/<reportID>` and the report document stays small.
///
/// **What is written** (`<collection>/<reportID>`):
/// - `app`, `device`, `report`, `telemetry` — the envelope minus its stream, decoded from
///   JSON so the data is queryable in Firestore rather than an opaque blob.
/// - `hasScreenshot` — whether `<screenshotCollection>/<reportID>` holds the image.
/// - `status` — always `"new"`; the panel owns the lifecycle afterwards.
/// - `createdAt` — server timestamp.
///
/// **What is written** (`<entriesCollection>/<reportID>`): `appKey`, `entries`, `createdAt`.
/// `appKey` is repeated there so the security rules can scope the collection without
/// reading the parent document.
///
/// The `entries` array is written **losslessly** wherever it lands: every category the host
/// logged is kept, exactly as `ReportEnvelopeBuilder` produced it.
public final class FirestoreTransport: ReportTransport, @unchecked Sendable {

    /// Where reports and screenshots are written.
    public struct Configuration: Sendable {
        /// Firestore collection that receives the reports.
        public var collection: String
        /// Firestore collection that receives the base64 screenshots, one document per
        /// report. Kept separate so listing reports never pulls image data along.
        public var screenshotCollection: String
        /// Firestore collection that receives the raw log stream, one document per report.
        /// Separate for the same reason as the screenshot: the panel lists reports without
        /// it, and it is the part that grows without bound.
        public var entriesCollection: String
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
            entriesCollection: String = "collie_report_entries",
            configCollection: String = "collie_config",
            maxDocumentBytes: Int = 900_000,
            maxScreenshotBytes: Int = 650_000
        ) {
            self.appKey = appKey
            self.collection = collection
            self.screenshotCollection = screenshotCollection
            self.entriesCollection = entriesCollection
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

        // 2. The log stream, into its own document — the whole point of the split. Written
        //    BEFORE the report for the same reason the screenshot is: the report document
        //    is what the panel discovers, and it must never point at a stream that is not
        //    there yet.
        //
        //    A permanent failure falls back to the old shape rather than dropping the logs.
        //    Rules that predate this collection reject the write permanently, and a report
        //    whose stream was silently discarded is worse than a large document: the stream
        //    is what the analyst reads to reconstruct the bug. Size is not a concern in that
        //    path — the envelope was already checked against `maxDocumentBytes` above, with
        //    the entries inside it.
        if let entries = document.removeValue(forKey: "entries") {
            switch await putEntries(entries, reportID: reportID) {
            case .success:
                // The write below merges, so an `entries` field left by an EARLIER attempt
                // would survive it: a report queued by a build that wrote the stream inline
                // and retried after the app updated. Deleting the field keeps the report
                // document small in that case too, and the stream is already safely written.
                document["entries"] = FieldValue.delete()
            case .transientFailure(let reason):
                return .transientFailure(reason)
            case .permanentFailure:
                document["entries"] = entries
            }
        }

        document["appKey"] = configuration.appKey
        document["hasScreenshot"] = hasScreenshot
        document["status"] = "new"
        document["clientReportId"] = reportID
        document["createdAt"] = FieldValue.serverTimestamp()

        // 3. The report id IS the document id → a retry overwrites the same document
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

    // MARK: - Log stream

    /// Writes the raw log stream into its own document, keyed by the report id so a retry
    /// overwrites rather than duplicates — the same idempotency the report document gets.
    ///
    /// `appKey` travels with it because the security rules scope this collection on its own;
    /// a rule that had to `get()` the parent report would both cost a read per write and
    /// fail on the very first write, when the parent does not exist yet.
    private func putEntries(
        _ entries: Any,
        reportID: String
    ) async -> CollieOperationResult<Void> {
        do {
            try await firestore
                .collection(configuration.entriesCollection)
                .document(reportID)
                .setData([
                    "appKey": configuration.appKey,
                    "entries": entries,
                    "createdAt": FieldValue.serverTimestamp(),
                ], merge: true)
            return .success(())
        } catch {
            return Self.classify(error, action: "write the log entries")
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
