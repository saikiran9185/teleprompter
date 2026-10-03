import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("Teleprompter", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.studio)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { app.closeProject() }.keyboardShortcut("n")
                Button("Open Project…") { app.chooseProjectFolder() }.keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export Chosen Takes…") { app.exportChosen() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(app.project == nil)
            }
            CommandMenu("Prompter") {
                Button("Bigger Text") { app.fontSize = min(96, app.fontSize + 4) }.keyboardShortcut("+")
                Button("Smaller Text") { app.fontSize = max(28, app.fontSize - 4) }.keyboardShortcut("-")
                Toggle("Mirror for Teleprompter Glass", isOn: $app.mirror).keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}
