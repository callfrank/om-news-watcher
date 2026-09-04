import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
#if canImport(FoundationXML)
import FoundationXML
#endif

struct FeedHistoryItem: Codable, Identifiable, Equatable {
    var guid: String
    var source: String
    var sourceLabel: String?
    var title: String
    var link: String
    var pageDate: String?
    var publishedAt: String?
    var detectedAt: String
    var deliveredAt: String?
    var recovered: Bool?
    var recoveryReason: String?
    var historicalBackfill: Bool?
    var manualOverride: Bool?
    var manualConfirmedAt: String?
    var groups: [String]?
    var tags: [String]?
    var priority: Int?
    var duplicateSources: [String]?

    var id: String { guid }
    var effectivePriority: Int { max(1, min(3, priority ?? 2)) }
    var displayDetectedAt: String {
        guard let date = Self.parseDate(detectedAt) else { return detectedAt }
        return Self.displayFormatter.string(from: date)
    }

    var displayPageDate: String? {
        guard let raw = pageDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        guard let date = Self.parsedPageDate(raw) else {
            return raw
        }

        return Self.publicationDisplayFormatter.string(from: date)
    }

    var effectivePublishedDate: Date? {
        if let publishedAt,
           let date = Self.parsedDate(publishedAt) {
            return date
        }

        if let pageDate,
           let date = Self.parsedPageDate(pageDate) {
            return date
        }

        return nil
    }

    var effectiveReaderDate: Date? {
        effectivePublishedDate ?? Self.parsedDate(detectedAt)
    }

    var isHistoricalDelivery: Bool {
        // Eine bewusste manuelle Übernahme ist kein versehentlicher
        // historischer Backfill und bleibt deshalb im Reader sichtbar.
        if manualOverride == true {
            return false
        }

        if historicalBackfill == true {
            return true
        }

        guard let published = effectivePublishedDate,
              let delivered = Self.parsedDate(deliveredAt ?? detectedAt)
        else {
            return false
        }

        return delivered.timeIntervalSince(published) >
            72 * 60 * 60
    }

    var isRecovered: Bool {
        recovered == true
    }

    func publicationIsCurrent(
        reference: Date = Date(),
        maxAgeHours: Double = 48
    ) -> Bool {
        guard let published = effectivePublishedDate else {
            // Quellen ohne brauchbares Veröffentlichungsdatum dürfen
            // weiterhin über ihren echten Erkennungszeitpunkt arbeiten.
            guard let detected = Self.parsedDate(detectedAt) else {
                return false
            }

            return detected >=
                reference.addingTimeInterval(-maxAgeHours * 60 * 60)
        }

        let lower =
            reference.addingTimeInterval(-maxAgeHours * 60 * 60)

        // Bei reinen Tagesdaten etwas Zukunftstoleranz.
        let upper =
            reference.addingTimeInterval(24 * 60 * 60)

        return published >= lower && published <= upper
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy · HH:mm"
        return formatter
    }()

    private static let publicationDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = .current
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private static let pageDateFormatters: [DateFormatter] = {
        let specifications: [(String, String)] = [
            ("de_DE", "dd.MM.yyyy"),
            ("de_DE", "d.M.yyyy"),
            ("de_DE", "d. MMMM yyyy"),
            ("de_DE", "d. MMM yyyy"),
            ("en_US_POSIX", "MMM d, yyyy"),
            ("en_US_POSIX", "MMM. d, yyyy"),
            ("en_US_POSIX", "MMMM d, yyyy"),
            ("en_US_POSIX", "d MMM yyyy"),
            ("en_US_POSIX", "MM/dd/yyyy")
        ]

        return specifications.map { locale, format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let fallbackFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parsedDate(_ value: String) -> Date? {
        if let date = isoFormatter.date(from: value) { return date }
        for formatter in fallbackFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func parsedPageDate(_ value: String) -> Date? {
        let clean = value
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let date = parsedDate(clean) {
            return date
        }

        for formatter in pageDateFormatters {
            if let date = formatter.date(from: clean) {
                return date
            }
        }

        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        parsedDate(value)
    }
}

enum SourceListFilter: String, CaseIterable, Identifiable {
    case all, active, paused, problems, visual, timeout, untested
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Alle"
        case .active: return "Aktiv"
        case .paused: return "Pausiert"
        case .problems: return "Probleme"
        case .visual: return "Visuell eingelernt"
        case .timeout: return "Timeout"
        case .untested: return "Noch nicht getestet"
        }
    }
}

enum EmailAlertMode: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case hourly = "hourly"
    case twoHourly = "two-hour"
    case daily = "daily"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Aus"
        case .hourly:
            return "Stündlich (05–18 Uhr)"
        case .twoHourly:
            return "Alle 2 Stunden (05–18 Uhr)"
        case .daily:
            return "1× täglich (06 Uhr)"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Keine E-Mail-Benachrichtigungen."
        case .hourly:
            return "Sammelmail jede Stunde von 05 bis einschließlich 18 Uhr – nur wenn neue Treffer vorliegen."
        case .twoHourly:
            return "Sammelmail um 05, 07, 09, 11, 13, 15 und 17 Uhr – nur wenn neue Treffer vorliegen."
        case .daily:
            return "Eine Sammelmail um 06 Uhr – nur wenn seit der letzten Mail neue Treffer vorliegen."
        }
    }
}

struct EmailNotificationSettings: Codable, Equatable {
    var mode: EmailAlertMode
    var timezone: String
    var enabledAt: String?

    static let off = EmailNotificationSettings(
        mode: .off,
        timezone: "Europe/Berlin",
        enabledAt: nil
    )
}

struct SourceHealthAuditItem: Codable, Equatable {
    var title: String?
    var link: String?
    var pageDate: String?
    var publishedAt: String?
    var detectedAt: String?
    var deliveredAt: String?
    var recovered: Bool?
}

struct SourceHealthSnapshot: Codable, Identifiable, Equatable {
    var source: String
    var sourceLabel: String?
    var url: String?
    var enabled: Bool
    var skipped: Bool
    var checkedAt: String?
    var lastSuccessAt: String?
    var lastNewAt: String?
    var hitCount: Int?
    var averageHitCount: Double?
    var technicalHitCount: Int?
    var eligibleHitCount: Int?
    var rejectedHitCount: Int?
    var healthStatus: String?
    var healthSummary: String?
    var durationMs: Int?
    var anomaly: String?
    var message: String?
    var trackingStatus: String?
    var trackingWarning: String?
    var latestDetected: SourceHealthAuditItem?
    var latestStored: SourceHealthAuditItem?
    var healedCount: Int?
    var healedTodayCount: Int?
    var baselineSuppressedCount: Int?
    var undeliveredRecentCount: Int?
    var nextCheckAt: String?
    var checkIntervalMinutes: Int?
    var weekdaysOnly: Bool?

    var id: String { source.lowercased() }

    var effectiveHealthStatus: String {
        if let healthStatus, !healthStatus.isEmpty {
            return healthStatus
        }

        if skipped {
            return "skipped"
        }

        if (anomaly ?? "").hasPrefix("Abruf fehlgeschlagen:") {
            return "error"
        }

        if !(anomaly ?? "").isEmpty ||
           (undeliveredRecentCount ?? 0) > 0 ||
           trackingStatus == "warning" {
            return "anomaly"
        }

        if (eligibleHitCount ?? 0) == 0 {
            return "no-new"
        }

        return "healthy"
    }

    var hasWarning: Bool {
        effectiveHealthStatus == "error" ||
        effectiveHealthStatus == "anomaly"
    }

    var healthTitle: String {
        switch effectiveHealthStatus {
        case "error":
            return "Fehler"
        case "anomaly":
            return "Auffällig"
        case "no-new":
            return "Keine neue Meldung"
        case "skipped":
            return "Übersprungen"
        case "paused":
            return "Pausiert"
        default:
            return "Gesund"
        }
    }

    var healthSystemImage: String {
        switch effectiveHealthStatus {
        case "error":
            return "xmark.octagon.fill"
        case "anomaly":
            return "exclamationmark.triangle.fill"
        case "no-new":
            return "checkmark.circle"
        case "skipped":
            return "clock.fill"
        case "paused":
            return "pause.circle.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    var trackingDisplay: String {
        if let count = undeliveredRecentCount, count > 0 {
            return "⚠ \(count) fehlt"
        }
        if trackingStatus == "healed", (healedCount ?? 0) > 0 {
            return "🩹 \(healedCount ?? 0) gesamt"
        }
        return "OK"
    }

    var displayTechnicalCount: String {
        if let technicalHitCount {
            if let averageHitCount {
                return "\(technicalHitCount) · Ø \(String(format: "%.1f", averageHitCount))"
            }
            return "\(technicalHitCount)"
        }

        if let hitCount {
            return "\(hitCount)"
        }

        return "—"
    }

    // Backward-compatible alias for older views/debug helpers.
    var displayHitCount: String {
        displayTechnicalCount
    }

    var displayEligibleCount: String {
        guard let eligibleHitCount else {
            return "—"
        }

        if let rejectedHitCount, rejectedHitCount > 0 {
            return "\(eligibleHitCount) · −\(rejectedHitCount)"
        }

        return "\(eligibleHitCount)"
    }

}

struct SourceHealthReport: Codable {
    var generatedAt: String
    var watcherVersion: String?
    var trackingSchemaVersion: Int?
    var sources: [SourceHealthSnapshot]
}

private struct ReaderActivityState: Codable {
    var lastSeenAt: String
    var updatedAt: String
    var appVersion: String
}

private struct OMNewsWatcherBackup: Codable {
    var version: Int
    var exportedAt: String
    var sources: [JSONValue]
    var readerReadIDs: [String]
    var readerFavoriteIDs: [String]
    var readerArchivedIDs: [String]
    var owner: String
    var repo: String
    var branch: String
    var workflow: String
    var sourcesPath: String
    var emailAlertMode: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sources: [SourceRecord] = []
    @Published var selectedSourceID: UUID?
    @Published var isBusy = false
    @Published var isDirty = false
    @Published var statusMessage = "Bereit"
    @Published var errorMessage: String?
    @Published var latestRun: WorkflowRun?
    @Published var hasToken = false
    @Published var showSettings = false
    @Published var showEditor = false
    @Published var showProblems = false
    @Published var editingSource: SourceRecord?
    @Published var testResults: [UUID: SourceTestResult] = [:]
    @Published var testingSourceID: UUID?
    @Published var showVisualTrainer = false
    @Published var visualTrainingSource: SourceRecord?
    @Published var emailAlertMode: EmailAlertMode = .off
    @Published var emailSettingsDirty = false
    @Published var emailTestStatus: String?
    @Published var isTestingAll = false
    @Published var allTestCompleted = 0
    @Published var allTestTotal = 0
    @Published var allTestCurrentName = ""
    @Published var feedItems: [FeedHistoryItem] = []
    @Published var showFeedPreview = false
    @Published var showHealthDashboard = false
    @Published var showGroupManager = false
    @Published var showBulkManager = false
    @Published var showRuleDebugger = false
    @Published var bulkSelectedIDs: Set<UUID> = []
    @Published var healthItems: [SourceHealthSnapshot] = []
    @Published var healthGeneratedAt: String?
    @Published var healthWatcherVersion: String?
    @Published var healthTrackingSchemaVersion: Int?

