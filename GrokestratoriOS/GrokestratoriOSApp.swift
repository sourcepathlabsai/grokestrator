import SwiftUI

@main
struct GrokestratoriOSApp: App {
    @State private var model = iOSAppModel()
    @Environment(\.scenePhase) private var scenePhase

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
        // The OS suspends us and kills sockets while the phone sleeps; on return
        // to the foreground, refresh links so a dropped connection re-establishes
        // (and its Connections rebind to a live session) instead of staying stuck.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.handleForeground() }
        }
    }
}
