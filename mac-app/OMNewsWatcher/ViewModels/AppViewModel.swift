import Foundation
import AppKit

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

    func applyEditorResult(_ edited: SourceRecord) {
        var copy = edited
        copy.baselineVersion = SourceRecord.makeBaselineVersion()

        if let index = sources.firstIndex(where: { $0.id == edited.id }) {
            sources[index] = copy
        } else {
            sources.append(copy)
            selectedSourceID = copy.id
        }

        testResults.removeValue(forKey: copy.id)
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
        guard testingSourceID == nil else { return }

        testingSourceID = source.id
        statusMessage = "Teste \(source.name) …"
        errorMessage = nil

        let tester = SourceTester()
        activeTester = tester
        let result = await tester.test(source)
        activeTester = nil

        testResults[source.id] = result
        testingSourceID = nil

        switch result.kind {
        case .success:
            statusMessage = "\(source.name): \(result.hitCount) Treffer"
        case .zeroHits:
            statusMessage = "\(source.name): keine Treffer"
        case .tooManyHits:
            statusMessage = "\(source.name): zu viele Treffer"
        case .technicalError:
            statusMessage = "\(source.name): technischer Fehler"
        }
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
