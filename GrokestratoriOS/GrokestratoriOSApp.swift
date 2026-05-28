import SwiftUI

@main
struct GrokestratoriOSApp: App {
    @State private var model = iOSAppModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            iOSContentView(model: model)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
                .background(Theme.bg.ignoresSafeArea())
        }
    }
}
