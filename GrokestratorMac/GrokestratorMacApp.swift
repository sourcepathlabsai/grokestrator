import SwiftUI
import GrokestratorCore

@main
struct GrokestratorMacApp: App {
    @State private var model = GrokestratorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
