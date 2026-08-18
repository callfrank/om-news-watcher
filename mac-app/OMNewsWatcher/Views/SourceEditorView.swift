import SwiftUI

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SourceRecord
    @State private var showDiscardConfirmation = false

    private let original: SourceRecord
    let isExisting: Bool
    let availableGroups: [String]
    let suggestTags: (SourceRecord) -> [String]
    let onSave: (SourceRecord) -> Void
    let onSaveAndTrain: (SourceRecord) -> Void

    init(
        source: SourceRecord,
        isExisting: Bool,
        availableGroups: [String],
        suggestTags: @escaping (SourceRecord) -> [String],
        onSave: @escaping (SourceRecord) -> Void,
        onSaveAndTrain: @escaping (SourceRecord) -> Void
    ) {
        _draft = State(initialValue: source)
        original = source
        self.isExisting = isExisting
        self.availableGroups = availableGroups
        self.suggestTags = suggestTags
        self.onSave = onSave
        self.onSaveAndTrain = onSaveAndTrain
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quelle") {
                    TextField("Name", text: binding(\.name))

                    TextField("URL", text: Binding(
                        get: { draft.url },
                        set: { newValue in
                            let oldSuggested = SourceRecord.suggestedName(from: draft.url)
                            draft.url = newValue
                            if !isExisting &&
                                (draft.name == "Neue Quelle" || draft.name == oldSuggested) {
                                draft.name = SourceRecord.suggestedName(from: newValue)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)

                    TextField("Feed-Kurzname (optional)", text: Binding(
                        get: { draft.shortName ?? "" },
                        set: { draft.shortName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Section("Ordner") {
                    Picker("Ordner / Themenbereich", selection: primaryGroupBinding) {
                        Text("Ohne Ordner").tag("")
                        ForEach(groupChoices, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Der Ordner steuert die redaktionelle Hauptsortierung. Inhaltliche Begriffe werden separat als Schlagworte gepflegt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Themen & Schlagworte") {
                    Toggle(
                        "Schlagworte automatisch aus erkannten Inhalten ergänzen",
                        isOn: binding(\.automaticTagging)
                    )

                    TextField("Schlagworte – mit Komma trennen", text: Binding(
                        get: { draft.tags.joined(separator: ", ") },
                        set: { draft.tags = splitList($0) }
                    ))

                    if !currentTagSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Automatische Vorschläge")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(currentTagSuggestions, id: \.self) { tag in
                                    Button {
                                        toggleTag(tag)
                                    } label: {
                                        Label(
                                            tag,
                                            systemImage: containsTag(tag)
                                                ? "checkmark.circle.fill"
                                                : "plus.circle"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(containsTag(tag) ? .green : nil)
                                }
                            }
                        }
                    } else {
                        Text("Nach einem erfolgreichen Quellentest kann die App zusätzliche Schlagworte aus den erkannten Meldungstiteln ableiten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Redaktionelle Relevanz", selection: binding(\.priority)) {
                        Text("★☆☆ Niedrig").tag(1)
                        Text("★★☆ Normal").tag(2)
                        Text("★★★ Hoch").tag(3)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Überwachung") {
                    Picker("Status", selection: binding(\.enabled)) {
                        Label("Aktiv", systemImage: "checkmark.circle.fill").tag(true)
                        Label("Pausiert", systemImage: "pause.circle.fill").tag(false)
                    }
                    .pickerStyle(.segmented)

                    Text(
                        draft.enabled
                            ? "Die Quelle wird bei den nächsten Läufen geprüft."
                            : "Die Quelle bleibt erhalten, wird aber nicht geprüft und erzeugt keine neuen Meldungen."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Inhaltsfilter (optional)") {
                    TextField("Nur wenn eines dieser Wörter vorkommt", text: Binding(
                        get: { draft.includeKeywords.joined(separator: ", ") },
                        set: { draft.includeKeywords = splitList($0) }
                    ))

                    TextField("Diese Wörter ausschließen", text: Binding(
                        get: { draft.excludeKeywords.joined(separator: ", ") },
                        set: { draft.excludeKeywords = splitList($0) }
                    ))

                    Text("Die Filter gelten für den erkannten Titel. Leer lassen = keine Einschränkung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Erkennung") {
                    HStack {
                        Text("JavaScript-Wartezeit")
                        Spacer()
                        Stepper(
                            "\(draft.waitMs) ms",
                            value: binding(\.waitMs),
                            in: 0...8000,
                            step: 500
                        )
                    }

                    Text("Schwierige Quellen kannst du zusätzlich visuell einlernen. Die Validierung lädt die Seite danach vollständig neu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        onSaveAndTrain(preparedDraft)
                    } label: {
                        Label("Speichern & visuell einlernen", systemImage: "cursorarrow.click.2")
                    }
                    .disabled(!isValid)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isExisting ? "Quelle bearbeiten" : "Quelle hinzufügen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { requestDismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(preparedDraft)
                    } label: {
                        Label(
                            hasDraftChanges ? "Änderungen speichern" : "Speichern",
                            systemImage: hasDraftChanges
                                ? "exclamationmark.circle.fill"
                                : "square.and.arrow.down"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(hasDraftChanges ? .orange : .accentColor)
                    .disabled(!isValid)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .frame(width: 700, height: 720)
        .interactiveDismissDisabled(hasDraftChanges)
        .confirmationDialog(
            "Ungespeicherte Änderungen verwerfen?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Änderungen verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        } message: {
            Text("Die Änderungen an dieser Quelle wurden noch nicht übernommen.")
        }
    }

    private var preparedDraft: SourceRecord {
        var value = draft
        if value.automaticTagging {
            value.tags = mergedTags(value.tags, currentTagSuggestions)
        }
        return value
    }

    private var primaryGroupBinding: Binding<String> {
        Binding(
            get: { draft.primaryGroup ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.groups = trimmed.isEmpty ? [] : [trimmed]
            }
        )
    }

    private var groupChoices: [String] {
        var values = availableGroups
        if let current = draft.primaryGroup,
           !values.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            values.append(current)
        }
        return values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var currentTagSuggestions: [String] { suggestTags(draft) }
    private var hasDraftChanges: Bool { draft != original }

    private func requestDismiss() {
        if hasDraftChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SourceRecord, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func containsTag(_ tag: String) -> Bool {
        draft.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func toggleTag(_ tag: String) {
        if containsTag(tag) {
            draft.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        } else {
            draft.tags.append(tag)
        }
    }

    private func mergedTags(_ existing: [String], _ suggestions: [String]) -> [String] {
        var result = existing
        for suggestion in suggestions where !result.contains(
            where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        ) {
            result.append(suggestion)
        }
        return result
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: draft.url)?.scheme?.hasPrefix("http") == true
    }
}
