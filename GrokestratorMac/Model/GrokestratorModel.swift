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

    /// The Grok Build black box. Owns real instance lifecycles; shared by all
    /// `LiveConversationDriver`s.
    let manager = GrokBuildManager()

    init(instances: [InstanceItem]) {
        self.instances = instances
        self.selectedInstanceID = instances.first?.id
    }

    /// Default app state with one mock connection so first run isn't empty.
    convenience init() {
        self.init(instances: [
            InstanceItem(
                name: "Mock Grok (offline)",
                status: .running,
                driver: MockConversationDriver(label: "mock")
            ),
        ])
    }

    var selectedInstance: InstanceItem? {
        guard let id = selectedInstanceID else { return nil }
        return instances.first { $0.id == id }
    }

    /// Adds a mock connection (no real process).
    func addMockConnection(name: String) {
        let item = InstanceItem(name: name, status: .running, driver: MockConversationDriver(label: name))
        instances.append(item)
        selectedInstanceID = item.id
    }

    /// Adds a real connection and launches the underlying `grok` process.
    /// Status reflects launch progress; failures surface into the conversation.
    func addRealConnection(name: String, command: String, arguments: [String], workingDirectory: String?) {
        let config = ManagedInstance(
            name: name,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            status: .stopped
        )
        let item = InstanceItem(
            id: config.id,
            name: name,
            status: .starting,
            driver: LiveConversationDriver(manager: manager, instanceID: config.id)
        )
        instances.append(item)
        selectedInstanceID = item.id

        Task {
            do {
                let updated = try await manager.startInstance(config)
                item.status = updated.status
            } catch {
                item.status = .errored
                item.conversation.appendSystem("Failed to launch: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Stops a real instance's process (no-op for mock connections).
    func stop(_ item: InstanceItem) {
        item.status = .stopping
        Task {
            await manager.stopInstance(id: item.id)
            item.status = .stopped
        }
    }
}
