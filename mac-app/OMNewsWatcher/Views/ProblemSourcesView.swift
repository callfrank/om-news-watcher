import SwiftUI

struct ProblemSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel

    private var testedProblems: [SourceRecord] {
        model.sources.filter { source in
            model.testResults[source.id]?.isProblem == true
        }
    }

    private var pausedSources: [SourceRecord] {
        model.sources.filter { !$0.enabled }
    }

    var body: some View {
        NavigationStack {
            Group {
                if testedProblems.isEmpty && pausedSources.isEmpty {
                    ContentUnavailableView(
                        "Keine Problemquellen",
                        systemImage: "checkmark.seal.fill",
                        description: Text("Aktuell ist beim Schnelltest keine auffällige und keine pausierte Quelle vorhanden.")
                    )
                } else {
                    List {
                        if !testedProblems.isEmpty {
                            Section("Auffällige Quellen (\(testedProblems.count))") {
                                ForEach(testedProblems) { source in
                                    sourceRow(source)
                                }
                            }
                        }

                        if !pausedSources.isEmpty {
                            Section("Pausierte Quellen (\(pausedSources.count))") {
                                ForEach(pausedSources) { source in
                                    sourceRow(source)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Problemquellen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .frame(width: 780, height: 560)
    }

    @ViewBuilder
    private func sourceRow(_ source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon(for: source))
                    .foregroundStyle(color(for: source))

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.headline)
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if model.testingSourceID == source.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Testen") {
                        Task { await model.testSource(source) }
                    }
                }
            }

            Text(problemText(for: source))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let result = model.testResults[source.id], !result.examples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.examples.prefix(3)) { hit in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(hit.title)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }

    private func problemText(for source: SourceRecord) -> String {
        if let result = model.testResults[source.id], result.isProblem {
            return result.message
        }

        if !source.enabled {
            return "Quelle ist pausiert und wird vom GitHub-Watcher derzeit nicht geprüft."
        }

        return "Quelle prüfen."
    }

    private func icon(for source: SourceRecord) -> String {
        if let result = model.testResults[source.id] {
            switch result.kind {
            case .success: return "checkmark.circle.fill"
            case .zeroHits: return "questionmark.circle.fill"
            case .tooManyHits: return "exclamationmark.triangle.fill"
            case .technicalError: return "xmark.octagon.fill"
            }
        }

        return source.enabled ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private func color(for source: SourceRecord) -> Color {
        if let result = model.testResults[source.id] {
            switch result.kind {
            case .success: return .green
            case .zeroHits: return .orange
            case .tooManyHits: return .orange
            case .technicalError: return .red
            }
        }

        return source.enabled ? .green : .secondary
    }
}