    // MARK: - Integrierter Reader
    @Published var showReader = false
    @Published private(set) var readerReadIDs: Set<String> = []
    @Published private(set) var readerFavoriteIDs: Set<String> = []
    @Published private(set) var readerArchivedIDs: Set<String> = []
    @Published private(set) var readerCachedItems: [FeedHistoryItem] = []

    @Published var readerReadRetentionDays: Int {
        didSet {
            let allowed = [0, 1, 3, 7, 14, 30]

            if !allowed.contains(readerReadRetentionDays) {
                readerReadRetentionDays = 1
                return
            }

            defaults.set(
                readerReadRetentionDays,
                forKey: Keys.readerReadRetentionDays
            )

            rebuildReaderUnreadCache()
        }
    }

    private var readerUnreadTotalCache = 0
    private var readerUnreadByGroupCache: [String: Int] = [:]
    private var readerUnreadBySourceCache: [String: Int] = [:]
    private var readerUngroupedUnreadCache = 0

    private var readerAllByGroupCache: [String: Int] = [:]
    private var readerFavoriteByGroupCache: [String: Int] = [:]
    private var readerArchivedByGroupCache: [String: Int] = [:]

    @Published var owner: String {
        didSet { defaults.set(owner, forKey: Keys.owner) }
    }

    @Published var repo: String {
        didSet { defaults.set(repo, forKey: Keys.repo) }
    }

    @Published var branch: String {
        didSet { defaults.set(branch, forKey: Keys.branch) }
    }

    @Published var workflow: String {
        didSet { defaults.set(workflow, forKey: Keys.workflow) }
    }

    @Published var sourcesPath: String {
        didSet { defaults.set(sourcesPath, forKey: Keys.sourcesPath) }
    }

    private let defaults = UserDefaults.standard
    private var token = ""
    private var currentSHA = ""
    private var emailSettingsSHA = ""
    private var emailEnabledAt: String?
    private var pollingTask: Task<Void, Never>?
    private var lastRefreshedCompletedRunID: Int64?
    private var readerActivitySyncTask: Task<Void, Never>?
    private var activeTester: SourceTester?
    private var savedSourcesSnapshot: [SourceRecord] = []

    private enum Keys {
        static let owner = "github.owner"
        static let repo = "github.repo"
        static let branch = "github.branch"
        static let workflow = "github.workflow"
        static let sourcesPath = "github.sourcesPath"
        static let readerReadIDs = "reader.readIDs"
        static let readerFavoriteIDs = "reader.favoriteIDs"
        static let readerArchivedIDs = "reader.archivedIDs"
        static let readerV41BaselineApplied = "reader.v41BaselineApplied"
        static let readerLastOpenedAt = "reader.lastOpenedAt"
        static let readerReadRetentionDays = "reader.readRetentionDays"
    }

    init() {
        let storedRetention =
            UserDefaults.standard.object(
                forKey: Keys.readerReadRetentionDays
            ) as? Int

        readerReadRetentionDays =
            [0, 1, 3, 7, 14, 30].contains(storedRetention ?? -1)
            ? (storedRetention ?? 1)
            : 1

        owner = UserDefaults.standard.string(forKey: Keys.owner) ?? "callfrank"
        repo = UserDefaults.standard.string(forKey: Keys.repo) ?? "om-news-watcher"
        branch = UserDefaults.standard.string(forKey: Keys.branch) ?? "main"
        workflow = UserDefaults.standard.string(forKey: Keys.workflow) ?? "watch.yml"
        sourcesPath = UserDefaults.standard.string(forKey: Keys.sourcesPath) ?? "sources.json"

        readerReadIDs = Set(
            UserDefaults.standard.stringArray(forKey: Keys.readerReadIDs) ?? []
        )
        readerFavoriteIDs = Set(
            UserDefaults.standard.stringArray(forKey: Keys.readerFavoriteIDs) ?? []
        )
        readerArchivedIDs = Set(
            UserDefaults.standard.stringArray(forKey: Keys.readerArchivedIDs) ?? []
        )
    }

