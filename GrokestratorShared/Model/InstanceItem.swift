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

    /// True while this Connection is waiting on the user — a pending permission or
    /// question. Because every Connection subscribes eagerly (even unopened ones),
    /// this is set for background Connections too, so the sidebar "needs you" badge
    /// and the global/Dock count can surface a pending prompt without opening it.
    var needsAttention: Bool {
        conversation.pendingPermission != nil || conversation.pendingUserQuestion != nil
    }

    init(id: UUID = UUID(), name: String, status: InstanceStatus,
                driver: ConversationDriver, serverID: UUID? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conversation = ConversationViewModel(driver: driver)
        self.serverID = serverID
    }
}
