import Foundation

/// Result of a single Jira call.
enum JiraOperationResult<T: Sendable>: Sendable {
    /// Success (2xx).
    case success(T)
    /// Permanent failure (auth/schema/field error). Must not be retried.
    case permanentFailure(String)
    /// Transient failure (network / no VPN / 5xx / 408 / 429). Should be queued and
    /// retried with backoff.
    case transientFailure(String)
}

/// Jira transport interface used by the queue (mocked in tests).
protocol JiraTransport: Sendable {
    /// Creates an issue; returns the issue key (e.g. `PROJ-123`) on success.
    func createIssue(body: Data) async -> JiraOperationResult<String>
    /// Attaches a file to an existing issue.
    func attach(issueKey: String, data: Data, filename: String, mimeType: String) async -> JiraOperationResult<Void>
}

/// Direct Jira REST v2 (Server/DC) client.
///
/// - **Its own `URLSession` with `protocolClasses = []`**: the host's network-capture
///   protocol (e.g. Olaf's) is not injected → Jira traffic is not captured, no recursion.
///   (Additionally the host adds the Jira base URL to its capture exclude list — double
///   safeguard.)
/// - Auth: `Authorization: Bearer <PAT>` (Jira Server/DC Personal Access Token).
final class JiraClient: JiraTransport, @unchecked Sendable {

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

    // MARK: - Issue creation

    private struct CreatedIssue: Decodable {
        let key: String
    }

    /// `POST /rest/api/2/issue` — the body is the output of `JiraIssueBuilder.makeCreateBody`.
    func createIssue(body: Data) async -> JiraOperationResult<String> {
        var request = URLRequest(url: configuration.issueCreateURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let outcome = await perform(request: request, body: body)
        switch outcome {
        case .success(let data):
            guard let issue = try? JSONDecoder().decode(CreatedIssue.self, from: data) else {
                // 2xx but the expected body is missing — retrying the create would risk
                // a duplicate issue.
                return .permanentFailure("Could not decode Jira response (no issue key)")
            }
            return .success(issue.key)
        case .permanentFailure(let reason):
            return .permanentFailure(reason)
        case .transientFailure(let reason):
            return .transientFailure(reason)
        }
    }

    // MARK: - Attachment

    /// `POST /rest/api/2/issue/{key}/attachments` — multipart `file` part.
    /// The `X-Atlassian-Token: no-check` header is required to bypass Jira's XSRF
    /// protection for attachment uploads.
    func attach(
        issueKey: String,
        data: Data,
        filename: String,
        mimeType: String
    ) async -> JiraOperationResult<Void> {
        let (body, boundary) = Self.makeMultipartBody(filename: filename, mimeType: mimeType, fileData: data)
        var request = URLRequest(url: configuration.attachmentsURL(issueKey: issueKey))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.pat)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")

        let outcome = await perform(request: request, body: body)
        switch outcome {
        case .success:
            return .success(())
        case .permanentFailure(let reason):
            return .permanentFailure(reason)
        case .transientFailure(let reason):
            return .transientFailure(reason)
        }
    }

    // MARK: - Shared request/classification

    private func perform(request: URLRequest, body: Data) async -> JiraOperationResult<Data> {
        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure("Invalid response")
            }
            return Self.classify(statusCode: http.statusCode, responseBody: data)
        } catch {
            let description = (error as NSError).localizedDescription
            // Corporate Jira is usually reachable only over VPN — the most likely cause.
            return .transientFailure("\(description) — Jira may be unreachable (check your VPN connection)")
        }
    }

    /// Classifies an HTTP status code as permanent/transient.
    /// 2xx success · 408/429 transient · other 4xx permanent (special message for 401) ·
    /// 5xx transient.
    static func classify(statusCode: Int, responseBody: Data) -> JiraOperationResult<Data> {
        switch statusCode {
        case 200..<300:
            return .success(responseBody)
        case 401:
            return .permanentFailure("PAT is invalid or expired (401)")
        case 408, 429:
            return .transientFailure("HTTP \(statusCode)")
        case 400..<500:
            return .permanentFailure("HTTP \(statusCode)\(errorSnippet(from: responseBody))")
        default:
            return .transientFailure("HTTP \(statusCode)")
        }
    }

    /// Extracts a short, diagnosis-friendly snippet from a Jira error body.
    private static func errorSnippet(from data: Data) -> String {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        return ": " + String(compact.prefix(300))
    }

    // MARK: - Multipart body construction

    /// Single-file multipart body for Jira's attachment endpoint. The part name must be
    /// `file` (Jira contract).
    static func makeMultipartBody(
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> (body: Data, boundary: String) {
        let boundary = "CollieBoundary-\(UUID().uuidString)"
        var body = Data()

        func appendString(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")
        appendString("--\(boundary)--\r\n")
        return (body, boundary)
    }
}
