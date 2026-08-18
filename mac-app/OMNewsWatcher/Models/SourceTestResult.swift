import Foundation

enum SourceTestKind: String, Codable {
    case success
    case largeArchive
    case zeroHits
    case tooManyHits
    case timeout
    case technicalError

    var title: String {
        switch self {
        case .success: return "Quelle funktioniert"
        case .largeArchive: return "Großes Archiv – plausibel"
        case .zeroHits: return "Keine Treffer"
        case .tooManyHits: return "Zu viele Treffer"
        case .timeout: return "Zeitüberschreitung"
        case .technicalError: return "Technischer Fehler"
        }
    }

    var isSuccessLike: Bool {
        self == .success || self == .largeArchive
    }
}

struct SourceTestHit: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String?
    let publicationDate: String?

    init(title: String, url: String?, publicationDate: String? = nil) {
        self.title = title
        self.url = url
        self.publicationDate = publicationDate
    }
}

struct VisualTrainingSample: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String
}

struct VisualTrainingPreview: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String
    let date: String?
}

struct VisualTrainingRule: Equatable {
    let itemSelector: String
    let titleSelector: String
    let linkSelector: String
    let dateSelector: String?
    let candidateSelector: String
    let urlRegex: String?
    let allowExternal: Bool
    let sampleCount: Int
    let previewCount: Int
    let preview: [VisualTrainingPreview]
    let strategy: String
    let sampleURLs: [String]

    var isUsable: Bool {
        sampleCount >= 2 &&
        previewCount >= sampleCount &&
        previewCount <= 300 &&
        (!itemSelector.isEmpty || !(urlRegex ?? "").isEmpty) &&
        !candidateSelector.isEmpty
    }
}

struct SourceRepairProposal: Equatable {
    let title: String
    let explanation: String
    let previewCount: Int
    let examples: [SourceTestHit]

    var candidateSelector: String?
    var includeRegex: String?
    var excludeRegex: String?
    var fetchMode: String?
    var minTitleLength: Int?
    var allowExternal: Bool?

    func applying(to source: SourceRecord) -> SourceRecord {
        var repaired = source

        if let candidateSelector { repaired.candidateSelector = candidateSelector }
        if let includeRegex { repaired.includeRegex = includeRegex }
        if let excludeRegex { repaired.excludeRegex = excludeRegex }
        if let fetchMode { repaired.fetchMode = fetchMode }
        if let minTitleLength { repaired.minTitleLength = minTitleLength }
        if let allowExternal { repaired.allowExternal = allowExternal }

        repaired.baselineVersion = SourceRecord.makeBaselineVersion()
        return repaired
    }
}

struct SourceTestResult: Identifiable, Equatable {
    let id = UUID()
    let sourceID: UUID
    let kind: SourceTestKind
    let hitCount: Int
    let examples: [SourceTestHit]
    let message: String
    let testedAt: Date
    let repairProposal: SourceRepairProposal?
    let durationMs: Int

    init(
        sourceID: UUID,
        kind: SourceTestKind,
        hitCount: Int,
        examples: [SourceTestHit],
        message: String,
        testedAt: Date,
        repairProposal: SourceRepairProposal? = nil,
        durationMs: Int = 0
    ) {
        self.sourceID = sourceID
        self.kind = kind
        self.hitCount = hitCount
        self.examples = examples
        self.message = message
        self.testedAt = testedAt
        self.repairProposal = repairProposal
        self.durationMs = durationMs
    }

    func withDuration(_ milliseconds: Int) -> SourceTestResult {
        SourceTestResult(
            sourceID: sourceID,
            kind: kind,
            hitCount: hitCount,
            examples: examples,
            message: message,
            testedAt: testedAt,
            repairProposal: repairProposal,
            durationMs: milliseconds
        )
    }

    var isProblem: Bool { !kind.isSuccessLike }
}
