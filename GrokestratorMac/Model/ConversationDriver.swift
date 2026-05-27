import Foundation
import GrokestratorCore

/// Abstraction over "send a prompt, get a stream of updates".
///
/// This is the single seam between the UI and whatever is actually driving a
/// conversation. Today the UI runs against `MockConversationDriver` so we can
/// iterate on the experience without a live `grok` process; `LiveConversationDriver`
/// wires the exact same surface to the real Grok Build black box (`GrokBuildManager`).
public protocol ConversationDriver: Sendable {
    /// Sends a prompt and returns a stream of high-level conversation updates.
    func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate>
}

/// Drives a conversation against a real Grok Build instance via the black box.
///
/// Not used by the default (mock) app state yet — it exists so the wiring point
/// is explicit and compiles. The next slice will launch real instances and hand
/// these to the app model.
public struct LiveConversationDriver: ConversationDriver {
    public let manager: GrokBuildManager
    public let instanceID: UUID

    public init(manager: GrokBuildManager, instanceID: UUID) {
        self.manager = manager
        self.instanceID = instanceID
    }

    public func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        try await manager.sendPrompt(to: instanceID, prompt: prompt)
    }
}

/// Produces a scripted, delayed stream of updates that resembles a real turn
/// (thoughts, progress/activity notes, a tool call, then a final message).
/// Lets us build and feel the UI before wiring real processes.
public struct MockConversationDriver: ConversationDriver {
    public var label: String

    public init(label: String = "mock") {
        self.label = label
    }

    public func send(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        AsyncStream { continuation in
            let task = Task {
                func emit(_ update: ConversationUpdate, after ms: UInt64 = 450) async {
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                    guard !Task.isCancelled else { return }
                    continuation.yield(update)
                }

                // Stream a thought token-by-token, then finalize it.
                let thought = "Parsing request: \"\(prompt)\""
                for word in thought.split(separator: " ") {
                    await emit(.thoughtDelta(String(word) + " "), after: 60)
                }
                await emit(.thought(thought, metadata: nil), after: 100)

                await emit(.progressNote("Scanning workspace", phase: "scan", metadata: nil))
                await emit(.activityNote("Read 3 files", kind: "io", metadata: nil))
                await emit(.toolCallRequested(ToolCallInfo(id: "t1", toolName: "search", arguments: ["query": prompt], sessionId: nil)))
                await emit(.progressNote("Synthesizing answer", phase: "draft", metadata: nil))

                // Stream the answer token-by-token, then finalize it.
                let answer = "(\(label)) Here's a response to: \(prompt)"
                for word in answer.split(separator: " ") {
                    await emit(.messageDelta(String(word) + " "), after: 70)
                }
                await emit(.message(answer, metadata: nil), after: 120)

                await emit(.turnComplete(finalAnswer: answer), after: 150)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
