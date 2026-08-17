import SwiftUI
import AppKit
import WebKit

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var selectedFolder: String? = nil
    @State private var listFilter: SourceListFilter = .all

    var body: some View {
        NavigationSplitView {
            folderSidebar
        } content: {
            sourceColumn
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
        .sheet(isPresented: $model.showReader) {
            ReaderView(model: model)
        }
        .sheet(isPresented: $model.showFeedPreview) {
            FeedPreviewView(model: model)
        }
        .sheet(isPresented: $model.showHealthDashboard) {
            HealthDashboardView(model: model)
        }
        .sheet(isPresented: $model.showGroupManager) {
            GroupManagerView(model: model)
        }
        .sheet(isPresented: $model.showBulkManager) {
            BulkManagerView(model: model)
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

    private var folderSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 1) {
                    Text("OM News Watcher")
                        .font(.headline)
                    Text("Ordner & Themen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            List {
                Section("Ordner") {
                    Button {
                        selectedFolder = nil
                    } label: {
                        HStack {
                            Label("Alle Quellen", systemImage: selectedFolder == nil ? "tray.full.fill" : "tray.full")
                            Spacer()
                            Text("\(model.sources.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(model.allGroups, id: \.self) { group in
                        Button {
                            selectedFolder = group
                        } label: {
                            HStack {
                                Label(group, systemImage: selectedFolder == group ? "folder.fill" : "folder")
                                Spacer()
                                Text("\(model.groupCount(group))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Gruppenfeed öffnen") { model.openGroupFeed(group) }
                        }
                    }

                    if model.ungroupedCount > 0 {
                        Button {
                            selectedFolder = "__UNGROUPED__"
                        } label: {
                            HStack {
                                Label("Ohne Ordner", systemImage: "folder.badge.questionmark")
                                Spacer()
                                Text("\(model.ungroupedCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text(selectedFolderTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.showGroupManager = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .help("Ordner verwalten")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }

            HStack {
                Text("\(model.allGroups.count) Ordner")
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
        .navigationTitle("Ordner")
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 290)
    }

    private var sourceColumn: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedFolderTitle)
                        .font(.headline)
                    Text("\(filteredSources.count) Quellen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            List(selection: $model.selectedSourceID) {
                ForEach(filteredSources) { source in
                    HStack(spacing: 9) {
                        Image(systemName: source.enabled ? "checkmark.circle.fill" : "pause.circle.fill")
                            .foregroundStyle(source.enabled ? .green : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.name)
                                    .lineLimit(1)
                                Text(source.priorityStars)
                                    .font(.caption2)
                                    .foregroundStyle(source.priority == 3 ? .orange : .secondary)
                            }

                            HStack(spacing: 5) {
                                Text(host(for: source.url))
                                    .lineLimit(1)
                                if selectedFolder == nil, let group = source.primaryGroup {
                                    Text("· \(group)")
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        Button("Quelle testen") { Task { await model.testSource(source) } }
                        Button(source.enabled ? "Pausieren" : "Aktivieren") { model.setEnabled(!source.enabled, for: source.id) }
                        Button("Bearbeiten") { model.selectedSourceID = source.id; model.editSelectedSource() }
                        Divider()
                        Button("Löschen", role: .destructive) { model.selectedSourceID = source.id; showDeleteConfirmation = true }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Quellen suchen")
            .safeAreaInset(edge: .top) {
                HStack {
                    Picker("Filter", selection: $listFilter) {
                        ForEach(SourceListFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)

                    Spacer()

                    Button { model.showBulkManager = true } label: {
                        Image(systemName: "checkmark.circle.badge.plus")
                    }
                    .help("Quellen verwalten")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }

            HStack {
                Text("\(filteredSources.filter(\.enabled).count) aktiv")
                let pausedVisible = filteredSources.filter { !$0.enabled }.count
                if pausedVisible > 0 {
                    Text("• \(pausedVisible) pausiert")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .navigationTitle(selectedFolderTitle)
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
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

                            LabeledContent("Ordner", value: source.groups.isEmpty ? "—" : source.groups.joined(separator: ", "))
                            LabeledContent("Schlagwörter", value: source.tags.isEmpty ? "—" : source.tags.joined(separator: ", "))
                            LabeledContent("Relevanz", value: source.priorityStars)
                            if let latest = model.latestItem(for: source) {
                                LabeledContent("Letzter neuer Treffer", value: latest.displayDetectedAt)
                            }

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
                model.showReader = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "newspaper.fill")
                    Text(model.readerUnreadCount > 0 ? "Reader \(model.readerUnreadCount)" : "Reader")
                }
            }
            .help(
                model.readerUnreadCount > 0
                ? "\(model.readerUnreadCount) ungelesene Meldungen öffnen"
                : "Redaktionellen News-Reader öffnen"
            )

            Menu {
                Button { model.showHealthDashboard = true } label: { Label("Übersicht", systemImage: "gauge.with.dots.needle.67percent") }
                Button { model.showFeedPreview = true } label: { Label("Feed-Rohansicht", systemImage: "list.bullet.rectangle") }
                Button { model.showGroupManager = true } label: { Label("Ordner verwalten", systemImage: "folder.badge.gearshape") }
                Button { model.showBulkManager = true } label: { Label("Quellen verwalten", systemImage: "checkmark.circle.badge.plus") }
                Divider()
                Button("Feeds als OPML exportieren") { model.exportOPML() }
                Button("Quellen als CSV exportieren") { model.exportSourcesCSV() }
                Button("Quellen als JSON exportieren") { model.exportSourcesJSON() }
                Button("OPML importieren …") { model.importOPML() }
            } label: {
                HStack(spacing: 5) { Image(systemName: "rectangle.3.group"); Text("Redaktion") }
            }
            .help("Ordner, Meldungen, Quellenverwaltung und Export")

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

    private var selectedFolderTitle: String {
        if selectedFolder == "__UNGROUPED__" { return "Ohne Ordner" }
        return selectedFolder ?? "Quellen"
    }

    private var filteredSources: [SourceRecord] {
        var list = model.sources

        if selectedFolder == "__UNGROUPED__" {
            list = list.filter { $0.groups.isEmpty }
        } else if let selectedFolder {
            list = list.filter { $0.groups.contains(where: { $0.caseInsensitiveCompare(selectedFolder) == .orderedSame }) }
        }

        switch listFilter {
        case .all: break
        case .active: list = list.filter(\.enabled)
        case .paused: list = list.filter { !$0.enabled }
        case .problems: list = list.filter { model.testResults[$0.id]?.isProblem == true }
        case .visual: list = list.filter(\.visualLearned)
        case .timeout: list = list.filter { model.testResults[$0.id]?.kind == .timeout }
        case .untested: list = list.filter { model.testResults[$0.id] == nil }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.url.localizedCaseInsensitiveContains(query) ||
                $0.groups.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
        }

        return list.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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



// MARK: - Organisation, Export und Dashboard

struct FeedPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel
    @State private var search = ""
    @State private var group = "Alle"

    var body: some View {
        NavigationStack {
            List(filteredItems) { item in
                Button { model.openFeedItem(item) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.sourceLabel ?? item.source).font(.caption.bold())
                            Text(String(repeating: "★", count: item.effectivePriority)).font(.caption2).foregroundStyle(.orange)
                            if let groups = item.groups, !groups.isEmpty { Text(groups.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Text(item.pageDate ?? item.displayDetectedAt).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(item.title).font(.headline).multilineTextAlignment(.leading)
                        if let duplicates = item.duplicateSources, !duplicates.isEmpty {
                            Text("Auch gefunden bei: \(duplicates.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Meldungen suchen")
            .navigationTitle("Feed-Vorschau")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem { Picker("Ordner", selection: $group) { Text("Alle").tag("Alle"); ForEach(model.allGroups, id: \.self) { Text($0).tag($0) } } }
            }
        }.frame(minWidth: 820, minHeight: 620)
    }

    private var filteredItems: [FeedHistoryItem] {
        model.feedItems.filter { item in
            let matchesGroup = group == "Alle" || (item.groups ?? []).contains(group)
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesGroup && (q.isEmpty || item.title.localizedCaseInsensitiveContains(q) || item.source.localizedCaseInsensitiveContains(q))
        }.sorted {
            if $0.effectivePriority != $1.effectivePriority { return $0.effectivePriority > $1.effectivePriority }
            return $0.detectedAt > $1.detectedAt
        }
    }
}

struct HealthDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        HealthCard(title: "Aktiv", value: model.activeCount, systemImage: "checkmark.circle.fill")
                        HealthCard(title: "Probleme", value: model.problemCount, systemImage: "exclamationmark.triangle.fill")
                        HealthCard(title: "Ordner", value: model.allGroups.count, systemImage: "folder.fill")
                        HealthCard(title: "Feed-Einträge", value: model.feedItems.count, systemImage: "newspaper.fill")
                    }
                    GroupBox("Quellen ohne aktuellen Verlaufstreffer") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(model.sources.filter { model.latestItem(for: $0) == nil }.prefix(20)) { source in
                                HStack { Text(source.name); Spacer(); Text(source.enabled ? "aktiv" : "pausiert").foregroundStyle(.secondary) }
                            }
                        }.padding(6)
                    }
                    GroupBox("Problemquellen") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(model.sources.filter { model.testResults[$0.id]?.isProblem == true }) { source in
                                HStack { Text(source.name); Spacer(); Text(model.testResults[source.id]?.kind.title ?? "Problem").foregroundStyle(.orange) }
                            }
                        }.padding(6)
                    }
                }.padding(22)
            }
            .navigationTitle("Quellen-Gesundheit")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }.frame(minWidth: 820, minHeight: 600)
    }
}

private struct HealthCard: View {
    let title: String; let value: Int; let systemImage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage).font(.title2)
            Text("\(value)").font(.system(size: 32, weight: .bold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct GroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel
    @State private var newGroup = ""
    @State private var renameValues: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Neuen Ordner anlegen") {
                    HStack { TextField("z. B. Payment", text: $newGroup); Button("Anlegen") { model.addGroup(newGroup); if !newGroup.trimmingCharacters(in: .whitespaces).isEmpty { renameValues[newGroup] = newGroup }; newGroup = "" } }
                }
                Section("Vorhandene Ordner") {
                    ForEach(model.allGroups, id: \.self) { group in
                        HStack {
                            TextField(group, text: Binding(get: { renameValues[group] ?? group }, set: { renameValues[group] = $0 }))
                            Text("\(model.groupCount(group)) Quellen").foregroundStyle(.secondary)
                            Button("Umbenennen") { model.renameGroup(group, to: renameValues[group] ?? group) }
                            Button("Feed öffnen") { model.openGroupFeed(group) }
                            Button("Entfernen", role: .destructive) { model.deleteGroup(group) }
                        }
                    }
                }
                Text("Ordner werden über die Quellen gespeichert. Ein leerer Ordner ohne zugeordnete Quelle existiert daher erst, sobald mindestens eine Quelle zugeordnet wurde.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Ordner & Themenfeeds")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }.frame(width: 820, height: 560)
    }
}

struct BulkManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel
    @State private var groupName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(model.sources) { source in
                    Button {
                        if model.bulkSelectedIDs.contains(source.id) { model.bulkSelectedIDs.remove(source.id) } else { model.bulkSelectedIDs.insert(source.id) }
                    } label: {
                        HStack {
                            Image(systemName: model.bulkSelectedIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) { Text(source.name); Text(source.groups.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(source.priorityStars).font(.caption)
                        }
                    }.buttonStyle(.plain)
                }
                Divider()
                HStack {
                    Text("\(model.bulkSelectedIDs.count) ausgewählt").font(.headline)
                    Button("Alle") { model.bulkSelectedIDs = Set(model.sources.map(\.id)) }
                    Button("Keine") { model.bulkSelectedIDs.removeAll() }
                    Divider().frame(height: 24)
                    Button("Aktivieren") { model.setEnabled(true, for: model.bulkSelectedIDs) }
                    Button("Pausieren") { model.setEnabled(false, for: model.bulkSelectedIDs) }
                    Button("Testen") { Task { await model.testSources(model.bulkSelectedIDs) } }
                    TextField("Ordner", text: $groupName).frame(width: 160)
                    Button("Zuordnen") { model.assignGroup(groupName, to: model.bulkSelectedIDs); groupName = "" }
                    Spacer()
                    Button("Löschen", role: .destructive) { model.deleteSources(model.bulkSelectedIDs) }
                }.padding(12)
            }
            .navigationTitle("Quellen verwalten")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        }.frame(minWidth: 920, minHeight: 650)
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
                strategy: strategy,
                sampleURLs: samples.map(\.url)
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

    // v2.1: Bei Karten zuerst die eigentliche Überschrift verwenden.
    // CTA-Links enthalten auf vielen Seiten Datum + Titel + „Mehr erfahren“.
    const selectors = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';
    for (const node of Array.from(card?.querySelectorAll?.(selectors) || [])) {
      const value = clean(node.textContent || node.getAttribute?.('aria-label') || '');
      if (value.length >= 5 && value.length <= 320 && !generic(value)) return node;
    }

    const own = clean(clickable?.textContent || clickable?.getAttribute?.('aria-label') || '');
    if (own.length >= 5 && own.length <= 320 && !generic(own)) return clickable;
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
    // Ein reines Host-Muster wäre viel zu breit (z. B. PayPal-Kategorien).
    // Bei gemeinsamen Unterordnern bleibt das URL-Muster ein starker Filter;
    // sonst übernimmt v2.1 die gespeicherte URL-Form der Trainingsbeispiele.
    if (!common.length) return '';
    const prefix = '/' + common.join('/') + '/';
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


// MARK: - Integrierter News-Reader

enum ReaderScope: Hashable {
    case inbox
    case all
    case favorites
    case archive
    case group(String)
}

enum ReaderSort: String, CaseIterable, Identifiable {
    case newest
    case relevance
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Neueste"
        case .relevance: return "Relevanz"
        case .source: return "Quelle"
        }
    }
}

enum ReaderDateRange: String, CaseIterable, Identifiable {
    case all
    case today
    case last24Hours
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Alle Zeiträume"
        case .today: return "Heute"
        case .last24Hours: return "Letzte 24 Stunden"
        case .week: return "Diese Woche"
        }
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel

    @State private var scope: ReaderScope = .inbox
    @State private var selectedID: String?
    @State private var search = ""
    @State private var sort: ReaderSort = .newest
    @State private var dateRange: ReaderDateRange = .all
    @State private var selectedSource = "Alle"
    @State private var selectedTag = "Alle"
    @State private var minimumPriority = 1
    @State private var showWebPreview = false

    var body: some View {
        NavigationSplitView {
            readerSidebar
        } content: {
            readerList
        } detail: {
            readerDetail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear {
            if selectedID == nil {
                selectedID = filteredItems.first?.id
            }
            model.updateReaderDockBadge()
        }
        .onChange(of: selectedID) { _, newValue in
            guard
                let newValue,
                let item = model.feedItems.first(where: { $0.id == newValue })
            else { return }
            model.readerMarkRead(item)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }

            ToolbarItemGroup {
                Button {
                    model.readerMarkAllRead(filteredItems)
                } label: {
                    Label("Alle gelesen", systemImage: "checkmark.circle")
                }
                .disabled(filteredItems.isEmpty)

                Button {
                    Task { await model.reloadAll() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)

                Picker("Sortierung", selection: $sort) {
                    ForEach(ReaderSort.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .frame(width: 125)
            }
        }
    }

    private var readerSidebar: some View {
        List(selection: $scope) {
            Section("Reader") {
                ReaderSidebarRow(
                    title: "Posteingang",
                    systemImage: "tray.full.fill",
                    count: model.readerUnreadCount
                )
                .tag(ReaderScope.inbox)

                ReaderSidebarRow(
                    title: "Alle Meldungen",
                    systemImage: "newspaper",
                    count: model.feedItems.filter {
                        !model.readerIsArchived($0)
                    }.count
                )
                .tag(ReaderScope.all)

                ReaderSidebarRow(
                    title: "Favoriten",
                    systemImage: "star.fill",
                    count: model.feedItems.filter {
                        model.readerIsFavorite($0) &&
                        !model.readerIsArchived($0)
                    }.count
                )
                .tag(ReaderScope.favorites)

                ReaderSidebarRow(
                    title: "Archiv",
                    systemImage: "archivebox",
                    count: model.feedItems.filter {
                        model.readerIsArchived($0)
                    }.count
                )
                .tag(ReaderScope.archive)
            }

            if !model.allGroups.isEmpty {
                Section("Ordner") {
                    ForEach(model.allGroups, id: \.self) { group in
                        ReaderSidebarRow(
                            title: group,
                            systemImage: "folder",
                            count: model.readerUnreadCount(in: group)
                        )
                        .tag(ReaderScope.group(group))
                    }
                }
            }
        }
        .navigationTitle("News")
        .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 300)
    }

    private var readerList: some View {
        VStack(spacing: 0) {
            ReaderFilterBar(
                sources: sourceChoices,
                tags: tagChoices,
                selectedSource: $selectedSource,
                selectedTag: $selectedTag,
                minimumPriority: $minimumPriority,
                dateRange: $dateRange
            )

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    "Keine Meldungen",
                    systemImage: "newspaper",
                    description: Text("Für die gewählten Filter gibt es aktuell keine Meldungen.")
                )
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredItems) { item in
                        ReaderItemRow(
                            item: item,
                            isRead: model.readerIsRead(item),
                            isFavorite: model.readerIsFavorite(item)
                        )
                        .tag(item.id)
                        .contextMenu {
                            Button(
                                model.readerIsRead(item)
                                ? "Als ungelesen markieren"
                                : "Als gelesen markieren"
                            ) {
                                model.readerToggleRead(item)
                            }

                            Button(
                                model.readerIsFavorite(item)
                                ? "Favorit entfernen"
                                : "Als Favorit markieren"
                            ) {
                                model.readerToggleFavorite(item)
                            }

                            Button(
                                model.readerIsArchived(item)
                                ? "Aus Archiv holen"
                                : "Archivieren"
                            ) {
                                model.readerToggleArchive(item)
                                if selectedID == item.id {
                                    selectedID = filteredItems.first {
                                        $0.id != item.id
                                    }?.id
                                }
                            }

                            Divider()

                            Button("Im Browser öffnen") {
                                model.openFeedItem(item)
                                model.readerMarkRead(item)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Meldungen durchsuchen")
        .navigationTitle(scopeTitle)
        .navigationSplitViewColumnWidth(min: 390, ideal: 470, max: 620)
        .onChange(of: scope) { _, _ in
            ensureSelection()
        }
        .onChange(of: search) { _, _ in
            ensureSelection()
        }
        .onChange(of: selectedSource) { _, _ in
            ensureSelection()
        }
        .onChange(of: selectedTag) { _, _ in
            ensureSelection()
        }
        .onChange(of: minimumPriority) { _, _ in
            ensureSelection()
        }
        .onChange(of: dateRange) { _, _ in
            ensureSelection()
        }
    }

    @ViewBuilder
    private var readerDetail: some View {
        if let item = selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.sourceLabel ?? item.source)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            Text(String(repeating: "★", count: item.effectivePriority))
                                .foregroundStyle(.orange)

                            Spacer()

                            if !model.readerIsRead(item) {
                                Text("UNGelesen".uppercased())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.blue.opacity(0.12), in: Capsule())
                            }
                        }

                        Text(item.title)
                            .font(.system(size: 28, weight: .bold))
                            .textSelection(.enabled)

                        HStack(spacing: 12) {
                            Label(
                                item.pageDate ?? item.displayDetectedAt,
                                systemImage: "calendar"
                            )

                            if let groups = item.groups, !groups.isEmpty {
                                Label(
                                    groups.joined(separator: " · "),
                                    systemImage: "folder"
                                )
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.openFeedItem(item)
                            model.readerMarkRead(item)
                        } label: {
                            Label("Im Browser öffnen", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.readerToggleRead(item)
                        } label: {
                            Label(
                                model.readerIsRead(item)
                                ? "Ungelesen"
                                : "Gelesen",
                                systemImage:
                                    model.readerIsRead(item)
                                    ? "circle"
                                    : "checkmark.circle"
                            )
                        }

                        Button {
                            model.readerToggleFavorite(item)
                        } label: {
                            Label(
                                model.readerIsFavorite(item)
                                ? "Favorit entfernen"
                                : "Favorit",
                                systemImage:
                                    model.readerIsFavorite(item)
                                    ? "star.fill"
                                    : "star"
                            )
                        }

                        Button {
                            model.readerToggleArchive(item)
                        } label: {
                            Label(
                                model.readerIsArchived(item)
                                ? "Aus Archiv"
                                : "Archivieren",
                                systemImage:
                                    model.readerIsArchived(item)
                                    ? "tray.and.arrow.up"
                                    : "archivebox"
                            )
                        }

                        Spacer()
                    }

                    GroupBox("Meldung") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Quelle", value: item.source)
                            LabeledContent("Erkannt", value: item.displayDetectedAt)

                            if let pageDate = item.pageDate, !pageDate.isEmpty {
                                LabeledContent("Veröffentlicht", value: pageDate)
                            }

                            if let tags = item.tags, !tags.isEmpty {
                                LabeledContent("Schlagwörter", value: tags.joined(separator: ", "))
                            }

                            if let duplicates = item.duplicateSources, !duplicates.isEmpty {
                                LabeledContent(
                                    "Auch gefunden bei",
                                    value: duplicates.joined(separator: ", ")
                                )
                            }

                            LabeledContent("Ziel") {
                                Text(item.link)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                    }

                    Toggle(
                        "Artikel direkt in der App anzeigen",
                        isOn: $showWebPreview
                    )
                    .toggleStyle(.switch)

                    if showWebPreview {
                        ReaderWebPreview(urlString: item.link)
                            .frame(minHeight: 430)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.separator, lineWidth: 1)
                            }
                    }
                }
                .padding(22)
            }
            .navigationTitle("Artikel")
        } else {
            ContentUnavailableView(
                "Meldung auswählen",
                systemImage: "newspaper",
                description: Text("Wähle links eine Meldung aus.")
            )
        }
    }

    private var selectedItem: FeedHistoryItem? {
        guard let selectedID else { return nil }
        return model.feedItems.first { $0.id == selectedID }
    }

    private var sourceChoices: [String] {
        ["Alle"] + Array(Set(model.feedItems.map(\.source))).sorted()
    }

    private var tagChoices: [String] {
        ["Alle"] + Array(
            Set(model.feedItems.flatMap { $0.tags ?? [] })
        ).sorted()
    }

    private var scopeTitle: String {
        switch scope {
        case .inbox: return "Posteingang"
        case .all: return "Alle Meldungen"
        case .favorites: return "Favoriten"
        case .archive: return "Archiv"
        case .group(let group): return group
        }
    }

    private var filteredItems: [FeedHistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        var values = model.feedItems.filter { item in
            let scopeMatches: Bool = {
                switch scope {
                case .inbox:
                    return !model.readerIsArchived(item) &&
                        !model.readerIsRead(item)
                case .all:
                    return !model.readerIsArchived(item)
                case .favorites:
                    return !model.readerIsArchived(item) &&
                        model.readerIsFavorite(item)
                case .archive:
                    return model.readerIsArchived(item)
                case .group(let group):
                    return !model.readerIsArchived(item) &&
                        (item.groups ?? []).contains(group)
                }
            }()

            guard scopeMatches else { return false }

            if selectedSource != "Alle", item.source != selectedSource {
                return false
            }

            if selectedTag != "Alle",
               !(item.tags ?? []).contains(selectedTag) {
                return false
            }

            if item.effectivePriority < minimumPriority {
                return false
            }

            if !query.isEmpty {
                let haystack = [
                    item.title,
                    item.source,
                    item.sourceLabel ?? "",
                    (item.groups ?? []).joined(separator: " "),
                    (item.tags ?? []).joined(separator: " ")
                ].joined(separator: " ")

                if !haystack.localizedCaseInsensitiveContains(query) {
                    return false
                }
            }

            if dateRange != .all {
                guard let detected = ISO8601DateFormatter().date(
                    from: item.detectedAt
                ) else {
                    return false
                }

                switch dateRange {
                case .all:
                    break
                case .today:
                    if !Calendar.current.isDateInToday(detected) {
                        return false
                    }
                case .last24Hours:
                    if detected < now.addingTimeInterval(-24 * 60 * 60) {
                        return false
                    }
                case .week:
                    if detected < now.addingTimeInterval(-7 * 24 * 60 * 60) {
                        return false
                    }
                }
            }

            return true
        }

        values.sort { lhs, rhs in
            switch sort {
            case .newest:
                return lhs.detectedAt > rhs.detectedAt
            case .relevance:
                if lhs.effectivePriority != rhs.effectivePriority {
                    return lhs.effectivePriority > rhs.effectivePriority
                }
                return lhs.detectedAt > rhs.detectedAt
            case .source:
                let result = lhs.source.localizedCaseInsensitiveCompare(
                    rhs.source
                )
                if result == .orderedSame {
                    return lhs.detectedAt > rhs.detectedAt
                }
                return result == .orderedAscending
            }
        }

        return values
    }

    private func ensureSelection() {
        if let selectedID,
           filteredItems.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = filteredItems.first?.id
    }
}

