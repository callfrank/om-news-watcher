import SwiftUI

@main
struct OMNewsWatcherApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await model.startup()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neue Quelle …") {
                    model.addSource()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Quellen speichern") {
                    Task { await model.saveSourcesFromToolbar() }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!model.isDirty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
