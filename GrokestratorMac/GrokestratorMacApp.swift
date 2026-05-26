import SwiftUI
import GrokestratorCore

@main
struct GrokestratorMacApp: App {
    // In a real Xcode project, you would add the local GrokestratorCore package
    // via File > Add Packages > Add Local... pointing to ../Packages/GrokestratorCore

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)  // Clean, low-chrome Mac feel to start
    }
}
