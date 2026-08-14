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
                    TextField("Name", text: Binding(
                        get: { draft.name },
                        set: { draft.name = $0 }
                    ))

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

                    TextField(
                        "Feed-Kurzname (optional)",
                        text: Binding(
                            get: { draft.shortName ?? "" },
                            set: { draft.shortName = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Text("Feedly: \(draft.feedLabel) · <Originaltitel>")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Aktiv überwachen", isOn: Binding(
                        get: { draft.enabled },
                        set: { draft.enabled = $0 }
                    ))
                }

                Section("Erkennung") {
                    HStack {
                        Text("JavaScript-Wartezeit")
                        Spacer()
                        Stepper(
                            "\(draft.waitMs) ms",
                            value: Binding(
                                get: { draft.waitMs },
                                set: { draft.waitMs = $0 }
                            ),
                            in: 0...8000,
                            step: 500
                        )
                    }

                    Text("Die automatische Erkennung bleibt erhalten. Für neue oder schwierige Quellen kannst du die Seite zusätzlich visuell einlernen: Öffne die Website in der App und klicke 2–3 echte Meldungen an.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        onSaveAndTrain(draft)
                    } label: {
                        Label(
                            "Speichern & visuell einlernen",
                            systemImage: "cursorarrow.click.2"
                        )
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
                    Button("Speichern") {
                        onSave(draft)
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(width: 580, height: 450)
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: draft.url)?.scheme?.hasPrefix("http") == true
    }
}