    var repositorySettings: RepositorySettings {
        RepositorySettings(
            owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
            repo: repo.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            workflow: workflow.trimmingCharacters(in: .whitespacesAndNewlines),
            sourcesPath: sourcesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var activeCount: Int {
        sources.filter(\.enabled).count
    }

    var pausedCount: Int {
        sources.count - activeCount
    }

    var allGroups: [String] {
        Array(Set(sources.flatMap(\.groups))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var allTags: [String] {
        Array(Set(sources.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var ungroupedCount: Int { sources.filter { $0.groups.isEmpty }.count }

    func groupCount(_ group: String) -> Int {
        sources.filter { $0.groups.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) }.count
    }

    func latestItem(for source: SourceRecord) -> FeedHistoryItem? {
        feedItems
            .filter { $0.source == source.name }
            .max { $0.detectedAt < $1.detectedAt }
    }

    func groupFeedURL(_ group: String) -> URL? {
        URL(string: "https://\(owner).github.io/\(repo)/feeds/\(Self.slugify(group)).xml")
    }

    static func slugify(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    var problemCount: Int {
        sources.filter { source in
            testResults[source.id]?.isProblem == true
        }.count
    }

    var allTestProgressText: String? {
        guard isTestingAll, allTestTotal > 0 else { return nil }
        return "\(allTestCompleted) von \(allTestTotal) geprüft" +
            (allTestCurrentName.isEmpty ? "" : " · \(allTestCurrentName)")
    }

    var feedURL: URL? {
        URL(string: "https://\(owner).github.io/\(repo)/feed.xml")
    }

    var selectedSource: SourceRecord? {
        guard let id = selectedSourceID else { return nil }
        return sources.first(where: { $0.id == id })
    }

    func startup() async {
        token = await KeychainStore.readToken() ?? ""
        hasToken = !token.isEmpty
        await reloadAll()
        lastRefreshedCompletedRunID =
            latestRun?.status == "completed" ? latestRun?.id : nil
        beginPolling()

        if let stored = defaults.string(
            forKey: Keys.readerLastOpenedAt
        ).flatMap(FeedHistoryItem.parsedDate) {
            scheduleReaderActivitySync(
                at: stored,
                delayNanoseconds: 300_000_000
            )
        }
    }

    func reloadAll() async {
        await loadSources()

        async let feedLoad: Void = loadFeedItems()
        async let emailLoad: Void = loadEmailSettings()
        async let runLoad: Void = refreshLatestRun()
        async let healthLoad: Void = loadHealth()
        _ = await (feedLoad, emailLoad, runLoad, healthLoad)
    }

    func loadFeedItems() async {
        do {
            guard let file = try await client().fetchFileIfExists(path: "data/items.json") else {
                feedItems = []
                return
            }
            let decoded =
                (try? JSONDecoder().decode([FeedHistoryItem].self, from: file.data)) ?? []
            let cleaned = cleanedReaderItems(from: decoded)

            feedItems = decoded
            readerCachedItems = cleaned

            pruneReaderState()
            applyReaderV41BaselineIfNeeded()
            rebuildReaderUnreadCache()
            updateReaderDockBadge()
        } catch {
            // Feed-Vorschau ist eine Komfortfunktion und soll den Start nicht blockieren.
        }
    }

    // MARK: - Manuelle Reader-Übernahme

    /// Übernimmt bewusst bestätigte Testtreffer in genau dieselbe Ablage wie
    /// der Watcher. Die automatische Erkennung und deren Eligibility-Gate
    /// bleiben davon unberührt.
    func importRejectedHitsIntoReader(
        _ hits: [SourceRejectedHit],
        from source: SourceRecord
    ) async {
        let candidates = hits.filter {
            guard let url = $0.url?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) else {
                return false
            }
            return !url.isEmpty
        }

        guard !candidates.isEmpty else {
            statusMessage = "Für diese Treffer fehlt eine übernehmbare URL"
            return
        }

        await performBusy("Übernehme in den Reader …") {
            guard self.hasToken else {
                self.showSettings = true
                throw GitHubAPIError.missingToken
            }

            let existing = try await self.client().fetchFileIfExists(
                path: "data/items.json"
            )
            var items = existing.flatMap {
                try? JSONDecoder().decode(
                    [FeedHistoryItem].self,
                    from: $0.data
                )
            } ?? []

            var knownGUIDs = Set(items.map(\.guid))
            var knownLinks = Set(items.map { self.normalizedReaderLink($0.link) })
            let now = ISO8601DateFormatter().string(from: Date())
            var added = 0
            var skipped = 0

            for hit in candidates {
                guard let link = hit.url?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !link.isEmpty else {
                    continue
                }

                let guid = self.readerGUID(for: link)
                let normalizedLink = self.normalizedReaderLink(link)
                guard !knownGUIDs.contains(guid),
                      !knownLinks.contains(normalizedLink)
                else {
                    skipped += 1
                    continue
                }

                items.append(
                    FeedHistoryItem(
                        guid: guid,
                        source: source.name,
                        sourceLabel: source.feedLabel,
                        title: hit.title,
                        link: link,
                        pageDate: hit.publicationDate,
                        publishedAt: nil,
                        detectedAt: now,
                        deliveredAt: now,
                        recovered: false,
                        recoveryReason: "Manuell im Quellen-Test bestätigt",
                        historicalBackfill: false,
                        manualOverride: true,
                        manualConfirmedAt: now,
                        groups: source.groups,
                        tags: source.tags,
                        priority: source.priority,
                        duplicateSources: nil
                    )
                )
                knownGUIDs.insert(guid)
                knownLinks.insert(normalizedLink)
                added += 1
            }

            guard added > 0 else {
                self.statusMessage = "Bereits im Reader vorhanden"
                return
            }

            items.sort { $0.detectedAt > $1.detectedAt }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes
            ]
            let data = try encoder.encode(items)

            _ = try await self.client().saveFile(
                path: "data/items.json",
                data: data,
                sha: existing?.sha,
                message: "Manually add confirmed reader item via OM News Watcher Mac"
            )

            self.feedItems = items
            self.readerCachedItems = self.cleanedReaderItems(from: items)
            self.pruneReaderState()
            self.rebuildReaderUnreadCache()
            self.updateReaderDockBadge()

            let addedText = added == 1
                ? "1 Treffer in den Reader übernommen"
                : "\(added) Treffer in den Reader übernommen"
            self.statusMessage = skipped > 0
                ? "\(addedText) · \(skipped) bereits vorhanden"
                : addedText
        }
    }

    func rejectedHitIsAlreadyInReader(_ hit: SourceRejectedHit) -> Bool {
        guard let link = hit.url?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !link.isEmpty else {
            return false
        }

        let guid = readerGUID(for: link)
        let normalizedLink = normalizedReaderLink(link)
        return feedItems.contains {
            $0.guid == guid || normalizedReaderLink($0.link) == normalizedLink
        }
    }

    private func readerGUID(for link: String) -> String {
        // Entspricht der ID-Bildung des Watchers: SHA-256 der gespeicherten
        // (bereits vom Tester aufgelösten) Ziel-URL, auf 24 Stellen gekürzt.
        let digest = SHA256.hash(data: Data(link.utf8))
        return digest.map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)
            .description
    }

    private func normalizedReaderLink(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
        }

        components.fragment = nil
        components.queryItems = components.queryItems?.filter { item in
            let key = item.name.lowercased()
            return !key.hasPrefix("utm_") &&
                key != "fbclid" &&
                key != "gclid" &&
                key != "ref" &&
                !key.hasPrefix("ref_") &&
                key != "source" &&
                !key.hasPrefix("mc_") &&
                key != "cache_bust" &&
                key != "cachebust" &&
                key != "_omw_fresh"
        }

        var normalized = (components.string ?? value).lowercased()
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    func loadHealth() async {
        do {
            guard let file = try await client().fetchFileIfExists(
                path: "data/health.json"
            ) else {
                healthItems = []
                healthGeneratedAt = nil
                healthWatcherVersion = nil
                healthTrackingSchemaVersion = nil
                return
            }

            let report = try JSONDecoder().decode(
                SourceHealthReport.self,
                from: file.data
            )
            healthItems = report.sources
            healthGeneratedAt = report.generatedAt
            healthWatcherVersion = report.watcherVersion
            healthTrackingSchemaVersion = report.trackingSchemaVersion
        } catch {
            // Ergänzende Diagnose darf den Start nicht blockieren.
        }
    }

    func health(for source: SourceRecord) -> SourceHealthSnapshot? {
        healthItems.first {
            $0.source.caseInsensitiveCompare(source.name) == .orderedSame
        }
    }

    var healthWarningCount: Int {
        healthItems.filter(\.hasWarning).count
    }

    var healthHealthyCount: Int {
        healthItems.filter {
            $0.enabled &&
            $0.effectiveHealthStatus == "healthy"
        }.count
    }

    var healthNoNewCount: Int {
        healthItems.filter {
            $0.enabled &&
            $0.effectiveHealthStatus == "no-new"
        }.count
    }

    var healthAnomalyCount: Int {
        healthItems.filter {
            $0.enabled &&
            $0.effectiveHealthStatus == "anomaly"
        }.count
    }

    var healthErrorCount: Int {
        healthItems.filter {
            $0.enabled &&
            $0.effectiveHealthStatus == "error"
        }.count
    }

    var healthHealedTodayCount: Int {
        healthItems.reduce(0) {
            $0 + ($1.healedTodayCount ?? 0)
        }
    }

    var healthSkippedCount: Int {
        healthItems.filter { $0.enabled && $0.skipped }.count
    }

    var healthStaleCount: Int {
        let threshold = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        return healthItems.filter { item in
            guard item.enabled,
                  let raw = item.lastNewAt,
                  let date = FeedHistoryItem.parsedDate(raw)
            else { return false }
            return date < threshold
        }.count
    }

    func selectSource(named name: String) {
        selectedSourceID = sources.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.id
    }

    func loadSources() async {
        await performBusy("Quellen werden geladen …") {
            let file = try await self.client().fetchSources()
            let values = try JSONDecoder().decode([JSONValue].self, from: file.data)

            let decodedSources = values.compactMap { value -> SourceRecord? in
                guard case .object(let object) = value else { return nil }
                return SourceRecord(raw: object)
            }

            self.sources = decodedSources
            self.savedSourcesSnapshot = decodedSources
            self.currentSHA = file.sha
            self.isDirty = false
            self.testResults = [:]

            if let selected = self.selectedSourceID,
               !decodedSources.contains(where: { $0.id == selected }) {
                self.selectedSourceID = decodedSources.first?.id
            } else if self.selectedSourceID == nil {
                self.selectedSourceID = decodedSources.first?.id
            }

            self.statusMessage = "\(decodedSources.count) Quellen geladen"
        }
    }

    func saveSources() async throws {
        guard hasToken else {
            showSettings = true
            throw GitHubAPIError.missingToken
        }

        guard !currentSHA.isEmpty else {
            throw GitHubAPIError.invalidResponse
        }

        let values = sources.map { JSONValue.object($0.raw) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values)

        statusMessage = "Speichere sources.json …"
        let newSHA = try await client().saveSources(data: data, sha: currentSHA)
        currentSHA = newSHA
        savedSourcesSnapshot = sources
        isDirty = false
        statusMessage = "Quellen gespeichert"
    }

    func saveSourcesFromToolbar() async {
        await performBusy("Speichere Quellen …") {
            try await self.saveSources()
        }
    }

    func saveSourcesForNavigation() async -> Bool {
        guard !isBusy else { return false }

        isBusy = true
        statusMessage = "Speichere Änderungen …"
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await saveSources()
            return true
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Fehler"
            return false
        }
    }

    func discardUnsavedChanges() {
        sources = savedSourcesSnapshot

        let validIDs = Set(savedSourcesSnapshot.map(\.id))
        testResults = testResults.filter { validIDs.contains($0.key) }

        if let selectedSourceID, !validIDs.contains(selectedSourceID) {
            self.selectedSourceID = savedSourcesSnapshot.first?.id
        }

        isDirty = false
        statusMessage = "Ungespeicherte Änderungen verworfen"
    }

    func runWorkflow() async {
        await performBusy("Watcher wird gestartet …") {
            if self.isDirty {
                try await self.saveSources()
            }

            if let run = try await self.client().dispatchWorkflow() {
                self.latestRun = run
            }

            self.statusMessage = "Watcher gestartet"
            self.beginPolling()
        }
    }

    func refreshLatestRun() async {
        do {
            latestRun = try await client().latestWorkflowRun()
        } catch {
            // Komfortfunktion: Fehler beim Statusabruf blockieren die Quellenverwaltung nicht.
        }
    }

    func addSource(defaultGroup: String? = nil) {
        var source = SourceRecord.new()
        if let defaultGroup,
           !defaultGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source.groups = [defaultGroup]
        }
        editingSource = source
        showEditor = true
    }

    func editSelectedSource() {
        guard let selectedSource else { return }
        editingSource = selectedSource
        showEditor = true
    }

    func startVisualTrainingSelected() {
        guard let selectedSource else { return }
        startVisualTraining(sourceID: selectedSource.id)
    }

    func startVisualTraining(sourceID: UUID) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        visualTrainingSource = source
        showVisualTrainer = true
        statusMessage = "Visuelles Einlernen: \(source.name)"
    }

    func applyVisualTrainingRule(
        _ rule: VisualTrainingRule,
        to sourceID: UUID
    ) {
        Task { @MainActor in
            await validateAndApplyVisualTrainingRule(rule, to: sourceID)
        }
    }

    private func validateAndApplyVisualTrainingRule(
        _ rule: VisualTrainingRule,
        to sourceID: UUID
    ) async {
        guard !isTestingAll,
              testingSourceID == nil,
              let index = sources.firstIndex(where: { $0.id == sourceID })
        else { return }

        let original = sources[index]
        let variants = visualValidationVariants(for: rule)

        showVisualTrainer = false
        visualTrainingSource = nil
        testingSourceID = sourceID
        statusMessage = "\(original.name): Einlernregel wird nach komplettem Neuladen validiert …"

        var bestResult: SourceTestResult?
        var acceptedSource: SourceRecord?
        var acceptedResult: SourceTestResult?

        var acceptedURLOnlyFallback = false

        for (attemptIndex, validationVariant) in variants.enumerated() {
            let variant = validationVariant.rule
            statusMessage = "\(original.name): Validierung \(attemptIndex + 1)/\(variants.count) – \(variant.strategy)"

            var candidate = original
            candidate.applyVisualTrainingRule(variant)

            var validationSource = candidate
            validationSource.waitMs = max(validationSource.waitMs, 4500)

            let tester = SourceTester()
            activeTester = tester
            var result = await tester.test(validationSource)
            activeTester = nil

            if result.hitCount < variant.sampleCount ||
               result.kind == .zeroHits ||
               result.kind == .timeout ||
               result.kind == .technicalError {
                var retrySource = candidate
                retrySource.waitMs = max(retrySource.waitMs, 7500)

                let retryTester = SourceTester()
                activeTester = retryTester
                let retryResult = await retryTester.test(retrySource)
                activeTester = nil

                if retryResult.kind.isSuccessLike ||
                   retryResult.hitCount > result.hitCount {
                    result = retryResult
                }
            }

            if bestResult == nil || result.hitCount > (bestResult?.hitCount ?? -1) {
                bestResult = result
            }

            let expectedCount = max(
                variant.previewCount,
                variant.sampleCount
            )
            let isDirectURLPattern =
                variant.strategy == "Direktes URL-Muster"

            let maximumPlausibleCount =
                isDirectURLPattern
                ? max(80, expectedCount * 8)
                : max(
                    expectedCount * 2 + 4,
                    variant.sampleCount * 4
                )

            if result.kind.isSuccessLike,
               result.hitCount >= variant.sampleCount,
               result.hitCount <= maximumPlausibleCount,
               !result.usedBroadVisualFallback {
                let validationMessage: String
                if validationVariant.isURLOnlyFallback {
                    validationMessage =
                        "URL-Regel gespeichert, Kartenstruktur war nach Reload nicht stabil"
                } else {
                    validationMessage =
                        "Nach Reload bestätigt: \(result.hitCount) Treffer · \(variant.strategy)"
                }

                candidate.markVisualTrainingValidated(validationMessage)
                acceptedSource = candidate
                acceptedResult = result
                acceptedURLOnlyFallback = validationVariant.isURLOnlyFallback
                break
            }
        }

        testingSourceID = nil

        // Wenn Browser- und HTML-Reproduktion scheitern, darf das bereits
        // erzeugte URL-Muster noch direkt an den bewusst markierten
        // Beispiel-URLs geprüft werden. Gespeichert wird ausschließlich die
        // bereinigte URL-Variante ohne Karten- oder DOM-Selektoren.
        if acceptedSource == nil,
           let validationVariant = variants.first(where: {
               $0.isURLOnlyFallback &&
               visualSampleURLsValidate($0.rule, sourceURL: original.url)
           }) {
            var candidate = original
            candidate.applyVisualTrainingRule(validationVariant.rule)
            candidate.markVisualTrainingValidated(
                "URL-Regel gespeichert, Kartenstruktur war nach Reload nicht stabil"
            )
            acceptedSource = candidate
            acceptedResult = SourceTestResult(
                sourceID: sourceID,
                kind: .noCurrentNews,
                hitCount: validationVariant.rule.sampleCount,
                examples: validationVariant.rule.preview.prefix(
                    validationVariant.rule.sampleCount
                ).map {
                    SourceTestHit(
                        title: $0.title,
                        url: $0.url,
                        publicationDate: $0.date
                    )
                },
                eligibleCount: 0,
                eligibleExamples: [],
                message:
                    "URL-Regel anhand der markierten Beispiel-URLs gespeichert; " +
                    "die Kartenstruktur war nach Reload nicht stabil.",
                testedAt: Date()
            )
            acceptedURLOnlyFallback = true
        }

        guard let candidate = acceptedSource,
              let result = acceptedResult
        else {
            if let bestResult {
                testResults[sourceID] = bestResult
            }

            errorMessage =
                "Die neue Einlernregel wurde nicht gespeichert. " +
                "Die App hat URL-Muster, markierte Beispiel-URLs und Kartenstruktur nach einem vollständigen Neuladen geprüft, " +
                "konnte die markierten Beispiele aber nicht stabil reproduzieren. " +
                "Die vorherige Regel bleibt unverändert."

            statusMessage = "\(original.name): Einlernregel nach Reload verworfen"
            return
        }

        sources[index] = candidate
        testResults[sourceID] = result
        isDirty = true
        statusMessage = acceptedURLOnlyFallback
            ? "\(original.name): URL-Regel gespeichert, Kartenstruktur war nach Reload nicht stabil – bitte speichern"
            : "\(original.name): Einlernregel validiert – bitte speichern"
    }

    private func visualValidationVariants(
        for rule: VisualTrainingRule
    ) -> [(rule: VisualTrainingRule, isURLOnlyFallback: Bool)] {
        var values: [(rule: VisualTrainingRule, isURLOnlyFallback: Bool)] = []
        var signatures = Set<String>()

        func append(
            _ value: VisualTrainingRule,
            isURLOnlyFallback: Bool = false
        ) {
            let signature = [
                value.itemSelector,
                value.titleSelector,
                value.linkSelector,
                value.candidateSelector,
                value.urlRegex ?? ""
            ].joined(separator: "|")

            guard signatures.insert(signature).inserted else { return }
            values.append((value, isURLOnlyFallback))
        }

        // Die vom Trainer vorgeschlagene vollständige Regel hat Vorrang.
        // Bei schwierigen Seiten ist das häufig "Kartenstruktur + URL-Muster".
        append(rule)

        // Wenn die Kartenstruktur nach Reload nicht reproduzierbar ist,
        // wird dieselbe URL-Regel ohne Karten- oder DOM-Selektoren geprüft.
        // SourceTester verwendet dann seinen allgemeinen Linkscan und wendet
        // weiterhin URL-Muster und Sample-URL-Formprüfung an.
        if let regex = rule.urlRegex, !regex.isEmpty {
            append(
                VisualTrainingRule(
                    itemSelector: "",
                    titleSelector: "",
                    linkSelector: "",
                    dateSelector: nil,
                    candidateSelector: "",
                    urlRegex: regex,
                    allowExternal: rule.allowExternal,
                    sampleCount: rule.sampleCount,
                    previewCount: rule.previewCount,
                    preview: rule.preview,
                    strategy: "URL-Muster",
                    sampleURLs: rule.sampleURLs
                ),
                isURLOnlyFallback: true
            )
        }

        return values
    }

    private func visualSampleURLsValidate(
        _ rule: VisualTrainingRule,
        sourceURL: String
    ) -> Bool {
        guard let pattern = rule.urlRegex,
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rule.sampleCount >= 2,
              rule.sampleURLs.count >= rule.sampleCount,
              let regex = try? NSRegularExpression(
                  pattern: pattern,
                  options: [.caseInsensitive]
              )
        else {
            return false
        }

        let sampleURLs = Array(rule.sampleURLs.prefix(rule.sampleCount))
        let allMatchExactly = sampleURLs.allSatisfy { value in
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(
                in: value,
                options: [],
                range: range
            ) else {
                return false
            }
            return match.range == range
        }

        guard allMatchExactly else { return false }

        let parsed = sampleURLs.compactMap(URL.init(string:))
        guard parsed.count == sampleURLs.count else { return false }

        let hosts = Set(parsed.compactMap { $0.host?.lowercased() })
        guard hosts.count == 1, let sampleHost = hosts.first else {
            return false
        }

        if !rule.allowExternal {
            guard let sourceHost = URL(string: sourceURL)?.host?.lowercased(),
                  sampleHost == sourceHost ||
                    sampleHost.hasSuffix(".\(sourceHost)") ||
                    sourceHost.hasSuffix(".\(sampleHost)")
            else {
                return false
            }
        }

        let pathParts = parsed.map {
            $0.path.split(separator: "/").map(String.init)
        }
        guard pathParts.allSatisfy({ $0.count >= 2 }) else {
            return false
        }

        let leaves = Set(pathParts.compactMap { $0.last?.lowercased() })
        return leaves.count >= 2
    }

    func restorePreviousRule(for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        var copy = sources[index]
        guard copy.restorePreviousRule() else {
            statusMessage = "\(copy.name): keine ältere Regel vorhanden"
            return
        }

        sources[index] = copy
        testResults.removeValue(forKey: sourceID)
        isDirty = true
        statusMessage = "\(copy.name): vorherige Regel wiederhergestellt – bitte testen und speichern"
    }

    func restoreAutomaticDetection(for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }

        var source = sources[index]
        source.restoreBeforeVisualTraining()
        sources[index] = source

        testResults.removeValue(forKey: sourceID)
        isDirty = true
        statusMessage = "\(source.name): Einlernregel zurückgesetzt"
    }

