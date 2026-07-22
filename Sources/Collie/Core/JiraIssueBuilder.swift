import Foundation

/// Builds the Jira issue content (summary + wiki-markup description + fields) from
/// report data: 250-char summary, wiki escaping (markup-injection prevention),
/// failure-first top-15 requests in the network section, category counts, and a short
/// Telemetry section. `parent` and `assignee` are always set — every report is created
/// as a subtask under the configured parent.
enum JiraIssueBuilder {

    // MARK: - Input

    struct ReportContext: Sendable {
        let whatHappened: String
        let whatExpected: String
        let testerName: String?
        let identity: CollieDeviceIdentity
        let telemetry: CollieTelemetry?
        let sessionID: String
        let capturedAt: Date
        let entries: [CollieLogEntry]
    }

    /// Maximum characters a single failing body may occupy in the description.
    /// (Jira's description field is limited to ~32k; full bodies live in the attached JSON.)
    private static let maxBodyChars = 1_500
    /// Overall safety ceiling for the description.
    private static let maxDescriptionChars = 30_000
    /// Maximum number of requests listed in the network section.
    static let maxNetworkRows = 15

    // MARK: - Create body

    private struct KeyField: Encodable { let key: String }
    private struct NameField: Encodable { let name: String }

    private struct CreateFields: Encodable {
        let project: KeyField
        let issuetype: NameField
        let summary: String
        let description: String
        let assignee: NameField
        let parent: KeyField
        let labels: [String]?
    }

    private struct CreateBody: Encodable { let fields: CreateFields }

    /// Produces the `POST /rest/api/2/issue` body.
    static func makeCreateBody(
        configuration: CollieConfiguration,
        context: ReportContext
    ) throws -> Data {
        let fields = CreateFields(
            project: KeyField(key: configuration.projectKey),
            issuetype: NameField(name: configuration.subtaskIssueType),
            summary: makeSummary(appName: configuration.resolvedAppDisplayName,
                                 whatHappened: context.whatHappened),
            description: makeDescription(configuration: configuration, context: context),
            assignee: NameField(name: configuration.assigneeUsername),
            parent: KeyField(key: configuration.parentIssueKey),
            labels: configuration.defaultLabels.isEmpty ? nil : configuration.defaultLabels
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(CreateBody(fields: fields))
    }

    // MARK: - Summary

    static func makeSummary(appName: String, whatHappened: String) -> String {
        let summary = "[\(appName)] \(firstLine(whatHappened))"
        return String(summary.prefix(250))
    }

    static func firstLine(_ text: String?) -> String {
        guard let text else { return "Bug report" }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? "Bug report" : line
    }

    // MARK: - Description

    static func makeDescription(
        configuration: CollieConfiguration,
        context: ReportContext
    ) -> String {
        let identity = context.identity
        let network = context.entries.filter { $0.category == "network" }.map(NetworkView.init)
        let navigation = context.entries.filter { $0.category == "navigation" }.map(NavigationView.init)

        var sections: [String] = [
            "h3. Reporter",
            "* *Name:* \(wikiEscape(context.testerName ?? "Unknown tester"))",
            "* *Device:* \(wikiEscape(identity.model))",
            "",
            "h3. Environment",
            "* *iOS:* \(wikiEscape(identity.osVersion))",
            "* *App:* \(wikiEscape(CollieDeviceIdentity.appVersion)) (build \(wikiEscape(CollieDeviceIdentity.appBuild)))",
            "* *Environment:* \(wikiEscape(configuration.environment))",
            "* *Locale:* \(wikiEscape(identity.locale))",
            "* *Session:* \(wikiEscape(context.sessionID.isEmpty ? "-" : context.sessionID)) — \(wikiEscape(iso8601(context.capturedAt)))",
            "",
            "h3. What happened?",
            wikiEscape(context.whatHappened),
            "",
            "h3. What was expected?",
            wikiEscape(context.whatExpected),
            ""
        ]

        if let telemetry = context.telemetry {
            sections.append(contentsOf: ["h3. Telemetry", formatTelemetry(telemetry), ""])
        }

        sections.append(contentsOf: [
            "h3. Navigation",
            formatNavigation(navigation),
            "",
            "h3. Network",
            formatNetwork(network),
            "",
            "h3. Logs",
            summarizeCategories(context.entries)
        ])

        let description = sections.joined(separator: "\n")
        if description.count > maxDescriptionChars {
            return String(description.prefix(maxDescriptionChars)) + "\n_…description truncated; full data in the attached collie-logs JSON._"
        }
        return description
    }

    // MARK: - Derived views (device-side counterpart of the backend's report-parser)

    struct NetworkView {
        let timestamp: Date
        let method: String?
        let url: String?
        let status: Int?
        let durationMs: Int?
        let error: String?
        let requestBody: String?
        let responseBody: String?

        init(entry: CollieLogEntry) {
            let meta = entry.metadata
            timestamp = entry.date
            method = meta["method"]
            url = meta["url"]
            status = meta["status"].flatMap(Int.init)
            durationMs = meta["durationMs"].flatMap(Double.init).map(Int.init)
            error = meta["error"]
            requestBody = meta["requestBody"]
            responseBody = meta["responseBody"]
        }

        var isFailure: Bool {
            if error?.isEmpty == false { return true }
            if let status, status >= 400 { return true }
            return false
        }
    }

    struct NavigationView {
        let timestamp: Date
        let screen: String?
        let kind: String?

        init(entry: CollieLogEntry) {
            timestamp = entry.date
            screen = entry.metadata["screen"] ?? entry.metadata["screenId"] ?? (entry.message.isEmpty ? nil : entry.message)
            kind = entry.metadata["kind"]
        }
    }

    static func formatNavigation(_ nav: [NavigationView]) -> String {
        guard !nav.isEmpty else { return "_No navigation captured_" }
        return nav.map { n in
            let kind = n.kind.map { " (\(wikiEscape($0)))" } ?? ""
            return "* [\(timeString(n.timestamp))] \(wikiEscape(n.screen ?? "unknown"))\(kind)"
        }
        .joined(separator: "\n")
    }

    static func formatNetwork(_ network: [NetworkView]) -> String {
        guard !network.isEmpty else { return "_No network activity captured_" }

        // Failing/critical requests first; original order preserved on ties (stable sort).
        let sorted = network.enumerated().sorted { a, b in
            let aRank = a.element.isFailure ? 0 : 1
            let bRank = b.element.isFailure ? 0 : 1
            return aRank == bRank ? a.offset < b.offset : aRank < bRank
        }.map(\.element)
        let top = sorted.prefix(maxNetworkRows)

        let rows = top.map { n -> String in
            let status = n.status.map(String.init) ?? "-"
            let dur = n.durationMs.map { "\($0)ms" } ?? "-"
            let err = n.error.map { " *ERROR:* \(wikiEscape($0))" } ?? ""
            var block = "* *\(wikiEscape(n.method ?? "GET"))* \(wikiEscape(n.url ?? "")) → \(status) (\(dur))\(err)"
            if n.isFailure {
                if let body = n.requestBody, !body.isEmpty {
                    block += "\nRequest:\n\(codeBlock(truncate(body)))"
                }
                if let body = n.responseBody, !body.isEmpty {
                    block += "\nResponse:\n\(codeBlock(truncate(body)))"
                }
            }
            return block
        }
        .joined(separator: "\n")

        let more = network.count > top.count
            ? "\n_+\(network.count - top.count) more requests in attached collie-logs JSON_"
            : ""
        return rows + more
    }

    static func summarizeCategories(_ entries: [CollieLogEntry]) -> String {
        guard !entries.isEmpty else { return "_No logs_" }
        var counts: [String: Int] = [:]
        for entry in entries {
            let category = entry.category.isEmpty ? "general" : entry.category
            counts[category, default: 0] += 1
        }
        let lines = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "* \(wikiEscape($0.key)): \($0.value)" }
        return lines.joined(separator: "\n") + "\n_Full log set attached as collie-logs JSON_"
    }

