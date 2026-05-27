import SwiftUI
import GrokestratorCore

/// Left sidebar: the list of connected Grok Build instances (design 02).
struct SidebarView: View {
    @Bindable var model: GrokestratorModel
    @State private var showingAdd = false

    var body: some View {
        List(selection: $model.selectedInstanceID) {
            Section("Connections") {
                ForEach(model.instances) { instance in
                    InstanceRow(instance: instance)
                        .tag(instance.id)
                        .contextMenu {
                            if instance.status == .running || instance.status == .starting {
                                Button("Stop") { model.stop(instance) }
                            }
                        }
                }
            }
        }
        .navigationTitle("Grokestrator")
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddConnectionView(model: model)
        }
    }
}

/// A single connection row: status indicator + name.
private struct InstanceRow: View {
    let instance: InstanceItem

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(instance.name)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .crashed, .errored: return .red
        case .stopped: return .secondary
        }
    }
}
