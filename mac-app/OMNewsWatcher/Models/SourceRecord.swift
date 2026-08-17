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

    var shortName: String? {
        get { clean(raw["shortName"]?.stringValue) }
        set {
            if let newValue {
                let trimmed = newValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                if trimmed.isEmpty {
                    raw.removeValue(forKey: "shortName")
                } else {
                    raw["shortName"] = .string(trimmed)
                }
            } else {
                raw.removeValue(forKey: "shortName")
            }
        }
    }

    var feedLabel: String {
        shortName ?? SourceRecord.compactSourceName(name)
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
        get { clean(raw["fetchMode"]?.stringValue) }
        set {
            if let newValue, !newValue.isEmpty {
                raw["fetchMode"] = .string(newValue)
            } else {
                raw.removeValue(forKey: "fetchMode")
            }
        }
    }

    var allowTitleOnly: Bool {
        get { raw["allowTitleOnly"]?.boolValue ?? false }
        set { raw["allowTitleOnly"] = .bool(newValue) }
    }

    var allowExternal: Bool {
        get { raw["allowExternal"]?.boolValue ?? false }
        set { raw["allowExternal"] = .bool(newValue) }
    }

    var candidateSelector: String? {
        get { clean(raw["candidateSelector"]?.stringValue) }
        set {
            if let newValue, !newValue.isEmpty {
                raw["candidateSelector"] = .string(newValue)
            } else {
                raw.removeValue(forKey: "candidateSelector")
            }
        }
    }

    var includeRegex: String? {
        get { clean(raw["includeRegex"]?.stringValue) }
        set {
            if let newValue, !newValue.isEmpty {
                raw["includeRegex"] = .string(newValue)
            } else {
                raw.removeValue(forKey: "includeRegex")
            }
        }
    }

    var excludeRegex: String? {
        get { clean(raw["excludeRegex"]?.stringValue) }
        set {
            if let newValue, !newValue.isEmpty {
                raw["excludeRegex"] = .string(newValue)
            } else {
                raw.removeValue(forKey: "excludeRegex")
            }
        }
    }

    var includeTitleRegex: String? {
        clean(raw["includeTitleRegex"]?.stringValue)
    }

    var excludeTitleRegex: String? {
        clean(raw["excludeTitleRegex"]?.stringValue)
    }

    var minTitleLength: Int {
        get { raw["minTitleLength"]?.intValue ?? 10 }
        set { raw["minTitleLength"] = .int(newValue) }
    }

    var maxDetectedItems: Int? {
        raw["maxDetectedItems"]?.intValue
    }

    var itemSelector: String? {
        get { selectorValue("item") }
        set { setSelectorValue("item", newValue) }
    }

    var titleSelector: String? {
        get { selectorValue("title") }
        set { setSelectorValue("title", newValue) }
    }

    var linkSelector: String? {
        get { selectorValue("link") }
        set { setSelectorValue("link", newValue) }
    }

    var dateSelector: String? {
        get { selectorValue("date") }
        set { setSelectorValue("date", newValue) }
    }

    var visualLearned: Bool {
        raw["visualLearned"]?.boolValue ?? false
    }

    var visualSampleCount: Int {
        raw["visualSampleCount"]?.intValue ?? 0
    }

    var visualLearnedAt: String? {
        clean(raw["visualLearnedAt"]?.stringValue)
    }

    var visualRuleVersion: Int {
        raw["visualRuleVersion"]?.intValue ?? (visualLearned ? 1 : 0)
    }

    var visualValidated: Bool {
        raw["visualValidated"]?.boolValue ?? false
    }

    var visualValidationMessage: String? {
        clean(raw["visualValidationMessage"]?.stringValue)
    }

    var visualSmartExtraction: Bool {
        raw["visualSmartExtraction"]?.boolValue ?? (visualRuleVersion >= 2)
    }

    mutating func applyVisualTrainingRule(_ rule: VisualTrainingRule) {
        if !visualLearned {
            let keys = [
                "candidateSelector",
                "includeRegex",
                "excludeRegex",
                "includeTitleRegex",
                "excludeTitleRegex",
                "fetchMode",
                "allowTitleOnly",
                "allowExternal",
                "minTitleLength",
                "selectors"
            ]

            var backup: [String: JSONValue] = [:]
            for key in keys {
                if let value = raw[key] { backup[key] = value }
            }
            raw["visualBackup"] = .object(backup)
        }

        itemSelector = rule.itemSelector.isEmpty ? nil : rule.itemSelector
        titleSelector = rule.titleSelector.isEmpty ? nil : rule.titleSelector
        linkSelector = rule.linkSelector.isEmpty ? nil : rule.linkSelector
        dateSelector = rule.dateSelector

        candidateSelector = rule.candidateSelector
        includeRegex = rule.urlRegex
        excludeRegex = nil
        raw.removeValue(forKey: "includeTitleRegex")
        raw.removeValue(forKey: "excludeTitleRegex")
        fetchMode = nil
        allowTitleOnly = false
        allowExternal = rule.allowExternal
        minTitleLength = 5

        raw["visualLearned"] = .bool(true)
        raw["visualSampleCount"] = .int(rule.sampleCount)
        raw["visualLearnedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        raw["visualRuleVersion"] = .int(2)
        raw["visualValidated"] = .bool(false)
        raw["visualSmartExtraction"] = .bool(true)
        raw["visualStrategy"] = .string(rule.strategy)
        raw.removeValue(forKey: "visualValidationMessage")
        baselineVersion = SourceRecord.makeBaselineVersion()
    }

    mutating func markVisualTrainingValidated(_ message: String) {
        guard visualLearned else { return }
        raw["visualValidated"] = .bool(true)
        raw["visualValidatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        raw["visualValidationMessage"] = .string(message)
    }

    mutating func markVisualTrainingUnvalidated(_ message: String) {
        guard visualLearned else { return }
        raw["visualValidated"] = .bool(false)
        raw["visualValidationMessage"] = .string(message)
    }

    mutating func restoreBeforeVisualTraining() {
        let keys = [
            "candidateSelector",
            "includeRegex",
            "excludeRegex",
            "includeTitleRegex",
            "excludeTitleRegex",
            "fetchMode",
            "allowTitleOnly",
            "allowExternal",
            "minTitleLength",
            "selectors"
        ]

        for key in keys {
            raw.removeValue(forKey: key)
        }

        if case .object(let backup) = raw["visualBackup"] {
            for (key, value) in backup {
                raw[key] = value
            }
        } else {
            raw["selectors"] = .object([
                "item": .string(""),
                "title": .string(""),
                "link": .string(""),
                "date": .string("")
            ])
        }

        raw.removeValue(forKey: "visualBackup")
        raw.removeValue(forKey: "visualLearned")
        raw.removeValue(forKey: "visualSampleCount")
        raw.removeValue(forKey: "visualLearnedAt")
        raw.removeValue(forKey: "visualRuleVersion")
        raw.removeValue(forKey: "visualValidated")
        raw.removeValue(forKey: "visualValidatedAt")
        raw.removeValue(forKey: "visualValidationMessage")
        raw.removeValue(forKey: "visualSmartExtraction")
        raw.removeValue(forKey: "visualStrategy")
        baselineVersion = SourceRecord.makeBaselineVersion()
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

    static func compactSourceName(_ value: String) -> String {
        var result = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let suffixPatterns = [
            #"(?i)\s+News\s*&\s*Presse$"#,
            #"(?i)\s+News\s*&\s*Events$"#,
            #"(?i)\s+News\s*&\s*Resources$"#,
            #"(?i)\s+Press\s+Newsroom$"#,
            #"(?i)\s+Press\s+Releases$"#,
            #"(?i)\s+News\s+Releases$"#,
            #"(?i)\s+Aktuelle\s+Mitteilungen$"#,
            #"(?i)\s+Corporate\s+News$"#,
            #"(?i)\s+Medieninformationen$"#,
            #"(?i)\s+Medienmitteilungen$"#,
            #"(?i)\s+Pressemitteilungen$"#,
            #"(?i)\s+Newsroom\s+DE$"#,
            #"(?i)\s+Newsroom$"#,
            #"(?i)\s+Presse$"#,
            #"(?i)\s+Papers$"#,
            #"(?i)\s+Reports$"#,
            #"(?i)\s+Blog$"#,
            #"(?i)\s+Events$"#
        ]

        for pattern in suffixPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        return result.isEmpty ? value : result
    }

    var detectionConfiguration: [String: JSONValue] {
        var copy = raw

        // Änderungen an Darstellung/Status sollen keinen neuen
        // Baseline-Lauf auslösen.
        copy.removeValue(forKey: "name")
        copy.removeValue(forKey: "shortName")
        copy.removeValue(forKey: "enabled")
        copy.removeValue(forKey: "baselineVersion")

        return copy
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

    private mutating func setSelectorValue(_ key: String, _ value: String?) {
        var selectors: [String: JSONValue] = [:]

        if case .object(let current) = raw["selectors"] {
            selectors = current
        }

        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        selectors[key] = .string(trimmed)
        raw["selectors"] = .object(selectors)
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
