import SwiftUI
import AppKit

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
                SourceEditorView(source: editing, isExisting: exists) { result in
                    model.applyEditorResult(result)
                }
            }
        }
        .sheet(isPresented: $model.showProblems) {
            ProblemSourcesView(model: model)
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

                            LabeledContent("JavaScript-Wartezeit", value: "\(source.waitMs) ms")

                            if source.fetchMode == "html" {
                                LabeledContent("Abruf", value: "Direktes HTML")
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
