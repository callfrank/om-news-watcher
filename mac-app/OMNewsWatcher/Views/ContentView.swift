import SwiftUI
import AppKit
import WebKit

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showEditor) {
            if let editing = model.editingSource {
                let exists = model.sources.contains(where: { $0.id == editing.id })
                SourceEditorView(
                    source: editing,
                    isExisting: exists,
                    onSave: { result in
                        model.applyEditorResult(result)
                    },
                    onSaveAndTrain: { result in
                        let id = result.id
                        model.applyEditorResult(result)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            model.startVisualTraining(sourceID: id)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $model.showProblems) {
            ProblemSourcesView(model: model)
        }
        .sheet(isPresented: $model.showVisualTrainer) {
            if let source = model.visualTrainingSource {
                VisualTrainingView(source: source) { rule in
                    model.applyVisualTrainingRule(
                        rule,
                        to: source.id
                    )
                }
            }
        }
        .alert("Fehler", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unbekannter Fehler")
        }
        .confirmationDialog(
            "Quelle wirklich löschen?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quelle löschen", role: .destructive) {
                model.deleteSelectedSource()
            }
        } message: {
            Text("Die Quelle wird beim nächsten Speichern aus sources.json entfernt.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 1) {
                    Text("OM News Watcher")
                        .font(.headline)
                    Text("Quellen & Website-Monitoring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: $model.selectedSourceID) {
                ForEach(filteredSources) { source in
                    HStack(spacing: 10) {
                        Image(systemName: source.enabled ? "checkmark.circle.fill" : "pause.circle.fill")
                            .foregroundStyle(source.enabled ? .green : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .lineLimit(1)
                            Text(host(for: source.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if let result = model.testResults[source.id], result.isProblem {
                            Image(systemName: result.kind == .technicalError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.kind == .technicalError ? .red : .orange)
                                .help(result.message)
                        }
                    }
                    .tag(source.id)
                    .contextMenu {
                        Button("Quelle testen") {
                            Task { await model.testSource(source) }
                        }

                        Button(source.enabled ? "Pausieren" : "Aktivieren") {
                            model.setEnabled(!source.enabled, for: source.id)
                        }

                        Button("Bearbeiten") {
                            model.selectedSourceID = source.id
                            model.editSelectedSource()
                        }

                        Divider()

                        Button("Löschen", role: .destructive) {
                            model.selectedSourceID = source.id
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Quellen suchen")

            HStack {
                Text("\(model.activeCount) aktiv")
                if model.pausedCount > 0 {
                    Text("• \(model.pausedCount) pausiert")
                }
                Spacer()
                if model.isDirty {
                    Label("Nicht gespeichert", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .navigationTitle("OM News Watcher")
        .frame(minWidth: 310)
    }

    @ViewBuilder
    private var detail: some View {
        if let source = model.selectedSource {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.name)
                                .font(.largeTitle.bold())

                            Text(source.url)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Toggle("Aktiv", isOn: Binding(
                            get: { source.enabled },
                            set: { model.setEnabled($0, for: source.id) }
                        ))
                        .toggleStyle(.switch)
                    }

                    GroupBox("Quelle") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Status") {
                                Label(
                                    source.enabled ? "Wird überwacht" : "Pausiert",
                                    systemImage: source.enabled ? "checkmark.circle" : "pause.circle"
                                )
                            }

                            LabeledContent(
                                "Feed-Kennzeichnung",
                                value: source.feedLabel
                            )

                            LabeledContent(
                                "Feed-Titel",
                                value: "\(source.feedLabel) · <Originaltitel>"
                            )

                            LabeledContent("JavaScript-Wartezeit", value: "\(source.waitMs) ms")

                            if source.fetchMode == "html" {
                                LabeledContent("Abruf", value: "Direktes HTML")
                            }

                            if source.visualLearned {
                                LabeledContent("Erkennung") {
                                    Label(
                                        "Visuell eingelernt (\(source.visualSampleCount) Beispiele)",
                                        systemImage: "cursorarrow.click.2"
                                    )
                                    .foregroundStyle(.green)
                                }
                            }

                            if let baseline = source.baselineVersion {
                                LabeledContent("Erkennungsstand", value: baseline)
                            }
                        }
                        .padding(6)
                    }

                    sourceTestSection(source)

                    HStack {
                        Button("Website öffnen") {
                            model.openSource(source)
                        }

                        Button("Bearbeiten") {
                            model.editSelectedSource()
                        }

                        Button {
                            model.startVisualTrainingSelected()
                        } label: {
                            Label(
                                source.visualLearned
                                ? "Neu einlernen"
                                : "Visuell einlernen",
                                systemImage: "cursorarrow.click.2"
                            )
                        }

                        if source.visualLearned {
                            Button("Zur Automatik zurücksetzen") {
                                model.restoreAutomaticDetection(for: source.id)
                            }
                        }

                        Spacer()

                        Button("Löschen", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
                .padding(28)
            }
        } else {
            ContentUnavailableView(
                "Keine Quelle ausgewählt",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("Wähle links eine Quelle aus oder füge eine neue URL hinzu.")
            )
        }
    }

    @ViewBuilder
    private func sourceTestSection(_ source: SourceRecord) -> some View {
        GroupBox("Quelle testen") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Schnelltest mit der aktuellen Erkennungsregel")
                            .font(.headline)
                        Text("Die App lädt die Seite lokal und zeigt Beispieltreffer, 0 Treffer, zu viele Treffer oder technische Fehler.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await model.testSource(source) }
                    } label: {
                        if model.testingSourceID == source.id {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Teste …")
                            }
                        } else {
                            Label("Quelle testen", systemImage: "stethoscope")
                        }
                    }
                    .disabled(model.testingSourceID != nil)
                }

                if let result = model.testResults[source.id] {
                    Divider()

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: testIcon(result.kind))
                            .font(.title2)
                            .foregroundStyle(testColor(result.kind))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.kind.title)
                                .font(.headline)
                            Text(result.message)
                                .foregroundStyle(.secondary)
                            Text("Getestet: \(result.testedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if !result.examples.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Beispieltreffer")
                                .font(.subheadline.bold())

                            ForEach(result.examples) { hit in
                                Button {
                                    model.openHit(hit)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(hit.title)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            if let publicationDate = hit.publicationDate {
                                                Text("Veröffentlicht: \(publicationDate)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            if let url = hit.url {
                                                Text(url)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }


                    if let repair = result.repairProposal {
                        Divider()
                            .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "wand.and.stars")
                                    .font(.title2)
                                    .foregroundStyle(.blue)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Automatische Reparatur")
                                        .font(.headline)
                                    Text(repair.title)
                                        .font(.subheadline.bold())
                                    Text(repair.explanation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    Task {
                                        await model.applyRepairProposal(
                                            repair,
                                            to: source.id
                                        )
                                    }
                                } label: {
                                    Label(
                                        "Quelle automatisch reparieren",
                                        systemImage: "wand.and.stars"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.testingSourceID != nil)
                            }

                            HStack(spacing: 16) {
                                Label(
                                    "\(repair.previewCount) Treffer in der Vorschau",
                                    systemImage: "checkmark.circle"
                                )

                                if let includeRegex = repair.includeRegex {
                                    Label(
                                        "URL-Filter",
                                        systemImage: "line.3.horizontal.decrease.circle"
                                    )
                                    .help(includeRegex)
                                }

                                if repair.fetchMode == "html" {
                                    Label(
                                        "Direktes HTML",
                                        systemImage: "doc.text.magnifyingglass"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if !repair.examples.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Vorschau nach Reparatur")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)

                                    ForEach(repair.examples.prefix(5)) { hit in
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.green)
                                            Text(hit.title)
                                                .lineLimit(2)
                                        }
                                        .font(.caption)
                                    }
                                }
                                .padding(.leading, 4)
                            }

                            Text(
                                "Die Regel wird erst nach „Speichern“ in sources.json geschrieben. " +
                                "Der GitHub-Watcher verwendet danach dieselben URL-Filter."
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(
                            .blue.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                }
            }
            .padding(6)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.addSource()
            } label: {
                Label("Quelle hinzufügen", systemImage: "plus")
            }

            Button {
                Task { await model.saveSourcesFromToolbar() }
            } label: {
                Label("Speichern", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.isDirty || model.isBusy)

            Button {
                Task { await model.runWorkflow() }
            } label: {
                Label("Jetzt prüfen", systemImage: "play.fill")
            }
            .disabled(model.isBusy)
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                model.showProblems = true
            } label: {
                Label(
                    model.problemCount > 0 ? "Problemquellen (\(model.problemCount))" : "Problemquellen",
                    systemImage: model.problemCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal"
                )
            }
            .help("Beim Schnelltest auffällige sowie pausierte Quellen anzeigen")

            Button {
                Task { await model.reloadAll() }
            } label: {
                Label("Neu laden", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)

            Button {
                model.openFeed()
            } label: {
                Label("RSS-Feed", systemImage: "dot.radiowaves.left.and.right")
            }

            Button {
                model.showSettings = true
            } label: {
                Label("Einstellungen", systemImage: "gearshape")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isBusy || model.testingSourceID != nil {
                ProgressView()
                    .controlSize(.small)
            }

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if model.problemCount > 0 {
                Button {
                    model.showProblems = true
                } label: {
                    Label("\(model.problemCount) Problemquellen", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let run = model.latestRun {
                Button {
                    model.openLatestRun()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(runColor(run))
                            .frame(width: 8, height: 8)
                        Text("Letzter Lauf: \(run.displayStatus)")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var filteredSources: [SourceRecord] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.sources
        }

        return model.sources.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func host(for urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private func runColor(_ run: WorkflowRun) -> Color {
        if run.status != "completed" { return .orange }
        return run.conclusion == "success" ? .green : .red
    }

    private func testIcon(_ kind: SourceTestKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .zeroHits: return "questionmark.circle.fill"
        case .tooManyHits: return "exclamationmark.triangle.fill"
        case .technicalError: return "xmark.octagon.fill"
        }
    }

    private func testColor(_ kind: SourceTestKind) -> Color {
        switch kind {
        case .success: return .green
        case .zeroHits, .tooManyHits: return .orange
        case .technicalError: return .red
        }
    }
}


// MARK: - Visuelles Einlernen

struct VisualTrainingWebView: NSViewRepresentable {
    @ObservedObject var session: VisualTrainingSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct VisualTrainingView: View {
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord
    let onApply: (VisualTrainingRule) -> Void

    @StateObject private var session: VisualTrainingSession

    init(
        source: SourceRecord,
        onApply: @escaping (VisualTrainingRule) -> Void
    ) {
        self.source = source
        self.onApply = onApply
        _session = StateObject(
            wrappedValue: VisualTrainingSession(source: source)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quelle visuell einlernen")
                        .font(.title2.bold())
                    Text(source.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(
                    "\(session.samples.count) ausgewählt",
                    systemImage: "cursorarrow.click.2"
                )
                .foregroundColor(
                    session.samples.count >= 2 ? .green : .gray
                )

                Button("Neu laden") {
                    session.reload()
                }

                Button("Fertig") {
                    dismiss()
                }
            }
            .padding(14)

            Divider()

            VisualTrainingWebView(session: session)
                .frame(minHeight: 500)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker(
                            "Modus",
                            selection: Binding(
                                get: { session.interactionMode },
                                set: { session.setInteractionMode($0) }
                            )
                        ) {
                            ForEach(VisualTrainingInteractionMode.allCases) { mode in
                                Text(mode.title)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 520)

                        if session.interactionMode == .browse {
                            Text("1. Website bedienen")
                                .font(.headline)
                            Text("Cloudflare bestätigen, Cookiebanner akzeptieren, navigieren und scrollen. In diesem Modus verhält sich die Seite wie ein normaler Browser.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("2. Klicke 2–3 echte Meldungen an")
                                .font(.headline)
                            Text("Jetzt fängt die App Klicks auf Meldungen ab und markiert deine Auswahl blau. Ein erneuter Klick entfernt die Auswahl.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("Auswahl löschen") {
                        session.resetSelection()
                    }
                    .disabled(session.samples.isEmpty)
                }

                if !session.samples.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(session.samples) { sample in
                                Text(sample.title)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                if let rule = session.rule {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Vorschau: \(rule.previewCount) passende Links")
                                .font(.subheadline.bold())
                            Text("Regel: \(rule.itemSelector)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        if rule.previewCount > 300 {
                            Label("Regel noch zu breit", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }

                        Button("Regel übernehmen") {
                            onApply(rule)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!rule.isUsable)
                    }

                    if !rule.preview.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(rule.preview.prefix(6)) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.caption.bold())
                                            .lineLimit(2)
                                        if let date = item.date, !date.isEmpty {
                                            Text(date)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 220, alignment: .leading)
                                    .padding(8)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                } else {
                    Text(session.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 1100, minHeight: 760)
        .onAppear {
            session.load()
        }
        .onDisappear {
            session.teardown()
        }
    }
}

enum VisualTrainingInteractionMode: String, CaseIterable, Identifiable {
    case browse
    case select

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse:
            return "Website bedienen"
        case .select:
            return "Links markieren"
        }
    }
}

final class VisualTrainingSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var samples: [VisualTrainingSample] = []
    @Published var rule: VisualTrainingRule?
    @Published var statusMessage = "Website wird geladen …"
    @Published var interactionMode: VisualTrainingInteractionMode = .browse

    let webView: WKWebView
    private let source: SourceRecord
    private var didLoad = false

    init(source: SourceRecord) {
        self.source = source

        let configuration = WKWebViewConfiguration()
        // Persistente Cookies/Website-Daten sind absichtlich aktiv:
        // Cloudflare- und Cookie-Bestätigungen sollen beim nächsten
        // Öffnen derselben Quelle erhalten bleiben.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let controller = WKUserContentController()
        configuration.userContentController = controller

        self.webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        super.init()

        controller.add(self, name: "omVisualTrainer")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "omVisualTrainer"
        )
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true

        guard let url = URL(string: source.url) else {
            statusMessage = "Die URL ist ungültig."
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        webView.load(request)
    }

    func reload() {
        samples = []
        rule = nil
        statusMessage = "Website wird neu geladen …"
        webView.reload()
    }

    func setInteractionMode(
        _ mode: VisualTrainingInteractionMode
    ) {
        interactionMode = mode

        switch mode {
        case .browse:
            statusMessage =
                "Website bedienen: Cloudflare/Cookies bestätigen und zur gewünschten Liste navigieren."
        case .select:
            statusMessage =
                "Links markieren: Klicke jetzt 2–3 echte Meldungen an."
        }

        let jsMode =
            mode == .select
            ? "select"
            : "browse"

        webView.evaluateJavaScript(
            "window.omTrainerSetMode && window.omTrainerSetMode('\(jsMode)');",
            completionHandler: nil
        )
    }

    func resetSelection() {
        samples = []
        rule = nil
        statusMessage = "Klicke 2–3 echte Meldungen an."

        webView.evaluateJavaScript(
            "window.omTrainerReset && window.omTrainerReset();",
            completionHandler: nil
        )
    }

    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "omVisualTrainer"
        )
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusMessage = "Klicke jetzt 2–3 echte Meldungen auf der Seite an."

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await webView.evaluateJavaScript(Self.trainingScript)

                let jsMode =
                    self.interactionMode == .select
                    ? "select"
                    : "browse"

                _ = try await webView.evaluateJavaScript(
                    "window.omTrainerSetMode && window.omTrainerSetMode('\(jsMode)');"
                )

                self.statusMessage =
                    self.interactionMode == .select
                    ? "Links markieren: Klicke jetzt 2–3 echte Meldungen an."
                    : "Website bedienen: Cloudflare/Cookies bestätigen und zur gewünschten Liste navigieren."
            } catch {
                self.statusMessage = "Einlernmodus konnte nicht gestartet werden: \(error.localizedDescription)"
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        statusMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        statusMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target="_blank" und JavaScript-Popups im Bedienmodus
        // im selben Fenster öffnen. So kann man auch Cookie-/Login-
        // und Cloudflare-Flows innerhalb der Einlernansicht abschließen.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }

        return nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == "omVisualTrainer",
            let body = message.body as? [String: Any]
        else {
            return
        }

        let rawSamples = body["samples"] as? [[String: Any]] ?? []
        samples = rawSamples.compactMap { row in
            let title = (row["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (row["href"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty, !url.isEmpty else { return nil }
            return VisualTrainingSample(title: title, url: url)
        }

        rule = nil

        if samples.count >= 2 {
            Task { @MainActor [weak self] in
                await self?.buildRulePreview()
            }
        } else {
            statusMessage = "Noch \(2 - samples.count) weitere Meldung auswählen."
        }
    }

    @MainActor
    private func buildRulePreview() async {
        do {
            let value = try await webView.evaluateJavaScript(
                "window.omTrainerBuildRule && window.omTrainerBuildRule();"
            )

            guard let payload = value as? [String: Any] else {
                statusMessage = "Noch keine gemeinsame Struktur erkannt."
                return
            }

            if let error = payload["error"] as? String, !error.isEmpty {
                statusMessage = error
                return
            }

            let itemSelector = payload["itemSelector"] as? String ?? ""
            let titleSelector = payload["titleSelector"] as? String ?? ""
            let linkSelector = payload["linkSelector"] as? String ?? ""
            let dateSelector = (payload["dateSelector"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let allowExternal = payload["allowExternal"] as? Bool ?? false
            let sampleCount = payload["sampleCount"] as? Int ?? samples.count
            let previewCount = payload["previewCount"] as? Int ?? 0

            let rawPreview = payload["preview"] as? [[String: Any]] ?? []
            let preview = rawPreview.compactMap { row -> VisualTrainingPreview? in
                let title = row["title"] as? String ?? ""
                let url = row["href"] as? String ?? ""
                let date = (row["date"] as? String)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                guard !title.isEmpty, !url.isEmpty else { return nil }
                return VisualTrainingPreview(
                    title: title,
                    url: url,
                    date: (date?.isEmpty == false) ? date : nil
                )
            }

            let newRule = VisualTrainingRule(
                itemSelector: itemSelector,
                titleSelector: titleSelector,
                linkSelector: linkSelector,
                dateSelector: (dateSelector?.isEmpty == false) ? dateSelector : nil,
                allowExternal: allowExternal,
                sampleCount: sampleCount,
                previewCount: previewCount,
                preview: preview
            )

            rule = newRule
            statusMessage = newRule.isUsable
                ? "Regel erkannt. Vorschau prüfen und übernehmen."
                : "Regel erkannt, aber die Vorschau ist noch nicht plausibel. Auswahl ändern oder eine andere Meldung markieren."
        } catch {
            statusMessage = "Vorschau konnte nicht erzeugt werden: \(error.localizedDescription)"
        }
    }

    private static let trainingScript = #"""
(() => {
  if (window.__omVisualTrainerInstalled) {
    window.__omVisualTrainerPost?.();
    return { installed: true };
  }

  window.__omVisualTrainerInstalled = true;

  const state = {
    selected: [],
    mode: 'browse'
  };

  const clean = value =>
    (value || '').replace(/\s+/g, ' ').trim();

  const cssEscape = value => {
    if (window.CSS && CSS.escape) return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, ch => `\\${ch}`);
  };

  const badClass = token =>
    !token ||
    token.length > 42 ||
    /^(active|selected|current|open|closed|hover|focus|visible|hidden|show|hide|loaded|loading)$/i.test(token) ||
    /(^|[-_])(?:active|selected|current|hover|focus|open|closed|is-|has-)/i.test(token) ||
    /[a-f0-9]{10,}/i.test(token);

  const stableClasses = el =>
    Array.from(el?.classList || [])
      .filter(token => /^[A-Za-z_-][A-Za-z0-9_-]*$/.test(token))
      .filter(token => !badClass(token))
      .slice(0, 3);

  const selectorsFor = el => {
    if (!el || el.nodeType !== 1) return [];

    const tag = el.tagName.toLowerCase();
    const out = [];

    for (const attr of ['data-testid', 'data-component', 'data-module', 'data-type', 'data-cy']) {
      const value = clean(el.getAttribute(attr));
      if (value && value.length <= 60 && !/["'<>]/.test(value)) {
        out.push(`${tag}[${attr}="${value.replace(/"/g, '\\"')}"]`);
        out.push(`[${attr}="${value.replace(/"/g, '\\"')}"]`);
      }
    }

    for (const cls of stableClasses(el)) {
      out.push(`${tag}.${cssEscape(cls)}`);
      out.push(`.${cssEscape(cls)}`);
    }

    if (['article', 'li', 'tr', 'section', 'a', 'h2', 'h3', 'h4'].includes(tag)) {
      out.push(tag);
    }

    return [...new Set(out)];
  };

  const cardSelector = [
    'article',
    'li',
    'tr',
    'section',
    '[class*="card" i]',
    '[class*="teaser" i]',
    '[class*="news" i]',
    '[class*="press" i]',
    '[class*="event" i]',
    '[class*="story" i]',
    '[class*="result" i]',
    '[class*="item" i]',
    '[class*="report" i]',
    '[class*="post" i]'
  ].join(',');

  const genericText = value => {
    const lower = clean(value).toLowerCase();
    return !lower || [
      'mehr erfahren', 'read more', 'learn more', 'weiterlesen',
      'download', 'download for free', 'details', 'more',
      'link öffnet in neuem tab', 'opens in a new tab'
    ].includes(lower);
  };

  const findAnchor = target => {
    const direct = target?.closest?.('a[href]');
    if (direct) return direct;

    const card = target?.closest?.(cardSelector);
    return card?.querySelector?.('a[href]') || null;
  };

  const bestTitleElement = (target, anchor) => {
    const clickedHeading = target?.closest?.('h1,h2,h3,h4,h5,h6');
    if (clickedHeading && !genericText(clickedHeading.textContent)) {
      return clickedHeading;
    }

    if (!genericText(anchor?.textContent) && clean(anchor?.textContent).length >= 5) {
      return anchor;
    }

    const card = target?.closest?.(cardSelector) || anchor?.closest?.(cardSelector);
    const heading = card?.querySelector?.(
      'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i]'
    );

    if (heading && !genericText(heading.textContent)) {
      return heading;
    }

    return anchor;
  };

  const bestDateElement = card => {
    if (!card?.querySelector) return null;
    return card.querySelector(
      'time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]'
    );
  };

  const ancestorCandidates = (anchor, titleEl) => {
    const result = [];
    let node = titleEl?.closest?.(cardSelector) || anchor?.closest?.(cardSelector) || anchor;
    let depth = 0;

    while (node && node !== document.body && node !== document.documentElement && depth < 8) {
      if (node.contains(anchor) && (!titleEl || node.contains(titleEl))) {
        for (const selector of selectorsFor(node)) {
          result.push({ selector, depth });
        }
      }
      node = node.parentElement;
      depth += 1;
    }

    for (const selector of selectorsFor(anchor)) {
      result.push({ selector, depth: 0 });
    }

    return result;
  };

  const commonPathSelector = () => {
    if (state.selected.length < 2) return null;

    let urls;
    try {
      urls = state.selected.map(s => new URL(s.href, location.href));
    } catch {
      return null;
    }

    const origins = new Set(urls.map(u => u.origin));
    if (origins.size !== 1) return null;

    const lists = urls.map(u => u.pathname.split('/').filter(Boolean));
    const common = [];
    const min = Math.min(...lists.map(v => v.length));

    for (let i = 0; i < Math.max(0, min - 1); i++) {
      const value = lists[0][i];
      if (lists.every(list => list[i] === value)) common.push(value);
      else break;
    }

    if (!common.length) return null;
    const prefix = '/' + common.join('/') + '/';
    return `a[href*="${prefix.replace(/"/g, '\\"')}"]`;
  };

  const rootFor = (sample, selector) => {
    try {
      if (sample.anchor.matches(selector)) return sample.anchor;
      const root = sample.anchor.closest(selector);
      if (root && (!sample.titleEl || root.contains(sample.titleEl))) return root;
    } catch {}
    return null;
  };

  const chooseItemSelector = () => {
    const maps = state.selected.map(sample =>
      new Map(sample.itemCandidates.map(c => [c.selector, c.depth]))
    );

    const candidates = new Set(maps[0]?.keys?.() || []);
    const urlSelector = commonPathSelector();
    if (urlSelector) candidates.add(urlSelector);

    let best = null;

    for (const selector of candidates) {
      if (!maps.every(map => map.has(selector)) && selector !== urlSelector) continue;

      let roots;
      let count;
      try {
        roots = state.selected.map(sample => rootFor(sample, selector));
        if (roots.some(root => !root)) continue;
        count = document.querySelectorAll(selector).length;
      } catch {
        continue;
      }

      if (count < state.selected.length || count > 500) continue;

      const depths = state.selected.map((sample, index) =>
        maps[index].get(selector) ?? 0
      );
      const avgDepth = depths.reduce((a, b) => a + b, 0) / depths.length;
      const genericPenalty = /^(div|span|section|li|a)$/.test(selector) ? 80 : 0;
      const hugePenalty = Math.max(0, count - 120) * 2;
      const score = avgDepth * 25 + count + genericPenalty + hugePenalty;

      if (!best || score < best.score) {
        best = { selector, score };
      }
    }

    return best?.selector || urlSelector || 'a[href]';
  };

  const commonRelativeSelector = (elements, roots, fallback) => {
    if (!elements.length || elements.some(el => !el)) return fallback;

    const arrays = elements.map(el => selectorsFor(el));
    const candidates = arrays[0] || [];

    for (const selector of candidates) {
      if (!arrays.every(arr => arr.includes(selector))) continue;

      let valid = true;
      for (let i = 0; i < roots.length; i++) {
        try {
          const picked = roots[i].matches(selector)
            ? roots[i]
            : roots[i].querySelector(selector);
          if (!picked) { valid = false; break; }
        } catch {
          valid = false;
          break;
        }
      }
      if (valid) return selector;
    }

    return fallback;
  };

  const previewRule = rule => {
    let roots = [];
    try {
      roots = Array.from(document.querySelectorAll(rule.itemSelector));
    } catch {
      return [];
    }

    const pick = (root, selector) => {
      if (!root || !selector) return null;
      try {
        return root.matches(selector) ? root : root.querySelector(selector);
      } catch {
        return null;
      }
    };

    const rows = [];
    const seen = new Set();

    for (const root of roots) {
      const titleEl = pick(root, rule.titleSelector);
      const linkEl = pick(root, rule.linkSelector) || (root.matches?.('a[href]') ? root : root.querySelector?.('a[href]'));
      const dateEl = rule.dateSelector ? pick(root, rule.dateSelector) : null;

      const title = clean(
        titleEl?.textContent ||
        titleEl?.getAttribute?.('aria-label') ||
        titleEl?.title ||
        ''
      );
      const href = linkEl?.href || linkEl?.getAttribute?.('href') || '';
      const date = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || '');

      if (!title || !href || seen.has(href)) continue;
      seen.add(href);
      rows.push({ title, href, date });
    }

    return rows;
  };

  window.omTrainerBuildRule = () => {
    if (state.selected.length < 2) {
      return { error: 'Bitte mindestens zwei echte Meldungen anklicken.' };
    }

    const itemSelector = chooseItemSelector();
    const roots = state.selected.map(sample => rootFor(sample, itemSelector));

    if (roots.some(root => !root)) {
      return { error: 'Die angeklickten Meldungen haben noch keine gemeinsame Struktur. Bitte eine weitere Meldung anklicken.' };
    }

    const titleSelector = commonRelativeSelector(
      state.selected.map(s => s.titleEl),
      roots,
      'h1,h2,h3,h4,h5,h6,a[href]'
    );

    const linkSelector = commonRelativeSelector(
      state.selected.map(s => s.anchor),
      roots,
      'a[href]'
    );

    const dateElements = state.selected.map(s => s.dateEl);
    const dateSelector = dateElements.every(Boolean)
      ? commonRelativeSelector(
          dateElements,
          roots,
          'time,[class*="date" i],[class*="datum" i],[class*="published" i]'
        )
      : '';

    const rule = { itemSelector, titleSelector, linkSelector, dateSelector };
    const rows = previewRule(rule);

    let allowExternal = false;
    try {
      allowExternal = state.selected.some(s => new URL(s.href, location.href).host !== location.host);
    } catch {}

    return {
      ...rule,
      allowExternal,
      sampleCount: state.selected.length,
      previewCount: rows.length,
      preview: rows.slice(0, 12)
    };
  };

  const post = () => {
    const payload = {
      count: state.selected.length,
      samples: state.selected.map(s => ({ title: s.title, href: s.href }))
    };
    window.webkit?.messageHandlers?.omVisualTrainer?.postMessage(payload);
  };

  window.__omVisualTrainerPost = post;

  window.omTrainerSetMode = mode => {
    state.mode =
      mode === 'select'
        ? 'select'
        : 'browse';

    document.documentElement.setAttribute(
      'data-om-trainer-mode',
      state.mode
    );

    return state.mode;
  };

  window.omTrainerReset = () => {
    document.querySelectorAll('[data-om-visual-selected="1"]').forEach(el => {
      el.removeAttribute('data-om-visual-selected');
    });
    state.selected = [];
    post();
  };

  const style = document.createElement('style');
  style.id = 'om-visual-trainer-style';
  style.textContent = `
    [data-om-visual-selected="1"] {
      outline: 4px solid #0a84ff !important;
      outline-offset: 3px !important;
      border-radius: 4px !important;
    }
  `;
  document.head.appendChild(style);

  document.addEventListener('click', event => {
    // Im Bedienmodus keinerlei Klicks abfangen:
    // Cookiebanner, Cloudflare, Navigation und Formulare funktionieren normal.
    if (state.mode !== 'select') return;

    const target = event.target;
    const anchor = findAnchor(target);
    if (!anchor) return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();

    const href = anchor.href || anchor.getAttribute('href') || '';
    if (!href) return;

    const card =
      target?.closest?.(cardSelector) ||
      anchor?.closest?.(cardSelector) ||
      anchor;

    const highlight = card || anchor;

    // Eine Karte kann mehrere interne Links enthalten.
    // Für das Training zählt die Karte trotzdem nur einmal.
    const existingIndex = state.selected.findIndex(
      sample =>
        sample.highlight === highlight ||
        sample.href === href
    );

    if (existingIndex >= 0) {
      state.selected[existingIndex].highlight?.removeAttribute(
        'data-om-visual-selected'
      );
      state.selected.splice(existingIndex, 1);
      post();
      return;
    }

    // Maximal drei echte Karten reichen für die Regelerkennung.
    if (state.selected.length >= 3) return;

    const titleEl = bestTitleElement(target, anchor);
    const dateEl = bestDateElement(card);
    const title = clean(
      titleEl?.textContent ||
      titleEl?.getAttribute?.('aria-label') ||
      anchor.textContent ||
      anchor.getAttribute('aria-label') ||
      href
    );

    highlight.setAttribute('data-om-visual-selected', '1');

    state.selected.push({
      anchor,
      titleEl,
      dateEl,
      highlight,
      href,
      title,
      itemCandidates: ancestorCandidates(anchor, titleEl)
    });

    post();
  }, true);

  window.omTrainerSetMode('browse');
  post();
  return { installed: true };
})();
"""#
}
