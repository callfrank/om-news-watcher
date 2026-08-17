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
                            Image(systemName: result.kind == .technicalError ? "xmark.octagon.fill" : (result.kind == .timeout ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill"))
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
                                        source.visualValidated
                                        ? "Visuell eingelernt und validiert (\(source.visualSampleCount) Beispiele)"
                                        : "Visuell eingelernt – Reload-Test offen/fehlgeschlagen",
                                        systemImage: source.visualValidated
                                        ? "checkmark.seal.fill"
                                        : "exclamationmark.triangle.fill"
                                    )
                                    .foregroundStyle(source.visualValidated ? .green : .orange)
                                    .help(source.visualValidationMessage ?? "Einlernregel wird erst nach einem erfolgreichen Reload-Test als gültig bewertet.")
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
                    .disabled(model.testingSourceID != nil || model.isTestingAll)
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
                                .disabled(model.testingSourceID != nil || model.isTestingAll)
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
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("Quelle")
                }
            }
            .help("Neue Quelle hinzufügen")

            Button {
                Task { await model.testAllSources() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                    Text("Alle testen")
                }
            }
            .help("Alle aktiven Quellen nacheinander testen")
            .disabled(model.isBusy || model.testingSourceID != nil || model.isTestingAll)

            Button {
                Task { await model.saveSourcesFromToolbar() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Speichern")
                }
            }
            .help("Änderungen in sources.json speichern")
            .disabled(!model.isDirty || model.isBusy || model.isTestingAll)

            Button {
                Task { await model.runWorkflow() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("Jetzt prüfen")
                }
            }
            .help("GitHub-Watcher sofort starten")
            .disabled(model.isBusy || model.isTestingAll)
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                model.showProblems = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.problemCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    Text("Probleme")
                }
            }
            .help(model.problemCount > 0 ? "\(model.problemCount) Problemquellen anzeigen" : "Problemquellen anzeigen")

            Button {
                Task { await model.reloadAll() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("Neu laden")
                }
            }
            .help("Quellen und GitHub-Status neu laden")
            .disabled(model.isBusy || model.isTestingAll)

            Button {
                model.openFeed()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Feed")
                }
            }
            .help("RSS-Feed öffnen")

            Button {
                model.showSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                    Text("Einstellungen")
                }
            }
            .help("GitHub- und E-Mail-Einstellungen")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.isBusy || model.testingSourceID != nil {
                ProgressView()
                    .controlSize(.small)
            }

            if let progress = model.allTestProgressText {
                Text(progress)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            } else {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        case .largeArchive: return "archivebox.circle.fill"
        case .zeroHits: return "questionmark.circle.fill"
        case .tooManyHits: return "exclamationmark.triangle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .technicalError: return "xmark.octagon.fill"
        }
    }

    private func testColor(_ kind: SourceTestKind) -> Color {
        switch kind {
        case .success, .largeArchive: return .green
        case .zeroHits, .tooManyHits, .timeout: return .orange
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
                            Text("Strategie: \(rule.strategy)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Regel: \(rule.itemSelector.isEmpty ? rule.candidateSelector : rule.itemSelector)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let urlRegex = rule.urlRegex, !urlRegex.isEmpty {
                                Text("URL-Muster: \(urlRegex)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
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
        interactionMode = .browse
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
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Zweite Schutzschicht für Seiten, die trotz abgefangenem
        // DOM-Klick per JavaScript oder eigenem Router navigieren.
        // Im Markiermodus soll die aktuelle Trainingsseite niemals
        // verlassen werden.
        if interactionMode == .select,
           navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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
        if interactionMode == .select {
            return nil
        }

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
            let candidateSelector = payload["candidateSelector"] as? String ?? "a[href]"
            let urlRegex = (payload["urlRegex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let strategy = payload["strategy"] as? String ?? "Kartenstruktur"
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
                candidateSelector: candidateSelector,
                urlRegex: (urlRegex?.isEmpty == false) ? urlRegex : nil,
                allowExternal: allowExternal,
                sampleCount: sampleCount,
                previewCount: previewCount,
                preview: preview,
                strategy: strategy
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

  const state = { selected: [], mode: 'browse' };
  const clean = value => (value || '').replace(/\s+/g, ' ').trim();
  const clickableSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick]';
  const cardSelector = [
    'article','li','tr','section',
    '[class*="card" i]','[class*="teaser" i]','[class*="news" i]',
    '[class*="press" i]','[class*="event" i]','[class*="story" i]',
    '[class*="result" i]','[class*="item" i]','[class*="report" i]',
    '[class*="post" i]'
  ].join(',');

  const cssEscape = value => window.CSS?.escape ? CSS.escape(value) : String(value).replace(/[^a-zA-Z0-9_-]/g, ch => `\\${ch}`);
  const badClass = token =>
    !token || token.length > 42 ||
    /^(active|selected|current|open|closed|hover|focus|visible|hidden|show|hide|loaded|loading)$/i.test(token) ||
    /(^|[-_])(?:active|selected|current|hover|focus|open|closed|is-|has-)/i.test(token) ||
    /[a-f0-9]{10,}/i.test(token) ||
    (/^[A-Za-z0-9]{6,18}$/.test(token) && /[A-Z]/.test(token) && /[a-z]/.test(token) && /\d/.test(token));

  const stableClasses = el => Array.from(el?.classList || [])
    .filter(token => /^[A-Za-z_-][A-Za-z0-9_-]*$/.test(token))
    .filter(token => !badClass(token)).slice(0, 3);

  const selectorsFor = el => {
    if (!el || el.nodeType !== 1) return [];
    const tag = el.tagName.toLowerCase();
    const out = [];
    for (const attr of ['data-testid','data-component','data-module','data-type','data-cy']) {
      const value = clean(el.getAttribute(attr));
      if (value && value.length <= 60 && !/["'<>]/.test(value)) {
        const escaped = value.replace(/"/g, '\\"');
        out.push(`${tag}[${attr}="${escaped}"]`, `[${attr}="${escaped}"]`);
      }
    }
    for (const cls of stableClasses(el)) out.push(`${tag}.${cssEscape(cls)}`, `.${cssEscape(cls)}`);
    if (['article','li','tr','section','a','h2','h3','h4'].includes(tag)) out.push(tag);
    return [...new Set(out)];
  };

  const generic = value => {
    const lower = clean(value).toLowerCase();
    if (!lower) return true;
    if (/^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz|link öffnet|opens in)/i.test(lower)) return true;
    if (/^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower)) return true;
    return false;
  };

  const cardFor = target => {
    const direct = target?.closest?.(cardSelector);
    if (direct) return direct;
    let node = target;
    for (let depth = 0; node && depth < 6; depth++, node = node.parentElement) {
      const heading = node.querySelector?.('h1,h2,h3,h4,h5,h6,[class*="title" i],[class*="headline" i]');
      const clickable = node.querySelector?.(clickableSelector);
      if (heading && clickable && clean(node.textContent).length < 1800) return node;
    }
    return target?.parentElement || target;
  };

  const hrefFrom = (el, card = null) => {
    const nodes = [el, el?.closest?.('a[href]'), card];
    for (const node of nodes) {
      if (!node?.getAttribute) continue;
      const raw = node.href || node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || node.getAttribute('data-link') || '';
      if (raw) return raw;
      const onclick = node.getAttribute('onclick') || '';
      const m = onclick.match(/(?:location(?:\.href)?\s*=|window\.open\s*\()\s*['"]([^'"]+)['"]/i);
      if (m?.[1]) return m[1];
    }
    const link = card?.querySelector?.('a[href]');
    return link?.href || link?.getAttribute?.('href') || '';
  };

  const findClickable = target => {
    const direct = target?.closest?.(clickableSelector);
    if (direct) return direct;
    const card = cardFor(target);
    return card?.querySelector?.(clickableSelector) || null;
  };

  const bestTitleElement = (target, clickable, card) => {
    const clickedHeading = target?.closest?.('h1,h2,h3,h4,h5,h6');
    if (clickedHeading && !generic(clickedHeading.textContent)) return clickedHeading;
    const own = clean(clickable?.textContent || clickable?.getAttribute?.('aria-label') || '');
    if (own.length >= 5 && own.length <= 320 && !generic(own)) return clickable;
    const selectors = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';
    for (const node of Array.from(card?.querySelectorAll?.(selectors) || [])) {
      const value = clean(node.textContent || node.getAttribute?.('aria-label') || '');
      if (value.length >= 5 && value.length <= 320 && !generic(value)) return node;
    }
    return clickable;
  };

  const bestDateElement = card => card?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]') || null;

  const ancestorCandidates = (clickable, titleEl, card) => {
    const result = [];
    let node = card || clickable;
    let depth = 0;
    while (node && node !== document.body && node !== document.documentElement && depth < 8) {
      if (node.contains(clickable) && (!titleEl || node.contains(titleEl))) {
        for (const selector of selectorsFor(node)) result.push({ selector, depth });
      }
      node = node.parentElement;
      depth += 1;
    }
    return result;
  };

  const regexEscape = value => String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  const commonURLRegex = () => {
    if (state.selected.length < 2) return '';
    let urls;
    try { urls = state.selected.map(s => new URL(s.href, location.href)); } catch { return ''; }
    const hosts = new Set(urls.map(u => u.host.toLowerCase()));
    if (hosts.size !== 1) return '';
    const host = urls[0].host.toLowerCase();
    const lists = urls.map(u => u.pathname.split('/').filter(Boolean));
    const min = Math.min(...lists.map(v => v.length));
    const common = [];
    for (let i = 0; i < Math.max(0, min - 1); i++) {
      const value = lists[0][i];
      if (lists.every(list => list[i] === value)) common.push(value); else break;
    }
    const prefix = common.length ? '/' + common.join('/') + '/' : '/';
    return '^https?://' + regexEscape(host) + regexEscape(prefix);
  };

  const rootFor = (sample, selector) => {
    if (!selector) return null;
    try {
      if (sample.card?.matches?.(selector)) return sample.card;
      if (sample.clickable?.matches?.(selector)) return sample.clickable;
      return sample.clickable?.closest?.(selector) || null;
    } catch { return null; }
  };

  const chooseItemSelector = () => {
    const maps = state.selected.map(sample => new Map(sample.itemCandidates.map(c => [c.selector, c.depth])));
    const candidates = new Set(maps[0]?.keys?.() || []);
    let best = null;
    for (const selector of candidates) {
      if (!maps.every(map => map.has(selector))) continue;
      let roots, count;
      try {
        roots = state.selected.map(sample => rootFor(sample, selector));
        if (roots.some(root => !root)) continue;
        count = document.querySelectorAll(selector).length;
      } catch { continue; }
      if (count < state.selected.length || count > 500) continue;
      const avgDepth = state.selected.reduce((sum, sample, index) => sum + (maps[index].get(selector) || 0), 0) / state.selected.length;
      const genericPenalty = /^(div|span|section|li|a)$/.test(selector) ? 60 : 0;
      const hugePenalty = Math.max(0, count - 150);
      const score = avgDepth * 20 + count + genericPenalty + hugePenalty;
      if (!best || score < best.score) best = { selector, score };
    }
    return best?.selector || '';
  };

  const relativeSelector = (elements, roots, fallback) => {
    if (!elements.length || elements.some(el => !el) || roots.some(root => !root)) return fallback;
    const arrays = elements.map(el => selectorsFor(el));
    for (const selector of arrays[0] || []) {
      if (!arrays.every(arr => arr.includes(selector))) continue;
      let ok = true;
      for (let i = 0; i < roots.length; i++) {
        try { if (!(roots[i].matches?.(selector) ? roots[i] : roots[i].querySelector?.(selector))) { ok = false; break; } }
        catch { ok = false; break; }
      }
      if (ok) return selector;
    }
    return fallback;
  };

  const smartRow = (clickable, root = null) => {
    const card = root || cardFor(clickable);
    const titleEl = bestTitleElement(clickable, clickable, card);
    const title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || '');
    const href = hrefFrom(clickable, card);
    const dateEl = bestDateElement(card);
    const date = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || '');
    return { title, href, date };
  };

  const structuralPreview = rule => {
    if (!rule.itemSelector) return [];
    let roots = [];
    try { roots = Array.from(document.querySelectorAll(rule.itemSelector)); } catch { return []; }
    const rows = [], seen = new Set();
    for (const root of roots) {
      let linkEl = null;
      try { linkEl = root.matches?.(rule.linkSelector) ? root : root.querySelector?.(rule.linkSelector); } catch {}
      linkEl = linkEl || root.querySelector?.(clickableSelector) || (root.matches?.(clickableSelector) ? root : null);
      const row = smartRow(linkEl || root, root);
      if (!row.title || !row.href || seen.has(row.href)) continue;
      seen.add(row.href); rows.push(row);
    }
    return rows;
  };

  const semanticPreview = urlRegex => {
    let regex = null;
    try { if (urlRegex) regex = new RegExp(urlRegex, 'i'); } catch {}
    const rows = [], seen = new Set();
    for (const el of Array.from(document.querySelectorAll(clickableSelector))) {
      const row = smartRow(el);
      let absolute = '';
      try { absolute = new URL(row.href, location.href).href; } catch { continue; }
      if (regex && !regex.test(absolute)) continue;
      if (!row.title || generic(row.title) || seen.has(absolute)) continue;
      seen.add(absolute); rows.push({ ...row, href: absolute });
    }
    return rows;
  };

  window.omTrainerBuildRule = () => {
    if (state.selected.length < 2) return { error: 'Bitte mindestens zwei echte Meldungen anklicken.' };

    const itemSelector = chooseItemSelector();
    const roots = itemSelector ? state.selected.map(sample => rootFor(sample, itemSelector)) : [];
    const titleSelector = roots.length && !roots.some(r => !r)
      ? relativeSelector(state.selected.map(s => s.titleEl), roots, 'h1,h2,h3,h4,h5,h6,[class*="title" i],[class*="headline" i]') : '';
    const linkSelector = roots.length && !roots.some(r => !r)
      ? relativeSelector(state.selected.map(s => s.clickable), roots, clickableSelector) : clickableSelector;
    const dateElements = state.selected.map(s => s.dateEl);
    const dateSelector = roots.length && dateElements.every(Boolean)
      ? relativeSelector(dateElements, roots, 'time,[class*="date" i],[class*="datum" i],[class*="published" i]') : '';

    const urlRegex = commonURLRegex();
    const structural = structuralPreview({ itemSelector, titleSelector, linkSelector, dateSelector });
    const semantic = urlRegex ? semanticPreview(urlRegex) : [];

    let rows = structural;
    let strategy = 'Kartenstruktur';
    if (semantic.length >= state.selected.length && (structural.length < state.selected.length || semantic.length > structural.length)) {
      rows = semantic;
      strategy = 'URL-Muster + Karteninhalt';
    }

    if (rows.length < state.selected.length) {
      return {
        error: `Regel zu eng: ${state.selected.length} Beispiele markiert, aber nur ${rows.length} Treffer reproduzierbar. Bitte andere Karten markieren.`
      };
    }

    let allowExternal = false;
    try { allowExternal = state.selected.some(s => new URL(s.href, location.href).host !== location.host); } catch {}

    return {
      itemSelector,
      titleSelector,
      linkSelector,
      dateSelector,
      candidateSelector: clickableSelector,
      urlRegex,
      allowExternal,
      sampleCount: state.selected.length,
      previewCount: rows.length,
      preview: rows.slice(0, 12),
      strategy
    };
  };

  const post = () => {
    const payload = { count: state.selected.length, samples: state.selected.map(s => ({ title: s.title, href: s.href })) };
    window.webkit?.messageHandlers?.omVisualTrainer?.postMessage(payload);
  };
  window.__omVisualTrainerPost = post;

  window.omTrainerSetMode = mode => {
    state.mode = mode === 'select' ? 'select' : 'browse';
    document.documentElement.setAttribute('data-om-trainer-mode', state.mode);
    return state.mode;
  };

  window.omTrainerReset = () => {
    document.querySelectorAll('[data-om-visual-selected="1"]').forEach(el => el.removeAttribute('data-om-visual-selected'));
    state.selected = []; post();
  };

  const style = document.createElement('style');
  style.id = 'om-visual-trainer-style';
  style.textContent = '[data-om-visual-selected="1"]{outline:4px solid #0a84ff!important;outline-offset:3px!important;border-radius:4px!important;}';
  document.head.appendChild(style);

  const blockEarly = event => {
    if (state.mode !== 'select') return;
    const clickable = findClickable(event.target);
    if (!clickable) return;
    event.stopPropagation();
    event.stopImmediatePropagation?.();
  };
  ['pointerdown','pointerup','mousedown','mouseup','touchstart','touchend','auxclick'].forEach(type => document.addEventListener(type, blockEarly, true));

  document.addEventListener('click', event => {
    if (state.mode !== 'select') return;
    const target = event.target;
    const clickable = findClickable(target);
    if (!clickable) return;
    const card = cardFor(target || clickable);
    const href = hrefFrom(clickable, card);
    if (!href) return;

    event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();

    const highlight = card || clickable;
    const existingIndex = state.selected.findIndex(sample => sample.highlight === highlight || sample.href === href);
    if (existingIndex >= 0) {
      state.selected[existingIndex].highlight?.removeAttribute('data-om-visual-selected');
      state.selected.splice(existingIndex, 1); post(); return;
    }
    if (state.selected.length >= 3) return;

    const titleEl = bestTitleElement(target, clickable, card);
    const dateEl = bestDateElement(card);
    const title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || href);
    highlight.setAttribute('data-om-visual-selected','1');
    state.selected.push({
      clickable, card, titleEl, dateEl, highlight, href, title,
      itemCandidates: ancestorCandidates(clickable, titleEl, card)
    });
    post();
  }, true);

  window.omTrainerSetMode('browse'); post();
  return { installed: true };
})();
"""#
}
