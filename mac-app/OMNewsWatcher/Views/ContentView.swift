import SwiftUI
import AppKit
import WebKit

private enum PendingSourceNavigation {
    case source(UUID?)
    case folder(String?)
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppViewModel
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var selectedFolder: String? = nil
    @State private var listFilter: SourceListFilter = .all
    @State private var pendingNavigation: PendingSourceNavigation?
    @State private var showUnsavedNavigationConfirmation = false

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
                    availableGroups: model.allGroups,
                    suggestTags: { source in
                        model.automaticTagSuggestions(for: source)
                    },
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
        .sheet(isPresented: $model.showRuleDebugger) {
            RuleDebuggerView(model: model)
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
        .confirmationDialog(
            "Ungespeicherte Änderungen",
            isPresented: $showUnsavedNavigationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Speichern und wechseln") {
                Task {
                    if await model.saveSourcesForNavigation() {
                        applyPendingNavigation()
                    }
                }
            }

            Button("Änderungen verwerfen", role: .destructive) {
                model.discardUnsavedChanges()
                applyPendingNavigation()
            }

            Button("Abbrechen", role: .cancel) {
                pendingNavigation = nil
            }
        } message: {
            Text("Vor dem Wechsel sind noch Änderungen an sources.json ungespeichert.")
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
                        requestNavigation(.folder(nil))
                    } label: {
                        HStack {
                            Label("Alle Quellen", systemImage: selectedFolder == nil ? "tray.full.fill" : "tray.full")
                            Spacer()
                            Text("\(model.sources.count) Quellen")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            UnreadBadge(count: model.readerUnreadCount)
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(model.allGroups, id: \.self) { group in
                        Button {
                            requestNavigation(.folder(group))
                        } label: {
                            HStack {
                                Label(group, systemImage: selectedFolder == group ? "folder.fill" : "folder")
                                Spacer()
                                Text("\(model.groupCount(group))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                UnreadBadge(count: model.readerUnreadCount(in: group))
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Gruppenfeed öffnen") { model.openGroupFeed(group) }
                        }
                    }

                    if model.ungroupedCount > 0 {
                        Button {
                            requestNavigation(.folder("__UNGROUPED__"))
                        } label: {
                            HStack {
                                Label("Ohne Ordner", systemImage: "folder.badge.questionmark")
                                Spacer()
                                Text("\(model.ungroupedCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                UnreadBadge(count: model.readerUngroupedUnreadCount)
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

            List(selection: sourceSelectionBinding) {
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

                        UnreadBadge(count: model.readerUnreadCount(for: source))

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

                        Toggle(
                            source.enabled ? "Aktiv" : "Pausiert",
                            isOn: Binding(
                                get: { source.enabled },
                                set: { model.setEnabled($0, for: source.id) }
                            )
                        )
                        .toggleStyle(.switch)
                        .help(
                            source.enabled
                                ? "Quelle wird überwacht – ausschalten zum Pausieren"
                                : "Quelle ist pausiert – einschalten zum Aktivieren"
                        )
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
                            LabeledContent("Quellentyp", value: source.sourceType)
                            LabeledContent(
                                "Prüfintervall",
                                value: source.checkIntervalTitle +
                                    (source.weekdaysOnly ? " · Mo–Fr" : "")
                            )

                            if let latest = model.latestItem(for: source) {
                                LabeledContent("Letzter neuer Treffer", value: latest.displayDetectedAt)
                            }

                            if let health = model.health(for: source) {
                                if let checkedAt = health.checkedAt {
                                    LabeledContent(
                                        "Letzter GitHub-Check",
                                        value: FeedHistoryItem.parsedDate(checkedAt)
                                            .map {
                                                DateFormatter.localizedString(
                                                    from: $0,
                                                    dateStyle: .short,
                                                    timeStyle: .short
                                                )
                                            } ?? checkedAt
                                    )
                                }

                                if let watcher = model.healthWatcherVersion {
                                    LabeledContent(
                                        "Watcher-Version",
                                        value: "v\(watcher)"
                                    )
                                }

                                LabeledContent("Gesundheit") {
                                    Label(
                                        health.healthSummary ?? health.healthTitle,
                                        systemImage: health.healthSystemImage
                                    )
                                    .foregroundStyle(
                                        health.effectiveHealthStatus == "error"
                                        ? .red
                                        : health.effectiveHealthStatus == "anomaly"
                                        ? .orange
                                        : health.effectiveHealthStatus == "no-new"
                                        ? .blue
                                        : .green
                                    )
                                }

                                if let technical = health.technicalHitCount {
                                    LabeledContent(
                                        "Technisch erkannt",
                                        value: "\(technical)"
                                    )
                                }

                                if let eligible = health.eligibleHitCount {
                                    LabeledContent(
                                        "Reader-fähig",
                                        value: "\(eligible)"
                                    )
                                }

                                if let rejected = health.rejectedHitCount,
                                   rejected > 0 {
                                    LabeledContent(
                                        "Verworfen",
                                        value: "\(rejected)"
                                    )
                                }

                                if let detected = health.latestDetected,
                                   let title = detected.title,
                                   !title.isEmpty {
                                    LabeledContent(
                                        "Neuester erkannter Artikel",
                                        value: title
                                    )
                                }

                                if let stored = health.latestStored,
                                   let title = stored.title,
                                   !title.isEmpty {
                                    LabeledContent(
                                        "Neuester gespeicherter Artikel",
                                        value: title
                                    )
                                }

                                if (health.healedTodayCount ?? 0) > 0 {
                                    LabeledContent(
                                        "Tracking-Reparaturen heute",
                                        value: "\(health.healedTodayCount ?? 0)"
                                    )
                                }

                                if (health.healedCount ?? 0) > 0 {
                                    LabeledContent(
                                        "Tracking-Reparaturen gesamt",
                                        value: "\(health.healedCount ?? 0)"
                                    )
                                }
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
                            model.showRuleDebugger = true
                        } label: {
                            Label(
                                "Regel erklären",
                                systemImage: "ladybug"
                            )
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

                        if source.visualRuleHistoryCount > 0 {
                            Button("Vorherige Regel") {
                                model.restorePreviousRule(for: source.id)
                            }
                            .help(
                                "\(source.visualRuleHistoryCount) ältere Regelstände verfügbar"
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
                        Text("Die App trennt jetzt zwischen technisch erkannten Treffern und Meldungen, die tatsächlich in Reader/RSS übernommen würden.")
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

                    HStack(spacing: 18) {
                        Label(
                            "\(result.hitCount) technisch erkannt",
                            systemImage: "scope"
                        )
                        .foregroundStyle(.secondary)

                        Label(
                            "\(result.eligibleCount) Reader-fähig",
                            systemImage: result.eligibleCount > 0
                                ? "checkmark.seal.fill"
                                : "checkmark.seal"
                        )
                        .foregroundStyle(
                            result.eligibleCount > 0 ? .green : .secondary
                        )

                        if !result.rejectedExamples.isEmpty {
                            Label(
                                "\(max(0, result.hitCount - result.eligibleCount)) verworfen",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)

                    if !result.eligibleExamples.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Würde als neue Meldung gespeichert")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)

                            ForEach(result.eligibleExamples) { hit in
                                Button {
                                    model.openHit(hit)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
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

                    if !result.rejectedExamples.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Erkannt, aber vom News-Eligibility-Gate verworfen")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)

                            ForEach(result.rejectedExamples) { hit in
                                Button {
                                    if let url = hit.url {
                                        model.openHit(
                                            SourceTestHit(
                                                title: hit.title,
                                                url: url,
                                                publicationDate: hit.publicationDate
                                            )
                                        )
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(hit.title)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Text(hit.reason)
                                                .font(.caption)
                                                .foregroundStyle(.orange)
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
                                .disabled(hit.url == nil)
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
                let defaultGroup =
                    selectedFolder == "__UNGROUPED__"
                        ? nil
                        : selectedFolder
                model.addSource(defaultGroup: defaultGroup)
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
                    Image(
                        systemName: model.isDirty
                            ? "exclamationmark.circle.fill"
                            : "checkmark.circle"
                    )
                    Text(
                        model.isDirty
                            ? "Änderungen speichern"
                            : "Gespeichert"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isDirty ? .orange : .gray)
            .help(
                model.isDirty
                    ? "Ungespeicherte Änderungen in sources.json – jetzt speichern"
                    : "Alle Änderungen sind gespeichert"
            )
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.isDirty || model.isBusy || model.isTestingAll)

            Button {
                Task { await model.runWorkflow() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("Alle Quellen prüfen")
                }
            }
            .help("GitHub-Watcher starten und alle aktuell fälligen aktiven Quellen prüfen")
            .disabled(model.isBusy || model.isTestingAll)
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                openWindow(id: "reader")
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
                Divider()
                Button("Vollständiges Backup exportieren …") {
                    model.exportFullBackup()
                }
                Button("Backup wiederherstellen …") {
                    model.importFullBackup()
                }
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

    private var sourceSelectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedSourceID },
            set: { newValue in
                guard newValue != model.selectedSourceID else { return }
                requestNavigation(.source(newValue))
            }
        )
    }

    private func requestNavigation(_ navigation: PendingSourceNavigation) {
        if model.isDirty {
            pendingNavigation = navigation
            showUnsavedNavigationConfirmation = true
        } else {
            applyNavigation(navigation)
        }
    }

    private func applyPendingNavigation() {
        guard let pendingNavigation else { return }
        applyNavigation(pendingNavigation)
        self.pendingNavigation = nil
    }

    private func applyNavigation(_ navigation: PendingSourceNavigation) {
        switch navigation {
        case .source(let sourceID):
            model.selectedSourceID = sourceID
        case .folder(let folder):
            selectedFolder = folder

            if let selectedSourceID = model.selectedSourceID,
               !filteredSourcesForFolder(folder).contains(where: { $0.id == selectedSourceID }) {
                model.selectedSourceID = filteredSourcesForFolder(folder).first?.id
            }
        }
    }

    private func filteredSourcesForFolder(_ folder: String?) -> [SourceRecord] {
        if folder == "__UNGROUPED__" {
            return model.sources.filter { $0.groups.isEmpty }
        }

        if let folder {
            return model.sources.filter { source in
                source.groups.contains { group in
                    group.caseInsensitiveCompare(folder) == .orderedSame
                }
            }
        }

        return model.sources
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
        case .noCurrentNews: return "checkmark.circle"
        case .largeArchive: return "archivebox.circle.fill"
        case .zeroHits: return "questionmark.circle.fill"
        case .tooManyHits: return "exclamationmark.triangle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .technicalError: return "xmark.octagon.fill"
        }
    }

    private func testColor(_ kind: SourceTestKind) -> Color {
        switch kind {
        case .success, .noCurrentNews, .largeArchive: return .green
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
    @State private var onlyWarnings = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HealthCard(
                        title: "Aktiv",
                        value: model.activeCount,
                        systemImage: "checkmark.circle.fill"
                    )
                    HealthCard(
                        title: "Gesund",
                        value: model.healthHealthyCount,
                        systemImage: "checkmark.seal.fill"
                    )
                    HealthCard(
                        title: "Keine neue Meldung",
                        value: model.healthNoNewCount,
                        systemImage: "checkmark.circle"
                    )
                    HealthCard(
                        title: "Auffällig",
                        value: model.healthAnomalyCount,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    HealthCard(
                        title: "Fehler",
                        value: model.healthErrorCount,
                        systemImage: "xmark.octagon.fill"
                    )
                    HealthCard(
                        title: "Reparaturen heute",
                        value: model.healthHealedTodayCount,
                        systemImage: "cross.case.fill"
                    )
                }
                .padding()

                HStack {
                    Toggle("Nur Probleme", isOn: $onlyWarnings)
                        .toggleStyle(.switch)

                    Spacer()

                    TextField("Quelle suchen", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                if model.healthItems.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Gesundheitsdaten",
                        systemImage: "waveform.path.ecg",
                        description: Text(
                            "Starte den GitHub-Watcher nach dem Update einmal manuell. Danach steht data/health.json zur Verfügung."
                        )
                    )
                } else {
                    Table(filteredHealth) {
                        TableColumn("Quelle") { item in
                            HStack(spacing: 7) {
                                Image(
                                    systemName:
                                        item.healthSystemImage
                                )
                                .foregroundStyle(
                                    item.effectiveHealthStatus == "error"
                                    ? .red
                                    : item.effectiveHealthStatus == "anomaly"
                                    ? .orange
                                    : item.effectiveHealthStatus == "no-new"
                                    ? .blue
                                    : item.effectiveHealthStatus == "skipped"
                                    ? .secondary
                                    : .green
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.source)

                                    if let summary = item.healthSummary,
                                       !summary.isEmpty {
                                        Text(summary)
                                            .font(.caption2)
                                            .foregroundStyle(
                                                item.hasWarning
                                                ? .orange
                                                : .secondary
                                            )
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        TableColumn("Technisch") { item in
                            Text(item.displayTechnicalCount)
                        }
                        .width(100)

                        TableColumn("Reader") { item in
                            Text(item.displayEligibleCount)
                        }
                        .width(85)

                        TableColumn("Status") { item in
                            Text(item.healthTitle)
                                .foregroundStyle(
                                    item.effectiveHealthStatus == "error"
                                    ? .red
                                    : item.effectiveHealthStatus == "anomaly"
                                    ? .orange
                                    : item.effectiveHealthStatus == "no-new"
                                    ? .blue
                                    : .secondary
                                )
                        }
                        .width(115)

                        TableColumn("Tracking") { item in
                            Text(item.trackingDisplay)
                                .foregroundStyle(
                                    item.trackingStatus == "warning"
                                    ? .orange
                                    : item.trackingStatus == "healed"
                                    ? .green
                                    : .secondary
                                )
                        }
                        .width(115)

                        TableColumn("Dauer") { item in
                            Text(
                                item.durationMs.map {
                                    String(format: "%.1f s", Double($0) / 1000)
                                } ?? "—"
                            )
                        }
                        .width(75)

                        TableColumn("Letzter Erfolg") { item in
                            Text(displayDate(item.lastSuccessAt))
                        }
                        .width(135)

                        TableColumn("Letzte neue Meldung") { item in
                            Text(displayDate(item.lastNewAt))
                        }
                        .width(145)

                        TableColumn("Nächster Check") { item in
                            Text(
                                item.enabled
                                ? displayDate(item.nextCheckAt)
                                : "Pausiert"
                            )
                        }
                        .width(135)

                        TableColumn("") { item in
                            Button("Öffnen") {
                                model.selectSource(named: item.source)
                                dismiss()
                            }
                            .buttonStyle(.borderless)
                        }
                        .width(65)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Text("App 5.3.4")

                    if let watcher = model.healthWatcherVersion {
                        Text("Watcher v\(watcher)")
                    } else {
                        Text("Watcher-Version unbekannt")
                    }

                    if let schema = model.healthTrackingSchemaVersion {
                        Text("Tracking-Schema \(schema)")
                    }

                    Spacer()

                    if let generated = model.healthGeneratedAt {
                        Text("Health: \(displayDate(generated))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.bar)
            }
            .navigationTitle("Quellen-Gesundheit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem {
                    Button {
                        Task { await model.loadHealth() }
                    } label: {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(minWidth: 1240, minHeight: 680)
    }

    private var filteredHealth: [SourceHealthSnapshot] {
        model.healthItems
            .filter { item in
                let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
                let searchMatches =
                    q.isEmpty ||
                    item.source.localizedCaseInsensitiveContains(q)

                return searchMatches && (!onlyWarnings || item.hasWarning)
            }
            .sorted {
                func rank(_ item: SourceHealthSnapshot) -> Int {
                    switch item.effectiveHealthStatus {
                    case "error": return 0
                    case "anomaly": return 1
                    case "no-new": return 2
                    case "healthy": return 3
                    case "skipped": return 4
                    case "paused": return 5
                    default: return 6
                    }
                }

                let leftRank = rank($0)
                let rightRank = rank($1)

                if leftRank != rightRank {
                    return leftRank < rightRank
                }

                return $0.source.localizedCaseInsensitiveCompare(
                    $1.source
                ) == .orderedAscending
            }
    }

    private func displayDate(_ raw: String?) -> String {
        guard let raw else { return "—" }
        guard let date = FeedHistoryItem.parsedDate(raw) else { return raw }

        return DateFormatter.localizedString(
            from: date,
            dateStyle: .short,
            timeStyle: .short
        )
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
    @State private var tagName = ""
    @State private var priority = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(model.sources) { source in
                    Button {
                        if model.bulkSelectedIDs.contains(source.id) {
                            model.bulkSelectedIDs.remove(source.id)
                        } else {
                            model.bulkSelectedIDs.insert(source.id)
                        }
                    } label: {
                        HStack {
                            Image(
                                systemName:
                                    model.bulkSelectedIDs.contains(source.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(
                                    [
                                        source.groups.joined(separator: ", "),
                                        source.enabled ? "aktiv" : "pausiert",
                                        source.checkIntervalTitle
                                    ]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()
                            Text(source.priorityStars).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                VStack(spacing: 10) {
                    HStack {
                        Text("\(model.bulkSelectedIDs.count) ausgewählt")
                            .font(.headline)

                        Button("Alle") {
                            model.bulkSelectedIDs = Set(model.sources.map(\.id))
                        }
                        Button("Keine") {
                            model.bulkSelectedIDs.removeAll()
                        }

                        Spacer()

                        Button("Aktivieren") {
                            model.setEnabled(true, for: model.bulkSelectedIDs)
                        }
                        Button("Pausieren") {
                            model.setEnabled(false, for: model.bulkSelectedIDs)
                        }
                        Button("Testen") {
                            Task {
                                await model.testSources(model.bulkSelectedIDs)
                            }
                        }
                    }

                    HStack {
                        TextField("Ordner", text: $groupName)
                            .frame(width: 180)

                        Button("Ordner zuordnen") {
                            model.assignGroup(groupName, to: model.bulkSelectedIDs)
                            groupName = ""
                        }

                        Button("Aus Ordner entfernen") {
                            model.removeGroup(groupName, from: model.bulkSelectedIDs)
                            groupName = ""
                        }

                        Divider().frame(height: 26)

                        TextField("Schlagwort", text: $tagName)
                            .frame(width: 170)

                        Button("Tag hinzufügen") {
                            model.addTag(tagName, to: model.bulkSelectedIDs)
                            tagName = ""
                        }

                        Divider().frame(height: 26)

                        Picker("Relevanz", selection: $priority) {
                            Text("★☆☆").tag(1)
                            Text("★★☆").tag(2)
                            Text("★★★").tag(3)
                        }
                        .frame(width: 120)

                        Button("Setzen") {
                            model.setPriority(priority, for: model.bulkSelectedIDs)
                        }

                        Spacer()

                        Button("Löschen", role: .destructive) {
                            model.deleteSources(model.bulkSelectedIDs)
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Quellen verwalten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}

struct RuleDebuggerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel

    var body: some View {
        NavigationStack {
            if let source = model.selectedSource {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("Aktive Erkennungsregel") {
                            VStack(alignment: .leading, spacing: 7) {
                                debugLine("Quellentyp", source.sourceType)
                                debugLine("Abruf", source.fetchMode ?? "Browser / automatisch")
                                debugLine("Kandidatenselektor", source.candidateSelector ?? "Automatik")
                                debugLine("Karten-Selektor", source.itemSelector ?? "—")
                                debugLine("Titel-Selektor", source.titleSelector ?? "—")
                                debugLine("Link-Selektor", source.linkSelector ?? "—")
                                debugLine("URL einschließen", source.includeRegex ?? "—")
                                debugLine("URL ausschließen", source.excludeRegex ?? "—")
                                debugLine("Min. Titellänge", "\(source.minTitleLength)")
                                debugLine("Externe Links", source.allowExternal ? "erlaubt" : "nein")
                                debugLine("Regelstände", "\(source.visualRuleHistoryCount) vorherige")
                            }
                            .padding(8)
                        }

                        if let result = model.testResults[source.id] {
                            GroupBox("Letzter lokaler Test") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(
                                            result.kind.title,
                                            systemImage:
                                                result.kind.isSuccessLike
                                                ? "checkmark.circle.fill"
                                                : "exclamationmark.triangle.fill"
                                        )
                                        .foregroundStyle(
                                            result.kind.isSuccessLike
                                            ? .green
                                            : .orange
                                        )

                                        Spacer()

                                        Text(
                                            String(
                                                format: "%.1f s",
                                                Double(result.durationMs) / 1000
                                            )
                                        )
                                        .foregroundStyle(.secondary)
                                    }

                                    Text(result.message)
                                        .foregroundStyle(.secondary)

                                    ForEach(result.examples.prefix(8)) { hit in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(hit.title)
                                                .font(.headline)

                                            if let url = hit.url {
                                                Text(url)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }

                                            Text(explanation(for: hit, source: source))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                .padding(8)
                            }
                        } else {
                            ContentUnavailableView(
                                "Noch kein lokaler Test",
                                systemImage: "ladybug",
                                description: Text(
                                    "Führe „Quelle testen“ aus. Danach erklärt der Debugger die Beispieltreffer."
                                )
                            )
                        }

                        if let health = model.health(for: source) {
                            GroupBox("GitHub-Watcher") {
                                VStack(alignment: .leading, spacing: 7) {
                                    debugLine("Technisch erkannt", health.displayTechnicalCount)
                                    debugLine(
                                        "Dauer",
                                        health.durationMs.map {
                                            String(format: "%.1f s", Double($0) / 1000)
                                        } ?? "—"
                                    )
                                    debugLine("Warnung", health.anomaly ?? "keine")
                                    debugLine("Meldung", health.message ?? "—")
                                }
                                .padding(8)
                            }
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("Regel-Debugger · \(source.name)")
            } else {
                ContentUnavailableView(
                    "Keine Quelle ausgewählt",
                    systemImage: "ladybug"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }

            ToolbarItem {
                Button {
                    Task { await model.testSelectedSource() }
                } label: {
                    Label("Neu testen", systemImage: "stethoscope")
                }
                .disabled(model.testingSourceID != nil || model.isTestingAll)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
    }

    @ViewBuilder
    private func debugLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(value)
                .textSelection(.enabled)

            Spacer()
        }
    }

    private func explanation(
        for hit: SourceTestHit,
        source: SourceRecord
    ) -> String {
        var parts: [String] = []

        parts.append(
            hit.title.count >= source.minTitleLength
            ? "Titellänge erfüllt"
            : "Titellänge zu kurz"
        )

        if let urlString = hit.url,
           let url = URL(string: urlString) {
            let sourceHost = URL(string: source.url)?.host ?? ""

            parts.append(
                source.allowExternal || url.host == sourceHost
                ? "Host erlaubt"
                : "abweichender Host"
            )

            if let pattern = source.includeRegex,
               let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
               ) {
                let range = NSRange(urlString.startIndex..., in: urlString)
                parts.append(
                    regex.firstMatch(
                        in: urlString,
                        options: [],
                        range: range
                    ) != nil
                    ? "URL-Filter erfüllt"
                    : "URL-Filter nicht erfüllt"
                )
            }
        }

        if source.visualLearned {
            parts.append(
                source.visualValidated
                ? "visuelle Regel validiert"
                : "visuelle Regel nicht validiert"
            )
        }

        return parts.joined(separator: " · ")
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

                        Button("Regel prüfen & übernehmen") {
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

        if let messageText = body["status"] as? String,
           !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = messageText
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
  const clickableSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick],[onclick]';
  const titleSelector = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[class*="name" i],[data-testid*="title" i],strong';
  const cardSelector = [
    'article','li','tr',
    '[class*="card" i]','[class*="teaser" i]','[class*="news" i]',
    '[class*="press" i]','[class*="event" i]','[class*="conference" i]',
    '[class*="messe" i]','[class*="story" i]','[class*="result" i]',
    '[class*="entry" i]','[class*="item" i]','[class*="report" i]',
    '[class*="post" i]'
  ].join(',');

  const cssEscape = value => window.CSS?.escape ? CSS.escape(value) : String(value).replace(/[^a-zA-Z0-9_-]/g, ch => `\\${ch}`);
  const utilityClass = token => /^(?:p[trblxy]?|m[trblxy]?|gap|space-[xy]|w|h|min-w|max-w|min-h|max-h|text|bg|border|rounded|shadow|grid|flex|block|inline|hidden|relative|absolute|sticky|top|right|bottom|left|z|opacity|overflow|items|justify|content|self|place|col|row|leading|tracking|font)(?:-|$)/i.test(token);
  const badClass = token =>
    !token || token.length > 42 || utilityClass(token) ||
    /^(active|selected|current|open|closed|hover|focus|visible|hidden|show|hide|loaded|loading|container|wrapper)$/i.test(token) ||
    /(^|[-_])(?:active|selected|current|hover|focus|open|closed|is-|has-)/i.test(token) ||
    /[a-f0-9]{10,}/i.test(token);

  const stableClasses = el => Array.from(el?.classList || [])
    .filter(token => /^[A-Za-z_-][A-Za-z0-9_-]*$/.test(token))
    .filter(token => !badClass(token))
    .sort((a, b) => {
      const semantic = token => /(news|press|event|conference|messe|article|post|story|card|entry|item|teaser|result|report)/i.test(token) ? 0 : 1;
      return semantic(a) - semantic(b);
    })
    .slice(0, 4);

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
    for (const cls of stableClasses(el)) {
      out.push(`${tag}.${cssEscape(cls)}`, `.${cssEscape(cls)}`);
    }
    if (['article','li','tr','a','h2','h3','h4'].includes(tag)) out.push(tag);
    return [...new Set(out)];
  };

  const generic = value => {
    const lower = clean(value).toLowerCase();
    if (!lower) return true;
    if (/^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|zur konferenz|zur veranstaltung|tickets?|get started|link öffnet|opens in)$/i.test(lower)) return true;
    if (/^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower)) return true;
    return false;
  };

  const eventElement = event => {
    const path = event?.composedPath?.() || [];
    for (const node of path) {
      if (node?.nodeType === 1) return node;
    }
    return event?.target?.nodeType === 1 ? event.target : event?.target?.parentElement;
  };

  const rawHref = node => {
    if (!node?.getAttribute) return '';
    const raw = node.href || node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || node.getAttribute('data-link') || '';
    if (raw) return raw;
    const onclick = node.getAttribute('onclick') || '';
    const match = onclick.match(/(?:location(?:\.href)?\s*=|window\.open\s*\()\s*['"]([^'"]+)['"]/i);
    return match?.[1] || '';
  };

  const usableHref = value => {
    const raw = clean(value);
    return !!raw && raw !== '#' && !/^(?:javascript:|mailto:|tel:)/i.test(raw);
  };

  const absoluteHref = value => {
    try { return new URL(value, location.href).href; } catch { return ''; }
  };

  const linkCandidates = root => {
    const values = [];
    if (root?.matches?.(clickableSelector)) values.push(root);
    values.push(...Array.from(root?.querySelectorAll?.(clickableSelector) || []));
    return [...new Set(values)].filter(node => usableHref(rawHref(node)));
  };

  const bestTitleElement = (target, clickable, card) => {
    const clickedHeading = target?.closest?.('h1,h2,h3,h4,h5,h6');
    if (clickedHeading && !generic(clickedHeading.textContent)) return clickedHeading;

    const own = clean(clickable?.textContent || clickable?.getAttribute?.('aria-label') || clickable?.getAttribute?.('title') || '');
    if (own.length >= 5 && own.length <= 320 && !generic(own)) return clickable;

    for (const node of Array.from(card?.querySelectorAll?.(titleSelector) || [])) {
      const value = clean(node.textContent || node.getAttribute?.('aria-label') || node.getAttribute?.('title') || '');
      if (value.length >= 5 && value.length <= 320 && !generic(value)) return node;
    }
    return null;
  };

  const bestDateElement = card => card?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]') || null;

  const isPlausibleCard = (node, target) => {
    if (!node || node === document.body || node === document.documentElement) return false;
    const text = clean(node.textContent || '');
    if (text.length < 8 || text.length > 2600) return false;
    const links = linkCandidates(node);
    if (links.length < 1 || links.length > 14) return false;
    if (!bestTitleElement(target, links[0], node)) return false;
    const rect = node.getBoundingClientRect?.();
    return !(rect && (rect.width < 80 || rect.height < 28));
  };

  const cardFor = target => {
    let node = target;
    let fallback = null;
    for (let depth = 0; node && depth < 10 && node !== document.body && node !== document.documentElement; depth += 1, node = node.parentElement) {
      if (!isPlausibleCard(node, target)) continue;
      if (!fallback) fallback = node;
      if (node.matches?.(cardSelector)) return node;
      const classes = Array.from(node.classList || []).join(' ');
      if (/(news|press|event|conference|messe|article|post|story|card|entry|teaser|result|report)/i.test(classes)) return node;
    }
    return fallback;
  };

  const scoreLink = (node, target, card) => {
    const absolute = absoluteHref(rawHref(node));
    if (!absolute) return -10000;
    let score = 0;
    if (target?.closest?.(clickableSelector) === node) score += 250;
    const text = clean(node.textContent || node.getAttribute?.('aria-label') || node.getAttribute?.('title') || '');
    if (!generic(text) && text.length >= 8) score += 70;
    if (/zur konferenz|zur veranstaltung|details|read more|weiterlesen/i.test(text)) score += 25;
    try {
      const url = new URL(absolute);
      if (url.pathname && url.pathname !== '/') score += 35;
      if (url.pathname.split('/').filter(Boolean).length >= 2) score += 20;
      if (url.href !== location.href) score += 20;
    } catch {}
    const heading = card?.querySelector?.(titleSelector);
    if (heading && node.contains?.(heading)) score += 80;
    return score;
  };

  const bestClickable = (target, card) => {
    const direct = target?.closest?.(clickableSelector);
    if (direct && usableHref(rawHref(direct))) return direct;
    const candidates = linkCandidates(card);
    if (!candidates.length) return null;
    return candidates.map(node => ({ node, score: scoreLink(node, target, card) })).sort((a, b) => b.score - a.score)[0]?.node || null;
  };

  const hrefFrom = (clickable, card) => {
    const direct = rawHref(clickable);
    if (usableHref(direct)) return absoluteHref(direct);
    const cardDirect = rawHref(card);
    if (usableHref(cardDirect)) return absoluteHref(cardDirect);
    const best = bestClickable(card, card);
    return best ? absoluteHref(rawHref(best)) : '';
  };

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

  const selectionFor = target => {
    const card = cardFor(target);
    const clickable = bestClickable(target, card);
    if (!card || !clickable) return null;
    const href = hrefFrom(clickable, card);
    if (!href) return null;
    const titleEl = bestTitleElement(target, clickable, card);
    const title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || clickable?.textContent || href);
    if (!title || generic(title)) return null;
    const dateEl = bestDateElement(card);
    return { clickable, card, titleEl, dateEl, highlight: card, href, title, itemCandidates: ancestorCandidates(clickable, titleEl, card) };
  };

  const regexEscape = value => String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const extensionOf = path => {
    const leaf = path.split('/').filter(Boolean).pop() || '';
    return leaf.match(/(\.[A-Za-z0-9]{1,8})$/)?.[1]?.toLowerCase() || '';
  };

  const candidateSelectorFromSelected = () => {
    if (state.selected.length < 2) return clickableSelector;

    let urls;
    try {
      urls = state.selected.map(
        sample => new URL(sample.href, location.href)
      );
    } catch {
      return clickableSelector;
    }

    const hosts = new Set(
      urls.map(url => url.host.toLowerCase())
    );

    if (hosts.size !== 1) return clickableSelector;

    const pathParts = urls.map(
      url => url.pathname.split('/').filter(Boolean)
    );

    const common = [];
    const shortest = Math.min(...pathParts.map(parts => parts.length));

    // Der letzte Pfadteil ist üblicherweise der Artikelslug und wird
    // absichtlich nicht als gemeinsamer Teil verwendet.
    for (let index = 0; index < Math.max(0, shortest - 1); index++) {
      const value = pathParts[0][index];
      if (pathParts.every(parts => parts[index] === value)) {
        common.push(value);
      } else {
        break;
      }
    }

    if (!common.length) return clickableSelector;

    const prefix = '/' + common.join('/') + '/';
    const escaped = prefix
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"');

    return [
      `a[href*="${escaped}"]`,
      `[data-href*="${escaped}"]`,
      `[data-url*="${escaped}"]`,
      `[data-link*="${escaped}"]`,
      `[onclick*="${escaped}"]`
    ].join(',');
  };

  const buildURLRegex = () => {
    if (state.selected.length < 2) return '';
    let urls;
    try { urls = state.selected.map(sample => new URL(sample.href, location.href)); } catch { return ''; }
    const hosts = new Set(urls.map(url => url.host.toLowerCase()));
    if (hosts.size !== 1) return '';
    const host = urls[0].host.toLowerCase();
    const pathParts = urls.map(url => url.pathname.split('/').filter(Boolean));
    const depths = pathParts.map(parts => parts.length);
    if (new Set(depths).size !== 1 || depths[0] < 1) return '';
    const minDepth = depths[0];
    const common = [];
    for (let index = 0; index < Math.max(0, minDepth - 1); index++) {
      const value = pathParts[0][index];
      if (pathParts.every(parts => parts[index] === value)) common.push(value);
      else break;
    }
    const extensions = new Set(urls.map(url => extensionOf(url.pathname)));
    const extension = extensions.size === 1 ? [...extensions][0] : '';
    const dynamicDepth = minDepth - common.length;
    if (dynamicDepth < 1) return '';
    const prefix = '/' + common.map(regexEscape).join('/') + (common.length ? '/' : '');
    const dynamic = Array.from({ length: dynamicDepth }, (_, index) => {
      const isLast = index === dynamicDepth - 1;
      return isLast && extension ? '[^/?#]+' + regexEscape(extension) : '[^/?#]+';
    }).join('/');
    return '^https?://' + regexEscape(host) + regexEscape(prefix) + dynamic + '/?(?:\\\\?[^#]*)?(?:#.*)?$';
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
    const maps = state.selected.map(sample => new Map(sample.itemCandidates.map(candidate => [candidate.selector, candidate.depth])));
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
      const genericPenalty = /^(div|span|section|li|a)$/.test(selector) ? 80 : 0;
      const utilityPenalty = /\.(?:p[trblxy]?|m[trblxy]?|gap|w|h|text|bg|flex|grid)-/i.test(selector) ? 180 : 0;
      const semanticBonus = /(news|press|event|conference|messe|article|post|story|card|entry|teaser|result|report)/i.test(selector) ? -80 : 0;
      const hugePenalty = Math.max(0, count - 120);
      const score = avgDepth * 20 + count + genericPenalty + utilityPenalty + semanticBonus + hugePenalty;
      if (!best || score < best.score) best = { selector, score };
    }
    return best?.selector || '';
  };

  const relativeSelector = (elements, roots, fallback) => {
    if (!elements.length || elements.some(element => !element) || roots.some(root => !root)) return fallback;
    const arrays = elements.map(element => selectorsFor(element));
    for (const selector of arrays[0] || []) {
      if (!arrays.every(array => array.includes(selector))) continue;
      let ok = true;
      for (let index = 0; index < roots.length; index++) {
        try {
          if (!(roots[index].matches?.(selector) || roots[index].querySelector?.(selector))) { ok = false; break; }
        } catch { ok = false; break; }
      }
      if (ok) return selector;
    }
    return fallback;
  };

  const dateFromText = value => {
    const text = clean(value);
    if (!text) return '';

    const patterns = [
      /\b\d{1,2}\.\d{1,2}\.20\d{2}\b/,
      /\b20\d{2}-\d{2}-\d{2}\b/,
      /\b\d{1,2}\.?\s+(?:Jan(?:uar)?|Feb(?:ruar)?|Mär(?:z)?|Mrz|Apr(?:il)?|Mai|Jun(?:i)?|Jul(?:i)?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Dez(?:ember)?|January|February|March|April|May|June|July|August|September|October|November|December)\.?\s+20\d{2}\b/i,
      /\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2},\s+20\d{2}\b/i
    ];

    for (const pattern of patterns) {
      const match = text.match(pattern);
      if (match?.[0]) return match[0];
    }

    return '';
  };

  const smartRow = (clickable, root = null) => {
    const card = root || cardFor(clickable);
    const titleEl = bestTitleElement(clickable, clickable, card);
    const title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || '');
    const href = hrefFrom(clickable, card);
    const dateEl = bestDateElement(card);
    const explicitDate = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || '');
    const date = explicitDate || dateFromText(card?.textContent || '');
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
      linkEl = linkEl || bestClickable(root, root) || (root.matches?.(clickableSelector) ? root : null);
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
    for (const element of Array.from(document.querySelectorAll(clickableSelector))) {
      const row = smartRow(element);
      const absolute = absoluteHref(row.href);
      if (!absolute || (regex && !regex.test(absolute)) || !row.title || generic(row.title) || seen.has(absolute)) continue;
      seen.add(absolute); rows.push({ ...row, href: absolute });
    }
    return rows;
  };

  window.omTrainerBuildRule = () => {
    if (state.selected.length < 2) return { error: 'Bitte mindestens zwei echte Meldungen anklicken.' };

    const urlRegex = buildURLRegex();
    const semantic = urlRegex ? semanticPreview(urlRegex) : [];
    const itemSelector = chooseItemSelector();
    const roots = itemSelector ? state.selected.map(sample => rootFor(sample, itemSelector)) : [];
    const relativeTitleSelector = roots.length && !roots.some(root => !root)
      ? relativeSelector(state.selected.map(sample => sample.titleEl), roots, titleSelector) : '';
    const relativeLinkSelector = roots.length && !roots.some(root => !root)
      ? relativeSelector(state.selected.map(sample => sample.clickable), roots, clickableSelector) : clickableSelector;
    const dateElements = state.selected.map(sample => sample.dateEl);
    const dateSelector = roots.length && dateElements.every(Boolean)
      ? relativeSelector(dateElements, roots, 'time,[class*="date" i],[class*="datum" i],[class*="published" i]') : '';
    const structural = structuralPreview({
      itemSelector,
      titleSelector: relativeTitleSelector,
      linkSelector: relativeLinkSelector,
      dateSelector
    });

    const structuralWithURL = (() => {
      if (!urlRegex) return structural;
      let regex = null;
      try { regex = new RegExp(urlRegex, 'i'); } catch { return structural; }
      return structural.filter(row => {
        try {
          return regex.test(new URL(row.href, location.href).href);
        } catch {
          return false;
        }
      });
    })();

    let allowExternal = false;
    try {
      allowExternal = state.selected.some(
        sample => new URL(sample.href, location.href).host !== location.host
      );
    } catch {}

    const narrowURLLimit = Math.max(18, state.selected.length * 6);
    const urlIsNarrow =
      semantic.length >= state.selected.length &&
      semantic.length <= narrowURLLimit;

    // Ein enges, eindeutig passendes URL-Muster ist weiterhin die
    // einfachste und stabilste Lösung.
    if (urlIsNarrow) {
      return {
        itemSelector: '',
        titleSelector: '',
        linkSelector: '',
        dateSelector: '',
        candidateSelector: candidateSelectorFromSelected(),
        urlRegex,
        allowExternal,
        sampleCount: state.selected.length,
        previewCount: semantic.length,
        preview: semantic.slice(0, 12),
        strategy: 'URL-Muster'
      };
    }

    // Bei Seiten wie Ecommerce News liegen Artikel und Navigationsseiten
    // auf derselben URL-Ebene. Dann ist die Kombination aus Kartenstruktur
    // und URL-Muster wesentlich präziser als URL-only.
    if (
      itemSelector &&
      structuralWithURL.length >= state.selected.length
    ) {
      return {
        itemSelector,
        titleSelector: relativeTitleSelector,
        linkSelector: relativeLinkSelector,
        dateSelector,
        candidateSelector: candidateSelectorFromSelected(),
        urlRegex,
        allowExternal,
        sampleCount: state.selected.length,
        previewCount: structuralWithURL.length,
        preview: structuralWithURL.slice(0, 12),
        strategy: 'Kartenstruktur + URL-Muster'
      };
    }

    if (structural.length >= state.selected.length) {
      return {
        itemSelector,
        titleSelector: relativeTitleSelector,
        linkSelector: relativeLinkSelector,
        dateSelector,
        candidateSelector: clickableSelector,
        urlRegex: '',
        allowExternal,
        sampleCount: state.selected.length,
        previewCount: structural.length,
        preview: structural.slice(0, 12),
        strategy: 'Kartenstruktur'
      };
    }

    // Einige moderne Seiten (z. B. React/Headless-CMS) rendern die
    // Kartenstruktur nach Benutzerinteraktion anders als beim Reload.
    // Wenn die 2–3 bewusst markierten Ziele aber ein gemeinsames enges
    // URL-Muster besitzen, ist dieses Muster selbst die stabilere Regel.
    if (urlRegex) {
      const selectedPreview = state.selected.map(sample => ({
        title: sample.title,
        href: sample.href,
        date: clean(
          sample.dateEl?.getAttribute?.('datetime') ||
          sample.dateEl?.textContent ||
          ''
        )
      }));

      return {
        itemSelector: '',
        titleSelector: '',
        linkSelector: '',
        dateSelector: '',
        candidateSelector: candidateSelectorFromSelected(),
        urlRegex,
        allowExternal,
        sampleCount: state.selected.length,
        previewCount: selectedPreview.length,
        preview: selectedPreview,
        strategy: 'Direktes URL-Muster'
      };
    }

    if (semantic.length >= state.selected.length) {
      return {
        error:
          `Das URL-Muster ist zu breit (${semantic.length} Treffer) und ` +
          `die markierten Karten konnten nicht stabil genug eingegrenzt werden. ` +
          `Bitte 2–3 vergleichbare echte Meldungskarten anklicken.`
      };
    }

    return {
      error:
        `Die ${state.selected.length} markierten Beispiele besitzen weder ` +
        `eine reproduzierbare Kartenstruktur noch ein gemeinsames Ziel-URL-Muster.`
    };
  };

  const post = status => {
    const count = state.selected.length;
    const text = status || (
      count === 0 ? 'Links markieren: Klicke 2–3 echte Meldungen oder Karten an.' :
      count === 1 ? '1 Meldung ausgewählt – bitte noch mindestens eine weitere markieren.' :
      `${count} Meldungen ausgewählt – Regel wird vorbereitet.`
    );
    window.webkit?.messageHandlers?.omVisualTrainer?.postMessage({
      count, status: text,
      samples: state.selected.map(sample => ({ title: sample.title, href: sample.href }))
    });
  };
  window.__omVisualTrainerPost = post;

  window.omTrainerSetMode = mode => {
    state.mode = mode === 'select' ? 'select' : 'browse';
    document.documentElement.setAttribute('data-om-trainer-mode', state.mode);
    return state.mode;
  };

  window.omTrainerReset = () => {
    document.querySelectorAll('[data-om-visual-selected="1"]').forEach(element => element.removeAttribute('data-om-visual-selected'));
    state.selected = [];
    post('Auswahl gelöscht. Klicke 2–3 echte Meldungen oder Karten an.');
  };

  const style = document.createElement('style');
  style.id = 'om-visual-trainer-style';
  style.textContent = `
    [data-om-visual-selected="1"]{outline:4px solid #0a84ff!important;outline-offset:3px!important;border-radius:5px!important;}
    html[data-om-trainer-mode="select"] body,html[data-om-trainer-mode="select"] body *{cursor:crosshair!important;}
  `;
  document.head.appendChild(style);

  document.addEventListener('click', event => {
    if (state.mode !== 'select') return;
    const target = eventElement(event);
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation?.();

    const selection = selectionFor(target);
    if (!selection) {
      post('An dieser Stelle wurde kein verwertbarer Ziel-Link gefunden. Klicke auf Titel, Datum, Logo, Kartenfläche oder den Aktionsbutton.');
      return;
    }

    const existingIndex = state.selected.findIndex(sample => sample.highlight === selection.highlight || sample.href === selection.href);
    if (existingIndex >= 0) {
      state.selected[existingIndex].highlight?.removeAttribute('data-om-visual-selected');
      state.selected.splice(existingIndex, 1);
      post();
      return;
    }

    if (state.selected.length >= 3) {
      post('Es sind bereits 3 Beispiele ausgewählt. Entferne eines durch erneuten Klick.');
      return;
    }

    selection.highlight.setAttribute('data-om-visual-selected','1');
    state.selected.push(selection);
    post();
  }, true);

  window.omTrainerSetMode('browse');
  post();
  return { installed: true, version: '5.0.2' };
})();
"""#
}




private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue, in: Capsule())
                .accessibilityLabel("\(count) ungelesene Meldungen")
        }
    }
}

// MARK: - Integrierter News-Reader

enum ReaderScope: Hashable {
    case newRelevant
    case inbox
    case sinceLastVisit
    case editorial
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

enum ReaderLayoutMode: String, CaseIterable, Identifiable {
    case compact
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Kompakt"
        case .detail: return "Detail"
        }
    }

    var systemImage: String {
        switch self {
        case .compact: return "list.bullet"
        case .detail: return "rectangle.split.3x1"
        }
    }
}

enum ReaderFolderBasis {
    case inbox
    case all
    case favorites
    case archive
}

struct ReaderView: View {
    @ObservedObject var model: AppViewModel

    @State private var scope: ReaderScope = .newRelevant
    @State private var selectedID: String?
    @State private var search = ""
    @State private var sort: ReaderSort = .newest
    @State private var dateRange: ReaderDateRange = .all
    @State private var selectedSource = "Alle"
    @State private var selectedTag = "Alle"
    @State private var minimumPriority = 1
    @State private var layoutMode: ReaderLayoutMode = .compact
    @State private var folderBasis: ReaderFolderBasis = .inbox
    @State private var showWebPreview = false
    @State private var markReadTask: Task<Void, Never>?
    @State private var previousReaderVisit: Date?

    var body: some View {
        Group {
            if layoutMode == .compact {
                NavigationSplitView {
                    readerSidebar
                } detail: {
                    compactReaderList
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView {
                    readerSidebar
                } content: {
                    readerList
                } detail: {
                    readerDetail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear {
            if previousReaderVisit == nil {
                previousReaderVisit = model.beginReaderSession()
            }

            if selectedID == nil {
                selectedID = filteredItems.first?.id
            }

            model.updateReaderDockBadge()
        }
        .onChange(of: selectedID) { _, newValue in
            markReadTask?.cancel()

            // Keine automatische Webnavigation beim Durchklicken.
            showWebPreview = false

            // Im Kompaktmodus wird erst beim tatsächlichen Öffnen als gelesen
            // markiert. Die Verzögerung gilt nur für die Detailansicht.
            guard layoutMode == .detail else { return }

            guard
                let newValue,
                let item = model.readerItems.first(where: { $0.id == newValue })
            else { return }

            markReadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1250))
                guard !Task.isCancelled, selectedID == newValue else { return }
                model.readerMarkRead(item)
            }
        }
        .onChange(of: layoutMode) { _, newMode in
            markReadTask?.cancel()
            showWebPreview = false
            if newMode == .detail {
                ensureSelection()
            }
        }
        .onChange(of: scope) { _, newScope in
            switch newScope {
            case .newRelevant, .inbox, .sinceLastVisit, .editorial:
                folderBasis = .inbox
            case .all:
                folderBasis = .all
            case .favorites:
                folderBasis = .favorites
            case .archive:
                folderBasis = .archive
            case .group:
                break
            }
            ensureSelection()
        }
        .onDisappear {
            markReadTask?.cancel()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            ToolbarItemGroup {
                Picker("Ansicht", selection: $layoutMode) {
                    ForEach(ReaderLayoutMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help("Zwischen kompakter Feed-Liste und Detailansicht wechseln")

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help("Reader im Vollbild anzeigen (⌃⌘F)")

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
                    title: "Neu & relevant",
                    systemImage: "sparkles.rectangle.stack.fill",
                    count: newRelevantCount
                )
                .tag(ReaderScope.newRelevant)

                ReaderSidebarRow(
                    title: "Posteingang",
                    systemImage: "tray.full.fill",
                    count: model.readerUnreadCount
                )
                .tag(ReaderScope.inbox)

                ReaderSidebarRow(
                    title: "Seit letztem Besuch",
                    systemImage: "clock.badge.checkmark",
                    count: sinceLastVisitCount
                )
                .tag(ReaderScope.sinceLastVisit)

                ReaderSidebarRow(
                    title: "Heute relevant",
                    systemImage: "sparkles",
                    count: editorialCount
                )
                .tag(ReaderScope.editorial)

                ReaderSidebarRow(
                    title: "Alle Meldungen",
                    systemImage: "newspaper",
                    count: model.readerActiveAllCount()
                )
                .tag(ReaderScope.all)

                ReaderSidebarRow(
                    title: "Favoriten",
                    systemImage: "star.fill",
                    count: model.readerItems.filter {
                        model.readerIsFavorite($0) &&
                        !model.readerIsArchived($0)
                    }.count
                )
                .tag(ReaderScope.favorites)

                ReaderSidebarRow(
                    title: "Archiv",
                    systemImage: "archivebox",
                    count: model.readerItems.filter {
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
                            count: readerFolderCount(group)
                        )
                        .tag(ReaderScope.group(group))
                    }
                }
            }
        }
        .navigationTitle("News")
        .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 300)
    }

    private var compactReaderList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeTitle)
                        .font(.title2.bold())

                    Text(
                        filteredItems.count == 1
                        ? "1 Meldung"
                        : "\(filteredItems.count) Meldungen"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Meldungen durchsuchen", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 9)

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
                    scope == .inbox ? "Keine neuen Meldungen" : "Keine Meldungen",
                    systemImage: scope == .inbox ? "checkmark.circle" : "newspaper",
                    description: Text(
                        scope == .inbox
                        ? "Seit dem letzten Stand wurden keine ungelesenen Meldungen erkannt."
                        : "Für die gewählten Filter gibt es aktuell keine Meldungen."
                    )
                )
            } else {
                List {
                    ForEach(filteredItems) { item in
                        Button {
                            model.openFeedItem(item)
                            model.readerMarkRead(item)
                        } label: {
                            ReaderCompactItemRow(
                                item: item,
                                isRead: model.readerIsRead(item),
                                isFavorite: model.readerIsFavorite(item)
                            )
                        }
                        .buttonStyle(.plain)
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
                            }

                            Divider()

                            Button("Im Browser öffnen") {
                                model.openFeedItem(item)
                                model.readerMarkRead(item)
                            }
                        }
                        .help("Artikel im Browser öffnen")
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    model.readerMarkAllRead(filteredItems)
                } label: {
                    Label("Alle als gelesen markieren", systemImage: "checkmark.circle")
                }
                .disabled(filteredItems.isEmpty)

                Button {
                    Task { await model.reloadAll() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)

                Spacer()

                Text("Klick auf eine Meldung öffnet den Artikel im Browser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .navigationTitle(scopeTitle)
        .onChange(of: scope) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onChange(of: search) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onChange(of: selectedSource) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onChange(of: selectedTag) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onChange(of: minimumPriority) { _, _ in
            selectedID = filteredItems.first?.id
        }
        .onChange(of: dateRange) { _, _ in
            selectedID = filteredItems.first?.id
        }
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

                            if item.isRecovered {
                                Text("🩹 Wiederhergestellt")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.green.opacity(0.12), in: Capsule())
                            }

                            if item.isHistoricalDelivery {
                                Text("Altbestand")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.orange.opacity(0.12), in: Capsule())
                            }

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
                                item.displayPageDate ?? item.displayDetectedAt,
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

                            if let pageDate = item.displayPageDate, !pageDate.isEmpty {
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

                    HStack {
                        Text("Artikelvorschau")
                            .font(.headline)

                        Spacer()

                        Button {
                            showWebPreview.toggle()
                        } label: {
                            Label(
                                showWebPreview
                                    ? "Vorschau schließen"
                                    : "Vorschau laden",
                                systemImage: showWebPreview
                                    ? "xmark.rectangle"
                                    : "rectangle.and.text.magnifyingglass"
                            )
                        }
                    }

                    if showWebPreview {
                        ReaderWebPreview(urlString: item.link)
                            .frame(minHeight: 430)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(.separator, lineWidth: 1)
                            }
                    } else {
                        ContentUnavailableView(
                            "Vorschau nicht geladen",
                            systemImage: "bolt.horizontal.circle",
                            description: Text(
                                "Die Website wird aus Performance-Gründen erst auf Klick geladen."
                            )
                        )
                        .frame(minHeight: 180)
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
        return model.readerItems.first { $0.id == selectedID }
    }

    private var sourceChoices: [String] {
        ["Alle"] + Array(Set(model.readerItems.map(\.source))).sorted()
    }

    private var tagChoices: [String] {
        ["Alle"] + Array(
            Set(model.readerItems.flatMap { $0.tags ?? [] })
        ).sorted()
    }

    private var newRelevantCount: Int {
        model.readerItems.filter {
            guard !model.readerIsArchived($0),
                  !model.readerIsRead($0),
                  !$0.isHistoricalDelivery,
                  $0.effectivePriority >= 2,
                  $0.publicationIsCurrent()
            else {
                return false
            }

            return true
        }.count
    }

    private var sinceLastVisitCount: Int {
        guard let previousReaderVisit else {
            return model.readerUnreadCount
        }

        return model.readerItems.filter {
            guard !model.readerIsArchived($0),
                  !$0.isHistoricalDelivery,
                  let date = FeedHistoryItem.parsedDate($0.detectedAt)
            else {
                return false
            }

            return date >= previousReaderVisit
        }.count
    }

    private var editorialCount: Int {
        model.readerItems.filter {
            guard !model.readerIsArchived($0),
                  !model.readerIsRead($0),
                  !$0.isHistoricalDelivery,
                  $0.effectivePriority >= 2,
                  let date = $0.effectiveReaderDate
            else {
                return false
            }

            return Calendar.current.isDateInToday(date)
        }.count
    }

    private var scopeTitle: String {
        switch scope {
        case .newRelevant: return "Neu & relevant"
        case .inbox: return "Posteingang"
        case .sinceLastVisit: return "Seit letztem Besuch"
        case .editorial: return "Heute relevant"
        case .all: return "Alle Meldungen"
        case .favorites: return "Favoriten"
        case .archive: return "Archiv"
        case .group(let group): return group
        }
    }

    private var filteredItems: [FeedHistoryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        var values = model.readerItems.filter { item in
            let scopeMatches: Bool = {
                switch scope {
                case .newRelevant:
                    guard !model.readerIsArchived(item),
                          !model.readerIsRead(item),
                          !item.isHistoricalDelivery,
                          item.effectivePriority >= 2,
                          item.publicationIsCurrent(
                            reference: now
                          )
                    else {
                        return false
                    }

                    return true

                case .inbox:
                    return !model.readerIsArchived(item) &&
                        !model.readerIsRead(item) &&
                        !item.isHistoricalDelivery

                case .sinceLastVisit:
                    guard !model.readerIsArchived(item),
                          !item.isHistoricalDelivery
                    else {
                        return false
                    }

                    guard let previousReaderVisit else {
                        return !model.readerIsRead(item)
                    }

                    guard let detected = FeedHistoryItem.parsedDate(
                        item.detectedAt
                    ) else {
                        return false
                    }

                    return detected >= previousReaderVisit

                case .editorial:
                    guard !model.readerIsArchived(item),
                          !model.readerIsRead(item),
                          !item.isHistoricalDelivery,
                          item.effectivePriority >= 2,
                          let published = item.effectiveReaderDate
                    else {
                        return false
                    }

                    return Calendar.current.isDateInToday(published)

                case .all:
                    return model.readerVisibleInAll(
                        item,
                        reference: now
                    )
                case .favorites:
                    return !model.readerIsArchived(item) &&
                        model.readerIsFavorite(item)
                case .archive:
                    return model.readerIsArchived(item)
                case .group(let group):
                    return (item.groups ?? []).contains(group) &&
                        readerItemMatchesFolderBasis(item)
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
                guard let detected = item.effectiveReaderDate else {
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
            let lhsDate =
                lhs.effectiveReaderDate ??
                FeedHistoryItem.parsedDate(lhs.detectedAt) ??
                .distantPast

            let rhsDate =
                rhs.effectiveReaderDate ??
                FeedHistoryItem.parsedDate(rhs.detectedAt) ??
                .distantPast

            switch sort {
            case .newest:
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.detectedAt > rhs.detectedAt
            case .relevance:
                if lhs.effectivePriority != rhs.effectivePriority {
                    return lhs.effectivePriority > rhs.effectivePriority
                }
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
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

    private func readerFolderCount(_ group: String) -> Int {
        switch folderBasis {
        case .inbox:
            return model.readerUnreadCount(in: group)
        case .all:
            return model.readerAllCount(in: group)
        case .favorites:
            return model.readerFavoriteCount(in: group)
        case .archive:
            return model.readerArchivedCount(in: group)
        }
    }

    private func readerItemMatchesFolderBasis(_ item: FeedHistoryItem) -> Bool {
        switch folderBasis {
        case .inbox:
            return !model.readerIsArchived(item) && !model.readerIsRead(item)
        case .all:
            return model.readerVisibleInAll(item)
        case .favorites:
            return !model.readerIsArchived(item) && model.readerIsFavorite(item)
        case .archive:
            return model.readerIsArchived(item)
        }
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

private struct ReaderCompactItemRow: View {
    let item: FeedHistoryItem
    let isRead: Bool
    let isFavorite: Bool

    private var sourceName: String {
        item.sourceLabel ?? item.source
    }

    private var topicName: String {
        if let first = item.groups?.first, !first.isEmpty {
            return first
        }
        return "Ohne Thema"
    }

    private var timelineText: String {
        if let published = item.effectivePublishedDate {
            return "Veröffentlicht: " + published.formatted(
                Date.FormatStyle()
                    .day(.twoDigits)
                    .month(.twoDigits)
                    .year(.twoDigits)
                    .locale(Locale(identifier: "de_DE"))
            )
        }

        guard let date = FeedHistoryItem.parsedDate(item.detectedAt) else {
            return "Erkannt: \(item.displayDetectedAt)"
        }

        if Calendar.current.isDateInToday(date) {
            return "Erkannt: " + date.formatted(
                Date.FormatStyle()
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(Locale(identifier: "de_DE"))
            )
        }

        return "Erkannt: " + date.formatted(
            Date.FormatStyle()
                .day(.twoDigits)
                .month(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(Locale(identifier: "de_DE"))
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)

            Text("\(sourceName) · \(item.title)")
                .font(isRead ? .body : .body.weight(.semibold))
                .foregroundStyle(isRead ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            Text(
                "Quelle: \(sourceName) · Thema: \(topicName) · Relevanz: " +
                String(repeating: "★", count: item.effectivePriority) +
                " · \(timelineText)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 360, idealWidth: 520, maxWidth: 650, alignment: .trailing)

            Image(systemName: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
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

                    Text(
                        item.displayPageDate ??
                        item.displayDetectedAt
                    )
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

