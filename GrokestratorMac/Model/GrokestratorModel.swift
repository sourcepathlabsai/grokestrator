import Foundation
import Observation
import GrokestratorCore

/// A connection (Grok Build instance) shown in the sidebar, plus its conversation.
///
/// For this first slice each instance owns a single conversation; multiple
/// conversations per instance (per design 02) come later.
@MainActor
@Observable
final class InstanceItem: Identifiable {
    let id: UUID
    var name: String
    var status: InstanceStatus
    let conversation: ConversationViewModel

    init(id: UUID = UUID(), name: String, status: InstanceStatus, driver: ConversationDriver) {
        self.id = id
        self.name = name
        self.status = status
        self.conversation = ConversationViewModel(driver: driver)
    }
}

/// Root application state for the Mac app.
///
/// Owns the list of instances and the current selection. Seeded with mock
/// instances so the UI is runnable and iterable without a live `grok` process;
/// real instances (backed by `LiveConversationDriver`) plug in here next.
@MainActor
@Observable
final class GrokestratorModel {
    var instances: [InstanceItem]
    var selectedInstanceID: InstanceItem.ID?

    init(instances: [InstanceItem]) {
        self.instances = instances
        self.selectedInstanceID = instances.first?.id
    }

    /// Default app state with a couple of mock connections.
    convenience init() {
        self.init(instances: [
            InstanceItem(
                name: "Local Grok 1 (heavy MCPs)",
                status: .running,
                driver: MockConversationDriver(label: "grok-1")
            ),
            InstanceItem(
                name: "Local Grok 2 (clean research)",
                status: .running,
                driver: MockConversationDriver(label: "grok-2")
            ),
        ])
    }

    var selectedInstance: InstanceItem? {
        guard let id = selectedInstanceID else { return nil }
        return instances.first { $0.id == id }
    }
}
