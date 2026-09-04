import SwiftUI
import AppKit

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
            CommandGroup(replacing: .appInfo) {
                Button("Über OM News Watcher") {
                    AboutPanelPresenter.show()
                }
            }

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

        Window("OM News Reader", id: "reader") {
            ReaderView(model: model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)

        Settings {
            SettingsView(model: model)
        }
    }
}

private enum AboutPanelPresenter {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 5

        let credits = NSAttributedString(
            string: """
            Persönlicher News-Reader und Quellenmonitor
            für onlinemarktplatz.de

            Entwickelt und betrieben von
            Frank Weyermann

            Prüft Nachrichtenquellen, bündelt neue Meldungen
            und unterstützt die redaktionelle Sichtung.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )

        NSApp.orderFrontStandardAboutPanel(
            options: [
                .credits: credits
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
    }
}
