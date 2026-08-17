import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppViewModel

    @State private var tokenDraft = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let message),
                 .failure(let message):
                return message
            }
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub Repository") {
                    TextField("Benutzer / Organisation", text: $model.owner)
                    TextField("Repository", text: $model.repo)
                    TextField("Branch", text: $model.branch)
                    TextField("Workflow-Datei", text: $model.workflow)
                    TextField("Quellen-Datei", text: $model.sourcesPath)
                }

                Section("E-Mail-Benachrichtigungen") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(
                            "Benachrichtigungen",
                            selection: Binding(
                                get: {
                                    model.emailAlertMode
                                },
                                set: {
                                    model.setEmailAlertMode($0)
                                }
                            )
                        ) {
                            ForEach(EmailAlertMode.allCases) { mode in
                                Text(mode.title)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(model.emailAlertMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Label(
                                "Zeitzone: Europe/Berlin",
                                systemImage: "clock"
                            )

                            Spacer()

                            if model.emailSettingsDirty {
                                Label(
                                    "Noch nicht gespeichert",
                                    systemImage:
                                        "exclamationmark.circle"
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)

                        HStack {
                            Button("Einstellung speichern") {
                                Task {
                                    await model.saveEmailSettings()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                !model.emailSettingsDirty ||
                                model.isBusy
                            )

                            Button("Test-E-Mail senden") {
                                Task {
                                    await model.sendTestEmail()
                                }
                            }
                            .disabled(
                                model.emailAlertMode == .off ||
                                model.isBusy
                            )

                            Spacer()

                            Button("GitHub Secrets öffnen") {
                                model.openRepositorySecrets()
                            }
                        }

                        if let status = model.emailTestStatus {
                            Label(
                                status,
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.green)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                "Einmalig in GitHub Secrets hinterlegen:"
                            )
                            .font(.caption.bold())

                            Text(
                                "OM_SMTP_HOST · OM_SMTP_PORT · OM_SMTP_USER · OM_SMTP_PASSWORD · OM_EMAIL_FROM · OM_EMAIL_TO"
                            )
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)

                            Text(
                                "Empfänger und Mail-Zugangsdaten werden nicht in der öffentlichen sources.json oder in der App gespeichert."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("GitHub-Zugriff") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fine-grained Personal Access Token")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        SecureField(
                            "Token hier einfügen",
                            text: $tokenDraft
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Aus Zwischenablage einfügen") {
                                if let clipboard =
                                    NSPasteboard.general.string(forType: .string) {
                                    tokenDraft = clipboard
                                        .trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        )
                                }
                            }

                            Spacer()

                            Button("Token speichern") {
                                Task {
                                    await model.saveToken(tokenDraft)

                                    if model.hasToken {
                                        tokenDraft = ""
                                        testResult = .success(
                                            "Token wurde im macOS-Schlüsselbund gespeichert."
                                        )
                                    } else if let error = model.errorMessage {
                                        testResult = .failure(error)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                tokenDraft
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    )
                                    .isEmpty
                            )
                        }

                        if model.hasToken {
                            HStack {
                                Label(
                                    "Token ist im macOS-Schlüsselbund gespeichert",
                                    systemImage: "checkmark.circle.fill"
                                )
                                .foregroundStyle(.green)

                                Spacer()

                                Button(
                                    "Token entfernen",
                                    role: .destructive
                                ) {
                                    Task {
                                        await model.clearToken()
                                        testResult = nil
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Text(
                        "Empfohlen: ein Fine-grained Token nur für dieses Repository " +
                        "mit „Contents: Read and write“ und „Actions: Read and write“. " +
                        "Das Token wird im macOS-Schlüsselbund gespeichert."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button {
                                testConnection()
                            } label: {
                                HStack(spacing: 7) {
                                    if isTesting {
                                        ProgressView()
                                            .controlSize(.small)
                                    }

                                    Text(
                                        isTesting
                                        ? "Verbindung wird getestet …"
                                        : "Verbindung testen / Quellen laden"
                                    )
                                }
                            }
                            .disabled(isTesting)

                            Spacer()

                            Button("GitHub-Seite für Fine-grained Tokens öffnen") {
                                if let url = URL(
                                    string:
                                        "https://github.com/settings/personal-access-tokens/new"
                                ) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }

                        if let testResult {
                            HStack(alignment: .top, spacing: 8) {
                                Image(
                                    systemName:
                                        testResult.isSuccess
                                        ? "checkmark.circle.fill"
                                        : "exclamationmark.triangle.fill"
                                )

                                Text(testResult.message)
                                    .textSelection(.enabled)
                            }
                            .font(.callout)
                            .foregroundStyle(
                                testResult.isSuccess
                                ? Color.green
                                : Color.red
                            )
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                .quaternary,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 680, height: 790)
    }

    private func testConnection() {
        guard !isTesting else { return }

        isTesting = true
        testResult = nil
        model.errorMessage = nil

        Task {
            await model.reloadAll()

            await MainActor.run {
                isTesting = false

                if let error = model.errorMessage {
                    testResult = .failure(
                        "Verbindung fehlgeschlagen: \(error)"
                    )
                } else {
                    testResult = .success(
                        "Verbindung erfolgreich – \(model.sources.count) Quellen geladen. " +
                        "Letzter GitHub-Actions-Status wurde ebenfalls abgefragt."
                    )
                }
            }
        }
    }
}
