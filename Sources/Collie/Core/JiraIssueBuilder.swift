import Foundation

/// Builds the Jira issue content (summary + wiki-markup description + fields) from
/// report data: "Collie iOS Report - <date&time>" summary, visual Server/DC wiki markup
/// (tables, colored panels, status colors, emoticons), wiki escaping (markup-injection
/// prevention), failure-first top-15 requests in the network section, and category
/// counts. `parent` and `assignee` are always set — every report is created as a
/// subtask under the configured parent.
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
        let collieInitializedAt: Date
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
            summary: makeSummary(capturedAt: context.capturedAt),
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

    /// Fixed task-name format: `Collie iOS Report - 23.07.2026 14:31`.
    static func makeSummary(capturedAt: Date) -> String {
        "Collie iOS Report - \(dateTimeString(capturedAt, seconds: false))"
    }

    // MARK: - Description

    static func makeDescription(
        configuration: CollieConfiguration,
        context: ReportContext
    ) -> String {
        let identity = context.identity
        let network = context.entries.filter { $0.category == "network" }.map(NetworkView.init)
        let navigation = context.entries.filter { $0.category == "navigation" }.map(NavigationView.init)

        let reportRows = [
            row("Reporter", context.testerName ?? "Unknown tester"),
            row("Device", "\(CollieDeviceModel.marketingName(for: identity.model)) — iOS \(identity.osVersion)"),
            row("App", "\(configuration.resolvedAppDisplayName) \(CollieDeviceIdentity.appVersion) (build \(CollieDeviceIdentity.appBuild)) — \(configuration.environment)"),
            row("Locale", identity.locale),
            row("Session", context.sessionID.isEmpty ? "-" : context.sessionID),
            row("Captured", dateTimeString(context.capturedAt)),
            row("Collie initialized", dateTimeString(context.collieInitializedAt))
        ].joined(separator: "\n")

        var sections: [String] = [
            "h3. (i) Report",
            reportRows,
            "",
            "h3. (!) What happened?",
            panel(wikiEscape(context.whatHappened), bgColor: "#FFEBE6", borderColor: "#FFBDAD"),
            "",
            "h3. (/) What was expected?",
            panel(wikiEscape(context.whatExpected), bgColor: "#E3FCEF", borderColor: "#ABF5D1"),
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
        var lines = ["||Time||Screen||Transition||"]
        lines.append(contentsOf: nav.map { n in
            "|\(timeString(n.timestamp))|\(cell(n.screen ?? "unknown"))|\(cell(n.kind ?? "-"))|"
        })
        return lines.joined(separator: "\n")
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

        var lines = ["|| ||Method||URL||Status||Duration||"]
        lines.append(contentsOf: top.map { n in
            let icon = n.isFailure ? "(x)" : "(/)"
            let dur = n.durationMs.map { "\($0)ms" } ?? "-"
            return "|\(icon)|*\(cell(n.method ?? "GET"))*|\(cell(n.url ?? "-"))|\(statusCell(n))|\(cell(dur))|"
        })

        // Failing request/response details live below the table ({code} blocks cannot
        // sit inside table cells).
        for n in top where n.isFailure {
            var details: [String] = []
            if let error = n.error, !error.isEmpty {
                details.append("{color:#DE350B}\(wikiEscape(error)){color}")
            }
            if let body = n.requestBody, !body.isEmpty {
                details.append("Request:\n\(codeBlock(truncate(body)))")
            }
            if let body = n.responseBody, !body.isEmpty {
                details.append("Response:\n\(codeBlock(truncate(body)))")
            }
            guard !details.isEmpty else { continue }
            lines.append("\n(x) *\(cell(n.method ?? "GET")) \(cell(n.url ?? "-"))*\n"
                         + details.joined(separator: "\n"))
        }

        let more = network.count > top.count
            ? "\n_+\(network.count - top.count) more requests in attached collie-logs JSON_"
            : ""
        return lines.joined(separator: "\n") + more
    }

    static func summarizeCategories(_ entries: [CollieLogEntry]) -> String {
        guard !entries.isEmpty else { return "_No logs_" }
        var counts: [String: Int] = [:]
        for entry in entries {
            let category = entry.category.isEmpty ? "general" : entry.category
            counts[category, default: 0] += 1
        }
        var lines = ["||Category||Count||"]
        lines.append(contentsOf: counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "|\(cell($0.key))|\($0.value)|" })
        return lines.joined(separator: "\n") + "\n_Full log set attached as collie-logs JSON_"
    }

    // MARK: - Wiki markup helpers

    /// A table cell: escaped, newline-free (a newline would break the row), `-` when
    /// empty.
    static func cell(_ value: String?) -> String {
        let escaped = wikiEscape(value).replacingOccurrences(of: "\n", with: " ")
        return escaped.isEmpty ? "\\-" : escaped
    }

    /// A `||Key|value|` table row with a header-style key column. `key` is Collie's own
    /// literal, never user content.
    private static func row(_ key: String, _ value: String) -> String {
        "||\(key)|\(cell(value))|"
    }

    /// A colored `{panel}` block. `body` must already be wiki-escaped, which also
    /// prevents user text from closing the panel early (`{` → `\{`).
    private static func panel(_ body: String, bgColor: String, borderColor: String) -> String {
        "{panel:bgColor=\(bgColor)|borderColor=\(borderColor)}\n\(body.isEmpty ? "-" : body)\n{panel}"
    }

    /// Status column: red bold for failures, green for successful responses.
    private static func statusCell(_ n: NetworkView) -> String {
        guard let status = n.status else {
            return n.isFailure ? "{color:#DE350B}*ERR*{color}" : "\\-"
        }
        return n.isFailure
            ? "{color:#DE350B}*\(status)*{color}"
            : "{color:#00875A}\(status){color}"
    }

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
        var rows: [String] = []
        if let network = t.networkType { rows.append(row("Network", network)) }
        if let level = t.batteryLevel {
            let state = t.batteryState.map { " (\($0))" } ?? ""
            rows.append(row("Battery", "\(level)%\(state)"))
        }
        if let lowPower = t.lowPowerMode {
            rows.append("||Low power mode|\(lowPower ? "(on) on" : "(off) off")|")
        }
        if let thermal = t.thermalState { rows.append(row("Thermal", thermal)) }
        if let orientation = t.orientation { rows.append(row("Orientation", orientation)) }
        if let free = t.freeDiskBytes { rows.append(row("Free disk", plainByteString(free))) }
        if let mem = t.appMemoryBytes { rows.append(row("App memory", plainByteString(mem))) }
        return rows.isEmpty ? "_No telemetry_" : rows.joined(separator: "\n")
    }

    /// Unescaped byte string — callers pass it through `cell`/`row` for escaping.
    private static func plainByteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Human-readable date & time, e.g. `23.07.2026 14:31:05` (`seconds: false` →
    /// `23.07.2026 14:31`). Device-local time zone.
    static func dateTimeString(_ date: Date, seconds: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = seconds ? "dd.MM.yyyy HH:mm:ss" : "dd.MM.yyyy HH:mm"
        return f.string(from: date)
    }
}
