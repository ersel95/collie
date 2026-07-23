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
    /// (Jira's description field is limited to ~32k; full bodies live in the attached JSON
    /// and in the per-request network attachments.)
    private static let maxBodyChars = 1_500
    /// Overall safety ceiling for the description.
    private static let maxDescriptionChars = 30_000
    /// Safety ceiling for the network table. Every captured request gets a row (so its
    /// attachment can be linked); this only stops a pathological session from blowing up
    /// the description.
    static let maxNetworkRows = 200
    /// Maximum number of failing requests whose bodies are inlined below the table. The
    /// rest are one click away via their own attachment.
    static let maxFailureDetails = 10

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
        let network = NetworkAttachmentBuilder.plan(
            entries: context.entries,
            limit: configuration.maxNetworkAttachments
        )
        let navigation = context.entries.filter { $0.category == "navigation" }.map(NavigationView.init)

        var rows = [row("Reporter", context.testerName ?? "Unknown tester")]
        if let customerNumber = latestCustomerNumber(context.entries) {
            rows.append(row("Customer no", customerNumber))
        }
        rows.append(contentsOf: [
            row("Device", CollieDeviceModel.marketingName(for: identity.model)),
            row("iOS version", identity.osVersion),
            row("App", configuration.resolvedAppDisplayName),
            row("Version", "\(CollieDeviceIdentity.appVersion) (build \(CollieDeviceIdentity.appBuild))"),
            row("Environment", configuration.environment),
            row("Language", languageString(identity.locale)),
            row("Session", context.sessionID.isEmpty ? "-" : context.sessionID),
            row("Captured", dateTimeString(context.capturedAt)),
            row("Session started", dateTimeString(context.collieInitializedAt))
        ])
        let reportRows = rows.joined(separator: "\n")

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

    // MARK: - Signed-in user

    /// Metadata key a host writes on its sign-in log entries so a report shows which
    /// account the tester was using. Category-agnostic: any entry carrying the key
    /// counts, so no logging library or screen name leaks into Collie.
    static let customerNumberKey = "customerNo"

    /// The most recent non-empty `customerNo` in the log snapshot — i.e. the account
    /// signed in at capture time. `nil` when the host never logs it (or nobody signed
    /// in), in which case the Report table simply omits the row.
    static func latestCustomerNumber(_ entries: [CollieLogEntry]) -> String? {
        var latest: (date: Date, value: String)?
        for entry in entries {
            guard let raw = entry.metadata[customerNumberKey] else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let current = latest, entry.date < current.date { continue }
            latest = (entry.date, value)
        }
        return latest?.value
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
        let message: String
        /// `reqH.`-prefixed metadata, un-prefixed.
        let requestHeaders: [String: String]
        /// `respH.`-prefixed metadata, un-prefixed.
        let responseHeaders: [String: String]
        /// Everything else the host attached, so the per-request file can dump the entry
        /// in full.
        let otherMetadata: [String: String]

        private static let knownKeys: Set<String> = [
            "method", "url", "status", "durationMs", "error", "requestBody", "responseBody"
        ]

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
            message = entry.message

            var request: [String: String] = [:]
            var response: [String: String] = [:]
            var other: [String: String] = [:]
            for (key, value) in meta {
                if key.hasPrefix("reqH.") {
                    request[String(key.dropFirst("reqH.".count))] = value
                } else if key.hasPrefix("respH.") {
                    response[String(key.dropFirst("respH.".count))] = value
                } else if !Self.knownKeys.contains(key) {
                    other[key] = value
                }
            }
            requestHeaders = request
            responseHeaders = response
            otherMetadata = other
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
            // A screen title if the host provides one; otherwise the raw screen id,
            // shortened at render time (associated values / payload dumps make the
            // column unreadable — the full value stays in the log JSON).
            screen = entry.metadata["navigationTitle"]
                ?? entry.metadata["title"]
                ?? entry.metadata["screen"]
                ?? entry.metadata["screenId"]
                ?? (entry.message.isEmpty ? nil : entry.message)
            kind = entry.metadata["kind"]
        }
    }

    /// Longest screen name kept in the Navigation table.
    private static let maxScreenChars = 60

    /// `accounts-transactions(screens: Yk…(iban: …))` → `accounts-transactions`.
    /// Strips the payload an enum/case dump drags along, then hard-caps the length so
    /// one row cannot stretch the whole table.
    static func shortScreen(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        let head = raw.prefix { $0 != "(" }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        guard base.count > maxScreenChars else { return base }
        return String(base.prefix(maxScreenChars)) + "…"
    }

    static func formatNavigation(_ nav: [NavigationView]) -> String {
        guard !nav.isEmpty else { return "_No navigation captured_" }
        var lines = ["||Time||Screen||Kind||"]
        lines.append(contentsOf: nav.map { n in
            "|\(timeString(n.timestamp))|\(cell(shortScreen(n.screen)))|\(cell(n.kind ?? "-"))|"
        })
        return lines.joined(separator: "\n")
    }

    /// Failing/critical requests first; original order preserved on ties (stable sort).
    /// Shared with `NetworkAttachmentBuilder` so a table row and its attachment carry the
    /// same number.
    static func failuresFirst(_ network: [NetworkView]) -> [NetworkView] {
        network.enumerated().sorted { a, b in
            let aRank = a.element.isFailure ? 0 : 1
            let bRank = b.element.isFailure ? 0 : 1
            return aRank == bRank ? a.offset < b.offset : aRank < bRank
        }.map(\.element)
    }

    /// The network table. Jira sizes table columns by their widest cell, so full URLs
    /// used to squeeze every other column into vertical letter-stacks: the shared host is
    /// therefore hoisted above the table and rows carry only the path, while the `File`
    /// column shows a short link label (`net-003`) pointing at the full attachment name.
    static func formatNetwork(_ plan: [NetworkAttachmentBuilder.PlannedRequest]) -> String {
        guard !plan.isEmpty else { return "_No network activity captured_" }
        let top = plan.prefix(maxNetworkRows)
        let origin = commonOrigin(top.map(\.view.url))

        var lines: [String] = []
        if let origin {
            lines.append("*Host:* \(wikiEscape(origin))\n_Each request is also attached as its own file — see the File column._")
        } else {
            lines.append("_Each request is also attached as its own file — see the File column._")
        }
        lines.append("|| ||Method||Path||Status||Duration||File||")
        lines.append(contentsOf: top.map { item in
            let n = item.view
            let icon = n.isFailure ? "(x)" : "(/)"
            let dur = n.durationMs.map { "\($0)ms" } ?? "-"
            return "|\(icon)|*\(cell(n.method ?? "GET"))*|\(cell(shortPath(n.url, origin: origin)))|\(statusCell(n))|\(cell(dur))|\(fileCell(item.filename))|"
        })

        // Failing request/response details live below the table ({code} blocks cannot
        // sit inside table cells).
        var remainingDetails = maxFailureDetails
        for item in top where item.view.isFailure && remainingDetails > 0 {
            let n = item.view
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
            remainingDetails -= 1
            let file = item.filename.map { " \($0.isEmpty ? "" : fileCell($0))" } ?? ""
            lines.append("\n(x) *\(cell(n.method ?? "GET")) \(cell(shortPath(n.url, origin: origin)))*\(file)\n"
                         + details.joined(separator: "\n"))
        }

        var notes: [String] = []
        if plan.count > top.count {
            notes.append("_+\(plan.count - top.count) more requests in the attached collie-logs JSON_")
        }
        let unattached = plan.filter { $0.filename == nil }.count
        if unattached > 0 {
            notes.append("_\(unattached) requests were not attached individually (attachment limit reached); they are in the attached collie-logs JSON._")
        }
        return lines.joined(separator: "\n") + (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
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

    /// File column: a Jira attachment link labelled with just the request number
    /// (`[net-003^net-003-GET-500-v1-users.txt]`) — the full name would widen the column
    /// far more than it informs. The filename is Collie-generated and slug-safe
    /// (`NetworkAttachmentBuilder.slug`), so it is deliberately NOT escaped — escaping
    /// would break the link.
    private static func fileCell(_ filename: String?) -> String {
        guard let filename, !filename.isEmpty else { return "\\-" }
        let label = filename.split(separator: "-").prefix(2).joined(separator: "-")
        return label.isEmpty ? "[^\(filename)]" : "[\(label)^\(filename)]"
    }

    /// Longest path kept in the Network table.
    private static let maxPathChars = 70

    /// The scheme+host every request shares, so the table can drop it. `nil` when the
    /// requests are spread over several hosts (then full URLs stay, since a stripped
    /// path would be ambiguous).
    static func commonOrigin(_ urls: [String?]) -> String? {
        var origins: Set<String> = []
        for url in urls {
            guard let url, let components = URLComponents(string: url),
                  let scheme = components.scheme, let host = components.host else { return nil }
            let port = components.port.map { ":\($0)" } ?? ""
            origins.insert("\(scheme)://\(host)\(port)")
            if origins.count > 1 { return nil }
        }
        return origins.first
    }

    /// `https://api.example.com/v1/users?page=2` → `/v1/users?page=2` once `origin` is
    /// shown above the table. Over-long paths are cut in the middle, keeping the
    /// distinguishing tail.
    static func shortPath(_ url: String?, origin: String?) -> String {
        guard let url, !url.isEmpty else { return "-" }
        var path = url
        if let origin, path.hasPrefix(origin) {
            path = String(path.dropFirst(origin.count))
            if path.isEmpty { path = "/" }
        }
        guard path.count > maxPathChars else { return path }
        let head = path.prefix(maxPathChars / 2)
        let tail = path.suffix(maxPathChars / 2 - 1)
        return "\(head)…\(tail)"
    }

    /// `tr_TR` → `Turkish (Turkey) (tr_TR)`. English names, so the issue reads the same
    /// for everyone regardless of the device's language; falls back to the raw
    /// identifier when it cannot be resolved.
    static func languageString(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "-" }
        let english = Locale(identifier: "en_US")
        guard let name = english.localizedString(forIdentifier: trimmed), !name.isEmpty else {
            return trimmed
        }
        return "\(name) (\(trimmed))"
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
