import Foundation

/// Result of a single backend call.
enum CollieOperationResult<T: Sendable>: Sendable {
    /// Success (2xx).
    case success(T)
    /// Permanent failure (auth/validation/too large). Must not be retried.
    case permanentFailure(String)
    /// Transient failure (network / no VPN / 5xx / 408 / 429). Should be queued and
    /// retried with backoff.
    case transientFailure(String)
}

/// Server-side switches fetched at startup. The kill switch lets the backend turn the
/// reporter off for an app without shipping a new build.
struct CollieRemoteConfig: Decodable, Sendable {
    let captureEnabled: Bool
    let maxScreenshotBytes: Int?
}

/// Ingestion transport used by the queue (mocked in tests).
protocol ReportTransport: Sendable {
    /// Uploads one report (JSON envelope + optional screenshot); returns the server's
    /// report id on success.
    ///
    /// - Parameter reportID: Client-generated idempotency key. Retrying with the same
    ///   value must not create a second report server-side.
    func upload(
        reportID: String,
        envelope: Data,
        screenshot: Data?
    ) async -> CollieOperationResult<String>

    /// Fetches the server-side kill switch. `nil` when it could not be reached — the
    /// caller decides how to treat that (Collie fails *open* here, see `BugReportService`).
    func fetchRemoteConfig() async -> CollieRemoteConfig?
}

/// Collie backend client: one multipart POST per report.
///
/// - **Its own `URLSession` with `protocolClasses = []`**: any network-capture protocol
///   the host uses is not injected → Collie's own traffic is not captured, no recursion.
///   (Additionally the host adds `captureExclusionFragments` to its capture exclude list —
///   double safeguard.)
/// - Auth: the `x-collie-api-key` header is the sole ingestion credential; it identifies
///   the app and authenticates the caller.
final class IngestionClient: ReportTransport, @unchecked Sendable {

    private let configuration: CollieConfiguration
    private let session: URLSession

    init(configuration: CollieConfiguration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.requestTimeout * 2
        sessionConfig.protocolClasses = []      // NO capture protocols
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Report upload

    /// The backend wraps successful responses in `{ success, data, message }`.
    private struct IngestResponse: Decodable {
        struct Payload: Decodable { let reportId: String }
        let data: Payload
    }

    /// `POST <reportsPath>` — multipart with a `report` JSON part and an optional
    /// `screenshot` binary part.
    func upload(
        reportID: String,
        envelope: Data,
        screenshot: Data?
    ) async -> CollieOperationResult<String> {
        let (body, boundary) = Self.makeMultipartBody(envelope: envelope, screenshot: screenshot)

        var request = URLRequest(url: configuration.reportsURL)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: CollieConfiguration.apiKeyHeader)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Duplicate prevention across retries: the server must treat a repeat of the same
        // key as the same report (a response lost in transit must not create a second one).
        request.setValue(reportID, forHTTPHeaderField: Self.idempotencyHeader)

        switch await perform(request: request, body: body) {
        case .success(let data):
            // A 2xx without a parseable id still means the server accepted the report —
            // retrying would duplicate it, so fall back to the client id instead of failing.
            guard let decoded = try? JSONDecoder().decode(IngestResponse.self, from: data) else {
                return .success(reportID)
            }
            return .success(decoded.data.reportId)
        case .permanentFailure(let reason):
            return .permanentFailure(reason)
        case .transientFailure(let reason):
            return .transientFailure(reason)
        }
    }

    // MARK: - Remote config

    /// `GET <configPath>` — the response is a bare object (no envelope), by contract with
    /// the SDK.
    func fetchRemoteConfig() async -> CollieRemoteConfig? {
        var request = URLRequest(url: configuration.configURL)
        request.httpMethod = "GET"
        request.setValue(configuration.apiKey, forHTTPHeaderField: CollieConfiguration.apiKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try? JSONDecoder().decode(CollieRemoteConfig.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Shared request/classification

    private func perform(request: URLRequest, body: Data) async -> CollieOperationResult<Data> {
        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure("Invalid response")
            }
            return Self.classify(statusCode: http.statusCode, responseBody: data)
        } catch {
            let description = (error as NSError).localizedDescription
            // Corporate backends are often reachable only over VPN — the most likely cause.
            return .transientFailure("\(description) — the Collie backend may be unreachable (check your VPN connection)")
        }
    }

    /// Classifies an HTTP status code as permanent/transient.
    /// 2xx success · 408/429 transient · other 4xx permanent (special messages for
    /// 401/403 and 413) · 5xx transient.
    static func classify(statusCode: Int, responseBody: Data) -> CollieOperationResult<Data> {
        switch statusCode {
        case 200..<300:
            return .success(responseBody)
        case 401, 403:
            return .permanentFailure("api-key is invalid or disabled (\(statusCode))")
        case 408, 429:
            return .transientFailure("HTTP \(statusCode)")
        case 413:
            return .permanentFailure("Report is too large (413)")
        case 400..<500:
            return .permanentFailure("HTTP \(statusCode)\(errorSnippet(from: responseBody))")
        default:
            return .transientFailure("HTTP \(statusCode)")
        }
    }

    /// Extracts a short, diagnosis-friendly snippet from an error body.
    private static func errorSnippet(from data: Data) -> String {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        return ": " + String(compact.prefix(300))
    }

    // MARK: - Multipart body construction

    /// Header carrying the client-generated idempotency key.
    static let idempotencyHeader = "x-collie-idempotency-key"

    /// Two-part multipart body. Part names are the backend contract: `report` (JSON) and
    /// `screenshot` (binary, optional).
    static func makeMultipartBody(
        envelope: Data,
        screenshot: Data?
    ) -> (body: Data, boundary: String) {
        let boundary = "CollieBoundary-\(UUID().uuidString)"
        var body = Data()

        func appendString(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        func appendPart(name: String, filename: String, mimeType: String, data: Data) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            appendString("Content-Type: \(mimeType)\r\n\r\n")
            body.append(data)
            appendString("\r\n")
        }

        appendPart(
            name: "report",
            filename: "report.json",
            mimeType: "application/json",
            data: envelope
        )
        if let screenshot, !screenshot.isEmpty {
            appendPart(
                name: "screenshot",
                filename: "screenshot.jpg",
                mimeType: "image/jpeg",
                data: screenshot
            )
        }
        appendString("--\(boundary)--\r\n")
        return (body, boundary)
    }
}
