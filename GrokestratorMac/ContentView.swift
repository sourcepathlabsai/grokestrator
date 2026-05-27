import SwiftUI
import GrokestratorCore

struct ContentView: View {
    @Bindable var model: GrokestratorModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let instance = model.selectedInstance {
                ConversationView(instance: instance)
            } else {
                ContentUnavailableView(
                    "No connection selected",
                    systemImage: "terminal",
                    description: Text("Pick a Grok Build instance from the sidebar.")
                )
            }
        }
    }
}

#Preview {
    ContentView(model: GrokestratorModel())
}
