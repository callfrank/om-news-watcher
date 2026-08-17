import Foundation
import AppKit
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
    var detectedAt: String
    var groups: [String]?
    var tags: [String]?
    var priority: Int?
    var duplicateSources: [String]?

    var id: String { guid }
    var effectivePriority: Int { max(1, min(3, priority ?? 2)) }
    var displayDetectedAt: String {
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: detectedAt) else { return detectedAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
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
    @Published var bulkSelectedIDs: Set<UUID> = []

    // MARK: - Integrierter Reader
    @Published var showReader = false
    @Published private(set) var readerReadIDs: Set<String> = []
    @Published private(set) var readerFavoriteIDs: Set<String> = []
    @Published private(set) var readerArchivedIDs: Set<String> = []

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
    private var activeTester: SourceTester?

    private enum Keys {
        static let owner = "github.owner"
        static let repo = "github.repo"
        static let branch = "github.branch"
        static let workflow = "github.workflow"
        static let sourcesPath = "github.sourcesPath"
        static let readerReadIDs = "reader.readIDs"
        static let readerFavoriteIDs = "reader.favoriteIDs"
        static let readerArchivedIDs = "reader.archivedIDs"
    }

    init() {
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
    }

    func reloadAll() async {
        await loadSources()
        await loadFeedItems()
        await loadEmailSettings()
        await refreshLatestRun()
    }

    func loadFeedItems() async {
        do {
            guard let file = try await client().fetchFileIfExists(path: "data/items.json") else {
                feedItems = []
                return
            }
            feedItems = (try? JSONDecoder().decode([FeedHistoryItem].self, from: file.data)) ?? []
            pruneReaderState()
            updateReaderDockBadge()
        } catch {
            // Feed-Vorschau ist eine Komfortfunktion und soll den Start nicht blockieren.
        }
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
        isDirty = false
        statusMessage = "Quellen gespeichert"
    }

    func saveSourcesFromToolbar() async {
        await performBusy("Speichere Quellen …") {
            try await self.saveSources()
        }
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

    func addSource() {
        editingSource = SourceRecord.new()
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
        var candidate = original
        candidate.applyVisualTrainingRule(rule)

        showVisualTrainer = false
        visualTrainingSource = nil
        testingSourceID = sourceID
        statusMessage = "\(original.name): Einlernregel wird nach komplettem Neuladen validiert …"

        let tester = SourceTester()
        activeTester = tester
        let result = await tester.test(candidate)
        activeTester = nil
        testingSourceID = nil

        guard result.kind.isSuccessLike,
              result.hitCount >= rule.sampleCount
        else {
            testResults[sourceID] = result
            errorMessage =
                "Die neue Einlernregel wurde nicht gespeichert. " +
                "Nach einem vollständigen Neuladen wurden \(result.hitCount) passende Treffer erkannt. " +
                "Die vorherige Regel bleibt unverändert."
            statusMessage = "\(original.name): Einlernregel nach Reload verworfen"
            return
        }

        candidate.markVisualTrainingValidated(
            "Nach Reload bestätigt: \(result.hitCount) Treffer"
        )
        sources[index] = candidate
        testResults[sourceID] = result
        isDirty = true
        statusMessage = "\(original.name): Einlernregel validiert – bitte speichern"
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
            statusMessage = "\(source.name): \(result.hitCount) Treffer"
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
        let repaired = proposal.applying(to: original)

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


    // MARK: - Reader

    var readerUnreadCount: Int {
        feedItems.filter {
            !readerArchivedIDs.contains($0.id) &&
            !readerReadIDs.contains($0.id)
        }.count
    }

    func readerUnreadCount(in group: String) -> Int {
        feedItems.filter {
            !readerArchivedIDs.contains($0.id) &&
            !readerReadIDs.contains($0.id) &&
            ($0.groups ?? []).contains(group)
        }.count
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

    private func persistReaderState() {
        defaults.set(Array(readerReadIDs), forKey: Keys.readerReadIDs)
        defaults.set(Array(readerFavoriteIDs), forKey: Keys.readerFavoriteIDs)
        defaults.set(Array(readerArchivedIDs), forKey: Keys.readerArchivedIDs)
        updateReaderDockBadge()
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

            for _ in 0..<30 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(5))
                await self.refreshLatestRun()

                if self.latestRun?.status == "completed" {
                    self.statusMessage = "Watcher: \(self.latestRun?.displayStatus ?? "beendet")"
                    return
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
