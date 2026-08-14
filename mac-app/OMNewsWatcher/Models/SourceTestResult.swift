import Foundation

enum SourceTestKind: String, Codable {
    case success
    case zeroHits
    case tooManyHits
    case technicalError

    var title: String {
        switch self {
        case .success: return "Quelle funktioniert"
        case .zeroHits: return "Keine Treffer"
        case .tooManyHits: return "Zu viele Treffer"
        case .technicalError: return "Technischer Fehler"
        }
    }
}

struct SourceTestHit: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String?
}

struct SourceTestResult: Identifiable, Equatable {
    let id = UUID()
    let sourceID: UUID
    let kind: SourceTestKind
    let hitCount: Int
    let examples: [SourceTestHit]
    let message: String
    let testedAt: Date

    var isProblem: Bool {
        kind != .success
    }
}
