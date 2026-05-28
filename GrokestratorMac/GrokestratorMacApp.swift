import SwiftUI
import GrokestratorCore

@main
struct GrokestratorMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = GrokestratorModel()

    init() {
        Theme.registerFonts()
        // Register the model with the AppDelegate so applicationWillTerminate
        // can terminate child grok processes on quit.
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .background(Theme.bg)
        }

        Settings {
            SettingsView(model: model)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}
