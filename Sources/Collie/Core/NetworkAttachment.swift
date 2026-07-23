import Foundation

/// A file uploaded to the issue next to the report (screenshot, log JSON, per-request
/// network dump).
struct CollieAttachment: Sendable, Equatable {
    let filename: String
    let mimeType: String
    let data: Data
}

/// Splits the report's network traffic into one plain-text file per request, so a single
/// request can be downloaded straight from Jira instead of being dug out of the one big
/// `collie-logs` JSON (which is still attached, in full).
///
/// The plan is **deterministic**: the same entries always produce the same order and the
/// same filenames. That is what lets the description — written before the attachments are
/// uploaded — link to them (`[^net-001-GET-500-v1-users.txt]`).
enum NetworkAttachmentBuilder {

    /// One request in the report: its description-table row, and the file that row links
    /// to (`nil` for requests past `limit`).
    struct PlannedRequest {
        let view: JiraIssueBuilder.NetworkView
        let filename: String?
    }

    static let mimeType = "text/plain"

    /// Longest path slug kept in a filename (Jira shows long names truncated in the UI).
    private static let maxSlugLength = 40

    // MARK: - Plan

    /// Failure-first ordering (identical to the description table) + a filename for the
    /// first `limit` requests.
    static func plan(entries: [CollieLogEntry], limit: Int) -> [PlannedRequest] {
        let views = entries
            .filter { $0.category == "network" }
            .map(JiraIssueBuilder.NetworkView.init)
        return JiraIssueBuilder.failuresFirst(views).enumerated().map { index, view in
            PlannedRequest(
                view: view,
                filename: index < limit ? filename(order: index + 1, view: view) : nil
            )
        }
    }

    /// Renders the planned requests that got a filename into upload-ready attachments.
    static func attachments(for plan: [PlannedRequest]) -> [CollieAttachment] {
        plan.compactMap { item in
            guard let filename = item.filename,
                  let data = makeText(for: item.view).data(using: .utf8) else { return nil }
            return CollieAttachment(filename: filename, mimeType: mimeType, data: data)
        }
    }

    // MARK: - Filename

    /// `net-003-GET-500-v1-users.txt` — the order matches the description table's row
    /// order, so a row and its file are found by the same number.
    static func filename(order: Int, view: JiraIssueBuilder.NetworkView) -> String {
        let index = String(format: "%03d", order)
        let method = slug(view.method ?? "").uppercased()
        let status = view.status.map(String.init) ?? (view.isFailure ? "ERR" : "NA")
        return "net-\(index)-\(method.isEmpty ? "GET" : method)-\(status)-\(pathSlug(view.url)).txt"
    }

    /// The URL's last two path segments as a slug (`https://x/v1/users/42` → `users-42`),
    /// falling back to the host when there is no path.
    private static func pathSlug(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "request" }
        let components = URLComponents(string: raw)
        let segments = (components?.path ?? raw)
            .split(separator: "/")
            .map(String.init)
        let tail = segments.suffix(2).joined(separator: "-")
        let slugged = slug(tail.isEmpty ? (components?.host ?? raw) : tail)
        return slugged.isEmpty ? "request" : String(slugged.prefix(maxSlugLength))
    }

    /// Keeps ASCII letters/digits and collapses everything else into single dashes. The
    /// result is filename-safe AND wiki-link-safe — the description embeds it in
    /// `[^...]` without escaping.
    private static func slug(_ input: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in input {
            if character.isASCII && (character.isLetter || character.isNumber) {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - File body

    /// Plain-text dump of a single request: summary line, headers, and the raw bodies
    /// (never truncated — being able to read the full body is the whole point of the
    /// per-request file).
    static func makeText(for view: JiraIssueBuilder.NetworkView) -> String {
        var lines: [String] = [
            "\(view.method ?? "GET") \(view.url ?? "-")",
            "Status:   \(view.status.map(String.init) ?? (view.isFailure ? "ERR" : "-"))",
            "Duration: \(view.durationMs.map { "\($0)ms" } ?? "-")",
            "Time:     \(JiraIssueBuilder.dateTimeString(view.timestamp))"
        ]
        if let error = view.error, !error.isEmpty {
            lines.append("Error:    \(error)")
        }
        if !view.message.isEmpty {
            lines.append("Message:  \(view.message)")
        }

        appendPairs(&lines, title: "Request headers", pairs: view.requestHeaders)
        appendBody(&lines, title: "Request body", body: view.requestBody)
        appendPairs(&lines, title: "Response headers", pairs: view.responseHeaders)
        appendBody(&lines, title: "Response body", body: view.responseBody)
        appendPairs(&lines, title: "Other metadata", pairs: view.otherMetadata)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendPairs(_ lines: inout [String], title: String, pairs: [String: String]) {
        guard !pairs.isEmpty else { return }
        lines.append("")
        lines.append("--- \(title) ---")
        lines.append(contentsOf: pairs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
    }

    private static func appendBody(_ lines: inout [String], title: String, body: String?) {
        guard let body, !body.isEmpty else { return }
        lines.append("")
        lines.append("--- \(title) ---")
        lines.append(body)
    }
}
