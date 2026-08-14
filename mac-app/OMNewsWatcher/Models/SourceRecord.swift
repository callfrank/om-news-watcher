import Foundation

struct SourceRecord: Identifiable, Equatable {
    let id: UUID
    var raw: [String: JSONValue]

    init(id: UUID = UUID(), raw: [String: JSONValue]) {
        self.id = id
        self.raw = raw
    }

    var name: String {
        get { raw["name"]?.stringValue ?? "Ohne Namen" }
        set { raw["name"] = .string(newValue) }
    }

    var url: String {
        get { raw["url"]?.stringValue ?? "" }
        set { raw["url"] = .string(newValue) }
    }

    var enabled: Bool {
        get { raw["enabled"]?.boolValue ?? true }
        set { raw["enabled"] = .bool(newValue) }
    }

    var waitMs: Int {
        get { raw["waitMs"]?.intValue ?? 2500 }
        set { raw["waitMs"] = .int(newValue) }
    }

    var baselineVersion: String? {
        get { raw["baselineVersion"]?.stringValue }
        set {
            if let newValue {
                raw["baselineVersion"] = .string(newValue)
            } else {
                raw.removeValue(forKey: "baselineVersion")
            }
        }
    }

    var fetchMode: String? {
        raw["fetchMode"]?.stringValue
    }

    var allowTitleOnly: Bool {
        raw["allowTitleOnly"]?.boolValue ?? false
    }

    var allowExternal: Bool {
        raw["allowExternal"]?.boolValue ?? false
    }

    var candidateSelector: String? {
        clean(raw["candidateSelector"]?.stringValue)
    }

    var includeRegex: String? {
        clean(raw["includeRegex"]?.stringValue)
    }

    var excludeRegex: String? {
        clean(raw["excludeRegex"]?.stringValue)
    }

    var includeTitleRegex: String? {
        clean(raw["includeTitleRegex"]?.stringValue)
    }

    var excludeTitleRegex: String? {
        clean(raw["excludeTitleRegex"]?.stringValue)
    }

    var minTitleLength: Int {
        raw["minTitleLength"]?.intValue ?? 10
    }

    var maxDetectedItems: Int? {
        raw["maxDetectedItems"]?.intValue
    }

    var itemSelector: String? {
        selectorValue("item")
    }

    var titleSelector: String? {
        selectorValue("title")
    }

    var linkSelector: String? {
        selectorValue("link")
    }

    static func new(url: String = "") -> SourceRecord {
        let guessedName = suggestedName(from: url)

        return SourceRecord(raw: [
            "name": .string(guessedName),
            "url": .string(url),
            "enabled": .bool(true),
            "waitMs": .int(2500),
            "selectors": .object([
                "item": .string(""),
                "title": .string(""),
                "link": .string(""),
                "date": .string("")
            ]),
            "baselineVersion": .string(makeBaselineVersion())
        ])
    }

    static func suggestedName(from urlString: String) -> String {
        guard
            let url = URL(string: urlString),
            let host = url.host?.replacingOccurrences(of: "www.", with: "")
        else {
            return "Neue Quelle"
        }

        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    static func makeBaselineVersion() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "mac-app-\(formatter.string(from: Date()))"
    }

    private func selectorValue(_ key: String) -> String? {
        guard case .object(let selectors) = raw["selectors"] else { return nil }
        return clean(selectors[key]?.stringValue)
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct WorkflowRun: Decodable, Identifiable {
    let id: Int64
    let status: String
    let conclusion: String?
    let htmlURL: String
    let runNumber: Int?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case conclusion
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case createdAt = "created_at"
    }

    var displayStatus: String {
        if status == "completed" {
            switch conclusion {
            case "success": return "Erfolgreich"
            case "failure": return "Fehlgeschlagen"
            case "cancelled": return "Abgebrochen"
            default: return conclusion ?? "Beendet"
            }
        }

        switch status {
        case "queued": return "Wartet"
        case "in_progress": return "Läuft"
        default: return status
        }
    }
}
