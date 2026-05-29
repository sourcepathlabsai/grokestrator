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
        .commands {
            // Replace the stock about panel with our branded window.
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
        }

        // Branded About window, opened from the app menu above.
        Window("About Grokestrator", id: Self.aboutWindowID) {
            AboutView()
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(model: model)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }

    static let aboutWindowID = "about-grokestrator"
}

/// The "About Grokestrator" menu item. A tiny view so it can read
/// `openWindow` from the environment to surface the branded `AboutView`.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Grokestrator") {
            openWindow(id: GrokestratorMacApp.aboutWindowID)
        }
    }
}
