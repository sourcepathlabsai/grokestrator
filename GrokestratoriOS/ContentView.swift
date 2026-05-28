import SwiftUI
import GrokestratorCore

/// Root iOS scene. NavigationSplitView collapses to a navigation stack on
/// iPhone (sidebar pushes detail) and shows a two-column split on iPad.
struct iOSContentView: View {
    @Bindable var model: iOSAppModel

    var body: some View {
        NavigationSplitView {
            iOSConnectionsListView(model: model)
        } detail: {
            if let id = model.selectedInstanceID,
               let instance = model.instances.first(where: { $0.id == id }) {
                iOSConversationView(instance: instance)
            } else {
                ContentUnavailableView(
                    "Select a Connection",
                    systemImage: "tray",
                    description: Text("Pick a Connection from a server in the sidebar.")
                )
                .foregroundStyle(Theme.textMuted)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
