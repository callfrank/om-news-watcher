import SwiftUI

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SourceRecord
    let isExisting: Bool
    let onSave: (SourceRecord) -> Void
    let onSaveAndTrain: (SourceRecord) -> Void

    init(
        source: SourceRecord,
        isExisting: Bool,
        onSave: @escaping (SourceRecord) -> Void,
        onSaveAndTrain: @escaping (SourceRecord) -> Void
    ) {
        _draft = State(initialValue: source)
        self.isExisting = isExisting
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
                            if !isExisting && (draft.name == "Neue Quelle" || draft.name == oldSuggested) {
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

                    Toggle("Aktiv überwachen", isOn: binding(\.enabled))
                }

                Section("Redaktion & Sortierung") {
                    TextField("Ordner/Themen – mit Komma trennen", text: Binding(
                        get: { draft.groups.joined(separator: ", ") },
                        set: { draft.groups = splitList($0) }
                    ))
                    Text("Beispiele: Marktplätze & Handel, Payment, Logistik, Studien & Marktdaten, Recht & Regulierung, Events")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Schlagwörter – mit Komma trennen", text: Binding(
                        get: { draft.tags.joined(separator: ", ") },
                        set: { draft.tags = splitList($0) }
                    ))

                    Picker("Redaktionelle Relevanz", selection: binding(\.priority)) {
                        Text("★☆☆ Niedrig").tag(1)
                        Text("★★☆ Normal").tag(2)
                        Text("★★★ Hoch").tag(3)
                    }
                    .pickerStyle(.segmented)

                    Text("Die Priorität beeinflusst die Reihenfolge in Gruppenfeeds, Feed-Vorschau und E-Mail-Zusammenfassung.")
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

                    Text("Die automatische Erkennung bleibt erhalten. Schwierige Quellen kannst du zusätzlich visuell einlernen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        onSaveAndTrain(draft)
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
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { onSave(draft) }
                        .disabled(!isValid)
                }
            }
        }
        .frame(width: 680, height: 650)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SourceRecord, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: draft.url)?.scheme?.hasPrefix("http") == true
    }
}