    // MARK: - Wiki markup helpers

    private static let wikiSpecials: Set<Character> = [
        "{", "}", "[", "]", "|", "*", "_", "-", "#", "!", "?", "+", "^", "~"
    ]

    /// Escapes wiki-markup control characters (markup-injection prevention).
    static func wikiEscape(_ input: String?) -> String {
        guard let input, !input.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(input.count + 8)
        for ch in input.replacingOccurrences(of: "\r\n", with: "\n") {
            if wikiSpecials.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Wraps content in a `{code}` block (no escaping needed inside the macro; only the
    /// `{code}` literal is broken so the block cannot close early).
    static func codeBlock(_ content: String?) -> String {
        let safe = (content ?? "").replacingOccurrences(of: "{code}", with: "{ code }")
        return "{code}\n\(safe)\n{code}"
    }

    private static func truncate(_ body: String) -> String {
        guard body.count > maxBodyChars else { return body }
        return String(body.prefix(maxBodyChars)) + "… (truncated)"
    }

    // MARK: - Telemetry / time formatting

    private static func formatTelemetry(_ t: CollieTelemetry) -> String {
        var lines: [String] = []
        var row1: [String] = []
        if let network = t.networkType { row1.append("*Network:* \(wikiEscape(network))") }
        if let level = t.batteryLevel {
            let state = t.batteryState.map { " (\(wikiEscape($0)))" } ?? ""
            row1.append("*Battery:* \(level)%\(state)")
        }
        if let lowPower = t.lowPowerMode { row1.append("*Low power:* \(lowPower ? "yes" : "no")") }
        if !row1.isEmpty { lines.append("* " + row1.joined(separator: " · ")) }

        var row2: [String] = []
        if let thermal = t.thermalState { row2.append("*Thermal:* \(wikiEscape(thermal))") }
        if let orientation = t.orientation { row2.append("*Orientation:* \(wikiEscape(orientation))") }
        if !row2.isEmpty { lines.append("* " + row2.joined(separator: " · ")) }

        var row3: [String] = []
        if let free = t.freeDiskBytes { row3.append("*Free disk:* \(byteString(free))") }
        if let mem = t.appMemoryBytes { row3.append("*App memory:* \(byteString(mem))") }
        if !row3.isEmpty { lines.append("* " + row3.joined(separator: " · ")) }

        return lines.isEmpty ? "_No telemetry_" : lines.joined(separator: "\n")
    }

    private static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        // May contain wiki special characters (e.g. "-"); pass through the escaper.
        return wikiEscape(formatter.string(fromByteCount: bytes))
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
