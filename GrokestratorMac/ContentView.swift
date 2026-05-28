import SwiftUI
import GrokestratorCore

struct ContentView: View {
    @Bindable var model: GrokestratorModel
    /// The inspector follows the current selection (design/02): kept here at the
    /// top level so its open/closed state persists as you switch instances.
    @State private var showInspector = false

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
        .inspector(isPresented: $showInspector) {
            InstanceInspectorView(instance: model.selectedInstance, model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show instance inspector")
            }
        }
    }
}

#Preview {
    ContentView(model: GrokestratorModel())
}
