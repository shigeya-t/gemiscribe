import SwiftUI

@main
struct GemiScribeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(appState.localizer)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 940, height: 700)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(appState.localizer[.settings]) {
                    appState.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
