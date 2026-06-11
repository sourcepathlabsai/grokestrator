import Foundation
import Observation
import GrokestratorCore

/// A Connection shown in the UI, paired with its conversation view-model.
///
/// `serverID == nil` ⇒ a local Connection (Mac-hosted, drivable in-process).
/// `serverID != nil` ⇒ a remote Connection living on `RemoteServerLink.id`.
/// iOS only sees the remote case (it's a client-only app).
///
/// Lives in the shared target so both Mac and iOS UI code refer to the same type.
@MainActor
@Observable
final class InstanceItem: Identifiable {
    let id: UUID
    var name: String
    var status: InstanceStatus
    let conversation: ConversationViewModel
    /// `nil` for local; non-nil for remote (= the `RemoteServerLink.id`).
    let serverID: UUID?

    /// Place in the orchestration tree (see `ManagedConnection.role`). Mirrored
    /// here so the sidebar can render orchestrators with their children nested.
    var role: NodeRole
    /// The orchestrator this Connection reports to, or `nil` for a root. Used to
    /// group children under their parent in the sidebar. Always references a
    /// sibling on the *same* server (orchestration is host-local).
    var parentID: UUID?

    /// The Node's role/system prompt (see `ManagedConnection.rolePrompt`), mirrored
    /// here so the "Edit Role…" sheet can show/edit it. `nil`/empty ⇒ none.
    var rolePrompt: String?

    /// True while this Connection is waiting on the user — a pending permission or
    /// question. Because every Connection subscribes eagerly (even unopened ones),
    /// this is set for background Connections too, so the sidebar "needs you" badge
    /// and the global/Dock count can surface a pending prompt without opening it.
    var needsAttention: Bool {
        conversation.pendingPermission != nil || conversation.pendingUserQuestion != nil
    }

    /// True while this Connection's agent is actively working a turn. Because
    /// every Connection subscribes eagerly, this reflects busy state even for
    /// background Connections and for turns driven from another device — so the
    /// sidebar can show, at a glance, which agents are busy. This is the leaf-node
    /// signal the orchestration tree will roll up once nodes have children.
    var isBusy: Bool { conversation.isStreaming }

    init(id: UUID = UUID(), name: String, status: InstanceStatus,
                driver: ConversationDriver, serverID: UUID? = nil,
                role: NodeRole = .agent, parentID: UUID? = nil, rolePrompt: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conversation = ConversationViewModel(driver: driver)
        self.serverID = serverID
        self.role = role
        self.parentID = parentID
        self.rolePrompt = rolePrompt
    }
}
