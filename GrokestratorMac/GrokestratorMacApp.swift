import SwiftUI
import GrokestratorCore

@main
struct GrokestratorMacApp: App {
    @State private var model = GrokestratorModel()

    init() {
        Theme.registerFonts()
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
