import Foundation
import AppKit

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
    }

    init() {
        owner = UserDefaults.standard.string(forKey: Keys.owner) ?? "callfrank"
        repo = UserDefaults.standard.string(forKey: Keys.repo) ?? "om-news-watcher"
        branch = UserDefaults.standard.string(forKey: Keys.branch) ?? "main"
        workflow = UserDefaults.standard.string(forKey: Keys.workflow) ?? "watch.yml"
        sourcesPath = UserDefaults.standard.string(forKey: Keys.sourcesPath) ?? "sources.json"
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
        await loadEmailSettings()
        await refreshLatestRun()
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
        guard let url = URL(string: source.url) else { return }
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