    func applyEditorResult(_ edited: SourceRecord) {
        var copy = edited

        if let index = sources.firstIndex(where: { $0.id == edited.id }) {
            let previous = sources[index]

            if previous.detectionConfiguration != copy.detectionConfiguration {
                copy.baselineVersion = SourceRecord.makeBaselineVersion()
                testResults.removeValue(forKey: copy.id)
            } else {
                copy.baselineVersion = previous.baselineVersion
            }

            sources[index] = copy
        } else {
            copy.baselineVersion = SourceRecord.makeBaselineVersion()
            sources.append(copy)
            selectedSourceID = copy.id
        }

        isDirty = true
        showEditor = false
        editingSource = nil
    }

    func automaticTagSuggestions(
        for source: SourceRecord,
        result explicitResult: SourceTestResult? = nil
    ) -> [String] {
        var parts: [String] = [
            source.name,
            source.shortName ?? "",
            source.url
        ]

        let result = explicitResult ?? testResults[source.id]
        if let result {
            parts.append(contentsOf: result.examples.map(\.title))
        }

        let sourceNames = Set([
            source.name.lowercased(),
            source.feedLabel.lowercased()
        ])

        parts.append(
            contentsOf: feedItems
                .filter {
                    sourceNames.contains($0.source.lowercased()) ||
                    sourceNames.contains(($0.sourceLabel ?? "").lowercased())
                }
                .prefix(12)
                .map(\.title)
        )

        let corpus = " " + parts
            .joined(separator: " ")
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "de_DE")
            )
            .lowercased() + " "

