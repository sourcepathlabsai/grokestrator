import Foundation
import GrokestratorCore

/// Drives a conversation against a Grok Build instance running on a *remote*
/// Grokestrator server (typically reachable over Tailscale). Wraps a
/// `GrokBuildClientSession` so the UI's existing `ConversationDriver` seam
/// works identically for local and remote instances.
///
/// Owned by the parent `RemoteServerLink`, which holds the shared
/// `GrokestratorClient` + network transport for a server.
public final class RemoteConversationDriver: ConversationDriver, @unchecked Sendable {
    private let session: GrokBuildClientSession
    /// Tracks the most recent prompt so `respondToPermission` can address it.
    private var lastPromptID: UUID?

    public init(session: GrokBuildClientSession) {
        self.session = session
    }

    public func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        let started = try await session.startPrompt(prompt)
        lastPromptID = started.promptID
        return started.updates
    }

    public func respondToPermission(permissionId: String, optionId: String) async {
        guard let promptID = lastPromptID else { return }
        try? await session.respondToPermission(promptID: promptID,
                                               permissionId: permissionId,
                                               chosenOption: optionId)
    }

    public func capabilities() async -> AgentCapabilities? {
        await session.getCapabilities()
    }

    public func usage() async -> SessionUsage? {
        await session.getUsage()
    }
}
