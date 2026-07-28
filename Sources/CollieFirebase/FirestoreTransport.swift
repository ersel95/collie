import Foundation
import Collie
import FirebaseFirestore
import FirebaseStorage

/// Sends reports to **Firebase** instead of an HTTPS endpoint of your own.
///
/// This exists for hosts whose network policy allows Firebase but not arbitrary
/// destinations — a banking app that may reach `*.googleapis.com` and its own API, and
/// nothing else. The report lands in Firestore, the screenshot in Cloud Storage, and a
/// server-side worker (or the analyst panel) picks it up from there.
///
/// **Idempotency.** The queue's report id becomes the Firestore *document id*, so a
/// retry after a lost response writes to the same document instead of creating a second
/// report — the same guarantee the HTTPS transport gets from its idempotency header.
///
/// **What is written** (`<collection>/<reportID>`):
/// - `app`, `device`, `report`, `entries`, `telemetry` — the envelope, decoded from JSON
///   so the data is queryable in Firestore rather than an opaque blob.
/// - `screenshotPath` — Storage path of the JPEG, or `nil`.
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
        /// Cloud Storage folder screenshots are written under.
        public var storagePrefix: String
        /// Which app the report belongs to — the panel groups by this.
        public var appKey: String
        /// Firestore document holding the remote kill switch
        /// (`<configCollection>/<appKey>` with a boolean `captureEnabled`).
        public var configCollection: String
        /// Upper bound on a single Firestore document (Firestore's own hard limit is
        /// 1 MiB). Envelopes above this are rejected as a permanent failure rather than
        /// retried forever.
        public var maxDocumentBytes: Int

        public init(
            appKey: String,
            collection: String = "collie_reports",
            storagePrefix: String = "collie",
            configCollection: String = "collie_config",
            maxDocumentBytes: Int = 900_000
        ) {
            self.appKey = appKey
            self.collection = collection
            self.storagePrefix = storagePrefix
            self.configCollection = configCollection
            self.maxDocumentBytes = maxDocumentBytes
        }
    }

    private let configuration: Configuration
    private let firestore: Firestore
    private let storage: Storage

    /// - Parameters:
    ///   - configuration: Collection/bucket layout and the app key.
    ///   - firestore: Defaults to the app's default Firestore instance. The host must
    ///     have called `FirebaseApp.configure()` before this runs.
    ///   - storage: Defaults to the app's default Cloud Storage bucket.
    public init(
        configuration: Configuration,
        firestore: Firestore = Firestore.firestore(),
        storage: Storage = Storage.storage()
    ) {
        self.configuration = configuration
        self.firestore = firestore
        self.storage = storage
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

        // 1. Screenshot first: if it fails transiently the report is retried whole, and
        //    the document never points at an object that does not exist.
        var screenshotPath: String?
        if let screenshot, !screenshot.isEmpty {
            let path = "\(configuration.storagePrefix)/\(configuration.appKey)/\(reportID).jpg"
            switch await putScreenshot(screenshot, at: path) {
            case .success:
                screenshotPath = path
            case .permanentFailure(let reason):
                // Losing the image must not lose the report.
                document["screenshotError"] = reason
            case .transientFailure(let reason):
                return .transientFailure(reason)
            }
        }

        document["appKey"] = configuration.appKey
        document["screenshotPath"] = screenshotPath
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

    // MARK: - Storage

    private func putScreenshot(_ data: Data, at path: String) async -> CollieOperationResult<Void> {
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        do {
            _ = try await storage.reference(withPath: path).putDataAsync(data, metadata: metadata)
            return .success(())
        } catch {
            return Self.classify(error, action: "upload the screenshot")
        }
    }

    // MARK: - Error classification

    /// Maps Firebase errors onto the queue's retry policy. Permission/quota/argument
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

        if nsError.domain == StorageErrorDomain {
            switch StorageErrorCode(rawValue: nsError.code) {
            case .unauthenticated, .unauthorized, .quotaExceeded,
                 .bucketNotFound, .objectNotFound, .projectNotFound:
                return .permanentFailure(message)
            default:
                return .transientFailure(message)
            }
        }

        return .transientFailure(message)
    }
}