private struct ReaderSidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReaderItemRow: View {
    let item: FeedHistoryItem
    let isRead: Bool
    let isFavorite: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(isRead ? Color.clear : Color.blue)
                .frame(width: 7, height: 7)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.sourceLabel ?? item.source)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Text(
                        String(
                            repeating: "★",
                            count: item.effectivePriority
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)

                    Spacer()

                    if isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }

                    Text(item.displayDetectedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(item.title)
                    .font(isRead ? .body : .headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(3)

                if let groups = item.groups, !groups.isEmpty {
                    Text(groups.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReaderFilterBar: View {
    let sources: [String]
    let tags: [String]

    @Binding var selectedSource: String
    @Binding var selectedTag: String
    @Binding var minimumPriority: Int
    @Binding var dateRange: ReaderDateRange

    var body: some View {
        HStack(spacing: 8) {
            Picker("Zeitraum", selection: $dateRange) {
                ForEach(ReaderDateRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .frame(maxWidth: 160)

            Picker("Quelle", selection: $selectedSource) {
                ForEach(sources, id: \.self) { source in
                    Text(source).tag(source)
                }
            }
            .frame(maxWidth: 180)

            Picker("Tag", selection: $selectedTag) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).tag(tag)
                }
            }
            .frame(maxWidth: 160)

            Picker("Relevanz", selection: $minimumPriority) {
                Text("Alle ★").tag(1)
                Text("ab ★★").tag(2)
                Text("nur ★★★").tag(3)
            }
            .frame(maxWidth: 120)

            Spacer()
        }
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct ReaderWebPreview: NSViewRepresentable {
    let urlString: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(
            frame: .zero,
            configuration: configuration
        )
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard
            let url = URL(string: urlString),
            webView.url?.absoluteString != url.absoluteString
        else {
            return
        }

        webView.load(URLRequest(url: url))
    }
}