        let rules: [(String, [String])] = [
            (
                "Quartalszahlen",
                [" q1 ", " q2 ", " q3 ", " q4 ", " qz ", "quartal", "quarter", "earnings", "financial results", "jahreszahlen", "halbjahres"]
            ),
            (
                "Logistik",
                ["logistik", "logistics", "delivery", "shipping", "parcel", "paket", "freight", "warehouse", "lager", "fulfillment", "fulfilment", "dhl", "dpd", "fedex", "gls"]
            ),
            (
                "Payment",
                ["payment", "payments", "paypal", "visa", "mastercard", "klarna", "adyen", "checkout", "fintech", "wallet", "bezahlen", "zahlung"]
            ),
            (
                "E-Commerce",
                ["e-commerce", "ecommerce", "onlinehandel", "online retail", "marketplace", "marktplatz", "digital commerce"]
            ),
            (
                "Studien & Marktdaten",
                ["studie", "study", "studies", "research", "report", "survey", "umfrage", "index", "marktstudie", "market data"]
            ),
            (
                "Recht & Regulierung",
                ["recht", "gesetz", "regulier", "regulation", "compliance", "court", "gericht", "kartell", "bundeskartellamt", "bmj", "verbraucherzentrale", "consumer protection"]
            ),
            (
                "Events",
                ["event", "events", "conference", "konferenz", "summit", "messe", "webinar", "calendar", "kongress"]
            ),
            (
                "KI",
                [" kunstliche intelligenz ", " künstliche intelligenz ", " artificial intelligence ", " ai ", " ki ", "generative ai", "genai"]
            ),
            (
                "Sicherheit",
                ["cyber", "security", "fraud", "betrug", "phishing", "scam", "sicherheit"]
            ),
            (
                "Nachhaltigkeit",
                ["nachhalt", "sustainab", "esg", "climate", "klima", "circularity", "kreislauf"]
            ),
            (
                "Unternehmensstrategie",
                ["acquisition", "übernahme", "ubernahme", "merger", "strategie", "strategy", "expansion", "partnerschaft", "partnership"]
            )
        ]

        var suggestions: [String] = []

        for (tag, terms) in rules {
            guard terms.contains(where: { corpus.contains($0) }) else {
                continue
            }

            if !source.groups.contains(
                where: { $0.caseInsensitiveCompare(tag) == .orderedSame }
            ) {
                suggestions.append(tag)
            }
        }

        return Array(suggestions.prefix(6))
    }

    // Tag-Vorschläge sind bewusst nicht persistent.
    // automaticTagSuggestions(...) liest Testresultate und liefert sie dem Editor.
    // Erst der Quelleneditor übernimmt sie bei einem expliziten Speichern.

    func deleteSelectedSource() {
        guard let selectedID = selectedSourceID,
              let index = sources.firstIndex(where: { $0.id == selectedID })
        else { return }

        sources.remove(at: index)
        testResults.removeValue(forKey: selectedID)
        isDirty = true
        selectedSourceID = sources.indices.contains(index)
            ? sources[index].id
            : sources.last?.id
    }

    func setEnabled(_ enabled: Bool, for sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].enabled = enabled
        isDirty = true
    }

    func testSelectedSource() async {
        guard let selectedSource else { return }
        await testSource(selectedSource)
    }

    func testSource(_ source: SourceRecord) async {
        guard testingSourceID == nil, !isTestingAll else { return }

        testingSourceID = source.id
        statusMessage = "Teste \(source.name) …"
        errorMessage = nil

        let result = await executeTest(source)
        testResults[source.id] = result
        testingSourceID = nil
        updateVisualValidationAfterTest(sourceID: source.id, result: result)
        // Automatische Schlagworte bleiben nach Tests nur Vorschläge.
        // Sie werden erst bei einem bewussten Speichern im Quelleneditor übernommen.
        updateStatusAfterTest(source, result: result)
    }

    func testAllSources() async {
        guard !isTestingAll, testingSourceID == nil else { return }

        let candidates = sources.filter(\.enabled)
        isTestingAll = true
        allTestCompleted = 0
        allTestTotal = candidates.count
        allTestCurrentName = ""
        errorMessage = nil

        defer {
            testingSourceID = nil
            isTestingAll = false
            allTestCurrentName = ""
        }

        for source in candidates {
            allTestCurrentName = source.name
            testingSourceID = source.id
            statusMessage = "Alle Quellen testen: \(allTestCompleted) von \(allTestTotal)"

            let result = await executeTest(source)
            testResults[source.id] = result
            updateVisualValidationAfterTest(sourceID: source.id, result: result)
            // „Alle testen“ darf sources.json niemals still verändern.
            // Tag-Vorschläge werden aus testResults berechnet und erst im Editor gespeichert.
            allTestCompleted += 1
        }

        let testedResults = candidates.compactMap { testResults[$0.id] }
        let okCount = testedResults.filter { $0.kind == .success }.count
        let archiveCount = testedResults.filter { $0.kind == .largeArchive }.count
        let zeroCount = testedResults.filter { $0.kind == .zeroHits }.count
        let tooManyCount = testedResults.filter { $0.kind == .tooManyHits }.count
        let timeoutCount = testedResults.filter { $0.kind == .timeout }.count
        let technicalCount = testedResults.filter { $0.kind == .technicalError }.count

        statusMessage =
            "Alle getestet: \(okCount) OK · \(archiveCount) Archive · \(zeroCount) ohne Treffer · " +
            "\(tooManyCount) auffällig · \(timeoutCount) Timeout · \(technicalCount) technisch"
    }

    private func executeTest(_ source: SourceRecord) async -> SourceTestResult {
        let tester = SourceTester()
        activeTester = tester
        let result = await tester.test(source)
        activeTester = nil
        return result
    }

    private func updateVisualValidationAfterTest(
        sourceID: UUID,
        result: SourceTestResult
    ) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }),
              sources[index].visualLearned
        else { return }

        if result.kind.isSuccessLike {
            sources[index].markVisualTrainingValidated(
                "Nach Reload bestätigt: \(result.hitCount) Treffer"
            )
        } else {
            sources[index].markVisualTrainingUnvalidated(
                "Einlernregel nach Reload ungültig: \(result.kind.title)"
            )
        }
    }

    private func updateStatusAfterTest(
        _ source: SourceRecord,
        result: SourceTestResult
    ) {
        switch result.kind {
        case .success:
            statusMessage = "\(source.name): \(result.eligibleCount) aktuelle Meldung(en)"
        case .noCurrentNews:
            statusMessage = "\(source.name): technisch OK, aktuell keine neue Meldung"
        case .largeArchive:
            statusMessage = "\(source.name): großes plausibles Archiv (\(result.hitCount))"
        case .zeroHits:
            statusMessage = "\(source.name): keine Treffer"
        case .tooManyHits:
            statusMessage = "\(source.name): Trefferstruktur prüfen"
        case .timeout:
            statusMessage = "\(source.name): Zeitüberschreitung"
        case .technicalError:
            statusMessage = "\(source.name): technischer Fehler"
        }
    }

    func applyRepairProposal(
        _ proposal: SourceRepairProposal,
        to sourceID: UUID
    ) async {
        guard !isTestingAll,
              testingSourceID == nil,
              let index = sources.firstIndex(where: { $0.id == sourceID })
        else { return }

        let original = sources[index]
        var repairBase = original
        repairBase.recordRuleHistory(label: "Vor automatischer Reparatur")
        let repaired = proposal.applying(to: repairBase)

        testingSourceID = sourceID
        statusMessage = "\(original.name): Reparatur wird vor dem Speichern validiert …"
        let result = await executeTest(repaired)
        testingSourceID = nil
        testResults[sourceID] = result

        guard result.kind.isSuccessLike, result.hitCount >= 2 else {
            errorMessage =
                "Die automatische Reparatur wurde verworfen. " +
                "Die vorgeschlagene Regel liefert nach einem neuen Abruf kein plausibles Ergebnis."
            statusMessage = "\(original.name): Reparatur verworfen"
            return
        }

        sources[index] = repaired
        isDirty = true
        statusMessage = "\(original.name): Reparatur validiert – bitte speichern"
    }

    func loadEmailSettings() async {
        do {
            if let file = try await client().fetchFileIfExists(
                path: "email-settings.json"
            ) {
                let settings = try JSONDecoder().decode(
                    EmailNotificationSettings.self,
                    from: file.data
                )

                emailAlertMode = settings.mode
                emailEnabledAt = settings.enabledAt
                emailSettingsSHA = file.sha
            } else {
                emailAlertMode = .off
                emailEnabledAt = nil
                emailSettingsSHA = ""
            }

            emailSettingsDirty = false
        } catch {
            // Die Quellenverwaltung soll durch eine fehlende
            // E-Mail-Konfiguration nicht blockiert werden.
            emailAlertMode = .off
            emailEnabledAt = nil
            emailSettingsDirty = false
        }
    }

    func setEmailAlertMode(_ mode: EmailAlertMode) {
        guard emailAlertMode != mode else { return }

        let oldMode = emailAlertMode
        emailAlertMode = mode

        if mode == .off {
            emailEnabledAt = nil
        } else if oldMode == .off || emailEnabledAt == nil {
            emailEnabledAt = ISO8601DateFormatter().string(
                from: Date()
            )
        }

        emailSettingsDirty = true
        emailTestStatus = nil
    }

    func saveEmailSettings() async {
        await performBusy("E-Mail-Einstellung wird gespeichert …") {
            guard self.hasToken else {
                self.showSettings = true
                throw GitHubAPIError.missingToken
            }

            let settings = EmailNotificationSettings(
                mode: self.emailAlertMode,
                timezone: "Europe/Berlin",
                enabledAt:
                    self.emailAlertMode == .off
                    ? nil
                    : (
                        self.emailEnabledAt ??
                        ISO8601DateFormatter().string(from: Date())
                    )
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes
            ]

            let data = try encoder.encode(settings)

            let newSHA = try await self.client().saveFile(
                path: "email-settings.json",
                data: data,
                sha:
                    self.emailSettingsSHA.isEmpty
                    ? nil
                    : self.emailSettingsSHA,
                message:
                    "Update email alerts via OM News Watcher Mac"
            )

            self.emailSettingsSHA = newSHA
            self.emailEnabledAt = settings.enabledAt
            self.emailSettingsDirty = false
            self.emailTestStatus = "E-Mail-Einstellung gespeichert"
            self.statusMessage = "E-Mail-Einstellung gespeichert"
        }
    }

    func sendTestEmail() async {
        if emailSettingsDirty {
            await saveEmailSettings()
            if errorMessage != nil { return }
        }

        await performBusy("Test-E-Mail wird angefordert …") {
            guard self.hasToken else {
                self.showSettings = true
                throw GitHubAPIError.missingToken
            }

            try await self.client().dispatchWorkflow(
                workflow: "notify.yml",
                inputs: [
                    "force": "true"
                ]
            )

            self.emailTestStatus =
                "Test-E-Mail wurde bei GitHub angefordert. " +
                "Sie sollte nach dem Workflow-Lauf eintreffen."
            self.statusMessage = "Test-E-Mail angefordert"
        }
    }

    func openRepositorySecrets() {
        guard let url = URL(
            string:
                "https://github.com/\(owner)/\(repo)/settings/secrets/actions"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func saveToken(_ newToken: String) async {
        let cleaned = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        do {
            try await KeychainStore.saveToken(cleaned)
            token = cleaned
            hasToken = true
            statusMessage = "GitHub-Zugriff gespeichert"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearToken() async {
        do {
            try await KeychainStore.deleteToken()
            token = ""
            hasToken = false
            statusMessage = "GitHub-Zugriff entfernt"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addGroup(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let selectedSourceID {
            assignGroup(cleaned, to: Set([selectedSourceID]))
            statusMessage = "Ordner \"\(cleaned)\" angelegt und der ausgewählten Quelle zugeordnet"
        } else {
            statusMessage = "Bitte zuerst eine Quelle auswählen; der Ordner wird mit der ersten Zuordnung angelegt"
        }
    }

    func renameGroup(_ oldName: String, to newName: String) {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, oldName != cleaned else { return }
        for index in sources.indices {
            if sources[index].groups.contains(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) {
                sources[index].groups = sources[index].groups.map { $0.caseInsensitiveCompare(oldName) == .orderedSame ? cleaned : $0 }
            }
        }
        isDirty = true
        statusMessage = "Ordner umbenannt"
    }

    func deleteGroup(_ group: String) {
        for index in sources.indices {
            sources[index].groups.removeAll { $0.caseInsensitiveCompare(group) == .orderedSame }
        }
        isDirty = true
        statusMessage = "Ordner entfernt; Quellen bleiben erhalten"
    }

    func assignGroup(_ group: String, to ids: Set<UUID>) {
        let cleaned = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        for index in sources.indices where ids.contains(sources[index].id) {
            if !sources[index].groups.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                sources[index].groups.append(cleaned)
            }
        }
        isDirty = true
        statusMessage = "\(ids.count) Quellen dem Ordner \"\(cleaned)\" zugeordnet"
    }

    func setEnabled(_ enabled: Bool, for ids: Set<UUID>) {
        for index in sources.indices where ids.contains(sources[index].id) {
            sources[index].enabled = enabled
        }
        isDirty = true
    }

    func deleteSources(_ ids: Set<UUID>) {
        sources.removeAll { ids.contains($0.id) }
        for id in ids { testResults.removeValue(forKey: id) }
        bulkSelectedIDs.subtract(ids)
        if let selectedSourceID, ids.contains(selectedSourceID) {
            self.selectedSourceID = sources.first?.id
        }
        isDirty = true
        statusMessage = "\(ids.count) Quellen entfernt – bitte speichern"
    }

    func removeGroup(_ group: String, from ids: Set<UUID>) {
        let cleaned = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        for index in sources.indices where ids.contains(sources[index].id) {
            sources[index].groups.removeAll {
                $0.caseInsensitiveCompare(cleaned) == .orderedSame
            }
        }

        isDirty = true
        statusMessage = "\(ids.count) Quellen aus dem Ordner „\(cleaned)“ entfernt"
    }

    func addTag(_ tag: String, to ids: Set<UUID>) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        for index in sources.indices where ids.contains(sources[index].id) {
            if !sources[index].tags.contains(
                where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
            ) {
                sources[index].tags.append(cleaned)
            }
        }

        isDirty = true
        statusMessage = "Schlagwort „\(cleaned)“ für \(ids.count) Quellen ergänzt"
    }

    func setPriority(_ priority: Int, for ids: Set<UUID>) {
        for index in sources.indices where ids.contains(sources[index].id) {
            sources[index].priority = priority
        }
        isDirty = true
        statusMessage = "Relevanz für \(ids.count) Quellen geändert"
    }

    func testSources(_ ids: Set<UUID>) async {
        guard !isTestingAll, testingSourceID == nil else { return }
        let candidates = sources.filter { ids.contains($0.id) }
        isTestingAll = true
        allTestCompleted = 0
        allTestTotal = candidates.count
        defer { testingSourceID = nil; isTestingAll = false; allTestCurrentName = "" }
        for source in candidates {
            allTestCurrentName = source.name
            testingSourceID = source.id
            let result = await executeTest(source)
            testResults[source.id] = result
            updateVisualValidationAfterTest(sourceID: source.id, result: result)
            allTestCompleted += 1
        }
        statusMessage = "Auswahl getestet: \(candidates.count) Quellen"
    }


    func beginReaderSession() -> Date? {
        let previous = defaults.string(forKey: Keys.readerLastOpenedAt)
            .flatMap(FeedHistoryItem.parsedDate)

        let now = Date()

        defaults.set(
            ISO8601DateFormatter().string(from: now),
            forKey: Keys.readerLastOpenedAt
        )

        // Die Mail soll nur Meldungen schicken, die seit der letzten
        // tatsächlichen Reader-Aktivität neu sind.
        scheduleReaderActivitySync(
            at: now,
            delayNanoseconds: 500_000_000
        )

        return previous
    }

    // MARK: - Reader

    var readerItems: [FeedHistoryItem] {
        readerCachedItems
    }

    var readerUnreadCount: Int {
        readerUnreadTotalCache
    }

    func readerUnreadCount(in group: String) -> Int {
        readerUnreadByGroupCache[group.lowercased()] ?? 0
    }

    func readerUnreadCount(for source: SourceRecord) -> Int {
        readerUnreadBySourceCache[source.name.lowercased()] ?? 0
    }

    func readerAllCount(in group: String) -> Int {
        readerAllByGroupCache[group.lowercased()] ?? 0
    }

    func readerFavoriteCount(in group: String) -> Int {
        readerFavoriteByGroupCache[group.lowercased()] ?? 0
    }

    func readerArchivedCount(in group: String) -> Int {
        readerArchivedByGroupCache[group.lowercased()] ?? 0
    }

    var readerUngroupedUnreadCount: Int {
        readerUngroupedUnreadCache
    }

    func readerIsRead(_ item: FeedHistoryItem) -> Bool {
        readerReadIDs.contains(item.id)
    }

    func readerIsFavorite(_ item: FeedHistoryItem) -> Bool {
        readerFavoriteIDs.contains(item.id)
    }

    func readerIsArchived(_ item: FeedHistoryItem) -> Bool {
        readerArchivedIDs.contains(item.id)
    }

    /// Aktiver Reader-Verlauf:
    /// - ungelesene Meldungen bleiben immer sichtbar
    /// - Favoriten bleiben immer sichtbar
    /// - gelesene Meldungen verschwinden nach der gewählten Frist
    /// - Archiv wird separat behandelt
    func readerVisibleInAll(
        _ item: FeedHistoryItem,
        reference: Date = Date()
    ) -> Bool {
        guard !readerIsArchived(item) else {
            return false
        }

        if !readerIsRead(item) || readerIsFavorite(item) {
            return true
        }

        guard let date =
            item.effectiveReaderDate ??
            FeedHistoryItem.parsedDate(item.detectedAt)
        else {
            return false
        }

        if readerReadRetentionDays == 0 {
            return Calendar.current.isDateInToday(date)
        }

        let cutoff =
            reference.addingTimeInterval(
                -Double(readerReadRetentionDays) *
                24 * 60 * 60
            )

        return date >= cutoff
    }

    func readerActiveAllCount() -> Int {
        readerCachedItems.filter {
            readerVisibleInAll($0)
        }.count
    }

    func readerMarkRead(_ item: FeedHistoryItem, read: Bool = true) {
        if read {
            readerReadIDs.insert(item.id)
        } else {
            readerReadIDs.remove(item.id)
        }
        persistReaderState()
    }

    func readerToggleRead(_ item: FeedHistoryItem) {
        readerMarkRead(item, read: !readerIsRead(item))
    }

    func readerToggleFavorite(_ item: FeedHistoryItem) {
        if readerFavoriteIDs.contains(item.id) {
            readerFavoriteIDs.remove(item.id)
        } else {
            readerFavoriteIDs.insert(item.id)
        }
        persistReaderState()
    }

    func readerToggleArchive(_ item: FeedHistoryItem) {
        if readerArchivedIDs.contains(item.id) {
            readerArchivedIDs.remove(item.id)
        } else {
            readerArchivedIDs.insert(item.id)
            readerReadIDs.insert(item.id)
        }
        persistReaderState()
    }

    func readerMarkAllRead(_ items: [FeedHistoryItem]) {
        for item in items {
            readerReadIDs.insert(item.id)
        }
        persistReaderState()
        statusMessage = "\(items.count) Meldungen als gelesen markiert"
    }

    func readerUnarchiveAll(_ items: [FeedHistoryItem]) {
        for item in items {
            readerArchivedIDs.remove(item.id)
        }
        persistReaderState()
    }

    private func applyReaderV41BaselineIfNeeded() {
        guard !defaults.bool(forKey: Keys.readerV41BaselineApplied) else { return }
        // v4.1 behandelt alles, was beim ersten Start bereits vorhanden ist, als Altbestand.
        // Erst danach neu hinzukommende Meldungen landen als ungelesen im Posteingang.
        for item in readerItems {
            readerReadIDs.insert(item.id)
        }
        defaults.set(true, forKey: Keys.readerV41BaselineApplied)
        defaults.set(Array(readerReadIDs), forKey: Keys.readerReadIDs)
    }

    private func cleanedReaderItems(from values: [FeedHistoryItem]) -> [FeedHistoryItem] {
        let genericExact: Set<String> = [
            "main menu", "menu", "stories", "media kit", "financial reports",
            "media & resources", "media and resources", "mappe zum unternehmen",
            "unternehmensnews", "unternehmensmitteilungen", "newsroom", "press",
            "skip to main content", "events", "event", "paypal",
            "dokumentation zur fehlerbehebung", "aktualisieren sie diese seite",
            "update this page", "who we are", "find us", "find us on",
            "all publications", "alle publikationen",
            "broschüren und infomaterial", "broschueren und infomaterial",
            "brochures and information material"
        ]
        let genericPrefixes = [
            "read article", "read more", "learn more", "mehr erfahren", "weiterlesen",
            "weiter lesen", "download for free", "download", "alle akzeptieren",
            "accept all", "cookie", "privacy settings"
        ]

        func normalizedTitle(_ value: String) -> String {
            value
                .folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: .current
                )
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }

        func normalizedURL(_ value: String) -> String {
            guard var parts = URLComponents(string: value) else {
                return value.lowercased()
            }
            parts.query = nil
            parts.fragment = nil
            var result = (parts.string ?? value).lowercased()
            while result.hasSuffix("/") {
                result.removeLast()
            }
            return result
        }

        var homepageBySource: [String: String] = [:]
        for source in sources {
            let homepage = normalizedURL(source.url)
            homepageBySource[source.name.lowercased()] = homepage
            homepageBySource[source.feedLabel.lowercased()] = homepage
        }

        func titleTokens(_ value: String) -> Set<String> {
            let stopwords: Set<String> = [
                "der", "die", "das", "den", "dem", "des", "ein", "eine",
                "und", "oder", "für", "mit", "von", "zu", "im", "in", "auf",
                "the", "a", "an", "and", "or", "for", "with", "of", "to", "on"
            ]

            return Set(
                normalizedTitle(value)
                    .split(separator: " ")
                    .map(String.init)
                    .filter { $0.count >= 3 && !stopwords.contains($0) }
            )
        }

        func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
            let a = titleTokens(lhs)
            let b = titleTokens(rhs)
            guard a.count >= 4, b.count >= 4 else { return 0 }

            let intersection = a.intersection(b).count
            let union = a.union(b).count
            guard union > 0 else { return 0 }
            return Double(intersection) / Double(union)
        }

        var seenLinks = Set<String>()
        var seenSourceTitles = Set<String>()
        var cleaned: [FeedHistoryItem] = []
        cleaned.reserveCapacity(values.count)

        for var item in values.sorted(by: { $0.detectedAt > $1.detectedAt }) {
            let title = normalizedTitle(item.title)
            guard title.count >= 5 else { continue }
            let manuallyConfirmed = item.manualOverride == true

            if !manuallyConfirmed {
                guard !genericExact.contains(title) else { continue }
                guard title.range(
                    of: #"^(?:seite|page)\s*\d+$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil else { continue }
                guard title.range(
                    of: #"^(?:aktuelle\s+seite|current\s+page)\s*\d+$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil else { continue }
                guard !genericPrefixes.contains(where: {
                    title == $0 || title.hasPrefix($0 + " ")
                }) else {
                    continue
                }
            }

            let cssArtifact =
                title.range(
                    of: #"\.[a-z0-9_-]+\s*\{[^}]{0,400}(?:fill|stroke|color|font|display)\s*:"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil ||
                (title.contains("{") &&
                 title.contains(";") &&
                 title.range(
                    of: #"(?:stroke-width|stroke-linecap|stroke-linejoin|fill|stroke)\s*:"#,
                    options: [.regularExpression, .caseInsensitive]
                 ) != nil)

            guard manuallyConfirmed || !cssArtifact else { continue }

            let link = normalizedURL(item.link)

            if !manuallyConfirmed && link.range(
                of: #"/shareddocs/publikationen/"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                continue
            }
            let homepage =
                homepageBySource[item.source.lowercased()] ??
                homepageBySource[(item.sourceLabel ?? "").lowercased()]

            if !manuallyConfirmed, let homepage, link == homepage {
                continue
            }

            guard seenLinks.insert(link).inserted else {
                continue
            }

            let sourceTitleKey = item.source.lowercased() + "|" + title
            guard seenSourceTitles.insert(sourceTitleKey).inserted else {
                continue
            }

            if title.count >= 24,
               let duplicateIndex = cleaned.prefix(120).firstIndex(
                    where: {
                        $0.source.caseInsensitiveCompare(item.source) != .orderedSame &&
                        titleSimilarity($0.title, item.title) >= 0.86
                    }
               ) {
                var existing = cleaned[duplicateIndex]
                var duplicates = existing.duplicateSources ?? []

                if !duplicates.contains(
                    where: { $0.caseInsensitiveCompare(item.source) == .orderedSame }
                ) {
                    duplicates.append(item.source)
                }

                existing.duplicateSources = duplicates
                existing.groups = Array(Set(
                    (existing.groups ?? []) + (item.groups ?? [])
                ))
                existing.tags = Array(Set(
                    (existing.tags ?? []) + (item.tags ?? [])
                ))
                existing.priority = max(
                    existing.effectivePriority,
                    item.effectivePriority
                )
                cleaned[duplicateIndex] = existing
                continue
            }

            cleaned.append(item)
        }

        return cleaned
    }

    private func rebuildReaderUnreadCache() {
        var unreadTotal = 0
        var unreadByGroup: [String: Int] = [:]
        var unreadBySource: [String: Int] = [:]
        var unreadUngrouped = 0
        var allByGroup: [String: Int] = [:]
        var favoriteByGroup: [String: Int] = [:]
        var archivedByGroup: [String: Int] = [:]

        for item in readerCachedItems {
            let groups = item.groups ?? []
            let isArchived = readerArchivedIDs.contains(item.id)
            let isFavorite = readerFavoriteIDs.contains(item.id)
            let isUnread = !readerReadIDs.contains(item.id)
            let isHistoricalDelivery = item.isHistoricalDelivery

            if isArchived {
                for group in groups {
                    archivedByGroup[group.lowercased(), default: 0] += 1
                }
                continue
            }

            if readerVisibleInAll(item) {


                for group in groups {


                    allByGroup[group.lowercased(), default: 0] += 1


                }


            }



            if isFavorite {
                for group in groups {
                    favoriteByGroup[group.lowercased(), default: 0] += 1
                }
            }

            guard isUnread else { continue }
            guard !isHistoricalDelivery else { continue }

            unreadTotal += 1
            unreadBySource[item.source.lowercased(), default: 0] += 1

            if groups.isEmpty {
                unreadUngrouped += 1
            } else {
                for group in groups {
                    unreadByGroup[group.lowercased(), default: 0] += 1
                }
            }
        }

        readerUnreadTotalCache = unreadTotal
        readerUnreadByGroupCache = unreadByGroup
        readerUnreadBySourceCache = unreadBySource
        readerUngroupedUnreadCache = unreadUngrouped
        readerAllByGroupCache = allByGroup
        readerFavoriteByGroupCache = favoriteByGroup
        readerArchivedByGroupCache = archivedByGroup
    }

    private func persistReaderState() {
        defaults.set(Array(readerReadIDs), forKey: Keys.readerReadIDs)
        defaults.set(Array(readerFavoriteIDs), forKey: Keys.readerFavoriteIDs)
        defaults.set(Array(readerArchivedIDs), forKey: Keys.readerArchivedIDs)
        rebuildReaderUnreadCache()
        updateReaderDockBadge()

        // Debounced: viele Klicks hintereinander erzeugen nur einen
        // kleinen GitHub-Commit mit dem letzten Reader-Zeitpunkt.
        scheduleReaderActivitySync(
            at: Date(),
            delayNanoseconds: 1_500_000_000
        )
    }

    private func scheduleReaderActivitySync(
        at date: Date,
        delayNanoseconds: UInt64
    ) {
        guard hasToken, !token.isEmpty else { return }

        readerActivitySyncTask?.cancel()

        readerActivitySyncTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: delayNanoseconds
                )
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await self?.saveReaderActivity(
                requestedDate: date
            )
        }
    }

    private func saveReaderActivity(
        requestedDate: Date
    ) async {
        guard hasToken, !token.isEmpty else { return }

        let path = "reader-state.json"
        let iso = ISO8601DateFormatter()

        for _ in 0..<2 {
            do {
                let existing =
                    try await client().fetchFileIfExists(
                        path: path
                    )

                var effectiveDate =
                    requestedDate

                if let data = existing?.data,
                   let remote = try? JSONDecoder().decode(
                        ReaderActivityState.self,
                        from: data
                   ),
                   let remoteDate = FeedHistoryItem.parsedDate(
                        remote.lastSeenAt
                   ),
                   remoteDate > effectiveDate {
                    effectiveDate = remoteDate
                }

                // Ist GitHub bereits mindestens auf diesem Stand, ist
                // kein weiterer Commit nötig.
                if let data = existing?.data,
                   let remote = try? JSONDecoder().decode(
                        ReaderActivityState.self,
                        from: data
                   ),
                   let remoteDate = FeedHistoryItem.parsedDate(
                        remote.lastSeenAt
                   ),
                   remoteDate >= requestedDate {
                    return
                }

                let now =
                    iso.string(from: Date())

                let payload =
                    ReaderActivityState(
                        lastSeenAt:
                            iso.string(
                                from: effectiveDate
                            ),
                        updatedAt:
                            now,
                        appVersion:
                            "5.3.5"
                    )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [
                    .prettyPrinted,
                    .sortedKeys
                ]

                let data =
                    try encoder.encode(
                        payload
                    )

                _ = try await client().saveFile(
                    path: path,
                    data: data,
                    sha: existing?.sha,
                    message:
                        "Update reader activity via OM News Watcher Mac"
                )

                return
            } catch {
                // GitHub kann genau zwischen GET und PUT geändert worden
                // sein. Einmal frisch lesen und erneut versuchen.
                continue
            }
        }

        // Reader-Bedienung darf niemals wegen eines optionalen
        // Synchronisationsfehlers blockieren oder einen Dialog erzeugen.
    }

    private func pruneReaderState() {
        let known = Set(feedItems.map(\.id))
        // Lesestatus darf länger leben als der 500er Feed-Verlauf,
        // aber die lokalen Sets sollen nicht unbegrenzt wachsen.
        if readerReadIDs.count > 10_000 {
            readerReadIDs = readerReadIDs.intersection(known)
        }
        if readerFavoriteIDs.count > 5_000 {
            readerFavoriteIDs = readerFavoriteIDs.intersection(known)
        }
        if readerArchivedIDs.count > 10_000 {
            readerArchivedIDs = readerArchivedIDs.intersection(known)
        }
        defaults.set(Array(readerReadIDs), forKey: Keys.readerReadIDs)
        defaults.set(Array(readerFavoriteIDs), forKey: Keys.readerFavoriteIDs)
        defaults.set(Array(readerArchivedIDs), forKey: Keys.readerArchivedIDs)
    }

    func updateReaderDockBadge() {
        let count = readerUnreadCount
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func exportFullBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OM-News-Watcher-Backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let backup = OMNewsWatcherBackup(
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            sources: sources.map { .object($0.raw) },
            readerReadIDs: Array(readerReadIDs),
            readerFavoriteIDs: Array(readerFavoriteIDs),
            readerArchivedIDs: Array(readerArchivedIDs),
            owner: owner,
            repo: repo,
            branch: branch,
            workflow: workflow,
            sourcesPath: sourcesPath,
            emailAlertMode: emailAlertMode.rawValue
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            try encoder.encode(backup).write(to: url)
            statusMessage = "Vollständiges Backup exportiert"
        } catch {
            errorMessage = "Backup konnte nicht geschrieben werden: \(error.localizedDescription)"
        }
    }

    func importFullBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(
                OMNewsWatcherBackup.self,
                from: data
            )

            let restoredSources = backup.sources.compactMap { value -> SourceRecord? in
                guard case .object(let object) = value else { return nil }
                return SourceRecord(raw: object)
            }

            guard !restoredSources.isEmpty else {
                throw NSError(
                    domain: "OMNewsWatcherBackup",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Das Backup enthält keine Quellen."]
                )
            }

            sources = restoredSources
            readerReadIDs = Set(backup.readerReadIDs)
            readerFavoriteIDs = Set(backup.readerFavoriteIDs)
            readerArchivedIDs = Set(backup.readerArchivedIDs)

            owner = backup.owner
            repo = backup.repo
            branch = backup.branch
            workflow = backup.workflow
            sourcesPath = backup.sourcesPath

            if let mode = EmailAlertMode(rawValue: backup.emailAlertMode) {
                emailAlertMode = mode
                emailSettingsDirty = true
            }

            persistReaderState()
            rebuildReaderUnreadCache()
            updateReaderDockBadge()

            selectedSourceID = sources.first?.id
            isDirty = true
            statusMessage = "Backup geladen – Quellen bitte speichern"
        } catch {
            errorMessage = "Backup konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    func openGroupFeed(_ group: String) {
        guard let url = groupFeedURL(group) else { return }
        NSWorkspace.shared.open(url)
    }

    func openFeedItem(_ item: FeedHistoryItem) {
        guard let url = URL(string: item.link) else { return }
        NSWorkspace.shared.open(url)
    }

    func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OM-News-Watcher-Feeds.opml"
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let overall = feedURL?.absoluteString ?? ""
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\"><head><title>OM News Watcher</title></head><body>",
            "<outline text=\"OM News Watcher\" title=\"OM News Watcher\" type=\"rss\" xmlUrl=\"\(xmlEscape(overall))\"/>"
        ]
        if !allGroups.isEmpty {
            lines.append("<outline text=\"Themenfeeds\" title=\"Themenfeeds\">")
            for group in allGroups {
                if let url = groupFeedURL(group)?.absoluteString {
                    lines.append("<outline text=\"\(xmlEscape(group))\" title=\"\(xmlEscape(group))\" type=\"rss\" xmlUrl=\"\(xmlEscape(url))\"/>")
                }
            }
            lines.append("</outline>")
        }
        lines.append("</body></opml>")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        statusMessage = "OPML exportiert"
    }

    func exportSourcesCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OM-News-Watcher-Quellen.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["Name;URL;Aktiv;Ordner;Tags;Priorität;Letzter neuer Treffer"]
        for source in sources {
            let latest = latestItem(for: source)?.detectedAt ?? ""
            let cells = [source.name, source.url, source.enabled ? "Ja" : "Nein", source.groups.joined(separator: ", "), source.tags.joined(separator: ", "), String(source.priority), latest]
            lines.append(cells.map(csvEscape).joined(separator: ";"))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        statusMessage = "CSV exportiert"
    }

    func exportSourcesJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OM-News-Watcher-Quellen.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = sources.map { JSONValue.object($0.raw) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(values) { try? data.write(to: url) }
        statusMessage = "JSON exportiert"
    }

    func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let parser = OPMLSourceParser(data: data)
        let entries = parser.parse()
        var added = 0
        for entry in entries {
            guard !entry.url.isEmpty, !sources.contains(where: { $0.url == entry.url }) else { continue }
            var source = SourceRecord.new(url: entry.url)
            source.name = entry.title.isEmpty ? SourceRecord.suggestedName(from: entry.url) : entry.title
            if let group = entry.group, !group.isEmpty { source.groups = [group] }
            if entry.isFeed { source.fetchMode = "feed"; source.allowExternal = true }
            source.homepageURL = entry.homepage
            sources.append(source); added += 1
        }
        if added > 0 { isDirty = true; selectedSourceID = sources.last?.id }
        statusMessage = "OPML importiert: \(added) neue Quellen"
    }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func openFeed() {
        guard let feedURL else { return }
        NSWorkspace.shared.open(feedURL)
    }

    func openLatestRun() {
        guard let latestRun,
              let url = URL(string: latestRun.htmlURL)
        else { return }

        NSWorkspace.shared.open(url)
    }

    func openRepository() {
        guard let url = URL(string: "https://github.com/\(owner)/\(repo)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openSource(_ source: SourceRecord) {
        guard let url = URL(string: source.homepageURL ?? source.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func openHit(_ hit: SourceTestHit) {
        guard let urlString = hit.url,
              let url = URL(string: urlString)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func client() -> GitHubClient {
        GitHubClient(settings: repositorySettings, token: token)
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                await self.refreshLatestRun()

                if let run = self.latestRun,
                   run.status == "completed",
                   run.id != self.lastRefreshedCompletedRunID {
                    async let feedLoad: Void = self.loadFeedItems()
                    async let healthLoad: Void = self.loadHealth()
                    _ = await (feedLoad, healthLoad)
                    self.lastRefreshedCompletedRunID = run.id
                    self.statusMessage = "Watcher: \(self.latestRun?.displayStatus ?? "beendet")"
                }
            }
        }
    }

    private func performBusy(
        _ message: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        isBusy = true
        statusMessage = message
        errorMessage = nil

        defer { isBusy = false }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Fehler"
        }
    }
}


private struct OPMLSourceEntry {
    let title: String
    let url: String
    let homepage: String?
    let group: String?
    let isFeed: Bool
}

private final class OPMLSourceParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var stack: [(title: String, isFolder: Bool)] = []
    private var entries: [OPMLSourceEntry] = []

    init(data: Data) { self.data = data }

    func parse() -> [OPMLSourceEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        let title = attributeDict["title"] ?? attributeDict["text"] ?? ""
        let html = attributeDict["htmlUrl"] ?? attributeDict["htmlurl"]
        let xml = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"]
        let isFolder = (html ?? xml) == nil
        let currentGroup = stack.last(where: { $0.isFolder })?.title
        if let url = xml ?? html {
            entries.append(OPMLSourceEntry(title: title, url: url, homepage: html, group: currentGroup, isFeed: xml != nil))
        }
        stack.append((title, isFolder))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "outline", !stack.isEmpty { stack.removeLast() }
    }
}
